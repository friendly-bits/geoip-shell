#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-apply.sh

# Copyright: friendly bits
# github.com/friendly-bits

## Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${p_name}-common.sh" || exit 1

check_root

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


## USAGE

usage() {
cat <<EOF

Usage: $me <action> [-l <"list_ids">] [-d] [-h]
Switches geoip blocking on/off, or loads/removes ip sets and firewall rules for specified lists.

Actions:
  on|off           : enable or disable the geoip blocking chain (via a rule in the base chain)
  add|remove       : Add or remove ip sets and firewall rules for lists specified with the '-l' option

Options:
  -l <"list_ids">  : iplist id's in the format <country_code>_<family> (if specifying multiple list id's, use double quotes)

  -d               : Debug
  -h               : This help

EOF
}

## PARSE ARGUMENTS

# check for valid action
action="$1"
case "$action" in
	add|remove|on|off|update) ;;
	* ) unknownact
esac

# process the rest of the args
shift 1
while getopts ":l:dh" opt; do
	case $opt in
		l) list_ids=$OPTARG ;;
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

echo

setdebug

debugentermsg

## VARIABLES

for entry in "Families families" "NoBlock noblock" "Geomode geomode" "PerfOpt perf_opt" \
		"Autodetect autodetect_opt" "Ifaces _ifaces" "tcp tcp_ports" "udp udp_ports" \
		"LanSubnets_ipv4 lan_subnets_ipv4" "LanSubnets_ipv6 lan_subnets_ipv6" \
		"TSubnets_ipv4 t_subnets_ipv4" "TSubnets_ipv6 t_subnets_ipv6"; do
	getconfig "${entry% *}" "${entry#* }"
done

iplist_dir="${datadir}/ip_lists"
status_file="$iplist_dir/status"

action="$(tolower "$action")"

geotag_aux="${geotag}_aux"

## CHECKS

[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."
[ ! "$datadir" ] && die "the \$datadir variable is empty."
[ ! "$geomode" ] && die "the \$geomode variable is empty."

[ "$_ifaces" ] && {
	all_ifaces="$(detect_ifaces)" || die "$FAIL detect network interfaces."
	nl2sp all_ifaces
	subtract_a_from_b "$all_ifaces" "$_ifaces" bad_ifaces ' '
	[ "$bad_ifaces" ] && die "Network interfaces '$bad_ifaces' do not exist in this system."
}

## MAIN

. "$_lib-apply-$_fw_backend.sh"
