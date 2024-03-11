#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090

# geoip-shell-apply-nft.sh

# nftables-specific library for the -apply script

# Copyright: friendly bits
# github.com/friendly-bits

. "$_lib-nft.sh" || exit 1

#### FUNCTIONS

die_a() {
	echolog -err "$*"
	echo "Destroying temporary ipsets..."
	for new_ipset in $new_ipsets; do
		nft delete set inet "$geotable" "$new_ipset" 1>/dev/null 2>/dev/null
	done
	die 254
}

#### Variables

case "$list_type" in
	whitelist) iplist_verdict="accept" ;;
	blacklist) iplist_verdict="drop" ;;
	*) die "Unknown firewall mode '$list_type'."
esac

: "${perf_opt:=memory}"

#### MAIN

### Read current firewall geoip rules
geochain_on=''
is_geochain_on && geochain_on=1
nft_get_geotable 1>/dev/null
geochain_cont="$(nft_get_chain "$geochain")"
base_chain_cont="$(nft_get_chain "$base_geochain")"

### apply the 'on/off' action
case "$action" in
	off) [ -z "$geochain_on" ] && { echo "Geoip chain is already switched off."; exit 0; }
		printf %s "Removing the geoip enable rule... "
		mk_nft_rm_cmd "$base_geochain" "$base_chain_cont" "${geotag}_enable" | nft -f -; rv=$?
		[ $rv != 0 ] || is_geochain_on && { FAIL; die "$FAIL remove firewall rule."; }
		OK
		exit 0 ;;
	on) [ -n "$geochain_on" ] && { echo "Geoip chain is already switched on."; exit 0; }
		[ -z "$base_chain_cont" ] && missing_chain="base geoip"
		[ -z "$geochain_cont" ] && missing_chain="geoip"
		[ -n "$missing_chain" ] && { echo "Can't switch geoip on because $missing_chain chain is missing."; exit 1; }

		printf %s "Adding the geoip enable rule... "
		printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable" | nft -f -; rv=$?
		[ $rv != 0 ] || ! is_geochain_on && { FAIL; die "$FAIL add firewall rule."; }
		OK
		exit 0
esac

[ ! "$list_ids" ] && [ "$action" != update ] && {
	usage
	die 254 "Specify iplist id's!"
}

# generate lists of $new_ipsets and $old_ipsets
old_ipsets=''; new_ipsets=''
curr_ipsets="$(nft -t list sets inet | grep "$geotag")"
for list_id in $list_ids; do
	case "$list_id" in *_*) ;; *) die "Invalid iplist id '$list_id'."; esac
	family="${list_id#*_}"
	iplist_file="${iplist_dir}/${list_id}.iplist"
	getstatus "$status_file" "PrevDate_${list_id}" list_date ||
		die "$FAIL read value for '$PrevDate_${list_id}' from file '$status_file'."
	ipset="${list_id}_${list_date}_${geotag}"
	case "$curr_ipsets" in
		*"$ipset"* ) [ "$action" = add ] && { echo "Ip set for '$list_id' is already up-to-date."; continue; }
			old_ipsets="$old_ipsets$ipset " ;;
		*"$list_id"* )
			get_matching_line "$curr_ipsets" "*" "$list_id" "*" ipset_line
			n="${ipset_line#*set }"
			old_ipset="${n%"_$geotag"*}_$geotag"
			old_ipsets="$old_ipsets$old_ipset "
	esac
	[ "$action" = "add" ] && new_ipsets="$new_ipsets$ipset "
done


### create the table
nft add table inet $geotable || die "$FAIL create table '$geotable'"

### apply the action 'add' for ipsets
for new_ipset in $new_ipsets; do
	printf %s "Adding ip set '$new_ipset'... "
	get_ipset_id "$new_ipset" || die_a
	iplist_file="${iplist_dir}/${list_id}.iplist"
	[ ! -f "$iplist_file" ] && die_a "Can not find the iplist file '$iplist_file'."

	# count ips in the iplist file
	[ "$debugmode" ] && ip_cnt="$(tr ',' ' ' < "$iplist_file" | wc -w)"
	debugprint "\nip count in the iplist file '$iplist_file': $ip_cnt"

	# read $iplist_file into new set
	{
		printf %s "add set inet $geotable $new_ipset { type ${family}_addr; flags interval; auto-merge; policy $perf_opt; "
		cat "$iplist_file"
		printf '%s\n' "; }"
	} | nft -f - || die_a "$FAIL import the iplist from '$iplist_file' into ip set '$new_ipset'."
	OK

	[ "$debugmode" ] && debugprint "elements in $new_ipset: $(nft_cnt_elements "$new_ipset")"
done

#### Assemble commands for nft
printf %s "Assembling nftables commands... "

nft_cmd_chain="$(
	rv=0

	### Create the chains
	printf '%s\n%s\n' "add chain inet $geotable $base_geochain { type filter hook prerouting priority mangle; policy accept; }" \
		"add chain inet $geotable $geochain"

	## Remove the whitelist blocking rule and the auxiliary rules
	mk_nft_rm_cmd "$geochain" "$geochain_cont" "${geotag}_whitelist_block" "${geotag_aux}" || exit 1

	## Remove the geoip enable rule
	mk_nft_rm_cmd "$base_geochain" "$base_chain_cont" "${geotag}_enable" || exit 1

	## Remove old ipsets and their rules
	for old_ipset in $old_ipsets; do
		mk_nft_rm_cmd "$geochain" "$geochain_cont" "$old_ipset" || exit 1
		printf '%s\n' "delete set inet $geotable $old_ipset"
	done

	### Create new rules

	## Auxiliary rules

	# apply geoip to ifaces
	[ "$_ifaces" ] && opt_ifaces="iifname { $(printf '%s, ' $_ifaces) }"

	# trusted subnets
	for family in $families; do
		eval "t_subnets=\"\$t_subnets_$family\""
		[ -n "$t_subnets" ] && {
			get_nft_family
			nft_get_geotable | grep "${geotag}_trusted_$family" >/dev/null &&
				printf '%s\n' "delete set inet $geotable ${geotag}_trusted_$family"
			printf %s "add set inet $geotable ${geotag}_trusted_$family \
				{ type ${family}_addr; flags interval; auto-merge; elements={ "
			printf '%s,' $t_subnets
			printf '%s\n' " }; }"
			printf '%s\n' "insert rule inet $geotable $geochain $opt_ifaces $nft_family saddr @${geotag}_trusted_$family accept comment ${geotag_aux}_trusted"
		}
	done

	# LAN subnets
	if [ "$list_type" = "whitelist" ]; then
		for family in $families; do
			if [ ! "$autodetect" ]; then
				eval "lan_subnets=\"\$lan_subnets_$family\""
			else
				a_d_failed=
				lan_subnets="$(call_script "${i_script}-detect-lan.sh" -s -f "$family")" || a_d_failed=1
				[ ! "$lan_subnets" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL autodetect $family local subnets."; exit 1; }
				setconfig "LanSubnets_$family" "$lan_subnets"
			fi
			[ -n "$lan_subnets" ] && {
				get_nft_family
				nft_get_geotable | grep "${geotag}_lansubnets_$family" >/dev/null &&
					printf '%s\n' "delete set inet $geotable ${geotag}_lansubnets_$family"
				printf %s "add set inet $geotable ${geotag}_lansubnets_$family \
					{ type ${family}_addr; flags interval; auto-merge; elements={ "
				printf '%s,' $lan_subnets
				printf '%s\n' " }; }"
				printf '%s\n' "insert rule inet $geotable $geochain $opt_ifaces $nft_family saddr @${geotag}_lansubnets_$family accept comment ${geotag_aux}_lan"
			}
		done
	fi

	# ports
	for proto in tcp udp; do
		eval "proto_exp=\"\$${proto}_ports\""
		[ "$proto_exp" = skip ] && continue
		printf '%s\n' "insert rule inet $geotable $geochain $opt_ifaces $proto_exp counter accept comment ${geotag_aux}_ports"
	done

	# established/related
	printf '%s\n' "insert rule inet $geotable $geochain $opt_ifaces ct state established,related accept comment ${geotag_aux}_est-rel"

	# lo interface
	[ "$list_type" = "whitelist" ] && [ ! "$_ifaces" ] &&
		printf '%s\n' "insert rule inet $geotable $geochain iifname lo accept comment ${geotag_aux}-loopback"

	## add iplist-specific rules
	for new_ipset in $new_ipsets; do
		get_ipset_id "$new_ipset" || exit 1
		get_nft_family
		printf '%s\n' "add rule inet $geotable $geochain $opt_ifaces $nft_family saddr @$new_ipset counter $iplist_verdict"
	done

	## whitelist blocking rule
	[ "$list_type" = whitelist ] && printf '%s\n' "add rule inet $geotable $geochain $opt_ifaces counter drop comment ${geotag}_whitelist_block"

	## geoip enable rule
	[ -z "$noblock" ] && printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable"

	exit 0
)" || die_a 254 "$FAIL assemble nftables commands."
OK

# debugprint "new rules: $_nl'$nft_cmd_chain'"

### Apply new rules
printf %s "Applying new firewall rules... "
printf '%s\n' "$nft_cmd_chain" | nft -f - || die_a "$FAIL apply new firewall rules"
OK

[ -n "$noblock" ] && echolog -err "$WARN Geoip blocking is disabled via config."

echo

:
