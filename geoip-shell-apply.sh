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
	[ "$counters_set" ] || return 0
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
					debugprint "Invalid/empty counter val '$counter_val' for rule '$1', enc_rule '$enc_rule'"
					counter_val="packets 0 bytes 0"
			esac ;;
		ipt)
			case "$counter_val" in
				\[*:*\])
					# debugprint "counter val for rule '$1': '$counter_val'"
					: ;;
				*)
					debugprint "Invalid/empty counter val '$counter_val' for rule '$1', enc_rule '$enc_rule'"
					counter_val="[0:0]"
			esac
	esac
	:
}

# 1 - direction
# 2 - family
set_allow_ipset_vars() {
	eval "allow_ipset_name=\"\${allow_ipset_name_${1}_${2}}\""
	allow_iplist_file="$iplist_dir/$allow_ipset_name.iplist"
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

is_whitelist_present && [ "$autodetect" ] &&
	{ [ -s "${_lib}-detect-lan.sh" ] && . "${_lib}-detect-lan.sh" || die "$FAIL source the detect-lan script"; }


### compile allowlist ip's and write to file
for family in $families; do
	unset autodetected all_allow_ips_prev allow_iplist_file_prev
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue

		unset all_allow_ips res_subnets trusted lan_ips ll_addr

		allow_ipset_name="allow_${direction%bound}_${family#ipv}"
		allow_iplist_file="$iplist_dir/$allow_ipset_name.iplist"
		eval "allow_ipset_name_${direction}_${family}=\"$allow_ipset_name\""
		eval "allow_iplist_file_${direction}_${family}=\"$allow_iplist_file\""
		eval "allow_ipset_type_${direction}_${family}=ip"
		allow_ipset_type=ip


		rm -f "$allow_iplist_file"

		[ "$geomode" = whitelist ] && {
			eval "allow_ipset_type_${direction}_${family}=net"
			allow_ipset_type=net

			## load or detect lan ip's
			if [ "$autodetect" ] && [ "$autodetected" ]; then
				res_subnets=
				get_lan_subnets "$family" || die
				autodetected=1
				[ "$res_subnets" ] && nl2sp "lan_ips_$family" "net:$res_subnets"
				lan_ips="$res_subnets"
			else
				eval "lan_ips=\"\${lan_ips_$family}\""
				lan_ips="${lan_ips#*":"}"
				sp2nl lan_ips
			fi

			## set link-local subnets
			case "$family" in
				ipv6) ll_addr="fe80::/10" ;;
				ipv4) ll_addr="169.254.0.0/16"
			esac
		}

		eval "trusted=\"\$trusted_$family\""

		case "$trusted" in net:*|ip:*)
			ips_type="${trusted%%":"*}"
			trusted="${trusted#*":"}"
		esac

		if [ -n "$trusted" ]; then
			[ "$ips_type" = net ] && {
				allow_ipset_type=net
				eval "allow_ipset_type_${direction}_${family}=net"
			}
			sp2nl trusted
		fi


		cat_cnt=0
		for cat in trusted lan_ips ll_addr; do
			eval "cat_ips=\"\${$cat}\""
			[ ! "$cat_ips" ] && continue
			cat_cnt=$((cat_cnt+1))
			all_allow_ips="$all_allow_ips${cat_ips%"${_nl}"}$_nl"
		done

		[ "$all_allow_ips" ] || continue

		if [ "$all_allow_ips" != "$all_allow_ips_prev" ]; then
			all_allow_ips_prev="$all_allow_ips"
			allow_iplist_file_prev="$allow_iplist_file"

			# aggregate allowed ip's/subnets
			res_subnets=
			if [ "$_fw_backend" = ipt ] && [ $cat_cnt -ge 2 ] && [ "$allow_ipset_type" = net ] &&
				allow_hex="$(printf %s "$all_allow_ips" | ips2hex "$family")" &&
				[ "$allow_hex" ] &&
				aggregate_subnets "$family" "$allow_hex" && [ "$res_subnets" ]
			then
				:
			else
				res_subnets="$all_allow_ips"
			fi

			[ "$res_subnets" ] && {
				printf '%s\n' "$res_subnets" > "$allow_iplist_file" || die "$FAIL write to file '$allow_iplist_file'"
				debugprint "res_subnets:${_nl}'$res_subnets'"
			}
		else
			# if allow ip's are identical for inbound and outbound, use same ipset for both
			allow_ipset_name="allow_${family#ipv}"
			allow_iplist_file="$iplist_dir/$allow_ipset_name.iplist"
			for dir in inbound outbound; do
				eval "allow_ipset_name_${dir}_${family}=\"$allow_ipset_name\"
					allow_iplist_file_${dir}_${family}=\"$allow_iplist_file\""
			done

			mv "$allow_iplist_file_prev" "$allow_iplist_file" || die "$FAIL rename file '$allow_iplist_file'"
		fi
	done
done

debugprint "calling apply_rules()"

apply_rules
rv_apply=$?

[ "$autodetect" ] && {
	[ "$lan_ips_ipv4" ] && setconf_lan=lan_ips_ipv4
	[ "$lan_ips_ipv6" ] && setconf_lan="$setconf_lan lan_ips_ipv6"
	[ "$setconf_lan" ] && setconfig $setconf_lan
}

exit $rv_apply
