#!/bin/sh
# shellcheck disable=SC2086,SC2154,SC2155,SC2034,SC1090

# geoip-shell-lib-setup.sh

# implements CLI interactive/noninteractive setup and args parsing for the -manage script

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


#### FUNCTIONS

validate_ccodes() {
	bad_ccodes=
	for ccode in $1; do
		validate_ccode "$ccode"
		case $? in
			1) die "Internal error while validating country codes." ;;
			2) bad_ccodes="$bad_ccodes$ccode "
		esac
	done
	[ "$bad_ccodes" ] && die "Invalid 2-letters country codes: '${bad_ccodes% }'."
}

# checks country code by asking the user, then validates against known-good list
pick_user_ccode() {
	[ "$user_ccode_arg" = none ] || { [ "$nointeract" ] && [ ! "$user_ccode_arg" ]; } && { user_ccode=none; return 0; }

	[ ! "$user_ccode_arg" ] && printf '\n%s\n%s\n' "${blue}Please enter your country code.$n_c" \
		"It will be used to check if your geoblocking settings may block your own country and warn you if so."
	REPLY="$user_ccode_arg"
	while :; do
		[ ! "$REPLY" ] && {
			printf %s "Country code (2 letters)/Enter to skip: "
			read -r REPLY
		}
		case "$REPLY" in
			'') printf '%s\n\n' "Skipped."; user_ccode=none; return 0 ;;
			*)
				is_alphanum "$REPLY" || {
					REPLY=
					[ "$nointeract" ] && die 1
					continue
				}
				toupper REPLY
				validate_ccode "$REPLY"; rv=$?
				case "$rv" in
					0)  user_ccode="$REPLY"; break ;;
					1)  die "Internal error while trying to validate country codes." ;;
					2)  printf '\n%s\n' "'$REPLY' is not a valid 2-letter country code."
						[ "$nointeract" ] && die 1
						printf '%s\n\n' "Try again or press Enter to skip this check."
						REPLY=
				esac
		esac
	done
}

# asks the user to entry country codes, then validates against known-good list
pick_ccodes() {
	[ "$nointeract" ] && [ ! "$ccodes_arg" ] && die "Specify country codes with '-c <\"country_codes\">'."
	[ ! "$ccodes_arg" ] && printf '\n%s\n' "${blue}Please enter country codes to include in $direction geoblocking $geomode.$n_c"
	REPLY="$ccodes_arg"
	while :; do
		unset bad_ccodes ok_ccodes
		[ ! "$REPLY" ] && {
			printf %s "Country codes (2 letters) or [a] to abort: "
			read -r REPLY
		}
		case "$REPLY" in *[!A-Za-z\ ,\;]*)
			msg="Invalid country codes: '$REPLY'."
			[ "$nointeract" ] && die "$msg"
			printf '%s\n' "$msg" >&2
			REPLY=
			continue
		esac
		toupper REPLY
		trimsp REPLY
		case "$REPLY" in
			a|A) die 253 ;;
			*)
				newifs ' ;,' pcc
				for ccode in $REPLY; do
					[ "$ccode" ] && {
						validate_ccode "$ccode" && ok_ccodes="$ok_ccodes$ccode " || bad_ccodes="$bad_ccodes$ccode "
					}
				done
				oldifs pcc
				[ "$bad_ccodes" ] && {
					msg="Invalid 2-letter country codes: '${bad_ccodes% }'."
					[ "$nointeract" ] && die "$msg"
					printf '%s\n' "$msg" >&2
					REPLY=
					continue
				}
				[ ! "$ok_ccodes" ] && {
					msg="No valid country codes detected in '$REPLY'."
					[ "$nointeract" ] && die "$msg"
					printf '%s\n' "$msg" >&2
					REPLY=
					continue
				}
				ccodes="${ok_ccodes% }"; break
		esac
	done
}

pick_geomode() {
	printf '\n%s\n' "${blue}Select *$direction* geoblocking mode:$n_c [w]hitelist or [b]lacklist or [d]isable, or [a] to abort."
	[ "$direction" = outbound ] && printf '%s\n' \
		"${yellow}*NOTE*${n_c}: this may block Internet access if you are not careful. If unsure, select [d]isable."
	pick_opt "w|b|d|a"
	case "$REPLY" in
		w) geomode=whitelist ;;
		b) geomode=blacklist ;;
		d) geomode=disable ;;
		a) die 253
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
		san_str -n auto_ifaces
		get_intersection "$auto_ifaces" "$all_ifaces" auto_ifaces "$_nl"
		nl2sp auto_ifaces
	}

	nl2sp all_ifaces
	printf '\n%s\n' "${yellow}*NOTE*: ${blue}Geoblocking firewall rules will be applied to specific network interfaces of this machine.$n_c"
	[ ! "$ifaces_arg" ] && [ "$auto_ifaces" ] && {
		printf '%s\n%s\n' "All found network interfaces: $all_ifaces" \
			"Automatically detected WAN interfaces: $blue$auto_ifaces$n_c"
		[ "$1" = "-a" ] && { ifaces="$auto_ifaces"; ifaces_picked=1; return; }
		[ "$nointeract" ] && die
		printf '%s\n' "[c]onfirm, c[h]ange, or [a]bort?"
		pick_opt "c|h|a"
		case "$REPLY" in
			c) ifaces="$auto_ifaces"; ifaces_picked=1; return ;;
			a) die 253
		esac
	}

	[ "$1" = "-a" ] && [ ! "$ifaces_arg" ] && [ ! "$auto_ifaces" ] && [ "$nointeract" ] &&
		die "$FAIL automatically detect WAN network interfaces."

	REPLY="$ifaces_arg"
	while :; do
		u_ifaces=
		[ ! "$REPLY" ] && [ ! "$nointeract" ] && {
			printf '%s\n%s\n' "All found network interfaces: $all_ifaces" \
				"Type in WAN network interface names, or [a] to abort."
			read -r REPLY
			case "$REPLY" in a|A) die 253; esac
		}
		san_str u_ifaces "$REPLY"
		[ -z "$u_ifaces" ] && {
			printf '%s\n' "No interface names detected in '$REPLY'." >&2
			REPLY=
			[ "$nointeract" ] && die
			continue
		}
		subtract_a_from_b "$all_ifaces" "$u_ifaces" bad_ifaces
		[ -z "$bad_ifaces" ] && break
		echolog -err "Network interfaces '$bad_ifaces' do not exist in this system."
		echo
		[ "$nointeract" ] && die
		REPLY=
		printf '\n'
	done
	ifaces="$u_ifaces"
	printf '%s\n' "Selected interfaces: '$ifaces'."
	ifaces_picked=1
}

# 1 - input IPs/subnets
# 2 - output var base name
# outputs whitespace-delimited validated IPs via $2_$family
# if a subnet detected in ips of a particular family, output is prefixed with 'net:', otherwise with 'ip:'
# expects the $families var to be set
validate_arg_ips() {
	va_ips_a=
	sp2nl va_ips_i "$1"
	san_str -n va_ips_i
	[ ! "$va_ips_i" ] && { echolog -err "No IPs detected in '$1'."; return 1; }
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
	subtract_a_from_b "$va_ips_a" "$va_ips_i" bad_ips "$_nl" ||
		{ nl2sp bad_ips; echolog -err "Invalid IPs for families '$families': '$bad_ips'"; return 1; }

	for f in $families; do
		eval "${2}_$f=\"\$va_$f\""
	done
	:
}

# 1 - var name for output
# 2 - family
# 3 - description to print
pick_ips() {
	pi_var="$1"
	pi_family="$2"
	pi_msg="$3"
	while :; do
		unset REPLY pi_ips
		printf '\n%s\n' "Type in $family addresses for $pi_msg, [s] to skip or [a] to abort."
		read -r REPLY
		case "$REPLY" in
			s|S) unset "$pi_var"; return 1 ;;
			a|A) die 253
		esac
		case "$REPLY" in *[!A-Za-z0-9.:/\ ]*)
			printf '%s\n' "Invalid IP adresses: '$REPLY'"
			continue
		esac
		san_str pi_ips "$REPLY"
		[ -z "$pi_ips" ] && continue
		validate_ip "$pi_ips" "$family" && break
	done
	eval "$pi_var=\"$pi_ips\""
}

pick_lan_ips() {
	confirm_ips() {
		unset "lan_ips_$family"
		[ "$lan_ips" ] && eval "lan_ips_$family=\"$ipset_type:$lan_ips\""
	}

	debugprint "Processing lan ips..."
	lan_picked=1
	unset autodetect ipset_type lan_ips lan_ips_ipv4 lan_ips_ipv6
	case "$lan_ips_arg" in
		none) return 0 ;;
		auto) lan_ips_arg=''; autodetect=1
	esac

	[ "$lan_ips_arg" ] && validate_arg_ips "$lan_ips_arg" lan_ips && return 0

	[ "$nointeract" ] && [ ! "$autodetect" ] && die "Specify lan IPs with '-l <\"lan_ips\"|auto|none>'."

	[ ! "$nointeract" ] && {
		[ ! "$autodetect" ] && echo "You can specify LAN subnets and/or individual IPs to allow."
	}

	[ -s "${_lib}-ip-tools.sh" ] && . "${_lib}-ip-tools.sh" || echolog -err "$FAIL source ${_lib}-ip-tools.sh"

	for family in $families; do
		ipset_type=net
		echo
		command -v get_lan_subnets 1>/dev/null && {
			printf %s "Detecting $family LAN subnets..."
			lan_ips="$(get_lan_subnets "$family")"
		} || {
			[ "$nointeract" ] && die
		}

		[ -n "$lan_ips" ] && {
			nl2sp lan_ips
			printf '\n%s\n' "Automatically detected $family LAN subnets: '$blue$lan_ips$n_c'."
			[ "$autodetect" ] && { confirm_ips; continue; }
			printf '%s\n%s\n' "[c]onfirm, c[h]ange, [s]kip or [a]bort?" \
				"Verify that correct LAN subnets have been detected in order to avoid accidental lockout or other problems."
			pick_opt "c|h|s|a"
			case "$REPLY" in
				c) confirm_ips; continue ;;
				s) continue ;;
				h) autodetect_off=1 ;;
				a) die 253
			esac
		}

		pick_ips lan_ips "$family" "LAN IP addresses and/or subnets" || continue
		confirm_ips
	done
	echo

	[ "$autodetect" ] || [ "$autodetect_off" ] && return
	printf '%s\n' "${blue}A[u]tomatically detect LAN subnets when updating IP lists or keep this config c[o]nstant?$n_c"
	pick_opt "u|o"
	[ "$REPLY" = u ] && autodetect=1
}

pick_source_ips() {
	confirm_ips() {
		unset "source_ips_$family"
		[ "$source_ips" ] && eval "source_ips_$family=\"$ipset_type:$source_ips\""
	}

	debugprint "Processing source ips..."
	unset source_ips_autodetect source_ips_policy source_ips source_ips_ipv4 source_ips_ipv6 ipset_type
	tolower source_ips_arg
	case "$source_ips_arg" in
		pause|none) source_ips_policy="$source_ips_arg"; source_ips_arg=''; return 0 ;;
		auto) source_ips_arg=''; source_ips_autodetect=1
	esac

	[ "$source_ips_arg" ] && {
		validate_arg_ips "$source_ips_arg" source_ips && return 0
		[ "$nointeract" ] && die
	}


	if [ ! "$source_ips_autodetect" ]; then
		[ "$nointeract" ] && return 0
		printf '\n%s\n%s\n%s\n%s\n' "$WARN outbound geoblocking may prevent $p_name from being able to automatically update IP lists." \
			"To safeguard automatic IP list updates, either choose IP addresses of the download servers to bypass outbound geoblocking," \
			"  or enable pausing of outbound geoblocking before each IP lists update." \
			"[C]hoose IP addresses, [p]ause outbound geoblocking every time before IP list updates, [s]kip or [a]bort?"
		pick_opt "c|p|s|a"
		case "$REPLY" in
			c) source_ips_policy= ;;
			p) source_ips_policy=pause; return 0 ;;
			s) source_ips_policy=none; return 0 ;;
			a) die 253
		esac
	fi

	for family in $families; do
		ipset_type=ip
		echo
		source_ips="$(resolve_geosource_ips "$family")"

		if [ -n "$source_ips" ]; then
			nl2sp source_ips
			printf '\n%s\n' "Automatically detected $family addresses for source '$geosource': '$blue$source_ips$n_c'."
			[ "$source_ips_autodetect" ] && { confirm_ips; continue; }
			printf '%s\n' "[c]onfirm, c[h]ange, [a]bort?"
			pick_opt "c|h|a"
			case "$REPLY" in
				c) confirm_ips; continue ;;
				h) ;;
				a) die 253
			esac
		elif [ "$geosource" = ipdeny ] && [ "$family" = ipv6 ]; then
				printf '%s\n' "At this time the 'ipdeny' servers do not have ipv6 addresses - skipping."
				continue
		else
			printf '%s\n' "$FAIL automatically detect $family addresses for source '$geosource'."
		fi

		pick_ips source_ips "$family" "addresses for source '$geosource'" || continue
		confirm_ips
	done
	echo
}

invalid_str() { echolog -err "Invalid string '$1'."; }

check_edge_chars() {
	[ "${1%"${1#?}"}" = "$2" ] && { invalid_str "$1"; return 1; }
	[ "${1#"${1%?}"}" = "$2" ] && { invalid_str "$1"; return 1; }
	:
}

# output via variables: $_ports, $mp
parse_ports() {
	invalid_ports() { echolog -err "Invalid string in ports expression: '$1'."; }
	check_edge_chars "$1" "," || return 1
	ranges_cnt=0
	_ports=
	IFS=","
	for _range in $1; do
		ranges_cnt=$((ranges_cnt+1))
		trimsp _range
		check_edge_chars "$_range" '-' || return 1
		case "${_range#*"-"}" in *-*) invalid_ports "$_range"; return 1; esac
		IFS="-"
		for _port in $_range; do
			trimsp _port
			case "$_port" in *[!0-9]*) invalid_ports "$_port"; return 1; esac
			_ports="$_ports$_port-"
		done
		_ports="${_ports%"-"},"
		case "$_range" in *-*)
			[ "${_range%"-"*}" -ge "${_range##*"-"}" ] &&
			{ invalid_ports "$_range"; return 1; }
		esac
	done
	[ "$ranges_cnt" = 0 ] && { echolog -err "No ports specified for protocol $_proto."; return 1; }
	_ports=":${_ports%,}"

	[ "$ranges_cnt" -gt 1 ] && mp="multiport "
	:
}

# input format: '[tcp|udp]:[allow|block]:[ports]'
# output format: 'skip|all|<[!]dport:[port-port,port...]>'
# output via variables: ${_proto}_ports, ${direction}_${_proto}_ports
setports() {
	tolower _lines "$1"
	newifs "$_nl" sp
	for _line in $_lines; do
		unset ranges _ports neg mp
		trimsp _line
		check_edge_chars "$_line" ":" || return 1
		IFS=':'
		set -- $_line
		[ $# != 3 ] && { echolog -err "Invalid syntax '$_line'"; return 1; }
		_proto="$1"
		proto_act="$2"
		_ranges="$3"
		trimsp _ranges
		trimsp _proto
		trimsp proto_act
		case "$proto_act" in
			allow) neg='' ;;
			block) neg='!' ;;
			*) { echolog -err "Expected 'allow' or 'block' instead of '$proto_act'"; return 1; }
		esac
		# check for valid protocol
		eval "reg_proto=\"\$${direction}_reg_proto\""
		case $_proto in
			udp|tcp)
				case "$reg_proto" in *"$_proto"*)
					echolog -err "Can't add protocol '$_proto' twice for direction '$direction'."; return 1
				esac
				eval "${direction}_reg_proto=\"$reg_proto$_proto \"" ;;
			*) echolog -err "Unsupported protocol '$_proto'."; return 1
		esac

		if [ "$_ranges" = all ]; then
			_ports=
			[ "$neg" ] && ports_exp=skip || ports_exp=all
		else
			parse_ports "$_ranges" || return 1
			ports_exp="$mp${neg}dport"
		fi
		trimsp ports_exp
		eval "${direction}_${_proto}_ports=\"$ports_exp$_ports\" ${_proto}_ports=\"$ports_exp$_ports\""
		debugprint "$direction $_proto: ports: '$ports_exp$_ports'"
	done
	oldifs sp
}

warn_lockout() {
	printf '\n\n%s\n' \
	"${yellow}*NOTE*${n_c}: ${blue}In whitelist mode, traffic from your LAN subnets will be blocked, unless you whitelist them.$n_c"
}

# assigns default values, unless the var is set
set_defaults() {
	_fw_backend_def="$(detect_fw_backend)" || die

	# check RAM capacity, set default optimization policy for nftables sets to performance if RAM>=1840MiB
	[ ! "$nft_perf" ] && {
		nft_perf_def=memory
		IFS=': ' read -r _ memTotal _ < /proc/meminfo 2>/dev/null
		case "$memTotal" in
			''|*![0-9]*) ;;
			*) [ $memTotal -ge 1884160 ] && nft_perf_def=performance
		esac
	}

	noblock_def=false no_persist_def=false force_cron_persist_def=false

	# randomly select schedule minute between 10 and 19
	[ ! "$schedule" ] && {
		rand_int="$(tr -cd 0-9 < /dev/urandom | dd bs=1 count=1 2>/dev/null)"
		: "${rand_int:=0}"
		# for the superstitious
		[ "$rand_int" = 3 ] && rand_int=10
		def_sch_minute=$((10+rand_int))
	}

	if [ "$_OWRTFW" ]; then
		geosource_def=ipdeny datadir_def="/tmp/$p_name-data" nobackup_def=true
		local_iplists_dir_def="$conf_dir/local_iplists"
	else
		geosource_def=ripe datadir_def="/var/lib/$p_name" nobackup_def=false
		local_iplists_dir_def="$datadir_def/local_iplists"
	fi

	keep_mm_db_def=false

	: "${nobackup:="$nobackup_def"}"
	: "${datadir:="$datadir_def"}"
	: "${local_iplists_dir:="$local_iplists_dir_def"}"
	: "${schedule:="$def_sch_minute 4 * * *"}"
	: "${families:="ipv4 ipv6"}"
	: "${geosource:="$geosource_def"}"
	: "${keep_mm_db:=false}"
	: "${_fw_backend:="$_fw_backend_def"}"
	: "${inbound_tcp_ports:=skip}"
	: "${inbound_udp_ports:=skip}"
	: "${outbound_tcp_ports:=skip}"
	: "${outbound_udp_ports:=skip}"
	: "${nft_perf:=$nft_perf_def}"
	: "${reboot_sleep:=30}"
	: "${max_attempts:=5}"
	: "${noblock:=$noblock_def}"
	: "${no_persist:=$no_persist_def}"
	: "${force_cron_persist:=$force_cron_persist_def}"
}

get_general_prefs() {
	dir_change() {
		eval "dir_arg=\"\${${1}_arg}\" dir_old=\"\${$1%/}\""
		dir_new="${dir_arg%/}"
		[ ! "$dir_new" ] && die "Invalid directory '$dir_arg'."
		case "$dir_new" in /*) ;; *) die "Invalid directory '$dir_arg'."; esac
		[ "$dir_new"  = "$dir_old" ] && { eval "$1"='$dir_old'; return 0; }
		case "$dir_new" in "$datadir"|"$local_iplists_dir"|"$iplist_dir"|"$conf_dir")
			die "Directory '$dir_new' is reserved. Please pick another one."
		esac
		is_dir_empty "$dir_new" || die "Can not use directory '$dir_arg': it exists and is not empty."
		parent_dir="${dir_new%/*}/"
		[ ! -d "$parent_dir" ] && die "Can not create directory '$dir_arg': parent directory '$parent_dir' doesn't exist."
		eval "$1"='${dir_new}'
	}

	set_defaults
	# firewall backend
	[ "$_fw_backend_arg" ] && {
		[ "$_OWRTFW" ] && die "Changing the firewall backend is unsupported on OpenWrt."
		check_fw_backend "$_fw_backend_arg" ||
		case $? in
			1) die ;;
			2) die "Firewall backend '${_fw_backend_arg}ables' not found." ;;
			3) die "Utility 'ipset' not found."
		esac
	}
	_fw_backend="${_fw_backend_arg:-$_fw_backend}"

	# nft_perf
	[ "$nft_perf_arg" ] && {
		[ "$_fw_backend" = ipt ] && die "Option -O does not work with iptables+ipset."
		tolower nft_perf_arg
	}
	case "$nft_perf_arg" in
		''|performance|memory) ;;
		*) die "Invalid value for option '-O': '$nft_perf_arg'."
	esac
	nft_perf="${nft_perf_arg:-$nft_perf}"

	# nobackup, noblock, no_persist, force_cron_persist, keep_mm_db
	for _par in "nobackup o" "noblock N" "no_persist n" "force_cron_persist F" "keep_mm_db K"; do
		par_name="${_par% *}" par_opt="${_par#* }"
		eval "par_val=\"\$$par_name\"
			par_val_arg=\"\${${par_name}_arg}\"
			def_val=\"\$${par_name}_def\""
		[ "$par_val_arg" ] && tolower par_val_arg
		case "$par_val_arg" in
			''|true|false) ;;
			*) die "Invalid value for option '-$par_opt': '$par_val_arg'."
		esac
		par_val="${par_val_arg:-"$par_val"}"
		case "$par_val" in
			true)
				[ "$first_setup" ] && [ "$par_val_arg" != true ] &&
					case "$par_name" in noblock|no_persist|force_cron_persist)
						echolog -warn "${_nl}option '$par_name' is set to 'true' in config."
					esac ;;
			false) ;;
			*)
				[ ! "$first_setup" ] &&
					echolog -warn "Config has invalid value for parameter '$par_name': '$par_val'. Resetting to default: '$def_val'."
				par_val="$def_val"
		esac
		eval "$par_name"='$par_val'
	done

	# datadir
	[ "$datadir_arg" ] && dir_change datadir

	# local IP lists dir
	[ "$local_iplists_dir_arg" ] && dir_change local_iplists_dir

	# cron schedule
	schedule="${schedule_arg:-"$schedule"}"

	{ [ "$schedule" != "$schedule_prev" ] && [ "$schedule" != disable ]; } ||
	{ [ "$no_persist" != "$no_persist_prev" ] && [ "$no_persist" = false ]; } &&
		{ check_cron_compat || die; }
	[ "$schedule_arg" ] && [ "$schedule_arg" != disable ] && {
		call_script "$_script-cronsetup.sh" -x "$schedule_arg" || die "$FAIL validate cron schedule '$schedule_arg'."
	}

	# families
	[ "$families_arg" ] && tolower families_arg
	case "$families_arg" in
		'') ;;
		inet|ipv4) families_arg=ipv4 ;;
		inet6|ipv6) families_arg=ipv6 ;;
		'inet inet6'|'inet6 inet'|'ipv4 ipv6'|'ipv6 ipv4') families_arg="ipv4 ipv6" ;;
		*) die "Invalid family '$families_arg'."
	esac
	families="${families_arg:-"$families"}"

	# source
	is_alphanum "$geosource_arg" && tolower geosource_arg && subtract_a_from_b "$valid_sources" "$geosource_arg" ||
		die "Invalid source: '$geosource_arg'"
	geosource="${geosource_arg:-$geosource}"
	if [ "$geosource_arg" = maxmind ]; then
		setup_maxmind || die 253
	fi

	# process trusted IPs if specified
	case "$trusted_arg" in
		none) unset trusted_ipv4 trusted_ipv6 ;;
		'') ;;
		*)
			validate_arg_ips "$trusted_arg" trusted && return 0
			[ "$nointeract" ] && die
			for family in $families; do
				ipset_type=net
				pick_ips trusted "$family" "trusted IP addresses or subnets" || continue
				unset "trusted_$family"
				[ "$trusted" ] && eval "trusted_$family=\"$ipset_type:$trusted\""
			done
	esac

	# sanitization for local IP lists
	sed_san() {
		sed 's/\r/\n/g;s/\n$//' "$1" | sed "s/#.*//;s/^${blanks}//;s/${blanks}$//;/^$/d"
	}

	# process and import local IP lists if specified
	for iplist_type in allow block; do
		eval "file=\"\$local_${iplist_type}_arg\""
		case "$file" in
			'') continue ;;
			remove)
				printf '%s\n' "Removing local ${iplist_type}lists..."
				prev_local_file="$(find "${local_iplists_dir}" -name "local_${iplist_type}_*" -exec rm -f {} \; -exec printf '%s\n' {} \;)"
				[ -n "${prev_local_file}" ] && lists_change=1
				continue
		esac

		printf %s "Checking local ${iplist_type}list file '$file'... "
		[ -s "$file" ] || die "${_nl}IP list file '$file' is empty or doesn't exist."
		# detect family
		for iplist_family in 4 6; do
			eval "ip_regex=\"\${ipv${iplist_family}_regex}\"
				mb_regex=\"\${maskbits_regex_ipv${iplist_family}}\""
			sed 's/\r/\n/g;s/\n$//' "$file" | grep -E -m1 "^${blank}*${ip_regex}(/${mb_regex}|)${blank}*$" 1>/dev/null &&
				break
		done ||
			die "${_nl}$FAIL process IP list file '$file' or it does not contain newline-separated IP addresses."

		# check for invalid lines
		invalid_ip="$(
			sed_san "$file" | {
				grep -Ev -m1 "^${ip_regex}(/${mb_regex}|)$"
				rv=$?
				cat 1>/dev/null
				exit $rv
			}
		)" &&
		# found invalid line
		{
			case "$iplist_family" in
				4) check_family=6 ;;
				6) check_family=4
			esac
			eval "iplist_regex=\"^\${ipv${check_family}_regex}(/\${maskbits_regex_ipv${check_family}}|)$\""
			if printf '%s\n' "$invalid_ip" | grep -E "$iplist_regex" 1>/dev/null; then
				die "${_nl}IP list file '$file' contains both IPv4 and IPv6 addresses - this is not supported."
			else
				die "${_nl}IP list file '$file' contains unexpected string '$invalid_ip'."
			fi
		}

		# determine elements type
		iplist_el_type=ip
		grep -E -m1 "/${mb_regex}" "$file" 1>/dev/null && iplist_el_type=net

		printf '%s\n' "${blue}Detected IPv${iplist_family} with elements of type '$iplist_el_type'${n_c}."
		dir_mk "$local_iplists_dir"
		printf %s "Importing local IPv${iplist_family} ${iplist_type}list file... "
		dest_file="${local_iplists_dir}/local_${iplist_type}_ipv${iplist_family}.${iplist_el_type}"
		{
			[ -f "$dest_file" ] && cat "$dest_file"
			sed_san "$file"
			tail -c 1 "$file" | grep . && printf '\n' # add newline if needed
			:
		} | sort -u > "/tmp/$p_name-import.tmp" && [ -s "/tmp/$p_name-import.tmp" ] &&
		{
			old_local_exists=
			[ -f "$dest_file" ] && old_local_exists=1
			if [ -n "$old_local_exists" ] && [ "$(get_md5 "$dest_file")" = "$(get_md5 "/tmp/$p_name-import.tmp")" ]; then
				rm -f "/tmp/$p_name-import.tmp"
			else
				mv "/tmp/$p_name-import.tmp" "$dest_file"
			fi
		} || {
				FAIL
				rm -f "/tmp/$p_name-import.tmp"
				[ -n "$old_local_exists" ] || rm -f "$dest_file"
				die "$FAIL import the IP list into file '$dest_file'."
			}
		OK

		case "$iplist_el_type" in
			ip) inv_el_type=net ;;
			net) inv_el_type=ip
		esac
		rm -f "${dest_file%."$iplist_el_type"}.${inv_el_type}"

		printf '%s\n' "${yellow}You can delete the file '$file' to free up space.${n_c}"
		lists_change=1
	done

	[ ! "$user_ccode" ] || [ "$user_ccode_arg" ] && pick_user_ccode
	:
}

[ "$script_dir" = "$install_dir" ] && _script="$i_script" || _script="$p_script"

:
