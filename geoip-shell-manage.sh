#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034,SC2059

# geoip-shell-manage.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
export geomode nolog=1 manmode=1

. "/usr/bin/${p_name}-geoinit.sh" || exit 1
. "$_lib-setup.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

#### USAGE

usage() {
cat <<EOF
v$curr_ver

Usage: $me <action> [-c <"country_codes">] [-s <"[expression]"|disable>]  [-p <portoptions>] [-i <"[ifaces]"|auto|all>]
$sp8$sp8$sp8    [-l <"[lan_ips]"|auto|none>] [-t <"[trusted_ips]"|none>] [-m <whitelist|blacklist>] [-u <ripe|ipdeny>]
$sp8$sp8$sp8    [-i <"ifaces"|auto|all>] [-l <"lan_ips"|auto|none>] [-t <"trusted_ips">] [-p <port_options>] [-v] [-f] [-d] [-h]

Provides interface to configure geoip blocking.

Actions:
  on|off      : enable or disable the geoip blocking chain  (via a rule in the base geoip chain)
  add|remove  : add or remove 2-letter country codes to/from geoip blocking rules
  apply       : change geoip blocking config. May be used with options: '-c', 'u', '-m', '-i', '-l', '-t', '-p'
  schedule    : change the cron schedule
  status      : check on the current status of geoip blocking
  reset       : reset geoip config and firewall geoip rules
  restore     : re-apply geoip blocking rules from the config
  showconfig  : print the contents of the config file

Options:

  -c 2-letter country codes to add or remove. If passing multiple country codes, use double quotes."

  -s $schedule_usage

Options for the 'apply' action:

  -c $ccodes_usage

  -u $sources_usage

  -m $geomode_usage

  -i $ifaces_usage

  -l $lan_ips_usage

  -t $trusted_ips_usage

  -p $ports_usage

  -v  : Verbose status output
  -f  : Force the action
  -d  : Debug
  -h  : This help

EOF
}


#### PARSE ARGUMENTS

# check for valid action
action="$1"
case "$action" in
	add|remove|status|schedule|restore|reset|on|off|apply|showconfig) ;;
	*) unknownact
esac

# process the rest of the args
shift 1
while getopts ":c:m:s:i:l:t:p:u:vfdh" opt; do
	case $opt in
		c) ccodes_arg=$OPTARG ;;
		m) geomode_arg=$OPTARG ;;
		s) cron_schedule=$OPTARG ;;
		i) ifaces_arg=$OPTARG ;;
		l) lan_ips_arg=$OPTARG ;;
		t) trusted_arg=$OPTARG ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		u) source_arg=$OPTARG ;;

		v) verb_status=1 ;;
		f) force_action=1 ;;
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

check_root
. "$_lib-$_fw_backend.sh" || die
. "$_lib-status-$_fw_backend.sh" || die
[ "$_OWRT_install" ] && { . "$_lib-owrt-common.sh" || exit 1; }

setdebug
debugentermsg


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

report_status() {
	warn_persist() {
		echolog -warn "$_nl$1 Geoip${cr_p# and} $wont_work."
	}

	incr_issues() { issues=$((issues+1)); }

	_Q="${red}?${n_c}"
	issues=0

	for entry in "Source ipsource" "Ifaces _ifaces" "tcp_ports tcp_ports" "udp_ports udp_ports"; do
		getconfig "${entry% *}" "${entry#* }"
	done

	ipsets="$(get_ipsets)"

	printf '\n%s\n\n%s\n' "${purple}Geoip blocking status report:${n_c}" "$p_name ${blue}v$curr_ver$n_c"

	printf '\n%s\n%s\n' "Geoip blocking mode: ${blue}${geomode}${n_c}" "Ip lists source: ${blue}${ipsource}${n_c}"

	check_lists_coherence && lists_coherent=" $_V" || { report_incoherence; incr_issues; lists_coherent=" $_Q"; }

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
	[ "$_ifaces" ] && _ifaces_r=": ${blue}$_ifaces$n_c" || _ifaces_all="${blue}all$n_c "
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
		[ "$lan_ips_ipv4$lan_ips_ipv6" ] || [ ! "$_ifaces" ] && {
			printf '\n%s\n' "Allowed LAN ip's:"
			for f in $families; do
				eval "lan_ips=\"\$lan_ips_$f\""
				[ "$lan_ips" ] && lan_ips="${blue}$lan_ips${n_c}" || lan_ips="${red}None${n_c}"
				[ "$lan_ips" ] || [ ! "$_ifaces" ] && printf '%s\n' "$f: $lan_ips"
			done
		}
	}

	report_proto
	echo
	report_fw_state

	[ "$verb_status" ] && {
		printf '\n%s' "Ip ranges count in active geoip sets: "
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
}

report_incoherence() {
	discr="Discrepancy detected between"
	printf '\n%s\n' "$WARN $discr the firewall state and the config file." >&2
	for opt in unexpected missing; do
		eval "[ \"\$${opt}_lists\" ] && printf '%s\n' \"$opt ip lists in the firewall: '\$${opt}_lists'\"" >&2
	done
	[ "$iplists_incoherent" ] && printf '%s\n' "$WARN $discr geoip ipsets and geoip firewall rules!" >&2
}

incoherence_detected() {
	report_incoherence

	printf '%s\n\n%s\n' "Re-apply the rules from the config file to fix this?" \
		"'Y' to re-apply the config rules. 'N' to exit the script. 'S' to show configured ip lists."

	while true; do
		printf %s "(Y/N/S) "
		read -r REPLY
		case "$REPLY" in
			[Yy] ) echo; restore_from_config; break ;;
			[Nn] ) die ;;
			[Ss] ) printf '\n\n\n%s\n' "$geomode ip lists in the config file: '$config_lists_str'" ;;
			* ) printf '\n%s\n' "Enter 'y/n/s'."
		esac
	done
}

# restore ccodes from the config file
# if that fails, restore from backup
restore_from_config() {
	check_reapply() {
		check_lists_coherence && { echolog "$restore_ok_msg"; return 0; }
		echolog -err "$FAIL apply $p_name config."
		report_incoherence
		return 1
	}

	restore_msg="Restoring $p_name from config... "
	restore_ok_msg="Successfully restored $p_name from config."
	[ "$restore_req" ] && {
		restore_msg="Applying new config... "
		restore_ok_msg="Successfully applied new config."
	}
	echolog "$restore_msg"
	case "$config_lists_str" in
		'') echolog -err "no ip lists registered in the config file." ;;
		*) call_script "$i_script-uninstall.sh" -l || return 1
			setconfig "Lists=$config_lists_str"
			call_script -l "$run_command" add -l "$config_lists_str"
			check_reapply && return 0
	esac

	# call the *backup script to initiate recovery from fault
	call_script -l "$i_script-backup.sh" restore && check_reapply && return 0

	die "$FAIL restore $p_name state from backup. If it's a bug then please report it."
}

# tries to prevent the user from locking themselves out
check_for_lockout() {
	# if we don't have user's country code, don't check for lockout
	[ ! "$user_ccode" ] && return 0
	tip_msg="Make sure you do not lock yourself out."
	u_ccode="country code '$user_ccode'"
	inlist="in the planned $geomode"
	trying="You are trying to"

	if [ "$in_install" ] || [ "$geomode_change" ]; then
		get_matching_line "$planned_lists" "" "$user_ccode" "_*" filtered_ccode
		case "$geomode" in
			whitelist) [ ! "$filtered_ccode" ] && lo_msg="Your $u_ccode is not included $inlist. $tip_msg" ;;
			blacklist) [ "$filtered_ccode" ] && lo_msg="Your $u_ccode is included $inlist. $tip_msg"
		esac
	else
		get_matching_line "$lists_to_change" "" "$user_ccode" "_*" filtered_ccode

		# if action is unrelated to user's country code, skip further checks
		[ ! "$filtered_ccode" ] && return 0

		case "$action" in
			add) [ "$geomode" = blacklist ] && lo_msg="$trying add your $u_ccode to the blacklist. $tip_msg" ;;
			remove) [ "$geomode" = whitelist ] && lo_msg="$trying remove your $u_ccode from the whitelist. $tip_msg"
		esac
	fi
	[ "$lo_msg" ] && {
		printf '\n%s\n\n%s\n' "$WARN $lo_msg" "Proceed?"
		pick_opt "y|n"
		case "$REPLY" in
			y|Y) printf '\n%s\n' "Proceeding..." ;;
			n|N)
				[ "$geomode_change" ] && geomode="$geomode_prev"
				[ ! "$in_install" ] && report_lists
				echo
				die 0 "Aborted action '$action' for ip lists '$lists_to_change_str'."
		esac
	}
	:
}

get_wrong_ccodes() {
	for list_id in $wrong_lists; do
		wrong_ccodes="$wrong_ccodes${list_id%_*} "
	done
	san_str -s wrong_ccodes
}


#### VARIABLES

for entry in "Geomode geomode" "Families families" "Lists config_lists_str" "UserCcode user_ccode"\
		"tcp_ports tcp_ports" "udp_ports udp_ports" "LanIps_ipv4 c_lan_ips_ipv4" \
		"LanIps_ipv6 c_lan_ips_ipv6" "Autodetect autodetect" "Trusted_ipv4 trusted_ipv4" \
		"Trusted_ipv6 trusted_ipv6" "Ifaces conf_ifaces" "Source source" ; do
	getconfig "${entry% *}" "${entry#* }"
done

case "$geomode" in whitelist|blacklist) ;; *) die "Unexpected geoip mode '$geomode'!"; esac

san_str -s ccodes_arg "$(toupper "$ccodes_arg")"

sp2nl config_lists "$config_lists_str"

action="$(tolower "$action")"

run_command="$i_script-run.sh"


#### CHECKS

# check that the config file exists
[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."

[ ! "$geomode" ] && die "\$geomode variable should not be empty! Something is wrong!"


## Check args for sanity

erract="action '$action'"
incompat="$erract is incompatible with option"

case "$action" in
	add|remove)
		# check for valid country codes
		[ ! "$ccodes_arg" ] && die "$erract requires to specify countries with '-c <country_codes>'!"
		bad_ccodes=
		for ccode in $ccodes_arg; do
			validate_ccode "$ccode"
			case $? in
				1) die "Internal error while trying to validate country codes." ;;
				2) bad_ccodes="$bad_ccodes$ccode "
			esac
		done
		[ "$bad_ccodes" ] && die "Invalid 2-letters country codes: '${bad_ccodes% }'." ;;
	schedule|status|restore|reset|on|off|showconfig) [ "$ccodes_arg" ] && die "$incompat '-c'."
esac

[ "$action" != apply ] && {
	[ "$geomode_arg" ] && die "$incompat '-m'."
	[ "$trusted_arg" ] && die "$incompat '-t'."
	[ "$ports_arg" ] && die "$incompat '-p'."
	[ "$lan_ips_arg" ] && die "$incompat '-l'."
	[ "$ifaces_arg" ] && die "$incompat '-i'."
	[ "$source_arg" ] && die "$incompat '-u'."
}
[ "$action" != schedule ] && [ "$cron_schedule" ] && die "$incompat '-s'."



#### MAIN

case "$action" in
	status) report_status; die 0 ;;
	showconfig) printf '\n%s\n\n' "Config in $conf_file:"; cat "$conf_file"; die 0 ;;
	schedule) [ ! "$cron_schedule" ] && die "Specify cron schedule for autoupdate or 'disable'."
		# communicate schedule to *cronsetup via config
		setconfig "CronSchedule=$cron_schedule"
		call_script "$i_script-cronsetup.sh" || die "$FAIL update cron jobs."
		die 0
esac

mk_lock
trap 'eval "$trap_args_unlock"' INT TERM HUP QUIT


case "$action" in
	on|off)
		case "$action" in
			on) [ ! "$config_lists" ] && die "No ip lists registered. Refusing to enable geoip blocking."
				setconfig "NoBlock=" ;;
			off) setconfig "NoBlock=1"
		esac
		call_script "$i_script-apply.sh" $action || die
		die 0 ;;
	reset) call_script "$i_script-uninstall.sh" -l; die $? ;;
	restore) restore_from_config; die $?
esac

check_lists_coherence || incoherence_detected

for ccode in $ccodes_arg; do
	for f in $families; do
		add2list lists_arg "${ccode}_$f" "$_nl"
	done
done

case "$action" in
	apply) unset restore_req geomode_change geomode_prev ifaces_change planned_lists_str
		[ "$geomode_arg" ] && [ "$geomode_arg" != "$geomode" ] && { geomode_change=1; geomode_prev="$geomode"; }
		[ "$ifaces_arg" ] && [ "${ifaces_arg%all}" != "$conf_ifaces" ] && ifaces_change=1
		: "${source_arg:="$source"}"
		: "${lists_arg:="$config_lists"}"
		nl2sp lists_arg_str "$lists_arg"
		[ "$geomode_change" ] || [ "$source_arg" != "$source" ] || { [ "$ifaces_change" ] && [ "$_fw_backend" = nft ]; } ||
			! get_difference "$config_lists" "$lists_arg" && restore_req=1
		get_prefs || die
		planned_lists_str="$lists_arg_str"
		lists_to_change_str="$planned_lists_str"
		config_lists_str="$planned_lists_str"
		sp2nl planned_lists "$planned_lists_str"
		[ "$geomode_change" ] && check_for_lockout

		setconfig "tcp_ports=$tcp_ports" "udp_ports=$udp_ports" "Source=$source" "LanIps_ipv4=$c_lan_ips_ipv4" \
			"LanIps_ipv6=$c_lan_ips_ipv6" "Autodetect=$autodetect" "Trusted_ipv4=$trusted_ipv4" \
			"Trusted_ipv6=$trusted_ipv6" "Ifaces=$conf_ifaces" "Geomode=$geomode" "Lists=$planned_lists_str"

		if [ ! "$restore_req" ]; then
			call_script "$i_script-apply.sh" "update"; rv_apply=$?
			[ $rv_apply != 0 ] || ! check_lists_coherence && { restore_from_config && rv_apply=254 || rv_apply=1; }
		else
			restore_from_config; rv_apply=$?
		fi
		die $rv_apply ;;
	add)
		san_str requested_lists "$config_lists$_nl$lists_arg"
#		debugprint "requested resulting lists: '$requested_lists'"

		if [ ! "$force_action" ]; then
			get_difference "$config_lists" "$requested_lists" lists_to_change
			get_intersection "$lists_arg" "$config_lists" wrong_lists

			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				printf '%s\n' "NOTE: country codes '$wrong_ccodes' have already been added to the $geomode." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		san_str planned_lists "$config_lists$_nl$lists_to_change"
#		debugprint "action: add, lists_to_change: '$lists_to_change'"
		;;

	remove)
#		debugprint "requested lists to remove: '$lists_arg'"
		if [ ! "$force_action" ]; then
			get_intersection "$config_lists" "$lists_arg" lists_to_change
			subtract_a_from_b "$config_lists" "$lists_arg" wrong_lists
			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				printf '%s\n' "NOTE: country codes '$wrong_ccodes' have not been added to the $geomode, so can not remove." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		# remove any entries found in lists_to_change from config_lists and assign to planned_lists
		subtract_a_from_b "$lists_to_change" "$config_lists" planned_lists
esac

if [ ! "$lists_to_change" ] && [ ! "$force_action" ]; then
	report_lists
	die 254 "Nothing to do, exiting."
fi

debugprint "planned lists after '$action': '$planned_lists'"

if [ ! "$planned_lists" ] && [ ! "$force_action" ] && [ "$geomode" = "whitelist" ]; then
	die "Planned whitelist is empty! Disallowing this to prevent accidental lockout of a remote server."
fi

nl2sp lists_to_change_str "$lists_to_change"

# try to prevent possible user lock-out
check_for_lockout

### Call the *run script

nl2sp planned_lists_str "$planned_lists"
debugprint "Writing new config to file: 'Lists=$planned_lists_str'"
setconfig "Lists=$planned_lists_str"

call_script -l "$run_command" "$action" -l "$lists_to_change_str"; rv=$?

# positive return code means apply failure or another permanent error, except for 254
case "$rv" in 0|254) ;; *)
	printf '%s\n' "Error performing action '$action' for lists '$lists_to_change_str'." >&2
	[ ! "$config_lists" ] && die "Can not restore previous ip lists because they are not found in the config file."
	# write previous config lists
	setconfig "Lists=$config_lists_str"
	restore_from_config
esac

get_active_iplists new_verified_lists
subtract_a_from_b "$new_verified_lists" "$planned_lists" failed_lists
if [ "$failed_lists" ]; then
	nl2sp failed_lists_str "$failed_lists"
	debugprint "planned_lists: '$planned_lists_str', new_verified_lists: '$new_verified_lists', failed_lists: '$failed_lists_str'."
	echolog -warn "failed to apply new $geomode rules for ip lists: $failed_lists_str."
	# if the error encountered during installation, exit with error to fail the installation
	[ "$in_install" ] && die
	get_difference "$lists_to_change" "$failed_lists" ok_lists
	[ ! "$ok_lists" ] && die "All actions failed."
fi

report_lists
[ ! "$in_install" ] && statustip

die 0
