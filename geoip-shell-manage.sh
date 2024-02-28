#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034,SC2059

# geoip-shell-manage.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${p_name}-common.sh" || exit 1
. "$script_dir/${p_name}-lib-$_fw_backend.sh" || exit 1
[ "$_OWRT_install" ] && { . "$script_dir/${p_name}-owrt-common.sh" || exit 1; }

export list_type nolog=1 manmode=1

check_root

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

#### USAGE

usage() {
cat <<EOF

Usage: $me <action> [-c <"country_codes">] [-s <"expression"|disable>]  [-p <portoptions>] [-v] [-f] [-d] [-h]

Provides interface to configure geoip blocking.

Actions:
  on|off      : enable or disable the geoip blocking chain  (via a rule in the base geoip chain)
  add|remove  : add or remove country codes (ISO 3166-1 alpha-2) to/from geoip blocking rules
  apply       : apply current config settings. If used with option '-p', allows to change ports geoblocking applies to.
  schedule    : change the cron schedule
  status      : check on the current status of geoip blocking
  reset       : reset geoip config and firewall geoip rules
  restore     : re-apply geoip blocking rules from the config
  showconfig  : print the contents of the config file

Options:
  -c <"country_codes">               : country codes (ISO 3166-1 alpha-2). if passing multiple country codes, use double quotes.
  -s <"expression"|disable>          : schedule expression for the periodic cron job implementing auto-updates of the ip lists,
                                           must be inside double quotes.
                                           default schedule is "15 4 * * *" (at 4:15 [am] every day)
                                       disable: skip creating the autoupdate cron job
  -p <[tcp:udp]:[allow|block]:ports> : For given protocol (tcp/udp), use "block" to only geoblock incoming traffic on specific ports,
                                          or use "allow" to geoblock all incoming traffic except on specific ports.
                                          Multiple '-p' options are allowed to specify both tcp and udp in one command.
                                          Only works with the 'apply' action.
                                          For examples, refer to NOTES.md.
  -v                                 : Verbose status output
  -f                                 : Force the action
  -d                                 : Debug
  -h                                 : This help

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
while getopts ":c:s:p:vfdh" opt; do
	case $opt in
		c) ccodes_arg=$OPTARG ;;
		s) cron_schedule=$OPTARG ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;

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
	warn_persist() {
		printf '\n%s\n' "$WARN $1 Geoip${cr_p# and} $wont_work." >&2
	}

	incr_issues() { issues=$((issues+1)); }

	_V="${green}✔${n_c}"
	_X="${red}✘${n_c}"
	_Q="${red}?${n_c}"
	issues=0

	for entry in "Source ipsource" "WAN_ifaces wan_ifaces" "tcp tcp_ports" "udp udp_ports" \
			"LanSubnets_ipv4 lan_subnets_ipv4" "LanSubnets_ipv6 lan_subnets_ipv6"; do
		getconfig "${entry% *}" "${entry#* }"
	done

	printf '\n%s\n' "${purple}Geoip blocking status report:${n_c}"

	printf '\n%s\n%s\n' "Geoip blocking mode: ${blue}${list_type}${n_c}" "Ip lists source: ${blue}${ipsource}${n_c}"

	check_lists_coherence && lists_coherent=" $_V" || { report_incoherence; incr_issues; lists_coherent=" $_Q"; }

	# check ipsets and firewall rules for active ccodes
	for list_id in $active_lists; do
		active_ccodes="$active_ccodes${list_id%_*} "
		active_families="$active_families${list_id#*_} "
	done
	san_str active_ccodes
	san_str active_families
	printf %s "Country codes in the $list_type: "
	case "$active_ccodes" in
		'') printf '%s\n' "${red}None $_X"; incr_issues ;;
		*) printf '%s\n' "${blue}${active_ccodes}${n_c}${lists_coherent}"
	esac
	printf %s "IP families in firewall rules: "
	case "$active_families" in
		'') printf '%s\n' "${red}None${n_c} $_X" ;;
		*) printf '%s\n' "${blue}${active_families}${n_c}${lists_coherent}"
	esac

	[ -n "$wan_ifaces" ] && wan_ifaces_r="${blue}$wan_ifaces$n_c" || wan_ifaces_r="${blue}All$n_c"
	printf '%s\n' "Geoip rules applied to network interfaces: $wan_ifaces_r"

	if [ "$list_type" = "whitelist" ] && [ -z "$wan_ifaces" ]; then
		printf '\n%s\n' "Whitelist exceptions for LAN subnets:"
		for family in $families; do
			eval "lan_subnets=\"\$lan_subnets_$family\""
			[ -n "$lan_subnets" ] && lan_subnets="${blue}$lan_subnets${n_c}"|| lan_subnets="${red}None${n_c}"
			printf '%s\n' "$family: $lan_subnets"
		done
	fi

	. "${p_name}-status-lib-$_fw_backend.sh" || die "Failed to check status for $_fw_backend."

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

		echolog -err "$FAIL re-apply previous $list_type lists." >&2
		report_incoherence
		return 1
	}

	echolog "Restoring lists '$config_lists_str' from the config file... "
	case "$config_lists_str" in
		'') echolog -err "$ERR no ip lists registered in the config file." ;;
		*) call_script "$script_dir/${p_name}-uninstall.sh" -l || return 1
			setconfig "Lists=$config_lists_str"
			call_script "$run_command" add -l "$config_lists_str"
			check_reapply && return 0
	esac

	# call the *backup script to initiate recovery from fault
	call_script "$install_dir/${p_name}-backup.sh" restore && check_reapply && return 0

	die "$FAIL restore $p_name state from backup. If it's a bug then please report it."
}

# tries to prevent the user from locking themselves out
check_for_lockout() {
	# if we don't have user's country code, don't check for lockout
	[ ! "$user_ccode" ] && return 0
	tip_msg="Make sure you do not lock yourself out."
	u_ccode="country code '$user_ccode'"
	inlist="in the planned $list_type"
	trying="You are trying to"

	if [ "$in_install" ]; then
		get_matching_line "$planned_lists" "" "$user_ccode" "_*" filtered_ccode
		case "$list_type" in
			whitelist)
				[ ! "$filtered_ccode" ] && lo_msg="Your $u_ccode is not included $inlist. $tip_msg"
				return 0 ;;
			blacklist)
				[ "$filtered_ccode" ] && lo_msg="Your $u_ccode is included $inlist. $tip_msg"
				return 0
		esac
	else
		get_matching_line "$lists_to_change" "" "$user_ccode" "_*" filtered_ccode

		# if action is unrelated to user's country code, skip further checks
		[ ! "$filtered_ccode" ] && return 0

		case "$action" in
			add) [ "$list_type" = blacklist ] && lo_msg="$trying add your $u_ccode to the blacklist. $tip_msg"; return 0 ;;
			remove) [ "$list_type" = whitelist ] && lo_msg="$trying remove your $u_ccode from the whitelist. $tip_msg"; return 0 ;;
			*) printf '\n%s\n' "$ERR Unexpected action '$action'." >&2; return 1
		esac
	fi
}

get_wrong_ccodes() {
	for list_id in $wrong_lists; do
		wrong_ccodes="$wrong_ccodes${list_id%_*} "
	done
	san_str wrong_ccodes
}


#### VARIABLES

for entry in "ListType list_type" "Families families" "Lists config_lists_str" "UserCcode user_ccode"; do
	getconfig "${entry% *}" "${entry#* }"
done

case "$list_type" in whitelist|blacklist) ;; *) die "$ERR Unexpected geoip mode '$list_type'!"; esac

san_str ccodes_arg "$(toupper "$ccodes_arg")"

sp2nl "$config_lists_str" config_lists

action="$(tolower "$action")"

run_command="$install_dir/${p_name}-run.sh"


#### CHECKS

# check that the config file exists
[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."

[ ! "$list_type" ] && die "\$list_type variable should not be empty! Something is wrong!"


## Check args for sanity

erract="$ERR action '$action'"
incompat="$erract is incompatible with option"

case "$action" in
	add|remove)
		# check for valid country codes
		[ ! "$ccodes_arg" ] && die "$erract requires to specify countries with '-c <country_codes>'!"
		rv=0
		for ccode in $ccodes_arg; do
			validate_ccode "$ccode"
			case $? in
				1)  die "Internal error while trying to validate country codes." ;;
				2)  bad_ccodes="$bad_ccodes$ccode "; rv=1
			esac
		done

		[ "$rv" != 0 ] && die "Invalid 2-letters country codes: '${bad_ccodes% }'." ;;
	schedule|status|restore|reset|on|off|apply|showconfig)
		[ "$ccodes_arg" ] && die "$incompat '-c'."
esac

[ "$action" != apply ] && [ "$ports_arg" ] && { usage; die "$incompat '-p'."; }
[ "$action" != schedule ] && [ "$cron_schedule" ] && { usage; die "$incompat '-s'."; }



#### MAIN

case "$action" in
	status) report_status; exit 0 ;;
	showconfig) printf '\n%s\n\n' "Geoip config in $conf_file:"; cat "$conf_file"; exit 0 ;;
	on|off)
		case "$action" in
			on) [ ! "$config_lists" ] && die "No ip lists registered. Refusing to enable geoip blocking."
				setconfig "NoBlock=" ;;
			off) setconfig "NoBlock=1"
		esac
		call_script "$script_dir/${p_name}-apply.sh" $action || exit 1
		exit 0 ;;
	reset) call_script "$script_dir/${p_name}-uninstall.sh" -l; exit $? ;;
	restore) restore_from_config; exit $? ;;
	schedule)
		[ ! "$cron_schedule" ] && { usage; die "Specify cron schedule for autoupdate or 'disable'."; }

		# communicate schedule to *cronsetup via config
		setconfig "CronSchedule=$cron_schedule"

		call_script "$install_dir/${p_name}-cronsetup.sh" || die "$ERR $FAIL update cron jobs."
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
	apply) lists_to_change="$config_lists"; planned_lists="$config_lists" ;;
	add)
		san_str requested_lists "$config_lists$_nl$lists_arg" "$_nl"
#		debugprint "requested resulting lists: '$requested_lists'"

		if [ ! "$force_action" ]; then
			get_difference "$config_lists" "$requested_lists" lists_to_change
			get_intersection "$lists_arg" "$config_lists" wrong_lists

			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				printf '%s\n' "NOTE: country codes '$wrong_ccodes' have already been added to the $list_type." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		san_str planned_lists "$config_lists$_nl$lists_to_change" "$_nl"
#		debugprint "action: add, lists_to_change: '$lists_to_change'"
		;;

	remove)
#		debugprint "requested lists to remove: '$lists_arg'"
		if [ ! "$force_action" ]; then
			get_intersection "$config_lists" "$lists_arg" lists_to_change
			subtract_a_from_b "$config_lists" "$lists_arg" wrong_lists
			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				printf '%s\n' "NOTE: country codes '$wrong_ccodes' have not been added to the $list_type, so can not remove." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		# remove any entries found in lists_to_change from config_lists and assign to planned_lists
		subtract_a_from_b "$lists_to_change" "$config_lists" planned_lists
esac

if [ ! "$lists_to_change" ] && [ "$action" != apply ] && [ ! "$force_action" ]; then
	report_lists
	die 254 "Nothing to do, exiting."
fi

debugprint "planned lists after '$action': '$planned_lists'"

if [ ! "$planned_lists" ] && [ ! "$force_action" ] && [ "$list_type" = "whitelist" ]; then
	die "Planned whitelist is empty! Disallowing this to prevent accidental lockout of a remote server."
fi

# try to prevent possible user lock-out
[ "$action" != apply ] && { check_for_lockout || die "Error in 'check_for_lockout' function."; }

nl2sp "$lists_to_change" lists_to_change_str

if [ "$lo_msg" ]; then
		printf '\n%s\n\n%s\n' "$WARN $lo_msg" "Proceed?"
		pick_opt "y|n"
		case "$REPLY" in
			y|Y) printf '\n%s\n' "Proceeding..." ;;
			n|N) [ ! "$in_install" ] && report_lists
				echo
				die "Aborted action '$action' for ip lists '$lists_to_change_str'."
		esac
fi

### Call the *run script

nl2sp "$planned_lists" planned_lists_str
debugprint "Writing new config to file: 'Lists=$planned_lists_str'"
setconfig "Lists=$planned_lists_str"

if [ "$action" = apply ]; then
	setports "${ports_arg%"$_nl"}" || die
	call_script "$script_dir/${p_name}-apply.sh" "update"; rv=$?
else
	call_script "$run_command" "$action" -l "$lists_to_change_str"; rv=$?
fi

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
	nl2sp "$failed_lists" failed_lists_str
	debugprint "planned_lists: '$planned_lists_str', new_verified_lists: '$new_verified_lists', failed_lists: '$failed_lists_str'."
	echolog -err "$WARN failed to apply new $list_type rules for ip lists: $failed_lists_str."
	# if the error encountered during installation, exit with error to fail the installation
	[ "$in_install" ] && die
	get_difference "$lists_to_change" "$failed_lists" ok_lists
	[ ! "$ok_lists" ] && die "All actions failed."
fi

report_lists
[ ! "$in_install" ] && statustip

:
