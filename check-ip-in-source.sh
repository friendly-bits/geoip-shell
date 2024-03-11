#!/bin/sh
# shellcheck disable=SC2317,SC2034,SC1090,SC2154

# check-ip-in-source.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export manmode=1
. "$script_dir/${p_name}-common.sh" || exit 1
. "$_lib-ip-regex.sh"


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <country_code> -i <"ip [ip ... ip]"> [-u ripe|ipdeny] [-d] [-h]

For each of the specified ip addresses, checks whether it belongs to one of the subnets
    in the list fetched from a source (either RIPE or ipdeny) for a given country code.
Accepts a mix of ipv4 and ipv6 addresses.

Requires the 'grepcidr' utility, '${p_name}-fetch.sh', '${p_name}-common.sh', 'cca2.list'

Options:
  -c <country_code>    : Country code (ISO 3166-1 alpha-2)
  -i <"ip_addresses">  : ip addresses to check
                         - if specifying multiple addresses, use double quotes
  -u <ripe|ipdeny>     : Source to check in. By default checks in RIPE.

  -d                   : Debug
  -h                   : This help

EOF
}


#### Parse args

while getopts ":c:i:u:dh" opt; do
	case $opt in
	c) ccode=$OPTARG ;;
	i) ips=$OPTARG ;;
	u) source_arg=$OPTARG ;;
	d) debugmode_args=1 ;;
	h) usage; exit 0 ;;
	*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

setdebug


#### Functions

die() {
	rm "$list_file" "$status_file" 2>/dev/null
	printf '\n%s\n\n' "$*" >&2
	exit 1
}

process_grep_results() {
# takes grep return value $1 and grep output string $2,
# converts these results into a truth table,
# then calculates the validation result based on the truth table sum
# the idea is to cross-reference both values in order to avoid erroneous validation results

	grep_rv="$1"
	grep_output="$2"

	# convert 'grep return value' and 'grep output value' resulting value into truth table inputs
	[ "$grep_rv" -ne 0 ] && rv1=1 || rv1=0
	[ -z "$grep_output" ] && rv2=2 || rv2=0

	# calculate the truth table sum
	truth_table_result=$((rv1 + rv2))
	return "$truth_table_result"
}

validate_ip() {
	validated_ip=''
	printf '%s\n' "$1" | grep -E "^$ipv4_regex$" 1>/dev/null 2>/dev/null; rv=$?
	if [ "$rv" = 0 ]; then families="${families}ipv4 "; validated_ip="$1"; validated_ipv4s="${validated_ipv4s}$1 "; return 0
	else
		printf '%s\n' "$1" | grep -Ei "^$ipv6_regex$" 1>/dev/null 2>/dev/null; rv=$?
		if [ "$rv" = 0 ]; then families="${families}ipv6 "; validated_ip="$1"; validated_ipv6s="${validated_ipv6s}$1 "; return 0
		else return 1
		fi
	fi
}


#### Constants

export nolog=1

fetch_script="$p_script-fetch.sh"

valid_sources="ripe${_nl}ipdeny"
default_source="ripe"


#### Variables

source_arg="$(tolower "$source_arg")"
dl_source="${source_arg:-"$default_source"}"
ccode="$(toupper "$ccode")"
ip_check_rv=0


#### Checks

check_deps grepcidr || die

[ -z "$ccode" ] && { usage; die "Specify country code with '-c <country_code>'."; }
[ "$(printf %s "$ccode" | wc -w)" -gt 1 ] && { usage; die "Specify only one country code."; }

validate_ccode "$ccode" "$script_dir/cca2.list"; rv=$?
case "$rv" in
	1) die ;;
	2) usage; die "Invalid country code: '$ccode'."
esac

[ "$(printf %s "$dl_source" | wc -w)" -gt 1 ] && { usage; die "Specify only one source."; }
[ -z "$dl_source" ] && die "'\$dl_source' variable should not be empty!"

subtract_a_from_b "$valid_sources" "$dl_source" invalid_source
[ -n "$invalid_source" ] && { usage; die "Invalid source: $invalid_source"; }

[ -z "$ips" ] && { usage; die "Specify the ip addresses to check with '-i <\"ip_addresses\">'."; }

[ ! -f "$fetch_script" ] && die "Can not find '$fetch_script'."

# convert ips to upper case and remove duplicates etc
san_str -s ips "$(toupper "$ips")"


#### Main

printf '\n'

for ip in $ips; do
	# validate the ip address by grepping it with the pre-defined validation regex
	# also populates variables: $families, $validated_ipv4s, $validated_ipv6s
	validate_ip "$ip"; rv=$?

	# process grep results
	process_grep_results "$rv" "$validated_ip"; true_grep_rv=$?

	case "$true_grep_rv" in
		0) ;;
		1) die "grep reported an error but returned a non-empty '\$validated_ip'. Something is wrong." ;;
		2) die "grep didn't report any error but returned an empty '\$validated_ip'. Something is wrong." ;;
		3) invalid_ips="$invalid_ips$ip " ;;
		*) die "unexpected \$true_grep_rv: '$true_grep_rv'. Something is wrong." ;;
	esac
done

# trim extra whitespaces
invalid_ips="${invalid_ips% }"
san_str -s families "$families"

if [ -z "$validated_ipv4s$validated_ipv6s" ]; then
	echo
	die "all ip addresses failed validation."
fi

### Fetch the ip list file

[ -z "$families" ] && die "\$families variable is empty."

for family in $families; do
	case "$family" in
		ipv4 ) validated_ips="${validated_ipv4s% }" ;;
		ipv6 ) validated_ips="${validated_ipv6s% }" ;;
		* ) die "unexpected family: '$family'." ;;
	esac

	list_id="${ccode}_${family}"
	status_file="/tmp/fetched-status-$list_id.tmp"

	list_file="/tmp/iplist-$list_id.tmp"

	sh "$fetch_script" -r -l "$list_id" -o "$list_file" -s "$status_file" -u "$dl_source" ||
		die "$FAIL fetch ip lists."

	# read *fetch results from the status file
	getstatus "$status_file" "FailedLists" failed_lists ||
		die "Couldn't read value for 'failed_lists' from status file '$status_file'."

	[ -n "$failed_lists" ] && die "ip list fetch failed."

	### Test the fetched list for specified ip's

	printf '\n%s\n' "Checking ip addresses..."

	for validated_ip in $validated_ips; do
		unset match
		filtered_ip="$(printf '%s\n' "$validated_ip" | grepcidr -f "$list_file")"; rv=$?
		[ "$rv" -gt 1 ] && die "grepcidr returned error code '$grep_rv'."

		# process grep results
		process_grep_results "$rv" "$filtered_ip"; true_grep_rv=$?

		case "$true_grep_rv" in
			0) no='' ;;
			1) die "grepcidr reported an error but returned a non-empty '\$filtered_ip'. Something is wrong." ;;
			2) die "grepcidr didn't report any error but returned an empty '\$filtered_ip'. Something is wrong." ;;
			3) no="no" ;;
			*) die "unexpected \$true_grep_rv: '$true_grep_rv'. Something is wrong."
		esac

		eval "${no}match_ips=\"\${${no}match_ips}$validated_ip$_nl\""

		# increment the return value if matching didn't succeed
		[ "$true_grep_rv" != 0 ] && ip_check_rv=$((ip_check_rv+1))
	done
	rm "$list_file" "$status_file" 2>/dev/null
done

match="${green}*BELONG*${n_c}"
nomatch="${red}*DO NOT BELONG*${n_c}"
msg_pt2="to a subnet in $(toupper "$dl_source")'s list for country '$ccode':"

printf '\n%s\n' "${yellow}Results:${n_c}"

for m in match nomatch; do
	eval "if [ -n \"\$${m}_ips\" ]; then printf '\n%s\n%s\n' \"\$$m $msg_pt2\" \"\${${m}_ips%$_nl}\"; fi"
done

if [ -n "$invalid_ips" ]; then
	printf '\n%s\n%s\n' "${red}Invalid${n_c} ip addresses:" "${invalid_ips% }"
	ip_check_rv=$((ip_check_rv+1))
fi

echo

exit "$ip_check_rv"
