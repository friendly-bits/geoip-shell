#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-cronsetup.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
geoinit="${p_name}-geoinit.sh"
for geoinit_path in "$script_dir/$geoinit" "/usr/bin/$geoinit"; do
	[ -f "$geoinit_path" ] && break
done
. "$geoinit_path" || exit 1

nolog=1


#### USAGE

usage() {
cat <<EOF
v$curr_ver

Usage: $me [-x <"expression">] [-d] [-h]
Validates a cron expression, or loads cron-related config from the config file and sets up cron jobs for geoip blocking accordingly.

Options:
  -x <"expr"> : validate cron expression
  -d          : Debug
  -h          : This help

EOF
}

val_cron_exp() {
	sourceline="$(tolower "$1")"

	# Functions

	reg_err() {
		err=1
		errstr="$errstr$1$_nl"
	}

	print_tip() {
		printf '%s\n%s\n%s\n' "Crontab expression format: 'minute hour day-of-month month day-of-week'." \
			"Valid example: '15 4 * * 6'." \
			"Use double quotes around your cron schedule expression." >&2
	}

	validateNum() {
		num="$1"; min="$2"; max="$3"
		case "$num" in
			'*' ) return 0 ;;
			''|*[!0-9]* ) return 1
		esac
		[ "$num" -le "$prevnum" ] && return 1
		prevnum="$num"
		return $(( num<min || num>max))
	}

	validateDay() {
		eval "case \"$1\" in
			$dow_values) abbr=1; return 0
		esac"
		return 1
	}

	validateMon() {
		eval "case \"$1\" in
			$mon_values) abbr=1; return 0
		esac"
		return 1
	}

	validateName() {
		case "$1" in
			"mon") validateMon "$2" ;;
			"dow") validateDay "$2" ;;
			*) return 1
		esac
	}

	# validates a field of the cron schedule (month, day of month, day of week, hour or minute)
	# 1 - field name
	# 2 - string
	# 3 - min val
	# 4 - max val
	validateField() {
		invalid_char() { reg_err "Invalid value '$1' in field '$fieldName': it $2 with '$3'."; }
		check_edge_chars() {
			case "${1%"${1#?}"}" in "$2") invalid_char "$1" "starts" "$2"; esac
			case "${1#"${1%?}"}" in "$2") invalid_char "$1" "ends" "$2"; esac
		}

		field_id="$1"
		eval "fieldName=\"\$$1\""
		fieldStr="$2"
		minval="$3"
		maxval="$4"

		segnum_field=0
		astnum_field=0

		check_edge_chars "$fieldStr" ","

		newifs ","
		for slice in $fieldStr; do
			check_edge_chars "$slice" "-"
			segnum=0 prevnum=$((minval-1)) abbr=
			IFS='-'
			for segment in $slice; do
				oldifs
				# try validating the segment as a number or an asterisk
				if ! validateNum "$segment" "$minval" "$maxval" ; then
					# if that fails, try validating the segment as a name or an asterisk
					if ! validateName "$field_id" "$segment"; then
						# if that fails, the segment is invalid
						eval "val_seg=\"\$${field_id}_values\""
						[ "$val_seg" ] && val_seg=", $val_seg"
						reg_err "Invalid segment '$segment' in field: $fieldName. Valid values: $minval-$maxval$val_seg."
					fi
				fi

				# count dash-separated segments in a slice
				segnum=$((segnum+1))
				# count all segments in a field
				segnum_field=$((segnum_field+1))
				# count asterisks in a field
				[ "$segment" = "*" ] && astnum_field=$((astnum_field+1))
			done

			[ "$segnum" -gt 2 ] || { [ "$segnum" -gt 1 ] && [ "$abbr" ]; } && reg_err "Invalid value '$slice' in $fieldName '$fieldStr'."
		done
		oldifs

		# if a field contains an asterisk then there should be only one segment
		case $(( astnum_field > 0 && segnum_field > 1 )) in 1)
			reg_err "Invalid $fieldName '$fieldStr'."
		esac
	}


	err=0
	errstr=
	mn=minute
	hr=hour
	dom="day of month"
	mon=month
	dow="day of week"
	dow_values="sun|mon|tue|wed|thu|fri|sat|'*'"
	mon_values="jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|'*'"

	#### Basic sanity check for input args

	# separate the input by spaces and store results in variables
	set -- $sourceline
	for field in mn_val hr_val dom_val mon_val dow_val; do
		case "$1" in
			'') printf '\n\n%s\n' "$me: $ERR Not enough fields in schedule expression." >&2
				print_tip; die ;;
			*) eval "$field"='$1'; shift
		esac
	done

	# check for extra args
	[ -n "$*" ] && {
		printf '\n\n%s\n' "$me: $ERR Too many fields in schedule expression." >&2
		print_tip
		die
	}

	for field in "mn $mn_val 0 59" "hr $hr_val 0 23" "dom $dom_val 1 31" "mon $mon_val 1 12" "dow $dow_val 0 6"; do
		set -- $field
		validateField "$1" "$2" "$3" "$4"
	done

	[ $err != 0 ] && {
		printf '\n\n%s\n%s\n\n' "$me: errors in cron expression:" "${errstr%"$_nl"}" >&2
		print_tip
	}

	return $err
}


#### PARSE ARGUMENTS
while getopts ":x:dh" opt; do
	case $opt in
		x) val_cron_exp "$OPTARG"; exit $? ;;
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

check_root
setdebug
debugentermsg


#### Functions

create_cron_job() {

	job_type="$1"

	[ -z "$config_lists" ] && die "Countries list in the config file is empty! No point in creating autoupdate job."

	case "$job_type" in
		autoupdate)
			[ -z "$schedule" ] && die "cron schedule in the config file is empty!"
			# Validate cron schedule
			debugprint "\nValidating cron schedule: '$schedule'."
			val_cron_exp "$schedule"; rv=$?
			case "$rv" in
				0) debugprint "Successfully validated cron schedule: '$schedule'." ;;
				*) die "$FAIL validate cron schedule '$schedule'."
			esac

			# Remove existing autoupdate cron job before creating new one
			rm_cron_job "autoupdate"
			cron_cmd="$schedule \"$run_cmd\" update -a 1>/dev/null 2>/dev/null # ${p_name}-autoupdate"
			debugprint "Creating autoupdate cron job with schedule '$schedule'... " ;;
		persistence)
			debugprint "Creating persistence cron job... "

			# using the restore action for the *run script
			cron_cmd="@reboot sleep $sleeptime && \"$run_cmd\" restore -a 1>/dev/null 2>/dev/null # ${p_name}-persistence" ;;
		*) die "Unrecognized type of cron job: '$job_type'."
	esac

	#### Create new cron job

	curr_cron="$(crontab -u root -l 2>/dev/null)"; rv1=$?
	printf '%s\n%s\n' "$curr_cron" "$cron_cmd" | crontab -u root -; rv2=$?

	case $((rv1 & rv2)) in
		0) debugprint "Ok." ;;
		*) die "$FAIL create $job_type cron job!"
	esac
}


# remove existing cron job
# cron jobs are identified by the comment at the end of each job in crontab
rm_cron_job() {
	job_type="$1"

	case "$job_type" in
		autoupdate|persistence) ;;
		*) die "rm_cron_job: unknown cron job type '$job_type'."
	esac

	debugprint "Removing $job_type cron job for $p_name... "
	curr_cron="$(crontab -u root -l 2>/dev/null)"; rv1=$?
	printf '%s\n' "$curr_cron" | grep -v "${p_name}-${job_type}" | crontab -u root -; rv2=$?

	case $((rv1 & rv2)) in
		0) debugprint "Ok." ;;
		*) die "$FAIL remove $job_type cron job."
	esac
}


#### Variables

for entry in "CronSchedule schedule_conf" "NoPersistence no_persist" \
		"RebootSleep sleeptime" "Lists config_lists"; do
	getconfig "${entry% *}" "${entry#* }"
done

run_cmd="$i_script-run.sh"

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
:
