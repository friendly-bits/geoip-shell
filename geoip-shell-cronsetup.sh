#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-cronsetup.sh


#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1

nolog=1

check_root


#### USAGE

usage() {
    cat <<EOF

Usage: $me [-d] [-h]

    Loads cron-related config from the config file and sets up cron jobs for geoip blocking accordingly.

Options:
    -d  : Debug
    -h  : This help

EOF
}

#### PARSE ARGUMENTS
while getopts ":dh" opt; do
	case $opt in
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

setdebug

debugentermsg


#### Functions

create_cron_job() {

	job_type="$1"

	[ -z "$config_lists" ] && die "Error: Countries list in the config file is empty! No point in creating autoupdate job."

	case "$job_type" in
		autoupdate)
			[ -z "$schedule" ] && die "Error: cron schedule in the config file is empty!"
			# Validate cron schedule
			debugprint "\nValidating cron schedule: '$schedule'."
			call_script "$install_dir/validate-cron-schedule.sh" -x "$schedule"; rv=$?
			case "$rv" in
				0) debugprint "Successfully validated cron schedule: '$schedule'." ;;
				*) die "Error validating cron schedule '$schedule'."
			esac

			# Remove existing autoupdate cron job before creating new one
			rm_cron_job "autoupdate"
			cron_cmd="$schedule \"$run_cmd\" update 1>/dev/null 2>/dev/null # ${proj_name}-autoupdate"
			debugprint "Creating autoupdate cron job with schedule '$schedule'... "
		;;

		persistence)
			debugprint "Creating persistence cron job... "

			# using the restore action for the *run script
			cron_cmd="@reboot sleep $sleeptime && \"$run_cmd\" restore 1>/dev/null 2>/dev/null # ${proj_name}-persistence"
		;;

		*) die "Unrecognized type of cron job: '$job_type'."
	esac

	#### Create new cron job

	curr_cron="$(crontab -u root -l 2>/dev/null)"; rv1=$?
	printf '%s\n%s\n' "$curr_cron" "$cron_cmd" | crontab -u root -; rv2=$?

	case $((rv1 & rv2)) in
		0) debugprint "Ok." ;;
		*) die "Error creating $job_type cron job!"
	esac
}


# remove existing cron job
# cron jobs are identified by the comment at the end of each job in crontab
rm_cron_job() {
	job_type="$1"

	case "$job_type" in
		autoupdate|persistence) ;;
		*) die "rm_cron_job: Error: unknown cron job type '$job_type'."
	esac

	debugprint "Removing $job_type cron job for ${proj_name}... "
	curr_cron="$(crontab -u root -l 2>/dev/null)"; rv1=$?
	printf '%s\n' "$curr_cron" | grep -v "${proj_name}-${job_type}" | crontab -u root -; rv2=$?

	case $((rv1 & rv2)) in
		0) debugprint "Ok." ;;
		*) die "Error: failed to remove $job_type cron job."
	esac
}


#### Variables

for entry in "CronSchedule schedule_conf" "DefaultSchedule schedule_default" "NoPersistence no_persistence" \
		"RebootSleep sleeptime" "Installdir install_dir" "Lists config_lists"; do
	getconfig "${entry% *}" "${entry#* }"
done

run_cmd="${install_dir}/${proj_name}-run.sh"

schedule="${schedule_conf:-$schedule_default}"


#### Checks

if [ "$schedule" != "disable" ] && [ ! "$no_persistence" ]; then
	# check cron service
	check_cron || { die "Error: cron seems to not be enabled." "Enable the cron service before using this script." \
			"Or install with options '-n' '-s disable' which will disable persistence and autoupdates."; }
fi


#### Main

printf %s "Processing cron jobs..."

# autoupdate job
case "$schedule" in
	disable) rm_cron_job "autoupdate" ;;
	*) create_cron_job "autoupdate"
esac

# persistence job
rm_cron_job "persistence"
case "$no_persistence" in
	'') create_cron_job "persistence" ;;
	*) printf '%s\n%s\n' "Note: no-persistence option was specified during installation. Geoip blocking will likely be deactivated upon reboot." \
		"To enable persistence, run the *install script again without the '-n' option." >&2
esac

echo "Ok."
exit 0
