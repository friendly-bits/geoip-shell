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
	_chain_cont="$(nft_get_geotable "$2" | sed -n -e /"chain $1 {"/\{:1 -e n\;/"^[[:blank:]]*}"/q\;p\;b1 -e \})"
	[ -z "$_chain_cont" ] && return 1 || { printf '%s\n' "$_chain_cont"; return 0; }
}

rm_all_georules() {
	nft_get_geotable -f 1>/dev/null 2>/dev/null || return 0
	get_counters
	printf %s "Removing $p_name firewall rules... "
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

	sed "s/ifname/if/;s/accept/acpt/g;s/drop/drp/;s/comment//;s/${p_name}[_]*//g;s/${p_name_cap}[_]*//g;s/ct\ state//;
		s/\"//g;s/\;//g;s/saddr/sa/;s/daddr/da/;s/aux_//;s/inbound/in/g;s/outbound/out/g;s/dport/dpt/;s/link-local/lnkl/;
		s/-/_/g;s~/~W~g;s/\!=/X/g;s/,/Y/g;s/:/Q/g;s/{//g;s/}//g;s/@/U/;s/^${blanks}//;s/${blanks}/Z/g;
		$sed_inc_counter_2"
}

# print current counter values and store them in vars
# 1 - chain contents
get_counters_nft() {
	counter_strings="$(
		nft -ta list ruleset inet | \
		sed -n ":2 /chain $p_name_cap/{:1 n;/^[[:blank:]]*}/b2;s/ # handle.*//;/counter${blanks}packets/{s/counter${blanks}//;p;};b1;}" | \
		awk 'match($0,/[[:blank:]]packets [0-9]+ bytes [0-9]+/){print substr($0,1,RSTART-1) substr($0,RSTART+RLENGTH) "=" substr($0,RSTART+1,RLENGTH-1)}' | \
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
		sed -n "/${addr_type}[[:blank:]]*@[A-Z][A-Z]_[0-9]_.*${nft_verdict}/{s/.*@//;s/_[0-9][0-9][0-9][0-9].*//;s/_/_ipv/;p;}"
	:
}

### (ip)sets

get_ipset_id() {
	list_id_temp="${1%_*}"
	ipv="${list_id_temp#???}"
	family="ipv${ipv}"
	list_id="${1%%_*}_${family}"
	case "$family" in
		ipv4|ipv6) return 0 ;;
		*) echolog -err "ip set name '$1' has unexpected format."
			unset family list_id
			return 1
	esac
}

get_ipsets() {
	nft_get_geotable -f | sed -n '/^[[:blank:]]*set[[:blank:]]/{s/^[[:blank:]]*set[[:blank:]][[:blank:]]*//;s/[[:blank:]].*//;p;}'
}

get_ipset_iplists() {
	get_ipsets | sed -n '/[A-Z][A-Z]_[46]_..........$/{s/_..........$//;s/_/_ipv/;p;}'
}

# 1 - ipset tag
# 2 - ipsets
get_ipset_elements() {
    get_matching_line "$2" "" "$1" "*" ipset
    [ "$ipset" ] && nft list set inet "$geotable" "$ipset" |
        sed -n -e /"elements[[:blank:]]*=/{s/elements[[:blank:]]*=[[:blank:]]*{//;:1" -e "/}/{s/}//"\; -e p\; -e q\; -e \}\; -e p\; -e n\;b1 -e \}
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
	get_ipset_elements "$1" "$2" | awk '{gsub(",", "");$1=$1};1' ORS=' '
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
		rules="$(nft_get_chain "$geochain" | sed 's/^[[:blank:]]*//;s/ # handle.*//' | grep .)" ||
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
	for direction in inbound outbound; do
		set_dir_vars "$direction"
		[ "$geomode" = disable ] && {
			echo "$direction geoblocking mode is set to 'disable' - skipping."
			continue
		}
		get_nft_geoip_state -f "$direction" || return 1
		[ -n "$geochain_on" ] && { echo "${direction} geoblocking chain is already enabled."; continue; }
		if [ -z "$base_chain_cont" ]; then
			missing_chain="base geoip"
		elif [ -z "$geochain_cont" ]; then
			missing_chain=geoip
		fi
		[ -n "$missing_chain" ] && {
			echolog -err "Cannot enable $direction geoblocking on because $direction $missing_chain chain is missing."
			continue
		}

		printf %s "Adding $direction geoblocking enable rule... "
		printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable" | nft -f - &&
			is_geochain_on -f "$direction" || { FAIL; die "$FAIL add $direction geoblocking enable rule."; }
		OK
	done
}

geoip_off() {
	for direction in inbound outbound; do
		get_nft_geoip_state -f "$direction" || return 1
		[ -z "$geochain_on" ] && { echo "$direction geoblocking chain is already disabled."; continue; }
		printf %s "Removing $direction geoblocking enable rule... "
		mk_nft_rm_cmd "$base_geochain" "$base_chain_cont" "${geotag}_enable" | nft -f - &&
			! is_geochain_on -f "$direction" || { FAIL; die "$FAIL remove $direction geoblocking enable rule."; }
		OK
	done
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
	#### Variables

	: "${nft_perf:=memory}"

	#### MAIN

	getstatus "$status_file" || die "$FAIL read the status file '$status_file'."
	curr_ipsets="$(get_ipsets)"

	unset old_ipsets new_ipsets

	for direction in inbound outbound; do
		unset "new_ipsets_$direction"
		eval "list_ids=\"\$${direction}_list_ids\"
			geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && {
			debugprint "apply_rules: $direction geomode is disable - skipping"
			continue
		}

		# generate lists of $new_ipsets and $old_ipsets
		for list_id in $list_ids; do
			case "$list_id" in *_*) ;; *) die "Invalid iplist id '$list_id'."; esac
			family="${list_id#*_}"
			eval "list_date=\"\$prev_date_${list_id}\""
			[ ! "$list_date" ] && die "$FAIL read value for 'prev_date_${list_id}' from file '$status_file'."
			list_id_short="${list_id%%_*}_${list_id##*ipv}"
			ipset="${list_id_short}_${list_date}"
			case "$action" in add|update) add2list "new_ipsets_$direction" "$ipset"; esac
			case "$curr_ipsets" in
				*"$ipset"*)
					case "$action" in add|update) printf '%s\n' "Ip set for '$list_id' is already up-to-date."; continue; esac
					add2list old_ipsets "$ipset" ;;
				*"$list_id_short"*)
					get_matching_line "$curr_ipsets" "" "$list_id_short" "*" old_ipset
					add2list old_ipsets "$old_ipset"
			esac
			case "$action" in add|update) add2list new_ipsets "$ipset"; esac
		done

		for family in ipv4 ipv6; do
			for ipset_type in trusted lan; do
				ipset_name="${ipset_type}_${family#ipv}"
				case "$curr_ipsets" in *"$ipset_name"*) add2list old_ipsets "$ipset_name"; esac
			done
		done
	done

	debugprint "new ipsets: '$new_ipsets'"
	debugprint "old ipsets: '$old_ipsets'"

	### create the table
	nft add table inet "$geotable" || die "$FAIL create table '$geotable'"

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
			printf %s "add set inet $geotable $new_ipset \
				{ type ${family}_addr; flags interval; auto-merge; policy $nft_perf; "
			sed '/\}/{s/,*[[:blank:]]*\}/ \}; \}/;q;};$ {s/$/; \}/}' "$iplist_file"
		} | nft -f - || die_a "$FAIL import the iplist from '$iplist_file' into ip set '$new_ipset'."
		OK

		[ "$debugmode" ] && debugprint "elements in $new_ipset: $(sp2nl ipsets "$new_ipsets"; cnt_ipset_elements "$new_ipset" "$ipsets")"
	done


	#### Assemble commands for nft
	opt_ifaces_gen=
	[ "$ifaces" != all ] && {
		unset br1 br2
		case "$ifaces" in *' '*) br1='{ ' br2=' }'; esac
		opt_ifaces_gen="$br1$(printf '"%s", ' $ifaces)"
		opt_ifaces_gen="${opt_ifaces_gen%", "}$br2"
	}

	printf %s "Assembling nftables commands... "
	nft_get_geotable -f >/dev/null
	nft_cmd_chain="$(
		## Remove old ipsets and their rules
		for direction in inbound outbound; do
			get_nft_geoip_state "$direction"
			for old_ipset in $old_ipsets; do
				mk_nft_rm_cmd "$geochain" "$geochain_cont" "$old_ipset" || exit 1
			done
		done
		for old_ipset in $old_ipsets; do
			printf '%s\n' "delete set inet $geotable $old_ipset"
		done

		# add ipsets for trusted subnets/ips
		for family in $families; do
			ipset_name="trusted_${family#ipv}"
			eval "trusted=\"\$trusted_$family\""
			interval=
			case "${trusted%%":"*}" in net|ip)
				[ "${trusted%%":"*}" = net ] && interval="flags interval; auto-merge;"
				trusted="${trusted#*":"}"
			esac

			[ -n "$trusted" ] && {
				printf %s "add set inet $geotable $ipset_name { type ${family}_addr; $interval elements={ "
				printf '%s,' $trusted
				printf '%s\n' " }; }"
			}
		done

		# add ipsets for LAN subnets/ips
		is_whitelist_present && {
			for family in $families; do
				ipset_name="lan_${family#ipv}"
				if [ ! "$autodetect" ]; then
					eval "lan_ips=\"\$lan_ips_$family\""
				else
					a_d_failed=
					lan_ips="$(call_script "${i_script}-detect-lan.sh" -s -f "$family")" || a_d_failed=1
					[ ! "$lan_ips" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL detect $family LAN subnets."; exit 1; }
					nl2sp lan_ips "net:$lan_ips"
					eval "lan_ips_$family=\"$lan_ips\""
				fi

				interval=
				[ "${lan_ips%%":"*}" = net ] && interval="flags interval; auto-merge;"
				lan_ips="${lan_ips#*":"}"
				[ -n "$lan_ips" ] && {
					printf %s "add set inet $geotable $ipset_name { type ${family}_addr; $interval elements={ "
					printf '%s,' $lan_ips
					printf '%s\n' " }; }"
				}
			done
			[ -n "$lan_ips_ipv4$lan_ips_ipv6" ] && [ "$autodetect" ] && setconfig lan_ips_ipv4 lan_ips_ipv6
		}

		for direction in inbound outbound; do
			set_dir_vars "$direction"
			case "$direction" in
				inbound) hook=prerouting priority=-141 addr_type=saddr iface_keyword=iifname ;;
				outbound) hook=postrouting priority=0 addr_type=daddr iface_keyword=oifname
			esac
			opt_ifaces=
			[ "$opt_ifaces_gen" ] && opt_ifaces=" $iface_keyword $opt_ifaces_gen"

			## Read current firewall geoip rules
			get_nft_geoip_state "$direction" || exit 1
			geopath="inet $geotable $geochain"

			## Remove the whitelist blocking rule and the auxiliary rules
			[ "$geochain_cont" ] && {
				mk_nft_rm_cmd "$geochain" "$geochain_cont" "${geotag}_${direction}_whitelist_block" "${geotag_aux}_DHCPv6" \
					 "${geotag_aux}_link-local" "${geotag_aux}_ports" "${geotag_aux}_est-rel" "${geotag_aux}-loopback" || exit 1
			}

			## Remove the geoip enable rule
			[ "$base_chain_cont" ] &&
				{ mk_nft_rm_cmd "$base_geochain" "$base_chain_cont" "${geotag}_enable" || exit 1; }

			case "$geomode" in
				whitelist) iplist_verdict=accept ;;
				blacklist) iplist_verdict=drop ;;
				disable)
					debugprint "$direction geoblocking mode is 'disable'. Skipping rules creation."
					continue ;;
				*) echolog -err "Unknown geoblocking mode '$geomode'."; exit 1
			esac

			# Create the chains
			[ ! "$base_chain_cont" ] &&
				printf '%s\n' "add chain inet $geotable $base_geochain { type filter hook $hook priority $priority; policy accept; }"
			[ ! "$geochain_cont" ] && printf '%s\n' "add chain $geopath"

			### Create new rules

			## Auxiliary rules

			# trusted subnets/ips
			for family in $families; do
				ipset_name="trusted_${family#ipv}"
				eval "trusted=\"\$trusted_$family\""
				[ -n "$trusted" ] && {
					get_nft_family
					printf '%s\n' "insert rule $geopath$opt_ifaces $nft_family $addr_type @$ipset_name accept comment ${geotag_aux}_trusted"
				}
			done

			[ "$geomode" = whitelist ] && {
				# LAN subnets/ips
				for family in $families; do
					ipset_name="lan_${family#ipv}"
					eval "lan_ips=\"\$lan_ips_$family\""
					[ -n "$lan_ips" ] && {
						get_nft_family
						printf '%s\n' "insert rule $geopath$opt_ifaces $nft_family $addr_type @$ipset_name accept comment ${geotag_aux}_lan"
					}
				done

				# Allow DHCPv6
				[ "$ifaces" != all ] || [ "$direction" = outbound ] && {
					rule_DHCPv6_1="ip6 saddr fc00::/6 ip6 daddr fc00::/6 udp dport 546"
					rule_DHCPv6_2="accept comment \"${geotag_aux}_DHCPv6\""
					get_counter_val "$rule_DHCPv6_1 $rule_DHCPv6_2"
					printf '%s\n' "insert rule $geopath$opt_ifaces $rule_DHCPv6_1 counter $counter_val $rule_DHCPv6_2"
				}

				# Allow link-local
				rule_LL_1="ip6 $addr_type fe80::/10"
				rule_LL_2="accept comment \"${geotag_aux}_link-local\""
				get_counter_val "$rule_LL_1 $rule_LL_2"
				printf '%s\n' "insert rule $geopath$opt_ifaces $rule_LL_1 counter $counter_val $rule_LL_2"

				# leaving DHCP v4 allow disabled for now because it's unclear that it is needed
				# printf '%s\n' "add rule $geopath$opt_ifaces meta nfproto ipv4 udp dport 68 counter accept comment ${geotag_aux}_DHCP"
			}

			# ports
			for proto in tcp udp; do
				eval "ports_exp=\"\${${direction}_${proto}_ports%:*}\" ports=\"\${${direction}_${proto}_ports##*:}\""
				debugprint "$direction ports_exp: '$ports_exp', ports: '$ports'"
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
				rule_ports_pt2="accept comment \"${geotag_aux}_ports\""
				get_counter_val "$ports_exp $rule_ports_pt2"
				printf '%s\n' "insert rule $geopath$opt_ifaces $ports_exp counter $counter_val $rule_ports_pt2"
			done

			# established/related
			printf '%s\n' "insert rule $geopath$opt_ifaces ct state established,related accept comment ${geotag_aux}_est-rel"

			# lo interface
			[ "$geomode" = whitelist ] && [ "$ifaces" = all ] &&
				printf '%s\n' "insert rule $geopath $iface_keyword lo accept comment ${geotag_aux}-loopback"

			## add iplist-specific rules
			eval "new_ipsets_direction=\"\${new_ipsets_${direction}}\""
			debugprint "$direction new ipsets: '$new_ipsets_direction'"
			for new_ipset in $new_ipsets_direction; do
				get_ipset_id "$new_ipset" || exit 1
				get_nft_family
				rule_ipset="$nft_family $addr_type @$new_ipset"
				get_counter_val "$rule_ipset $iplist_verdict"
				mk_nft_rm_cmd "$geochain" "$geochain_cont" "${new_ipset}"
				printf '%s\n' "add rule $geopath$opt_ifaces $rule_ipset counter $counter_val $iplist_verdict comment ${geotag}"
			done

			## whitelist blocking rule
			[ "$geomode" = whitelist ] && {
				rule_wl_pt2="drop comment \"${geotag}_${direction}_whitelist_block\""
				get_counter_val "$rule_wl_pt2"
				printf '%s\n' "add rule $geopath$opt_ifaces counter $counter_val $rule_wl_pt2"
			}

			## geoip enable rule
			[ "$noblock" = false ] && printf '%s\n' "add rule inet $geotable $base_geochain jump $geochain comment ${geotag}_enable"
		done

		exit 0
	)" || die_a 254 "$FAIL assemble nftables commands."
	OK

	# printf '%s\n' "new rules: $_nl'$nft_cmd_chain'" >&2

	### Apply new rules
	printf %s "Applying new firewall rules... "
	printf '%s\n' "$nft_cmd_chain" | nft -f - || die_a "$FAIL apply new firewall rules"
	OK

	# update ports in config
	nft_get_geotable -f >/dev/null
	ports_conf=
	ports_exp=
	for direction in inbound outbound; do
		set_dir_vars "$direction"
		[ "$geomode" = disable ] && continue
		for proto in tcp udp; do
			eval "ports_exp=\"\$${direction}_${proto}_ports\""
			case "$ports_exp" in skip|all) continue; esac
			ports_line="$(nft_get_chain "$geochain" | grep -m1 -o "${proto} dport.*")"

			IFS=' 	' set -- $ports_line; shift 2
			get_nft_list "$@"; ports_exp="$_res"
			unset mp neg
			case "$ports_exp" in *','*) mp="multiport "; esac
			case "$ports_exp" in *'!'*) neg='!'; esac
			ports_conf="$ports_conf${direction}_${proto}_ports=$mp${neg}dport:${ports_exp#*"!="}$_nl"
		done
	done
	[ "$ports_conf" ] && setconfig "${ports_conf%"$_nl"}"

	[ "$noblock" = true ] && echolog -warn "Geoblocking is disabled via config."

	echo

	:
}

# extracts ip lists from backup
extract_iplists() {
	printf %s "Restoring ip lists from backup... "
	mkdir -p "$iplist_dir"
	for list_id in $iplists; do
		bk_file="$bk_dir/$list_id.$bk_ext"
		iplist_file="$iplist_dir/${list_id}.iplist"

		[ ! -s "$bk_file" ] && rstr_failed "'$bk_file' is empty or doesn't exist."

		# extract elements and write to $iplist_file
		$extract_cmd "$bk_file" > "$iplist_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
		[ ! -s "$iplist_file" ] && rstr_failed "$FAIL extract ip list for $list_id."
		[ "$debugmode" ] && debugprint "\nLines count in $list_id backup: $(wc -c < "$iplist_file")"
	done
	OK
	:
}

# Saves current firewall state to a backup file
create_backup() {
	# back up current ip sets
	printf %s "Creating backup of $p_name ip sets... "
	getstatus "$status_file" || bk_failed
	for list_id in $iplists; do
		bk_file="${bk_dir_new}/${list_id}.${bk_ext:-bak}"
		eval "list_date=\"\$prev_date_${list_id}\""
		[ -z "$list_date" ] && bk_failed "$FAIL get date for ip list '$list_id'."
		list_id_short="${list_id%%_*}_${list_id##*ipv}"
		ipset="${list_id_short}_${list_date}"

		rm -f "$tmp_file"
		# extract elements and write to $tmp_file
		nft list set inet "$geotable" "$ipset" |
			sed -n -e /"elements[[:blank:]]*=[[:blank:]]*{"/\{ -e s/[[:blank:]][[:blank:]]*//g\; -e p\;/\}/q\;:1 -e n\; -e s/[[:blank:]][[:blank:]]*//\; -e p\; -e /\}/q\;b1 -e \} \
				> "$tmp_file"
		[ ! -s "$tmp_file" ] && bk_failed "tmp file for '$list_id' is empty or doesn't exist."

		[ "$debugmode" ] && bk_len="$(wc -l < "$tmp_file")"
		debugprint "\n$list_id backup length: $bk_len"

		$compr_cmd < "$tmp_file" > "$bk_file" || bk_failed "$compr_cmd exited with status $? for ip list '$list_id'."
		[ -s "$bk_file" ] || bk_failed "resulting compressed file for '$list_id' is empty or doesn't exist."
	done

	OK
	:
}

geotable="$geotag"
inbound_base_geochain=${p_name_cap}_BASE_IN outbound_base_geochain=${p_name_cap}_BASE_OUT
