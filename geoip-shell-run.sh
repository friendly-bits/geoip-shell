#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-run

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${p_name}-common.sh" || exit 1
. "$_lib-$_fw_backend.sh" || die

check_root

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me [action] [-l <"list_ids">] [-o] [-d] [-h]

Serves as a proxy to call the -fetch, -apply and -backup scripts with arguments required for each action.

Actions:
  add|remove  : Add or remove ip lists to/from geoip firewall rules.
  update      : Fetch ip lists and reactivate them via the *apply script.
  restore     : Restore previously downloaded lists (skip fetching).

Options:
  -l <"list_ids">  : List id's in the format <countrycode>_<family>. if passing multiple list id's, use double quotes.
  -o               : No backup: don't create backup of current firewall state after the action.

  -a               : daemon mode (will retry actions \$max_attempts times with growing time intervals)
  -d               : Debug
  -h               : This help

EOF
}

#### PARSE ARGUMENTS

action_run="$(tolower "$1")"
daemon_mode=

# process the rest of the args
shift 1
while getopts ":l:aodh" opt; do
	case $opt in
		l) arg_lists=$OPTARG ;;
		a) export daemon_mode=1 ;;
		o) nobackup_args=1 ;;
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

setdebug
debugentermsg

extra_args "$@"

daemon_prep_next() {
	echolog "Retrying in $secs seconds"
	sleep $secs
	ok_lists="$ok_lists$fetched_lists "
	san_str -s lists_fetch "$failed_lists $missing_lists"
}

#### VARIABLES

for entry in "Lists config_lists" "NoBackup nobackup_conf" "Source dl_source" "Geomode geomode" "MaxAttempts max_attempts"; do
	getconfig "${entry% *}" "${entry#* }"
done
export config_lists geomode

nobackup="${nobackup_args:-$nobackup_conf}"

use_conf=

case "$action_run" in update|restore) use_conf=1; esac

if [ ! "$arg_lists" ] && [ "$use_conf" ]; then
	lists="$config_lists"
else
	lists="$arg_lists"
fi

trimsp lists
fast_el_cnt "$lists" " " lists_cnt

iplist_dir="$datadir/ip_lists"

status_file="$iplist_dir/status"

failed_lists_cnt=0

[ "$_fw_backend" = ipt ] && raw_mode="-r"


#### CHECKS

check_deps "$i_script-fetch.sh" "$i_script-apply.sh" "$i_script-backup.sh" || die

# check that the config file exists
[ ! -f "$conf_file" ] && die "config file '$conf_file' doesn't exist! Re-install $p_name."

[ ! "$iplist_dir" ] && die "iplist file path can not be empty!"

[ ! "$geomode" ] && die "\$geomode variable should not be empty! Something is wrong!"


#### MAIN

mk_lock

[ ! "$manmode" ] && echolog "Starting action '$action_run'."

# check for valid action and translate *run action to *apply action
# *apply does the same thing whether we want to update, apply(refresh) or to add a new ip list, which is why this translation is needed
case "$action_run" in
	add) action_apply=add ;;
	# if firewall is in incoherent state, force re-fetch
	update) action_apply=add; check_lists_coherence || force="-f" ;;
	remove) action_apply=remove ;;
	restore)
		check_lists_coherence -n 2>/dev/null && { echolog "Geoip firewall rules and sets are Ok. Exiting."; die 0; }
		if [ "$nobackup" ]; then
			echolog "$p_name was installed with 'nobackup' option, changing action to 'update'."
			# if backup file doesn't exist, force re-fetch
			action_run=update action_apply=add force="-f"
		else
			call_script -l "$i_script-backup.sh" "restore"; rv_cs=$?
			getconfig Lists lists
			if [ "$rv_cs" = 0 ]; then
				nobackup=1
			else
				echolog -err "Restore from backup failed. Changing action to 'update'."
				rm_all_georules || die "$FAIL remove firewall rules."
				# if restore failed, force re-fetch
				action_run=update action_apply=add force="-f"
			fi
		fi ;;
	*) action="$action_run"; unknownact
esac


#### Daemon loop

[ ! "$daemon_mode" ] && max_attempts=1
attempt=0 secs=4 ok_lists='' missing_lists=
while true; do
	attempt=$((attempt+1))
	secs=$((secs+1))
	[ "$daemon_mode" ] && [ $attempt -gt $max_attempts ] && die "Giving up."

	### Fetch ip lists

	if [ "$action_apply" = add ]; then
		[ ! "$lists" ] && { usage; die "no list id's were specified!"; }

		# mark all lists as failed in the status file before launching *fetch. if *fetch completes successfully, it will reset this
		setstatus "$status_file" "FailedLists=$lists"

		call_script "$i_script-fetch.sh" -l "$lists" -p "$iplist_dir" -s "$status_file" -u "$dl_source" "$force" "$raw_mode"

		# read *fetch results from the status file
		getstatus "$status_file" FailedLists failed_lists &&
		getstatus "$status_file" FetchedLists fetched_lists || die

		[ "$failed_lists" ] && {
			echolog -err "$FAIL fetch and validate lists '$failed_lists'."
			[ "$action_run" = add ] && {
				set +f; rm "$iplist_dir/"*.iplist 2>/dev/null; set -f
				die 254 "Aborting the action 'add'."
			}
			[ "$daemon_mode" ] && { daemon_prep_next; continue; }
		}

		fast_el_cnt "$failed_lists" " " failed_lists_cnt
		[ "$failed_lists_cnt" -ge "$lists_cnt" ] && {
			[ "$daemon_mode" ] && { daemon_prep_next; continue; } ||
				die 254 "All fetch attempts failed."
		}
	fi


	### Apply ip lists

	san_str -s lists "$fetched_lists $ok_lists"
	apply_rv=0
	case "$action_run" in update|add|remove)
		[ ! "$lists" ] && {
			echolog "Firewall reconfiguration isn't required."; die 0
		}

		call_script "$i_script-apply.sh" "$action_apply" -l "$lists"; apply_rv=$?
		set +f; rm "$iplist_dir/"*.iplist 2>/dev/null; set -f

		case "$apply_rv" in
			0) ;;
			254) [ "$in_install" ] && die
				echolog -err "*apply exited with code '254'. $FAIL execute action '$action_apply'." ;;
			*) debugprint "NOTE: *apply exited with error code '$apply_rv'."; die "$apply_rv"
		esac
		echolists=" for lists '$lists'"
	esac

	if check_lists_coherence; then
		[ "$failed_lists" ] && [ "$daemon_mode" ] && { daemon_prep_next; continue; }
		echolog "Successfully executed action '$action_run'$echolists."; break
	else
		[ "$daemon_mode" ] && { daemon_prep_next; continue; }
		echolog -err "$WARN actual $geomode firewall config differs from the config file!"
		for opt in unexpected missing; do
			eval "[ \"\$${opt}_lists\" ] && printf '%s\n' \"$opt $geomode ip lists in the firewall: '\$${opt}_lists'\"" >&2
		done
		die
	fi
done

if [ "$apply_rv" = 0 ] && [ ! "$nobackup" ]; then
	call_script -l "$i_script-backup.sh" create-backup
else
	debugprint "Skipping backup of current firewall state."
fi

case "$failed_lists_cnt" in
	0) rv=0;;
	*) 	debugprint "failed_lists_cnt: $failed_lists_cnt"
		rv=254
esac

die "$rv"
