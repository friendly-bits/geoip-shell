#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-cronsetup.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/lib/${p_name}-common.sh" || exit 1
[ "$_OWRT_install" ] && { . "$script_dir/${p_name}-owrt-common.sh" || exit 1; }

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

	[ -z "$config_lists" ] && die "$ERR Countries list in the config file is empty! No point in creating autoupdate job."

	case "$job_type" in
		autoupdate)
			[ -z "$schedule" ] && die "$ERR cron schedule in the config file is empty!"
			# Validate cron schedule
			debugprint "\nValidating cron schedule: '$schedule'."
			call_script "$install_dir/validate-cron-schedule.sh" -x "$schedule"; rv=$?
			case "$rv" in
				0) debugprint "Successfully validated cron schedule: '$schedule'." ;;
				*) die "Error validating cron schedule '$schedule'."
			esac

			# Remove existing autoupdate cron job before creating new one
			rm_cron_job "autoupdate"
			cron_cmd="$schedule \"$run_cmd\" update 1>/dev/null 2>/dev/null # ${p_name}-autoupdate"
			debugprint "Creating autoupdate cron job with schedule '$schedule'... "
		;;

		persistence)
			debugprint "Creating persistence cron job... "

			# using the restore action for the *run script
			cron_cmd="@reboot sleep $sleeptime && \"$run_cmd\" restore 1>/dev/null 2>/dev/null # ${p_name}-persistence"
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
		*) die "rm_cron_job: $ERR unknown cron job type '$job_type'."
	esac

	debugprint "Removing $job_type cron job for $p_name... "
	curr_cron="$(crontab -u root -l 2>/dev/null)"; rv1=$?
	printf '%s\n' "$curr_cron" | grep -v "${p_name}-${job_type}" | crontab -u root -; rv2=$?

	case $((rv1 & rv2)) in
		0) debugprint "Ok." ;;
		*) die "$ERR failed to remove $job_type cron job."
	esac
}


#### Variables

for entry in "CronSchedule schedule_conf" "NoPersistence no_persist" \
		"RebootSleep sleeptime" "Lists config_lists"; do
	getconfig "${entry% *}" "${entry#* }"
done

run_cmd="${install_dir}/${p_name}-run.sh"

schedule="${schedule_conf:-$default_schedule}"


#### Checks

check_cron_compat

#### Main

printf %s "Processing cron jobs..."

# autoupdate job
case "$schedule" in
	disable) rm_cron_job autoupdate ;;
	*) create_cron_job autoupdate
esac

# persistence job
[ ! "$_OWRTFW" ] && {
	rm_cron_job persistence
	case "$no_persist" in
		'') create_cron_job persistence ;;
		*) printf '%s\n%s\n' "Note: no-persistence option was specified during installation. Geoip blocking will likely be deactivated upon reboot." \
			"To enable persistence, install $p_name again without the '-n' option." >&2
	esac
}

OK
exit 0
