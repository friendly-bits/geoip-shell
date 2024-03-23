#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154

# check-ip-in-source.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export manmode=1
. "$script_dir/${p_name}-geoinit.sh" || exit 1
. "$_lib-ip-regex.sh"


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <country_code> -i <"ip [ip ... ip]"> [-u ripe|ipdeny] [-d] [-h]

For each of the specified ip addresses, checks whether it belongs to one of the subnets
    in the list fetched from a source (either RIPE or ipdeny) for a given country code.
Accepts a mix of ipv4 and ipv6 addresses.

Requires the 'grepcidr' utility

Options:
  -c <country_code>    : 2-letter country code
  -i <"ip_addresses">  : ip addresses to check
                         if specifying multiple addresses, use double quotes
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
	rm -f "$list_file" "$status_file" 2>/dev/null
	printf '\n%s\n\n' "$*" >&2
	exit 1
}

validate_ip() {
	val_ip=
	for family in ipv4 ipv6; do
		eval "regex=\"^\$${family}_regex$\""
		[ -z "$regex" ] && die "$FAIL load regex's."
		printf '%s\n' "$1" | grep -Ei "$regex" 1>/dev/null &&
			{ add2list families "$family "; add2list "val_${family}s" "$1"; val_ip="$1"; return 0; }
	done

	return 1
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

# remove duplicates etc
san_str -s ips


#### Main

for ip in $ips; do
	# populates variables: $families, $val_ipv4s, $val_ipv6s
	validate_ip "$ip" || add2list invalid_ips "$ip"
done

[ -z "$val_ipv4s$val_ipv6s" ] && die "All ip addresses failed validation."
[ -z "$families" ] && die "\$families variable is empty."

### Fetch the ip list file

for family in $families; do
	eval "val_ips=\"\$val_${family}s\""

	list_id="${ccode}_${family}"
	status_file="/tmp/fetched-status-$list_id.tmp"

	list_file="/tmp/iplist-$list_id.tmp"

	sh "$fetch_script" -r -l "$list_id" -o "$list_file" -s "$status_file" -u "$dl_source" || die "$FAIL fetch ip lists."

	# read *fetch results from the status file
	getstatus "$status_file" "FailedLists" failed_lists ||
		die "Couldn't read value for 'FailedLists' from status file '$status_file'."

	[ -n "$failed_lists" ] && die "ip list fetch failed."

	### Test the fetched list for specified ip's

	printf '\n%s\n' "Checking the ip addresses..."

	for val_ip in $val_ips; do
		unset match no
		filtered_ip="$(printf '%s\n' "$val_ip" | grepcidr -f "$list_file")"; rv=$?
		[ "$rv" -gt 1 ] && die "grepcidr returned error code '$grep_rv'."
		[ "$rv" =  1 ] && { no="no"; ip_check_rv=$((ip_check_rv+1)); }
		add2list "${no}match_ips" "$val_ip" "$_nl"
	done
	rm -f "$list_file" "$status_file" 2>/dev/null
done

match="Included"
nomatch="Not included"
match_color="$green"
nomatch_color="$red"
msg_pt2="in $(toupper "$dl_source")'s ip list for country '$ccode':"

printf '\n%s\n' "${purple}Results:${n_c}"

for m in match nomatch; do
	eval "[ -n \"\$${m}_ips\" ] && printf '\n%s\n%s\n' \"\$$m $msg_pt2\" \"\$${m}_color\${${m}_ips%$_nl}$n_c\""
done

[ -n "$invalid_ips" ] && {
	printf '\n%s\n%s\n' "${red}Invalid${n_c} ip addresses:" "$purple${invalid_ips% }$n_c"
	ip_check_rv=$((ip_check_rv+1))
}

echo

exit "$ip_check_rv"
