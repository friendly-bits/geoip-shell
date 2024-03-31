#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090,SC2034

# geoip-shell-manage.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
export geomode nolog=1 manmode=1

. "/usr/bin/${p_name}-geoinit.sh" &&
script_dir="$install_dir" &&
. "$_lib-setup.sh" &&
. "$_lib-uninstall.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

#### USAGE

usage() {

cat <<EOF
Usage: $me <action> [-c <"country_codes">] [-s $sch_syn] [-i $if_syn] [-m $mode_syn] [-u <ripe|ipdeny>]
${sp8}[-l $lan_syn] [-t $tr_syn] [-i $if_syn] [-p $ports_syn] [-o <true|false>] [-a <"path">]
${sp8}[-v] [-f] [-d] [-V] [-h]

Provides interface to configure geoip blocking.

Actions:
  on|off      : enable or disable the geoip blocking chain  (via a rule in the base geoip chain)
  add|remove  : add or remove 2-letter country codes to/from geoip blocking rules
  configure   : change $p_name config. May be used with options: '-c', '-u', '-m', '-i', '-l', '-t', '-p', '-o', '-a', '-s'
  status      : check on the current status of geoip blocking
  reset       : reset geoip config and firewall geoip rules
  restore     : re-apply geoip blocking rules from the config
  showconfig  : print the contents of the config file

Options for the add|remove actions:

  -c <"country_codes"> : 2-letter country codes to add or remove. If passing multiple country codes, use double quotes.

Options for the 'configure' action:

  -c $ccodes_usage

  -u $sources_usage

  -m $geomode_usage

  -i $ifaces_usage

  -l $lan_ips_usage

  -t $trusted_ips_usage

  -p $ports_usage

  -o $nobackup_usage

  -a $datadir_usage

  -s $schedule_usage

Other options:

  -v  : Verbose status output
  -f  : Force the action
  -d  : Debug
  -V  : Version
  -h  : This help

EOF
}


#### PARSE ARGUMENTS

# check for valid action
action="$1"
case "$action" in
	add|remove|configure|status|restore|reset|on|off|showconfig) shift ;;
	*) unknownact
esac

# process the rest of the args
while getopts ":c:m:s:i:l:t:p:u:a:o:vfdVh" opt; do
	case $opt in
		c) ccodes_arg=$OPTARG ;;
		m) geomode_arg=$OPTARG ;;
		s) schedule_arg=$OPTARG ;;
		i) ifaces_arg=$OPTARG ;;
		l) lan_ips_arg=$OPTARG ;;
		t) trusted_arg=$OPTARG ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		u) geosource_arg=$OPTARG ;;
		a) datadir_arg="$OPTARG" ;;
		o) nobackup_arg=$OPTARG ;;

		v) verb_status="-v" ;;
		f) force_action=1 ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

is_root_ok
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
			[Ss] ) printf '\n\n\n%s\n' "$geomode ip lists in the config file: '$iplists'" ;;
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
		restore_msg="Applying config... "
		restore_ok_msg="Successfully applied config."
	}
	echolog "$restore_msg"
	case "$iplists" in
		'') echolog -err "No ip lists registered in the config file." ;;
		*) rm_iplists_rules || return 1
			setconfig iplists
			call_script -l "$run_command" add -l "$iplists"
			check_reapply && return 0
	esac

	# call the *backup script to initiate recovery from fault
	call_script -l "$i_script-backup.sh" restore && check_reapply && return 0

	die "$FAIL restore $p_name state from backup. If it's a bug then please report it."
}

# tries to prevent the user from locking themselves out
check_for_lockout() {
	# if we don't have user's country code, don't check for lockout
	[ "$user_ccode" = none ] && return 0
	tip_msg="Make sure you do not lock yourself out."
	u_ccode="country code '$user_ccode'"
	inlist="in the planned $geomode"
	trying="You are trying to"

	sp2nl planned_lists_nl "$planned_lists"
	sp2nl lists_to_change_nl "$lists_to_change"

	if [ "$in_install" ] || [ "$geomode_change" ] || [ "$lists_change" ]; then
		get_matching_line "$planned_lists_nl" "" "$user_ccode" "_*" filtered_ccode
		case "$geomode" in
			whitelist) [ ! "$filtered_ccode" ] && lo_msg="Your $u_ccode is not included $inlist. $tip_msg" ;;
			blacklist) [ "$filtered_ccode" ] && lo_msg="Your $u_ccode is included $inlist. $tip_msg"
		esac
	else
		get_matching_line "$lists_to_change_nl" "" "$user_ccode" "_*" filtered_ccode

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
				die 0 "Aborted action '$action'."
		esac
	}
	:
}

get_wrong_ccodes() {
	for list_id in $wrong_lists; do
		wrong_ccodes="$wrong_ccodes${list_id%_*} "
	done
	san_str wrong_ccodes
}


#### VARIABLES

get_config_vars

case "$geomode" in
	whitelist|blacklist) ;;
	'') echolog "geoip mode is not set."; [ "$action" != configure ] && echolog "Changing action to 'configure'"; action=configure ;;
	*) die "Unexpected geoip mode '$geomode'!"
esac

toupper ccodes_arg
san_str ccodes_arg

tolower action

run_command="$i_script-run.sh"


#### CHECKS

# check that the config file exists
[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."


## Check args for sanity

erract="action '$action'"
incompat="$erract is incompatible with option"

case "$action" in
	add|remove)
		# check for valid country codes
		[ ! "$ccodes_arg" ] && die "$erract requires to specify countries with '-c <country_codes>'!" ;;
	status|restore|reset|on|off|showconfig) [ "$ccodes_arg" ] && die "$incompat '-c'."
esac

[ "$action" != configure ] && {
	for i_opt in \
			"geomode m" "trusted t" "ports p" "lan_ips l" "ifaces i" "geosource u" "datadir a" "nobackup o" "schedule s"; do
		eval "[ \"\$${i_opt% *}_arg\" ]" && die "$incompat '-${i_opt#* }'."
	done
}


#### MAIN

case "$action" in
	status) . "$_lib-status.sh"; die $? ;;
	showconfig) printf '\n%s\n\n' "Config in $conf_file:"; cat "$conf_file"; die 0
esac

mk_lock
trap 'eval "$trap_args_unlock"' INT TERM HUP QUIT


case "$action" in
	on|off)
		case "$action" in
			on) [ ! "$iplists" ] && die "No ip lists registered. Refusing to enable geoip blocking."
				setconfig "noblock=" ;;
			off) setconfig "noblock=1"
		esac
		call_script "$i_script-apply.sh" $action
		die $? ;;
	reset) rm_iplists_rules; setconfig "iplists="; die $? ;;
	restore) restore_from_config; die $?
esac

if [ "$action" = configure ]; then
	unset restore_req planned_lists \
		datadir_change nobackup_change geomode_change geosource_change ifaces_change lists_change schedule_change
	for var_name in datadir nobackup geomode geosource ifaces schedule iplists; do
		eval "${var_name}_prev=\"\$$var_name\""
	done

	for opt_ch in datadir nobackup geomode geosource ifaces schedule; do
		eval "[ \"\$${opt_ch}_arg\" ] && [ \"\$${opt_ch}_arg\" != \"\$${opt_ch}\" ] && ${opt_ch}_change=1"
	done

	check_lists_coherence 2>/dev/null || restore_req=1

	get_prefs || die
	ccodes_arg="$ccodes"

	for opt_ch in datadir nobackup geomode geosource ifaces schedule; do
		eval "[ \"\$${opt_ch}\" != \"\$${opt_ch}_prev\" ] && ${opt_ch}_change=1"
	done

else
	check_lists_coherence || incoherence_detected
fi

[ "$ccodes_arg" ] && validate_arg_ccodes

lists_arg=
for ccode in $ccodes_arg; do
	for f in $families; do
		add2list lists_arg "${ccode}_$f"
	done
done

case "$action" in
	configure)
		: "${lists_arg:="$iplists"}"
		! get_difference "$iplists" "$lists_arg" && lists_change=1

		planned_lists="$lists_arg"
		lists_to_change="$lists_arg"

		[ "$geomode_change" ] || [ "$geosource_change" ] || { [ "$ifaces_change" ] && [ "$_fw_backend" = nft ]; } ||
			[ "$lists_change" ] && restore_req=1

		[ "$geomode_change" ] || [ "$lists_change" ] && check_for_lockout
		iplists="$lists_arg"

		bk_dir="$datadir/backup"
		[ "$nobackup_change" ] && {
			[ -d "$bk_dir" ] && {
				printf %s "Removing old backup... "
				rm -rf "${bk_dir:?}" || die "$FAIL remove the backup."
				OK
			}
			[ "$nobackup" = false ] && restore_req=1
		}

		[ "$datadir_change" ] && {
			[ ! "$datadir" ] && die "Internal error: \$datadir var is unset"
			printf %s "Creating the new data dir '$datadir'... "
			mkdir -p "$datadir" && chmod -R 600 "$datadir" && chown -R root:root "$datadir" || die "$FAIL create '$datadir'."
			OK
			[ -d "$datadir_prev" ] && {
				printf %s "Moving data to the new path... "
				set +f
				mv "$datadir_prev"/* "$datadir" || { rm -rf "${datadir:?}" 2>/dev/null; die "$FAIL move the data."; }
				set -f
				OK
				printf %s "Removing the old data dir '$datadir_prev'..."
				rm -rf "${datadir_prev:?}" || { rm -rf "${datadir:?}" 2>/dev/null; die "$FAIL remove the old data dir."; }
				OK
			}
			export datadir status_file="$datadir/status"
		}

		setconfig tcp_ports udp_ports geosource lan_ips_ipv4 lan_ips_ipv6 autodetect trusted_ipv4 trusted_ipv6 \
			ifaces geomode iplists datadir nobackup user_ccode schedule

		if [ ! "$restore_req" ]; then
			call_script "$i_script-apply.sh" update; rv_apply=$?
			[ $rv_apply != 0 ] || ! check_lists_coherence && { restore_from_config && rv_apply=254 || rv_apply=1; }
		else
			restore_from_config; rv_apply=$?
		fi

		[ "$schedule_change" ] && {
			call_script "$i_script-cronsetup.sh" || die "$FAIL update cron jobs."
		}

		[ "$rv_apply" = 0 ] && [ "$_OWRTFW" ] && {
			.  "$_lib-owrt-common.sh" || exit 1
			[ ! -f "$conf_dir/setupdone" ] && touch "$conf_dir/setupdone" "/tmp/$p_name-setupdone"
			rm_lock
			enable_owrt_init; rv_apply=$?
			rm -f "/tmp/$p_name-setupdone"
		}
		[ ! "$in_install" ] && statustip
		die $rv_apply ;;
	add)
		san_str requested_lists "$iplists $lists_arg"
#		debugprint "requested resulting lists: '$requested_lists'"

		if [ ! "$force_action" ]; then
			get_difference "$iplists" "$requested_lists" lists_to_change
			get_intersection "$lists_arg" "$iplists" wrong_lists

			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				echolog "NOTE: country codes '$wrong_ccodes' have already been added to the $geomode."
			}
		else
			lists_to_change="$lists_arg"
		fi
		san_str planned_lists "$iplists $lists_to_change"
#		debugprint "action: add, lists_to_change: '$lists_to_change'"
		;;

	remove)
#		debugprint "requested lists to remove: '$lists_arg'"
		if [ ! "$force_action" ]; then
			get_intersection "$iplists" "$lists_arg" lists_to_change
			subtract_a_from_b "$iplists" "$lists_arg" wrong_lists
			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				echolog "NOTE: country codes '$wrong_ccodes' have not been added to the $geomode, so can not remove."
			}
		else
			lists_to_change="$lists_arg"
		fi
		# remove any entries found in lists_to_change from iplists and assign to planned_lists
		subtract_a_from_b "$lists_to_change" "$iplists" planned_lists
esac

if [ ! "$lists_to_change" ] && [ ! "$force_action" ]; then
	report_lists
	die 0 "Nothing to do, exiting."
fi

debugprint "planned lists after '$action': '$planned_lists'"

if [ ! "$planned_lists" ] && [ ! "$force_action" ] && [ "$geomode" = whitelist ]; then
	die "Planned whitelist is empty! Disallowing this to prevent accidental lockout of a remote server."
fi

# try to prevent possible user lock-out
check_for_lockout

### Call the *run script

debugprint "Writing new config to file: 'iplists=$planned_lists'"
setconfig "iplists=$planned_lists"

call_script -l "$run_command" "$action" -l "$lists_to_change"; rv=$?

# positive return code means apply failure or another permanent error, except for 254
case "$rv" in 0|254) ;; *)
	echolog -err "$FAIL perform action '$action' for lists '$lists_to_change_str'."
	[ ! "$iplists" ] && die "Can not restore previous ip lists because they are not found in the config file."
	# write previous config lists
	setconfig iplists
	restore_from_config
esac

get_active_iplists new_verified_lists
subtract_a_from_b "$new_verified_lists" "$planned_lists" failed_lists
if [ "$failed_lists" ]; then
	debugprint "planned_lists: '$planned_lists', new_verified_lists: '$new_verified_lists', failed_lists: '$failed_lists'."
	echolog -warn "$FAIL apply new $geomode rules for ip lists: $failed_lists."
	# if the error encountered during installation, exit with error to fail the installation
	[ "$in_install" ] && die
	get_difference "$lists_to_change" "$failed_lists" ok_lists
	[ ! "$ok_lists" ] && die "All actions failed."
fi

[ ! "$in_install" ] && { report_lists; statustip; }

die 0
