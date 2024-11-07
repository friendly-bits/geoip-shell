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

Usage: $me [action] [-D $direction_syn -l <"list_ids">] [-o] [-d] [-V] [-h]

Coordinates and calls the -fetch, -apply and -backup scripts to perform requested action.

Actions:
  add|remove :  Add or remove ip lists to/from geoip firewall rules, for specified direction(s)
  update     :  Fetch updated ip lists and activate them via the -apply script.
  restore    :  Restore previously downloaded lists from backup (falls back to fetch if fails).

Options:
  -D $direction_syn : $direction_usage
  -l <"list_ids">       : $list_ids_usage

  -o : No backup: don't create backup of ip lists and firewall rules after the action.
  -f : Force action
  -a : Daemon mode (will retry actions \$max_attempts times with growing time intervals)
  -d : Debug
  -V : Version
  -h : This help

EOF
}

#### PARSE ARGUMENTS

parse_iplist_args() {
	case "$action_run" in add|remove) ;; *) usage; die "Option '-l' can only be used with the 'add' and 'remove' actions."; esac
	case "$direction" in
		inbound|outbound)
			eval "[ -n \"\$${direction}_lists_arg\" ]" && die "Option '-l' can not be used twice for direction '$direction'."
			eval "${direction}_lists_arg"='$OPTARG' ;;
		*) usage; die "Specify direction (inbound|outbound) to use with the '-l' option."
	esac
	req_direc_opt=
}

daemon_mode=

# check for valid action
tolower action_run "$1"
case "$action_run" in
	add|remove|update|restore) shift ;;
	*) action="$1"; unknownact
esac

# process the rest of the args
req_direc_opt=
while getopts ":D:l:faodVh" opt; do
	case $opt in
		D) case "$OPTARG" in
				inbound|outbound)
					case "$action_run" in add|remove) ;; *)
						usage
						die "Action is '$action_run', but direction-dependent options require the action to be 'add|remove'."
					esac
					[ "$req_direc_opt" ] && { usage; die "Provide valid options for the '$direction' direction."; }
					direction="$OPTARG"
					req_direc_opt=1 ;;
				*) usage; die "Invalid string '$OPTARG'. Use 'inbound|outbound' with the '-D' option"
			esac ;;
		l) parse_iplist_args ;;
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

[ "$req_direc_opt" ] && { usage; die "Provide valid options for direction '$direction'."; }

extra_args "$@"

is_root_ok
. "$_lib-$_fw_backend.sh" || die

setdebug
debugentermsg


daemon_prep_next() {
	echolog "Retrying in $secs seconds"
	sleep $secs
	add2list ok_lists "$fetched_lists"
	san_str lists_fetch "$failed_lists $missing_lists" || die
}

#### VARIABLES

for entry in inbound_iplists outbound_iplists inbound_geomode outbound_geomode nobackup geosource max_attempts reboot_sleep; do
	getconfig "$entry"
done
export inbound_iplists outbound_iplists inbound_geomode outbound_geomode

nobackup="${nobackup_arg:-$nobackup}"

inbound_apply_lists_req="$inbound_lists_arg"
outbound_apply_lists_req="$outbound_lists_arg"
san_str all_apply_lists_req "$inbound_lists_arg $outbound_lists_arg" || die
[ ! "$all_apply_lists_req" ] &&
	case "$action_run" in update|restore)
		inbound_apply_lists_req="$inbound_iplists" outbound_apply_lists_req="$outbound_iplists"
		san_str all_apply_lists_req "$inbound_iplists $outbound_iplists" || die
	esac

trimsp inbound_apply_lists_req
trimsp inbound_apply_lists_req
fast_el_cnt "$all_apply_lists_req" " " lists_cnt

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
	add) action_apply=add; [ ! "$all_apply_lists_req" ] && die "no list id's were specified!"
		get_counters ;;
	# if firewall rules don't match the config, force re-fetch
	update) action_apply=add; check_lists_coherence || force_run="-f"
		get_counters ;;
	remove) action_apply=remove; inbound_rm_lists="$inbound_apply_lists_req" outbound_rm_lists="$outbound_apply_lists_req" ;;
	restore)
		[ ! "$force_run" ] && check_lists_coherence -n 2>/dev/null &&
			{ echolog "Geoip firewall rules and sets are Ok. Exiting."; die 0; }
		get_counters
		if [ "$nobackup" = true ]; then
			echolog "$p_name was configured with 'nobackup' option, changing action to 'update'."
			# if backup file doesn't exist, force re-fetch
			action_run=update action_apply=add force_run="-f"
		else
			call_script -l "$i_script-backup.sh" restore; rv_cs=$?
			getconfig inbound_apply_lists_req inbound_iplists
			getconfig outbound_apply_lists_req outbound_iplists
			if [ "$rv_cs" = 0 ]; then
				nobackup=true
			else
				echolog -err "Restore from backup failed. Changing action to 'update'."
				# if restore failed, force re-fetch
				action_run=update action_apply=add force_run="-f"
			fi
		fi
esac


#### Daemon loop

unset echolists ok_lists missing_lists lists_fetch fetched_lists

[ ! "$daemon_mode" ] && max_attempts=1
case "$action_run" in add|update) lists_fetch="$all_apply_lists_req" ;; *) max_attempts=1; esac

attempt=0 secs=5
while :; do
	attempt=$((attempt+1))
	secs=$((secs+5))
	[ $attempt -gt $max_attempts ] && die "Giving up."

	### Fetch ip lists

	if [ "$action_apply" = add ] && [ "$lists_fetch" ]; then
		# mark all lists as failed in the status file before calling fetch. if fetch completes successfully, it will reset this
		setstatus "$status_file" "failed_lists=$lists_fetch" "fetched_lists=" || die

		call_script "$i_script-fetch.sh" -l "$lists_fetch" -p "$iplist_dir" -s "$status_file" -u "$geosource" "$force_run" "$raw_mode"

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
	elif [ "$action_apply" = add ] && [ ! "$lists_fetch" ]; then
		debugprint "No lists to fetch for action 'add'."
		:
	fi


	### Apply ip lists

	lists_fetch=
	san_str ok_lists "$fetched_lists $ok_lists" || die

	get_intersection "$ok_lists" "$inbound_apply_lists_req" inbound_apply_lists
	get_intersection "$ok_lists" "$outbound_apply_lists_req" outbound_apply_lists

	san_str inbound_apply_lists "$inbound_apply_lists $inbound_rm_lists" &&
	san_str outbound_apply_lists "$outbound_apply_lists $outbound_rm_lists" &&
	san_str all_apply_lists "$inbound_apply_lists $outbound_apply_lists" || die

	apply_rv=0
	case "$action_run" in update|add|remove)
		[ ! "$all_apply_lists" ] && { echolog "Firewall reconfiguration isn't required."; die 0; }

		apply_args=
		for d in inbound outbound; do
			eval "[ -n \"\${${d}_apply_lists}\" ] && apply_args=\"\${apply_args}-D $d -l \\\"\${${d}_apply_lists}\\\" \""
		done

		eval "call_script \"$i_script-apply.sh\" \"$action_apply\" $apply_args"
		apply_rv=$?
		set +f; rm -f "$iplist_dir/"*.iplist; set -f

		case "$apply_rv" in
			0) ;;
			254) [ "$in_install" ] && die
				echolog -err "$p_name-apply.sh exited with code '254'. $FAIL execute action '$action_apply'." ;;
			*)
				debugprint "NOTE: apply exited with code '$apply_rv'."
				die "$apply_rv"
		esac
		[ -n "$inbound_apply_lists" ] && echo_inb=" inbound geoblocking ip lists '$inbound_apply_lists',"
		[ -n "$outbound_apply_lists" ] && echo_outb=" outbound geoblocking ip lists '$outbound_apply_lists',"
		echolists=" for${echo_inb}${echo_outb}"
	esac

	if check_lists_coherence; then
		[ "$failed_lists" ] && [ "$daemon_mode" ] && { daemon_prep_next; continue; }
		[ "$action_run" = update ] && [ ! "$failed_lists" ] &&
			{ setstatus "$status_file" "last_update=$(date +%h-%d-%Y' '%H:%M:%S)" || die; }
		echolog "Successfully executed action '$action_run'${echolists%,}."; echo; break
	else
		[ "$daemon_mode" ] && { daemon_prep_next; continue; }
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
