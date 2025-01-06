#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154

# check-ip-in-source.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
export manmode=1 nolog=1 LC_ALL=C POSIXLY_CORRECT=YES
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

set_path() {
	var_name="$1"
	case "$var_name" in *[a-zA-Z0-9_]*) ;; *) printf '%s\n' "set_path: invalid var name '$var_name'"; exit 1; esac
	f_name="$2"
	dir1="$script_dir"
	dir2="$3"
	for dir in "$dir1" "$dir2"; do
		[ -f "$dir/$f_name" ] && {
			eval "${var_name}_path=\"$dir/$f_name\""
			break
		}
	done || { printf '%s\n' "Error: Can not find '$f_name'."; exit 1; }
}

# set $geoinit_path, $fetch_path
for f_opts in "geoinit ${p_name}-geoinit.sh /usr/bin" "fetch ${p_name}-fetch.sh /usr/bin"; do
	set_path $f_opts
done

. "$geoinit_path" || exit 1

# set $cca2_path
set_path cca2 cca2.list "$conf_dir"


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <country_code> -i <"IP [IP ... IP]"> [-u <ripe|ipdeny|maxmind>] [-d] [-h]

For each of the specified IP addresses, checks whether it belongs to one of the subnets
    in the list fetched from a source (RIPE or ipdeny or MaxMind) for a given country code.
Accepts a mix of ipv4 and ipv6 addresses.

Requires the 'grepcidr' utility

Options:
  -c <country_code>        : 2-letter country code
  -i <"ip_addresses">      : IP addresses to check
                             if specifying multiple addresses, use double quotes
  -u <ripe|ipdeny|maxmind> : Source to check in. By default checks in RIPE.

  -d                       : Debug
  -h                       : This help

EOF
}


#### Parse args

while getopts ":c:i:u:dh" opt; do
	case $opt in
	c) ccode=$OPTARG ;;
	i) ips=$OPTARG ;;
	u) source_arg=$OPTARG ;;
	d) debugmode_arg=1 ;;
	h) usage; exit 0 ;;
	*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

setdebug


#### Functions

die() {
	rm -f "$list_file" "$fetch_res_file"
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
valid_sources="ripe ipdeny maxmind"
default_source=ripe


#### Variables

tolower source_arg
dl_source="${source_arg:-"$default_source"}"
toupper ccode
ip_check_rv=0


#### Checks

check_deps grepcidr || die

[ -z "$ccode" ] && { usage; die "Specify country code with '-c <country_code>'."; }
[ "$(printf %s "$ccode" | wc -w)" -gt 1 ] && { usage; die "Specify only one country code."; }

validate_ccode "$ccode" "$cca2_path"; rv=$?
case "$rv" in
	1) die ;;
	2) usage; die "Invalid country code: '$ccode'."
esac

checkvars dl_source
[ "$(printf %s "$dl_source" | wc -w)" -gt 1 ] && { usage; die "Specify only one source."; }

subtract_a_from_b "$valid_sources" "$dl_source" invalid_source
[ -n "$invalid_source" ] && { usage; die "Invalid source: $invalid_source"; }

[ -z "$ips" ] && { usage; die "Specify the IP addresses to check with '-i <\"ip_addresses\">'."; }

# remove duplicates etc
san_str ips || die


#### Main

for ip in $ips; do
	# populates variables: $families, $val_ipv4s, $val_ipv6s
	validate_ip "$ip" || add2list invalid_ips "$ip"
done

[ -z "$val_ipv4s$val_ipv6s" ] && die "All IP addresses failed validation."
[ -z "$families" ] && die "\$families variable is empty."

if [ "$dl_source" = maxmind ]; then
	setup_maxmind || die
fi

### Fetch the IP list file

for family in $families; do
	eval "val_ips=\"\$val_${family}s\""

	list_id="${ccode}_${family}"
	fetch_res_file="/tmp/fetch-res-$list_id.tmp"

	list_file="/tmp/iplist-$list_id.tmp"

	/bin/sh "$fetch_path" -r -l "$list_id" -o "$list_file" -s "$fetch_res_file" -u "$dl_source" || die "$FAIL fetch IP lists."

	# read fetch results from fetch_res_file
	getstatus "$fetch_res_file" || die "$FAIL read fetch results from file '$fetch_res_file'."

	[ -n "$failed_lists" ] && die "IP list fetch failed."

	### Test the fetched list for specified IPs

	printf '\n%s\n' "Checking the IP addresses..."

	for val_ip in $val_ips; do
		unset match no
		filtered_ip="$(printf '%s\n' "$val_ip" | grepcidr -f "$list_file")"; rv=$?
		[ "$rv" -gt 1 ] && die "grepcidr returned error code '$grep_rv'."
		[ "$rv" =  1 ] && { no="no"; ip_check_rv=$((ip_check_rv+1)); }
		add2list "${no}match_ips" "$val_ip" "$_nl"
	done
	rm -f "$list_file" "$fetch_res_file"
done

match="Included"
nomatch="Not included"
match_color="$green"
nomatch_color="$red"
toupper dl_src_uc "$dl_source"
msg_pt2="in ${dl_src_uc}'s IP list for country '$ccode':"

printf '\n%s\n' "${purple}Results:${n_c}"

for m in match nomatch; do
	eval "[ -n \"\$${m}_ips\" ] && printf '\n%s\n%s\n' \"\$$m $msg_pt2\" \"\$${m}_color\${${m}_ips%$_nl}$n_c\""
done

[ -n "$invalid_ips" ] && {
	printf '\n%s\n%s\n' "${red}Invalid${n_c} IP addresses:" "$purple${invalid_ips% }$n_c"
	ip_check_rv=$((ip_check_rv+1))
}

echo

exit "$ip_check_rv"
