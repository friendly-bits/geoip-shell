#!/bin/sh
# shellcheck disable=SC2154,SC1090,SC2086,SC2059

# geoip-shell-status-nft.sh

# nftables-specific library for report_status() in the -manage script


# Report protocols and ports
report_proto() {
	printf '\n%s\n' "Protocols:"
	for proto in tcp udp; do
		ports_act=''; p_sel=''
		eval "ports=\"\$${proto}_ports\""

		case "$ports" in
			*"meta l4proto"*) ports_act="${red}*Geoip inactive*"; ports='' ;;
			skip) ports="to ${green}all ports" ;;
			*"dport !="*) p_sel="${yellow}only to ports " ;;
			*) p_sel="to ${yellow}all ports except "
		esac
		case "$ports" in ''|*all*) ;; *) ports="'$(printf %s "$ports" | sed 's/.*dport [!= ]*//;s/{ //g;s/ }//g')'"; esac

		[ ! "$ports_act" ] && ports_act="Geoip is applied "
		printf '%s\n' "${blue}$proto${n_c}: $ports_act$p_sel$ports${n_c}"
	done
}

report_fw_state() {
	curr_geotable="$(nft_get_geotable)" ||
		{ printf '%s\n' "$ERR failed to read the firewall state or firewall table $geotable does not exist." >&2; incr_issues; }

	wl_rule="$(printf %s "$curr_geotable" | grep "drop comment \"${geotag}_whitelist_block\"")"

	is_geochain_on && chain_status="$_V" || { chain_status="$_X"; incr_issues; }
	printf '%s\n' "Geoip firewall chain enabled: $chain_status"
	[ "$list_type" = whitelist ] && {
		case "$wl_rule" in
			'') wl_rule_status="$_X"; incr_issues ;;
			*) wl_rule_status="$_V"
		esac
		printf '%s\n' "Whitelist blocking rule: $wl_rule_status"
	}

	if [ "$verb_status" ]; then
		dashes="$(printf '%158s' ' ' | tr ' ' '-')"
		# report geoip rules
		fmt_str="%-9s%-11s%-5s%-8s%-5s%-24s%-33s%s\n"
		printf "\n%s\n%s\n${fmt_str}%s\n" "${purple}Firewall rules in the $geochain chain${n_c}:" \
			"$dashes${blue}" packets bytes ipv verdict prot dports interfaces extra "$n_c$dashes"
		rules="$(nft_get_chain "$geochain" | sed 's/^[[:space:]]*//;s/ # handle.*//' | grep .)" ||
			printf '%s\n' "${red}None $_X"
		newifs "$_nl" rules
		for rule in $rules; do
			newifs ' "' wrds
			set -- $rule
			case "$families" in "ipv4 ipv6"|"ipv6 ipv4") dfam="both" ;; *) dfam="$families"; esac
			pkts='---'; bytes='---'; ipv="$dfam"; verd='---'; prot='all'; dports='all'; in='all'; line=''
			while [ -n "$1" ]; do
				case "$1" in
					iifname) shift; get_nft_list "$@"; in="$_res"; shift "$n" ;;
					ip) ipv="ipv4" ;;
					ip6) ipv="ipv6" ;;
					dport) shift; get_nft_list "$@"; dports="$_res"; shift "$n" ;;
					udp|tcp) prot="$1 " ;;
					packets) pkts=$(num2human $2); shift ;;
					bytes) bytes=$(num2human $2 bytes); shift ;;
					counter) ;;
					accept) verd="ACCEPT" ;;
					drop) verd="DROP  " ;;
					*) line="$line$1 "
				esac
				shift
			done
			printf "$fmt_str" "$pkts " "$bytes " "$ipv " "$verd " "$prot " "$dports " "$in " "${line% }"
		done
		oldifs rules

		printf '\n%s' "Ip ranges count in active geoip sets: "
		case "$active_ccodes" in
			'') printf '%s\n' "${red}None $_X" ;;
			*) printf '\n'
				ipsets="$(nft -t list sets inet | grep -o ".._ipv._.*_$geotag")"
				for ccode in $active_ccodes; do
					el_summary=''
					printf %s "${blue}${ccode}${n_c}: "
					for family in $active_families; do
						get_matching_line "$ipsets" "" "${ccode}_${family}" "*" ipset
						el_cnt=0
						[ -n "$ipset" ] && el_cnt="$(nft_cnt_elements "$ipset")"
						[ "$el_cnt" != 0 ] && list_empty='' || { list_empty=" $_X"; incr_issues; }
						el_summary="$el_summary$family - $el_cnt$list_empty, "
						total_el_cnt=$((total_el_cnt+el_cnt))
					done
					printf '%s\n' "${el_summary%, }"
				done
		esac
		printf '\n%s\n' "Total number of ip ranges: $total_el_cnt"
	fi
}