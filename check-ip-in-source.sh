#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154

# check-ip-in-source.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
export manmode=1 nolog=1 LC_ALL=C POSIXLY_CORRECT=YES
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

get_path() {
	var_name="$1"
	case "$var_name" in *[a-zA-Z0-9_]*) ;; *) printf '%s\n' "get_path: invalid var name '$var_name'" >&2; exit 1; esac
	f_name="$2"
	dir1="$script_dir"
	dir2="$3"
	for dir in "$dir1" "$dir2"; do
		[ -f "$dir/$f_name" ] && {
			eval "$var_name=\"$dir/$f_name\""
			break
		}
	done || { printf '%s\n' "Error: Can not find '$f_name'." >&2; exit 1; }
}

# set $geoinit_path, $fetch_path
get_path geoinit_path "${p_name}-geoinit.sh" /usr/bin
get_path fetch_path "${p_name}-fetch.sh" /usr/bin

. "$geoinit_path" || exit 1


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <country_code> -i <"IP [IP ... IP]"> [-u <ripe|ipdeny|maxmind>] [-d] [-h]

For each of the specified IP addresses, checks whether it belongs to one of the IP ranges
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
	c) ccode_arg=$OPTARG ;;
	i) ips=$OPTARG ;;
	u) src_arg=$OPTARG ;;
	d) debugmode_arg=1 ;;
	h) usage; exit 0 ;;
	*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

setdebug


#### Functions

die_l() {
	rm -f "$list_file" "$ciis_fetch_res_file"
	die "$@"
}

validate_ip() {
	val_ip=
	for family in ipv4 ipv6; do
		eval "regex=\"^\$${family}_regex$\""
		[ -z "$regex" ] && die_l "$FAIL load regex's."
		printf '%s\n' "$1" | grep -Ei "$regex" 1>/dev/null &&
			{ add2list families "$family "; add2list "val_${family}s" "$1"; val_ip="$1"; return 0; }
	done

	return 1
}


#### Constants
valid_srcs_country="ripe ipdeny maxmind"
default_src=ripe


#### Variables

tolower src_arg
dl_src="${src_arg:-"$default_src"}"
ip_check_rv=0


#### Checks

check_deps grepcidr || die_l

normalize_ccode ccode "$ccode_arg"
case $? in
	0) ;;
	2|3) usage; die_l "Invalid country code '$ccode_arg'. Specify one country code with '-c <country_code>'." ;;
	*) die_l
esac

checkvars dl_src
[ "$(printf %s "$dl_src" | wc -w)" -gt 1 ] && { usage; die_l "Specify only one source."; }

subtract_a_from_b "$valid_srcs_country" "$dl_src" invalid_src
[ -n "$invalid_src" ] && { usage; die_l "Invalid source: $invalid_src"; }

[ -z "$ips" ] && { usage; die_l "Specify the IP addresses to check with '-i <\"ip_addresses\">'."; }

# remove duplicates etc
san_str ips || die_l


#### Main

for ip in $ips; do
	# populates variables: $families, $val_ipv4s, $val_ipv6s
	validate_ip "$ip" || add2list invalid_ips "$ip"
done

[ -z "$val_ipv4s$val_ipv6s" ] && die_l "All IP addresses failed validation."
[ -z "$families" ] && die_l "\$families variable is empty."

if [ "$dl_src" = maxmind ]; then
	[ -s "$conf_file" ] && [ "$root_ok" ] && {
		nodie=1 getconfig mm_license_type
		nodie=1 getconfig mm_acc_id
		nodie=1 getconfig mm_license_key
		nodie=1 getconfig keep_mm_db
		export mm_license_type mm_acc_id mm_license_key keep_mm_db
	}
	[ "$mm_license_type" ] && [ "$mm_acc_id" ] && [ "$mm_license_key" ] || {
		setup_maxmind || die_l
	}
fi

### Fetch the IP list file

if [ -n "$root_ok" ] && [ -n "$GEORUN_DIR" ]; then
	mk_lock || die_l
else
	export GEORUN_DIR="/tmp/check-ip-in-source"
	export GEOTEMP_DIR="$GEORUN_DIR"
fi

trap 'die_l' INT TERM HUP QUIT

dir_mk -n "$GEORUN_DIR" || die_l

for family in $families; do
	eval "val_ips=\"\$val_${family}s\""

	list_id="${ccode}_${family}"
	ciis_fetch_res_file="$GEORUN_DIR/fetch-res-$list_id.tmp"
	list_file="$GEORUN_DIR/iplist-$list_id.tmp"

	printf '' > "$ciis_fetch_res_file" &&
	call_script "$fetch_path" -r -l "$list_id" -o "$list_file" -s "$ciis_fetch_res_file" -u "$dl_src" ||
		die_l "$FAIL fetch IP lists."

	# read fetch results from ciis_fetch_res_file
	getstatus "$ciis_fetch_res_file" || die_l "$FAIL read fetch results from file '$ciis_fetch_res_file'."

	[ -n "$failed_lists" ] && die_l "IP list fetch failed."

	### Test the fetched list for specified IPs

	printf '\n%s\n' "Checking $family IP addresses..."

	for val_ip in $val_ips; do
		unset match no
		filtered_ip="$(printf '%s\n' "$val_ip" | grepcidr -f "$list_file")"; rv=$?
		[ "$rv" -gt 1 ] && die_l "grepcidr returned error code '$grep_rv'."
		[ "$rv" =  1 ] && { no="no"; ip_check_rv=$((ip_check_rv+1)); }
		add2list "${no}match_ips" "$val_ip" "$_nl"
	done
	rm -f "$list_file" "$ciis_fetch_res_file"
done

match="Included"
nomatch="Not included"
match_color="$green"
nomatch_color="$red"
toupper dl_src_uc "$dl_src"
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

die_l "$ip_check_rv"
