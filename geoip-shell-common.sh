#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2155,SC2018,SC2019,SC2012,SC2254,SC2086,SC2015,SC2046

# geoip-shell-common.sh

# Copyright: friendly bits
# github.com/friendly-bits

# Common functions and variables for geoip-shell suite


### Functions

setdebug() {
	export debugmode="${debugmode_args:-$debugmode}"
}

set_ascii() {
	set -- $(printf '\033[0;31m \033[0;32m \033[1;34m \033[1;33m \033[0;35m \033[0m \35 \t')
	export red="$1" green="$2" blue="$3" yellow="$4" purple="$5" n_c="$6" delim="$7" trim_IFS=" $8"
}

newifs() {
	eval "IFS_OLD_$2"='$IFS'; IFS="$1"
}

oldifs() {
	eval "IFS=\"\$IFS_OLD_$1\""
}

check_root() {
	[ "$root_ok" ] && return 0
	case "$(id -u)" in 0) export root_ok="1" ;; *)
		die "$ERR $me needs to be run as root."
	esac
}

extra_args() {
	[ "$*" ] && { usage; echolog "Error in arguments. First unexpected argument: '$1'." >&2; exit 1; }
}

checkutil() {
	command -v "$1" 1>/dev/null
}

unknownopt() {
	usage; die "Unknown option '-$OPTARG' or it requires an argument."
}

statustip() {
	printf '\n%s\n\n' "View geoip status with '${blue}${p_name} status${n_c}' (may require 'sudo')."
}

report_lists() {
	get_active_iplists verified_lists
	nl2sp verified_lists
	printf '\n%s\n' "Ip lists in the final $list_type: '${blue}$verified_lists${n_c}'."
}

unknownact() {
	specifyact="Specify action in the 1st argument!"
	case "$action" in
		"-h") usage; exit 0 ;;
		'') usage; die "$specifyact" ;;
		*) usage; die "$ERR Unknown action: '$action'." "$specifyact"
	esac
}

pick_opt() {
	opts=''
	newifs '|' gr
	for opt in $1; do
		opt_c="$(toupper "$opt")"
		opts="$opts$opt|$opt_c|"
	done
	opts="${opts%|}"
	oldifs gr
	while true; do
		printf %s "$1: "
		read -r REPLY
		eval "case \"$REPLY\" in
				$opts) return ;;
				*) printf '\n%s\n\n' \"Please enter $1\"
			esac"
	done
}

# counts elements in input
# fast but may work incorrectly if too many elements provided as input
# ignores empty elements
# 1 - input string
# 2 - delimiter
# 3 - var name for output
fast_el_cnt() {
	el_cnt_var="$3"
	newifs "$2" cnt
	set -- $1
	eval "$el_cnt_var"='$#'
	oldifs cnt
}

tolower() {
	printf %s "$@" | tr 'A-Z' 'a-z'
}

toupper() {
	printf %s "$@" | tr 'a-z' 'A-Z'
}

# calls another script and resets the config cache on exit
call_script() {
	[ "$1" = '-l' ] && { use_lock=1; shift; }
	script_to_call="$1"
	shift

	# call the daughter script, then reset $config_var to force re-read of the config file
	[ ! "$script_to_call" ] && { echolog -err "call_script: $ERR received empty string."; return 1 ; }

	[ "$use_lock" ] && rm_lock
	sh "$script_to_call" "$@"; call_rv=$?; export config_var=""
	debugexitmsg
	[ "$use_lock" ] && mk_lock
	return "$call_rv"
}

# sets some strings for debug and logging
init_geoscript(){
	: "${me:="${0##*/}"}"
	me_short="${me#"${p_name}-"}"
	me_short="${me_short%.sh}"
	me_short_cap="$(toupper "$me_short")"
	set -f
}

check_deps() {
	missing_deps=''
	for dep; do ! checkutil "$dep" && missing_deps="${missing_deps}'$dep', "; done
	[ "$missing_deps" ] && { echolog -err "$ERR missing dependencies: ${missing_deps%, }"; return 1; }
	:
}

get_json_lines() {
	sed -n -e /"$1"/\{:1 -e n\;/"$2"/q\;p\;b1 -e \}
}

# outputs args to stdout and writes them to syslog
# if one of the args is "-err" then redirect output to stderr
echolog() {
	unset msg_args __nl

	highlight="$blue"; msg_type=info
	for arg in "$@"; do
		case "$arg" in
			"-err" ) highlight="$yellow"; msg_type=err ;;
			'') ;;
			* ) msg_args="$msg_args$arg$delim"
		esac
	done

	# check for newline in the biginning of the line and strip it
	case "$msg_args" in "$_nl"* )
		__nl="$_nl"
		msg_args="${msg_args#"$_nl"}"
	esac

	newifs "$delim" ecl
	set -- $msg_args; oldifs ecl

	for arg in "$@"; do
		[ ! "$noecho" ] && {
			_msg="${__nl}$highlight$me_short$n_c: $arg"
			case "$msg_type" in
				info) printf '%s\n' "$_msg" ;;
				err) printf '%s\n' "$_msg" >&2
			esac
		}
		[ ! "$nolog" ] && logger -t "$me" -p user."$msg_type" "$(printf %s "$arg" | sed -e 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
	done
}

# prints a debug message
debugprint() {
	[ ! "$debugmode" ] && return
	__nl=
	dbg_args="$*"
	case "$dbg_args" in "\n"* )
		__nl="$_nl"
		dbg_args="${dbg_args#"\n"}"
	esac

	printf '%s\n' "${__nl}Debug: ${me_short}: $dbg_args" >&2
}

debugentermsg() {
	[ ! "$debugmode" ] || [ ! "$me_short_cap" ] && return 0
	printf %s "${yellow}Started *${me_short_cap}* with args: "
	newifs "$delim" dbn
	for arg in $_args; do printf %s "'$arg' "; done
	printf '%s\n' "${n_c}"
	oldifs dbn
}

debugexitmsg() {
	[ ! "$debugmode" ] || [ ! "$me_short_cap" ] && return 0
	printf '%s\n' "${yellow}Back to *$me_short_cap*...${n_c}"
}

die() {
	# if first arg is a number, assume it's the exit code
	case "$1" in
		''|*[!0-9]* ) die_rv="1" ;;
		* ) die_rv="$1"; shift
	esac

	unlock='' die_args=''
	for die_arg in "$@"; do
		case "$die_arg" in
			-nolog) nolog="1" ;;
			-u) rm_lock ;;
			'') ;;
			*) die_args="$die_args$die_arg$delim"
		esac
	done

	[ "$die_args" ] && {
		echo >&2
		newifs "$delim" die
		for arg in $die_args; do
			printf '%s\n' "$yellow$me_short$n_c: $arg" >&2
			[ ! "$nolog" ] && logger -t "$me" -p "user.err" "$(printf %s "$arg" | sed -e 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
		done
		oldifs die
	}
	exit "$die_rv"
}

# 1 - key
# 2 - var name for output
# 3 - optional path to config file
# 4 - optional '-nodie'
getconfig() {
	getconfig_failed() {
		eval "$outvar_gc"=''
		[ ! "$nodie" ] && die "$ERR $FAIL read value for '$key_conf' from file '$target_file'."
	}

	read_conf() {
		[ ! -s "$target_file" ] && { getconfig_failed; return 1; }
		conf="$(cat "$target_file")" || { getconfig_failed; return 1; }
	}

	key_conf="$1"
	outvar_gc="$2"
	target_file="${3:-$conf_file}"
	nodie=''
	[ "$4" = "-nodie" ] && nodie=1
	[ ! "$key_conf" ] || [ ! "$target_file" ] && { getconfig_failed; return 1; }

	# re-use existing $config_var if possible
	case "$target_file" in
		"$conf_file" )
			case "$config_var" in
				'') read_conf || { getconfig_failed; return 1; }
					export config_var="$conf" ;;
				*) conf="$config_var"
			esac ;;
		*) read_conf || { getconfig_failed; return 1; }
	esac

	get_matching_line "$conf" "" "$key_conf=" "*" "conf_line" || { getconfig_failed; return 2; }
	eval "$2"='${conf_line#"${key_conf}"=}'
	:
}

# 1 - int
# 2 - (optional) "bytes"
num2human() {
	i=${1:-0} s=0
	for S in B KiB MiB TiB PiB; do
		[ $((i > 1024 && s < 4)) = 0 ] && break
		d=$i
		i=$((i / 1024))
		s=$((s + 1))
	done
	[ "$2" != bytes ] && { S=${S%B}; S=${S%i}; }
	d=$((d % 1024 * 100 / 1024))
	case $d in
		0) printf "%s%s\n" "$i" "$S"; return ;;
		[1-9]) f="02" ;;
		*0) d=${d%0}; f="01"
	esac
	printf "%s.%${f}d%s\n" "$i" "$d" "$S"
}

# 1 - input
# 2 - leading '*' wildcard (if required)
# 3 - filter string
# 4 - trailing '*' wildcard (if required)
# 5 - optional var name for output
# outputs the 1st match
get_matching_line() {
	newifs "$_nl" gml
	_rv=1; _res=''
	for _line in $1; do
		case "$_line" in $2"$3"$4) _res="$_line"; _rv=0; break; esac
	done
	[ "$5" ] && eval "$5"='$_res'
	oldifs gml
	return $_rv
}

# utilizes getconfig() but intended for reading status from status files
# 1 - status file
# 2 - key
# 3 - var name for output
getstatus() {
	target_file="$1"
	[ ! "$target_file" ] && die "$ERR getstatus: target file not specified!" ||
		getconfig "$2" "status_value" "$target_file" "-nodie"; rv_gs=$?
	eval "$3"='$status_value'
	return $rv_gs
}

# Accepts key=value pairs and writes them to (or replaces in) config file specified in global variable $conf_file
# if one of the value pairs is "target_file=[file]" then writes to $file instead
setconfig() {
	unset args_lines args_target_file keys_test_str newconfig nodie
	IFS_OLD_sc="$IFS"
	for argument_conf in "$@"; do
		# separate by newline and process each line (support for multi-line args)
		IFS="$_nl"
		for line in $argument_conf; do
			case "$line" in *'='* )
				key_conf="${line%%=*}"
		   		value_conf="${line#*=}"
				case "$key_conf" in
					'' ) ;;
					target_file ) args_target_file="$value_conf" ;;
					* ) args_lines="${args_lines}${key_conf}=$value_conf$_nl"
						keys_test_str="${keys_test_str}\"${key_conf}=\"*|"
				esac
			esac
		done
	done

	keys_test_str="${keys_test_str%|}"
	target_file="${args_target_file:-$conf_file}"

	[ ! "$target_file" ] && { sc_failed "'\$target_file' variable is not set."; return 1; }

	[ -f "$target_file" ] && { oldconfig="$(cat "$target_file")" || { sc_failed "$FAIL read '$target_file'."; return 1; }; }
	# join old and new config
	for config_line in $oldconfig; do
		eval "case \"$config_line\" in
				''|$keys_test_str ) ;;
				* ) newconfig=\"$newconfig$config_line$_nl\"
			esac"
	done
	printf %s "$newconfig$args_lines" > "$target_file" || { sc_failed "$FAIL write to '$target_file'"; return 1; }
	oldifs sc
	export config_var=''
	:
}

sc_failed() {
	echolog -err "setconfig: $ERR $1"
	[ ! "$nodie" ] && die
}

# utilizes setconfig() for writing to status files
# 1 - path to the status file
# extra args are passed as is to setconfig
setstatus() {
	target_file="$1"
	shift 1
	[ ! "$target_file" ] && { echolog -err "setstatus: $ERR target file not specified!"; [ ! "$nodie" ] && die; return 1; }
	[ ! -d "${target_file%/*}" ] && mkdir -p "${target_file%/*}"
	[ ! -f "$target_file" ] && touch "$target_file"
	setconfig "target_file=$target_file" "$@"
}

# 1 - var name
# (optional) 2 - string
trimsp() {
	trim_var="$1"
	newifs "$trim_IFS" trim
	case "$2" in '') eval "set -- \$$1" ;; *) set -- $2; esac
	eval "$trim_var"='$*'
	oldifs trim
}

# 0 - optional -s to delimit by ' '
# 1 - var name for output
# 2 - optional input string (otherwise uses prev value)
# 3 - optional input delimiter
# 4 - optional output delimiter
san_str() {
	[ "$1" = '-s' ] && { _del=' '; shift; } || _del="$_nl"
	[ "$2" ] && inp_str="$2" || eval "inp_str=\"\$$1\""

	_sid="${3:-"$_del"}"
	_sod="${4:-"$_del"}"
	_words=
	newifs "$_sid" san
	for _w in $inp_str; do
		case "$_words" in "$_w"|"$_w$_sod"*|*"$_sod$_w"|*"$_sod$_w$_sod"*) ;; *) _words="$_words$_w$_sod"; esac
	done
	eval "$1"='${_words%$_sod}'
	oldifs san
}

get_intersection() {
	[ ! "$1" ] || [ ! "$2" ] && { eval "$3"=''; return 1; }
	_fs="${4:-"$_nl"}"
	_intersect=''
	for e in $2; do
		case "$1" in "$e"|"$e$_fs"*|*"$_fs$e"|*"$_fs$e$_fs"*)
			case "$_intersect" in
				"$e"|"$e$_fs"*|*"$_fs$e"|*"$_fs$e$_fs"*) ;;
				*) _intersect="$_intersect$e$_fs"
			esac
		esac
	done
	eval "$3"='${_intersect%$_fs}'
}

get_difference() {
	case "$1" in
		'') case "$2" in '') eval "$3"=''; return 1 ;; *) eval "$3"='$2'; return 0; esac ;;
		*) case "$2" in '') eval "$3"='$1'; return 0; esac
	esac
	_fs_gd="${4:-"$_nl"}"
	subtract_a_from_b "$1" "$2" "_diff1"
	subtract_a_from_b "$2" "$1" "_diff2"
	_diff="$_diff1$_diff2"
	eval "$3"='${_diff%$_fs_gd}'
}

subtract_a_from_b() {
	case "$2" in '') eval "$3"=''; return 0; esac
	case "$1" in '') eval "$3"='$2'; return 0; esac
	_fs_su="${4:-"$_nl"}"
	_diff=''
	for e in $2; do
		case "$1" in "$e"|"$e$_fs_su"*|*"$_fs_su$e"|*"$_fs_su$e$_fs_su"*) ;; *)
			case "$_diff" in
				"$e"|"$e$_fs_su"*|*"$_fs_su$e"|*"$_fs_su$e$_fs_su"*) ;;
				*) _diff="$_diff$e$_fs_su"
			esac
		esac
	done
	eval "$3"='${_diff%$_fs_su}'
}

sp2nl() {
	var_stn="$1"
	[ $# = 2 ] && _inp="$2" || eval "_inp=\"\$$1\""
	newifs "$trim_IFS" stn
	set -- $_inp
	IFS="$_nl"
	eval "$var_stn"='$*'
	oldifs stn
}

nl2sp() {
	var_nts="$1"
	[ $# = 2 ] && _inp="$2" || eval "_inp=\"\$$1\""
	newifs "$_nl" nts
	set -- $_inp
	IFS=' '
	eval "$var_nts"='$*'
	oldifs nts
}

# trims extra whitespaces, discards empty args
# output string is delimited with $delim
san_args() {
	_args=''
	for arg in "$@"; do
		trimsp arg
		[ "$arg" ] && _args="$_args$arg$delim"
	done
}

# checks whether current ipsets and iptables rules match ones in the config file
check_lists_coherence() {
	debugprint "Verifying ip lists coherence..."

	# check for a valid list type
	case "$list_type" in whitelist|blacklist) ;; *) die "$ERR Unexpected geoip mode '$list_type'!"; esac

	unset unexp_lists missing_lists
	getconfig "Lists" config_lists
	sp2nl config_lists
	force_read_geotable=1
	get_active_iplists active_lists || {
		nl2sp ips_l_str "$ipset_lists"; nl2sp ipr_l_str "$iprules_lists"
		echolog -err "$WARN ip sets ($ips_l_str) differ from iprules lists ($ipr_l_str)."
		return 1
	}
	force_read_geotable=

	get_difference "$active_lists" "$config_lists" lists_difference
	case "$lists_difference" in
		'') debugprint "Successfully verified ip lists coherence."; return 0 ;;
		*) nl2sp active_l_str "$active_lists"; nl2sp config_l_str "$config_lists"
			echolog -err "$_nl$FAIL verify ip lists coherence." "firewall ip lists: '$active_l_str'" "config ip lists: '$config_l_str'"
			subtract_a_from_b "$config_lists" "$active_lists" unexp_lists; nl2sp unexpected_lists "$unexp_lists"
			subtract_a_from_b "$active_lists" "$config_lists" missing_lists; nl2sp missing_lists
			return 1
	esac
}

# validates country code in $1 against cca2.list
# must be in upper case
# optional $2 may contain path to cca2.list
# returns 0 if validation successful, 2 if not, 1 if cca2 list is empty
validate_ccode() {
	cca2_path="${2:-"$script_dir/cca2.list"}"
	[ -s "$cca2_path" ] && export ccode_list="${ccode_list:-"$(cat "$cca2_path")"}"
	case "$ccode_list" in
		'') printf '%s\n' "$ERR \$ccode_list variable is empty. Perhaps cca2.list is missing?" >&2; return 1 ;;
		*" $1 "*) return 0 ;;
		*) return 2
	esac
}

# detects all network interfaces known to the kernel, except the loopback interface
# returns 1 if nothing detected
detect_ifaces() {
	[ -r "/proc/net/dev" ] && sed -n '/^[[:space:]]*[^[:space:]]*:/{s/^[[:space:]]*//;s/:.*//p}' < /proc/net/dev | grep -vx 'lo'
}

# format: '-p [tcp|udp]:[allow|block]:[ports]'
setports() {
	invalid_str() { usage; echolog -err "Invalid string '$1'."; }
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
		[ "$ranges_cnt" = 0 ] && { usage; echolog -err "$ERR no ports specified for protocol $_proto."; return 1; }
		_ports="${_ports%,}"

		[ "$_fw_backend" = ipt ] && {
			dport="dport"
			[ "$ranges_cnt" -gt 1 ] && { mp="-m multiport"; dport="dports"; }
			dport="--$dport $_ports"
		}
		:
	}

	_lines="$(tolower "$1")"
	newifs "$_nl" sp
	for _line in $_lines; do
		case "$_fw_backend" in
			nft) _neg='!=' p_delim='-' _all="meta l4proto $_proto" ;;
			ipt) _neg='!' p_delim=':' _all=
		esac
		unset ranges _ports neg mp skip
		trimsp _line
		check_edge_chars "$_line" ":" || return 1
		IFS=":"
		set -- $_line
		[ $# != 3 ] && { usage; echolog -err "Invalid syntax '$_line'"; return 1; }
		_proto="$1"
		proto_act="$2"
		_ranges="$3"
		trimsp _ranges
		trimsp _proto
		trimsp proto_act
		case "$proto_act" in
			allow) neg='' ;;
			block) neg="$_neg" ;;
			*) { usage; echolog -err "$ERR expected 'allow' or 'block' instead of '$proto_act'"; return 1; }
		esac
		# check for valid protocol
		case $_proto in
			udp|tcp) case "$reg_proto" in *"$_proto"*) usage; echolog -err "$ERR can't add protocol '$_proto' twice"; return 1; esac
				reg_proto="$reg_proto$_proto " ;;
			*) usage; echolog -err "Unsupported protocol '$_proto'."; return 1
		esac

		if [ "$_ranges" = all ]; then
			[ "$neg" ] && ports_line=skip || ports_line="$_all"
		else
			parse_ports || return 1
			case "$_fw_backend" in
				nft) ports_line="$_proto dport $neg { $_ports }" ;;
				ipt) ports_line="$mp $neg $dport"
			esac
		fi
		trimsp ports_line
		ports_conf="$ports_conf$_proto=$ports_line$_nl"
	done
	oldifs sp
	setconfig "$ports_conf"
}

check_cron() {
	[ "$cron_rv" ] && return "$cron_rv"
	# check if cron service is enabled
	unset cron_rv cron_reboot
	case "$initsys" in
		systemd ) (systemctl is-enabled cron.service || systemctl is-enabled crond.service) 1>/dev/null 2>/dev/null; cron_rv=$?
	esac
	# check for cron or crond in running processes
	[ "$cron_rv" != 0 ] && if ! pidof cron 1>/dev/null && ! pidof crond 1>/dev/null; then cron_rv=1; else cron_rv=0; fi
	export cron_rv
	cron_cmd="$(command -v crond || command -v cron)"
	[ "$cron_cmd" ] && case "$(ls -l "$cron_cmd")" in *busybox*) ;; *) export cron_reboot=1; esac

	return "$cron_rv"
}

check_cron_compat() {
	unset cr_p1 cr_p2 no_cr_persist
	[ ! "$_OWRTFW" ] && { cr_p1="s '-n'"; cr_p2="persistence and "; }
	[ "$no_persist" ] || [ "$_OWRTFW" ] && no_cr_persist=1
	if [ "$schedule" != "disable" ] || [ ! "$no_cr_persist" ] ; then
		# check cron service
		check_cron || die "$ERR cron is not running." "Enable the cron service before using this script." \
				"Or install $p_name with option$cr_p1 '-s disable' which will disable ${cr_p2}autoupdates."
		[ ! "$cron_reboot" ] && [ ! "$no_persist" ] && [ ! "$_OWRTFW" ] && die "$ERR cron-based persistence doesn't work with Busybox cron." \
			"If you want to install without persistence support, install with option '-n'"
	fi
}

OK() { echo "Ok."; }
FAIL() { echo "Failed."; }

mk_lock() { check_lock; touch "$lock_file" || die "$ERR failed to set lock '$lock_file'"; nodie=1; }

rm_lock() {
	[ -f "$lock_file" ] && { rm -f "$lock_file" 2>/dev/null || die "$ERR failed to remove lock '$lock_file'"; }
	nodie=
}

check_lock() {
	[ -f "$lock_file" ] &&
		die "Lock file $lock_file indicates that $p_name is doing something in the background, refusing to open another instance."
}

kill_geo_pids() {
	for i in 1 2; do
		for script in run fetch apply cronsetup backup; do
			_pids="$(pgrep -fa "geoip-shell-$script.sh" | grep -v pgrep | grep -Eo "^[0-9]+")"
			for _pid in $_pids; do kill "$_pid"; done
		done
	done
}

export lock_file="/tmp/$p_name-run.lock"
export install_dir="/usr/bin" p_script="$script_dir/${p_name}"
export i_script="$install_dir/${p_name}"
export lib_dir="$script_dir/lib"
export _lib="$lib_dir/$p_name-lib"

init_geoscript

[ ! "$geotag" ] && {
	export geotag="$p_name" LC_ALL=C conf_dir="/etc/$p_name" _nl='
'
	export geochain="$(toupper "$geotag")" conf_file="$conf_dir/$p_name.conf" default_IFS=" 	$_nl"
	set_ascii
	export WARN="${red}Warning${n_c}:" ERR="${red}Error${n_c}:" FAIL="${red}Failed${n_c} to" IFS="$default_IFS"

	check_deps tr cut sort wc awk sed grep logger pgrep || die
	{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
	{
		nolog=1 check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore 2>/dev/null &&
			{ check_deps ipset || die; export _fw_backend=ipt; }
	} || die "$ERR neither nftables nor iptables found."
}

:
