#!/bin/sh
# shellcheck disable=SC2154,SC2034

# geoip-shell-lib-ipt.sh

# geoip-shell library for interacting with iptables

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


# 1 - family
set_ipt_cmds() {
	case "$1" in ipv4) f='' ;; ipv6) f=6 ;; *) echolog -err "set_ipt_cmds: Unexpected family '$1'."; return 1; esac
	ipt_cmd="ip${f}tables -t $ipt_table"
	ipt_save="ip${f}tables-save -t $ipt_table"
	ipt_save_cmd="{ ${ipt_save} || exit 1; } | { grep -i $geotag; :; }"
	ipt_save_cmd_c="{ ${ipt_save} -c || exit 1; } | { grep -i $geotag; :; }"
	ipt_restore_cmd="ip${f}tables-restore -n"
	:
}

# 1 - family
# 2 - (optional) -c
ipt_save() {
	set_ipt_cmds "$1" || return 1
	case "$2" in
		'') eval "$ipt_save_cmd" ;;
		'-c') eval "$ipt_save_cmd_c"
	esac || { echolog -err "ipt_save: $FAIL get $family iptables rules."; exit 1; }
	:
}

# 1 - string
# 2 - target
filter_ipt_rules() {
	grep "$1" | grep -o "$2.* \*/"
}

get_ipsets() {
	ipset list -t
}

# 1 - ipset tag
# 2 - ipsets
print_ipset_elements() {
	get_matching_line "$2" "*" "$1" "*" ipset &&
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
		f_short="${family#ipv}"
		curr_ipt="$(ipt_save "$family" -c)" || return 1
		rm_ipt_rules "$curr_ipt" "$family" "${geotag}_enable"
		for direction in inbound outbound; do
			set_dir_vars "$direction"
			# remove the iface chain if it exists
			printf '%s\n' "$curr_ipt" | grep "$iface_chain" >/dev/null && {
				printf %s "Removing $direction $family chain '$iface_chain'... "
				printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $iface_chain" "-X $iface_chain" "COMMIT" |
					eval "$ipt_restore_cmd" && OK || { FAIL; return 1; }
			}
			# remove the main geoblocking chain
			printf '%s\n' "$curr_ipt" | grep "$geochain" >/dev/null && {
				printf %s "Removing $direction $family chain '$geochain'... "
				printf '%s\n%s\n%s\n%s\n' "*$ipt_table" "-F $geochain" "-X $geochain" "COMMIT" | eval "$ipt_restore_cmd" && OK ||
					{ FAIL; return 1; }
			}
		done
	done
	# remove ipsets
	rm_ipsets_rv=0
	unisleep
	printf %s "Destroying $p_name ipsets... "
	for ipset in $(ipset list -n | grep "$geotag"); do
		ipset destroy "$ipset" || rm_ipsets_rv=1
	done
	[ "$rm_ipsets_rv" = 0 ] && OK || FAIL
	return "$rm_ipsets_rv"
}

get_fwrules_iplists() {
	case "$1" in
		inbound) dir_kwrd_ipset='src' ;;
		outbound) dir_kwrd_ipset='dst' ;;
		*) echolog -err "get_fw_rules_iplists: direction not specified"; return 1;
	esac
	set_dir_vars "$1"
	p="$p_name" t="$ipt_target"
	{ ipt_save ipv4; ipt_save ipv6; } |
		sed -n "/match-set${blanks}${p}_.*${blanks}${dir_kwrd_ipset}.* -j $t/{s/.*match-set${blanks}${p}_//;s/${blanks}${dir_kwrd_ipset}.*//;p}" | grep -vE "(lan_|trusted_)"
}

get_ipset_iplists() {
	get_ipsets | sed -n /"$geotag"/\{s/"$geotag"_//\;s/^Name:\ //\;p\} | grep -vE "(lan_|trusted_)"
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
	for tmp_ipset in $(ipset list -n | grep "$p_name" | grep "temp"); do
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
		sed_inc_counter_1="/^[[:blank:]]*\\[.*\\]/{"
		sed_inc_counter_2=";}"
		sed_colon_res="s/Q/:/;"
	fi

	[ "$1" ] || { echolog -err "encode_rules: family not set"; return 1; }
	sed -n "${sed_inc_counter_1}s/${blanks}-A${blanks}//;
		s/$p_name//g;s/${p_name_cap}//g;s/-m set --match-set//;s/--ctstate//;
		s/${ipt_comm}[[:blank:]][^[:blank:]]*//g;s/-m conntrack//g;s/-m multiport//g;s/_//g;s~/~W~g;
		s/-/_/g;s/!/X/g;s/:/Q/g;${sed_colon_res}s/,/Y/g;s/${blanks}/Z/g;s/\$/_${1#ipv}/;/^$/d;p${sed_inc_counter_2}"
}

# Get counters from existing rules and store them in vars
get_counters_ipt() {
	for f in $families; do
		curr_ipt="$(ipt_save "$f" -c)" || return 1
		case "$curr_ipt" in *":$inbound_geochain "*|*":$outbound_geochain "*) ;; *) return 1; esac
		eval "${f}_ipt"='$curr_ipt'
	done
	counter_strings="$(
		# encode rules in [[:alnum:]_] strings, generate variable assignments
		for f in $families; do
			eval "curr_ipt=\"\$${f}_ipt\""
			printf '%s\n' "$curr_ipt" |
			encode_rules "$f"
		done | awk -F "]" '$2 ~ /^[a-zA-Z0-9_]+$/ {print $2 "=" $1 "]"}'
	)"
	:
}

add_ipset() {
	perm_ipset="$1"; tmp_ipset="${1}_temp"; iplist_file="$2"; ipset_type="$3"
	[ ! -f "$iplist_file" ] && critical "Can not find the iplist file in path: '$iplist_file'."

	ipset destroy "$tmp_ipset" 1>/dev/null 2>/dev/null

	# count ips in the iplist file
	ip_cnt=$(wc -w < "$iplist_file")
#	debugprint "ip count in the iplist file '$iplist_file': $ip_cnt"

	# set hashsize to 1024 or (ip_cnt / 2), whichever is larger
	ipset_hs=$((ip_cnt / 2))
	[ $ipset_hs -lt 1024 ] && ipset_hs=1024
	debugprint "hashsize for ipset $list_id: $ipset_hs"

	debugprint "Creating ipset '$tmp_ipset'... "
	ipset create "$tmp_ipset" "hash:$ipset_type" family "$family" hashsize "$ipset_hs" maxelem "$ip_cnt" ||
		crtical "$FAIL create ipset '$tmp_ipset'."
	debugprint "Ok."

	debugprint "Importing iplist '$iplist_file' into temporary ipset... "
	# read $iplist_file, transform each line into 'add' command and pipe the result into "ipset restore"
	sed "s/^/add \"$tmp_ipset\" /" "$iplist_file" | ipset restore -exist ||
		critical "$FAIL import the iplist from '$iplist_file' into ipset '$tmp_ipset'."
	debugprint "Ok."

	[ "$debugmode" ] && debugprint "ip's in the temporary ipset: $(ipset save "$tmp_ipset" | grep -c "add $tmp_ipset")"

	# swap the temp ipset with the permanent ipset
	debugprint "Making the ipset '$perm_ipset' permanent... "
	ipset swap "$tmp_ipset" "$perm_ipset" || critical "$FAIL swap temporary and permanent ipsets."
	debugprint "Ok."
	rm -f "$iplist_file"
}

# creates new permanent ipset if it doesn't exist
# 1 - perm ipset name
# 2 - ipset type
# 3 - curr ipsets
mk_perm_ipset() {
	tmp_ipset="${1}_temp"
	case "$3" in *"$1"* ) ;; *)
		debugprint "Creating permanent ipset '$1'... "
		ipset create "$1" "hash:$2" family "$family" hashsize 1 maxelem 1 ||
			die_a "$FAIL create ipset '$1'."
	esac
}

get_curr_ipsets() {
	ipset list -n | grep "$geotag"
}

# 1 - ipset name
# 2 - current ipsets
rm_ipset() {
	[ ! "$1" ] && return 0
	case "$2" in
		*"$1"* )
			debugprint "Destroying ipset '$1'... "
			ipset destroy "$1"; rv=$?
			case "$rv" in
				0)
					debugprint "Ok."
					;;
				*)
					debugprint "Failed."
					echolog -err "$FAIL destroy ipset '$1'."
					retval="254"
					return 1
			esac
	esac
	:
}

# 1 - direction (inbound|outbound)
report_fw_state() {
	direction="$1"
	set_dir_vars "$direction"

	dashes="$(printf '%148s' ' ' | tr ' ' '-')"
	for family in $families; do
		f_short="${family#ipv}"
		set_ipt_cmds "$family"
		curr_ipt="$($ipt_cmd -vL)" && [ "$curr_ipt" ] || die "$FAIL read $family iptables rules."

		wl_rule="$(printf %s "$curr_ipt" | filter_ipt_rules "${p_name}_whitelist_block_${dir_short}" "DROP")"
		ipt_header="  $dashes$_nl  ${blue}$(printf %s "$curr_ipt" | grep -m1 "pkts.*destination")${n_c}$_nl  $dashes"

		case "$(printf %s "$curr_ipt" | filter_ipt_rules "${p_name}_enable_${dir_short}_${f_short}" "${geochain%_*}")" in
			'') chain_status="disabled $_X"; incr_issues ;;
			*) chain_status="enabled $_V"
		esac
		printf '%s\n' "  Geoblocking firewall chain ($family): $chain_status"
		[ "$geomode" = whitelist ] && {
			case "$wl_rule" in
				'') wl_rule=''; wl_rule_status="$_X"; incr_issues ;;
				*) wl_rule="$_nl$wl_rule"; wl_rule_status="$_V"
			esac
			printf '%s\n' "  Whitelist blocking rule ($family): $wl_rule_status"
		}

		if [ "$verb_status" ]; then
			# report gepblocking rules
			printf '\n%s\n%s\n' "  ${purple}Firewall rules in the $geochain chain ($family)${n_c}:" "$ipt_header"
			printf %s "$curr_ipt" | sed -n -e /"^Chain $geochain"/\{n\;:1 -e n\;/^Chain\ /q\;/^$/q\;s/^/\ \ /\;p\;b1 -e \} |
				grep . || { printf '%s\n' "${red}None $_X"; incr_issues; }
			echo
		fi
	done
}

geoip_on() {
	unset curr_ipt curr_ipt_ipv4 curr_ipt_ipv6 first_chain
	for direction in inbound outbound; do
		set_dir_vars "$direction"
		[ "$ifaces" != all ] && first_chain="$iface_chain" || first_chain="$geochain"
		[ "$geomode" = disable ] && {
			echo "$direction geoblocking mode is set to 'disable' - skipping."
			continue
		}
		for family in $families; do
			eval "curr_ipt=\"\${curr_ipt_${family}}\""
			f_short="${family#ipv}"
			[ "$curr_ipt" ] || curr_ipt="$(ipt_save "$family")" || return 1
			eval "curr_ipt_$family"='$curr_ipt'
			case "$curr_ipt" in
				*"${geotag}_enable_${dir_short}_${f_short}"*) printf '%s\n' "$direction geoblocking is already on for $family." ;;
				*)
					set_ipt_cmds "$family" || die_a
					printf %s "Inserting the $direction $family geoblocking enable rule... "
					eval "$ipt_cmd" -I "$base_geochain" -j "$first_chain" $ipt_comm "${geotag}_enable_${dir_short}_${f_short}" || critical "$insert_failed"
					OK
			esac
		done
	done
}

geoip_off() {
	for family in $families; do
		f_short="${family#ipv}"
		curr_ipt="$(ipt_save "$family")" || return 1
		case "$curr_ipt" in
			*"${geotag}_enable"*) rm_ipt_rules "$curr_ipt" "$family" "${geotag}_enable" || return 1 ;;
			*) printf '%s\n' "Geoblocking is already off for $family."
		esac
	done
	:
}

apply_rules() {
	#### VARIABLES

	retval=0

	insert_failed="$FAIL insert a firewall rule."
	ipsets_to_rm=

	for family in $families; do
		curr_ipt="$(ipt_save "$family" -c)" || die_a "$FAIL read iptables rules."
		eval "${family}_ipt"='$curr_ipt'
	done

	#### MAIN

	### remove lan and trusted ipsets and rules
	curr_ipsets="$(get_curr_ipsets)"
	for family in $families; do
		### Read current iptables rules
		eval "curr_ipt=\"\${${family}_ipt}\""
		f_short="${family#ipv}"

		t_ipset="${geotag}_trusted_${f_short}"
		lan_ipset="${geotag}_lan_${f_short}"
		[ "$curr_ipt" ] && {
			rm_ipt_rules "$curr_ipt" "$family" "${geotag_aux}_trusted_${f_short}" "${geotag_aux}_lan_${f_short}"
			unisleep
		}
		rm_ipset "$t_ipset" "$curr_ipsets" &&
		rm_ipset "$lan_ipset" "$curr_ipsets" || die_a
	done

	curr_ipsets="$(get_curr_ipsets)"
	for family in $families; do
		f_short="${family#ipv}"
		set_ipt_cmds "$family" || die_a
		eval "curr_ipt=\"\${${family}_ipt}\""
		t_ipset="${geotag}_trusted_${f_short}"
		lan_ipset="${geotag}_lan_${f_short}"

		ipsets_to_add=

		### make perm ipsets, assemble $ipsets_to_add and $ipsets_to_rm
		san_str list_ids "$inbound_list_ids $outbound_list_ids" || die
		for list_id in $list_ids; do
			case "$list_id" in *_*) ;; *) die_a "Invalid iplist id '$list_id'."; esac
			[ "${list_id#*_}" != "$family" ] && continue
			perm_ipset="${geotag}_${list_id}"
			if [ "$action" = add ] && [ ! "$skip_ipsets" ]; then
				iplist_file="${iplist_dir}/${list_id}.iplist"
				mk_perm_ipset "$perm_ipset" net "$curr_ipsets"
				ipsets_to_add="$ipsets_to_add$perm_ipset $iplist_file$_nl"
			elif [ "$action" = remove ]; then
				ipsets_to_rm="$ipsets_to_rm$perm_ipset "
			fi
		done

		### trusted subnets/ip's
		eval "trusted=\"\$trusted_$family\""
		ipset_type=net
		case "${trusted%%":"*}" in net|ip)
			ipset_type="${trusted%%":"*}"
			trusted="${trusted#*":"}"
		esac

		[ -n "$trusted" ] && {
			iplist_file="$iplist_dir/$t_ipset.iplist"
			sp2nl trusted
			printf '%s\n' "$trusted" > "$iplist_file" || die_a "$FAIL write to file '$iplist_file'"
			mk_perm_ipset "$t_ipset" "$ipset_type" "$curr_ipsets"
			ipsets_to_add="$ipsets_to_add$ipset_type:$t_ipset $iplist_file$_nl"
		}

		### LAN subnets/ip's
		is_whitelist_present && {
			if [ ! "$autodetect" ]; then
				eval "lan_ips=\"\$lan_ips_$family\""
				sp2nl lan_ips
			else
				a_d_failed=
				lan_ips="$(call_script "${i_script}-detect-lan.sh" -s -f "$family")" || a_d_failed=1
				[ ! "$lan_ips" ] || [ "$a_d_failed" ] && { echolog -err "$FAIL detect $family LAN subnets."; exit 1; }
				lan_ips="net:$lan_ips"
				nl2sp "lan_ips_$family" "$lan_ips"
			fi
			ipset_type="${lan_ips%%":"*}"
			lan_ips="${lan_ips#*":"}"
			[ -n "$lan_ips" ] && {
				iplist_file="$iplist_dir/$lan_ipset.iplist"
				printf '%s\n' "$lan_ips" > "$iplist_file" || die_a "$FAIL write to file '$iplist_file'"
				mk_perm_ipset "$lan_ipset" "$ipset_type" "$curr_ipsets"
				ipsets_to_add="$ipsets_to_add$ipset_type:$lan_ipset $iplist_file$_nl"
			}
		}

		#### Assemble commands for iptables-restore
		printf %s "Assembling new $family firewall rules... "

		curr_ipt="$(ipt_save "$family" -c)" || die_a "$FAIL read iptables rules."
		iptr_cmd_chain="$(
			printf '%s\n' "*$ipt_table"

			### Remove existing rules

			## Remove the main blocking rule, the whitelist blocking rule and the auxiliary rules
			mk_ipt_rm_cmd "$curr_ipt" "${geotag}_enable" "${geotag_aux}" "${geotag}_whitelist_block" "${geotag}_iface_filter" || exit 1

			## Remove rules for $list_ids
			[ "$action" != update ] &&
				for list_id in $list_ids; do
					[ "$family" != "${list_id#*_}" ] && continue
					list_tag="${geotag}_${list_id}"
					mk_ipt_rm_cmd "$curr_ipt" "$list_tag" || exit 1
				done

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

				## Create the geochain if it doesn't exist
				case "$curr_ipt" in *":$geochain "*) ;; *) printf '%s\n' ":$geochain -"; esac

				### Create new rules

				# interfaces
				if [ "$ifaces" != all ]; then
					case "$curr_ipt" in *":$iface_chain "*) ;; *) printf '%s\n' ":$iface_chain -"; esac
					for _iface in $ifaces; do
						printf '%s\n' "$iface_kwrd $_iface -I $iface_chain -j $geochain $ipt_comm ${geotag}_iface_filter_${f_short}"
					done
				fi

				## Auxiliary rules

				# trusted subnets/ips
				[ "$trusted" ] && {
					rule="$geochain -m set --match-set ${geotag}_trusted_${f_short} $dir_kwrd_ipset $ipt_comm ${geotag_aux}_trusted_${f_short} -j ACCEPT"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -I $rule"
				}

				# LAN subnets/ips
				[ "$geomode" = whitelist ] && {
					[ "$lan_ips" ] && {
						rule="$geochain -m set --match-set ${geotag}_lan_${f_short} $dir_kwrd_ipset $ipt_comm ${geotag_aux}_lan_${f_short} -j ACCEPT"
						get_counter_val "$rule" "$family"
						printf '%s\n' "$counter_val -I $rule"
					}

					if [ "$family" = ipv6 ]; then
						# Allow DHCPv6
						[ "$ifaces" != all ] || [ "$direction" = outbound ] && {
							rule_DHCPv6="$geochain -s fc00::/6 -d fc00::/6 -p udp -m udp --dport 546 $ipt_comm ${geotag_aux}_DHCPv6 -j ACCEPT"
							get_counter_val "$rule_DHCPv6" "$family"
							printf '%s\n' "$counter_val -I $rule_DHCPv6"
						}

						# Allow ipv6 link-local
						rule_LL="$geochain $dir_kwrd fe80::/10 $ipt_comm ${geotag_aux}_link-local_${f_short} -j ACCEPT"
						get_counter_val "$rule_LL" "$family"
						printf '%s\n' "$counter_val -I $rule_LL"
					fi

					# Allow DHCPv4
					if [ "$family" = ipv4 ] && { [ "$ifaces" != all ] || [ "$direction" = outbound ]; }; then
						printf '%s\n' "-A $geochain -p udp -m udp --dport 68 $ipt_comm ${geotag_aux}_DHCP -j ACCEPT"
					fi
				}

				# ports
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

				# established/related
				rule="$geochain -m conntrack --ctstate RELATED,ESTABLISHED $ipt_comm ${geotag_aux}_rel-est_${f_short} -j ACCEPT"
				get_counter_val "$rule" "$family"
				printf '%s\n' "$counter_val -I $rule"

				# lo interface
				[ "$geomode" = whitelist ] && [ "$ifaces" = all ] &&
					printf '%s\n' "[0:0] -I $geochain $iface_kwrd lo $ipt_comm ${geotag_aux}-lo_${f_short} -j ACCEPT"

				## iplist-specific rules
				if [ "$action" = add ]; then
					for list_id in $list_ids; do
						[ "$family" != "${list_id#*_}" ] && continue
						perm_ipset="${geotag}_${list_id}"
						list_tag="${geotag}_${list_id}"
						rule="$geochain -m set --match-set $perm_ipset $dir_kwrd_ipset $ipt_comm $list_tag -j $fw_target"
						get_counter_val "$rule" "$family"
						printf '%s\n' "$counter_val -A $rule"
					done
				fi

				# whitelist block
				[ "$geomode" = whitelist ] && {
					rule="$geochain $ipt_comm ${geotag}_whitelist_block_${dir_short} -j DROP"
					get_counter_val "$rule" "$family"
					printf '%s\n' "$counter_val -A $rule"
				}
			done
			echo COMMIT
			:
		)" || die_a "$FAIL assemble commands for iptables-restore"
		OK

		### Apply new rules
		[ "$debugmode" ] && printf '\n%s\n%s\n\n' "Rules:" "$iptr_cmd_chain" >&2
		printf %s "Applying new $family firewall rules... "
		printf '%s\n' "$iptr_cmd_chain" | eval "$ipt_restore_cmd -c" || critical "$FAIL apply new iptables rules"
		OK

		[ -n "$ipsets_to_add" ] && {
			printf %s "Adding $family ipsets... "
			newifs "$_nl" apply
			for entry in ${ipsets_to_add%"$_nl"}; do
				ipset_type=net
				case "$entry" in "ip:"*|"net:"*) ipset_type="${entry%%":"*}"; entry="${entry#*":"}"; esac
				add_ipset "${entry%% *}" "${entry#* }" "$ipset_type"
				ipsets_to_rm="$ipsets_to_rm${entry%% *}_temp "
			done
			oldifs apply
			OK; echo
		}
	done

	[ -n "$ipsets_to_rm" ] && {
		printf %s "Removing old ipsets... "
		curr_ipsets="$(get_curr_ipsets)"
		unisleep
		rm_ipsets_rv=0
		for ipset in $ipsets_to_rm; do
			rm_ipset "$ipset" "$curr_ipsets" || rm_ipsets_rv=1
		done
		[ "$rm_ipsets_rv" = 0 ] && OK || FAIL
		echo
	}


	# insert the main blocking rule
	case "$noblock" in
		false) geoip_on ;;
		true) echolog -warn "Geoip blocking is disabled via config."
	esac

	[ "$autodetect" ] && setconfig lan_ips_ipv4 lan_ips_ipv6

	echo

	return "$retval"
}

# extracts ip lists from backup
extract_iplists() {
	printf '%s\n' "Restoring $p_name ip lists from backup... "

	bk_file="${bk_dir}/${p_name}_backup.${bk_ext:-bak}"
	[ "$bk_file" ] || die "Backup file path is not set in config."
	[ -f "$bk_file" ] || die "Can not find the backup file '$bk_file'."

	# extract the backup archive into tmp_file
	tmp_file="/tmp/${p_name}_backup.tmp"
	$extract_cmd "$bk_file" > "$tmp_file" && [ -s "$tmp_file" ] ||
		rstr_failed "Backup file '$bk_file' is empty or backup extraction failed."

	grep -m1 "add .*$p_name" "$tmp_file" 1>/dev/null || rstr_failed "ip lists backup appears to be empty or non-existing."

	printf '%s\n\n' "Successfully read backup file: '$bk_file'."
	:
}

# loads extracted ip lists into ipsets
restore_ipsets() {
	printf %s "Restoring $p_name ipsets... "
	ipset restore < "$tmp_file"; rv=$?
	rm_rstr_tmp

	case "$rv" in
		0) OK ;;
		*) FAIL; rstr_failed "$FAIL restore $p_name ipsets from backup." reset
	esac
	:
}

# Saves current ipsets to a backup file
create_backup() {
	bk_file="${bk_dir_new}/${p_name}_backup.${bk_ext:-bak}"
	ipsets="$(ipset list -n | grep "$geotag")" || { echolog "create_backup: no ipsets found."; return 0; }
	for ipset in $ipsets; do
		printf %s "Creating backup of ipset '$ipset'... " >&2
		ipset save "$ipset" || { printf '\n%s\n' "$FAIL back up ipset '$ipset'." >&2; exit 1; }
		OK >&2
	done | eval "$compr_cmd" > "$bk_file" && [ -s "$bk_file" ] || bk_failed "$FAIL backup $p_name ipsets."

	:
}

ipt_table=mangle
ipt_comm="-m comment --comment"
inbound_iface_chain=${p_name_cap}_WAN_IN outbound_iface_chain=${p_name_cap}_WAN_OUT
inbound_base_geochain=PREROUTING outbound_base_geochain=POSTROUTING
