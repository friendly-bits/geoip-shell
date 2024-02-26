#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2154,SC2086,SC1090,SC2089,SC2090

# validate_cron_schedule.sh

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/lib/${p_name}-common.sh" || exit 1

set -f

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

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

#### Parse args

while getopts ":x:h" opt; do
	case $opt in
	x) sourceline="$(tolower "$OPTARG")" ;;
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
errstr=''
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


#### Main

for field in "mn $mn_val 0 59" "hr $hr_val 0 23" "dom $dom_val 1 31" "mon $mon_val 1 12" "dow $dow_val 0 6"; do
	set -- $field
	validateField "$1" "$2" "$3" "$4"
done

[ $err != 0 ] && {
	printf '\n\n%s\n%s\n\n' "$me: errors in cron expression:" "${errstr%"$_nl"}" >&2
	print_tip
}

exit $err
