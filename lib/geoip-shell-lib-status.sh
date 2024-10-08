#!/bin/sh
# shellcheck disable=SC2154,SC1090,SC2034

# geoip-shell-lib-status.sh

# reports current geoip-shell status

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

. "$_lib-$_fw_backend.sh" || die

#### FUNCTIONS

# Report protocols and ports
report_proto() {
	printf '\n%s\n' "Protocols:"
	for proto in tcp udp; do
		unset ports ports_act p_sel
		eval "ports_exp=\"\${${proto}_ports%:*}\" ports=\"\${${proto}_ports##*:}\""

		case "$ports_exp" in
			all) ports_act="${red}*Geoip inactive*"; ports='' ;;
			skip) ports="to ${green}all ports" ;;
			*"!dport"*) p_sel="${yellow}only to ports " ;;
			*) p_sel="to ${yellow}all ports except "
		esac

		[ "$p_sel" ] && [ ! "$ports" ] &&
			die "$FAIL get ports from the config, or the config is invalid. \$ports_exp: '$ports_exp', \$ports_act: '$ports_act', \$ports: '$ports'$n_c, \$p_sel: '$p_sel'."
		[ ! "$ports_act" ] && ports_act="Geoip is applied "
		printf '%s\n' "${blue}$proto${n_c}: $ports_act$p_sel$ports${n_c}"
	done
}

warn_persist() {
	echolog -warn "$_nl$1 Geoip${cr_p# and} $wont_work."
}

incr_issues() { issues=$((issues+1)); }


# Main

_Q="${red}?${n_c}"
issues=0

ipsets="$(get_ipsets)"

printf '\n%s\n\n%s\n' "${purple}$p_name status:${n_c}" "$p_name ${blue}v$curr_ver$n_c"

case "$_fw_backend" in
	ipt|nft) _fw="$blue${_fw_backend}ables$n_c" ;;
	*) _fw="${red}Not set $_X"; incr_issues
esac

printf '\n%s\n%s\n%s\n' "Firewall backend: $_fw" "Geoip blocking mode: ${blue}${geomode}${n_c}" "Ip lists source: ${blue}${geosource}${n_c}"

check_lists_coherence && lists_coherent=" $_V" || { incr_issues; lists_coherent=" $_Q"; }

# check ipsets and firewall rules for active ccodes
for list_id in $active_lists; do
	active_ccodes="$active_ccodes${list_id%_*} "
	active_families="$active_families${list_id#*_} "
done
san_str active_ccodes
san_str active_families
printf %s "Country codes in the $geomode: "
case "$active_ccodes" in
	'') printf '%s\n' "${red}None $_X"; incr_issues ;;
	*) printf '%s\n' "${blue}${active_ccodes}${n_c}${lists_coherent}"
esac
printf %s "IP families in firewall rules: "
case "$active_families" in
	'') printf '%s\n' "${red}None${n_c} $_X"; incr_issues ;;
	*) printf '%s\n' "${blue}${active_families}${n_c}${lists_coherent}"
esac

[ "$ifaces" ] && _ifaces_r="${blue}$ifaces$n_c" || { _ifaces_r="${red}Not set $_X"; incr_issues; }
printf '%s\n' "Geoip rules applied to network interfaces: $_ifaces_r"

for family in $families; do
	f="$family"
	[ "$_fw_backend" = nft ] && f="${f#ipv}"
	trusted_ips="$(print_ipset_elements "trusted_$f")"
	eval "trusted_$family=\"$trusted_ips\""
done

[ "$trusted_ipv4$trusted_ipv6" ] && {
	printf '\n%s\n' "Trusted ip's:"
	for f in $families; do
		eval "trusted=\"\$trusted_$f\""
		[ "$trusted" ] && printf '%s\n' "$f: ${blue}$trusted${n_c}"
	done
}

[ "$geomode" = whitelist ] && {
	for family in $families; do
		f="$family"
		[ "$_fw_backend" = nft ] && f="${f#ipv}"
		lan_ips="$(print_ipset_elements "lan_ips_$f")"
		eval "lan_ips_$family=\"$lan_ips\""
	done

	[ "$lan_ips_ipv4$lan_ips_ipv6" ] || [ "$ifaces" = all ] && {
		printf '\n%s\n' "Allowed LAN ip's:"

		for f in $families; do
			eval "lan_ips=\"\$lan_ips_$f\""
			[ "$lan_ips" ] && lan_ips="${blue}$lan_ips${n_c}" || lan_ips="${red}None${n_c}"
			[ "$lan_ips" ] || [ "$ifaces" = all ] && printf '%s\n' "$f: $lan_ips"
		done
		autodetect_hr=Off
		[ "$autodetect" ] && autodetect_hr=On
		printf '%s\n' "LAN subnets automatic detection: $blue$autodetect_hr$n_c"
	}
}

report_proto
echo
report_fw_state

[ "$verb_status" ] && {
	printf %s "Ip ranges count in active geoip sets: "
	case "$active_ccodes" in
		'') printf '%s\n' "${red}None $_X"; incr_issues ;;
		*) echo
			for ccode in $active_ccodes; do
				el_summary=''
				printf %s "${purple}${ccode}${n_c}: "
				for family in $families; do
					list_id="${ccode}_${family}"
					f="$family"
					[ "$_fw_backend" = nft ] && f="${family#ipv}"
					el_cnt="$(cnt_ipset_elements "${ccode}_${f}")"
					[ "$el_cnt" != 0 ] && list_empty='' || {
						case "$exclude_iplists" in
							*"$list_id"*) list_empty=" (excluded)" ;;
							*) list_empty=" $_X"; incr_issues
						esac
					}
					el_summary="$el_summary$family - $blue$el_cnt$n_c$list_empty, "
					total_el_cnt=$((total_el_cnt+el_cnt))
				done
				printf '%s\n' "${el_summary%, }"
			done
			printf '\n%s\n' "Total number of ip ranges: $blue$total_el_cnt$n_c"
	esac
}

unset cr_p
[ ! "$_OWRTFW" ] && cr_p=" and persistence across reboots"
wont_work="will likely not work" a_disabled="appears to be disabled"

# check if cron service is enabled
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
	check_owrt_init ||
		{ rv=1; printf '%s\n' "$_X"; warn_persist "procd init script for $p_name $a_disabled."; incr_issues; }

	check_owrt_include ||
		{ [ $rv = 0 ] && printf '%s\n' "$_X"; rv=1; warn_persist "Firewall include is not found."; incr_issues; }
	[ $rv = 0 ] && printf '%s\n' "$_V"
}

# check automatic backup
[ "$nobackup" = true ] && backup_st="${yellow}Off" || backup_st="${green}On"

printf '%s\n' "Automatic backup of ip lists: $backup_st$n_c"

case $issues in
	0) printf '\n%s\n\n' "${green}No problems detected.${n_c}" ;;
	*) printf '\n%s\n\n' "${red}Problems detected: $issues.${n_c}"
esac

[ "$issues" != 0 ] && [ -f "$lock_file" ] &&
	echo "NOTE: $lock_file lock file indicates that $p_name is doing something in the background. Wait a bit and check again."

return $issues
