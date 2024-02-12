#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-manage.sh


#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/${proj_name}-nft.sh" || exit 1

export list_type nolog=1 manualmode=1

check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs

#### USAGE

usage() {
cat <<EOF

Usage: $me <action> [-c <"country_codes">] [-s <"expression"|disable>] [-v] [-f] [-d] [-h]

Provides interface to configure geoip blocking.

Actions:
    on|off      : enable or disable the geoip blocking chain  (via a rule in the base geoip chain)
    add|remove  : add or remove country codes (ISO 3166-1 alpha-2) to/from geoip blocking rules
    schedule    : change the cron schedule
    status      : check on the current status of geoip blocking
    reset       : reset geoip config and firewall geoip rules
    restore     : re-apply geoip blocking rules from the config

Options:
    -c <"country_codes">      : country codes (ISO 3166-1 alpha-2). if passing multiple country codes, use double quotes.
    -s <"expression"|disable> : schedule expression for the periodic cron job implementing auto-updates of the ip lists,
                                        must be inside double quotes.
                                        default schedule is "15 4 * * *" (at 4:15 [am] every day)
                                disable: skip creating the autoupdate cron job

    -v                        : Verbose status output
    -f                        : Force the action
    -d                        : Debug
    -h                        : This help

EOF
}


#### PARSE ARGUMENTS

# check for valid action
action="$1"
case "$action" in
	add|remove|status|schedule|restore|reset|on|off) ;;
	*) unknownact
esac

# process the rest of the arguments
shift 1
while getopts ":c:s:vfdh" opt; do
	case $opt in
		c) ccodes_arg=$OPTARG ;;
		s) cron_schedule=$OPTARG ;;
		v) verb_status=1 ;;
		f) force_action=1 ;;
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

echo

setdebug

debugentermsg


#### FUNCTIONS

report_status() {
	incr_issues() { issues=$((issues+1)); }

	V_sym="${green}✔${n_c}"
	X_sym="${red}✘${n_c}"
	Q_sym="${red}?${n_c}"
	issues=0

	for entry in "Source ipsource" "WAN_ifaces wan_ifaces" \
			"LanSubnets_ipv4 lan_subnets_ipv4" "LanSubnets_ipv6 lan_subnets_ipv6"; do
		getconfig "${entry% *}" "${entry#* }"
	done

	printf '\n%s\n' "${purple}Geoip blocking status report:${n_c}"

	printf '\n%s\n%s\n' "Geoip blocking mode: ${blue}${list_type}${n_c}" "Ip lists source: ${blue}${ipsource}${n_c}"

	check_lists_coherence && lists_coherent=" $V_sym" || { report_incoherence; incr_issues; lists_coherent=" $Q_sym"; }

	# check ipsets and firewall rules for active ccodes
	for list_id in $active_lists; do
		active_ccodes="$active_ccodes${list_id%_*} "
		active_families="$active_families${list_id#*_} "
	done
	sanitize_str active_ccodes
	sanitize_str active_families
	printf %s "Country codes in the $list_type: "
	case "$active_ccodes" in
		'') printf '%s\n' "${red}None $X_sym"; incr_issues ;;
		*) printf '%s\n' "${blue}${active_ccodes}${n_c}${lists_coherent}"
	esac
	printf %s "IP families in firewall rules: "
	case "$active_families" in
		'') printf '%s\n\n' "${red}None${n_c} $X_sym" ;;
		*) printf '%s\n\n' "${blue}${active_families}${n_c}${lists_coherent}"
	esac

	curr_geotable="$(nft_get_geotable)" ||
		{ echo "Error: failed to read the firewall state or firewall table $geotable does not exist." >&2; incr_issues; }

	wl_rule="$(printf %s "$curr_geotable" | grep "drop comment \"${geotag}_whitelist_block\"")"

	case "$(printf %s "$curr_geotable" | grep "jump $geochain comment \"${geotag}_enable\"")" in
		'') chain_status="$X_sym"; incr_issues ;;
		*) chain_status="$V_sym"
	esac
	printf '%s\n' "Geoip firewall chain enabled: $chain_status"
	[ "$list_type" = whitelist ] && {
		case "$wl_rule" in
			'') wl_rule=''; wl_rule_status="$X_sym"; incr_issues ;;
			*) wl_rule="$_nl$wl_rule"; wl_rule_status="$V_sym"
		esac
		printf '%s\n' "Whitelist blocking rule: $wl_rule_status"
	}

	if [ "$list_type" = "whitelist" ] && [ -z "$wan_ifaces" ]; then
		printf '\n%s\n' "Whitelist exceptions for LAN subnets:"
		for family in $families; do
			eval "lan_subnets=\"\$lan_subnets_$family\""
			[ -n "$lan_subnets" ] && lan_subnets="${blue}$lan_subnets${n_c}"|| lan_subnets="${red}None${n_c}"
			printf '%s\n' "$family: $lan_subnets"
		done
		printf '\n'
	fi

	[ -n "$wan_ifaces" ] && wan_ifaces="${blue}$wan_ifaces$n_c" || wan_ifaces="${blue}All$n_c"
	printf '%s\n' "Geoip rules applied to network interfaces: $wan_ifaces"

	if [ "$verb_status" ]; then
		# report geoip rules
		printf '%s\n' "${purple}Firewall rules in the $geochain chain${n_c}:"
		nft_get_chain "$geochain" | sed 's/^[[:space:]]*//;s/ # handle.*//' | grep . || printf '%s\n' "${red}None $X_sym"

		printf '\n%s' "Ip ranges count in active geoip sets: "
		case "$active_ccodes" in
			'') printf '%s\n' "${red}None $X_sym" ;;
			*) printf '\n'
				ipsets="$(nft -t list sets inet | grep -o ".._ipv._.*_$geotag")"
				for ccode in $active_ccodes; do
					el_summary=''
					printf %s "${blue}${ccode}${n_c}: "
					for family in $active_families; do
						get_matching_line "$ipsets" "" "${ccode}_${family}" "*" ipset
						el_cnt=0
						[ -n "$ipset" ] && el_cnt="$(nft_cnt_elements "$ipset")"
						[ "$el_cnt" != 0 ] && list_empty='' || { list_empty=" $X_sym"; incr_issues; }
						el_summary="$el_summary$family - $el_cnt$list_empty, "
						total_el_cnt=$((total_el_cnt+el_cnt))
					done
					printf '%s\n' "${el_summary%, }"
				done
		esac
		printf '\n%s\n\n' "Total number of ip ranges: $total_el_cnt"

	fi

	# check if cron service is enabled
	if check_cron; then
		printf '%s\n' "Cron system service: $V_sym"

		# check cron jobs

		cron_jobs="$(crontab -u root -l 2>/dev/null)"

		# check for persistence cron job
		get_matching_line "$cron_jobs" "*" "${proj_name}-persistence" "" persist_job
		case "$persist_job" in
			'') persist_job_status="$X_sym"; incr_issues ;;
			*) persist_job_status="$V_sym"
		esac
		printf '%s\n' "Persistence cron job: $persist_job_status"

		# check for autoupdate cron job
		get_matching_line "$cron_jobs" "*" "${proj_name}-autoupdate" "" update_job
		case "$update_job" in
			'') update_job_status="$X_sym"; upd_schedule=''; incr_issues ;;
			*) update_job_status="$V_sym"; upd_schedule="${update_job%%\"*}"
		esac
		printf '%s\n' "Autoupdate cron job: $update_job_status"
		[ "$upd_schedule" ] && printf '%s\n\n' "Autoupdate schedule: '${blue}${upd_schedule% }${n_c}'"
	else
		printf '\n%s\n' "${yellow}WARNING${n_c}: cron service appears to be disabled. Persistence across reboots and autoupdates will likely not work." >&2
		incr_issues
	fi
	case $issues in
		0) printf '%s\n\n' "${green}No problems detected.${n_c}" ;;
		*) printf '\n%s\n\n' "${red}Problems detected: $issues.${n_c}"
	esac
}

report_incoherence() {
	printf '\n%s\n' "${red}Warning${n_c}: Discrepancy detected between the firewall state and the config file." >&2
	for opt in unexpected missing; do
		eval "[ \"\$${opt}_lists\" ] && printf '%s\n' \"$opt $list_type ip lists in the firewall: '\$${opt}_lists'\"" >&2
	done
	[ "$iplists_incoherent" ] && printf '%s\n' "${red}Warning${n_c}: Discrepancy detected between geoip ipsets and geoip firewall rules!" >&2
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
			[Nn] ) exit 1 ;;
			[Ss] ) printf '\n\n\n%s\n' "$list_type ip lists in the config file: '$config_lists_str'" ;;
			* ) printf '\n%s\n' "Enter 'y/n/s'."
		esac
	done
}

# restore ccodes from the config file
# if that fails, restore from backup
restore_from_config() {
	check_reapply() {
		check_lists_coherence && { echolog "Successfully re-applied previous $list_type ip lists."; return 0; }

		echolog -err "Failed to re-apply previous $list_type lists." >&2
		report_incoherence
		return 1
	}

	echolog "Restoring lists '$config_lists_str' from the config file... "
	case "$config_lists_str" in
		'') echolog -err "Error: no ip lists registered in the config file." ;;
		*) call_script "$script_dir/${proj_name}-uninstall.sh" -l || return 1
			setconfig "Lists=$config_lists_str"
			call_script "$run_command" add -l "$config_lists_str"
			check_reapply && return 0
	esac

	# call the *backup script to initiate recovery from fault
	call_script "$install_dir/${proj_name}-backup.sh" restore && check_reapply && return 0

	die "Failed to restore the firewall state from backup. If it's a bug then please report it."
}

# tries to prevent the user from locking themselves out
check_for_lockout() {
	# if we don't have user's country code, don't check for lockout
	[ ! "$user_ccode" ] && return 0
	tip_msg="Make sure you do not lock yourself out."
	u_ccode="country code '$user_ccode'"

	if [ "$in_install" ]; then
		get_matching_line "$planned_lists" "" "$user_ccode" "_*" filtered_ccode
		case "$list_type" in
			whitelist)
				[ ! "$filtered_ccode" ] && lockout_msg="Your $u_ccode is not included in the planned whitelist. $tip_msg"
				return 0 ;;
			blacklist)
				[ "$filtered_ccode" ] && lockout_msg="Your $u_ccode is included in the planned blacklist. $tip_msg"
				return 0
		esac
	else
		get_matching_line "$lists_to_change" "" "$user_ccode" "_*" filtered_ccode

		# if action is unrelated to user's country code, skip further checks
		[ ! "$filtered_ccode" ] && return 0

		case "$action" in
			add)
				[ "$list_type" = blacklist ] && lockout_msg="You are trying to add your $u_ccode to the blacklist. $tip_msg"
				return 0 ;;
			remove)
				[ "$list_type" = whitelist ] && lockout_msg="You are trying to remove your $u_ccode from the whitelist. $tip_msg"
				return 0 ;;
			*) printf '\n%s\n' "Error: Unexpected action '$action'." >&2; return 1
		esac
	fi
}

get_wrong_ccodes() {
	for list_id in $wrong_lists; do
		wrong_ccodes="$wrong_ccodes${list_id%_*} "
	done
	sanitize_str wrong_ccodes
}


#### VARIABLES

for entry in "ListType list_type" "Families families" "Lists config_lists_str" "UserCcode user_ccode"; do
	getconfig "${entry% *}" "${entry#* }"
done

case "$list_type" in whitelist|blacklist) ;; *) die "Error: Unexpected geoip mode '$list_type'!"; esac

sanitize_str ccodes_arg "$(toupper "$ccodes_arg")"

sp2nl "$config_lists_str" config_lists

action="$(tolower "$action")"

run_command="$install_dir/${proj_name}-run.sh"


#### CHECKS

# check that the config file exists
[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."

[ ! "$list_type" ] && die "\$list_type variable should not be empty! Something is wrong!"


## Check arguments for sanity
case "$action" in
	add|remove)
		# check for valid country codes
		[ ! "$ccodes_arg" ] && die "Error: action '$action' requires to specify countries with '-c <country_codes>'!"
		rv=0
		for ccode in $ccodes_arg; do
			validate_ccode "$ccode"
			case $? in
				1)  die "Internal error while trying to validate country codes." ;;
				2)  bad_ccodes="$bad_ccodes$ccode "; rv=1
			esac
		done

		[ "$rv" != 0 ] && die "Invalid 2-letters country codes: '${bad_ccodes% }'."
		;;
	schedule|status|restore|reset|on|off) [ "$ccodes_arg" ] && die "Error: action '$action' is incompatible with option '-c'."
esac

[ "$action" != "schedule" ] && [ "$cron_schedule" ] && {
	usage
	die "Action '$action' is incompatible with option '-s'."
}


#### MAIN

case "$action" in
	status) report_status; exit 0 ;;
	on|off)
		case "$action" in
			on) [ ! "$config_lists" ] && die "No ip lists registered. Refusing to enable geoip blocking."
				setconfig "NoBlock=" ;;
			off) setconfig "NoBlock=1"
		esac
		call_script "$script_dir/${proj_name}-apply.sh" $action || exit 1
		exit 0 ;;
	reset) call_script "$script_dir/${proj_name}-uninstall.sh" -l; exit $? ;;
	restore) restore_from_config; exit $? ;;
	schedule)
		[ ! "$cron_schedule" ] && { usage; die "Specify cron schedule for autoupdate or 'disable'."; }

		# communicate schedule to *cronsetup via config
		setconfig "CronSchedule=$cron_schedule"

		call_script "$install_dir/${proj_name}-cronsetup.sh" || die "Error: Failed to update cron jobs."
		exit 0
esac

check_lists_coherence || incoherence_detected

for ccode in $ccodes_arg; do
	for family in $families; do
		lists_arg="${lists_arg}${ccode}_${family}${_nl}"
	done
done
lists_arg="${lists_arg%"${_nl}"}"

case "$action" in
	add)
		sanitize_str requested_lists "$config_lists$_nl$lists_arg" "$_nl"
#		debugprint "requested resulting lists: '$requested_lists'"

		if [ ! "$force_action" ]; then
			get_difference "$config_lists" "$requested_lists" lists_to_change
			get_intersection "$lists_arg" "$config_lists" wrong_lists

			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				echo "NOTE: country codes '$wrong_ccodes' have already been added to the $list_type." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		sanitize_str planned_lists "$config_lists$_nl$lists_to_change" "$_nl"
#		debugprint "action: add, lists_to_change: '$lists_to_change'"
		;;

	remove)
#		debugprint "requested lists to remove: '$lists_arg'"
		if [ ! "$force_action" ]; then
			get_intersection "$config_lists" "$lists_arg" lists_to_change
			subtract_a_from_b "$config_lists" "$lists_arg" wrong_lists
			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				echo "NOTE: country codes '$wrong_ccodes' have not been added to the $list_type, so can not remove." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		# remove any entries found in lists_to_change from config_lists and assign to planned_lists
		subtract_a_from_b "$lists_to_change" "$config_lists" planned_lists
esac

if [ ! "$lists_to_change" ] && [ ! "$force_action" ]; then
	printf '\n%s\n' "Lists in the final $list_type: '${blue}$config_lists_str${n_c}'."
	die 254 "Nothing to do, exiting."
fi

debugprint "planned lists after '$action': '$planned_lists'"

if [ ! "$planned_lists" ] && [ ! "$force_action" ] && [ "$list_type" = "whitelist" ]; then
	die "Planned whitelist is empty! Disallowing this to prevent accidental lockout of a remote server."
fi

# try to prevent possible user lock-out
check_for_lockout || die "Error in 'check_for_lockout' function."

nl2sp "$lists_to_change" lists_to_change_str

if [ "$lockout_msg" ]; then
		printf '\n%s\n\n%s\n' "${red}Warning${n_c}: $lockout_msg" "Proceed?"
		pick_opt "y|n"
		case "$REPLY" in
			y|Y) printf '\n%s\n' "Proceeding..." ;;
			n|N) [ ! "$in_install" ] && printf '\n%s\n' "Ip lists in the final $list_type: '${blue}$config_lists_str${n_c}'."
				echo
				die "Aborted action '$action' for ip lists '$lists_to_change_str'."
		esac
fi

### Call the *run script

nl2sp "$planned_lists" planned_lists_str
debugprint "Writing new config to file: 'Lists=$planned_lists_str'"
setconfig "Lists=$planned_lists_str"

call_script "$run_command" "$action" -l "$lists_to_change_str"; rv=$?

# positive return code means apply failure or another permanent error, except for 254
case "$rv" in 0|254) ;; *)
	echo "Error performing action '$action' for lists '$lists_to_change_str'." >&2
	[ ! "$config_lists" ] && die "Can not restore previous ip lists because they are not found in the config file."
	# write previous config lists
	setconfig "Lists=$config_lists_str"
	restore_from_config
esac

get_active_iplists new_verified_lists
subtract_a_from_b "$new_verified_lists" "$planned_lists" failed_lists
if [ "$failed_lists" ]; then
	nl2sp "$failed_lists" failed_lists_str
	debugprint "planned_lists: '$planned_lists_str', new_verified_lists: '$new_verified_lists', failed_lists: '$failed_lists_str'."
	echolog -err "Warning: failed to apply new $list_type rules for ip lists: $failed_lists_str."
	# if the error encountered during installation, exit with error to fail the installation
	[ "$in_install" ] && die
	get_difference "$lists_to_change" "$failed_lists" ok_lists
	[ ! "$ok_lists" ] && die "All actions failed."
fi

printf '\n%s\n\n' "Ip lists in the final $list_type: '${blue}$planned_lists_str${n_c}'."
[ ! "$in_install" ] && printf '%s\n\n' "View geoip blocking status with '${blue}${proj_name} status${n_c}' (may require 'sudo')."

exit 0
