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


# checks current ipsets and iptables rules for geoip-shell
# returns a list of active ip lists
# (optional: 1 - '-f', irrelevant for iptables)
# 1 - var name for output
get_active_iplists() {
	[ "$1" = "-f" ] && shift
	case "$geomode" in
		whitelist) ipt_target="ACCEPT" ;;
		blacklist) ipt_target="DROP" ;;
		*) die "get_active_iplists: unexpected geoip mode '$geomode'."
	esac
	ipset_lists="$(ipset list -n | grep "$p_name" | sed -n /"$geotag"/s/_"$geotag"//p | grep -vE "(lan_ips_|trusted_)")"
	p="_${p_name}"; t="$ipt_target"
	iprules_lists="$( { iptables-save -t "$ipt_table"; ip6tables-save -t "$ipt_table"; } |
		sed -n "/match-set .*$p.* -j $t/{s/.*match-set //;s/$p.*//;p}" | grep -vE "(lan_ips_|trusted_)")"

	get_difference "$ipset_lists" "$iprules_lists" lists_difference
	get_intersection "$ipset_lists" "$iprules_lists" "$1"

	case "$lists_difference" in '') iplists_incoherent=''; return 0 ;; *) iplists_incoherent=1; return 1; esac
}

ipt_table=mangle
iface_chain="${geochain}_WAN"
