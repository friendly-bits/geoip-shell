#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-run

#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/${proj_name}-ipt.sh" || exit 1

check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me <action> [-l <"list_ids">] [-o] [-d] [-h]

Serves as a proxy to call the -fetch, -apply and -backup scripts with arguments required for each action.

Actions:
    add|remove  : Add or remove ip lists to/from geoip firewall rules.
    update      : Fetch ip lists and reactivate them via the *apply script.
    restore     : Restore previously downloaded lists (skip fetching)

Options:
    -l <"list_ids">  : List id's in the format <countrycode>_<family>. If passing multiple list id's, use double quotes.
    -o               : No backup: don't create backup of current firewall state after the action.

    -d               : Debug
    -h               : This help

EOF
}

#### PARSE ARGUMENTS

action_run="$(tolower "$1")"

# process the rest of the arguments
shift 1
while getopts ":l:odh" opt; do
	case $opt in
		l) arg_lists=$OPTARG ;;
		o) nobackup_args=1 ;;
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


#### VARIABLES

for entry in "Lists config_lists" "NoBackup nobackup_conf" "Source dl_source" "ListType list_type" "BackupFile bk_file"; do
	getconfig "${entry% *}" "${entry#* }"
done
export config_lists list_type

nobackup="${nobackup_args:-$nobackup_conf}"

use_conf=

case "$action_run" in update|restore) use_conf=1; esac

if [ ! "$arg_lists" ] && [ "$use_conf" ]; then
	lists="$config_lists"
else
	lists="$arg_lists"
fi

trim_spaces "$lists" lists
fast_el_cnt "$lists" " " lists_cnt

knowngood_file="$datadir/iptables_knowngood.bak"
iplist_dir="$datadir/ip_lists"

status_file="$iplist_dir/status"

failed_lists_cnt=0


#### CHECKS

check_deps "$script_dir/${proj_name}-fetch.sh" "$script_dir/${proj_name}-apply.sh" "$script_dir/${proj_name}-backup.sh" || die

# check that the config file exists
[ ! -f "$conf_file" ] && die "Error: config file '$conf_file' doesn't exist! Run the installation script again."

[ ! "$knowngood_file" ] && die "Error: Known-good file path can not be empty!"

[ ! "$iplist_dir" ] && die "Error: iplist file path can not be empty!"

[ ! "$list_type" ] && die "\$list_type variable should not be empty! Something is wrong!"


#### MAIN

# check for valid action and translate *run action to *apply action
# *apply does the same thing whether we want to update, apply(refresh) or to add a new ip list, which is why this translation is needed
case "$action_run" in
	add) action_apply=add ;;
	update) action_apply=add; check_lists_coherence || force="-f" ;; # if firewall is in incoherent state, force re-fetch
	remove) action_apply=remove ;;
	restore)
		if [ ! "$bk_file" ] || [ ! -f "$bk_file" ]; then
			action_run=update; action_apply=add; force="-f" # if backup file doesn't exist, force re-fetch
		else
			call_script "$script_dir/${proj_name}-backup.sh" "restore"; rv_cs=$?
			getconfig Lists lists
			if [ "$rv_cs" = 0 ]; then
				nobackup=1
			else
				echolog -err "Restore from backup failed. Attempting to restore from config."
				rm_all_ipt_rules || die "Error removing firewall rules and ipsets."
				action_run=update; action_apply=add; force="-f" # if restore failed, force re-fetch
			fi
		fi
		;;
	*) action="$action_run"; unknownact
esac


### Fetch ip lists

if [ "$action_apply" = add ]; then
	[ ! "$lists" ] && { usage; die "Error: no list id's were specified!"; }

	# mark all lists as failed in the status file before launching *fetch. if *fetch completes successfully, it will reset this
	setstatus "$status_file" "FailedLists=$lists" || setstatus_failed

	call_script "$script_dir/${proj_name}-fetch.sh" -l "$lists" -p "$iplist_dir" -s "$status_file" -u "$dl_source" "$force"

	# read *fetch results from the status file
	getstatus "$status_file" FetchedLists lists
	getstatus "$status_file" FailedLists failed_lists

	[ "$failed_lists" ] && echolog -err "Failed to fetch and validate lists '$failed_lists'."

	fast_el_cnt "$failed_lists" " " failed_lists_cnt

	[ "$failed_lists_cnt" -ge "$lists_cnt" ] && die 254 "All fetch attempts failed."
fi


### Apply ip lists

apply_rv=0
case "$action_run" in update|add|remove)
	[ ! "$lists" ] && { echolog "Firewall reconfiguration isn't required."; exit 0; }

	call_script "$script_dir/${proj_name}-apply.sh" "$action_apply" -l "$lists"; apply_rv=$?
	set +f; rm "$iplist_dir/"*.iplist 2>/dev/null
	case "$apply_rv" in
		0) ;;
		254) echolog -err "Error: *apply exited with code '254'. Failed to execute action '$action_apply'." ;;
		*) debugprint "NOTE: *apply exited with error code '$apply_rv'."; die "$apply_rv"
	esac
esac


if check_lists_coherence; then
	echolog "Successfully executed action '$action_run' for lists '$lists'."
else
	echolog -err "Warning: actual $list_type firewall config differs from the config file!" \
		"Please run '$proj_name restore' to restore config coherence!" \
		"If it's a recurring issue, please consider filing a bug report!"
		for opt in unexpected missing; do
			eval "[ \"\$${opt}_lists\" ] && printf '%s\n' \"$opt $list_type ip lists in the firewall: '\$${opt}_lists'\"" >&2
		done
	echo
	exit 1
fi

if [ "$apply_rv" = 0 ] && [ ! "$nobackup" ]; then
	# create a backup of config, ipsets and firewall state
	call_script "$script_dir/${proj_name}-backup.sh" create-backup
else
	debugprint "Skipping backup of current firewall state."
fi

case "$failed_lists_cnt" in
	0) rv=0;;
	*) 	debugprint "failed_lists_cnt: $failed_lists_cnt"
		rv=254
esac

exit "$rv"
