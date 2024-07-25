#!/bin/sh
# shellcheck disable=SC2154,SC2155

# geoip-shell-lib-ipt.sh

# geoip-shell library for interacting with nftables

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

### General

get_nft_family() {
	nft_family="${family%ipv4}"; nft_family="ip${nft_family#ipv}"
}


### Tables and chains

# 1 - optional -f for forced re-read
is_geochain_on() {
	get_matching_line "$(nft_get_chain "$base_geochain" "$1")" "*" "${geotag}_enable" "*" test; rv=$?
	return $rv
}

nft_get_geotable() {
	[ "$1" != "-f" ] && [ -n "$_geotable_cont" ] && { printf '%s\n' "$_geotable_cont"; return 0; }
	export _geotable_cont="$(nft -ta list ruleset inet | sed -n -e /"^table inet $geotable"/\{:1 -e n\;/^\}/q\;p\;b1 -e \})"
	[ -z "$_geotable_cont" ] && return 1 || { printf '%s\n' "$_geotable_cont"; return 0; }
}

# 1 - chain name
# 2 - optional '-f' for forced re-read
nft_get_chain() {
	_chain_cont="$(nft_get_geotable "$2" | sed -n -e /"chain $1 {"/\{:1 -e n\;/"^[[:space:]]*}"/q\;p\;b1 -e \})"
	[ -z "$_chain_cont" ] && return 1 || { printf '%s\n' "$_chain_cont"; return 0; }
}

rm_all_georules() {
	nft_get_geotable -f 1>/dev/null 2>/dev/null || return 0
	printf %s "Removing $p_name firewall rules... "
	export _geotable_cont=
	nft delete table inet "$geotable" || { echolog -err -nolog "$FAIL delete table '$geotable'."; return 1; }
	OK
}


### Rules

# store current counter values in vars
# 1 - chain contents
get_geocounters() {
	curr_rules="$(printf '%s\n' "$1" | grep "$geotag")"
	newifs "$_nl" cnt
	for rule in $curr_rules; do
		case "$rule" in *counter*) ;; *) continue; esac

		# remove leading whitespaces and tabs
		rule="${rule#"${rule%%[! 	]*}"}"

		# extract counter values
		counter_val_tmp="${rule##*"counter "}"
		bytes="${counter_val_tmp##*"bytes "}"
		bytes="${bytes%% *}"
		counter_val="${counter_val_tmp%%bytes*}bytes $bytes"

		# remove counter values from the rule string
		rule_pt2="${rule#*bytes }"
		rule="${rule%%counter*}${rule_pt2#* }"
		rule="${rule%%" #"*}"

		rule_md5="$(get_md5 "$rule")"
		[ ! "$rule_md5" ] && continue

		eval "counter_$rule_md5=\"$counter_val\""
		eval "printf '%s\n' \"counter_$rule_md5=$counter_val\""
	done
	oldifs cnt
}

# 1 - chain name
# 2 - current chain contents
# 3... tags list
mk_nft_rm_cmd() {
	chain="$1"; _chain_cont="$2"; shift 2
	[ ! "$chain" ] || [ ! "$*" ] && return 1
	for tag in "$@"; do
		printf '%s\n' "$_chain_cont" | sed -n "/$tag/"'s/^.* # handle/'"delete rule inet $geotable $chain handle"'/p' || return 1
	done
}

# parses an nft array/list and outputs it in human-readable format
# sets $n to number of elements
get_nft_list() {
	n=0; _res=
	[ "$1" = '!=' ] && { _res='!='; shift; n=$((n+1)); }
	case "$1" in
		'{')
			while true; do
				shift; n=$((n+1))
				[ "$1" = '}' ] && break
				_res="$_res$1"
			done ;;
		*) _res="$_res$1"
	esac
}

get_fwrules_iplists() {
	nft_get_geotable "$force_read" |
		sed -n "/saddr[[:space:]]*@.*${geotag}.*$nft_verdict/{s/.*@//;s/_.........._${geotag}.*//p}"
}

### (ip)sets

get_ipset_id() {
	list_id="${1%_"$geotag"}"
	list_id="${list_id%_*}"
	family="${list_id#*_}"
	case "$family" in
		ipv4|ipv6) return 0 ;;
		*) echolog -err "ip set name '$1' has unexpected format."
			unset family list_id
			return 1
	esac
}

get_ipsets() {
	nft -t list sets inet | grep -o "[a-zA-Z0-9_-]*_$geotag"
}

get_ipset_iplists() {
	nft -t list sets inet | sed -n "/$geotag/{s/.*set[[:space:]]*//;s/_.........._${geotag}.*//p}"
}

# 1 - ipset tag
# expects $ipsets to be set
get_ipset_elements() {
    get_matching_line "$ipsets" "" "$1" "*" ipset
    [ "$ipset" ] && nft list set inet "$geotable" "$ipset" |
        sed -n -e /"elements[[:space:]]*=/{s/elements[[:space:]]*=[[:space:]]*{//;:1" -e "/}/{s/}//"\; -e p\; -e q\; -e \}\; -e p\; -e n\;b1 -e \}
}

# 1 - ipset tag
# expects $ipsets to be set
cnt_ipset_elements() {
    get_matching_line "$ipsets" "" "$1" "*" ipset
    [ ! "$ipset" ] && { echo 0; return 1; }
    get_ipset_elements "$1" | wc -w
}

print_ipset_elements() {
	get_ipset_elements "$1" | awk '{gsub(",", "");$1=$1};1' ORS=' '
}

report_fw_state() {
	curr_geotable="$(nft_get_geotable)" ||
		{ printf '%s\n' "$FAIL read the firewall state or firewall table $geotable does not exist." >&2; incr_issues; }

	wl_rule="$(printf %s "$curr_geotable" | grep "drop comment \"${geotag}_whitelist_block\"")"

	is_geochain_on && chain_status="${green}enabled $_V" || { chain_status="${red}disabled $_X"; incr_issues; }
	printf '%s\n' "Geoip firewall chain: $chain_status"
	[ "$geomode" = whitelist ] && {
		case "$wl_rule" in
			'') wl_rule_status="$_X"; incr_issues ;;
			*) wl_rule_status="$_V"
		esac
		printf '%s\n' "Whitelist blocking rule: $wl_rule_status"
	}
	[ ! "$nft_perf" ] && { nft_perf="${red}Not set $_X"; incr_issues; }
	printf '\n%s\n' "nftables sets optimization policy: ${blue}$nft_perf$n_c"

	if [ "$verb_status" ]; then
		dashes="$(printf '%158s' ' ' | tr ' ' '-')"
		# report geoip rules
		fmt_str="%-9s%-11s%-5s%-8s%-5s%-24s%-33s%s\n"
		printf "\n%s\n%s\n${fmt_str}%s\n" "${purple}Firewall rules in the $geochain chain${n_c}:" \
			"$dashes${blue}" packets bytes ipv verdict prot dports interfaces extra "$n_c$dashes"
		rules="$(nft_get_chain "$geochain" | sed 's/^[[:space:]]*//;s/ # handle.*//' | grep .)" ||
			{ printf '%s\n' "${red}None $_X"; incr_issues; }
		newifs "$_nl" rules
		for rule in $rules; do
			newifs ' "' wrds
			set -- $rule
			case "$families" in "ipv4 ipv6"|"ipv6 ipv4") dfam="both" ;; *) dfam="$families"; esac
			pkts='---'; bytes='---'; ipv="$dfam"; verd='---'; prot='all'; dports='all'; in='all'; line=''
			while [ -n "$1" ]; do
				case "$1" in
					iifname) shift; get_nft_list "$@"; in="$_res"; shift "$n" ;;
					ip) ipv="ipv4" ;;
					ip6) ipv="ipv6" ;;
					dport) shift; get_nft_list "$@"; dports="$_res"; shift "$n" ;;
					udp|tcp) prot="$1 " ;;
					packets) pkts=$(num2human $2); shift ;;
					bytes) bytes=$(num2human $2 bytes); shift ;;
					counter) ;;
					accept) verd="ACCEPT" ;;
					drop) verd="DROP  " ;;
					*) line="$line$1 "
				esac
				shift
			done
			printf "$fmt_str" "$pkts " "$bytes " "$ipv " "$verd " "$prot " "$dports " "$in " "${line% }"
		done
		oldifs rules
		echo
	fi
}

destroy_tmp_ipsets() {
	echo "Destroying temporary ipsets..."
	for new_ipset in $new_ipsets; do
		nft delete set inet "$geotable" "$new_ipset" 1>/dev/null 2>/dev/null
	done
}

geoip_on() {
	get_nft_geoip_state
	[ -n "$geochain_on" ] && { echo "Geoip chain is already switched on."; exit 0; }
	[ -z "$base_chain_cont" ] && missing_chain="base geoip"
	[ -z "$geochain_cont" ] && missing_chain=geoip
	[ -n "$missing_chain" ] && { echo "Can't switch geoip on because the $missing_chain chain is missing."; exit 1; }

	printf %s "Adding the geoip enable rule... "
	printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable" | nft -f -; rv=$?
	[ $rv != 0 ] || ! is_geochain_on -f && { FAIL; die "$FAIL add firewall rule."; }
	OK
}

geoip_off() {
	get_nft_geoip_state
	[ -z "$geochain_on" ] && { echo "Geoip chain is already disabled."; exit 0; }
	printf %s "Removing the geoip enable rule... "
	mk_nft_rm_cmd "$base_geochain" "$base_chain_cont" "${geotag}_enable" | nft -f -; rv=$?
	[ $rv != 0 ] || is_geochain_on -f && { FAIL; die "$FAIL remove firewall rule."; }
	OK
}

# populates $_geotable_cont, $geochain_cont, $base_chain_cont, $geochain_on
get_nft_geoip_state() {
	nft_get_geotable -f 1>/dev/null
	geochain_on=
	is_geochain_on && geochain_on=1
	geochain_cont="$(nft_get_chain "$geochain")"
	base_chain_cont="$(nft_get_chain "$base_geochain")"
}

apply_rules() {
	#### Variables

	: "${nft_perf:=memory}"

	#### MAIN

	### Read current firewall geoip rules
	get_nft_geoip_state

	[ ! "$list_ids" ] && [ "$action" != update ] && {
		usage
		die 254 "Specify iplist id's!"
	}

	# generate lists of $new_ipsets and $old_ipsets
	unset old_ipsets new_ipsets
	curr_ipsets="$(nft -t list sets inet | grep "$geotag")"

	getstatus "$status_file" || die "$FAIL read the status file '$status_file'."

	for list_id in $list_ids; do
		case "$list_id" in *_*) ;; *) die "Invalid iplist id '$list_id'."; esac
		family="${list_id#*_}"
		iplist_file="${iplist_dir}/${list_id}.iplist"
		eval "list_date=\"\$prev_date_${list_id}\""
		[ ! "$list_date" ] && die "$FAIL read value for 'prev_date_${list_id}' from file '$status_file'."
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
		[ "$debugmode" ] && ip_cnt="$(tr ',' ' ' < "$iplist_file" | sed 's/elements = { //;s/ }//' | wc -w)"
		debugprint "\nip count in the iplist file '$iplist_file': $ip_cnt"

		# read $iplist_file into new set
		{
			printf %s "add set inet $geotable $new_ipset { type ${family}_addr; flags interval; auto-merge; policy $nft_perf; "
			cat "$iplist_file"
			printf '%s\n' "; }"
		} | nft -f - || die_a "$FAIL import the iplist from '$iplist_file' into ip set '$new_ipset'."
		OK

		[ "$debugmode" ] && { ipsets="$(get_ipsets)"; debugprint "elements in $new_ipset: $(cnt_ipset_elements "$new_ipset")"; }
	done

	#### Assemble commands for nft
	opt_ifaces=
	[ "$ifaces" != all ] && {
		unset br1 br2
		case "$ifaces" in *' '*) br1='{ ' br2=' }'; esac
		opt_ifaces=" iifname $br1$(printf '"%s", ' $ifaces)"
		opt_ifaces="${opt_ifaces%", "}$br2"
	}
	geopath="inet $geotable $geochain"

	printf %s "Assembling nftables commands... "
	nft_cmd_chain="$(
		get_geocounters "$geochain_cont" >/dev/null

		### Create the chains
		printf '%s\n%s\n' "add chain inet $geotable $base_geochain { type filter hook prerouting priority -141; policy accept; }" \
			"add chain $geopath"

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

		# trusted subnets/ips
		for family in $families; do
			nft_get_geotable | grep "trusted_${family}_${geotag}" >/dev/null &&
				printf '%s\n' "delete set inet $geotable trusted_${family}_${geotag}"
			eval "trusted=\"\$trusted_$family\""
			interval=
			case "${trusted%%":"*}" in net|ip)
				[ "${trusted%%":"*}" = net ] && interval="flags interval; auto-merge;"
				trusted="${trusted#*":"}"
			esac

			[ -n "$trusted" ] && {
				get_nft_family
				printf %s "add set inet $geotable trusted_${family}_${geotag} \
					{ type ${family}_addr; $interval elements={ "
				printf '%s,' $trusted
				printf '%s\n' " }; }"
				printf '%s\n' "insert rule $geopath$opt_ifaces $nft_family saddr @trusted_${family}_${geotag} accept comment ${geotag_aux}_trusted"
			}
		done

		# LAN subnets/ips
		if [ "$geomode" = "whitelist" ]; then
			for family in $families; do
				if [ ! "$autodetect" ]; then
					eval "lan_ips=\"\$lan_ips_$family\""
				else
					a_d_failed=
					lan_ips="$(call_script "${i_script}-detect-lan.sh" -s -f "$family")" || a_d_failed=1
					[ ! "$lan_ips" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL detect $family LAN subnets."; exit 1; }
					nl2sp lan_ips "net:$lan_ips"
					eval "lan_ips_$family=\"$lan_ips\""
				fi

				nft_get_geotable | grep "lan_ips_${family}_${geotag}" >/dev/null &&
					printf '%s\n' "delete set inet $geotable lan_ips_${family}_${geotag}"
				interval=
				[ "${lan_ips%%":"*}" = net ] && interval="flags interval; auto-merge;"
				lan_ips="${lan_ips#*":"}"
				[ -n "$lan_ips" ] && {
					get_nft_family
					printf %s "add set inet $geotable lan_ips_${family}_${geotag} \
						{ type ${family}_addr; $interval elements={ "
					printf '%s,' $lan_ips
					printf '%s\n' " }; }"
					printf '%s\n' "insert rule $geopath$opt_ifaces $nft_family saddr @lan_ips_${family}_${geotag} accept comment ${geotag_aux}_lan"
				}
			done
			[ "$autodetect" ] && setconfig lan_ips_ipv4 lan_ips_ipv6
		fi

		# Allow link-local, DHCPv6
		[ "$geomode" = whitelist ] && [ "$ifaces" != all ] && {
			rule_DHCPv6_1="ip6 saddr fc00::/6 ip6 daddr fc00::/6 udp dport 546"
			rule_DHCPv6_2="accept comment \"${geotag_aux}_DHCPv6\""
			get_counter_val "$rule_DHCPv6_1 $rule_DHCPv6_2"
			printf '%s\n' "insert rule $geopath$opt_ifaces $rule_DHCPv6_1 counter $counter_val $rule_DHCPv6_2"

			rule_LL_1="ip6 saddr fe80::/10"
			rule_LL_2="accept comment \"${geotag_aux}_link-local\""
			get_counter_val "$rule_LL_1 $rule_LL_2"
			printf '%s\n' "insert rule $geopath$opt_ifaces $rule_LL_1 counter $counter_val $rule_LL_2"

			# leaving DHCP v4 allow disabled for now because it's unclear that it is needed
			# printf '%s\n' "add rule $geopath$opt_ifaces meta nfproto ipv4 udp dport 68 counter accept comment ${geotag_aux}_DHCP"
		}

		# ports
		for proto in tcp udp; do
			eval "ports_exp=\"\${${proto}_ports%:*}\" ports=\"\${${proto}_ports##*:}\""
			debugprint "ports_exp: '$ports_exp', ports: '$ports'"
			[ "$ports_exp" = skip ] && continue
			if [ "$ports_exp" = all ]; then
				ports_exp="meta l4proto $proto"
			else
				unset br1 br2
				case "$ports" in *','*)
					br1='{ ' br2=' }'
					ports="$(printf %s "$ports" | sed 's/,/, /g')"
				esac
				ports_exp="$proto $(printf %s "$ports_exp" | sed "s/multiport //;s/!dport/dport !=/") $br1$ports$br2"
			fi
			rule_ports_pt2="accept comment \"${geotag_aux}_ports\""
			get_counter_val "$ports_exp $rule_ports_pt2"
			printf '%s\n' "insert rule $geopath$opt_ifaces $ports_exp counter $counter_val $rule_ports_pt2"
		done

		# established/related
		printf '%s\n' "insert rule $geopath$opt_ifaces ct state established,related accept comment ${geotag_aux}_est-rel"

		# lo interface
		[ "$geomode" = "whitelist" ] && [ "$ifaces" = all ] &&
			printf '%s\n' "insert rule $geopath$opt_ifaces iifname lo accept comment ${geotag_aux}-loopback"

		## add iplist-specific rules
		for new_ipset in $new_ipsets; do
			get_ipset_id "$new_ipset" || exit 1
			get_nft_family
			rule_ipset="$nft_family saddr @$new_ipset"
			get_counter_val "$rule_ipset $iplist_verdict"
			printf '%s\n' "add rule $geopath$opt_ifaces $rule_ipset counter $counter_val $iplist_verdict"
		done

		## whitelist blocking rule
		[ "$geomode" = whitelist ] && {
			rule_wl_pt2="drop comment \"${geotag}_whitelist_block\""
			get_counter_val "$rule_wl_pt2"
			printf '%s\n' "add rule $geopath$opt_ifaces counter $counter_val $rule_wl_pt2"
		}

		## geoip enable rule
		[ "$noblock" = false ] && printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable"

		exit 0
	)" || die_a 254 "$FAIL assemble nftables commands."
	OK

	# debugprint "new rules: $_nl'$nft_cmd_chain'"

	### Apply new rules
	printf %s "Applying new firewall rules... "
	printf '%s\n' "$nft_cmd_chain" | nft -f - || die_a "$FAIL apply new firewall rules"
	OK

	# update ports in config
	nft_get_geotable -f >/dev/null
	ports_conf=
	for proto in tcp udp; do
		eval "ports_exp=\"\$${proto}_ports\""
		case "$ports_exp" in skip|all) continue; esac
		ports_line="$(nft_get_chain "$geochain" | grep -m1 -o "${proto} dport.*")"

		IFS=' 	' set -- $ports_line; shift 2
		get_nft_list "$@"; ports_exp="$_res"
		unset mp neg
		case "$ports_exp" in *','*) mp="multiport "; esac
		case "$ports_exp" in *'!'*) neg='!'; esac
		ports_conf="$ports_conf${proto}_ports=$mp${neg}dport:${ports_exp#*"!="}$_nl"
	done
	[ "$ports_conf" ] && setconfig "${ports_conf%"$_nl"}"

	[ "$noblock" = true ] && echolog -warn "Geoip blocking is disabled via config."

	echo

	:
}

# resets firewall rules, destroys geoip ipsets and then initiates restore from file
restorebackup() {
	printf %s "Restoring ip lists from backup... "
	counters_f="$bk_dir/counters.bak"
	mkdir -p "$iplist_dir"
	for list_id in $iplists; do
		bk_file="$bk_dir/$list_id.$bk_ext"
		iplist_file="$iplist_dir/${list_id}.iplist"

		[ ! -s "$bk_file" ] && rstr_failed "'$bk_file' is empty or doesn't exist."

		# extract elements and write to $iplist_file
		$extract_cmd "$bk_file" > "$iplist_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
		[ ! -s "$iplist_file" ] && rstr_failed "$FAIL extract ip list for $list_id."
		# count lines in the iplist file
		line_cnt=$(wc -l < "$iplist_file")
		debugprint "\nLines count in $list_id backup: $line_cnt"
	done
	OK

	[ "$restore_conf" ] && { cp_conf restore || rstr_failed; }
	export main_config=

	# remove geoip rules
	rm_all_georules || rstr_failed "$FAIL remove firewall rules."

	[ -s "$counters_f" ] && export_conf=1 nodie=1 get_config_vars "$counters_f"
	if [ -n "$iplists" ]; then
		call_script "${i_script}-apply.sh" add -l "$iplists"; apply_rv=$?
	else
		apply_rv=0
	fi
	rm -f "$iplist_dir/"*.iplist
	[ "$apply_rv" != 0 ] && rstr_failed "$FAIL restore the firewall state from backup." "reset"
	:
}

rm_rstr_tmp() {
	rm -f "$iplist_dir/"*.iplist
}

rstr_failed() {
	rm_rstr_tmp
	main_config=
	[ "$1" ] && echolog -err "$1"
	[ "$2" = reset ] && {
		echolog -err "*** Geoip blocking is not working. Removing geoip firewall rules. ***"
		rm_all_georules
	}
	die
}

bk_failed() {
	rm_bk_tmp
	die "$FAIL back up $p_name ip sets."
}

# Saves current firewall state to a backup file
create_backup() {
	# back up current ip sets
	printf %s "Creating backup of $p_name ip sets... "
	getstatus "$status_file" || bk_failed
	for list_id in $iplists; do
		bk_file="${bk_dir_new}/${list_id}.${bk_ext:-bak}"
		eval "list_date=\"\$prev_date_${list_id}\""
		[ -z "$list_date" ] && bk_failed
		ipset="${list_id}_${list_date}_${geotag}"

		rm -f "$tmp_file"
		# extract elements and write to $tmp_file
		nft list set inet "$geotable" "$ipset" |
			sed -n -e /"elements[[:space:]]*=[[:space:]]*{"/\{ -e p\;/\}/q\;:1 -e n\; -e p\; -e /\}/q\;b1 -e \} > "$tmp_file"
		[ ! -s "$tmp_file" ] && bk_failed

		[ "$debugmode" ] && bk_len="$(wc -l < "$tmp_file")"
		debugprint "\n$list_id backup length: $bk_len"

		$compr_cmd < "$tmp_file" > "$bk_file"; rv=$?
		[ "$rv" != 0 ] || [ ! -s "$bk_file" ] && bk_failed
	done

	OK

	bk_geocounters
	:
}

# backup up rule counters
bk_geocounters() {
	geochain_cont="$(nft_get_chain "$geochain")" &&
	get_geocounters "$geochain_cont" > "$bk_dir_new/counters.bak"
}

geotable="$geotag"
base_geochain="GEOIP-BASE"
