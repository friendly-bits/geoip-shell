#!/bin/sh
# shellcheck disable=SC2086,SC2154,SC2155,SC2034

# geoip-shell-lib-setup.sh

# Copyright: friendly bits
# github.com/friendly-bits

# implements CLI interactive/noninteractive setup and args parsing


#### FUNCTIONS

# checks country code by asking the user, then validates against known-good list
pick_user_ccode() {
	[ "$user_ccode_arg" = none ] || { [ "$nointeract" ] && [ ! "$user_ccode_arg" ]; } && { user_ccode=''; return 0; }

	[ ! "$user_ccode_arg" ] && printf '\n%s\n%s\n' "${blue}Please enter your country code.$n_c" \
		"It will be used to check if your geoip settings may block your own country and warn you if so."
	REPLY="$user_ccode_arg"
	while true; do
		[ ! "$REPLY" ] && {
			printf %s "Country code (2 letters)/Enter to skip: "
			read -r REPLY
		}
		case "$REPLY" in
			'') printf '%s\n\n' "Skipped."; return 0 ;;
			*) REPLY="$(toupper "$REPLY")"
				validate_ccode "$REPLY" "$script_dir/cca2.list"; rv=$?
				case "$rv" in
					0)  user_ccode="$REPLY"; break ;;
					1)  die "Internal error while trying to validate country codes." ;;
					2)  printf '\n%s\n' "'$REPLY' is not a valid 2-letter country code."
						[ "$nointeract" ] && exit 1
						printf '%s\n\n' "Try again or press Enter to skip this check."
						REPLY=
				esac
		esac
	done
}

# asks the user to entry country codes, then validates against known-good list
pick_ccodes() {
	[ "$nointeract" ] && [ ! "$ccodes_arg" ] && die "Specify country codes with '-c <\"country_codes\">'."
	[ ! "$ccodes_arg" ] && printf '\n%s\n' "${blue}Please enter country codes to include in geoip $geomode.$n_c"
	REPLY="$ccodes_arg"
	while true; do
		unset bad_ccodes ok_ccodes
		[ ! "$REPLY" ] && {
			printf %s "Country codes (2 letters) or [a] to abort the installation: "
			read -r REPLY
		}
		REPLY="$(toupper "$REPLY")"
		trimsp REPLY
		case "$REPLY" in
			a|A) exit 0 ;;
			*)
				newifs ' ;,' pcc
				for ccode in $REPLY; do
					[ "$ccode" ] && {
						validate_ccode "$ccode" "$script_dir/cca2.list" && ok_ccodes="$ok_ccodes$ccode " ||
							bad_ccodes="$bad_ccodes$ccode "
					}
				done
				oldifs pcc
				[ "$bad_ccodes" ] && {
					printf '%s\n' "Invalid 2-letter country codes: '${bad_ccodes% }'."
					[ "$nointeract" ] && exit 1
					REPLY=
					continue
				}
				[ ! "$ok_ccodes" ] && {
					printf '%s\n' "No country codes detected in '$REPLY'."
					[ "$nointeract" ] && exit 1
					REPLY=
					continue
				}
				ccodes="${ok_ccodes% }"; break
		esac
	done
}

pick_geomode() {
	printf '\n%s\n' "${blue}Select geoip blocking mode:$n_c [w]hitelist or [b]lacklist, or [a] to abort the installation."
	pick_opt "w|b|a"
	case "$REPLY" in
		w|W) geomode=whitelist ;;
		b|B) geomode=blacklist ;;
		a|A) exit 0
	esac
}

pick_ifaces() {
	all_ifaces="$(detect_ifaces)" || die "$FAIL detect network interfaces."

	[ ! "$ifaces_arg" ] && {
		# detect OpenWrt wan interfaces
		auto_ifaces=
		[ "$_OWRTFW" ] && auto_ifaces="$(fw$_OWRTFW zone wan)"

		# fallback and non-OpenWRT
		[ ! "$auto_ifaces" ] && auto_ifaces="$({ ip r get 1; ip -6 r get 1::; } 2>/dev/null |
			sed 's/.*[[:space:]]dev[[:space:]][[:space:]]*//;s/[[:space:]].*//' | grep -vx 'lo')"
		san_str auto_ifaces
		get_intersection "$auto_ifaces" "$all_ifaces" auto_ifaces
		nl2sp auto_ifaces
	}

	nl2sp all_ifaces
	printf '\n%s\n' "${yellow}*NOTE*: ${blue}Geoip firewall rules will be applied to specific network interfaces of this machine.$n_c"
	[ ! "$ifaces_arg" ] && [ "$auto_ifaces" ] && {
		printf '%s\n%s\n' "All found network interfaces: $all_ifaces" \
			"Autodetected WAN interfaces: $blue$auto_ifaces$n_c"
		[ "$1" = "-a" ] && { conf_ifaces="$auto_ifaces"; return; }
		printf '%s\n' "[c]onfirm, c[h]ange, or [a]bort installation?"
		pick_opt "c|h|a"
		case "$REPLY" in
			c|C) conf_ifaces="$auto_ifaces"; return ;;
			a|A) exit 0
		esac
	}

	REPLY="$ifaces_arg"
	while true; do
		u_ifaces=
		printf '\n%s\n' "All found network interfaces: $all_ifaces"
		[ ! "$REPLY" ] && {
			printf '%s\n' "Type in WAN network interface names, or [a] to abort installation."
			read -r REPLY
			case "$REPLY" in a|A) exit 0; esac
		}
		san_str -s u_ifaces "$REPLY"
		[ -z "$u_ifaces" ] && {
			printf '%s\n' "No interface names detected in '$REPLY'." >&2
			[ "$nointeract" ] && die
			REPLY=
			continue
		}
		subtract_a_from_b "$all_ifaces" "$u_ifaces" bad_ifaces ' '
		[ -z "$bad_ifaces" ] && break
		echolog -err "Network interfaces '$bad_ifaces' do not exist in this system."
		echo
		[ "$nointeract" ] && die
		REPLY=
	done
	conf_ifaces="$u_ifaces"
	printf '%s\n' "Selected interfaces: '$conf_ifaces'."
}

# 1 - input ip's/subnets
# 2 - output var base name
# output via $2_$family
# if a subnet detected in ips of a particular family, output is prefixed with 'subnet: '
# expects the $families var to be set
validate_arg_ips() {
	va_ips_a=
	sp2nl va_ips_i "$1"
	san_str va_ips_i
	[ ! "$va_ips_i" ] && { echolog -err "No ip's detected in '$1'."; return 1; }
	for f in $families; do
		unset "va_$f" ipset_type
		eval "ip_regex=\"\$${f}_regex\" mb_regex=\"\$maskbits_regex_$f\""
		va_ips_f="$(printf '%s\n' "$va_ips_i" | grep -E "^${ip_regex}(/$mb_regex){0,1}$")"
		[ "$va_ips_f" ] && {
			validate_ip "$va_ips_f" "$f" || return 1
			nl2sp "va_$f" "$ipset_type:$va_ips_f"
		}
		va_ips_a="$va_ips_a$va_ips_f$_nl"
	done
	subtract_a_from_b "$va_ips_a" "$va_ips_i" bad_ips || { nl2sp bad_ips; echolog -err "Invalid ip's: '$bad_ips'"; return 1; }
	for f in $families; do
		eval "${2}_$f=\"\$va_$f\""
	done
	:
}

pick_lan_ips() {
	confirm_ips() { eval "c_lan_ips_$family=\"$ipset_type:$u_ips\""; }

	lan_picked=1 autodetect=
	case "$lan_ips_arg" in
		none) return 0 ;;
		auto) lan_ips_arg=''; autodetect=1
	esac

	[ "$lan_ips_arg" ] && validate_arg_ips "$lan_ips_arg" c_lan_ips && return 0

	[ "$nointeract" ] && [ ! "$autodetect" ] && die "Specify lan ip's with '-l <\"lan_ips\"|auto|none>'."

	[ ! "$nointeract" ] && {
		printf '\n\n%s\n' "${yellow}*NOTE*${n_c}: ${blue}In whitelist mode, traffic from your LAN subnets will be blocked, unless you whitelist them.$n_c"
		[ ! "$autodetect" ] && echo "You can specify LAN subnets and/or individual ip's to allow."
	}

	for family in $families; do
		printf '\n%s\n' "Detecting $family LAN subnets..."
		u_ips="$(call_script "$p_script-detect-lan.sh" -s -f "$family")" || {
			echolog -err "$FAIL detect $family LAN subnets."
			[ "$nointeract" ] && die
		}
		nl2sp s

		[ -n "$u_ips" ] && {
			nl2sp u_ips
			ipset_type="net"
			printf '\n%s\n' "Autodetected $family LAN subnets: '$blue$u_ips$n_c'."
			[ "$autodetect" ] && { confirm_ips; continue; }
			printf '\n%s\n%s\n\n' "[c]onfirm, c[h]ange, [s]kip or [a]bort installation?" \
				"Verify that correct LAN subnets have been detected in order to avoid accidental lockout or other problems."
			pick_opt "c|h|s|a"
			case "$REPLY" in
				c|C) confirm_ips; continue ;;
				s|S) continue ;;
				h|H) autodetect_off=1 ;;
				a|A) exit 0
			esac
		}

		while true; do
			unset REPLY u_ips
			ipset_type=ip
			[ ! "$nointeract" ] && {
				printf '\n%s\n' "Type in $family LAN ip addresses and/or subnets, [s] to skip or [a] to abort installation."
				read -r REPLY
				case "$REPLY" in
					s|S) break ;;
					a|A) exit 0
				esac
			}
			san_str -s u_ips "$REPLY"
			[ -z "$u_ips" ] && continue
			validate_ip "$u_ips" "$family" && break
		done
		confirm_ips
	done

	[ "$autodetect" ] || [ "$autodetect_off" ] && return
	printf '\n%s\n' "[A]uto-detect LAN subnets when updating ip lists or keep this config [c]onstant?"
	pick_opt "a|c"
	case "$REPLY" in a|A) autodetect="1"; esac
}



invalid_str() { echolog -err "Invalid string '$1'."; }

check_edge_chars() {
	[ "${1%"${1#?}"}" = "$2" ] && { invalid_str "$1"; return 1; }
	[ "${1#"${1%?}"}" = "$2" ] && { invalid_str "$1"; return 1; }
	:
}

parse_ports() {
	check_edge_chars "$_ranges" "," || return 1
	ranges_cnt=0
	IFS=","
	for _range in $_ranges; do
		ranges_cnt=$((ranges_cnt+1))
		trimsp _range
		check_edge_chars "$_range" "-" || return 1
		case "${_range#*-}" in *-*) invalid_str "$_range"; return 1; esac
		IFS="-"
		for _port in $_range; do
			trimsp _port
			case "$_port" in *[!0-9]*) invalid_str "$_port"; return 1; esac
			_ports="$_ports$_port$p_delim"
		done
		_ports="${_ports%"$p_delim"},"
		case "$_range" in *-*) [ "${_range%-*}" -ge "${_range##*-}" ] && { invalid_str "$_range"; return 1; }; esac
	done
	[ "$ranges_cnt" = 0 ] && { echolog -err "no ports specified for protocol $_proto."; return 1; }
	_ports="${_ports%,}"

	[ "$_fw_backend" = ipt ] && [ "$ranges_cnt" -gt 1 ] && mp="multiport"
	:
}

# input format: '[tcp|udp]:[allow|block]:[ports]'
# output format: 'skip|all|<[!]dport:[port-port,port...]>'
setports() {
	_lines="$(tolower "$1")"
	newifs "$_nl" sp
	for _line in $_lines; do
		unset ranges _ports neg mp skip
		trimsp _line
		check_edge_chars "$_line" ":" || return 1
		IFS=":"
		set -- $_line
		[ $# != 3 ] && { echolog -err "Invalid syntax '$_line'"; return 1; }
		_proto="$1"
		p_delim='-'
		proto_act="$2"
		_ranges="$3"
		trimsp _ranges
		trimsp _proto
		trimsp proto_act
		case "$proto_act" in
			allow) neg='' ;;
			block) neg='!' ;;
			*) { echolog -err "expected 'allow' or 'block' instead of '$proto_act'"; return 1; }
		esac
		# check for valid protocol
		case $_proto in
			udp|tcp) case "$reg_proto" in *"$_proto"*) echolog -err "can't add protocol '$_proto' twice"; return 1; esac
				reg_proto="$reg_proto$_proto " ;;
			*) echolog -err "Unsupported protocol '$_proto'."; return 1
		esac

		if [ "$_ranges" = all ]; then
			_ports=
			[ "$neg" ] && ports_exp=skip || ports_exp=all
		else
			parse_ports || return 1
			ports_exp="$mp ${neg}dport"
		fi
		trimsp ports_exp
		eval "${_proto}_ports=\"$ports_exp:$_ports\""
		debugprint "$_proto: ports: '$ports_exp:$_ports'"
	done
	oldifs sp
}


get_prefs() {
	sleeptime=30 max_attempts=30

	# cron
	check_cron_compat
	[ "$schedule_arg" ] && [ "$schedule_arg" != disable ] && {
		call_script "$p_script-cronsetup.sh" -x "$schedule_arg" || die "$FAIL validate cron schedule '$schedule_arg'."
	}

	[ "$_OWRTFW" ] && {
		default_schedule="15 4 * * 5" source_default=ipdeny
	} ||
	{ default_schedule="15 4 * * *" source_default=ripe; }
	schedule="${schedule_arg:-$default_schedule}"

	# source
	source_arg="$(tolower "$source_arg")"
	case "$source_arg" in ''|ripe|ipdeny) ;; *) die "Unsupported source: '$source_arg'."; esac
	source="${source_arg:-$source_default}"

	# families
	families_default="ipv4 ipv6"
	[ "$families_arg" ] && families_arg="$(tolower "$families_arg")"
	case "$families_arg" in
		inet|inet6|'inet inet6'|'inet6 inet' ) families="$families_arg" ;;
		''|'ipv4 ipv6'|'ipv6 ipv4' ) families="$families_default" ;;
		ipv4 ) families="ipv4" ;;
		ipv6 ) families="ipv6" ;;
		* ) echolog -err "invalid family '$families_arg'."; exit 1
	esac
	[ ! "$families" ] && die "\$families variable should not be empty!"

	# process trusted ip's if specified
	[ "$trusted_arg" ] && { validate_arg_ips "$trusted_arg" trusted || die; }

	# ports
	tcp_ports=skip udp_ports=skip
	[ "$ports_arg" ] && { setports "${ports_arg%"$_nl"}" || die; }

	# country codes
	ccodes="$(toupper "$ccodes")"

	# geoip mode
	export geomode="$(tolower "$geomode")"
	case "$geomode" in
		whitelist|blacklist) ;;
		'') [ "$nointeract" ] && die "Specify geoip blocking mode with -m <whitelist|blacklist>"; pick_geomode ;;
		*) die "Unrecognized mode '$geomode'! Use either 'whitelist' or 'blacklist'!"
	esac
	[ "$lan_subnets_arg" ] && [ "$geomode" = blacklist ] && die "option '-l' is incompatible with mode 'blacklist'"

	pick_ccodes

	pick_user_ccode

	# ifaces and lan subnets
	lan_picked=
	if [ -z "$ifaces_arg" ]; then
		[ "$nointeract" ] && die "Specify interfaces with -i <\"ifaces\"|auto|all>."
		printf '\n%s\n%s\n%s\n%s\n' "${blue}Does this machine have dedicated WAN network interface(s)?$n_c [y|n] or [a] to abort the installation." \
			"For example, a router or a virtual private server may have it." \
			"A machine connected to a LAN behind a router is unlikely to have it." \
			"It is important to answer this question correctly."
		pick_opt "y|n|a"
		case "$REPLY" in
			a|A) exit 0 ;;
			y|Y) pick_ifaces ;;
			n|N) [ "$geomode" = whitelist ] && pick_lan_ips
		esac
	else
		case "$ifaces_arg" in
			all) [ "$geomode" = whitelist ] && pick_lan_ips ;;
			auto) ifaces_arg=''; pick_ifaces -a ;;
			*) pick_ifaces
		esac
	fi

	[ "$lan_subnets_arg" ] && [ "$lan_subnets_arg" != none ] && [ ! "$lan_picked" ] && pick_lan_ips
	:
}
