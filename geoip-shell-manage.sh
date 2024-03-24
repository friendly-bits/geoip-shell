#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034,SC2059

# geoip-shell-manage.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
export geomode nolog=1 manmode=1

. "/usr/bin/${p_name}-geoinit.sh" &&
script_dir="$install_dir" &&
. "$_lib-setup.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

#### USAGE

usage() {
cat <<EOF
v$curr_ver

Usage: $me <action> [-c <"country_codes">] [-s $sch_syn] [-i $if_syn] [-m $mode_syn]
${sp8}[-u <ripe|ipdeny>] [-l $lan_syn] [-t $tr_syn] [-i $if_syn] [-p $ports_syn]
${sp8}[-v] [-f] [-d] [-h]

Provides interface to configure geoip blocking.

Actions:
  on|off      : enable or disable the geoip blocking chain  (via a rule in the base geoip chain)
  add|remove  : add or remove 2-letter country codes to/from geoip blocking rules
  apply       : change geoip blocking config. May be used with options: '-c', '-u', '-m', '-i', '-l', '-t', '-p'
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
		u) geosource_arg=$OPTARG ;;

		v) verb_status="-v" ;;
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
[ "$_OWRT_install" ] && { . "$_lib-owrt-common.sh" || exit 1; }

setdebug
debugentermsg


#### FUNCTIONS

incoherence_detected() {
	printf '%s\n\n%s\n' "Re-apply the rules from the config file to fix this?" \
		"'Y' to re-apply the config rules. 'N' to exit the script. 'S' to show configured ip lists."

	while true; do
		printf %s "(Y/N/S) "
		read -r REPLY
		case "$REPLY" in
			[Yy] ) echo; restore_from_config; break ;;
			[Nn] ) die ;;
			[Ss] ) printf '\n\n\n%s\n' "$geomode ip lists in the config file: '$config_lists'" ;;
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
	case "$config_lists" in
		'') echolog -err "No ip lists registered in the config file." ;;
		*) call_script "$i_script-uninstall.sh" -l || return 1
			setconfig config_lists
			call_script -l "$run_command" add -l "$config_lists"
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
				[ "$lists_change" ] && config_lists="$config_lists_prev"
				[ ! "$in_install" ] && report_lists
				echo
				die 0 "Aborted action '$action'."
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

get_config_vars

case "$geomode" in whitelist|blacklist) ;; *) die "Unexpected geoip mode '$geomode'!"; esac

toupper ccodes_arg
san_str -s ccodes_arg
sp2nl config_lists_nl "$config_lists"

tolower action

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
	[ "$geosource_arg" ] && die "$incompat '-u'."
}
[ "$action" != schedule ] && [ "$cron_schedule" ] && die "$incompat '-s'."



#### MAIN

case "$action" in
	status) . "$_lib-status.sh"; die $? ;;
	showconfig) printf '\n%s\n\n' "Config in $conf_file:"; cat "$conf_file"; die 0 ;;
	schedule) [ ! "$cron_schedule" ] && die "Specify cron schedule for autoupdate or 'disable'."
		# communicate schedule to *cronsetup via config
		setconfig cron_schedule
		call_script "$i_script-cronsetup.sh" || die "$FAIL update cron jobs."
		die 0
esac

mk_lock
trap 'eval "$trap_args_unlock"' INT TERM HUP QUIT


case "$action" in
	on|off)
		case "$action" in
			on) [ ! "$config_lists_nl" ] && die "No ip lists registered. Refusing to enable geoip blocking."
				setconfig "noblock=" ;;
			off) setconfig "noblock=1"
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
	apply) unset restore_req geomode_prev config_lists_prev planned_lists_str \
			geomode_change geosource_change ifaces_change lists_change

		config_lists_prev="$config_lists"
		geomode_prev="$geomode"

		[ "$geomode_arg" ] && [ "$geomode_arg" != "$geomode" ] && geomode_change=1
		[ "$geosource_arg" ] && [ "$geosource_arg" != "$geosource" ] && geosource_change=1
		[ "$ifaces_arg" ] && [ "${ifaces_arg%all}" != "$conf_ifaces" ] && ifaces_change=1
		: "${geosource_arg:="$geosource"}"

		get_prefs || die

		[ ! "$lists_arg" ] && for ccode in $ccodes; do
			for f in $families; do
				add2list lists_arg "${ccode}_$f" "$_nl"
			done
		done
		: "${lists_arg:="$config_lists_nl"}"
		! get_difference "$config_lists_nl" "$lists_arg" && lists_change=1

		nl2sp lists_arg_str "$lists_arg"
		planned_lists="$lists_arg"
		planned_lists_str="$lists_arg_str"
		lists_to_change_str="$lists_arg_str"
		config_lists="$lists_arg_str"

		[ "$geomode_change" ] || [ "$geosource_change" ] || { [ "$ifaces_change" ] && [ "$_fw_backend" = nft ]; } ||
			[ "$lists_change" ] && restore_req=1

		[ "$geomode_change" ] || [ "$lists_change" ] && check_for_lockout

		setconfig tcp_ports udp_ports geosource lan_ips_ipv4 lan_ips_ipv6 autodetect trusted_ipv4 trusted_ipv6 \
			conf_ifaces geomode config_lists

		if [ ! "$restore_req" ]; then
			call_script "$i_script-apply.sh" "update"; rv_apply=$?
			[ $rv_apply != 0 ] || ! check_lists_coherence && { restore_from_config && rv_apply=254 || rv_apply=1; }
		else
			restore_from_config; rv_apply=$?
		fi
		die $rv_apply ;;
	add)
		san_str requested_lists "$config_lists_nl$_nl$lists_arg"
#		debugprint "requested resulting lists: '$requested_lists'"

		if [ ! "$force_action" ]; then
			get_difference "$config_lists_nl" "$requested_lists" lists_to_change
			get_intersection "$lists_arg" "$config_lists_nl" wrong_lists

			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				printf '%s\n' "NOTE: country codes '$wrong_ccodes' have already been added to the $geomode." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		san_str planned_lists "$config_lists_nl$_nl$lists_to_change"
#		debugprint "action: add, lists_to_change: '$lists_to_change'"
		;;

	remove)
#		debugprint "requested lists to remove: '$lists_arg'"
		if [ ! "$force_action" ]; then
			get_intersection "$config_lists_nl" "$lists_arg" lists_to_change
			subtract_a_from_b "$config_lists_nl" "$lists_arg" wrong_lists
			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				printf '%s\n' "NOTE: country codes '$wrong_ccodes' have not been added to the $geomode, so can not remove." >&2
			}
		else
			lists_to_change="$lists_arg"
		fi
		# remove any entries found in lists_to_change from config_lists_nl and assign to planned_lists
		subtract_a_from_b "$lists_to_change" "$config_lists_nl" planned_lists
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
debugprint "Writing new config to file: 'config_lists=$planned_lists_str'"
setconfig "config_lists=$planned_lists_str"

call_script -l "$run_command" "$action" -l "$lists_to_change_str"; rv=$?

# positive return code means apply failure or another permanent error, except for 254
case "$rv" in 0|254) ;; *)
	echolog -err "$FAIL perform action '$action' for lists '$lists_to_change_str'."
	[ ! "$config_lists_nl" ] && die "Can not restore previous ip lists because they are not found in the config file."
	# write previous config lists
	setconfig config_lists
	restore_from_config
esac

get_active_iplists new_verified_lists
subtract_a_from_b "$new_verified_lists" "$planned_lists" failed_lists
if [ "$failed_lists" ]; then
	nl2sp failed_lists_str "$failed_lists"
	debugprint "planned_lists: '$planned_lists_str', new_verified_lists: '$new_verified_lists', failed_lists: '$failed_lists_str'."
	echolog -warn "$FAIL apply new $geomode rules for ip lists: $failed_lists_str."
	# if the error encountered during installation, exit with error to fail the installation
	[ "$in_install" ] && die
	get_difference "$lists_to_change" "$failed_lists" ok_lists
	[ ! "$ok_lists" ] && die "All actions failed."
fi

[ ! "$in_install" ] && { report_lists; statustip; }

die 0
