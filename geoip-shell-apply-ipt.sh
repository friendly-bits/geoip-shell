#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-apply-ipt.sh

# iptables-specific library for the -apply script

# Copyright: friendly bits
# github.com/friendly-bits

. "$script_dir/${p_name}-ipt.sh" || exit 1


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
	for tmp_ipset in $(ipset list -n | grep "$proj_name" | grep "temp"); do
		ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null
	done
}

enable_geoip() {
	[ -n "$wan_ifaces" ] && first_chain="$iface_chain" || first_chain="$geochain"
	for family in $families; do
		set_ipt_cmds || die_a
		enable_rule="$($ipt_save_cmd | grep "${geotag}_enable")"
		[ ! "$enable_rule" ] && {
			printf %s "Inserting the enable geoip $family rule... "
			$ipt_cmd -I PREROUTING -j "$first_chain" $ipt_comm "${geotag}_enable" || critical "$insert_failed"
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
	perm_ipset="$1"; tmp_ipset="${1}_temp"; iplist_file="$2"
	[ ! -f "$iplist_file" ] && critical "$ERR Can not find the iplist file in path: '$iplist_file'."

	ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null

	# count ips in the iplist file
	ip_cnt=$(wc -w < "$iplist_file")
#	debugprint "ip count in the iplist file '$iplist_file': $ip_cnt"

	# set hashsize to 1024 or (ip_cnt / 2), whichever is larger
	ipset_hs=$((ip_cnt / 2))
	[ $ipset_hs -lt 1024 ] && ipset_hs=1024
	debugprint "hashsize for ipset $list_id: $ipset_hs"

	debugprint "Creating ipset '$tmp_ipset'... "
	ipset create "$tmp_ipset" hash:net family "$family" hashsize "$ipset_hs" maxelem "$ip_cnt" ||
		crtical "$FAIL create ipset '$tmp_ipset'."
	debugprint "Ok."

	debugprint "Importing iplist '$iplist_file' into temporary ipset... "
	# read $iplist_file, transform each line into 'add' command and pipe the result into "ipset restore"
	sed "s/^/add \"$tmp_ipset\" /" "$iplist_file" | ipset restore -exist ||
		critical "$FAIL import the iplist from '$iplist_file' into ipset '$tmp_ipset'."
	debugprint "Ok."

	[ "$debugmode" ] && debugprint "Subnets in the temporary ipset: $(ipset save "$tmp_ipset" | grep -c "add $tmp_ipset")"

	# swap the temp ipset with the permanent ipset
	debugprint "Making the ipset '$perm_ipset' permanent... "
	ipset swap "$tmp_ipset" "$perm_ipset" || critical "$FAIL swap temporary and permanent ipsets."
	debugprint "Ok."
	rm "$iplist_file"
}

mk_perm_ipset() {
	perm_ipset="$1"; tmp_ipset="${perm_ipset}_temp"
	# create new permanent ipset if it doesn't exist
	case "$curr_ipsets" in *"$perm_ipset"* ) ;; *)
		debugprint "Creating permanent ipset '$perm_ipset'... "
		ipset create "$perm_ipset" hash:net family "$family" hashsize 1 maxelem 1 ||
			die_a "$FAIL create ipset '$perm_ipset'."
		debugprint "Ok."
	esac
}

get_curr_ipsets() {
	curr_ipsets="$(ipset list -n | grep "$proj_name")"
}


#### VARIABLES

case "$list_type" in
	whitelist) fw_target="ACCEPT" ;;
	blacklist) fw_target="DROP" ;;
	*) die "Unknown firewall mode '$list_type'."
esac

exitvalue=0

insert_failed="$FAIL insert a firewall rule."
ipt_comm="-m comment --comment"

ipsets_to_rm=''
get_curr_ipsets

#### MAIN

### apply the 'on' and 'off' actions
case "$action" in
	off)
		for family in $families; do
			set_ipt_cmds || die
			enable_rule="$($ipt_save_cmd | grep "${geotag}_enable")"
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

for family in $families; do
	ipsets_to_add=''

	### make perm ipsets, assemble $ipsets_to_add and $ipsets_to_rm
	for list_id in $list_ids; do
		case "$list_id" in *_*) ;; *) die_a "Invalid iplist id '$list_id'."; esac
		[ "${list_id#*_}" != "$family" ] && continue
		perm_ipset="${proj_name}_${list_id}"
		if [ "$action" = "add" ]; then
			iplist_file="${iplist_dir}/${list_id}.iplist"
			mk_perm_ipset "$perm_ipset"
			ipsets_to_add="$ipsets_to_add$perm_ipset $iplist_file$_nl"
		elif [ "$action" = "remove" ]; then
			ipsets_to_rm="$ipsets_to_rm$perm_ipset "
		fi
	done

	### local networks
	if [ "$list_type" = "whitelist" ] && [ ! "$wan_ifaces" ]; then
		if [ ! "$autodetect" ]; then
			eval "lan_subnets=\"\$lan_subnets_$family\""
		else
			lan_subnets="$(sh "$script_dir/detect-local-subnets-AIO.sh" -s -f "$family")" || a_d_failed=1
			[ ! "$lan_subnets" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL autodetect $family local subnets."; exit 1; }
			setconfig "LanSubnets_$family" "$lan_subnets"
		fi

		[ -n "$lan_subnets" ] && {
			lan_ipset="${geotag}_lan_$family"
			iplist_file="$iplist_dir/$lan_ipset.iplist"
			sp2nl "$lan_subnets" lan_subnets
			printf '%s\n' "$lan_subnets" > "$iplist_file" || die_a "$FAIL write to file '$iplist_file'"
			mk_perm_ipset "$lan_ipset"
			ipsets_to_add="$ipsets_to_add$lan_ipset $iplist_file$_nl"
		}
	fi

	#### Assemble commands for iptables-restore
	printf %s "Assembling new $family firewall rules... "
	### Read current iptables rules
	set_ipt_cmds || die_a
	curr_ipt="$($ipt_save_cmd)" || die_a "$FAIL read iptables rules."

	iptr_cmd_chain="$(
		rv=0

		printf '%s\n' "*$ipt_table"

		### Remove existing geoip rules

		## Remove the main blocking rule, the whitelist blocking rule and the auxiliary rules
		mk_ipt_rm_cmd "${geotag}_enable" "${geotag_aux}" "${geotag}_whitelist_block" "${geotag}_iface_filter" || rv=1

		## Remove rules for $list_ids
		for list_id in $list_ids; do
			[ "$family" != "${list_id#*_}" ] && continue
			list_tag="${proj_name}_${list_id}"
			mk_ipt_rm_cmd "$list_tag" || rv=1
		done


		## Create the geochain if it doesn't exist
		case "$curr_ipt" in *":$geochain "*) ;; *) printf '%s\n' ":$geochain -"; esac

		### Create new rules

		if [ -n "$wan_ifaces" ]; then # apply geoip to wan ifaces
			case "$curr_ipt" in *":$iface_chain "*) ;; *) printf '%s\n' ":$iface_chain -"; esac
			for wan_iface in $wan_ifaces; do
				printf '%s\n' "-i $wan_iface -I $iface_chain -j $geochain $ipt_comm ${geotag}_iface_filter"
			done
		fi

		## Auxiliary rules

		# local networks
		if [ "$list_type" = "whitelist" ] && [ ! "$wan_ifaces" ]; then
			printf '%s\n' "-I $geochain -m set --match-set ${geotag}_lan_$family src $ipt_comm ${geotag_aux}_lan_$family -j ACCEPT"
		fi

		# ports
		for proto in tcp udp; do
			eval "dport=\"\$${proto}_ports\""
			[ "$dport" = skip ] && continue
			printf '%s\n' "-I $geochain -p $proto $dport -j ACCEPT $ipt_comm ${geotag_aux}_ports"
		done

		# established/related
		printf '%s\n' "-I $geochain -m conntrack --ctstate RELATED,ESTABLISHED $ipt_comm ${geotag_aux}_rel-est -j ACCEPT"

		# lo interface
		[ "$list_type" = "whitelist" ] && [ ! "$wan_ifaces" ] && \
			printf '%s\n' "-I $geochain -i lo $ipt_comm ${geotag_aux}-lo -j ACCEPT"

		## iplist-specific rules
		if [ "$action" = "add" ]; then
			for list_id in $list_ids; do
				[ "$family" != "${list_id#*_}" ] && continue
				perm_ipset="${geotag}_${list_id}"
				list_tag="${geotag}_${list_id}"
				printf '%s\n' "-A $geochain -m set --match-set $perm_ipset src $ipt_comm $list_tag -j $fw_target"
			done
		fi

		# whitelist block
		[ "$list_type" = "whitelist" ] && printf '%s\n' "-A $geochain $ipt_comm ${geotag}_whitelist_block -j DROP"

		echo "COMMIT"
		exit "$rv"
	)" || die_a "$ERR $FAIL assemble commands for iptables-restore"
	OK

	### "Apply new rules
	printf %s "Applying new $family firewall rules... "
	printf '%s\n' "$iptr_cmd_chain" | $ipt_restore_cmd || critical "$FAIL apply new iptables rules"
	OK

	[ -n "$ipsets_to_add" ] && {
		printf %s "Adding $family ipsets... "
		newifs "$_nl" apply
		for entry in ${ipsets_to_add%"$_nl"}; do
			add_ipset "${entry%% *}" "${entry#* }"
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
		case "$curr_ipsets" in
			*"$ipset"* )
				debugprint "Destroying ipset '$ipset'... "
				ipset destroy "$ipset"; rv=$?
				case "$rv" in
					0) debugprint "Ok." ;;
					*) echo "Failed."; echolog -err "$WARN $FAIL destroy ipset '$ipset'."; exitvalue="254"
				esac
				;;
			*) echo "Failed."; echolog -err "$WARN Can't remove ipset '$ipset' because it doesn't exist."; exitvalue="254"
		esac
	done
	[ "$exitvalue" = 0 ] && OK
}


# insert the main blocking rule
case "$noblock" in
	'') enable_geoip ;;
	*) echolog -err "WARNING: Geoip blocking is disabled via config." >&2
esac

echo

exit "$exitvalue"
