#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-apply.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

## Initial setup
p_name="geoip-shell"
. "/usr/bin/${p_name}-geoinit.sh" &&
. "$_lib-arrays.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

## USAGE

usage() {
cat <<EOF

Usage: $me <action> [-D $direction_syn -l <"list_ids">] [-s] [-d] [-V] [-h]
Switches geoip blocking on/off, or loads/removes ip sets and firewall rules for specified lists.

Actions:
  on|off     :  Enable or disable the geoip blocking chain (via a rule in the base chain)
  add|remove :  Add or remove ip sets and firewall rules for lists specified with the '-l' option
  update     :  Update auxiliary geoblocking rules based on current config

Options:
  -D $direction_syn : $direction_usage
  -l <"list_ids">       : $list_ids_usage

  -s : skip adding new ipsets (only create rules). Only for the iptables backend.
  -d : Debug
  -V : Version
  -h : This help

EOF
}

die_a() {
	destroy_tmp_ipsets
	set +f; rm -f "$iplist_dir/"*.iplist; set -f
	die "$@"
}

# populates $counter_val for rule $1
# 2 - family
get_counter_val() {
	[ "$counters_set" ] || {
		debugprint "get_counter_val: counters not set"
		return 0
	}
	enc_rule="$(printf %s "$1" | encode_rules -n "$2")"
	case "$enc_rule" in
		*[!A-Za-z0-9_]*)
			debugprint "get_counter_val: Error: invalid characters in encoded rule '$enc_rule' for rule '$1'"
			counter_val='' ;;
		'')
			debugprint "get_counter_val: Error: got empty string for rule '$1'"
			counter_val='' ;;
		*) eval "counter_val=\"\$$enc_rule\""
			# debugprint "enc_rule: '$enc_rule'"
	esac

	case "$_fw_backend" in
		nft)
			case "$counter_val" in
				packets*bytes*)
					# debugprint "counter val for rule '$1': '$counter_val'"
					: ;;
				*)
					debugprint "Invalid/empty counter val '$counter_val' for rule '$1'"
					counter_val="packets 0 bytes 0"
			esac ;;
		ipt)
			case "$counter_val" in
				\[*:*\])
					# debugprint "counter val for rule '$1': '$counter_val'"
					: ;;
				*)
					debugprint "Invalid/empty counter val '$counter_val' for rule '$1'"
					counter_val="[0:0]"
			esac
	esac
	:
}

## PARSE ARGUMENTS

parse_iplist_args() {
	case "$action" in add|remove) ;; *) usage; die "Option '-l' can only be used with the 'add' and 'remove' actions."; esac
	case "$direction" in
		inbound|outbound)
			eval "[ -n \"\$${direction}_list_ids_arg\" ]" && die "Option '-l' can not be used twice for direction '$direction'."
			eval "${direction}_list_ids_arg"='$OPTARG' ;;
		*) usage; die "Specify direction (inbound|outbound) to use with the '-l' option."
	esac
	req_direc_opt=
}

# check for valid action
tolower action "$1"
case "$action" in
	add|remove|on|off|update) shift ;;
	*) unknownact
esac

# process the rest of the args
unset skip_ipsets req_direc_opt
while getopts ":D:l:sdVh" opt; do
	case $opt in
		D) case "$OPTARG" in
				inbound|outbound)
					case "$action" in add|remove) ;; *)
						usage
						die "Action is '$action', but direction-dependent options require the action to be 'add|remove'."
					esac
					[ "$req_direc_opt" ] && { usage; die "Provide valid options for the '$direction' direction."; }
					direction="$OPTARG"
					req_direc_opt=1 ;;
				*) usage; die "Use 'inbound|outbound' with the '-D' option"
			esac ;;
		s) skip_ipsets=1 ;;
		l) parse_iplist_args ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

[ "$req_direc_opt" ] && { usage; die "Provide valid options for direction '$direction'."; }

extra_args "$@"

is_root_ok
setdebug
debugentermsg

## VARIABLES

get_config_vars

case "$inbound_list_ids_arg$outbound_list_ids_arg" in
	'')
		case "$action" in update|on|off) ;; *)
			usage
			die 254 "Specify iplist id's!"
		esac ;;
	*)
		case "$action" in update|on|off)
			usage
			die 254 "Action '$action' is incompatible with option '-l'."
		esac
esac

for direction in inbound outbound; do
	eval "
		if [ -n \"\$${direction}_list_ids_arg\" ]; then
			${direction}_list_ids=\"\$${direction}_list_ids_arg\"
		else
			${direction}_list_ids=\"\$${direction}_iplists\"
		fi"
done

debugprint "inbound list id's: '$inbound_list_ids', outbound list id's: '$outbound_list_ids'"

geotag_aux="${geotag}_aux"

## CHECKS

checkvars datadir inbound_geomode outbound_geomode ifaces _fw_backend noblock iplist_dir

[ "$ifaces" != all ] && {
	all_ifaces="$(detect_ifaces)" || die "$FAIL detect network interfaces."
	nl2sp all_ifaces
	subtract_a_from_b "$all_ifaces" "$ifaces" bad_ifaces
	[ "$bad_ifaces" ] && die "Network interfaces '$bad_ifaces' do not exist in this system."
}

## MAIN

debugprint "loading the $_fw_backend library..."
. "$_lib-$_fw_backend.sh" || exit 1

get_counters

case "$action" in
	on) geoip_on; exit ;;
	off) geoip_off; exit
esac

[ -n "$iplist_dir" ] && mkdir -p "$iplist_dir"

debugprint "calling apply_rules()"

apply_rules
