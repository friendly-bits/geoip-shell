#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-apply-ipt.sh

# iptables-specific library for the -apply script

# Copyright: friendly bits
# github.com/friendly-bits

. "$_lib-ipt.sh" || exit 1


#### FUNCTIONS

die_a() {
	destroy_tmp_ipsets
	set +f; rm "$iplist_dir/"*.iplist 2>/dev/null; set -f
	die "$@"
}

critical() {
	echo "Failed." >&2
	echolog -err "Removing geoip rules..."
	rm_all_georules
	set +f; rm "$iplist_dir/"*.iplist 2>/dev/null; set -f
	die "$1"
}

destroy_tmp_ipsets() {
	echolog -err "Destroying temporary ipsets..."
	for tmp_ipset in $(ipset list -n | grep "$p_name" | grep "temp"); do
		ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null
	done
}

enable_geoip() {
	[ -n "$_ifaces" ] && first_chain="$iface_chain" || first_chain="$geochain"
	for family in $families; do
		set_ipt_cmds || die_a
		enable_rule="$(eval "$ipt_save_cmd" | grep "${geotag}_enable")"
		[ ! "$enable_rule" ] && {
			printf %s "Inserting the enable geoip $family rule... "
			eval "$ipt_cmd" -I PREROUTING -j "$first_chain" $ipt_comm "${geotag}_enable" || critical "$insert_failed"
			OK
		} || printf '%s\n' "Geoip is already enabled for $family."
	done
}

# 1 - iptables tag
mk_ipt_rm_cmd() {
	for tag in "$@"; do
		printf '%s\n' "$curr_ipt"  | sed -n "/$tag/"'s/^-A /-D /p' || return 1
	done
}

add_ipset() {
	perm_ipset="$1"; tmp_ipset="${1}_temp"; iplist_file="$2"; ipset_type="$3"
	[ ! -f "$iplist_file" ] && critical "Can not find the iplist file in path: '$iplist_file'."

	ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null

	# count ips in the iplist file
	ip_cnt=$(wc -w < "$iplist_file")
#	debugprint "ip count in the iplist file '$iplist_file': $ip_cnt"

	# set hashsize to 1024 or (ip_cnt / 2), whichever is larger
	ipset_hs=$((ip_cnt / 2))
	[ $ipset_hs -lt 1024 ] && ipset_hs=1024
	debugprint "hashsize for ipset $list_id: $ipset_hs"

	debugprint "Creating ipset '$tmp_ipset'... "
	ipset create "$tmp_ipset" hash:$ipset_type family "$family" hashsize "$ipset_hs" maxelem "$ip_cnt" ||
		crtical "$FAIL create ipset '$tmp_ipset'."
	debugprint "Ok."

	debugprint "Importing iplist '$iplist_file' into temporary ipset... "
	# read $iplist_file, transform each line into 'add' command and pipe the result into "ipset restore"
	sed "s/^/add \"$tmp_ipset\" /" "$iplist_file" | ipset restore -exist ||
		critical "$FAIL import the iplist from '$iplist_file' into ipset '$tmp_ipset'."
	debugprint "Ok."

	[ "$debugmode" ] && debugprint "ip's in the temporary ipset: $(ipset save "$tmp_ipset" | grep -c "add $tmp_ipset")"

	# swap the temp ipset with the permanent ipset
	debugprint "Making the ipset '$perm_ipset' permanent... "
	ipset swap "$tmp_ipset" "$perm_ipset" || critical "$FAIL swap temporary and permanent ipsets."
	debugprint "Ok."
	rm "$iplist_file"
}

mk_perm_ipset() {
	perm_ipset="$1"; ipset_type="$2"; tmp_ipset="${perm_ipset}_temp"
	# create new permanent ipset if it doesn't exist
	case "$curr_ipsets" in *"$perm_ipset"* ) ;; *)
		debugprint "Creating permanent ipset '$perm_ipset'... "
		ipset create "$perm_ipset" hash:$ipset_type family "$family" hashsize 1 maxelem 1 ||
			die_a "$FAIL create ipset '$perm_ipset'."
		debugprint "Ok."
	esac
}

get_curr_ipsets() {
	curr_ipsets="$(ipset list -n | grep "$p_name")"
}

rm_ipset() {
	[ ! "$1" ] && return 0
	case "$curr_ipsets" in
		*"$1"* )
			debugprint "Destroying ipset '$1'... "
			ipset destroy "$1"; rv=$?
			case "$rv" in
				0) debugprint "Ok." ;;
				*) debugprint "Failed."; echolog -warn "$FAIL destroy ipset '$1'."; retval="254"
			esac
	esac
}


#### VARIABLES

case "$geomode" in
	whitelist) fw_target=ACCEPT ;;
	blacklist) fw_target=DROP ;;
	*) die "Unknown firewall mode '$geomode'."
esac

retval=0

insert_failed="$FAIL insert a firewall rule."
ipt_comm="-m comment --comment"

ipsets_to_rm=

#### MAIN

### apply the 'on' and 'off' actions
case "$action" in
	off)
		for family in $families; do
			set_ipt_cmds || die
			enable_rule="$(eval "$ipt_save_cmd" | grep "${geotag}_enable")"
			if [ "$enable_rule" ]; then
				rm_ipt_rules "${geotag}_enable" || critical
			else
				printf '%s\n' "Geoip is already disabled for $family."
			fi
		done
		exit 0 ;;
	on) enable_geoip; exit 0
esac

[ ! "$list_ids" ] && [ "$action" != update ] && {
	usage
	die 254 "Specify iplist id's!"
}

get_curr_ipsets

for family in $families; do
	set_ipt_cmds || die_a
	curr_ipt="$(eval "$ipt_save_cmd")" || die_a "$FAIL read iptables rules."

	# remove lan and trusted ipsets
	t_ipset="trusted_${family}_${geotag}"
	lan_ipset="lan_ips_${family}_${geotag}"
	rm_ipt_rules "$t_ipset" >/dev/null
	rm_ipt_rules "$lan_ipset" >/dev/null
	sleep 0.1 2>/dev/null || sleep 1
	rm_ipset "$t_ipset"
	rm_ipset "$lan_ipset"

	get_curr_ipsets
	curr_ipt="$(eval "$ipt_save_cmd")" || die_a "$FAIL read iptables rules."

	ipsets_to_add=

	### make perm ipsets, assemble $ipsets_to_add and $ipsets_to_rm
	for list_id in $list_ids; do
		case "$list_id" in *_*) ;; *) die_a "Invalid iplist id '$list_id'."; esac
		[ "${list_id#*_}" != "$family" ] && continue
		perm_ipset="${list_id}_$geotag"
		if [ "$action" = add ]; then
			iplist_file="${iplist_dir}/${list_id}.iplist"
			mk_perm_ipset "$perm_ipset" net
			ipsets_to_add="$ipsets_to_add$perm_ipset $iplist_file$_nl"
		elif [ "$action" = remove ]; then
			ipsets_to_rm="$ipsets_to_rm$perm_ipset "
		fi
	done

	### trusted subnets/ip's
	eval "trusted=\"\$trusted_$family\""
	ipset_type=net
	case "${trusted%%":"*}" in net|ip)
		ipset_type="${trusted%%":"*}"
		trusted="${trusted#*":"}"
	esac

	[ -n "$trusted" ] && {
		iplist_file="$iplist_dir/$t_ipset.iplist"
		sp2nl trusted
		printf '%s\n' "$trusted" > "$iplist_file" || die_a "$FAIL write to file '$iplist_file'"
		mk_perm_ipset "$t_ipset" "$ipset_type"
		ipsets_to_add="$ipsets_to_add$ipset_type:$t_ipset $iplist_file$_nl"
	}

	### LAN subnets/ip's
	[ "$geomode" = whitelist ] && {
		if [ ! "$autodetect" ]; then
			eval "lan_ips=\"\$lan_ips_$family\""
		else
			a_d_failed=
			lan_ips="$(call_script "${i_script}-detect-lan.sh" -s -f "$family")" || a_d_failed=1
			[ ! "$lan_ips" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL detect $family LAN subnets."; exit 1; }
			lan_ips="net:$lan_ips"
			setconfig "LanSubnets_$family" "$lan_ips"
		fi

		ipset_type="${lan_ips%%":"*}"
		lan_ips="${lan_ips#*":"}"
		[ -n "$lan_ips" ] && {
			iplist_file="$iplist_dir/$lan_ipset.iplist"
			sp2nl lan_ips
			printf '%s\n' "$lan_ips" > "$iplist_file" || die_a "$FAIL write to file '$iplist_file'"
			mk_perm_ipset "$lan_ipset" "$ipset_type"
			ipsets_to_add="$ipsets_to_add$ipset_type:$lan_ipset $iplist_file$_nl"
		}
	}

	#### Assemble commands for iptables-restore
	printf %s "Assembling new $family firewall rules... "
	### Read current iptables rules
	set_ipt_cmds || die_a

	iptr_cmd_chain="$(
		rv=0

		printf '%s\n' "*$ipt_table"

		### Remove existing geoip rules

		## Remove the main blocking rule, the whitelist blocking rule and the auxiliary rules
		mk_ipt_rm_cmd "${geotag}_enable" "${geotag_aux}" "${geotag}_whitelist_block" "${geotag}_iface_filter" || rv=1

		## Remove rules for $list_ids
		for list_id in $list_ids; do
			[ "$family" != "${list_id#*_}" ] && continue
			list_tag="${p_name}_${list_id}"
			mk_ipt_rm_cmd "$list_tag" || rv=1
		done


		## Create the geochain if it doesn't exist
		case "$curr_ipt" in *":$geochain "*) ;; *) printf '%s\n' ":$geochain -"; esac

		### Create new rules

		# interfaces
		if [ -n "$_ifaces" ]; then
			case "$curr_ipt" in *":$iface_chain "*) ;; *) printf '%s\n' ":$iface_chain -"; esac
			for _iface in $_ifaces; do
				printf '%s\n' "-i $_iface -I $iface_chain -j $geochain $ipt_comm ${geotag}_iface_filter"
			done
		fi

		## Auxiliary rules

		# trusted subnets/ips
		[ "$trusted" ] &&
			printf '%s\n' "-I $geochain -m set --match-set trusted_${family}_${geotag} src $ipt_comm trusted_${family}_${geotag_aux} -j ACCEPT"

		# LAN subnets/ips
		[ "$geomode" = whitelist ] && [ "$lan_ips" ] &&
			printf '%s\n' "-I $geochain -m set --match-set lan_ips_${family}_${geotag} src $ipt_comm lan_ips_${family}_${geotag_aux} -j ACCEPT"

		# ports
		for proto in tcp udp; do
			eval "ports_exp=\"\${${proto}_ports%:*}\" ports=\"\${${proto}_ports##*:}\""
			[ "$ports_exp" = skip ] && continue
			if [ "$ports_exp" = all ]; then
				ports_exp=
			else
				dport='--dport'
				case "$ports_exp" in *multiport*) dport='--dports'; esac
				ports="$(printf %s "$ports" | sed 's/-/:/g')"
				ports_exp="$(printf %s "$ports_exp" | sed "s/all//;s/multiport/-m multiport/;s/!/! /;s/dport/$dport/") $ports"
			fi
			printf '%s\n' "-I $geochain -p $proto $ports_exp -j ACCEPT $ipt_comm ${geotag_aux}_ports"
		done

		# established/related
		printf '%s\n' "-I $geochain -m conntrack --ctstate RELATED,ESTABLISHED $ipt_comm ${geotag_aux}_rel-est -j ACCEPT"

		# lo interface
		[ "$geomode" = whitelist ] && [ ! "$_ifaces" ] && \
			printf '%s\n' "-I $geochain -i lo $ipt_comm ${geotag_aux}-lo -j ACCEPT"

		## iplist-specific rules
		if [ "$action" = add ]; then
			for list_id in $list_ids; do
				[ "$family" != "${list_id#*_}" ] && continue
				perm_ipset="${list_id}_${geotag}"
				list_tag="${list_id}_${geotag}"
				printf '%s\n' "-A $geochain -m set --match-set $perm_ipset src $ipt_comm $list_tag -j $fw_target"
			done
		fi

		# whitelist block
		[ "$geomode" = whitelist ] && printf '%s\n' "-A $geochain $ipt_comm ${geotag}_whitelist_block -j DROP"

		echo "COMMIT"
		exit "$rv"
	)" || die_a "$FAIL assemble commands for iptables-restore"
	OK

	### "Apply new rules
	printf %s "Applying new $family firewall rules... "
	printf '%s\n' "$iptr_cmd_chain" | eval "$ipt_restore_cmd" || critical "$FAIL apply new iptables rules"
	OK

	[ -n "$ipsets_to_add" ] && {
		printf %s "Adding $family ipsets... "
		newifs "$_nl" apply
		for entry in ${ipsets_to_add%"$_nl"}; do
			ipset_type=net
			case "$entry" in "ip:"*|"net:"*) ipset_type="${entry%%":"*}"; entry="${entry#*":"}"; esac
			add_ipset "${entry%% *}" "${entry#* }" "$ipset_type"
			ipsets_to_rm="$ipsets_to_rm${entry%% *}_temp "
		done
		oldifs apply
		OK; echo
	}
done

[ -n "$ipsets_to_rm" ] && {
	printf %s "Removing old ipsets... "
	get_curr_ipsets
	sleep "0.1" 2>/dev/null || sleep 1
	for ipset in $ipsets_to_rm; do
		rm_ipset "$ipset"
	done
	[ "$retval" = 0 ] && OK
}


# insert the main blocking rule
case "$noblock" in
	'') enable_geoip ;;
	*) echolog -warn "Geoip blocking is disabled via config." >&2
esac

echo

return "$retval"
