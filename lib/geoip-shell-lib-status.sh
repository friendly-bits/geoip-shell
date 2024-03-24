#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034,SC2059

# geoip-shell-lib-status.sh

# reports current geoip-shell status. should be sourced from other scripts.

# Copyright: friendly bits
# github.com/friendly-bits

. "$_lib-$_fw_backend.sh" &&
. "$_lib-status-$_fw_backend.sh" || die
[ "$_OWRT_install" ] && { . "$_lib-owrt-common.sh" || exit 1; }

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

printf '\n%s\n%s\n' "Geoip blocking mode: ${blue}${geomode}${n_c}" "Ip lists source: ${blue}${geosource}${n_c}"

check_lists_coherence && lists_coherent=" $_V" || { incr_issues; lists_coherent=" $_Q"; }

# check ipsets and firewall rules for active ccodes
for list_id in $active_lists; do
	active_ccodes="$active_ccodes${list_id%_*} "
	active_families="$active_families${list_id#*_} "
done
san_str -s active_ccodes
san_str -s active_families
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

unset _ifaces_r _ifaces_all
[ "$conf_ifaces" ] && _ifaces_r=": ${blue}$conf_ifaces$n_c" || _ifaces_all="${blue}all$n_c "
printf '%s\n' "Geoip rules applied to ${_ifaces_all}network interfaces$_ifaces_r"

trusted_ipv4="$(print_ipset_elements trusted_ipv4)"
trusted_ipv6="$(print_ipset_elements trusted_ipv6)"
[ "$trusted_ipv4$trusted_ipv6" ] && {
	printf '\n%s\n' "Allowed trusted ip's:"
	for f in $families; do
		eval "trusted=\"\$trusted_$f\""
		[ "$trusted" ] && printf '%s\n' "$f: ${blue}$trusted${n_c}"
	done
}

[ "$geomode" = "whitelist" ] && {
	lan_ips_ipv4="$(print_ipset_elements lan_ips_ipv4)"
	lan_ips_ipv6="$(print_ipset_elements lan_ips_ipv6)"
	[ "$lan_ips_ipv4$lan_ips_ipv6" ] || [ ! "$conf_ifaces" ] && {
		printf '\n%s\n' "Allowed LAN ip's:"
		for f in $families; do
			eval "lan_ips=\"\$lan_ips_$f\""
			[ "$lan_ips" ] && lan_ips="${blue}$lan_ips${n_c}" || lan_ips="${red}None${n_c}"
			[ "$lan_ips" ] || [ ! "$conf_ifaces" ] && printf '%s\n' "$f: $lan_ips"
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
				printf %s "${blue}${ccode}${n_c}: "
				for family in $active_families; do
					el_cnt="$(cnt_ipset_elements "${ccode}_${family}")"
					[ "$el_cnt" != 0 ] && list_empty='' || { list_empty=" $_X"; incr_issues; }
					el_summary="$el_summary$family - $el_cnt$list_empty, "
					total_el_cnt=$((total_el_cnt+el_cnt))
				done
				printf '%s\n' "${el_summary%, }"
			done
	esac
	printf '\n%s\n' "Total number of ip ranges: $total_el_cnt"
}

unset cr_p
[ ! "$_OWRTFW" ] && cr_p=" and persistence across reboots"
wont_work="will likely not work" a_disabled="appears to be disabled"

# check if cron service is enabled
if check_cron; then
	printf '\n%s\n' "Cron system service: $_V"

	# check cron jobs

	cron_jobs="$(crontab -u root -l 2>/dev/null)"

	# check for autoupdate cron job
	get_matching_line "$cron_jobs" "*" "${p_name}-autoupdate" "" update_job
	case "$update_job" in
		'') upd_job_status="$_X"; upd_schedule=''; incr_issues ;;
		*) upd_job_status="$_V"; upd_schedule="${update_job%%\"*}"
	esac
	printf '%s\n' "Autoupdate cron job: $upd_job_status"
	[ "$upd_schedule" ] && printf '%s\n' "Autoupdate schedule: '${blue}${upd_schedule% }${n_c}'"

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
	printf '\n%s\n' "$WARN cron service $a_disabled. Autoupdates$cr_p $wont_work." >&2
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

case $issues in
	0) printf '\n%s\n\n' "${green}No problems detected.${n_c}" ;;
	*) printf '\n%s\n\n' "${red}Problems detected: $issues.${n_c}"
esac