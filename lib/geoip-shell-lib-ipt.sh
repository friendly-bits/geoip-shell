#!/bin/sh
# shellcheck disable=SC2154,SC2034

# library for interacting with iptables

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

# 1 - iptables tag
rm_ipt_rules() {
	printf %s "Removing $family iptables rules tagged '$1'... "
	set_ipt_cmds || return 1

	{ echo "*$ipt_table"; $ipt_save_cmd -t "$ipt_table" | sed -n "/$1/"'s/^-A /-D /p'; echo "COMMIT"; } | $ipt_restore_cmd ||
		{ echo "Failed."; echolog -err "rm_ipt_rules: Error when removing firewall rules tagged '$1'." >&2; return 1; }
	echo "Ok."
}

rm_all_georules() {
	for family in ipv4 ipv6; do
		rm_ipt_rules "${geotag}_enable" || return 1
		ipt_state="$($ipt_save_cmd)"
		printf '%s\n' "$ipt_state" | grep "$iface_chain" >/dev/null && {
			printf %s "Removing $family chain '$iface_chain'... "
			printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $iface_chain" "-X $iface_chain" "COMMIT" |
				$ipt_restore_cmd && echo "Ok." || { echo "Failed."; return 1; }
		}
		printf '%s\n' "$ipt_state" | grep "$geochain" >/dev/null && {
			printf %s "Removing $family chain '$geochain'... "
			printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $geochain" "-X $geochain" "COMMIT" | $ipt_restore_cmd && echo "Ok." ||
				{ echo "Failed."; return 1; }
		}
	done
	# remove ipsets
	rm_ipsets_rv=0
	sleep "0.1" 2>/dev/null || sleep 1
	printf %s "Destroying ipsets tagged '$geotag'... "
	for ipset in $(ipset list -n | grep "$geotag"); do
		ipset destroy "$ipset" || rm_ipsets_rv=1
	done
	[ "$rm_ipsets_rv" = 0 ] && echo "Ok." || echo "Failed."
	return "$rm_ipsets_rv"
}


# checks current ipsets and iptables rules for geoip-shell
# returns a list of active ip lists
# (optional: 1 - '-f', irrelevant for iptables)
# 1 - var name for output
get_active_iplists() {
	[ "$1" = "-f" ] && shift
	case "$geomode" in
		whitelist) ipt_target="ACCEPT" ;;
		blacklist) ipt_target="DROP" ;;
		*) die "get_active_iplists: Error: unexpected geoip mode '$geomode'."
	esac
	ipset_lists="$(ipset list -n | grep "$p_name" | grep -v "_lan_" | sed -n /"$geotag"/s/"$geotag"_//p)"
	p="${p_name}_"; t="$ipt_target"
	iprules_lists="$( { iptables-save -t "$ipt_table"; ip6tables-save -t "$ipt_table"; } | grep -v "_lan_" |
		sed -n "/match-set $p.* -j $t/{s/.*$p//;s/ -j $t.*//p}")"

	get_difference "$ipset_lists" "$iprules_lists" lists_difference
	get_intersection "$ipset_lists" "$iprules_lists" "$1"

	case "$lists_difference" in '') iplists_incoherent=''; return 0 ;; *) iplists_incoherent="true"; return 1; esac
}

ipt_table="mangle"
iface_chain="${geochain}_WAN"
