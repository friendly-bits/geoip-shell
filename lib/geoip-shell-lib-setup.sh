#!/bin/sh
# shellcheck disable=SC2086,SC2154,SC2155,SC2034,SC1090

# geoip-shell-lib-setup.sh

# implements CLI interactive/noninteractive setup and args parsing for the -manage script

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


#### FUNCTIONS

# validate reg. names or country codes against cca2.list, translate reg. names to country codes
# 1: var name for output
# 2: input
# 3 (optional): list of delimiters
normalize_ccodes() {
	nc_in="$2"
	eval "$1="
	nc_inval=
	load_cca2 "$CONF_DIR/cca2.list" || die
	toupper nc_in
	nc_out=
	newifs "${3:- }" ncc
	for nc_code in $nc_in; do
		oldifs ncc
		[ "$nc_code" = RIPE ] && nc_code=RIPENCC
		is_included "$nc_code" "$VALID_REGISTRIES" && {
			eval "nc_reg_ccodes=\"\${$nc_code}\""
			nc_ccodes="${nc_ccodes}${nc_ccodes:+ }${nc_reg_ccodes}"
			continue
		}
		is_included "$nc_code" "$ALL_CCODES" && {
			add2list nc_ccodes "$nc_code"
			continue
		}
		add2list nc_inval "$nc_code"
	done
	oldifs ncc

	[ -n "$nc_inval" ] && {
		echolog -err "'$nc_inval' are not valid region names or 2-letter country codes."
		return 1
	}

	eval "$1"='$nc_ccodes'
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
				validate_ccode REPLY "$REPLY" && { user_ccode="$REPLY"; break; }
				printf '%s\n\n' "Try again or press Enter to skip this check."
				REPLY=
		esac
	done
}

# asks the user to entry country codes, then validates against known-good list
pick_ccodes() {
	out_var_pc="$1" ccodes_arg_pc="$2"
	[ "$nointeract" ] && [ ! "$ccodes_arg_pc" ] && die "Specify country codes with '-c <\"country_codes\">'."
	[ ! "$ccodes_arg_pc" ] && printf '\n%s\n' "${blue}Please enter country codes to include in $direction geoblocking $geomode.$n_c"
	REPLY="$ccodes_arg_pc"
	while :; do
		unset ok_ccodes
		[ ! "$REPLY" ] && {
			printf %s "Enter whitespace-separated country codes (2 letters) and/or regions (RIPE, ARIN, APNIC, AFRINIC, LACNIC) or [a] to abort: "
			read -r REPLY
		}
		case "$REPLY" in
			a|A) die 253 ;;
			*)
				normalize_ccodes ok_ccodes "$REPLY" " ;," || {
					[ "$nointeract" ] && die
					REPLY=
					continue
				}
				eval "$out_var_pc"='${ok_ccodes% }'
				return 0
		esac
	done
}

pick_geomode() {
	printf '\n%s\n' "${blue}Select *$direction* geoblocking mode:$n_c [w]hitelist or [b]lacklist or [d]isable, or [a] to abort."
	[ "$direction" = outbound ] && printf '%s\n' \
		"${yellow}* NOTE *${n_c}: this may block Internet access if you are not careful. If unsure, select [d]isable."
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

# 1 - input IPs/ranges
# 2 - output var base name
# outputs whitespace-delimited validated IPs via $2_$family
# if a range is detected in addresses of a particular family, output is prefixed with 'net:', otherwise with 'ip:'
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
	eval "$pi_var"='$pi_ips'
}

pick_lan_ips() {
	confirm_ips() {
		unset "lan_ips_$family"
		[ "$lan_ips" ] && eval "lan_ips_$family"='$ipset_type:$lan_ips'
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
		[ ! "$autodetect" ] && echo "You can specify LAN IP addresses and/or IP ranges to allow."
	}

	source_lib ip-tools || die

	for family in $families; do
		ipset_type=net
		echo
		checkutil get_lan_addresses && {
			printf %s "Detecting $family LAN IP ranges..."
			lan_ips="$(get_lan_addresses "$family")"
		} || {
			[ "$nointeract" ] && die
		}

		[ -n "$lan_ips" ] && {
			nl2sp lan_ips
			printf '\n%s\n' "Automatically detected $family LAN IP ranges: '$blue$lan_ips$n_c'."
			[ "$autodetect" ] && { confirm_ips; continue; }
			printf '%s\n%s\n' "[c]onfirm, c[h]ange, [s]kip or [a]bort?" \
				"Verify that correct LAN IP ranges have been detected in order to avoid accidental lockout or other problems."
			pick_opt "c|h|s|a"
			case "$REPLY" in
				c) confirm_ips; continue ;;
				s) continue ;;
				h) autodetect_off=1 ;;
				a) die 253
			esac
		}

		pick_ips lan_ips "$family" "LAN IP addresses and/or IP ranges" || continue
		confirm_ips
	done
	echo

	[ "$autodetect" ] || [ "$autodetect_off" ] && return
	printf '%s\n' "${blue}A[u]tomatically detect LAN IP ranges when updating IP lists or keep this config c[o]nstant?$n_c"
	pick_opt "u|o"
	[ "$REPLY" = u ] && autodetect=1
}

pick_source_ips() {
	confirm_ips() {
		unset "source_ips_$family"
		[ "$source_ips" ] && eval "source_ips_$family"='$ipset_type:$source_ips'
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

	case "$geosource" in
		ripe) src_domains="${ripe_url_api%%/*}${_nl}${ripe_url_stats%%/*}" ;;
		ipdeny) src_domains="${ipdeny_ipv4_url%%/*}" ;;
		ipinfo) src_domains="${ipinfo_url%%/*}" ;;
		maxmind) src_domains="download.maxmind.com${_nl}www.maxmind.com${_nl}mm-prod-geoip-databases.a2649acb697e2c09b632799562c076f2.r2.cloudflarestorage.com"
	esac

	for family in $families; do
		ipset_type=ip
		echo
		source_ips="$(resolve_domain_ips "$family" "$src_domains")"

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
		elif [ "$family" = ipv6 ] && { [ "$geosource" = ipdeny ] || [ "$geosource" = ipinfo ]; }; then
				printf '%s\n' "At this time the $geosource servers do not have ipv6 addresses - skipping."
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

# input format: '< [tcp|udp]:[allow|block]:[ports] | icmp:[allow|block] >'
# output format: 'skip|all|<[!]dport:[port-port,port...]>'
# output via variables:
#   tcp/udp: ${direction}_${_proto}_ports
#   icmp: ${direction}_icmp
setprotocols() {
	tolower _lines "$1"
	newifs "$_nl" sp
	for _line in $_lines; do
		unset ranges _ports neg mp
		trimsp _line
		check_edge_chars "$_line" ":" || return 1
		IFS=':'
		set -- $_line
		_proto="$1"
		proto_act="$2"
		_ranges_in="$3"
		trimsp _ranges_in
		trimsp proto_act

		case "$_proto" in
			tcp|udp) _ranges="$_ranges_in"; trimsp _proto; [ $# = 3 ] ;;
			icmp) _ranges=all; [ $# = 2 ] || { [ $# = 3 ] && [ "$_ranges_in" = all ]; } ;;
			*) false
		esac || { echolog -err "Invalid syntax '$_line' in protocol expression."; return 1; }

		case "$proto_act" in
			allow) neg='' ;;
			block) neg='!' ;;
			*) { echolog -err "Expected 'allow' or 'block' instead of '$proto_act'"; return 1; }
		esac
		# check for valid protocol
		eval "reg_proto=\"\$${direction}_reg_proto\""
		case $_proto in
			udp|tcp|icmp)
				case "$reg_proto" in *"$_proto"*)
					echolog -err "Can't add rules for protocol '$_proto' twice for direction '$direction'."; return 1
				esac
				eval "${direction}_reg_proto"='$reg_proto$_proto ' ;;
			*) echolog -err "Unsupported protocol '$_proto'."; return 1
		esac

		case "$_ranges" in
			all)
				_ports=
				[ "$neg" ] && proto_exp=skip || proto_exp=all ;;
			*)
				parse_ports "$_ranges" || return 1
				proto_exp="$mp${neg}dport"
				trimsp proto_exp
		esac

		case "$_proto" in
			tcp|udp) eval "${direction}_${_proto}_ports"='$proto_exp$_ports' ;;
			icmp) eval "${direction}_icmp"='$proto_exp' ;;
		esac
		debugprint "$direction $_proto: expression: '$proto_exp$_ports'"
	done
	oldifs sp
}

warn_lockout() {
	printf '\n\n%s\n' \
	"${yellow}*NOTE*${n_c}: ${blue}In whitelist mode, traffic from your LAN IP ranges will be blocked, unless you whitelist them.$n_c"
}

# assigns default values, unless the var is set
set_defaults() {
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

	# randomly select schedule minute between 3 and 27
	[ ! "$schedule" ] && {
		get_random_int rand_int 24
		: "${rand_int:=0}"
		# for the superstitious
		[ "$rand_int" = 10 ] && rand_int=25
		def_sch_minute=$((3+rand_int))
	}

	if [ "$_OWRTFW" ]; then
		geosource_def=ipdeny datadir_def="$GEORUN_DIR/data" nobackup_def=true
		local_iplists_dir_def="$CONF_DIR/local_iplists"
		keep_fetched_db_def=false
	else
		geosource_def=ripe datadir_def="/var/lib/$p_name" nobackup_def=false
		local_iplists_dir_def="$datadir_def/local_iplists"
		keep_fetched_db_def=true
	fi

	: "${nobackup:="$nobackup_def"}"
	: "${datadir:="$datadir_def"}"
	: "${local_iplists_dir:="$local_iplists_dir_def"}"
	: "${schedule:="$def_sch_minute 4 * * *"}"
	: "${families:="ipv4 ipv6"}"
	: "${geosource:="$geosource_def"}"
	: "${keep_fetched_db:=false}"
	: "${_fw_backend:="$_FW_BACKEND_DEF"}"
	: "${inbound_tcp_ports:=skip}"
	: "${inbound_udp_ports:=skip}"
	: "${inbound_icmp:=skip}"
	: "${outbound_tcp_ports:=skip}"
	: "${outbound_udp_ports:=skip}"
	: "${outbound_icmp:=skip}"
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
		case "$dir_new" in "$datadir"|"$local_iplists_dir"|"$IPLIST_DIR"|"$CONF_DIR")
			die "Directory '$dir_new' is reserved. Please pick another one."
		esac
		is_dir_empty "$dir_new" || die "Can not use directory '$dir_arg': it exists and is not empty."
		parent_dir="${dir_new%/*}/"
		[ ! -d "$parent_dir" ] && die "Can not create directory '$dir_arg': parent directory '$parent_dir' doesn't exist."
		eval "$1"='${dir_new}'
	}

	[ -z "${_fw_backend}${_fw_backend_arg}" ] && {
		detect_fw_backends || die # sets $_FW_BACKEND_DEF
		case "$_FW_BACKEND_DEF" in
			ipt|nft) echolog "Setting firewall backend to ${_FW_BACKEND_DEF}ables."
		esac
	}

	set_defaults
	# firewall backend
	[ -z "$_fw_backend_arg" ] || check_fw_backend "$_fw_backend_arg" || {
		[ $? = 4 ] && echolog "NOTE: on OpenWrt, by default only one $p_name firewall backend library is installed."
		die
	}

	export _fw_backend="${_fw_backend_arg:-$_fw_backend}"

	# special treatment for LXC containers
	case "${_fw_backend}" in nft|ask)
		unpriv_lxc=''
		# check if running inside LXC container
		if { checkutil systemd-detect-virt && systemd-detect-virt | grep lxc; } ||
			grep -E '[ \t]/proc/(cpuinfo|meminfo|stat|uptime)[ \t].*[ \t]lxcfs[ \t]' /proc/self/mountinfo
		then
			# shellcheck disable=SC2010
			# check if container is privileged
			if ! ls -ld /proc | grep -E '^[-drwx \t]+[0-9]+[ \t]+root[ \t]'; then
				unpriv_lxc=1
			fi
		fi 1>/dev/null 2>/dev/null

		if [ "$unpriv_lxc" ]; then
			printf '\n%s\n%s\n%s\n%s\n\n' \
				"${yellow}** NOTE ** : $p_name seems to be running inside unprivileged LXC container." \
				"Using the nftables backend may run into problems.${n_c}" "Consider using the iptables backend." \
				"See: https://github.com/friendly-bits/geoip-shell/issues/24"
		fi

	esac

	if [ "$_fw_backend" = ask ]; then
		[ "$nointeract" ] && die "Specify the firewall backend with '$p_name configure -w <ipt|nft>'."
		printf '\n%s\n' "This system can use either iptables or nftables rules."
		[ "$IPT_RULES_PRESENT" ] &&
			printf '%s\n%s\n\n' "${yellow}** NOTE **${n_c}: This system has existing iptables rules." \
				"It is recommended to avoid mixing iptables and nftables rules."
		printf '%s\n' "Select the firewall backend: [i]ptables or [n]ftables. Or type in [a] to abort."
		pick_opt "i|n|a"
		case "$REPLY" in
			i) _fw_backend=ipt ;;
			n) _fw_backend=nft ;;
			a) die 253
		esac
		[ "$_fw_backend" = ipt ] && [ ! "$IPSET_PRESENT" ] && die "'ipset' utility is missing. Install it using your package manager."
	fi

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

	# nobackup, noblock, no_persist, force_cron_persist, keep_fetched_db
	for _par in "nobackup o" "noblock N" "no_persist n" "force_cron_persist F" "keep_fetched_db K"; do
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

	# custom_script
	case "$custom_script_arg" in
		'') ;;
		none) custom_script='' ;;
		*)
			check_custom_script "$custom_script_arg" || die
			custom_script="$custom_script_arg"
	esac

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
	is_alphanum "$geosource_arg" && tolower geosource_arg && subtract_a_from_b "$VALID_SRCS_COUNTRY" "$geosource_arg" ||
		die "Invalid source: '$geosource_arg'"
	geosource="${geosource_arg:-$geosource}"
	case "$geosource_arg" in
		maxmind) setup_maxmind ;;
		ipinfo) setup_ipinfo ;;
	esac || die 253

	# process trusted IPs if specified
	case "$trusted_arg" in
		none) unset trusted_ipv4 trusted_ipv6 ;;
		'') ;;
		*)
			validate_arg_ips "$trusted_arg" trusted && return 0
			[ "$nointeract" ] && die
			for family in $families; do
				ipset_type=net
				pick_ips trusted "$family" "trusted IP addresses or ranges" || continue
				unset "trusted_$family"
				[ "$trusted" ] && eval "trusted_$family"='$ipset_type:$trusted'
			done
	esac

	[ ! "$user_ccode" ] || [ "$user_ccode_arg" ] && pick_user_ccode
	:
}

do_configure() {
	prev_config="$main_config"

	[ ! -s "$CONF_FILE" ] && {
		touch "$CONF_FILE" && chmod 600 "$CONF_FILE" && chown root:root "$CONF_FILE" || {
			rm -f "$CONF_FILE"
			die "$FAIL create the config file."
		}
		[ "$_fw_backend" ] && rm_iplists_rules
	}

	debugprint "first_setup: '$first_setup'"

	for var_name in datadir local_iplists_dir noblock nobackup schedule no_persist geosource ifaces families _fw_backend nft_perf \
		user_ccode lan_ips_ipv4 lan_ips_ipv6 trusted_ipv4 trusted_ipv6 source_ips_ipv4 source_ips_ipv6 source_ips_policy; do
		eval "${var_name}_prev=\"\$$var_name\""
	done

	# sets _fw_backend nft_perf nobackup noblock no_persist force_cron_persist datadir local_iplists_dir schedule families
	#   geosource trusted user_ccode keep_fetched_db custom_script
	# imports local IP lists if specified
	get_general_prefs || die

	checkvars _fw_backend datadir

	for opt_ch in datadir local_iplists_dir noblock nobackup schedule no_persist geosource families \
			_fw_backend nft_perf user_ccode source_ips_policy; do
		unset "${opt_ch}_change"
		eval "[ \"\$${opt_ch}\" != \"\$${opt_ch}_prev\" ] && ${opt_ch}_change=1"
	done


	# determine if interactive geomode dialog is needed
	geomode_set=
	for direction in inbound outbound; do
		[ -n "$geomode" ] && geomode_set=1
		eval "geomode_arg=\"\$${direction}_geomode_arg\"
				geomode=\"\$${direction}_geomode\""

		[ "$geomode" ] && geomode_set=1

		[ "$geomode_arg" ] && {
			tolower geomode_arg
			case "$geomode_arg" in whitelist|blacklist|disable)
				geomode_set=1
				eval "${direction}_geomode_arg=\"$geomode_arg\""
			esac
		}
	done

	load_cca2 || die

	# set *_ccodes *_ports icmp *_iplists *_geomode
	unset proto_change geomode_change_g

	for direction in inbound outbound; do
		unset ccodes process_args geomode_change
		contradicts1="contradicts $direction geoblocking mode 'disable'."
		contradicts2="To enable geoblocking for direction $direction: '$p_name configure -D $direction -m <whitelist|blacklist>'"

		for _par in geomode iplists icmp tcp_ports udp_ports; do
			eval "${_par}=\"\${${direction}_${_par}}\" ${_par}_prev=\"\${${direction}_${_par}}\" \
				${direction}_${_par}_prev=\"\${${direction}_${_par}}\""
		done

		san_str "${direction}_ccodes_arg" || die
		toupper "${direction}_ccodes_arg"

		for _par in ccodes_arg proto_arg geomode_arg; do
			eval "${_par}=\"\${${direction}_${_par}}\""
		done

		[ -n "$ccodes_arg" ] || [ -n "$proto_arg" ] && process_args=1

		# geomode
		[ "$geomode_arg" ] && {
			case "$geomode_arg" in
				whitelist|blacklist|disable) geomode="$geomode_arg" ;;
				'') ;;
				*)
					echolog -err "Invalid geoblocking mode '$geomode_arg'."
					[ "$nointeract" ] && die
					pick_geomode
			esac
		}

		[ ! "$geomode_set" ] && {
			if [ "$nointeract" ]; then
				[ "$direction" = outbound ] && die "Specify geoblocking mode with -m $mode_syn"
				geomode=disable
			elif [ "$direction" = inbound ]; then
				pick_geomode
			elif [ "$direction" = outbound ]; then
				echolog "${_nl}${yellow}NOTE${n_c}: You can set up *outbound* geoblocking later by running 'geoip-shell configure -D outbound -m <whitelist|blacklist>'."
			fi
		}

		: "${geomode:=disable}"

		if [ "$geomode" = disable ]; then
			[ "$proto_arg" ] && die "Option '-p' $contradicts1" "$contradicts2"
			[ "$ccodes_arg" ] && die "Option '-c' $contradicts1" "$contradicts2"
			process_args=
			unset iplists "${direction}_iplists"
			eval "${direction}_tcp_ports=skip ${direction}_udp_ports=skip ${direction}_icmp=skip ${direction}_geomode=disable"
		else
			process_args=1
		fi

		[ "$geomode" != "$geomode_prev" ] && { geomode_change=1; geomode_change_g=1; }

		eval "${direction}_geomode"='$geomode' "${direction}_geomode_change"='$geomode_change'

		[ -n "$geomode_change" ] && unset iplists "${direction}_iplists"

		[ "$direction" = outbound ] && ! is_whitelist_present && {
			[ "$lan_ips_arg" ] && die "Option '-l' can only be used in whitelist geoblocking mode."
			if [ -n "$lan_ips_ipv4$lan_ips_ipv6" ]; then
				echolog -warn "Inbound geoblocking mode is '$inbound_geomode', outbound geoblocking mode is '$outbound_geomode'. Removing LAN IPs from config." # TODO: do not remove?
				unset lan_ips_ipv4 lan_ips_ipv6
			fi
		}

		[ ! "$process_args" ] && continue

		# protocols
		[ "$proto_arg" ] && { setprotocols "${proto_arg%"$_nl"}" || die; }
		for opt_ch in icmp tcp_ports udp_ports; do
			eval "[ \"\$${direction}_${opt_ch}\" != \"\$${direction}_${opt_ch}_prev\" ] && ${direction}_proto_change=1" &&
				proto_change=1
		done

		# country codes
		if [ "$ccodes_arg" ] || { [ -z "$ccodes_arg" ] && [ -z "$iplists" ]; }; then
			pick_ccodes ccodes "$ccodes_arg"
		fi

		[ "$families_change" ] && [ ! "$ccodes" ] &&
			for list_id in $iplists; do
				add2list ccodes "${list_id%_*}"
			done

		# generate a list of requested iplists
		lists_req=
		for ccode in $ccodes; do
			for f in $families; do
				add2list lists_req "${ccode}_$f"
			done
		done

		[ -n "$lists_req" ] && {
			san_list_ids lists_req "$lists_req" "country" || die
		}

		eval "${direction}_lists_req"='$lists_req' \
			"${direction}_ccodes"='$ccodes'
	done

	san_str all_ccodes_arg "$inbound_ccodes_arg $outbound_ccodes_arg" || die

	[ "$excl_list_ids" ] && report_excluded_lists "$excl_list_ids"

	[ "$all_ccodes_arg" ] && [ ! "$inbound_lists_req$outbound_lists_req" ] &&
		die "No applicable IP list IDs could be generated for country codes '$all_ccodes_arg'."

	# ifaces and lan addresses
	unset lan_picked ifaces_picked ifaces_change

	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\" geomode_change=\"\$${direction}_geomode_change\""
		[ "$geomode" = disable ] && continue
		if [ ! "$ifaces" ] && [ ! "$ifaces_arg" ]; then
			[ "$nointeract" ] && die "Specify interfaces with -i <\"ifaces\"|auto|all>."
			printf '\n%s\n%s\n%s\n%s\n' "${blue}Does this machine have dedicated WAN network interface(s)?$n_c [y|n] or [a] to abort." \
				"For example, a router or a virtual private server may have it." \
				"A machine connected to a LAN behind a router is unlikely to have it." \
				"It is important to answer this question correctly."
			pick_opt "y|n|a"
			case "$REPLY" in
				a) die 130 ;;
				y) pick_ifaces ;;
				n) ifaces=all; is_whitelist_present && [ ! "$lan_picked" ] && { warn_lockout; pick_lan_ips; }
			esac
			ifaces_change=1
		fi

		if [ "$ifaces_arg" ] && [ ! "$ifaces_picked" ]; then
			ifaces=
			case "$ifaces_arg" in
				all) ifaces=all
					is_whitelist_present && [ ! "$lan_picked" ] &&
						{ [ "$first_setup" ] || [ "$geomode_change" ] || [ "$ifaces_change" ]; } &&
							{ warn_lockout; pick_lan_ips; } ;;
				auto) ifaces_arg=''; pick_ifaces -a ;;
				*) pick_ifaces
			esac
		fi

		[ ! "$ifaces" ] && ifaces=all

		get_difference "$ifaces" "$ifaces_prev" || ifaces_change=1

		if [ ! "$lan_picked" ] && [ ! "$lan_ips_ipv4$lan_ips_ipv6" ] && is_whitelist_present && [ "$geomode_change" ] &&
			[ "$ifaces" = all ]; then
			warn_lockout; pick_lan_ips
		fi
	done

	[ "$lan_ips_arg" ] &&  [ ! "$lan_picked" ] && pick_lan_ips

	[ "$geosource_change" ] && unset source_ips_ipv4 source_ips_ipv6

	# source IPs
	if [ "$source_ips_arg" ] || {
			[ "$outbound_geomode" != disable ] && [ ! "$source_ips_ipv4$source_ips_ipv6" ] && [ "$source_ips_policy" != pause ] &&
			{
				[ ! "$source_ips_policy" ] ||
				[ "$geosource_change" ] ||
				{ [ "$outbound_geomode_change" ] && [ "$outbound_geomode_prev" = disable ]; }
			}
		}
	then
		pick_source_ips
	fi

	for opt_ch in lan_ips_ipv4 lan_ips_ipv6 trusted_ipv4 trusted_ipv6 source_ips_ipv4 source_ips_ipv6; do
		eval "[ \"\$${opt_ch}\" != \"\$${opt_ch}_prev\" ]" && eval "${opt_ch%_ipv*}_change=1"
	done

	[ "$source_ips_policy_change" ] && [ "$source_ips_policy" = true ] && source_ips_change=1

	unset all_iplists all_iplists_prev all_add_iplists
	for direction in inbound outbound; do
		eval "lists_req=\"\$${direction}_lists_req\" iplists=\"\$${direction}_iplists\" iplists_prev=\"\$${direction}_iplists_prev\""
		: "${lists_req:="$iplists"}"
		iplists="$lists_req"

		! get_difference "$iplists_prev" "$iplists" && {
			lists_change=1
			eval "${direction}_lists_change=1"
		}
		eval "${direction}_iplists"='$iplists'

		add2list all_iplists_prev "$iplists_prev"
		add2list all_iplists "$iplists"
	done

	subtract_a_from_b "$all_iplists_prev" "$all_iplists" all_add_iplists

	debugprint "all_add_iplists: '$all_add_iplists'"
}

import_local_iplists() {
	# sanitization for local IP lists
	sed_san() {
		{ cat "$1"; printf '\n'; } | sed 's/\r/\n/g;s/\n$//' | sed "s/#.*//;s/^${blanks}//;s/${blanks}$//;/^$/d"
	}

	rm -rf "$STAGING_LOCAL_DIR"

	for iplist_type in allow block; do
		eval "file=\"\$local_${iplist_type}_arg\""
		case "$file" in
			'') continue ;;
			remove)
				printf '%s\n' "Removing local ${iplist_type}lists..."
				prev_local_file="$(find "${local_iplists_dir}" -name "local_${iplist_type}_*" -exec rm -f {} \; -exec printf '%s\n' {} \; 2>/dev/null)"
				[ -n "${prev_local_file}" ] && lists_change=1
				continue
		esac

		dir_mk -n "$STAGING_LOCAL_DIR"

		printf '\n%s' "Checking local ${iplist_type}list file '$file'... "
		[ -s "$file" ] || die "${_nl}IP list file '$file' is empty or doesn't exist."

		# detect family
		local_ips_found=
		for iplist_family in 4 6; do
			local_f_name="local_${iplist_type}_ipv${iplist_family}"
			perm_file="${local_iplists_dir}/${local_f_name}"
			staging_file="$STAGING_LOCAL_DIR/${local_f_name}"

			eval "ip_regex=\"\${ipv${iplist_family}_regex}\"
				mb_regex=\"\${maskbits_regex_ipv${iplist_family}}\""
			import_el_type=ip
			for el_type in net ip; do
				case "$el_type" in
					net) detect_regex="${ip_regex}/${mb_regex}";;
					ip) detect_regex="${ip_regex}"
				esac
				if sed_san "$file" | grep -E "^${detect_regex}$" > "$staging_file.$el_type"; then
					[ "$el_type" = net ] && import_el_type=net
					local_ips_found=1
					continue
				else
					rm -f "$staging_file.$el_type"
				fi
			done
			[ -n "$local_ips_found" ] && break
		done
		[ -n "$local_ips_found" ] || die "${_nl}$FAIL process IP list file '$file' or it does not contain newline-separated IP addresses."

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
			rm -rf "$STAGING_LOCAL_DIR"
			case "$iplist_family" in
				4) check_family=6 ;;
				6) check_family=4
			esac
			eval "iplist_regex=\"^\${ip_or_range_regex_ipv${check_family}}$\""
			if printf '%s\n' "$invalid_ip" | grep -E "$iplist_regex" 1>/dev/null; then
				die "${_nl}IP list file '$file' contains both IPv4 and IPv6 addresses - this is not supported."
			else
				die "${_nl}IP list file '$file' contains unexpected string '$invalid_ip'."
			fi
		}

		# report elements type
		printf '%s\n' "${blue}Detected IPv${iplist_family} with elements of type '$import_el_type'${n_c}."
		dir_mk "$local_iplists_dir"
		printf %s "Importing local IPv${iplist_family} ${iplist_type}list file... "
		{
			for el_type in net ip; do
				[ -f "$perm_file.$el_type" ] && {
					cat "$perm_file.$el_type"
					[ "$el_type" = net ] && touch "$STAGING_LOCAL_DIR/net"
				}
				[ -f "$staging_file.$el_type" ] && {
					cat "$staging_file.$el_type"
					[ "$el_type" = net ] && touch "$STAGING_LOCAL_DIR/net"
				}
			done
			:
		} | sort -u > "$staging_file" && [ -s "$staging_file" ] &&
		{
			for el_type in net ip; do
				if [ -f "$perm_file.$el_type" ] && compare_files "$perm_file.$el_type" "$staging_file"; then
					echolog "${_nl}Local ${iplist_type}list already contains all IP's in file '$file'."
					set +f
					rm -f "$staging_file"*
					set -f
					continue 2
				fi
			done
			:
		} || {
				FAIL
				rm -rf "$STAGING_LOCAL_DIR"
				die "$FAIL import the IP list into file '$staging_file'."
			}
		OK

		rm -f "$staging_file.net" "$staging_file.ip"
		if [ -f "$STAGING_LOCAL_DIR/net" ]; then
			mv "$staging_file" "$staging_file.net"
		else
			mv "$staging_file" "$staging_file.ip"
		fi
		rm -f "$STAGING_LOCAL_DIR/net"
		printf '%s\n' "${yellow}You can delete the file '$file' to free up space.${n_c}"
		lists_change=1
	done
	[ -n "$lists_change" ] || die 0
}

[ "$script_dir" = "$INSTALL_DIR" ] && _script="$i_script" || _script="$p_script"

:
