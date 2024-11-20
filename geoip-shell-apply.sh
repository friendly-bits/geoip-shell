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

Usage: $me <action> [-s] [-d] [-V] [-h]
Switches geolocking on/off, creates or modifies ipsets and firewall rules for configured ip lists.

Actions:
  on|off  :  Enable or disable the geoblocking chain (via a rule in the base chain)
  add     :  Recreate geoblocking rules based on config and add missing ipsets, loading them from files
  update  :  Recreate geoblocking rules based on config, loading ipsets from files
  restore :  Recreate geoblocking rules based on config, re-using existing ipsets

  Actions add, update and restore automatically remove ipsets which are no longer needed.

Options:
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
	[ "$counters_set" ] || { counter_val=''; return 0; }
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
					;;
				*)
					debugprint "Invalid/empty counter val '$counter_val' for rule '$1', enc_rule '$enc_rule'"
					counter_val="packets 0 bytes 0"
			esac ;;
		ipt)
			case "$counter_val" in
				\[*:*\])
					# debugprint "counter val for rule '$1': '$counter_val'"
					;;
				*)
					debugprint "Invalid/empty counter val '$counter_val' for rule '$1', enc_rule '$enc_rule'"
					counter_val="[0:0]"
			esac
	esac
	:
}

# 1 - ipset name
# assigns results to $list_id, $ipset_family
get_ipset_id() {
	case "$1" in *"_dhcp"*|*"_allow"*) i="$1" ;; *) i="${1%_*}"; esac
	[ "$_fw_backend" = ipt ] && i="${i#*_}"
	ipset_family="ipv${i##*_}"
	list_id="${i%_*}_${ipset_family}"
	case "$ipset_family" in
		ipv4|ipv6) ;;
		*) echolog -err "ip set name '$1' has unexpected format."
			unset ipset_family list_id
			return 1
	esac
	:
}

# 1 - var name
# 2 - list id
# assigns result to var named $1
get_ipset_name() {
	eval "list_date=\"\$prev_date_${list_id}\""
	case "$1" in *"_dhcp"*|*"_allow"*) ;; *)
		[ "$list_date" ] || {
				echolog -err "The status file '$status_file' contains no information for list id '${list_id}'."
				return 1
		}
		date_suffix="_${list_date}"
	esac
	[ "$2" ] || { echolog -err "get_ipset_name: list_id not specified"; return 1; }
	[ "$_fw_backend" = ipt ] && prefix_gin="${p_name}_"
	eval "$1=\"${prefix_gin}${2%%_*}_${2##*ipv}${date_suffix}\""
}

# 1 - direction
# 2 - family
set_allow_ipset_vars() {
	eval "allow_ipset_name=\"\${allow_ipset_name_${1}_${2}}\""
	allow_iplist_file="$iplist_dir/$allow_ipset_name.iplist"
}


## PARSE ARGUMENTS

# check for valid action
tolower action "$1"
case "$action" in
	update|add|restore|on|off) shift ;;
	*) unknownact
esac

# process the rest of the args
while getopts ":dVh" opt; do
	case $opt in
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

is_root_ok
setdebug
debugentermsg

## VARIABLES

get_config_vars

geotag_aux="${geotag}_aux"


## CHECKS

checkvars datadir inbound_geomode outbound_geomode ifaces _fw_backend noblock iplist_dir

[ "$ifaces" != all ] && {
	all_ifaces="$(detect_ifaces)" || die "$FAIL detect network interfaces."
	nl2sp all_ifaces
	subtract_a_from_b "$all_ifaces" "$ifaces" bad_ifaces
	[ "$bad_ifaces" ] && die "Geoblocking was configured for network interfaces '$ifaces', but interfaces '$bad_ifaces' do not exist."
}

## MAIN

debugprint "loading the $_fw_backend library..."
. "$_lib-$_fw_backend.sh" || exit 1

case "$action" in
	on) geoip_on; exit ;;
	off) geoip_off
		case $? in
			0|2) exit 0 ;;
			1) exit 1
		esac
esac

[ -n "$iplist_dir" ] && mkdir -p "$iplist_dir"

[ -s "${_lib}-detect-lan.sh" ] && . "${_lib}-detect-lan.sh" || die "$FAIL source ${_lib}-detect-lan.sh"

### compile allowlist ip's and write to file
for family in $families; do
	unset lan_autodetected all_allow_ips_prev allow_iplist_file_prev
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue

		unset all_allow_ips res_subnets trusted lan_ips source_ips ll_addr

		allow_ipset_name="allow_${direction%bound}_${family#ipv}"
		allow_iplist_file="$iplist_dir/$allow_ipset_name.iplist"
		eval "allow_ipset_name_${direction}_${family}=\"$allow_ipset_name\"
			allow_iplist_file_${direction}_${family}=\"$allow_iplist_file\"
			allow_ipset_type_${direction}_${family}=ip"
		allow_ipset_type=ip


		rm -f "$allow_iplist_file"

		## load source ip's
		[ "$direction" = outbound ] && {
			eval "source_ips=\"\${source_ips_$family}\""

			case "$source_ips" in net:*|ip:*)
				ips_type="${source_ips%%":"*}"
				source_ips="${source_ips#*":"}"
			esac
			if [ -n "$source_ips" ]; then
				[ "$ips_type" = net ] && {
					allow_ipset_type=net
					eval "allow_ipset_type_${direction}_${family}=net"
				}
				sp2nl source_ips
			fi
		}

		[ "$geomode" = whitelist ] && {
			eval "allow_ipset_type_${direction}_${family}=net"
			allow_ipset_type=net

			## load or detect lan ip's
			if [ "$autodetect" ] && [ ! "$lan_autodetected" ]; then
				res_subnets=
				get_lan_subnets "$family" || die
				lan_autodetected=1
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
		for cat in trusted lan_ips ll_addr source_ips; do
			eval "cat_ips=\"\${$cat}\""
			[ ! "$cat_ips" ] && continue
			[ "$cat" != source_ips ] && cat_cnt=$((cat_cnt+1))
			all_allow_ips="$all_allow_ips${cat_ips%"${_nl}"}$_nl"
		done

		[ "$all_allow_ips" ] || continue

		eval "allow_ipset_present_${direction}_${family}=1"

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
				debugprint "allow ip's:${_nl}'$res_subnets'"
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

# generate lists:
# planned_ipsets_$direction - will be used to create direction-specific rules for iplists
# planned_ipsets - all planned final ipsets
# rm_ipsets - ipsets to remove
# load_ipsets - ipsets to load from file

getstatus "$status_file" || die "$FAIL read the status file '$status_file'."

curr_ipsets="$(get_ipsets)"

nl2sp curr_ipsets_sp "$curr_ipsets"

unset planned_ipsets rm1_ipsets load_ipsets
for direction in inbound outbound; do
	eval "
		${direction}_list_ids=\"\$${direction}_iplists\"
		list_ids=\"\$${direction}_list_ids\"
		geomode=\"\$${direction}_geomode\""

	debugprint "$direction list id's: '$list_ids'"

	unset "planned_ipsets_$direction"

	[ "$geomode" = disable ] && {
		debugprint "$direction geomode is disable - skipping adding ipsets for it"
		continue
	}

	# process list_ids
	for list_id in $list_ids; do
		case "$list_id" in [A-Z][A-Z]_ipv[46]) ;; *) die "Invalid iplist id '$list_id'."; esac

		# set list_id-specific vars
		family="${list_id#*_}"
		list_id_short="${list_id%%_*}_${list_id##*ipv}"
		get_ipset_name ipset "$list_id" || die

		add2list "planned_ipsets_$direction" "$ipset"

		case "$curr_ipsets_sp" in
			# check for ipset with exactly matching name (for nft - with same list_id and date, for ipt - same list_id)
			*"$ipset"*) [ "$action" = update ] && printf '%s\n' "Ip set for '$list_id' is already up-to-date." ;;
			# check for ipset with different date - for nft only
			*"$list_id_short"*)
				case "$action" in add|restore) die "Detected ipset with unexpected name for list id '$list_id'."; esac
				add2list rm1_ipsets "$ipset"
		esac

		add2list planned_ipsets "$ipset"
	done
done

subtract_a_from_b "$planned_ipsets" "$curr_ipsets_sp" rm2_ipsets
san_str rm_ipsets "$rm1_ipsets $rm2_ipsets"

subtract_a_from_b "$rm_ipsets" "$curr_ipsets_sp" keep_ipsets
subtract_a_from_b "$keep_ipsets" "$planned_ipsets" load_ipsets


debugprint "curr_ipsets_sp: '$curr_ipsets_sp'"
debugprint "planned ipsets: '$planned_ipsets'"
debugprint "rm1 ipsets: '$rm1_ipsets'"
debugprint "rm2 ipsets: '$rm2_ipsets'"
debugprint "rm ipsets: '$rm_ipsets'"
debugprint "keep ipsets: '$keep_ipsets'"
debugprint "load ipsets: '$load_ipsets'"

# check that there are iplist files to load ipsets from
for ipset in $load_ipsets; do
	get_ipset_id "$ipset"
	[ -f "$iplist_dir/$list_id.iplist" ] || die "Can not find file '$iplist_dir/$list_id.iplist' to load ipset '$ipset'."
done

get_counters

debugprint "calling apply_rules()"

apply_rules
rv_apply=$?

echo

[ "$rv_apply" = 0 ] && {
	setconf_ips=
	[ "$autodetect" ] && {
		[ "$lan_ips_ipv4" ] && setconf_ips=lan_ips_ipv4
		[ "$lan_ips_ipv6" ] && setconf_ips="$setconf_ips lan_ips_ipv6"
	}
	[ "$setconf_ips" ] && setconfig $setconf_ips
}

[ "$noblock" = true ] && { echolog -warn "Geoblocking is disabled via config."; echo; }

exit $rv_apply
