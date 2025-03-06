#!/bin/sh
# shellcheck disable=SC2154,SC2155,SC2015

# geoip-shell-lib-ipt.sh

# geoip-shell library for interacting with nftables

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

### General

# 1 - family
get_nft_family() {
	case "$1" in ipv4|ipv6) ;; *) echolog -err "get_nft_family: unexpected family '$1'"; nft_family=''; return 1; esac
	nft_family="${1%ipv4}"
	nft_family="ip${nft_family#ipv}"
}

### Tables and chains

# 1 - optional -f for forced re-read
# 1 - direction (inbound|outbound)
is_geochain_on() {
	[ "$1" = '-f' ] && { force_read='-f'; shift; }
	[ "$1" ] || { echolog -err "is_geochain_on: direction not specified"; return 2; }
	set_dir_vars "$1"
	get_matching_line "$(nft_get_chain "$base_geochain" "$force_read")" "*" "${geotag}_enable" "*"
	# returns the rv of above command
}

nft_get_geotable() {
	[ "$1" != "-f" ] && [ -n "$geotable_cont" ] && { printf '%s\n' "$geotable_cont"; return 0; }
	export geotable_cont="$(nft -ta list ruleset inet | sed -n -e /"^table inet $geotable"/\{:1 -e n\;/^\}/q\;p\;b1 -e \})"
	[ -z "$geotable_cont" ] && return 1 || { printf '%s\n' "$geotable_cont"; return 0; }
}

# 1 - chain name
# 2 - optional '-f' for forced re-read
nft_get_chain() {
	_chain_cont="$(nft_get_geotable "$2" | sed -n "/chain $1 {/{:1 n;/^${blank}*}/q;p;b1;}")"
	[ -z "$_chain_cont" ] && return 1 || { printf '%s\n' "$_chain_cont"; return 0; }
}

rm_all_georules() {
	nft_get_geotable -f 1>/dev/null 2>/dev/null || return 0
	get_counters
	printf_s "Removing $p_name firewall rules... "
	export geotable_cont=
	nft delete table inet "$geotable" || { echolog -err -nolog "$FAIL delete table '$geotable'."; return 1; }
	OK
}


### Rules

# shellcheck disable=SC2120
# Encodes rules into alphanumeric (and _) strings
# 1 - (optional) '-n' if no counter included
encode_rules() {
	unset sed_inc_counter_2
	[ "$1" != '-n' ] && sed_inc_counter_2="s/Z*=/=/;s/packetsZ/packets\ /;s/ZbytesZ/\ bytes\ /"

	sed "s/comment//;s/${p_name}[_]*//g;s/${p_name_cap}[_]*//g;s/ct\ state//;s/\"//g;s/\;//g;s/{//g;s/}//g;s/aux_//;s/^${blanks}//;
		s/ifname/if/;s/accept/acpt/g;s/drop/drp/;s/saddr/sa/;s/daddr/da/;s/inbound/in/g;s/outbound/out/g;s/dport/dpt/;
		s/link-local/lnkl/;s/-/_/g;s/\./_/g;s~/~W~g;s/\!=/X/g;s/,/Y/g;s/:/Q/g;s/@/U/;s/${blanks}/Z/g;
		$sed_inc_counter_2"
}

# print current counter values and store them in vars
# 1 - chain contents
get_counters_nft() {
	counter_strings="$(
		nft -ta list ruleset inet | \
		sed -n ":2 /chain $p_name_cap/{:1 n;/^${blank}*}/b2;s/ # handle.*//;/counter${blanks}packets/{s/counter${blanks}//;p;};b1;}" | \
		$awk_cmd 'match($0,/[ 	]packets [0-9]+ bytes [0-9]+/){print substr($0,1,RSTART-1) substr($0,RSTART+RLENGTH) "=" substr($0,RSTART+1,RLENGTH-1)}' | \
		encode_rules
	)"
	:
}

# 1 - chain name
# 2 - current chain contents
# 3... tags list
mk_nft_rm_cmd() {
	chain="$1"; _chain_cont="$2"; shift 2
	[ ! "$chain" ] && { echolog -err "mk_nft_rm_cmd: no chain name specified."; return 1; }
	for tag in "$@"; do
		printf '%s\n' "$_chain_cont" | sed -n "/$tag/{s/^.* # handle/delete rule inet $geotable $chain handle/;s/$/ # $tag/;p;}" || return 1
	done
}

# parses an nft array/list and outputs it in human-readable format
# sets $n to number of elements
get_nft_list() {
	n=0; _res=
	[ "$1" = '!=' ] && { _res='!='; shift; n=$((n+1)); }
	case "$1" in
		'{')
			while :; do
				shift; n=$((n+1))
				[ "$1" = '}' ] && break
				_res="$_res$1"
			done ;;
		*) _res="$_res$1"
	esac
}

# 1 - direction (inbound|outbound)
get_fwrules_iplists() {
	case "$1" in
		inbound) addr_type=saddr ;;
		outbound) addr_type=daddr ;;
		*) echolog -err "get_fw_rules_iplists: direction not specified"; return 1;
	esac
	set_dir_vars "$1"
	nft_get_chain "$geochain" "$force_read" |
	sed -n "/${addr_type}${blank}*@[a-zA-Z0-9_]/{s/.*${addr_type}\s*@//;s/${blanks}.*//;s/@dhcp_4.*/@dhcp_4/;s/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].*//;s/_4/_ipv4/;s/_6/_ipv6/;p;}"
	:
}

### (IP)sets

get_ipsets() {
	nft_get_geotable -f | sed -n "/^${blank}*set${blank}/{s/^${blank}*set${blank}${blank}*//;s/${blank}.*//;p;}"
}

# 1 - ipset tag
# 2 - ipsets
get_ipset_elements() {
    get_matching_line "$2" "" "$1" "*" ipset
    [ "$ipset" ] && nft list set inet "$geotable" "$ipset" |
        sed -n "/elements${blank}*=/{s/elements${blank}*=${blank}*{//;:1 /}/{s/}//;p;q;};p;n;b1;}"
}

# 1 - ipset tag
# 2 - ipsets
cnt_ipset_elements() {
    get_matching_line "$2" "" "$1" "*" ipset
    [ ! "$ipset" ] && { echo 0; return 1; }
    get_ipset_elements "$1" "$2" | wc -w
}

# 1 - ipset tag
# 2 - ipsets
print_ipset_elements() {
	get_ipset_elements "$1" "$2" | $awk_cmd '{gsub(",", "");$1=$1};1' ORS=' '
}

# 1 - direction (inbound|outbound)
report_fw_state() {
	curr_geotable="$(nft_get_geotable)" || {
		printf '%s\n' "$FAIL read the firewall state or firewall table '$geotable' does not exist." >&2
		incr_issues
		return 1
	}

	direction="$1"
	set_dir_vars "$direction"
	is_geochain_on "$direction" && chain_status="${green}enabled $_V" || { chain_status="${red}disabled $_X"; incr_issues; }
	printf '%s\n' "  Geoblocking firewall chain: $chain_status"
	[ "$geomode" = whitelist ] && {
		wl_rule="$(printf %s "$curr_geotable" | grep "drop comment \"${geotag}_${direction}_whitelist_block\"")"
		case "$wl_rule" in
			'') wl_rule_status="$_X"; incr_issues ;;
			*) wl_rule_status="$_V"
		esac
		printf '%s\n' "  whitelist blocking rule: $wl_rule_status"
	}

	if [ "$verb_status" ]; then
		dashes="$(printf '%156s' ' ' | tr ' ' '-')"
		# report geoip rules
		fmt_str="  %-9s%-11s%-5s%-8s%-5s%-24s%-33s%s\n"
		printf "\n%s\n%s\n${fmt_str}%s\n" "  Firewall rules in the $geochain chain:" \
			"  $dashes${blue}" packets bytes ipv verdict prot dports interfaces extra "$n_c  $dashes"
		rules="$(nft_get_chain "$geochain" | sed "s/^${blank}*//;s/ # handle.*//" | grep .)" ||
			{ printf '%s\n' "${red}None $_X"; incr_issues; }
		newifs "$_nl" rules
		for rule in $rules; do
			newifs ' "' wrds
			set -- $rule
			case "$families" in "ipv4 ipv6"|"ipv6 ipv4") dfam="both" ;; *) dfam="$families"; esac
			pkts='---'; bytes='---'; ipv="$dfam"; verd='---'; prot='all'; dports='all'; in='all'; line=''
			while [ -n "$1" ]; do
				case "$1" in
					iifname|oifname) shift; get_nft_list "$@"; in="$_res"; shift "$n" ;;
					ip) ipv="ipv4" ;;
					ip6) ipv="ipv6" ;;
					dport) shift; get_nft_list "$@"; dports="$_res"; shift "$n" ;;
					udp|tcp) prot="$1 " ;;
					packets) pkts=$(num2human "$2"); shift ;;
					bytes) bytes=$(num2human "$2" bytes); shift ;;
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
	for load_ipset in $load_ipsets; do
		nft delete set inet "$geotable" "$load_ipset" 1>/dev/null 2>/dev/null
	done
}

# 1 - (optional) direction
geoip_on() {
	for direction in ${1:-inbound outbound}; do
		set_dir_vars "$direction"
		[ "$geomode" = disable ] && {
			echo "$direction geoblocking mode is set to 'disable' - skipping."
			continue
		}
		get_nft_geoip_state -f "$direction" || return 1
		[ -n "$geochain_on" ] && { echo "${direction} geoblocking is already enabled."; continue; }
		if [ -z "$base_chain_cont" ]; then
			missing_chain="base geoip"
		elif [ -z "$geochain_cont" ]; then
			missing_chain=geoip
		fi
		[ -n "$missing_chain" ] && {
			echolog -err "Cannot enable $direction geoblocking because $direction $missing_chain chain is missing."
			continue
		}

		printf_s "Adding $direction geoblocking enable rule... "
		printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable" | nft -f - &&
			is_geochain_on -f "$direction" || { FAIL; die "$FAIL add $direction geoblocking enable rule."; }
		OK
	done
}

# 1 - (optional) direction
geoip_off() {
	off_ok=
	for direction in ${1:-inbound outbound}; do
		get_nft_geoip_state -f "$direction" || return 1
		[ -z "$geochain_on" ] && { echo "$direction geoblocking is already disabled."; continue; }
		printf %s "Removing the geoblocking enable rule for direction '$direction'... "
		mk_nft_rm_cmd "$base_geochain" "$base_chain_cont" "${geotag}_enable" | nft -f - &&
			! is_geochain_on -f "$direction" ||
				{ FAIL; echolog -err "$FAIL remove $direction geoblocking enable rule."; return 1; }
		off_ok=1
		OK
	done
	[ ! "$off_ok" ] && return 2
	:
}

# populates $geomode, $geochain, $base_geochain, $geotable_cont, $geochain_cont, $base_chain_cont, $geochain_on
# 1 - (optional) '-f' to force re-read geotable
# 1 - direction (inbound|outbound)
get_nft_geoip_state() {
	unset geomode geochain base_geochain geotable_cont geochain_cont base_chain_cont geochain_on
	[ "$1" = '-f' ] && { force_read='-f'; shift; }
	[ "$1" ] || { echolog -err "get_nft_geoip_state: direction not specified"; return 1; }
	set_dir_vars "$1"
	nft_get_geotable "$force_read" 1>/dev/null
	geochain_on=
	is_geochain_on "$1" && geochain_on=1
	geochain_cont="$(nft_get_chain "$geochain")"
	base_chain_cont="$(nft_get_chain "$base_geochain")"
	:
}

apply_rules() {
	print_ipset_rule() {
		case "$3" in
			ip) ipset_flags="" ;;
			net) ipset_flags="flags interval; auto-merge;"
		esac

		printf %s "add set inet $geotable $1 { type ${4}_addr; $ipset_flags policy $nft_perf; "

		case "$1" in
			local_*|allow_*)
				printf %s "elements={ "
				sed '/^$/d;s/$/,/' "$2"
				printf '%s\n' " }; }"
				;;
			*) sed -n '/\}/{s/,*[ 	]*\}/ \}; \}/;p;:1 n;b1;q;};$ {s/$/; \}/};p' "$2"
		esac
	}

	# fall back to 'memory' sets optimization if not set
	: "${nft_perf:=memory}"

	#### MAIN

	### create the table
	nft add table inet "$geotable" || die "$FAIL create table '$geotable'"

	### load ipsets
	printf_s "${_nl}Loading IP lists... "
	for load_ipset in $load_ipsets; do
		get_ipset_id "$load_ipset" || die_a
		[ -f "$iplist_path" ] || { FAIL; die_a "Can not find the iplist file '$iplist_path'."; }

		# count ips in the iplist file
		[ "$debugmode" ] && ip_cnt="$(tr ',' ' ' < "$iplist_path" | sed 's/elements = { //;s/ }//' | wc -w)"
		debugprint "\nip count in the iplist file '$iplist_path': $ip_cnt"

		# read the IP list into new set
		print_ipset_rule "$load_ipset" "$iplist_path" "$ipset_el_type" "$ipset_family" |
			nft -f - || { FAIL; die_a "$FAIL import the iplist from '$iplist_path' into IP set '$load_ipset'."; }

		rm -f "$iplist_path"

		[ "$debugmode" ] && debugprint "elements in $load_ipset: $(sp2nl ipsets "$load_ipsets"; cnt_ipset_elements "$load_ipset" "$ipsets")"
	done
	OK

	#### Assemble commands for nft
	opt_ifaces_gen=
	[ "$ifaces" != all ] && {
		unset br1 br2
		case "$ifaces" in *' '*) br1='{ ' br2=' }'; esac
		opt_ifaces_gen="$br1$(printf '"%s", ' $ifaces)"
		opt_ifaces_gen="${opt_ifaces_gen%", "}$br2"
	}

	printf_s "Assembling nftables commands... "

	nft_get_geotable -f 1>/dev/null
	nft_cmd_chain="$(
		### Remove current rules
		for direction in inbound outbound; do
			set_dir_vars "$direction"
			for chain in "$base_geochain" "$geochain"; do
				case "$geotable_cont" in *"chain $chain "*)
					printf '%s\n%s\n' "flush chain inet $geotable $chain" "delete chain inet $geotable $chain"
				esac
			done
		done

		### Remove old ipsets
		[ "$rm_ipsets" ] && debugprint "deleting ipsets '$rm_ipsets'"
		for rm_ipset in $rm_ipsets; do
			printf '%s\n' "delete set inet $geotable $rm_ipset"
		done

		### Load ipsets for local iplists, allowed subnets/ips
		for family in $families; do
			## local iplists
			[ "$inbound_geomode" != disable ] || [ "$outbound_geomode" != disable ] && {
				for ipset in $local_ipsets; do
					get_ipset_id "$ipset" || exit 1
					[ "$ipset_family" = "$family" ] || continue
					print_ipset_rule "$ipset" "$iplist_path" "$ipset_el_type" "$family"
				done
			}

			unset allow_iplist_file_prev
			for direction in inbound outbound; do
				eval "geomode=\"\$${direction}_geomode\""
				[ "$geomode" = disable ] && continue

				## allow iplists
				set_allow_ipset_vars "$direction" "$family"
				[ "$allow_iplist_file" = "$allow_iplist_file_prev" ] || [ ! -s "$allow_iplist_file" ] && continue
				allow_iplist_file_prev="$allow_iplist_file"
				eval "allow_ipset_type=\"\${allow_ipset_type_${direction}_${family}}\""

				print_ipset_rule "$allow_ipset_name" "$allow_iplist_file" "$allow_ipset_type" "$family"
			done
		done

		### add ipset for dhcpv4 subnets
		is_whitelist_present && {
			case "$families" in *ipv4*)
				printf '%s%s\n' "add set inet $geotable dhcp_4 { type ipv4_addr; flags interval; auto-merge; elements="\
					"{ 192.168.0.0/16, 172.16.0.0/12, 10.0.0.0/8 }; }"
			esac
		}

		### create new rules
		for direction in inbound outbound; do
			set_dir_vars "$direction"
			geopath="inet $geotable $geochain"
			rule_prefix="rule $geopath"

			case "$direction" in
				inbound) hook=prerouting priority=-141 addr_type=saddr iface_keyword=iifname ;;
				outbound) hook=postrouting priority=0 addr_type=daddr iface_keyword=oifname
			esac
			opt_ifaces=
			[ "$opt_ifaces_gen" ] && opt_ifaces="$iface_keyword $opt_ifaces_gen "

			case "$geomode" in
				whitelist) iplist_verdict=accept ;;
				blacklist) iplist_verdict=drop ;;
				disable)
					debugprint "$direction geoblocking mode is 'disable'. Skipping rules creation."
					continue ;;
				*) echolog -err "Unknown geoblocking mode '$geomode'."; exit 1
			esac

			### Create new chains
			printf '%s\n' "add chain inet $geotable $base_geochain { type filter hook $hook priority $priority; policy accept; }"
			printf '%s\n' "add chain $geopath"

			### Create new rules

			## Auxiliary rules

			# add rule to allow lo interface
			[ "$geomode" = whitelist ] && [ "$ifaces" = all ] &&
				printf '%s\n' "add rule $geopath $iface_keyword lo accept comment ${geotag_aux}_loopback"

			# add rule to allow established/related
			printf '%s\n' "add $rule_prefix ${opt_ifaces}ct state established,related accept comment ${geotag_aux}_est-rel"

			# add rules for allowed subnets/ips
			for family in $families; do
				set_allow_ipset_vars "$direction" "$family"
				[ ! -s "$allow_iplist_file" ] && continue
				get_nft_family "$family" || exit 1
				printf '%s\n' "add $rule_prefix $opt_ifaces$nft_family $addr_type @$allow_ipset_name accept comment ${geotag_aux}_allow"
			done

			# add rules to allow DHCP
			[ "$geomode" = whitelist ] && {
				for family in $families; do
					get_nft_family "$family" || exit 1
					f_short="${family#ipv}"
					case "$f_short" in
						6)
							dhcp_addr="fc00::/6"
							dhcp_dports="546, 547" ;;
						4)
							dhcp_addr="@dhcp_4"
							dhcp_dports="67, 68"
					esac
					rule_DHCP_1="$opt_ifaces$nft_family $addr_type $dhcp_addr udp dport { $dhcp_dports }"
					rule_DHCP_2="accept comment \"${geotag_aux}_DHCP_${f_short}\""
					get_counter_val "$rule_DHCP_1 $rule_DHCP_2"
					printf '%s\n' "add $rule_prefix $rule_DHCP_1 counter $counter_val $rule_DHCP_2"

				done
			}

			# add rules for ports
			for proto in tcp udp; do
				eval "ports_exp=\"\${${direction}_${proto}_ports%:*}\" ports=\"\${${direction}_${proto}_ports##*:}\""
				debugprint "$direction $proto ports_exp: '$ports_exp', ports: '$ports'"
				case "$ports_exp" in
					skip) continue ;;
					all) ports_exp="meta l4proto $proto" ;;
					'') echolog -err "\$ports_exp is empty string for direction '$direction'"; exit 1 ;;
					*)
						unset br1 br2
						case "$ports" in *','*)
							br1='{ ' br2=' }'
							ports="$(printf %s "$ports" | sed 's/,/, /g')"
						esac
						ports_exp="$proto $(printf %s "$ports_exp" | sed "s/multiport //;s/!dport/dport !=/") $br1$ports$br2"
				esac
				rule_ports_pt1="$opt_ifaces$ports_exp"
				rule_ports_pt2="accept comment \"${geotag_aux}_ports\""
				get_counter_val "$rule_ports_pt1 $rule_ports_pt2"
				printf '%s\n' "add $rule_prefix $rule_ports_pt1 counter $counter_val $rule_ports_pt2"
			done

			eval "planned_ipsets_direction=\"\${planned_ipsets_${direction}}\""
			debugprint "$direction planned ipsets: '$planned_ipsets_direction'"

			# add rules for local iplists
			for family in $families; do
				for ipset in $local_block_ipsets $local_allow_ipsets; do
					get_ipset_id "$ipset" &&
					get_nft_family "$ipset_family" || exit 1
					[ "$ipset_family" = "$family" ] || continue
					rule_ipset="$opt_ifaces$nft_family $addr_type @$ipset"
					case "$ipset" in
						*_allow_*) local_verdict=accept ;;
						*_block_*) local_verdict=drop
					esac
					get_counter_val "$rule_ipset $local_verdict"
					printf '%s\n' "add $rule_prefix $rule_ipset counter $counter_val $local_verdict comment ${geotag}"
				done
			done

			# add rules for country codes
			for ipset in $planned_ipsets_direction; do
				case "$ipset" in local_*) continue; esac
				get_ipset_id "$ipset" &&
				get_nft_family "$ipset_family" || exit 1
				rule_ipset="$opt_ifaces$nft_family $addr_type @$ipset"
				get_counter_val "$rule_ipset $iplist_verdict"
				printf '%s\n' "add $rule_prefix $rule_ipset counter $counter_val $iplist_verdict comment ${geotag}"
			done

			# add whitelist blocking rule
			[ "$geomode" = whitelist ] && {
				rule_wl_pt2="drop comment \"${geotag}_${direction}_whitelist_block\""
				get_counter_val "$opt_ifaces$rule_wl_pt2"
				printf '%s\n' "add $rule_prefix ${opt_ifaces}counter $counter_val $rule_wl_pt2"
			}

			# add geoblocking enable rule
			[ "$noblock" = false ] && printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable"
		done

		:
	)" || die_a 254 "$FAIL assemble nftables commands."
	OK

	#### Apply new rules
	[ "$debugmode" ] && printf '\n%s\n%s\n\n' "Rules:" "$nft_cmd_chain" >&2
	printf_s "Applying new firewall rules... "
	nft_output="$(printf '%s\n' "$nft_cmd_chain" | nft -f - 2>&1)" || {
		FAIL
		echolog -err "$FAIL apply new firewall rules"
		echolog "nftables errors: '$(printf %s "$nft_output" | sed "s/${blank}*\^\^\^[\^]*${blank}*/ /g" | tr '\n' ' ' | head -c 1k)'"
		die
	}

	OK

	#### Update ports in config
	nft_get_geotable -f >/dev/null
	ports_conf=
	ports_exp=
	for direction in inbound outbound; do
		set_dir_vars "$direction"
		[ "$geomode" = disable ] && continue
		for proto in tcp udp; do
			eval "ports_exp=\"\$${direction}_${proto}_ports\""
			case "$ports_exp" in skip|all) continue; esac
			ports_line="$(nft_get_chain "$geochain" | grep -m1 -o "${proto} dport.*${geotag_aux}_ports")"

			IFS=' 	' set -- $ports_line; shift 2
			get_nft_list "$@"; ports_exp="$_res"
			unset mp neg
			case "$ports_exp" in *','*) mp="multiport "; esac
			case "$ports_exp" in *'!'*) neg='!'; esac
			ports_conf="$ports_conf${direction}_${proto}_ports=$mp${neg}dport:${ports_exp#*"!="}$_nl"
		done
	done
	[ "$ports_conf" ] && setconfig "${ports_conf%"$_nl"}"

	:
}

# extracts IP lists from backup
extract_iplists() {
	printf_s "Restoring IP lists from backup... "
	dir_mk -n "$iplist_dir" || rstr_failed
	for list_id in $iplists; do
		bk_file="$bk_dir/$list_id.$bk_ext"
		iplist_file="$iplist_dir/${list_id}.iplist"

		[ ! -s "$bk_file" ] && rstr_failed "'$bk_file' is empty or doesn't exist."

		# extract elements and write to $iplist_file
		$extract_cmd "$bk_file" > "$iplist_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
		[ ! -s "$iplist_file" ] && rstr_failed "$FAIL extract IP list for $list_id."
		[ "$debugmode" ] && debugprint "\nLines count in $list_id backup: $(wc -w < "$iplist_file")"
	done
	OK
	:
}

# Saves current firewall state to a backup file
create_backup() {
	# back up current IP sets
	getstatus "$status_file" || bk_failed
	for list_id in $iplists; do
		bk_file="${bk_dir_new}/${list_id}.${bk_ext:-bak}"
		eval "list_date=\"\$prev_date_${list_id}\""
		[ -z "$list_date" ] && bk_failed "$FAIL get date for IP list '$list_id'."
		list_id_short="${list_id%%_*}_${list_id##*ipv}"
		ipset="${list_id_short}_${list_date}"

		rm -f "$tmp_file"
		# extract elements and write to $tmp_file
		nft list set inet "$geotable" "$ipset" |
			sed -n "/elements${blank}*=${blank}*{/{s/${blanks}//g;p;/\}/q;:1 n;s/${blanks}//;p;/\}/q;b1;}" \
				> "$tmp_file" && [ -s "$tmp_file" ] ||
					bk_failed "${_nl}$FAIL create backup of the ipset for iplist ID '$list_id'."

		[ "$debugmode" ] && bk_len="$(wc -l < "$tmp_file")"
		debugprint "\n$list_id backup length: $bk_len"

		$compr_cmd < "$tmp_file" > "$bk_file" || bk_failed "$compr_cmd exited with status $? for IP list '$list_id'."
		[ -s "$bk_file" ] || bk_failed "resulting compressed file for '$list_id' is empty or doesn't exist."
	done
	:
}

geotable="$geotag"
inbound_base_geochain=${p_name_cap}_BASE_IN outbound_base_geochain=${p_name_cap}_BASE_OUT
