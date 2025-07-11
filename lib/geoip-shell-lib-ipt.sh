#!/bin/sh
# shellcheck disable=SC2154,SC2034,SC1090,SC2120,SC2015,SC2016

# geoip-shell-lib-ipt.sh

# geoip-shell library for interacting with iptables

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


# 1 - family
set_ipt_cmds() {
	case "$1" in ipv4) f_ic='' ;; ipv6) f_ic=6 ;; *) echolog -err "set_ipt_cmds: Unexpected family '$1'."; return 1; esac
	ipt_cmd="ip${f_ic}tables -t $ipt_table"
	ipt_save="ip${f_ic}tables-save -t $ipt_table"
	ipt_save_cmd="${ipt_save} | grep -i $geotag"
	ipt_save_cmd_c="${ipt_save} -c | grep -i $geotag"
	ipt_restore_cmd="ip${f_ic}tables-restore -n"
	:
}

# 1 - family
test_read_ipt() {
	set_ipt_cmds "$1" &&
	eval "$ipt_save" 1>/dev/null || { echolog -err "$FAIL get $family iptables rules."; return 1; }
}

# 1 - family
# 2 - (optional) -c
ipt_save() {
	set_ipt_cmds "$1" || return 1
	case "$2" in
		'') eval "$ipt_save_cmd" ;;
		'-c') eval "$ipt_save_cmd_c"
	esac
	:
}

get_ipsets() {
	ipset list -n | grep "$geotag"
}

get_ext_ipsets() {
	ipset list -t
}

# 1 - ipset tag
print_ipset_elements() {
	get_matching_line "$2" "*" "$1" "*" &&
		ipset list "${geotag}_${1}" | sed -n -e /"Members:"/\{:1 -e n\; -e p\; -e b1\; -e \} | tr '\n' ' '
}

# 1 - ipset tag
# 2 - ipsets
cnt_ipset_elements() {
	printf %s "$2" |
		sed -n -e /"$1"/\{:1 -e n\;/maxelem/\{s/.*maxelem\ //\; -e s/\ .*//\; -e p\; -e q\; -e \}\;b1 -e \} |
			grep . || echo 0
}

# 1 - current iptables contents
# additional args - iptables tags
mk_ipt_rm_cmd() {
	[ "$1" ] || return 0
	curr_ipt="$1"
	shift
	mirc_tags=
	for mirc_tag in "$@"; do
		[ ! "$mirc_tag" ] && continue
		mirc_tags="$mirc_tags$mirc_tag|"
	done
	[ "$mirc_tags" ] || { echolog -err "mk_ipt_rm_cmd: no tags provided"; return 1; }
	printf '%s\n' "$curr_ipt" | grep -E -- "${mirc_tags}mirc_dummy" | sed '{s/^\[.*\]//;s/-A /-D /}' || return 1
	:
}

# 1 - current ipt contents
# 2 - family
# extra args: iptables tags
rm_ipt_rules() {
	[ "$1" ] || return 0
	case "$2" in ipv4|ipv6) ;; *) echolog -err "rm_ipt_rules: Unexpected family '$2'."; return 1; esac
	curr_ipt="$1"
	family="$2"
	shift 2
	set_ipt_cmds "$family" || return 1
	tags=
	for tag in "$@"; do
		[ ! "$tag" ] && continue
		tags="$tags'$tag', "
	done
	[ "$tags" ] || { echolog -err "rm_ipt_rules: no tags provided"; return 1; }
	printf %s "Removing $family iptables rules tagged ${tags%, }... "
	{
		printf '%s\n' "*$ipt_table"
		mk_ipt_rm_cmd "$curr_ipt" "$@" || return 1
		printf '%s\n' "COMMIT"
	} | eval "$ipt_restore_cmd" || { FAIL; echolog -err "rm_ipt_rules: $FAIL remove firewall rules."; return 1; }
	OK
}

rm_all_georules() {
	get_counters
	for family in ipv4 ipv6; do
		test_read_ipt "$family" || return 1
		f_short="${family#ipv}"
		curr_ipt="$(ipt_save "$family" -c)"
		rm_ipt_rules "$curr_ipt" "$family" "${geotag}_enable"
		for direction in inbound outbound; do
			set_dir_vars "$direction"
			# remove the iface chain if it exists
			printf '%s\n' "$curr_ipt" | grep "$iface_chain" >/dev/null && {
				printf_s "Removing $direction $family chain '$iface_chain'... "
				printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $iface_chain" "-X $iface_chain" "COMMIT" |
					eval "$ipt_restore_cmd" && OK || { FAIL; return 1; }
			}
			# remove the main geoblocking chain
			printf '%s\n' "$curr_ipt" | grep "$geochain" >/dev/null && {
				printf_s "Removing $direction $family chain '$geochain'... "
				printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $geochain" "-X $geochain" "COMMIT" | eval "$ipt_restore_cmd" && OK ||
					{ FAIL; return 1; }
			}
		done
	done

	# remove ipsets
	rm_ipsets_rv=0
	unisleep
	printf_s "Destroying $p_name ipsets... "
	for ipset in $(ipset list -n | grep "$geotag"); do
		ipset destroy "$ipset" || { rm_ipsets_rv=1; continue; }
	done
	[ "$rm_ipsets_rv" = 0 ] && OK || FAIL
	return "$rm_ipsets_rv"
}

get_fwrules_iplists() {
	case "$1" in
		inbound) dir_kwrd_ipset=src ;;
		outbound) dir_kwrd_ipset=dst ;;
		*) echolog -err "get_fw_rules_iplists: direction not specified"; return 1;
	esac
	set_dir_vars "$1"
	p="$p_name"
	for family in ipv4 ipv6; do
		test_read_ipt "$family" || return 1
	done
	{ ipt_save ipv4; ipt_save ipv6; } |
		sed -n "/match-set${blanks}${p}_.*${blanks}${dir_kwrd_ipset}/{s/.*match-set${blanks}${p}_//;s/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]//;s/${blanks}${dir_kwrd_ipset}.*//;s/_4/_ipv4/;s/_6/_ipv6/;p;}"
}

critical() {
	FAIL
	echolog -err "Removing geoip rules..."
	rm_all_georules
	set +f; rm -f "$iplist_dir/"*.iplist; set -f
	die "$1"
}

destroy_tmp_ipsets() {
	echolog -err "Destroying temporary ipsets..."
	for tmp_ipset in $(ipset list -n | grep "$p_name" | grep "_t$" | tr '\n' ' ') $new_ipsets; do
		ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null
	done
}

# Encodes rules into alphanumeric (and _) strings
# 1 - (optional) '-n' if no counter included
# 1 - family
encode_rules() {
	unset sed_inc_counter_1 sed_inc_counter_2
	sed_colon_rm=g

	if [ "$1" = '-n' ]; then
		shift
	else
		sed_inc_counter_1="/^${blank}*\\[.*\\]/{"
		sed_inc_counter_2=";}"
		sed_colon_res="s/Q/:/;"
	fi

	[ "$1" ] || { echolog -err "encode_rules: family not set"; return 1; }
	sed -n "${sed_inc_counter_1}s/${blanks}-A${blanks}//;
		s/$p_name//g;s/${p_name_cap}//g;s/-m set --match-set//;s/--ctstate//;
		s/${ipt_comm}${blank}${notblank}*//g;s/-m conntrack//g;s/-m multiport//g;s/-m udp//;s/_//g;
		s~/~W~g;s/-/_/g;s/\./_/g;s/!/X/g;s/:/Q/g;${sed_colon_res}s/,/Y/g;
		s/${blanks}/Z/g;s/\$/_${1#ipv}/;/^$/d;p${sed_inc_counter_2}"
}

# Get counters from existing rules and store them in $counter_strings
get_counters_ipt() {
	for f in $families; do
		curr_ipt="$(ipt_save "$f" -c)"
		case "$curr_ipt" in *":$inbound_geochain "*|*":$outbound_geochain "*) ;; *) return 1; esac
		eval "${f}_ipt"='$curr_ipt'
	done
	counter_strings="$(
		# encode rules in [[:alnum:]_] strings, generate variable assignments
		for f in $families; do
			eval "curr_ipt=\"\$${f}_ipt\""
			[ "$curr_ipt" ] && printf '%s\n' "$curr_ipt" | encode_rules "$f"
		done | $awk_cmd -F "]" '$2 ~ /^[a-zA-Z0-9_]+$/ {print $2 "=" $1 "]"}'
	)"
	:
}

load_ipsets() {
	printf_s "${_nl}Creating new ipsets... "

	newifs "$_nl" loi
	for entry in ${ipsets_to_add%"${_nl}"}; do
		IFS=' '
		set -- $entry
		oldifs loi

		[ $# -ge 6 ] || { FAIL; echolog -err "load_ipsets: invalid entry '$*'"; return 1; }

		case "$2" in
			ip|net) ;;
			*) FAIL; echolog -err "load_ipsets: Invalid ipset type '$2' in entry '$*'"; return 1
		esac

		ipset_name="$1" ipset_type="$2" family_li="$3" ipset_maxelem="$4" ipset_hs="$5"
		shift 5
		get_ipset_id "$ipset_name" || return 1
		ipset destroy "$ipset_name" 1>/dev/null 2>/dev/null

		debugprint "Creating ipset for ${list_id}, maxelem: $ipset_maxelem, hashsize: $ipset_hs... "
		ipset create "$ipset_name" "hash:$ipset_type" family "$family_li" hashsize "$ipset_hs" maxelem "$ipset_maxelem" ||
			{ FAIL; echolog -err "$FAIL create ipset '$ipset_name'."; return 1; }
	done
	OK

	printf %s "Loading ipsets... "
	IFS="$_nl"
	for entry in ${ipsets_to_add%"${_nl}"}; do
		IFS=' '
		set -- $entry
		oldifs loi
		ipset_name="$1"
		shift 5
		iplist_file="$*"
		# read $iplist_file, transform each line into 'add' command and pipe the result into "ipset restore"
		sed "/^$/d;s/^/add \"$ipset_name\" /" "$iplist_file"
		case "$ipset_name" in *_local_*) ;; *) rm -f "$iplist_file"; esac
	done | ipset restore -exist ||
		{ oldifs loi; FAIL; echolog -err "$FAIL load ipsets."; return 1; }
	oldifs loi
	OK

	:
}

# 1 - ipset name
# 2 - ipset type
# 3 - family
# 4 - path to file
# 5 - curr ipsets
reg_ipset() {
	debugprint "Registering load ipset '$1'... "
	case "$5" in *"$1"*) echolog -err "reg_ipset: ipset '$1' already exists."; return 1; esac

	[ -s "$4" ] || {
		FAIL
		echolog -err "reg_ipset: iplist file '$4' does not exist or is empty."
		return 1
	}

	# count ips in the iplist file
	ip_cnt_ri=$(wc -w < "$4") || {
		echolog -err "reg_ipset: $FAIL count IPs in file '$4'."
		return 1
	}
	case "$ip_cnt_ri" in ''|0|*[!0-9]*)
		echolog -err "reg_ipset: unexpected IP count '$ip_cnt_ri' for ipset '$1'."
		return 1
	esac
	debugprint "IP count in the iplist file '$4': $ip_cnt_ri"

	# set hashsize to 1024 or (ip_cnt_ri / 2), whichever is larger
	ipset_hs_ri=$((ip_cnt_ri / 2))
	[ $ipset_hs_ri -lt 1024 ] && ipset_hs_ri=1024

	new_ipsets="$new_ipsets$1 "
	ipsets_to_add="${ipsets_to_add}${1} ${2} ${3} ${ip_cnt_ri} ${ipset_hs_ri} ${4}${_nl}"
	:
}

# 1 - ipset name
# 2 - current ipsets
rm_ipset() {
	[ "$1" ] || { echolog -err "rm_ipset: ipset name not specified"; return 1; }
	case "$2" in *"$1"*) ;; *) return 0; esac

	debugprint "Destroying ipset '$1'... "
	ipset destroy "$1" || {
		echolog -err "$FAIL destroy ipset '$1'."
		return 1
	}
	:
}

# 1 - direction (inbound|outbound)
report_fw_state() {
	direction="$1"
	set_dir_vars "$direction"

	dashes="$(printf '%155s' ' ' | tr ' ' '-')"
	for family in $families; do
		f_short="${family#ipv}"
		set_ipt_cmds "$family"

		if ipt_save "$family" | grep "${p_name}_enable_${dir_short}_${f_short}.*${blanks}${geochain%_*}" 1>/dev/null; then
			chain_status="enabled $_V"
		else
			chain_status="disabled $_X"; incr_issues
		fi
		printf '%s\n' "  Geoblocking firewall chain ($family): $chain_status"

		[ "$geomode" = whitelist ] && {
			if ipt_save "$family" | grep "${dir_cap}.*${p_name}_whitelist_block.*${blanks}DROP" 1>/dev/null; then
				wl_rule_status="$_V"
			else
				wl_rule_status="$_X"; incr_issues
			fi
			printf '%s\n' "  Whitelist blocking rule ($family): $wl_rule_status"
		}

		if [ "$verb_status" ]; then
			# report gepblocking rules
			printf '\n%s\n' "  ${purple}Firewall rules in the $geochain chain ($family)${n_c}:"
			print_rules_table "$direction" "$family" || { printf '%s\n' "${red}None $_X"; incr_issues; }
			echo
		fi
	done
}

# 1 - direction
# 2 - family
print_rules_table() {
	set_dir_vars "$1"
	set_ipt_cmds "$2"

	rules="$(
		eval "$ipt_save" -c |
		sed -n "/${geochain}.*geoip-shell/{
			s/^${blank}*\[/-K /;
			s/:/ -B /;
			s/\]//;
			s/${geochain}${blanks}//;
			s/${blanks}-A${blanks}/ /;
			s/^${blank}*//;
			s/-m set --match-set/-S/;
			s/-m comment --comment/-c/;
			s/-m conntrack --ctstate${blanks}${notblank}*RELATED${notblank}*/-e \"conntrack RELATED,ESTABLISHED\"/;
			s/-p udp/-P udp/;
			s/-m udp//;
			s/-p tcp/-P tcp/;
			s/-m tcp//;
			s/-m multiport --dports/-p/;
			s/--dport/-p/;
			s/${blanks}dst${blanks}/ /;
			s/${blanks}src${blanks}/ /;
			p;}"
	)"

	[ "$rules" ] || return 1

	fmt_str="  %-9s%-11s%-8s%-5s%-20s%-10s%-10s%-20s%-17s%-16s%s\n"
	printf "%s\n${fmt_str}%s\n" \
		"  $dashes${blue}" packets bytes target prot dports source dest interfaces ipset comment extra "$n_c  $dashes"

	newifs "$_nl" table

	for rule in $rules; do
		[ -z "$rule" ] && continue
		unset pkts bytes target proto dports src dest ifaces ipset comment extra
		IFS=' '
		eval "set -- $rule"
		while getopts ":K:B::e:c:j:s:d:P:p:S:i:o:" opt; do
			case $opt in
				K) pkts=$(num2human "$OPTARG") ;;
				B) bytes=$(num2human "$OPTARG" bytes) ;;
				j) target="$OPTARG" ;;
				P) proto="$OPTARG" ;;
				p) dports="$OPTARG" ;;
				s) src="$OPTARG" ;;
				d) dest="$OPTARG" ;;
				i|o) ifaces="$OPTARG" ;;
				S) ipset="${OPTARG#"${p_name}_"}" ;;
				c) comment="${OPTARG#"${p_name}_"}"; comment="${comment#aux_}" ;;
				e) extra="$OPTARG" ;;
				*) echo "unknown opt: '$OPTARG'"
			esac
		done

		: "${pkts:=---}"
		: "${bytes:=---}"
		: "${target:=???}"
		: "${proto:=all}"
		: "${dports:=all}"
		: "${src:=any}"
		: "${dest:=any}"
		: "${ifaces:=all}"
		: "${ipset:=---}"
		: "${comment:=---}"
		: "${extra:=}"

		printf "$fmt_str" "$pkts " "$bytes " "$target " "$proto " "$dports " "$src " "$dest " "$ifaces " "$ipset" "$comment " "$extra "
	done
	oldifs table
	:
}

# 1 - (optional) direction
geoip_on() {
	unset curr_ipt curr_ipt_ipv4 curr_ipt_ipv6 first_chain
	for direction in ${1:-inbound outbound}; do
		set_dir_vars "$direction"
		[ "$ifaces" != all ] && first_chain="$iface_chain" || first_chain="$geochain"
		[ "$geomode" = disable ] && {
			echo "$direction geoblocking mode is set to 'disable' - skipping."
			continue
		}
		for family in $families; do
			eval "curr_ipt=\"\${curr_ipt_${family}}\""
			f_short="${family#ipv}"
			[ "$curr_ipt" ] || curr_ipt="$(ipt_save "$family")"
			eval "curr_ipt_$family"='$curr_ipt'
			case "$curr_ipt" in
				*"${geotag}_enable_${dir_short}_${f_short}"*) printf '%s\n' "$direction geoblocking is already on for $family." ;;
				*)
					set_ipt_cmds "$family" || die_a
					printf_s "Inserting the $direction $family geoblocking enable rule... "
					eval "$ipt_cmd" -I "$base_geochain" -j "$first_chain" $ipt_comm "${geotag}_enable_${dir_short}_${f_short}" ||
						critical "$FAIL insert the $direction $family geoblocking enable firewall rule"
					OK
			esac
		done
	done
}

# 1 - (optional) direction
geoip_off() {
	off_ok=
	for direction in ${1:-inbound outbound}; do
		dir_short="${direction%bound}"
		for family in $families; do
			curr_ipt="$(ipt_save "$family")" || return 1
			case "$curr_ipt" in
				*"${geotag}_enable_${dir_short}"*)
					rm_ipt_rules "$curr_ipt" "$family" "${geotag}_enable_${dir_short}" || return 1
					off_ok=1 ;;
				*) printf '%s\n' "${direction} $family geoblocking is already off."
			esac
		done
	done
	[ ! "$off_ok" ] && return 2
	:
}

# 1 - action
apply_rules() {
	#### Initialize things
	retval=0

	new_ipsets=

	#### Determine active IP families
	active_families=
	for family in ipv4 ipv6; do
		set_ipt_cmds "$family"
		test_read_ipt "$family" || die
		eval "$ipt_save" | grep -m1 -i "$geotag" 1>/dev/null && active_families="$active_families$family "
	done

	for family in $active_families; do
		set_ipt_cmds "$family" || die
		# Read current iptables rules
		curr_ipt="$(ipt_save "$family" -c)"

		#### Assemble commands to remove current rules
		printf_s "Removing $family geoblocking firewall rules... "
		rm_rules="$(
			printf '%s\n' "*$ipt_table"

			# remove the geoblocking enable rule
			mk_ipt_rm_cmd "$curr_ipt" "${geotag}_enable" || exit 1

			for direction in inbound outbound; do
				set_dir_vars "$direction"

				## Remove existing rules
				for chain in "$iface_chain" "$geochain"; do
					case "$curr_ipt" in *":$chain "*) printf '%s\n%s\n' "-F $chain" "-X $chain"; esac
				done
			done
			printf '%s\n' COMMIT
			:
		)" || die "$FAIL assemble remove commands for iptables-restore."

		### Apply rules removal
		debugprint "\nRemoval rules: $_nl$rm_rules$_nl"
		ipt_output="$(printf '%s\n' "$rm_rules" | eval "$ipt_restore_cmd -c" 2>&1)" || {
			echolog -err "$FAIL remove firewall rules"
			echolog "iptables errors: '$(printf %s "$ipt_output" | head -c 1k | tr '\n' ';')'"
			die
		}

		OK
	done

	curr_ipsets="$(get_ipsets)"

	#### Remove unneeded ipsets
	[ -n "$rm_ipsets" ] && {
		printf_s "Removing unneeded ipsets... "
		rm_ipsets_rv=0
		for ipset in $rm_ipsets; do
			rm_ipset "$ipset" "$curr_ipsets" || rm_ipsets_rv=1
			subtract_a_from_b "$ipset" "$curr_ipsets" curr_ipsets "$_nl"
		done
		[ "$rm_ipsets_rv" = 0 ] || { FAIL; echo; die; }
		OK
		echo
	}

	### register load ipsets
	ipsets_to_add=
	for family in $families; do
		for ipset in $ipsets_to_load; do
			[ ! "$ipset" ] && continue
			get_ipset_id "$ipset" || die
			case "$list_id" in *_*) ;; *) die "Invalid iplist ID '$list_id'."; esac
			[ "${ipset_family}" != "$family" ] && continue
			iplist_file="${iplist_dir}/${list_id}.iplist"
			reg_ipset "$ipset" net "$family" "${iplist_file}" "$curr_ipsets" || die
		done

		### register ipset for dhcpv4 subnets
		is_whitelist_present && [ "$family" = ipv4 ] && {
			dhcp_ipset="${geotag}_dhcp_4"
			dhcp_addr="192.168.0.0/16${_nl}172.16.0.0/12${_nl}10.0.0.0/8"
			dhcp_iplist_file="${iplist_dir}/${dhcp_ipset}.iplist"
			printf '%s\n' "$dhcp_addr" > "$dhcp_iplist_file"
			reg_ipset "$dhcp_ipset" net "$family" "${dhcp_iplist_file}" "$curr_ipsets" || die
		}

		### register ipsets for local iplists
		[ "$inbound_geomoe" != disable ] || [ "$outbound_geomode" != disable ] &&
			for ipset in $local_ipsets; do
				get_ipset_id "$ipset" || die
				[ "$ipset_family" = "$family" ] || continue
				reg_ipset "${ipset}" "$ipset_el_type" "$family" "$iplist_path" "$curr_ipsets" || die
			done

		### register ipsets for allowed subnets/IPs
		allow_iplist_file_prev=
		for direction in inbound outbound; do
			eval "geomode=\"\$${direction}_geomode\""
			set_allow_ipset_vars "$direction" "$family"
			[ "$allow_iplist_file" = "$allow_iplist_file_prev" ] || [ "$geomode" = disable ] ||
				[ ! -s "$allow_iplist_file" ] && continue

			allow_iplist_file_prev="$allow_iplist_file"
			eval "allow_ipset_type=\"\$allow_ipset_type_${direction}_${family}\""
			: "${allow_ipset_type:=ip}"
			reg_ipset "${geotag}_${allow_ipset_name}" "$allow_ipset_type" "$family" "$allow_iplist_file" "$curr_ipsets" || die
		done
	done

	### Load ipsets
	[ -n "$ipsets_to_add" ] && {
		load_ipsets || die_a
	}

	#### Assemble commands for iptables-restore
	printf_s "Assembling new firewall rules... "

	for family in $families; do
		f_short="${family#ipv}"
		set_ipt_cmds "$family" || die_a
		iptr_cmds="$(
			printf '%s\n' "*$ipt_table"

			### Create rules for each direction
			for direction in inbound outbound; do
				set_dir_vars "$direction"
				case "$direction" in
					inbound) dir_kwrd_ipset=src iface_kwrd='-i' dir_kwrd='-s' ;;
					outbound) dir_kwrd_ipset=dst iface_kwrd='-o' dir_kwrd='-d'
				esac

				case "$geomode" in
					whitelist) fw_target=ACCEPT ;;
					blacklist) fw_target=DROP ;;
					disable)
						debugprint "$direction geoblocking mode is 'disable'. Skipping rules creation."
						continue ;;
					*) echolog -err "Unknown geoblocking mode '$geomode' for direction '$direction'."; exit 1
				esac
				eval "list_ids=\"\$${direction}_list_ids\""
				[ "$list_ids" ] || { echolog -err "apply_rules: no list_ids for direction '$direction'."; exit 1; }

				## Create the geochain
				printf '%s\n' ":$geochain -"

				### Create new rules

				# Create chain and rules for ifaces if needed
				if [ "$ifaces" != all ]; then
					printf '%s\n' ":$iface_chain -"
					for _iface in $ifaces; do
						printf '%s\n' "-I $iface_chain $iface_kwrd $_iface -j $geochain $ipt_comm ${geotag}_iface_filter_${f_short}"
					done
				fi

				## Auxiliary rules

				# add rule for allowed subnets/ips
				set_allow_ipset_vars "$direction" "$family"
				eval "[ \"\${allow_ipset_present_${direction}_${family}}\" ]" && {
					rule="$geochain -m set --match-set ${geotag}_${allow_ipset_name} $dir_kwrd_ipset $ipt_comm ${geotag_aux}_allow_${f_short} -j ACCEPT"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -I $rule"
				}

				# add rule to allow DHCP
				[ "$geomode" = whitelist ] && {
					case "$family" in
						ipv4)
							dhcp_addr_expr="-p udp -m set --match-set ${geotag}_dhcp_4 $dir_kwrd_ipset"
							dhcp_dports="67,68" ;;
						ipv6)
							dhcp_addr_expr="$dir_kwrd fc00::/6 -p udp"
							dhcp_dports="546,547"
					esac
					rule_DHCP="$geochain $dhcp_addr_expr -m udp -m multiport --dports $dhcp_dports $ipt_comm ${geotag_aux}_DHCP_${f_short} -j ACCEPT"
					get_counter_val "$rule_DHCP" "$family"
					printf '%s\n' "$counter_val -I $rule_DHCP"
				}

				# add rules for ports
				for proto in tcp udp; do
					eval "ports_exp=\"\${${direction}_${proto}_ports%:*}\" ports=\"\${${direction}_${proto}_ports##*:}\""
					debugprint "$direction $proto ports_exp: '$ports_exp', ports: '$ports'"
					[ "$ports_exp" = skip ] && continue
					if [ "$ports_exp" = all ]; then
						ports_exp=
					else
						dport='--dport'
						case "$ports_exp" in *multiport*) dport='--dports' ;; '') ;; *) proto="$proto -m $proto"; esac
						ports="$(printf %s "$ports" | sed 's/-/:/g')"
						ports_exp="$(printf %s "$ports_exp" | sed "s/all//;s/multiport/-m multiport/;s/!/! /;s/dport/$dport/") $ports"
					fi
					trimsp ports_exp
					[ "$ports_exp" ] && ports_exp=" $ports_exp"
					rule="$geochain -p $proto$ports_exp $ipt_comm ${geotag_aux}_ports_${f_short} -j ACCEPT"
					debugprint "$direction rule: '$rule'"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -I $rule"
				done

				# add rule to allow established/related
				rule="$geochain -m conntrack --ctstate RELATED,ESTABLISHED $ipt_comm ${geotag_aux}_rel-est_${f_short} -j ACCEPT"
				get_counter_val "$rule" "$family"
				printf '%s\n' "$counter_val -I $rule"

				# add rule to allow lo interface
				[ "$geomode" = whitelist ] && [ "$ifaces" = all ] &&
					printf '%s\n' "[0:0] -I $geochain $iface_kwrd lo $ipt_comm ${geotag_aux}_lo_${f_short} -j ACCEPT"

				# add rules for local iplists
				for ipset in $local_block_ipsets $local_allow_ipsets; do
					get_ipset_id "$ipset" || exit 1
					[ "$ipset_family" = "$family" ] || continue
					case "$ipset" in
						*_allow_*) local_fw_target=ACCEPT ;;
						*_block_*) local_fw_target=DROP
					esac
					list_tag="${geotag}_${list_id}"
					rule="$geochain -m set --match-set $ipset $dir_kwrd_ipset $ipt_comm $list_tag -j $local_fw_target"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -A $rule"
				done

				# add rules for country codes
				for list_id in $list_ids; do
					[ "$family" != "${list_id#*_}" ] && continue
					get_ipset_name ipset "$list_id" || exit 1
					list_tag="${geotag}_${list_id}"
					rule="$geochain -m set --match-set $ipset $dir_kwrd_ipset $ipt_comm $list_tag -j $fw_target"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -A $rule"
				done

				# add whitelist blocking rule
				[ "$geomode" = whitelist ] && {
					rule="$geochain $ipt_comm ${geotag}_whitelist_block -j DROP"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -A $rule"
				}
			done
			echo COMMIT
			:
		)" || die_a "$FAIL assemble commands for iptables-restore"
		debugprint "\nNew $family rules: $_nl$iptr_cmds$_nl"
		eval "${family}_iptr_cmds=\"$iptr_cmds\""
	done

	OK

	### Apply new rules
	for family in $families; do
		set_ipt_cmds "$family" || die_a
		eval "iptr_cmds=\"\${${family}_iptr_cmds}\""
		printf_s "Applying new $family firewall rules... "
		ipt_output="$(printf '%s\n' "$iptr_cmds" | eval "$ipt_restore_cmd -c" 2>&1)" || {
			echolog -err "$FAIL apply new $family iptables rules"
			echolog "iptables errors: '$(printf %s "$ipt_output" | head -c 1k | tr '\n' ';')'"
			critical
		}
		printf '%s\n' "$iptr_cmds" | eval "$ipt_restore_cmd -c" || critical "$FAIL apply new $family iptables rules"
		OK
	done

	# insert the main blocking rules
	[ "$noblock" = false ] && geoip_on

	return "$retval"
}

# extracts IP lists from backup
extract_iplists() {
	printf '%s\n' "Restoring $p_name IP lists from backup... "

	bk_file="${bk_dir}/${p_name}_backup.${bk_ext:-bak}"
	[ "$bk_file" ] || die "Backup file path is not set in config."
	[ -f "$bk_file" ] || die "Can not find the backup file '$bk_file'."

	# extract the backup archive into tmp_file
	tmp_file="/tmp/${p_name}_backup.tmp"
	$extract_cmd "$bk_file" > "$tmp_file" && [ -s "$tmp_file" ] ||
		rstr_failed "Backup file '$bk_file' is empty or backup extraction failed."

	grep -m1 "add .*$p_name" "$tmp_file" 1>/dev/null || rstr_failed "IP lists backup appears to be empty or non-existing."

	printf '%s\n\n' "Successfully read backup file: '$bk_file'."
	:
}

# loads extracted IP lists into ipsets
restore_ipsets() {
	printf_s "Restoring $p_name ipsets... "
	ipset restore < "$tmp_file"; rv=$?
	rm_rstr_tmp

	case "$rv" in
		0) OK ;;
		*) FAIL; return 1
	esac
	:
}

# Saves current ipsets to a backup file
create_backup() {
	bk_file="${bk_dir_new}/${p_name}_backup.${bk_ext:-bak}"
	bk_failed_file="/tmp/$p_name-backup-failed"
	rm -f "$bk_failed_file"
	ipsets="$(ipset list -n | grep "$geotag")" || { echolog "create_backup: no ipsets found."; return 0; }
	for ipset in $ipsets; do
		ipset save "$ipset" || {
			touch "$bk_failed_file"
			echolog -err "${_nl}$FAIL create backup of ipset '$ipset'."
			exit 1
		}
	done | eval "$compr_cmd" > "$bk_file" && [ ! -f "$bk_failed_file" ] && [ -s "$bk_file" ] ||
	{
		rm -f "$bk_failed_file"
		bk_failed "${_nl}$FAIL create backup of $p_name ipsets."
	}
	:
}

ipt_table=mangle
ipt_comm="-m comment --comment"
inbound_iface_chain=${p_name_cap}_WAN_IN outbound_iface_chain=${p_name_cap}_WAN_OUT
inbound_base_geochain=PREROUTING outbound_base_geochain=POSTROUTING
