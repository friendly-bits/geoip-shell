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

. "$geoinit_path"


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <country_code> -i <"IP [IP ... IP]"> [-u <ripe|ipdeny|maxmind|ipinfo>] [-d] [-h]

For each of the specified IP addresses, checks whether it belongs to one of the IP ranges
    in the list fetched from a source (RIPE / ipdeny / MaxMind / IPinfo) for a given country code.
Accepts a mix of ipv4 and ipv6 addresses.

Requires the 'grepcidr' utility

Options:
  -c <country_code>               : 2-letter country code
  -i <"ip_addresses">             : IP addresses to check
                                    if specifying multiple addresses, use double quotes
  -u <ripe|ipdeny|maxmind|ipinfo> : Source to check in. By default checks in RIPE.

  -d  : Debug
  -h  : This help

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
	rm -rf "$GEOTEMP_DIR"
	die "$@"
}

validate_ip() {
	val_ip=
	for family in ipv4 ipv6; do
		eval "regex=\"^\$${family}_regex$\""
		[ -z "$regex" ] && die_l "$FAIL load regex's."
		printf '%s\n' "$1" | grep -Ei "$regex" 1>/dev/null &&
			{ add2list families "$family"; add2list "val_${family}s" "$1"; val_ip="$1"; return 0; }
	done

	return 1
}


load_cca2 "$script_dir/cca2.list" || die

#### Checks

check_deps grepcidr || die

validate_ccode ccode "$ccode_arg" || die "Specify one country code with '-c <country_code>'."

san_str ips || die
[ -z "$ips" ] && { usage; die "Specify IP addresses to check with '-i <\"ip_addresses\">'."; }


#### Main

ciis_conf_ok='' ciis_conf_found=''
[ -s "$CONF_FILE" ] && ciis_conf_found=1
ciis_cfg_keys="geosource mm_license_type mm_acc_id mm_license_key ipinfo_license_type ipinfo_token"

for ip in $ips; do
	# populates variables: $families, $val_ipv4s, $val_ipv6s
	validate_ip "$ip" || add2list invalid_ips "$ip"
done

[ -n "$val_ipv4s$val_ipv6s" ] || die "All IP addresses failed validation."
[ -n "$families" ] || die "\$families variable is empty."

#### DL Source
if [ -n "$src_arg" ]; then
	dl_src="$src_arg"
	[ "$(printf %s "$dl_src" | wc -w)" -gt 1 ] && { usage; die "Specify only one IP list source."; }
elif [ "$ROOT_OK" = 1 ] && [ -n "$ciis_conf_found" ]; then
	if nodie=1 load_config main "" "$ciis_cfg_keys" && [ -n "$geosource" ]; then
		dl_src="$geosource"
		ciis_conf_ok=1
	else
		ciis_conf_ok=0
	fi
fi
: "${dl_src:="$DEF_SRC_COUNTRY"}"
tolower dl_src
checkvars dl_src
is_included "$dl_src" "$VALID_SRCS_COUNTRY" || { usage; die "Invalid source: '$dl_src'"; }

case "${dl_src}" in maxmind|ipinfo)
	[ "$ROOT_OK" = 1 ] && [ -n "$ciis_conf_found" ] && [ -z "$ciis_conf_ok" ] &&
		EXPORT_CONF=1 nodie=1 load_config main "" "$ciis_cfg_keys"
esac

case "${dl_src}" in
	maxmind) [ "$mm_license_type" ] && [ "$mm_acc_id" ] && [ "$mm_license_key" ] || setup_maxmind ;;
	ipinfo) [ "$ipinfo_license_type" ] && [ "$ipinfo_token" ] || setup_ipinfo ;;
	*) : ;;
esac || die


### Fetch the IP list file

ciis_dir="${GEOTEMP_DIR:?}/ciis"

if [ "$ROOT_OK" = 1 ] && [ -n "$GEORUN_DIR" ]; then
	mk_lock || die_l
else
	export GEORUN_DIR="$ciis_dir"
fi

trap 'die_l' INT TERM HUP QUIT

dir_mk -n "$ciis_dir" || die_l

ip_check_rv=0
for family in $families; do
	printf '\n%s\n' "Checking $family IP addresses..."

	eval "val_ips=\"\$val_${family}s\""

	san_list_ids list_id "${ccode}_${family}" "country" || die_l
	[ -n "$list_id" ] || continue

	ciis_fetch_res_file="$ciis_dir/fetch-res-$list_id.tmp"
	list_file="$ciis_dir/$list_id.iplist"

	printf '' > "$ciis_fetch_res_file" &&
	call_script "$fetch_path" -t country -r -l "$list_id" -p "$ciis_dir" -s "$ciis_fetch_res_file" -u "$dl_src" ||
		die_l "$FAIL fetch IP lists."

	# read fetch results from ciis_fetch_res_file
	getstatus fetch_res "$ciis_fetch_res_file" || die_l "$FAIL read fetch results from file '$ciis_fetch_res_file'."

	[ -n "$failed_lists" ] && die_l "IP list fetch failed."

	### Test the fetched list for specified IPs

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
