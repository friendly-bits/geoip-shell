#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2154,SC2086,SC1090

# validate_cron_schedule.sh

#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1

set -f

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs

#### USAGE

usage() {
cat <<EOF

Usage: $me -x <"schedule_expression"> [-h]

Checks a cron schedule expression to ensure that it's formatted properly.
Expects standard cron notation of "minute hour day-of-month month day-of-week"
    where min is 0-59, hr 0-23, dom is 1-31, mon is 1-12 (or names) and dow is 0-7 (or names).
Supports month (Jan-Dec) and day-of-week (Sun-Sat) names.
Fields can have ranges (e.g. 5-8), lists separated by commas (e.g. Sun, Mon, Fri), or an asterisk for "any".

Options:
-x "expression"  : crontab schedule expression ***in double quotes***
                       example: "15 4 * * 6"
                       format: minute hour day-of-month month day-of-week
-h               : This help

EOF
}

#### Parse arguments

while getopts ":x:h" opt; do
	case $opt in
	x) sourceline=$OPTARG ;;
	h) usage; exit 0 ;;
	*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

debugentermsg

#### Functions

reg_err() {
	err=1
	errstr="$errstr$1$_nl"
}

print_tip() {
	printf '%s\n%s\n%s\n%s\n' "Crontab expression format: 'minute hour day-of-month month day-of-week'." \
		"You entered: '$sourceline'." \
		"Valid example: '15 4 * * 6'." \
		"Use double quotes around your cron schedule expression." >&2
}

validateNum() {
	num="$1"; min="$2"; max="$3"
	case "$num" in
		'*' ) return 0 ;;
		''|*[!0-9]* ) return 1
	esac
	return $(( num<min || num>max))
}

validateDay() {
	case $(tolower "$1") in
		sun|mon|tue|wed|thu|fri|sat|'*') return 0
	esac
	return 1
}

validateMon() {
	case $(tolower "$1") in
		jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|'*') return 0
	esac
	return 1
}

validateName() {
	fieldtype="$1"
	fieldvalue="$2"
	case "$fieldtype" in
		"month") validateMon "$fieldvalue"; return $? ;;
		"day of week") validateDay "$fieldvalue"; return $?
	esac
	return 1
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

	fieldName="$1"
	fieldStr="$2"
	minval="$3"
	maxval="$4"

	segnum_field=0
	astnum_field=0

	check_edge_chars "$fieldStr" ","

	newifs ","
	for slice in $fieldStr; do
		check_edge_chars "$slice" "-"
		segnum=0
		IFS='-'
		for segment in $slice; do
			oldifs
			# try validating the segment as a number or an asterisk
			if ! validateNum "$segment" "$minval" "$maxval" ; then
				# if that fails, try validating the segment as a name or an asterisk
				if ! validateName "$fieldName" "$segment"; then
					# if that fails, the segment is invalid
					reg_err "Invalid segment '$segment' in field: $fieldName."
				fi
			fi

			# count dash-separated segments in a slice
			segnum=$((segnum+1))
			# count all segments in a field
			segnum_field=$((segnum_field+1))
			# count asterisks in a field
			[ "$segment" = "*" ] && astnum_field=$((astnum_field+1))
		done

		[ "$segnum" -gt 2 ] && reg_err "Invalid value '$slice' in $fieldName '$fieldStr'."
	done
	oldifs

	# if a field contains an asterisk then there should be only one segment
	case $(( astnum_field > 0 && segnum_field > 1 )) in 1)
		reg_err "Invalid $fieldName '$fieldStr'."
	esac
}


err=0
errstr=''

#### Basic sanity check for input arguments

# separate the input by spaces and store results in variables
set -- $sourceline
for fieldCat in min hour dom mon dow; do
	case "$1" in
		'') printf '\n\n%s\n' "$me: Error: Not enough fields in schedule expression." >&2
			print_tip; die ;;
		*) eval "$fieldCat"='$1'; shift
	esac
done

# check for extra arguments
[ -n "$*" ] && {
	printf '\n\n%s\n' "$me: Error: Too many fields in schedule expression. I don't know what to do with '$*'." >&2
	print_tip
	die
}


#### Main

validateField "minute" "$min" "0" "60"
validateField "hour" "$hour" "0" "24"
validateField "day of month" "$dom" "1" "31"
validateField "month" "$mon" "1" "12"
validateField "day of week" "$dow" "1" "7"

[ $err != 0 ] && {
	printf '\n\n%s\n%s\n\n' "$me: errors in cron expression:" "${errstr%"$_nl"}" >&2
	print_tip
}

exit $err
