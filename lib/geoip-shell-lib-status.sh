#!/bin/sh
# shellcheck disable=SC2154,SC1090,SC2034

# geoip-shell-lib-status.sh

# reports current geoip-shell status

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

source_lib "$_fw_backend" || die

#### FUNCTIONS

# Report protocols and ports
# 1 - direction (inbound|outbound)
report_proto() {
	printf '\n%s\n' "  Protocols:"
	for proto in tcp udp; do
		unset ports ports_act p_sel
		eval "ports_exp=\"\${${1}_${proto}_ports%:*}\" ports=\"\${${1}_${proto}_ports##*:}\""

		case "$ports_exp" in
			all) ports_act="${red}*Geoblocking inactive*"; ports='' ;;
			skip) ports="${green}all destination ports" ;;
			*"!dport"*) p_sel="${yellow}only destination ports "; ports="${blue}$ports${n_c}" ;;
			*) p_sel="${yellow}all destination ports except "; ports="${blue}$ports${n_c}"
		esac

		[ "$p_sel" ] && [ ! "$ports" ] && {
			debugprint "\$ports_exp: '$ports_exp', \$ports_act: '$ports_act', \$ports: '$ports$n_c'."
			die "$FAIL get ports from the config, or the config is invalid."
		}
		[ ! "$ports_act" ] && ports_act="Geoblocking "
		printf '%s\n' "  $proto: $ports_act$p_sel$ports${n_c}"
	done
}

incr_issues() { issues=$((issues+1)); }


# Main
report_status() {
	_Q="${red}?${n_c}"
	issues=0

	printf '\n%s\n' "${purple}$p_name v$curr_ver status:${n_c}"

	case "$_fw_backend" in
		ipt|nft) _fw="$blue${_fw_backend}ables$n_c" ;;
		*) _fw="${red}Not set $_X"; incr_issues
	esac

	printf '\n%s\n%s\n' "Firewall backend: $_fw" "IP lists source: ${blue}${geosource}${n_c}"

	check_lists_coherence && lists_coherent=" $_V" || { incr_issues; lists_coherent=" $_Q"; }

	[ "$ifaces" ] && _ifaces_r="${blue}$ifaces$n_c" || { _ifaces_r="${red}Not set $_X"; incr_issues; }
	printf '%s\n' "Geoblocking rules applied to network interfaces: $_ifaces_r"

	blocking_disabled=
	[ "$inbound_geomode" = disable ] && [ "$outbound_geomode" = disable ] && blocking_disabled=1

	if [ "$_fw_backend" = nft ]; then
		[ ! "$nft_perf" ] && { nft_perf="${red}Not set $_X"; incr_issues; }
		printf '%s\n' "nftables sets optimization policy: ${blue}$nft_perf$n_c"
	fi

	is_whitelist_present && {
		autodetect_hr=Off
		[ "$autodetect" ] && autodetect_hr=On
		printf '%s\n' "LAN subnets automatic detection: $blue$autodetect_hr$n_c"
	}

	[ ! "$blocking_disabled" ] && {
		# check if cron service is enabled
		unset cr_p
		[ ! "$_OWRTFW" ] && cr_p=" and persistence across reboots"
		wont_work="will likely not work" a_disabled="appears to be disabled"

		if check_cron; then
			printf '\n%s\n' "Cron system service: $_V"

			# check cron jobs

			cron_jobs="$(crontab -u root -l 2>/dev/null)"

			# check for update cron job
			get_matching_line "$cron_jobs" "*" "${p_name}-update" "" update_job
			case "$update_job" in
				'') upd_job_status="$_X"; upd_schedule=''; incr_issues ;;
				*) upd_job_status="$_V"; upd_schedule="${update_job%%\/*}"
			esac
			printf '%s\n' "Update cron job: $upd_job_status"
			[ "$upd_schedule" ] && printf '%s\n' "Update schedule: '${blue}${upd_schedule% }${n_c}'"

			getstatus "$status_file"
			[ "$last_update" ] && last_update="$blue$last_update$n_c" || { last_update="${red}Unknown $_X"; incr_issues; }
			printf '%s\n' "Last successful update: $last_update"

			[ ! "$_OWRTFW" ] && {
				# check for persistence cron job
				get_matching_line "$cron_jobs" "*" "${p_name}-persistence" "" persist_job
				case "$persist_job" in
					'') persist_status="$_X"; incr_issues ;;
					*) persist_status="$_V"
				esac
				printf '%s\n' "Persistence cron job: $persist_status"
			}
		else
			printf '\n%s\n' "$WARN cron service $a_disabled. Automatic updates$cr_p $wont_work." >&2
			incr_issues
		fi

		[ "$_OWRTFW" ] && {
			rv=0
			printf %s "Persistence: "
			check_owrt_init || {
				printf '%s\n' "$_X"
				rv=1
				incr_issues
				echolog -warn "procd init script for $p_name $a_disabled."
			}

			check_owrt_include || {
				[ $rv = 0 ] && printf '%s\n' "$_X"
				rv=1
				incr_issues
				echolog -warn "Firewall include is not found."
			}
			if [ $rv = 0 ]; then
				printf '%s\n' "$_V"
			else
				echolog -warn "Geoblocking persistence across reboots and firewall restarts $wont_work."
			fi
		}
	}

	# check automatic backup
	[ "$nobackup" = true ] && backup_st="${yellow}Off" || backup_st="${green}On"

	printf '%s\n' "Automatic backup of IP lists: $backup_st$n_c"

	# compile lists of active country codes and local iplists
	unset local_iplists local_families all_active_ccodes
	for direction in inbound outbound; do
		# $${direction}_active_lists var populated in check_lists_coherence()
		set_dir_vars "$direction"
		[ "$geomode" = disable ] && continue
		eval "active_lists=\"\$${direction}_active_lists\""
		unset "${direction}_active_ccodes" "${direction}_active_families"
		for list_id in $active_lists; do
			case "$list_id" in
				allow_*|dhcp*) continue ;;
				local_*)
					add2list local_iplists "$list_id"
					add2list local_families "${list_id##*_}"
					add2list "${direction}_active_families" "${list_id##*_}"
					continue
			esac
			add2list "${direction}_active_ccodes" "${list_id%_*}"
			add2list all_active_ccodes "${list_id%_*}"
			add2list "${direction}_active_families" "${list_id##*_}"
		done
	done

	ipsets="$(get_ipsets)"

	if [ "$verb_mode" ]; then
		case "$_fw_backend" in
			nft) verb_ipsets="$ipsets" ;;
			ipt) verb_ipsets="$(get_ext_ipsets)"
		esac

		for ccode in $all_active_ccodes; do
			for family in $families; do
				list_id="${ccode}_${family}"
				f="${family#ipv}"
				el_cnt="$(cnt_ipset_elements "${ccode}_${f}" "$verb_ipsets")"
				: "${el_cnt:=0}"
				eval "${list_id}_el_cnt"='$el_cnt'
			done
		done

		for list_id in $local_iplists; do
			l="${list_id%_ipv*}"
			family="${list_id#"$l"}"
			f="${family#_ipv}"
			el_cnt="$(cnt_ipset_elements "${l}_${f}" "$verb_ipsets")"
			: "${el_cnt:=0}"
			eval "${list_id}_el_cnt"='$el_cnt'
		done
	fi

	if [ "$local_iplists" ]; then
		printf '\n%s' "${purple}Active local IP lists"
		if [ ! "$verb_mode" ]; then
			printf '%s\n' "${n_c}: ${blue}$local_iplists${n_c}"
		else
			printf '%s\n' " and respective elements counts${n_c}:"
			for list_id in $local_iplists; do
				eval "el_cnt=\"\${${list_id}_el_cnt}\""
				printf '%s\n' "  $list_id: ${blue}$el_cnt${n_c}"
			done
		fi
	fi

	for direction in inbound outbound; do
		printf '\n%s\n' "$purple$direction geoblocking:${n_c}"
		set_dir_vars "$direction"
		geomode_pr="${blue}${geomode}${n_c}"
		[ "$geomode" = disable ] && geomode_pr="${red}disable${n_c}"
		printf '%s\n' "  Mode: ${geomode_pr}"
		[ "$geomode" = disable ] && continue

		eval "active_ccodes=\"\${${direction}_active_ccodes}\" active_families=\"\${${direction}_active_families}\""

		printf %s "  Country codes: "
		case "$active_ccodes" in
			'') printf '%s\n' "${red}None $_X"; incr_issues ;;
			*) printf '%s\n' "${blue}${active_ccodes}${n_c}${lists_coherent}"
		esac

		printf %s "  IP families: "
		case "$active_families" in
			'') printf '%s\n' "${red}None${n_c} $_X"; incr_issues ;;
			*) printf '%s\n' "${blue}${active_families}${n_c}${lists_coherent}"
		esac

		for f in $families; do
			unset allow_ips no_allow_ips "allow_$f"
			case "$ipsets" in
				"allow_${f#ipv}"*|"${_nl}allow_${f#ipv}"*) allow_ipset_name="allow_${f#ipv}" ;;
				*"allow_${direction%bound}_${f#ipv}"*) allow_ipset_name="allow_${direction%bound}_${f#ipv}" ;;
				*) no_allow_ips=1
			esac
			[ "$_fw_backend" = ipt ] && allow_ipset_name="${geotag}_${allow_ipset_name}"
			[ ! "$no_allow_ips" ] && allow_ips="$(print_ipset_elements "$allow_ipset_name" "$ipsets" | tr '\n' ' ')"
			eval "allow_$f=\"${allow_ips% }\""
		done

		includes_server=
		[ "$direction" = outbound ] && {
			src_allow_ips_pr=
			for f in $families; do
				eval "src_ips_f=\"\${source_ips_$f}\""
				for rm_str in ip net; do
					src_ips_f="${src_ips_f#"${rm_str}:"}"
				done
				src_allow_ips_pr="${src_allow_ips_pr}${src_ips_f} "
			done
			san_str src_allow_ips_pr

			case "$source_ips_policy" in
				none) source_ips_policy_pr="${yellow}none${n_c}" ;;
				pause) source_ips_policy_pr="${blue}pause${n_c}${_nl}    Outbound geoblocking will be paused while fetching IP list updates." ;;
				'')
					case "$src_allow_ips_pr" in
						'') source_ips_policy_pr="${yellow}not set${n_c}" ;;
						*) source_ips_policy_pr="${blue}Allow specific IP addresses${n_c}${_nl}    IPs: ${blue}$src_allow_ips_pr${n_c}" ;;
					esac ;;
				*) source_ips_policy_pr="${red}${source_ips_policy} ${_X}${n_c} (invalid)"; incr_issues
			esac

			printf '%s\n' "  Policy for allowing automatic IP list updates: $source_ips_policy_pr"
			includes_server=", iplist server IPs"
		}

		printf '\n%s\n' "  Allowed IPs (includes link-local IPs, trusted IPs, LAN IPs${includes_server}):"
		for f in $families; do
			eval "allow_ips=\"\${allow_$f}\""
			[ "$allow_ips" ] && allow_ips="${blue}$allow_ips${n_c}" || allow_ips="${red}None${n_c}"
			[ "$allow_ips" ] || { [ "$geomode" = whitelist ] && [ "$ifaces" = all ]; } && printf '%s\n' "  $f: $allow_ips"
		done

		report_proto "$direction"
		printf '\n'

		report_fw_state "$direction"

		[ "$verb_mode" ] && {
			load_exclusions
			printf %s "  IP ranges count in active $direction geoblocking sets: "
			case "$active_ccodes" in
				'') printf '%s\n' "${red}None $_X"; incr_issues ;;
				*)
					echo
					dir_total_el_cnt=0
					for ccode in $active_ccodes; do
						el_summary=
						printf %s "  ${purple}${ccode}${n_c}: "
						for family in $families; do
							list_id="${ccode}_${family}"
							list_empty=
							eval "el_cnt=\"\${${list_id}_el_cnt}\""
							[ "$el_cnt" = 0 ] && {
								if is_included "$list_id" "$excl_file_lists"; then
									list_empty=" (excluded)"
								else
									list_empty=" $_X"
									incr_issues
								fi
							}
							el_summary="$el_summary$family - $blue$el_cnt$n_c$list_empty, "
							dir_total_el_cnt=$((dir_total_el_cnt+el_cnt))
						done
						printf '%s\n' "${el_summary%, }"
					done
					printf '\n%s\n' "  Total count of $direction geoblocking IP ranges: $blue$dir_total_el_cnt$n_c"
			esac
		}
	done

	case $issues in
		0) printf '\n%s\n\n' "${green}No problems detected.${n_c}" ;;
		*) printf '\n%s\n\n' "${red}Problems detected: $issues.${n_c}"
	esac

	[ "$issues" != 0 ] && [ -f "$lock_file" ] &&
		echo "NOTE: $lock_file lock file indicates that $p_name is doing something in the background. Wait a bit and check again."

	return $issues
}
