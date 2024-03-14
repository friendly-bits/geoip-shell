#!/bin/sh
# shellcheck disable=SC2154,SC1090

# geoip-shell-status-ipt.sh

# iptables-specific library for report_status() in the -manage script

echo

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

	echo
	if [ "$verb_status" ]; then
		total_el_cnt=0
		printf '%s' "Ip ranges count in active geoip sets: "
		case "$active_ccodes" in
			'') printf '%s\n' "${red}None $_X"; incr_issues ;;
			*) echo
				ipsets="$(ipset list -t)"
				for ccode in $active_ccodes; do
					el_summary=''
					printf %s "${blue}${ccode}${n_c}: "
					for family in $families; do
						el_cnt="$(printf %s "$ipsets" |
							sed -n -e /"${ccode}_$family"/\{:1 -e n\;/maxelem/\{s/.*maxelem\ //\; -e s/\ .*//\; -e p\; -e q\; -e \}\;b1 -e \})"
						: "${el_cnt:=0}"
						[ "$el_cnt" != 0 ] && list_empty='' || { list_empty=" $_X"; incr_issues; }
						el_summary="$el_summary$family - $el_cnt$list_empty, "
						total_el_cnt=$((total_el_cnt+el_cnt))
					done
					printf '%s\n' "${el_summary%, }"
				done
		esac
		printf '\n%s\n\n\n' "Total number of ip ranges: $total_el_cnt"
	fi
}