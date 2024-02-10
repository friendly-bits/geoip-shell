#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC1090,SC2034

# geoip-shell-apply.sh

#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/${proj_name}-ipt.sh" || exit 1

check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs


#### USAGE

usage() {
    cat <<EOF

Usage: $me <action> [-l <"list_ids">] [-d] [-h]
Switches geoip blocking on/off, or loads/removes ipsets and iptables rules for specified lists.

Actions:
    on|off           : enable or disable the geoip blocking chain (via a rule in the PREROUTING chain)
    add|remove       : Add or remove ipsets and iptables rules for lists specified with the '-l' option

Options:
    -l <"list_ids">  : iplist id's in the format <country_code>_<family> (if specifying multiple list id's, use double quotes)

    -d               : Debug
    -h               : This help

EOF
}

#### PARSE ARGUMENTS

# check for valid action
action="$1"
case "$action" in
	add|remove|on|off) ;;
	* ) unknownact
esac

# process the rest of the arguments
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

#### FUNCTIONS

die_a() {
	destroy_tmp_ipsets; die "$@"
}

critical() {
	echo "Failed." >&2
	echolog -err "Removing geoip rules..."
	for family in ipv4 ipv6; do
		set_ipt_cmds
		mk_ipt_rm_cmd "${geotag}_enable" | $ipt_restore_cmd 2>/dev/null
		$ipt_cmd -F "$iface_chain" 2>/dev/null
		$ipt_cmd -X "$iface_chain" 2>/dev/null
		$ipt_cmd -F "$geochain" 2>/dev/null
		$ipt_cmd -X "$geochain" 2>/dev/null
	done
	sleep "0.1" 2>/dev/null || sleep 1
	rm_all_ipsets
	die "$1"
}

destroy_tmp_ipsets() {
	echolog -err "Destroying temporary ipsets..."
	for tmp_ipset in $(ipset list -n | grep "$proj_name" | grep "temp"); do
		ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null
	done
}

enable_geoip() {
	[ "$devtype" = "router" ] && first_chain="$iface_chain" || first_chain="$geochain"
	for family in $families; do
		set_ipt_cmds || die_a
		enable_rule="$($ipt_save_cmd | grep "${geotag}_enable")"
		[ ! "$enable_rule" ] && {
			printf %s "Inserting the enable geoip $family rule... "
			$ipt_cmd -I PREROUTING -j "$first_chain" -m comment --comment "${geotag}_enable" || critical "$insert_failed"
			echo "Ok."
		} || printf '%s\n' "Geoip is already enabled for $family."
	done
}

# 1 - iptables tag
mk_ipt_rm_cmd() {
	for tag in "$@"; do
		printf '%s\n' "$curr_ipt"  | sed -n "/$tag/"'s/^-A /-D /p' || return 1
	done
}

add_ipset() {
	perm_ipset="$1"; tmp_ipset="${1}_temp"; iplist_file="$2"
	[ ! -f "$iplist_file" ] && critical "Error: Can not find the iplist file in path: '$iplist_file'."

	ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null

	# count ips in the iplist file
	ip_cnt=$(wc -w < "$iplist_file")
#	debugprint "ip count in the iplist file '$iplist_file': $ip_cnt"

	# set hashsize to 1024 or (ip_cnt / 2), whichever is larger
	ipset_hs=$((ip_cnt / 2))
	[ $ipset_hs -lt 1024 ] && ipset_hs=1024
	debugprint "hashsize for ipset $list_id: $ipset_hs"

	debugprint "Creating ipset '$tmp_ipset'... "
	ipset create "$tmp_ipset" hash:net family "$family" hashsize "$ipset_hs" maxelem "$ip_cnt" ||
		crtical "Failed to create ipset '$tmp_ipset'."
	debugprint "Ok."

	debugprint "Importing iplist '$iplist_file' into temporary ipset... "
	# read $iplist_file, transform each line into 'add' command and pipe the result into "ipset restore"
	sed "s/^/add \"$tmp_ipset\" /" "$iplist_file" | ipset restore -exist ||
		critical "Failed to import the iplist from '$iplist_file' into ipset '$tmp_ipset'."
	debugprint "Ok."

	[ "$debugmode" ] && debugprint "subnets in the temporary ipset: $(ipset save "$tmp_ipset" | grep -c "add $tmp_ipset")"

	# swap the temp ipset with the permanent ipset
	debugprint "Making the ipset '$perm_ipset' permanent... "
	ipset swap "$tmp_ipset" "$perm_ipset" || critical "Failed to swap temporary and permanent ipsets."
	debugprint "Ok."
}

mk_perm_ipset() {
	perm_ipset="$1"; tmp_ipset="${perm_ipset}_temp"
	# create new permanent ipset if it doesn't exist
	case "$curr_ipsets" in *"$perm_ipset"* ) ;; *)
		debugprint "Creating permanent ipset '$perm_ipset'... "
		ipset create "$perm_ipset" hash:net family "$family" hashsize 1 maxelem 1 ||
			die_a "Failed to create ipset '$perm_ipset'."
		debugprint "Ok."
	esac
}

get_curr_ipsets() {
	curr_ipsets="$(ipset list -n | grep "$proj_name")"
}
#### VARIABLES

export list_type="$list_type"
case "$list_type" in whitelist) fw_target="ACCEPT" ;; *) fw_target="DROP"; esac

for entry in "Families families" "NoBlock noblock" "ListType list_type" \
		"Autodetect autodetect_opt" "DeviceType devtype" "WAN_ifaces wan_ifaces" \
		"LanSubnets_ipv4 lan_subnets_ipv4" "LanSubnets_ipv6 lan_subnets_ipv6"; do
	getconfig "${entry% *}" "${entry#* }"
done


exitvalue=0

iplist_dir="${datadir}/ip_lists"

action="$(tolower "$action")"

geotag_aux="${proj_name}_aux"

insert_failed="Failed to insert a firewall rule."

ipsets_to_rm=''
get_curr_ipsets

#### CHECKS

[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."
[ -z "$datadir" ] && die "Internal error: the \$datadir variable is empty."
[ -z "$list_type" ] && die "Internal error: the \$list_type variable is empty."


#### MAIN

### apply the 'on' and 'off' actions
case "$action" in
	off)
		for family in $families; do
			set_ipt_cmds || die
			enable_rule="$($ipt_save_cmd | grep "${geotag}_enable")"
			if [ "$enable_rule" ]; then
				rm_ipt_rules "${geotag}_enable" || critical
			else
				printf '%s\n' "Geoip is already disabled for $family."
			fi
		done
		exit 0;;
	on) enable_geoip; exit 0
esac

[ ! "$list_ids" ] && {
	usage
	die 254 "Specify iplist id's!"
}

for family in $families; do
	ipsets_to_add=''

	### make perm ipsets, assemble $ipsets_to_add and $ipsets_to_rm
	for list_id in $list_ids; do
		case "$list_id" in *_*) ;; *) die_a "Invalid iplist id '$list_id'."; esac
		[ "${list_id#*_}" != "$family" ] && continue
		perm_ipset="${proj_name}_${list_id}"
		if [ "$action" = "add" ]; then
			iplist_file="${iplist_dir}/${list_id}.iplist"
			mk_perm_ipset "$perm_ipset"
			ipsets_to_add="$ipsets_to_add$perm_ipset $iplist_file$_nl"
		elif [ "$action" = "remove" ]; then
			ipsets_to_rm="$ipsets_to_rm$perm_ipset "
		fi
	done

	### local networks
	if [ "$list_type" = "whitelist" ] && [ "$devtype" = "host" ]; then
		if [ ! "$autodetect" ]; then
			eval "lan_subnets=\"\$lan_subnets_$family\""
		else
			lan_subnets="$(sh "$script_dir/detect-local-subnets-AIO.sh" -s -f "$family")" || a_d_failed=1
			[ ! "$lan_subnets" ] || [ "$a_d_failed" ] && { echolog -err "Failed to autodetect $family local subnets."; exit 1; }
			setconfig "LanSubnets_$family" "$lan_subnets"
		fi

		[ -n "$lan_subnets" ] && {
			lan_ipset="${geotag}_lan_$family"
			tmp_file="/tmp/$lan_ipset.tmp"
			sp2nl "$lan_subnets" lan_subnets
			printf '%s\n' "$lan_subnets" > "$tmp_file" || die_a "Failed to write to file '$tmp_file'"
			mk_perm_ipset "$lan_ipset"
			ipsets_to_add="$ipsets_to_add$lan_ipset $tmp_file$_nl"
		}
	fi

	#### Assemble commands for iptables-restore
	printf %s "Assembling new $family firewall rules... "
	### Read current iptables rules
	set_ipt_cmds || die_a
	curr_ipt="$($ipt_save_cmd)" || die_a "Failed to read iptables rules."

	iptr_cmd_chain="$(
		rv=0

		echo "*$ipt_table"

		### Remove existing geoip rules

		## Remove the main blocking rule, the whitelist blocking rule and the auxiliary rules
		mk_ipt_rm_cmd "${geotag}_enable" "${geotag}_aux" "${geotag}_whitelist_block" "${geotag}_iface_filter" || rv=1

		## Remove rules for $list_ids
		for list_id in $list_ids; do
			[ "$family" != "${list_id#*_}" ] && continue
			list_tag="${proj_name}_${list_id}"
			mk_ipt_rm_cmd "$list_tag" || rv=1
		done


		## Create the geochain if it doesn't exist
		case "$curr_ipt" in *":$geochain "*) ;; *) printf '%s\n' ":$geochain -"; esac

		### Create new rules

		if [ "$devtype" = "router" ]; then # apply geoip to wan ifaces
			[ -z "$wan_ifaces" ] && { echolog -err "Internal error: \$wan_ifaces var is empty."; exit 1; }
			case "$curr_ipt" in *":$iface_chain "*) ;; *) printf '%s\n' ":$iface_chain -"; esac
			for wan_iface in $wan_ifaces; do
				printf '%s\n' "-i $wan_iface -I $iface_chain -j $geochain -m comment --comment ${geotag}_iface_filter"
			done
		fi

		## Auxiliary rules

		### local networks
		if [ "$list_type" = "whitelist" ] && [ "$devtype" = "host" ]; then
			printf '%s\n' "-I $geochain -m set --match-set ${geotag}_lan_$family src -m comment --comment ${geotag}_aux_lan_$family -j ACCEPT"
		fi

		# established/related
		printf '%s\n' "-I $geochain -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment ${geotag_aux}_rel-est -j ACCEPT"

		# lo interface
		[ "$list_type" = "whitelist" ] && [ "$devtype" = "host" ] && \
			printf '%s\n' "-I $geochain -i lo -m comment --comment ${geotag_aux}-lo -j ACCEPT"

		## iplist-specific rules
		if [ "$action" = "add" ]; then
			for list_id in $list_ids; do
				[ "$family" != "${list_id#*_}" ] && continue
				perm_ipset="${geotag}_${list_id}"
				list_tag="${geotag}_${list_id}"
				printf '%s\n' "-A $geochain -m set --match-set $perm_ipset src -m comment --comment $list_tag -j $fw_target"
			done
		fi

		# whitelist block
		[ "$list_type" = "whitelist" ] && printf '%s\n' "-A $geochain -m comment --comment ${geotag}_whitelist_block -j DROP"

		echo "COMMIT"
		exit "$rv"
	)" || die_a "Error: Failed to assemble commands for iptables-restore"
	echo "Ok."

	### "Apply new rules
	printf %s "Applying new $family firewall rules... "
	printf '%s\n' "$iptr_cmd_chain" | $ipt_restore_cmd || critical "Failed to apply new iptables rules"
	echo "Ok."

	[ -n "$ipsets_to_add" ] && {
		printf %s "Adding $family ipsets... "
		newifs "$_nl" apply
		for entry in ${ipsets_to_add%"$_nl"}; do
			add_ipset "${entry%% *}" "${entry#* }"
			ipsets_to_rm="$ipsets_to_rm${entry%% *}_temp "
		done
		oldifs apply
		printf '%s\n\n' "Ok."
	}
done

[ -n "$ipsets_to_rm" ] && {
	printf %s "Removing old ipsets... "
	get_curr_ipsets
	sleep "0.1" 2>/dev/null || sleep 1
	for ipset in $ipsets_to_rm; do
		case "$curr_ipsets" in
			*"$ipset"* )
				debugprint "Destroying ipset '$ipset'... "
				ipset destroy "$ipset"; rv=$?
				case "$rv" in
					0) debugprint "Ok." ;;
					*) echo "Failed."; echolog -err "Warning: Failed to destroy ipset '$ipset'."; exitvalue="254"
				esac
				;;
			*) echo "Failed."; echolog -err "Warning: Can't remove ipset '$ipset' because it doesn't exist."; exitvalue="254"
		esac
	done
	[ "$exitvalue" = 0 ] && echo "Ok."
}


# insert the main blocking rule
case "$noblock" in
	'') enable_geoip ;;
	*) echolog -err "WARNING: Geoip blocking is disabled via config." >&2
esac

echo

exit "$exitvalue"
