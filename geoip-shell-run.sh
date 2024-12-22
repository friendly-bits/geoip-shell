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
set -- $_args; oldifs

#### USAGE

usage() {
cat <<EOF

Usage: $me [action] [-l <"list_ids">] [-o] [-d] [-V] [-h]

Coordinates and calls the -fetch, -apply and -backup scripts to perform requested action.

Actions:
  add     :  Add ip lists to firewall rules, for specified direction(s)
  update  :  Fetch updated ip lists and activate them via the -apply script.
  restore :  Restore previously downloaded lists from backup (falls back to fetch if fails).

Options:
  -l <"list_ids"> :  $list_ids_usage

  -o : No backup: don't create backup of ip lists and firewall rules after the action.
  -f : Force action
  -a : Daemon mode (will retry actions \$max_attempts times with growing time intervals)
  -d : Debug
  -V : Version
  -h : This help

EOF
}

#### PARSE ARGUMENTS

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
			[ "$action_run" = add ] || { usage; die "Option '-l' can only be used with the 'add' action."; }
			[ "$lists_arg" ] && die "Option '-l' can not be used twice."
			lists_arg="$OPTARG" ;;
		f) force_run="-f" ;;
		a) export daemon_mode=1 ;;
		o) nobackup_arg=true ;;
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
	die "$@"
}

resume_geoblocking() {
	[ "$resume_req" ] && [ "$outbound_geomode" != disable ] && [ "$noblock" = false ] && {
		echolog "Resuming outbound geoblocking."
		geoip_on outbound
		echo
	}
}


#### VARIABLES

export_conf=1 get_config_vars

nobackup="${nobackup_arg:-$nobackup}"

san_str apply_lists_req "$lists_arg" || die
[ ! "$apply_lists_req" ] &&
	case "$action_run" in
		add) die "no list id's were specified for actioin 'add'." ;;
		update|restore)
			san_str apply_lists_req "$inbound_iplists $outbound_iplists" || die
	esac

fast_el_cnt "$apply_lists_req" " " lists_cnt

failed_lists_cnt=0

[ "$_fw_backend" = ipt ] && raw_mode="-r"


#### CHECKS

checkvars i_script iplist_dir inbound_geomode outbound_geomode _fw_backend _lib
check_deps "$i_script-fetch.sh" "$i_script-apply.sh" "$i_script-backup.sh" || die

# check that the config file exists
[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Please run '$p_name configure'."


#### MAIN

[ ! "$manmode" ] && echolog "Starting action '$action_run'."

mkdir -p "$iplist_dir"
[ ! -d "$iplist_dir" ] && die "$FAIL create directory '$iplist_dir'."

mk_lock
trap 'trap - INT TERM HUP QUIT; set +f; rm -f \"$iplist_dir/\"*.iplist; rm -f \"$fetch_res_file\"; die' INT TERM HUP QUIT

# wait $reboot_sleep seconds after boot, or 0-59 seconds before updating
[ "$daemon_mode" ] && {
	if [ "$action_run" = restore ]; then
		IFS='. ' read -r uptime _ < /proc/uptime
		: "${uptime:=0}"
		: "${reboot_sleep:=30}"
		sl_time=$((reboot_sleep-uptime))
	elif [ "$action_run" = update ]; then
		rand_int="$(tr -cd 0-9 < /dev/urandom | dd bs=3 count=1 2>/dev/null)"
		: "${rand_int:=0}"
		sl_time=$(( $(printf "%.0f" "$rand_int")*60/999 ))
	fi
	[ $sl_time -gt 0 ] && {
		echolog "Sleeping for ${sl_time}s..."
		sleep $sl_time
	}
}

case "$action_run" in
	update)
		# if firewall rules don't match the config, force re-fetch
		check_lists_coherence || force_run="-f" ;;
	restore)
		[ ! "$force_run" ] && check_lists_coherence -n 2>/dev/null &&
			{ echolog "Geoblocking firewall rules and sets are Ok. Exiting."; die 0; }
		if [ "$nobackup" = true ]; then
			echolog "$p_name was configured with 'nobackup' option, changing action to 'update'."
			# if backup file doesn't exist, force re-fetch
			action_run=update force_run="-f"
		else
			get_counters
			if call_script -l "$i_script-backup.sh" restore -n && check_lists_coherence; then
				echolog "Successfully restored ip lists."
				die 0
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

unset all_fetched_lists missing_lists lists_fetch fetched_lists

[ ! "$daemon_mode" ] && max_attempts=1
case "$action_run" in add|update) lists_fetch="$apply_lists_req" ;; *) max_attempts=1; esac

mk_datadir

attempt=0 secs=5
resume_req=
if [ "$lists_fetch" ]; then
	[ "$source_ips_policy" = pause ] && [ "$outbound_geomode" != disable ] && {
		echolog "${_nl}Pausing outbound geoblocking before ip lists update."
		geoip_off outbound
		# 0 - geoip_off success, 2 - already off, 1 - error
		case $? in
			0) resume_req=1 ;;
			1) die ;;
			2)
		esac
	}

	while :; do
		attempt=$((attempt+1))
		secs=$((secs+5))
		[ $attempt -gt $max_attempts ] && fetch_failed "Giving up after $max_attempts fetch attempts."

		### Fetch ip lists
		# mark all lists as failed in the fetch_res file before calling fetch. fetch resets this on success
		setstatus "$fetch_res_file" "failed_lists=$lists_fetch" "fetched_lists=" || fetch_failed

		call_script "$i_script-fetch.sh" -l "$lists_fetch" -p "$iplist_dir" -s "$fetch_res_file" -u "$geosource" "$force_run" "$raw_mode"

		# read fetch results from the status file
		gs_rv=
		nodie=1 getstatus "$fetch_res_file" || gs_rv=1
		rm -f "$fetch_res_file"
		[ "$gs_rv" = 1 ] && fetch_failed "$FAIL read the fetch results file '$fetch_res_file'"

		add2list all_fetched_lists "$fetched_lists"
		[ "$failed_lists" ] && {
			echolog -err "$FAIL fetch and validate lists '$failed_lists'."

			[ "$daemon_mode" ] && {
				echolog "Retrying in $secs seconds"
				sleep $secs
				san_str lists_fetch "$failed_lists $missing_lists" || fetch_failed
				continue
			}

			[ "$action_run" = add ] && {
				set +f; rm -f "$iplist_dir/"*.iplist; set -f
				fetch_failed 254 "Aborting the action 'add'."
			}
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


### Apply ip lists

apply_rv=0

get_intersection "$all_fetched_lists" "$apply_lists_req" all_apply_lists

[ ! "$all_apply_lists" ] && {
	echolog "Firewall reconfiguration isn't required."
	if check_lists_coherence; then
		reg_last_update
		die 0
	else
		die 1
	fi
}

echolog "${_nl}${print_action} ip lists '$all_apply_lists'."

call_script "$i_script-apply.sh" "$action_run"
apply_rv=$?
set +f; rm -f "$iplist_dir/"*.iplist; set -f

case "$apply_rv" in
	0) ;;
	254)
		[ "$first_setup" ] && die
		echolog -err "$p_name-apply.sh exited with code '254'. $FAIL execute action '$action_run'."
		die 254 ;;
	*)
		debugprint "NOTE: apply exited with code '$apply_rv'."
		die "$apply_rv"
esac

if [ ! "$failed_lists" ] && check_lists_coherence; then
	reg_last_update
	echolog "Successfully ${print_action_done} ip lists '$apply_lists_req'."
	echo
	[ "$nobackup" = false ] && call_script -l "$i_script-backup.sh" create-backup
else
	die 1
fi

die 0
