#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090,SC2034

# geoip-shell-run

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
. "/usr/bin/${p_name}-geoinit.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args
oldifs

run_fail() {
	rm -f "$fetch_res_file"
	[ "$RM_IPLISTS" ] && rm_iplists
	case "$1" in ''|*[!0-9]*) ;; *) rf_rv="$1"; shift; esac
	[ -n "$*" ] && echolog -err "$@"
	if [ -n "$CUSTOM_SCRIPT_OK" ]; then
		(
			. "$custom_script"
			command -v gs_failure 1>/dev/null || exit 0
			session_log=
			[ -s "$GS_LOG_FILE" ] && session_log="$(get_session_log)"
			gs_failure "${session_log:+"Session log:${_nl}"}${session_log}"
		)
	fi
	rm -f "${GS_LOG_FILE}"
	die "${rf_rv:-1}"
}

run_success() {
	rm -f "$fetch_res_file"
	[ -n "$*" ] && echolog "$@"
	if [ -n "$CUSTOM_SCRIPT_OK" ]; then
		(
			. "$custom_script"
			command -v gs_success 1>/dev/null || exit 0
			session_log=
			grep -iE '^(\[.*\])*[ 	]*(ERROR|WARNING):' "$GS_LOG_FILE" 1>/dev/null 2>&1 &&
				session_log="$(get_session_log)"
			gs_success "${session_log:+"Errors/warnings encountered.${_nl}Session log:${_nl}"}${session_log}"
		)
	fi
	rm -f "${GS_LOG_FILE}"
	die 0
}


#### USAGE

usage() {
cat <<EOF

Usage: $me [action] [-l <"list_ids">] [-o] [-d] [-V] [-h]

Coordinates and calls the -fetch, -apply and -backup scripts to perform requested action.

Actions:
  add     :  Add IP lists to firewall rules, for specified direction(s)
  update  :  Fetch updated IP lists and activate them via the -apply script.
  restore :  Restore previously downloaded lists from backup (falls back to fetch if fails).

Options:
  -l <"list_ids"> :  $list_ids_usage

  -o : No backup: don't create backup of IP lists and firewall rules after the action.
  -f : Force action
  -a : Daemon mode (will retry actions \$max_attempts times with growing time intervals)
  -d : Debug
  -V : Version
  -h : This help

EOF
}

#### PARSE ARGUMENTS

RM_IPLISTS=
daemon_mode=

# check for valid action
tolower action_run "$1"
case "$action_run" in
	add|update|restore) shift ;;
	*) action="$1"; unknownact
esac

# process the rest of the args
while getopts ":l:faodVh" opt; do
	case $opt in
		l)
			[ "$action_run" = add ] || { usage; run_fail 1 "Option '-l' can only be used with the 'add' action."; }
			[ "$lists_arg" ] && run_fail 1 "Option '-l' can not be used twice."
			lists_arg="$OPTARG" ;;
		f) force_run="-f" ;;
		a) export daemon_mode=1 ;;
		o) nobackup_arg=true ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; die 0 ;;
		h) usage; die 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

is_root_ok
source_lib "$_fw_backend" || die

setdebug
debugentermsg


#### Functions

reg_last_update() {
	case "$action_run" in update|add)
		[ ! "$failed_lists" ] && setstatus "$status_file" "last_update=$(date +%h-%d-%Y' '%H:%M:%S)"
	esac
}

fetch_failed() {
	resume_geoblocking
	run_fail "$@"
}

resume_geoblocking() {
	[ "$resume_req" ] && [ "$outbound_geomode" != disable ] && [ "$noblock" = false ] && {
		echolog "Resuming outbound geoblocking."
		geoip_on outbound
		echo
	}
}


rm -f "${GS_LOG_FILE}"

#### VARIABLES

export_conf=1 nodie=1 get_config_vars || run_fail 1

CUSTOM_SCRIPT_OK=
[ -n "$custom_script" ] && [ -n "$daemon_mode" ] && check_custom_script "$custom_script" && CUSTOM_SCRIPT_OK=1

nobackup="${nobackup_arg:-$nobackup}"

san_str apply_lists_req "$lists_arg" || run_fail 1
[ ! "$apply_lists_req" ] &&
	case "$action_run" in
		add) run_fail 1 "no list IDs were specified for actioin 'add'." ;;
		update|restore)
			san_str apply_lists_req "$inbound_iplists $outbound_iplists" || run_fail 1
	esac

separate_excl_iplists apply_lists_req "$apply_lists_req" || run_fail 1

fast_el_cnt "$apply_lists_req" " " lists_cnt

failed_lists_cnt=0

[ "$_fw_backend" = ipt ] && raw_mode="-r"


#### CHECKS

checkvars i_script iplist_dir inbound_geomode outbound_geomode _fw_backend _lib
check_deps "$i_script-fetch.sh" "$i_script-apply.sh" "$i_script-backup.sh" || run_fail 1

# check that the config file exists
[ ! -f "$conf_file" ] && run_fail 1 "Config file '$conf_file' doesn't exist! Please run '$p_name configure'."


#### MAIN

[ "$manmode" != 1 ] && echolog "Starting action '$action_run'."

dir_mk -n "$iplist_dir" || run_fail 1

mk_lock || die
trap 'trap - INT TERM HUP QUIT; run_fail 1' INT TERM HUP QUIT

# wait $reboot_sleep seconds after boot, or 0-59 seconds before updating
[ "$daemon_mode" ] && {
	if [ "$action_run" = restore ]; then
		IFS='. ' read -r uptime _ < /proc/uptime
		: "${uptime:=0}"
		: "${reboot_sleep:=30}"
		sl_time=$((reboot_sleep-uptime))
	elif [ "$action_run" = update ]; then
		get_random_int sl_time 60
	fi
	[ $sl_time -gt 0 ] && {
		echolog "Sleeping for ${sl_time}s..."
		sleep $sl_time &
		wait $!
	}
}

case "$action_run" in
	update)
		# if firewall rules don't match the config, force re-fetch
		check_lists_coherence || force_run="-f" ;;
	restore)
		[ ! "$force_run" ] && check_lists_coherence -n 2>/dev/null &&
			run_success "Geoblocking firewall rules and sets are Ok. Exiting."
		if [ "$nobackup" = true ]; then
			echolog "$p_name was configured with 'nobackup' option, changing action to 'update'."
			# if backup file doesn't exist, force re-fetch
			action_run=update force_run="-f"
		else
			get_counters
			if call_script -l "$i_script-backup.sh" restore -n && check_lists_coherence; then
				run_success "Successfully restored IP lists."
			else
				# if restore failed, force re-fetch
				echolog -err "Restore from backup failed. Changing action to 'update'."
				action_run=update force_run="-f"
			fi
		fi
esac

# From here on, action_run is 'add' or 'update'
case "$action_run" in
	add)
		print_action=Adding
		print_action_done=added ;;
	update)
		print_action=Updating
		print_action_done=updated ;;
esac

#### Daemon loop

unset all_fetched_lists lists_fetch

[ ! "$daemon_mode" ] && max_attempts=3
case "$action_run" in add|update) lists_fetch="$apply_lists_req" ;; *) max_attempts=1; esac

dir_mk "$datadir" || run_fail 1

resume_req=
if [ "$lists_fetch" ]; then
	[ "$source_ips_policy" = pause ] && [ "$outbound_geomode" != disable ] && {
		echolog "${_nl}Pausing outbound geoblocking before IP lists update."
		geoip_off outbound
		# 0 - geoip_off success, 2 - already off, 1 - error
		case $? in
			0) resume_req=1 ;;
			1) run_fail 1 "$FAIL pause outbound geoblocking." ;;
			2)
		esac
	}

	RM_IPLISTS=1
	attempt=0 secs=5
	while :; do
		attempt=$((attempt+1))
		fetched_lists='' failed_lists=''

		### Fetch IP lists
		# mark all lists as failed in the fetch_res file before calling fetch. fetch resets this on success
		printf '' > "$fetch_res_file"
		setstatus "$fetch_res_file" "failed_lists=$lists_fetch" "fetched_lists=" || fetch_failed
		call_script "$i_script-fetch.sh" -l "$lists_fetch" -p "$iplist_dir" -s "$fetch_res_file" \
			-u "$geosource" "$force_run" "$raw_mode"

		case "$?" in 0|254) ;; *) fetch_failed; esac

		# read fetch results from the status file
		nodie=1 getstatus "$fetch_res_file" 2>/dev/null ||
			{ fetch_failed "$FAIL read the fetch results file '$fetch_res_file'"; failed_lists="$lists_fetch"; }

		add2list all_fetched_lists "$fetched_lists"

		[ "$failed_lists" ] && {
			echolog -err "$FAIL fetch and validate lists '$failed_lists'."

			[ $attempt -ge $max_attempts ] && {
				fetch_rv=1
				[ "$action_run" = add ] && fetch_rv=254
				fetch_failed "${fetch_rv}" "Giving up after $max_attempts fetch attempts."
			}
			lists_fetch="$failed_lists"
			echolog "Retrying in $secs seconds"
			sleep $secs &
			wait $!
			secs=$((secs*4))
			continue
		}

		fast_el_cnt "$failed_lists" " " failed_lists_cnt
		[ "$failed_lists_cnt" -ge "$lists_cnt" ] && fetch_failed 254 "All fetch attempts failed."
		break
	done
	resume_geoblocking
else
	debugprint "No lists to fetch."
	:
fi


### Apply IP lists

apply_rv=0

get_intersection "$all_fetched_lists" "$apply_lists_req" all_apply_lists

[ ! "$all_apply_lists" ] && {
	if check_lists_coherence; then
		reg_last_update
		run_success "Firewall reconfiguration isn't required."
	else
		run_fail 1
	fi
}

echolog "${_nl}${print_action} IP lists '$all_apply_lists'."

call_script "$i_script-apply.sh" "$action_run"
apply_rv=$?
rm_iplists

case "$apply_rv" in
	0) ;;
	254)
		[ "$first_setup" ] && run_fail 1
		run_fail 254 "$p_name-apply.sh exited with code '254'. $FAIL execute action '$action_run'." ;;
	*)
		debugprint "NOTE: apply exited with code '$apply_rv'."
		run_fail "$apply_rv"
esac

if [ ! "$failed_lists" ] && check_lists_coherence; then
	reg_last_update
	[ "$nobackup" = false ] && call_script -l "$i_script-backup.sh" create-backup
else
	run_fail 1
fi

run_success "Successfully ${print_action_done} IP lists '$apply_lists_req'."
echo

die 0