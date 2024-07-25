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

Usage: $me <action> [-c $ccodes_syn] [-f $fam_syn] [-s $sch_syn] [-i $if_syn]
${sp8}[-m $mode_syn] [-u $srcs_syn ] [-l $lan_syn] [-t $tr_syn] [-i $if_syn]
${sp8}[-p $ports_syn] [-r $user_ccode_syn] [-o <true|false>] [-a <"path">] [-w $fw_be_syn]
${sp8}[-O $nft_p_syn] [-z] [-v] [-F] [-d] [-V] [-h]

Provides interface to configure geoip blocking.

Actions:
  on|off      : enable or disable the geoip blocking chain (via a rule in the base geoip chain)
  add|remove  : add or remove 2-letter country codes to/from geoip blocking rules
  configure   : change $p_name config
  status      : check on the current status of geoip blocking
  reset       : reset geoip config and firewall geoip rules
  restore     : re-apply geoip blocking rules from the config
  showconfig  : print the contents of the config file

Options for the add|remove actions:

  -c <"country_codes"> : 2-letter country codes to add or remove. If passing multiple country codes, use double quotes.

Options for the 'configure' action:

  -m $geomode_usage

  -c $ccodes_usage

  -f $families_usage

  -u $sources_usage

  -i $ifaces_usage

  -l $lan_ips_usage

  -t $trusted_ips_usage

  -p $ports_usage

  -r $user_ccode_usage

  -o $nobackup_usage

  -a $datadir_usage

  -s $schedule_usage

  -w $fw_be_usage

  -O $nft_perf_usage

Other options:

  -v : Verbose status output
  -F : Force the action
  -z : $nointeract_usage
  -d : Debug
  -V : Version
  -h : This help

EOF
}


#### PARSE ARGUMENTS

# check for valid action
tolower action "$1"
case "$action" in
	add|remove|configure|status|restore|reset|on|off|showconfig) shift ;;
	*) action="$1"; unknownact
esac

# process the rest of the args
while getopts ":m:c:f:s:i:l:t:p:r:u:a:o:w:O:zvFdVh" opt; do
	case $opt in
		m) geomode_arg=$OPTARG ;;
		c) ccodes_arg=$OPTARG ;;
		f) families_arg=$OPTARG ;;
		s) schedule_arg=$OPTARG ;;
		i) ifaces_arg=$OPTARG ;;
		l) lan_ips_arg=$OPTARG ;;
		t) trusted_arg=$OPTARG ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		r) user_ccode_arg=$OPTARG ;;
		u) geosource_arg=$OPTARG ;;
		a) datadir_arg="$OPTARG" ;;
		o) nobackup_arg=$OPTARG ;;
		w) _fw_backend_arg=$OPTARG ;;
		O) nft_perf_arg=$OPTARG ;;

		z) nointeract_arg=1 ;;
		v) verb_status="-v" ;;
		F) force_action=1 ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

setdebug
debugentermsg

extra_args "$@"

is_root_ok


#### FUNCTIONS

incoherence_detected() {
	printf '%s\n\n%s\n' "Re-apply the rules from the config file to fix this?" \
		"'Y' to re-apply the config rules. 'N' to exit the script. 'S' to show configured ip lists."

	while true; do
		printf %s "[y|n|s] "
		read -r REPLY
		case "$REPLY" in
			[Yy] ) echo; restore_from_config; break ;;
			[Nn] ) die ;;
			[Ss] ) printf '\n\n\n%s\n' "$geomode ip lists in the config file: '$iplists'" ;;
			* ) printf '\n%s\n' "Enter 'y|n|s'."
		esac
	done
}

# restore ccodes from the config file
# if that fails, restore from backup
restore_from_config() {
	check_reapply() {
		check_lists_coherence && { echolog "$restore_ok_msg"; return 0; }
		echolog -err "$FAIL apply $p_name config."
		return 1
	}

	restore_msg="Restoring $p_name from ${_prev}config... "
	restore_ok_msg="Successfully restored $p_name from ${_prev}config."
	[ "$conf_act" = reset ] && {
		restore_msg="Applying ${_prev}config... "
		restore_ok_msg="Successfully applied ${_prev}config."
	}
	echolog "$restore_msg"
	case "$iplists" in
		'') echolog -err "No ip lists registered in the config." ;;
		*) [ ! "$in_install" ] && [ ! "$first_setup" ] && { rm_iplists_rules || return 1; }
			[ ! "$prev_config_try" ] && setconfig iplists
			rm -f "$datadir/status"
			call_script -l "$run_command" add -l "$iplists" -o
			check_reapply && {
				setstatus "$status_file" "last_update=$(date +%h-%d-%Y' '%H:%M:%S)" || die
				[ "$nobackup" = false ] && call_script -l "$i_script-backup.sh" create-backup
				return 0
			}
	esac

	[ "$in_install" ] || [ "$first_setup" ] && die

	[ "$prev_config" ] && [ ! "$prev_config_try" ] && {
		prev_config_try=1
		main_config="$prev_config"
		export_conf=1 get_config_vars
		_prev="previous "
		set_all_config
		restore_from_config && return 0
	}

	# call the *backup script to initiate recovery from fault
	[ -f "$datadir/backup/$p_name.conf.bak" ] && call_script -l "$i_script-backup.sh" restore && check_reapply && return 0

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

	if [ "$in_install" ] || [ "$geomode_change" ] || [ "$lists_change" ] || [ "$user_ccode_arg" ]; then
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
				[ ! "$in_install" ] && [ ! "$first_setup" ] && report_lists
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

changeact="Changing action to 'configure'."

conf_act=

[ ! -f "$conf_dir/setupdone" ] && {
	[ "$action" != configure ] && {
		echolog "Setup has not been completed. $changeact"
		action=configure conf_act=reset
	}

	[ ! "$nointeract_arg" ] && [ -s "$conf_file" ] && {
		q="[K]eep previous"; keep_opt=k
		for _par in geomode ccodes families schedule ifaces lan_ips trusted ports user_ccode geosource datadir nobackup \
			_fw_backend nft_perf no_persist noblock; do
			eval "[ \"\$${_par}_arg\" ]" && { q="[M]erge previous and new"; keep_opt=m; break; }
		done

		echo "Existing config file found. $q config or [f]orget the old config? [$keep_opt|f] or [a] to abort setup."
		pick_opt "$keep_opt|f|a"
		case "$REPLY" in
			a) exit 0 ;;
			f) rm -f "$conf_file"
		esac
	}
}

[ -s "$conf_file" ] && {
	nodie=1 get_config_vars 2>/dev/null || echolog "Config file not found or failed to get config."
}

[ "$_fw_backend" ] && { . "$_lib-$_fw_backend.sh" || die; } || {
	[ "$action" != configure ] && echolog "Firewall backend is not set. $changeact"
	action=configure conf_act=reset
}

[ "$_OWRT_install" ] && { . "$_lib-owrt-common.sh" || die; }

case "$geomode" in
	whitelist|blacklist) ;;
	'') [ "$action" != configure ] && echolog "Geoip mode is not set. $changeact"
		rm_setupdone
		action=configure conf_act=reset ;;
	*) die "Unexpected geoip mode '$geomode'!"
esac

san_str ccodes_arg
toupper ccodes_arg

tolower action

run_command="$i_script-run.sh"

[ -f "$excl_file" ] && nodie=1 getconfig exclude_iplists exclude_iplists "$excl_file"


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
			"geomode m" "trusted t" "ports p" "lan_ips l" "ifaces i" "geosource u" "datadir a" "nobackup o" "schedule s" \
				"families f" "user_ccode r" "nft_perf O" "nointeract z"; do
		eval "[ -n \"\$${i_opt% *}_arg\" ]" && die "$incompat '-${i_opt#* }'."
	done
}


#### MAIN

case "$action" in
	status) . "$_lib-status.sh"; die $? ;;
	showconfig) printf '\n%s\n\n' "Config in $conf_file:"; cat "$conf_file"; die 0
esac

mk_lock
trap 'die' INT TERM HUP QUIT


case "$action" in
	on|off)
		case "$action" in
			on) [ ! "$iplists" ] && die "No ip lists registered. Refusing to enable geoip blocking."
				setconfig "noblock=false" ;;
			off) setconfig "noblock=true"
		esac
		call_script "$i_script-apply.sh" $action
		die $? ;;
	reset) rm_iplists_rules; rm_data; rm -f "$conf_file"; rm_setupdone; die 0 ;;
	restore) restore_from_config; die $?
esac

if [ "$action" = configure ]; then
	[ ! -s "$conf_file" ] && {
		rm_setupdone
		touch "$conf_file" || die "$FAIL create the config file."
		[ "$_fw_backend" ] && rm_iplists_rules
	}
	first_setup=
	[ ! -f "$conf_dir/setupdone" ] && export first_setup=1

	unset planned_lists lists_change
	for var_name in datadir nobackup geomode geosource ifaces schedule iplists _fw_backend; do
		eval "${var_name}_prev=\"\$$var_name\""
	done

	for opt_ch in datadir nobackup geomode geosource ifaces schedule families _fw_backend nft_perf; do
		unset "${opt_ch}_change"
		eval "[ \"\$${opt_ch}_arg\" ] && [ \"\$${opt_ch}_arg\" != \"\$${opt_ch}\" ] && ${opt_ch}_change=1"
	done

	export nointeract="${nointeract_arg:-$nointeract}"

	get_prefs || die
	ccodes_arg="$ccodes"

	[ "$families_change" ] && [ ! "$ccodes_arg" ] && {
		lists_req=
		for list_id in $iplists; do
			add2list ccodes_arg "${list_id%_*}"
		done
	}

	for opt_ch in datadir nobackup geomode geosource ifaces schedule _fw_backend; do
		eval "[ \"\$${opt_ch}\" != \"\$${opt_ch}_prev\" ] && ${opt_ch}_change=1"
	done

else
	check_lists_coherence || incoherence_detected
fi

checkvars _fw_backend datadir geomode

unset lists_req excl_list_ids

[ "$ccodes_arg" ] && {
	validate_arg_ccodes
}

for ccode in $ccodes_arg; do
	for f in $families; do
		list_id="${ccode}_$f"
		case "$exclude_iplists" in *"$list_id"*)
			add2list excl_list_ids "$list_id"
			continue
		esac
		add2list lists_req "$list_id"
	done
done

[ "$ccodes_arg" ] && [ ! "$lists_req" ] && die "No applicable ip list id's could be generated for country codes '$ccodes_arg'."

[ "$excl_list_ids" ] && report_excluded_lists "$excl_list_ids"

case "$action" in
	configure)
		: "${lists_req:="$iplists"}"
		! get_difference "$iplists" "$lists_req" && lists_change=1

		planned_lists="$lists_req"
		lists_to_change="$lists_req"

		bk_dir="$datadir/backup"

		# logic for action 'configure'. careful: processing order matters!
		[ ! "$conf_act" ] && [ "$nobackup_change" ] && [ "$nobackup" = false ] && conf_act=backup
		[ "$conf_act" != reset ] &&
			{ [ "$ifaces_change" ] && [ "$_fw_backend" = nft ]; } || [ "$nft_perf_change" ] && conf_act=restore

		[ "$geomode_change" ] || [ "$geosource_change" ] || [ "$lists_change" ] || [ "$_fw_backend_change" ] && conf_act=reset

		[ "$geomode_change" ] || [ "$lists_change" ] && check_for_lockout
		iplists="$lists_req"

		[ "$nobackup_change" ] && {
			[ -d "$bk_dir" ] && {
				printf %s "Removing old backup... "
				rm -rf "$bk_dir" || die "$FAIL remove old backup."
				OK
			}
		}

		case "$conf_act" in ''|backup) ! check_lists_coherence 2>/dev/null && conf_act=restore; esac
		[ "$conf_act" = restore ] && { [ "$nobackup_prev" = true ] || [ ! -d "$bk_dir" ]; } && conf_act=reset

		debugprint "config action: '$conf_act'"
		[ "$datadir_change" ] && {
			printf %s "Creating the data dir '$datadir'... "
			rm -rf "$datadir"
			mkdir -p "$datadir" && chmod -R 600 "$datadir" && chown -R root:root "$datadir" || die "$FAIL create '$datadir'."
			OK
			[ -d "$datadir_prev" ] && {
				printf %s "Moving data to the new path... "
				set +f
				mv "$datadir_prev"/* "$datadir" || { rm -rf "$datadir"; die "$FAIL move the data."; }
				set -f
				OK
				printf %s "Removing the old data dir '$datadir_prev'..."
				rm -rf "$datadir_prev" || { rm -rf "$datadir"; die "$FAIL remove the old data dir."; }
				OK
			}
		}
		export datadir status_file="$datadir/status"
		prev_config="$main_config"

		set_all_config

		[ "$_fw_backend_change" ] && {
			_fw_be_new="$_fw_backend"
			export _fw_backend="$_fw_backend_prev"
			[ "$_fw_backend" ] && {
				# use previous backend to remove existing rules
				. "$_lib-$_fw_backend.sh" || die
				rm_iplists_rules
				rm_data
			}
			# source library for the new backend
			export _fw_backend="$_fw_be_new"
			. "$_lib-$_fw_backend.sh" || die
		}

		case "$conf_act" in
			reset) restore_from_config ;;
			restore) call_script -l "$i_script-backup.sh" restore -n ;;
			backup) call_script -l "$i_script-backup.sh" create-backup; die $? ;;
			'') call_script "$i_script-apply.sh" update
		esac
		rv_conf=$?

		[ "$conf_act" != reset ] && { [ "$rv_conf" != 0 ] || ! check_lists_coherence; } &&
			{ conf_act=reset; restore_from_config; rv_conf=$?; }

		[ "$schedule_change" ] || [ "$conf_act" = reset ]  || [ "$first_setup" ] && {
			call_script "$i_script-cronsetup.sh" || die "$FAIL update cron jobs."
		}

		[ ! "$conf_act" ] && [ "$nobackup" != true ] && call_script -l "$i_script-backup.sh" create-backup


		[ "$rv_conf" = 0 ] && [ "$first_setup" ] && {
			touch "$conf_dir/setupdone"
			[ "$_OWRTFW" ] && {
				.  "$_lib-owrt-common.sh" || die
				rm_lock
				enable_owrt_init; rv_conf=$?
				[ -f "$lock_file" ] && {
					echo "Waiting for background processes to complete..."
					for i in $(seq 1 30); do
						[ ! -f "$lock_file" ] && break
						sleep 1
					done
					[ $i = 30 ] && { echolog -warn "Lock file '$lock_file' is still in place. Please check system log."; }
				}
			}
		}

		report_lists; statustip
		die $rv_conf ;;
	add)
		san_str requested_lists "$iplists $lists_req"
#		debugprint "requested resulting lists: '$requested_lists'"

		if [ ! "$force_action" ]; then
			get_difference "$iplists" "$requested_lists" lists_to_change
			get_intersection "$lists_req" "$iplists" wrong_lists

			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				echolog "NOTE: country codes '$wrong_ccodes' have already been added to the $geomode."
			}
		else
			lists_to_change="$lists_req"
		fi
		san_str planned_lists "$iplists $lists_to_change"
#		debugprint "action: add, lists_to_change: '$lists_to_change'"
		;;

	remove)
#		debugprint "requested lists to remove: '$lists_req'"
		if [ ! "$force_action" ]; then
			get_intersection "$iplists" "$lists_req" lists_to_change
			subtract_a_from_b "$iplists" "$lists_req" wrong_lists
			[ "$wrong_lists" ] && {
				get_wrong_ccodes
				echolog "NOTE: country codes '$wrong_ccodes' have not been added to the $geomode, so can not remove."
			}
		else
			lists_to_change="$lists_req"
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

prev_iplists="$iplists"
debugprint "Writing new config to file: 'iplists=$planned_lists'"
setconfig "iplists=$planned_lists"

call_script -l "$run_command" "$action" -l "$lists_to_change"; run_rv=$?

case "$run_rv" in
	0) ;;
	*)
		echolog -err "$FAIL perform action '$action' for lists '$lists_to_change'." "Restoring previous config..."
		setconfig "iplists=$prev_iplists"
		case "$run_rv" in
			254) check_lists_coherence && { report_lists; die 254; }
				call_script -l "$i_script-backup.sh" restore
				die $? ;;
			*)
				[ ! "$prev_iplists" ] && die "Can not restore previous ip lists because they are not found in the config file."
				restore_from_config
		esac
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

report_lists
statustip

die 0
