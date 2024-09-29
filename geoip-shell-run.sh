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

Usage: $me [action] [-l <"list_ids">] [-o <true|false>] [-d] [-V] [-h]

Serves as a proxy to call the -fetch, -apply and -backup scripts with arguments required for each action.

Actions:
  add|remove  : Add or remove ip lists to/from geoip firewall rules.
  update      : Fetch ip lists and reactivate them via the *apply script.
  restore     : Restore previously downloaded lists (skip fetching).

Options:
  -l $list_ids_usage
  -o <true|false>  : No backup: don't create backup of ip lists and firewall rules after the action.

  -f               : Force fetch
  -a               : Daemon mode (will retry actions \$max_attempts times with growing time intervals)
  -d               : Debug
  -V               : Version
  -h               : This help

EOF
}

#### PARSE ARGUMENTS

daemon_mode=

# check for valid action
tolower action_run "$1"
case "$action_run" in
	add|remove|update|restore) shift ;;
	*) action="$1"; unknownact
esac

# process the rest of the args
while getopts ":l:faodVh" opt; do
	case $opt in
		l) lists_arg=$OPTARG ;;
		f) force_fetch="-f" ;;
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


daemon_prep_next() {
	echolog "Retrying in $secs seconds"
	sleep $secs
	add2list ok_lists "$fetched_lists"
	san_str lists_fetch "$failed_lists $missing_lists"
}

#### VARIABLES

for entry in iplists nobackup geosource geomode max_attempts reboot_sleep; do
	getconfig "$entry"
done
export iplists geomode

nobackup="${nobackup_arg:-$nobackup}"

apply_lists="$lists_arg"
[ ! "$apply_lists" ] && case "$action_run" in update|restore) apply_lists="$iplists"; esac

trimsp apply_lists
fast_el_cnt "$apply_lists" " " lists_cnt

failed_lists_cnt=0

[ "$_fw_backend" = ipt ] && raw_mode="-r"


#### CHECKS

checkvars i_script iplist_dir geomode _fw_backend _lib
check_deps "$i_script-fetch.sh" "$i_script-apply.sh" "$i_script-backup.sh" || die
check_libs "$_lib-$_fw_backend.sh" || die

# check that the config file exists
[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Please run '$p_name configure'."


#### MAIN

[ ! "$manmode" ] && echolog "Starting action '$action_run'."

mkdir -p "$iplist_dir"
[ ! -d "$iplist_dir" ] && die "$FAIL create directory '$iplist_dir'."

mk_lock
trap 'set +f; rm -f \"$iplist_dir/\"*.iplist; die' INT TERM HUP QUIT

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

# check for valid action and translate *run action to *apply action
# *apply does the same thing whether we want to update, apply(refresh) or to add a new ip list, which is why this translation is needed
case "$action_run" in
	add) action_apply=add; [ ! "$apply_lists" ] && die "no list id's were specified!" ;;
	# if firewall rules don't match the config, force re-fetch
	update) action_apply=add; check_lists_coherence || force_fetch="-f" ;;
	remove) action_apply=remove; rm_lists="$apply_lists" ;;
	restore)
		check_lists_coherence -n 2>/dev/null && { echolog "Geoip firewall rules and sets are Ok. Exiting."; die 0; }
		if [ "$nobackup" = true ]; then
			echolog "$p_name was configured with 'nobackup' option, changing action to 'update'."
			# if backup file doesn't exist, force re-fetch
			action_run=update action_apply=add force_fetch="-f"
		else
			call_script -l "$i_script-backup.sh" restore; rv_cs=$?
			getconfig apply_lists iplists
			if [ "$rv_cs" = 0 ]; then
				nobackup=true
			else
				echolog -err "Restore from backup failed. Changing action to 'update'."
				# if restore failed, force re-fetch
				action_run=update action_apply=add force_fetch="-f"
			fi
		fi
esac


#### Daemon loop

unset echolists ok_lists missing_lists lists_fetch fetched_lists

[ ! "$daemon_mode" ] && max_attempts=1
case "$action_run" in add|update) lists_fetch="$apply_lists" ;; *) max_attempts=1; esac

attempt=0 secs=5
while true; do
	attempt=$((attempt+1))
	secs=$((secs+5))
	[ $attempt -gt $max_attempts ] && die "Giving up."

	### Fetch ip lists

	if [ "$action_apply" = add ] && [ "$lists_fetch" ]; then
		# mark all lists as failed in the status file before calling fetch. if fetch completes successfully, it will reset this
		setstatus "$status_file" "failed_lists=$lists_fetch" "fetched_lists=" || die

		call_script "$i_script-fetch.sh" -l "$lists_fetch" -p "$iplist_dir" -s "$status_file" -u "$geosource" "$force_fetch" "$raw_mode"

		# read *fetch results from the status file
		getstatus "$status_file" || die "$FAIL read the status file '$status_file'"

		[ "$failed_lists" ] && {
			echolog -err "$FAIL fetch and validate lists '$failed_lists'."
			[ "$action_run" = add ] && {
				set +f; rm -f "$iplist_dir/"*.iplist; set -f
				die 254 "Aborting the action 'add'."
			}
			[ "$daemon_mode" ] && { daemon_prep_next; continue; }
		}

		fast_el_cnt "$failed_lists" " " failed_lists_cnt
		[ "$failed_lists_cnt" -ge "$lists_cnt" ] && {
			[ "$daemon_mode" ] && { daemon_prep_next; continue; }
			die 254 "All fetch attempts failed."
		}
	fi


	### Apply ip lists

	lists_fetch=
	san_str ok_lists "$fetched_lists $ok_lists"
	san_str apply_lists "$ok_lists $rm_lists"
	apply_rv=0
	case "$action_run" in update|add|remove)
		[ ! "$apply_lists" ] && { echolog "Firewall reconfiguration isn't required."; die 0; }

		call_script "$i_script-apply.sh" "$action_apply" -l "$apply_lists"; apply_rv=$?
		set +f; rm -f "$iplist_dir/"*.iplist; set -f

		case "$apply_rv" in
			0) ;;
			254) [ "$in_install" ] && die
				echolog -err "$p_name-apply.sh exited with code '254'. $FAIL execute action '$action_apply'." ;;
			*) debugprint "NOTE: apply exited with code '$apply_rv'."
				die "$apply_rv"
		esac
		echolists=" for ip lists '$ok_lists$rm_lists'"
	esac

	if check_lists_coherence; then
		[ "$failed_lists" ] && [ "$daemon_mode" ] && { daemon_prep_next; continue; }
		[ "$action_run" = update ] && [ ! "$failed_lists" ] &&
			{ setstatus "$status_file" "last_update=$(date +%h-%d-%Y' '%H:%M:%S)" || die; }
		echolog "Successfully executed action '$action_run'$echolists."; echo; break
	else
		[ "$daemon_mode" ] && { daemon_prep_next; continue; }
		die "actual $geomode firewall config differs from the config file!"
	fi
done

if [ "$apply_rv" = 0 ] && [ "$nobackup" = false ]; then
	call_script -l "$i_script-backup.sh" create-backup
else
	debugprint "Skipping backup of current firewall state."
	:
fi

case "$failed_lists_cnt" in
	0) rv=0 ;;
	*) rv=254
esac

die "$rv"
