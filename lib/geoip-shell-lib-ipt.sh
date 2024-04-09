#!/bin/sh
# shellcheck disable=SC2154,SC2034

# geoip-shell-lib-ipt.sh

# geoip-shell library for interacting with iptables

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


# $family needs to be set
set_ipt_cmds() {
	case "$family" in ipv4) f='' ;; ipv6) f=6 ;; *) echolog -err "set_ipt_cmds: Unexpected family '$family'."; return 1; esac
	ipt_cmd="ip${f}tables -t $ipt_table"; ipt_save_cmd="ip${f}tables-save -t $ipt_table"; ipt_restore_cmd="ip${f}tables-restore -n"
}

# 1 - string
# 2 - target
filter_ipt_rules() {
	grep "$1" | grep -o "$2.* \*/"
}

get_ipsets() {
	ipset list -t
}

# 1 - ipset tag
# expects $ipsets to be set
print_ipset_elements() {
	get_matching_line "$ipsets" "*" "$1" "*" ipset &&
		ipset list "${1}_$geotag" | sed -n -e /"Members:"/\{:1 -e n\; -e p\; -e b1\; -e \} | tr '\n' ' '
}

cnt_ipset_elements() {
	printf %s "$ipsets" |
		sed -n -e /"$1"/\{:1 -e n\;/maxelem/\{s/.*maxelem\ //\; -e s/\ .*//\; -e p\; -e q\; -e \}\;b1 -e \} |
			grep . || echo 0
}

# 1 - iptables tag
rm_ipt_rules() {
	printf %s "Removing $family iptables rules tagged '$1'... "
	set_ipt_cmds

	{ echo "*$ipt_table"; eval "$ipt_save_cmd" | sed -n "/$1/"'s/^-A /-D /p'; echo "COMMIT"; } |
		eval "$ipt_restore_cmd" ||
		{ FAIL; echolog -err "rm_ipt_rules: $FAIL remove firewall rules tagged '$1'."; return 1; }
	OK
}

rm_all_georules() {
	for family in ipv4 ipv6; do
		rm_ipt_rules "${geotag}_enable"
		ipt_state="$(eval "$ipt_save_cmd")"
		printf '%s\n' "$ipt_state" | grep "$iface_chain" >/dev/null && {
			printf %s "Removing $family chain '$iface_chain'... "
			printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $iface_chain" "-X $iface_chain" "COMMIT" |
				eval "$ipt_restore_cmd" && OK || { FAIL; return 1; }
		}
		printf '%s\n' "$ipt_state" | grep "$geochain" >/dev/null && {
			printf %s "Removing $family chain '$geochain'... "
			printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $geochain" "-X $geochain" "COMMIT" | eval "$ipt_restore_cmd" && OK ||
				{ FAIL; return 1; }
		}
	done
	# remove ipsets
	rm_ipsets_rv=0
	unisleep
	printf %s "Destroying ipsets tagged '$geotag'... "
	for ipset in $(ipset list -n | grep "$geotag"); do
		ipset destroy "$ipset" || rm_ipsets_rv=1
	done
	[ "$rm_ipsets_rv" = 0 ] && OK || FAIL
	return "$rm_ipsets_rv"
}

get_fwrules_iplists() {
	p="$p_name" t="$ipt_target"
	{ iptables-save -t "$ipt_table"; ip6tables-save -t "$ipt_table"; } |
		sed -n "/match-set .*$p.* -j $t/{s/.*match-set //;s/_$p.*//;p}" | grep -vE "(lan_ips_|trusted_)"
}

get_ipset_iplists() {
	get_ipsets | sed -n /"$geotag"/\{s/_"$geotag"//\;s/^Name:\ //\;p\} | grep -vE "(lan_ips_|trusted_)"
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

report_fw_state() {
	dashes="$(printf '%158s' ' ' | tr ' ' '-')"
	for family in $families; do
		set_ipt_cmds
		ipt_output="$($ipt_cmd -vL)" || die "$FAIL get $family iptables state."

		wl_rule="$(printf %s "$ipt_output" | filter_ipt_rules "${p_name}_whitelist_block" "DROP")"
		ipt_header="$dashes$_nl${blue}$(printf %s "$ipt_output" | grep -m1 "pkts.*destination")${n_c}$_nl$dashes"

		case "$(printf %s "$ipt_output" | filter_ipt_rules "${p_name}_enable" "$geochain")" in
			'') chain_status="disabled $_X"; incr_issues ;;
			*) chain_status="enabled $_V"
		esac
		printf '%s\n' "Geoip firewall chain ($family): $chain_status"
		[ "$geomode" = whitelist ] && {
			case "$wl_rule" in
				'') wl_rule=''; wl_rule_status="$_X"; incr_issues ;;
				*) wl_rule="$_nl$wl_rule"; wl_rule_status="$_V"
			esac
			printf '%s\n' "Whitelist blocking rule ($family): $wl_rule_status"
		}

		if [ "$verb_status" ]; then
			# report geoip rules
			printf '\n%s\n%s\n' "${purple}Firewall rules in the $geochain chain ($family)${n_c}:" "$ipt_header"
			printf %s "$ipt_output" | sed -n -e /"^Chain $geochain"/\{n\;:1 -e n\;/^Chain\ /q\;/^$/q\;p\;b1 -e \} |
				grep . || { printf '%s\n' "${red}None $_X"; incr_issues; }
			echo
		fi
	done
}

geoip_on() {
	[ "$ifaces" != all ] && first_chain="$iface_chain" || first_chain="$geochain"
	for family in $families; do
		set_ipt_cmds || die_a
		enable_rule="$(eval "$ipt_save_cmd" | grep "${geotag}_enable")"
		[ ! "$enable_rule" ] && {
			printf %s "Inserting the enable geoip $family rule... "
			eval "$ipt_cmd" -I PREROUTING -j "$first_chain" $ipt_comm "${geotag}_enable" || critical "$insert_failed"
			OK
		} || printf '%s\n' "Geoip is already on for $family."
	done
}

geoip_off() {
	for family in $families; do
		set_ipt_cmds || die
		enable_rule="$(eval "$ipt_save_cmd" | grep "${geotag}_enable")"
		if [ "$enable_rule" ]; then
			rm_ipt_rules "${geotag}_enable" || critical
		else
			printf '%s\n' "Geoip is already off for $family."
		fi
	done
}

apply_rules() {
	#### VARIABLES

	retval=0

	insert_failed="$FAIL insert a firewall rule."
	ipt_comm="-m comment --comment"

	ipsets_to_rm=

	#### MAIN

	### apply the 'on' and 'off' actions
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
		unisleep
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
				sp2nl lan_ips
			else
				a_d_failed=
				lan_ips="$(call_script "${i_script}-detect-lan.sh" -s -f "$family")" || a_d_failed=1
				[ ! "$lan_ips" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL detect $family LAN subnets."; exit 1; }
				lan_ips="net:$lan_ips"
				nl2sp "lan_ips_$family" "$lan_ips"
			fi

			ipset_type="${lan_ips%%":"*}"
			lan_ips="${lan_ips#*":"}"
			[ -n "$lan_ips" ] && {
				iplist_file="$iplist_dir/$lan_ipset.iplist"
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
				list_tag="${list_id}_${geotag}"
				mk_ipt_rm_cmd "$list_tag" || rv=1
			done


			## Create the geochain if it doesn't exist
			case "$curr_ipt" in *":$geochain "*) ;; *) printf '%s\n' ":$geochain -"; esac

			### Create new rules

			# interfaces
			if [ "$ifaces" != all ]; then
				case "$curr_ipt" in *":$iface_chain "*) ;; *) printf '%s\n' ":$iface_chain -"; esac
				for _iface in $ifaces; do
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

			# Allow link-local, DHCPv6
			[ "$geomode" = whitelist ] && [ "$ifaces" != all ] && {
				if [ "$family" = ipv6 ]; then
					printf '%s\n' "-I $geochain -s fc00::/6 -d fc00::/6 -p udp -m udp --dport 546 $ipt_comm ${geotag_aux}_DHCPv6 -j ACCEPT"
					printf '%s\n' "-I $geochain -s fe80::/8 $ipt_comm ${geotag_aux}_link-local -j ACCEPT"
				# leaving DHCP v4 allow disabled for now because it's unclear that it is needed
				# else
				# 	printf '%s\n' "-A $geochain -p udp -m udp --dport 68 $ipt_comm ${geotag_aux}_DHCP -j ACCEPT"
				fi
			}

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
			[ "$geomode" = whitelist ] && [ "$ifaces" = all ] &&
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
		unisleep
		for ipset in $ipsets_to_rm; do
			rm_ipset "$ipset"
		done
		[ "$retval" = 0 ] && OK
		echo
	}


	# insert the main blocking rule
	case "$noblock" in
		'') geoip_on ;;
		*) echolog -warn "Geoip blocking is disabled via config."
	esac

	[ "$autodetect" ] && setconfig lan_ips_ipv4 lan_ips_ipv6

	echo

	return "$retval"
}

# resets iptables policies and rules, destroys associated ipsets and then initiates restore from file
restorebackup() {
	# outputs the iptables portion of the backup file for $family
	get_iptables_bk() {
		sed -n -e /"\[${p_name}_IPTABLES_$family\]"/\{:1 -e n\;/\\["${p_name}_IP"/q\;p\;b1 -e \} < "$tmp_file"
	}
	# outputs the ipset portion of the backup file
	get_ipset_bk() { sed -n "/create .*${p_name}/,\$p" < "$tmp_file"; }

	printf '%s\n' "Restoring firewall state from backup... "

	bk_file="${bk_dir}/${p_name}_backup.${bk_ext:-bak}"
	[ -z "$bk_file" ] && die "Can not restore the firewall state: no backup found."
	[ ! -f "$bk_file" ] && die "Can not find the backup file '$bk_file'."

	# extract the backup archive into tmp_file
	tmp_file="/tmp/${p_name}_backup.tmp"
	$extract_cmd "$bk_file" > "$tmp_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
	[ ! -s "$tmp_file" ] && rstr_failed "backup file '$bk_file' is empty or backup extraction failed."

	printf '%s\n\n' "Successfully read backup file: '$bk_file'."

	printf %s "Checking the iptables portion of the backup file... "

	# count lines in the iptables portion of the backup file
	for family in $families; do
		line_cnt=$(get_iptables_bk | wc -l)
		debugprint "Firewall $family lines number in backup: $line_cnt"
		[ "$line_cnt" -lt 2 ] && rstr_failed "firewall $family backup appears to be empty or non-existing."
	done
	OK

	printf %s "Checking the ipset portion of the backup file... "
	# count lines in the ipset portion of the backup file
	get_ipset_bk | grep "add .*$p_name" 1>/dev/null || rstr_failed "ipset backup appears to be empty or non-existing."
	OK

	### Remove geoip iptables rules and ipsets
	rm_all_georules || rstr_failed "$FAIL remove firewall rules and ipsets."

	# ipset needs to be restored before iptables
	for restoretgt in ipset iptables; do
		printf %s "Restoring $restoretgt state... "
		case "$restoretgt" in
			ipset) get_ipset_bk | ipset restore; rv=$? ;;
			iptables)
				rv=0
				for family in $families; do
					set_ipt_cmds
					get_iptables_bk | $ipt_restore_cmd; rv=$((rv+$?))
				done ;;
		esac

		case "$rv" in
			0) OK ;;
			*) FAIL; rstr_failed "$FAIL restore $restoretgt state from backup." reset
		esac
	done

	rm_rstr_tmp

	cp_conf restore || rstr_failed
	:
}

rm_rstr_tmp() {
	rm -f "$tmp_file" 2>/dev/null
}

rstr_failed() {
	rm_rstr_tmp
	main_config=
	[ "$1" ] && echolog -err "$1"
	[ "$2" = reset ] && {
		echolog -err "*** Geoip blocking is not working. Removing geoip firewall rules. ***"
		rm_all_georules
	}
	die
}

rm_bk_tmp() {
	rm -f "$tmp_file" "${bk_file}.new" 2>/dev/null
}

bk_failed() {
	rm_bk_tmp
	die "$1"
}

# Saves current firewall state to a backup file
create_backup() {
	printf %s "Creating backup of current $p_name state... "

	bk_len=0
	for family in $families; do
		set_ipt_cmds
		printf '%s\n' "[${p_name}_IPTABLES_$family]" >> "$tmp_file" &&
		printf '%s\n' "*$ipt_table" >> "$tmp_file" &&
		$ipt_save_cmd | grep -i "$geotag" >> "$tmp_file" &&
		printf '%s\n' "COMMIT" >> "$tmp_file" || bk_failed "$FAIL back up $p_name state."
	done
	OK

	bk_len="$(wc -l < "$tmp_file")"
	printf '%s\n' "[${p_name}_IPSET]" >> "$tmp_file"

	for ipset in $(ipset list -n | grep $geotag); do
		printf %s "Creating backup of ipset '$ipset'... "

		# append current ipset content to tmp_file
		ipset save "$ipset" >> "$tmp_file"; rv=$?

		bk_len_old=$(( bk_len + 1 ))
		bk_len="$(wc -l < "$tmp_file")"
		[ "$rv" != 0 ] || [ "$bk_len" -le "$bk_len_old" ] && bk_failed "$FAIL back up ipset '$ipset'."
		OK
	done

	printf %s "Compressing backup... "
	bk_file="${bk_dir}/${p_name}_backup.${bk_ext:-bak}"
	$compr_cmd < "$tmp_file" > "${bk_file}.new" &&  [ -s "${bk_file}.new" ] ||
		bk_failed "$FAIL compress firewall backup to file '${bk_file}.new'."

	mv "${bk_file}.new" "$bk_file" || bk_failed "$FAIL overwrite file '$bk_file'."
	OK

	:
}

ipt_table=mangle
iface_chain="${geochain}_WAN"
