#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2155,SC2018,SC2019,SC2012,SC2254,SC2086,SC2015,SC2046,SC1090,SC2006,SC2010,SC2181,SC3040

# geoip-shell-common.sh

# Copyright: friendly bits
# github.com/friendly-bits

# Common functions and variables for geoip-shell suite


### Functions

setdebug() {
	export debugmode="${debugmode_args:-$debugmode}"
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
	[ ! "$debugmode" ] || [ ! "$me_short" ] && return 0
	{
		printf %s "${yellow}Started *"; toupper "$me_short"; printf %s "* with args: "
		newifs "$delim" dbn
		for arg in $_args; do printf %s "'$arg' "; done
		printf '%s\n' "${n_c}"
	} >&2
	oldifs dbn
}

debugexitmsg() {
	[ ! "$debugmode" ] || [ ! "$me_short" ] && return 0
	{ printf %s "${yellow}Back to *"; toupper "$me_short"; printf '%s\n' "*...${n_c}"; } >&2
}

# sets some variables for colors and ascii delimiter
set_ascii() {
	set -- $(printf '\033[0;31m \033[0;32m \033[1;34m \033[1;33m \033[0;35m \033[0m \35 \xE2\x9C\x94 \xE2\x9C\x98 \t')
	export red="$1" green="$2" blue="$3" yellow="$4" purple="$5" n_c="$6" delim="$7" _V="$8" _X="$9" trim_IFS=" ${10}"
	case "$curr_shell" in *yash*) _V="[Ok]"; _X="[!]"; esac
	_V="$green$_V$n_c" _X="$red$_X$n_c"
}

# set IFS to $1 while saving its previous value to variable tagged $2
newifs() {
	eval "IFS_OLD_$2"='$IFS'; IFS="$1"
}

# restore IFS value from variable tagged $1
oldifs() {
	eval "IFS=\"\$IFS_OLD_$1\""
}

check_root() {
	[ "$root_ok" ] && return 0
	case "$(id -u)" in 0) export root_ok="1" ;; *)
		die "$me needs to be run as root."
	esac
}

extra_args() {
	[ "$*" ] && { usage; echolog -err "Invalid arguments. First unexpected argument: '$1'."; die; }
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
		*) usage; die "Unknown action: '$action'." "$specifyact"
	esac
}

# asks the user to pick an option
# $1 - input in the format 'a|b|c'
# output via the $REPLY var
pick_opt() {
	_opts="$1|$(toupper "$1")"
	while true; do
		printf %s "$1: "
		read -r REPLY
		eval "case \"$REPLY\" in
				$_opts) return ;;
				*) printf '\n%s\n\n' \"Please enter $1\"
			esac"
	done
}

# 1 - key
# 2 - value to add
add2config_entry() {
	getconfig "$1" a2c_e
	is_included "$2" "$a2c_e" && return 0
	add2list a2c_e "$2"
	setconfig "$1" "$a2c_e"
}

# checks if $1 is alphanumeric
# optional '-n' in $2 silences error messages
is_alphanum() {
	case "$1" in *[!A-Za-z0-9_]* )
		[ "$2" != '-n' ] && echolog -err "Invalid string '$1'. Use alphanumerics and underlines."
		return 1
	esac
	:
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

	: "${use_shell:=$curr_shell}"
	: "${use_shell:=sh}"

	# call the daughter script, then reset $config_var to force re-read of the config file
	[ ! "$script_to_call" ] && { echolog -err "call_script: $ERR received empty string."; return 1 ; }

	[ "$use_lock" ] && rm_lock
	$use_shell "$script_to_call" "$@"; call_rv=$?; export config_var=
	debugexitmsg
	[ "$use_lock" ] && mk_lock -f
	use_lock=
	return "$call_rv"
}

check_deps() {
	missing_deps=
	for dep; do ! checkutil "$dep" && missing_deps="${missing_deps}'$dep', "; done
	[ "$missing_deps" ] && { echolog -err "missing dependencies: ${missing_deps%, }"; return 1; }
	:
}

get_json_lines() {
	sed -n -e /"$1"/\{:1 -e n\;/"$2"/q\;p\;b1 -e \}
}

# outputs args to stdout and writes them to syslog
# if one of the args is '-err' or '-warn' then redirect output to stderr
echolog() {
	unset msg_args __nl msg_prefix

	highlight="$blue"; err_l=info
	for arg in "$@"; do
		case "$arg" in
			"-err" ) highlight="$red"; err_l=err; msg_prefix="$ERR" ;;
			"-warn" ) highlight="$yellow"; err_l=warn; msg_prefix="$WARN" ;;
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
			_msg="${__nl}$highlight$me_short$n_c: $msg_prefix $arg"
			case "$err_l" in
				info) printf '%s\n' "$_msg" ;;
				err|warn) printf '%s\n' "$_msg" >&2
			esac
		}
		[ ! "$nolog" ] && logger -t "$me" -p user."$err_l" "$(printf %s " $msg_prefix $arg" | sed -e 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
	done
}

die() {
	# if first arg is a number, assume it's the exit code
	case "$1" in
		''|*[!0-9]* ) die_rv="1" ;;
		* ) die_rv="$1"; shift
	esac

	unset msg_type die_args
	case "$die_rv" in
		0) _err_l=notice ;;
		254) _err_l=warn; msg_type="-warn" ;;
		*) _err_l=err; msg_type="-err"
	esac

	for die_arg in "$@"; do
		case "$die_arg" in
			-nolog) nolog="1" ;;
			'') ;;
			*) die_args="$die_args$die_arg$delim"
		esac
	done

	[ "$die_unlock" ] && rm_lock

	[ "$die_args" ] && {
		newifs "$delim" die
		for arg in $die_args; do
			echolog "$msg_type" "$arg"
		done
		oldifs die
	}
	exit "$die_rv"
}

# 1 - key
# 2 - var name for output
# 3 - optional path to config file
getconfig() {
	getconfig_failed() {
		eval "$outvar_gc="
		[ ! "$nodie" ] && die "$FAIL read value for '$key_conf' from file '$target_file'."
	}

	read_conf() {
		[ ! -s "$target_file" ] && { getconfig_failed; return 1; }
		conf="$(cat "$target_file")" || { getconfig_failed; return 1; }
	}

	key_conf="$1"
	outvar_gc="$2"
	target_file="${3:-$conf_file}"
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

# converts unsigned integer to either [x|xK|xM|xT|xQ] or [xB|xKiB|xMiB|xTiB|xPiB], depending on $2
# if result is not an integer, outputs up to 2 digits after decimal point
# 1 - int
# 2 - (optional) "bytes"
num2human() {
	i=${1:-0} s=0 d=0
	case "$2" in bytes) m=1024 ;; '') m=1000 ;; *) return 1; esac
	case "$i" in *[!0-9]*) echolog -err "num2human: Invalid unsigned integer '$i'."; return 1; esac
	for S in B KiB MiB TiB PiB; do
		[ $((i > m && s < 4)) = 0 ] && break
		d=$i
		i=$((i/m))
		s=$((s+1))
	done
	[ -z "$2" ] && { S=${S%B}; S=${S%i}; [ "$S" = P ] && S=Q; }
	d=$((d % m * 100 / m))
	case $d in
		0) printf "%s%s\n" "$i" "$S"; return ;;
		[1-9]) f="02" ;;
		*0) d=${d%0}; f="01"
	esac
	printf "%s.%${f}d%s\n" "$i" "$d" "$S"
}

# primitive alternative to grep
# 1 - input
# 2 - leading '*' wildcard (if required, otherwise use empty string)
# 3 - filter string
# 4 - trailing '*' wildcard (if required, otherwise use empty string)
# 5 - optional var name for output
# outputs the 1st match
# return status is 0 for match, 1 for no match
get_matching_line() {
	newifs "$_nl" gml
	_rv=1; _res=
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
	[ ! "$target_file" ] && die "getstatus: target file not specified!" ||
		nodie=1 getconfig "$2" "status_value" "$target_file"; rv_gs=$?
	eval "$3"='$status_value'
	return $rv_gs
}

# Accepts key=value pairs and writes them to (or replaces in) config file specified in global variable $conf_file
# if one of the value pairs is "target_file=[file]" then writes to $file instead
setconfig() {
	unset args_lines args_target_file keys_test_str newconfig
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
	keys_test_str="${keys_test_str%\|}"
	target_file="${args_target_file:-$conf_file}"

	[ ! "$target_file" ] && { sc_failed "'\$target_file' variable is not set."; return 1; }

	[ -f "$target_file" ] && { oldconfig="$(cat "$target_file")" || { sc_failed "$FAIL read '$target_file'."; return 1; }; }
	# join old and new config
	for config_line in $oldconfig; do
		eval "case \"$config_line\" in
				''|$keys_test_str) ;;
				*) newconfig=\"$newconfig$config_line$_nl\"
			esac"
	done
	printf %s "$newconfig$args_lines" > "$target_file" || { sc_failed "$FAIL write to '$target_file'"; return 1; }
	oldifs sc
	export config_var=
	:
}

sc_failed() {
	echolog -err "setconfig: $1"
	[ ! "$nodie" ] && die
}

# utilizes setconfig() for writing to status files
# 1 - path to the status file
# extra args are passed as is to setconfig
setstatus() {
	target_file="$1"
	shift 1
	[ ! "$target_file" ] && { echolog -err "setstatus: target file not specified!"; [ ! "$nodie" ] && die; return 1; }
	[ ! -d "${target_file%/*}" ] && mkdir -p "${target_file%/*}"
	[ ! -f "$target_file" ] && touch "$target_file"
	setconfig "target_file=$target_file" "$@"
}

# trims leading, trailing and extra in-between spaces
# 1 - output var name
# input via $2, if unspecified then from previous value of $1
trimsp() {
	trim_var="$1"
	newifs "$trim_IFS" trim
	case "$#" in 1) eval "set -- \$$1" ;; *) set -- $2; esac
	eval "$trim_var"='$*'
	oldifs trim
}

# checks if string $1 is included in list $2, with optional field separator $3 (otherwise uses whitespace)
# result via return status
is_included() {
	_fs_ii="${3:- }"
	case "$2" in "$1"|"$1$_fs_ii"*|*"$_fs_ii$1"|*"$_fs_ii$1$_fs_ii"*) return 0 ;; *) return 1; esac
}

# adds a string to a list if it's not included yet
# 1 - name of var which contains the list
# 2 - new value
# 3 - optional delimiter (otherwise uses whitespace)
# returns 2 if value was already included, 1 if bad var name, 0 otherwise
add2list() {
	is_alphanum "$1" || return 1
	a2l_fs="${3:- }"
	eval "_curr_list=\"\$$1\""
	is_included "$2" "$_curr_list" "$a2l_fs" && return 2
	eval "$1=\"\${$1}$a2l_fs$2\"; $1=\"\${$1#$a2l_fs}\""
	return 0
}

# removes duplicate words, removes leading and trailing delimiter, trims in-between extra delimiter characters
# by default expects a newline-delimited list
# (1) - optional -s to delimit both input and output by whitespace
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
		add2list _words "$_w" "$_sod"
	done
	eval "$1"='$_words'
	oldifs san
}

# get intersection of lists $1 and $2, with optional field separator $4 (otherwise uses newline)
# output via variable with name $3
get_intersection() {
	[ ! "$1" ] || [ ! "$2" ] && { unset "$3"; return 1; }
	_fs_gi="${4:-"$_nl"}"
	_isect=
	newifs "$_fs_gi" _fs_gi
	for e in $2; do
		is_included "$e" "$1" "$_fs_gi" && add2list _isect "$e" "$_fs_gi"
	done
	eval "$3"='$_isect'
	oldifs _fs_gi
}

# get difference between lists $1 and $2, with optional field separator $4 (otherwise uses newline)
# output via variable with name $3
get_difference() {
	case "$1" in
		'') case "$2" in '') unset "$3"; return 1 ;; *) eval "$3"='$2'; return 0; esac ;;
		*) case "$2" in '') eval "$3"='$1'; return 0; esac
	esac
	_fs_gd="${4:-"$_nl"}"
	subtract_a_from_b "$1" "$2" "_diff1" "$_fs_gd"
	subtract_a_from_b "$2" "$1" "_diff2" "$_fs_gd"
	_diff="$_diff1$_fs_gd$_diff2"
	_diff="${_diff#"$_fs_gd"}"
	eval "$3"='${_diff%$_fs_gd}'
}

# subtract list $1 from list $2, with optional field separator $4 (otherwise uses newline)
# output via variable with name $3
# returns status 0 if lists match, 1 if not
subtract_a_from_b() {
	case "$2" in '') unset "$3"; return 0; esac
	case "$1" in '') eval "$3"='$2'; [ ! "$2" ]; return; esac
	_fs_su="${4:-"$_nl"}"
	rv_su=0 _subt=
	newifs "$_fs_su" _fs_su
	for e in $2; do
		is_included "$e" "$1" "$_fs_su" || { add2list _subt "$e" "$_fs_su"; rv_su=1; }
	done
	eval "$3"='$_subt'
	oldifs _fs_su
	return $rv_su
}

# converts whitespace-separated list to newline-separated list
# 1 - var name for output
# input via $2, if not specified then uses current value of $1
sp2nl() {
	var_stn="$1"
	[ $# = 2 ] && _inp="$2" || eval "_inp=\"\$$1\""
	newifs "$trim_IFS" stn
	set -- $_inp
	IFS="$_nl"
	eval "$var_stn"='$*'
	oldifs stn
}

# converts newline-separated list to whitespace-separated list
# 1 - var name for output
# input via $2, if not specified then uses current value of $1
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
# output via variable '_args'
# output string is delimited with $delim
san_args() {
	_args=
	for arg in "$@"; do
		trimsp arg
		[ "$arg" ] && _args="$_args$arg$delim"
	done
}

# restores the nolog var prev value
r_no_l() { nolog="$_no_l"; }

# checks whether current ipsets and iptables rules match ones in the config file
check_lists_coherence() {
	_no_l="$nolog"
	[ "$1" = '-n' ] && nolog=1
	debugprint "Verifying ip lists coherence..."

	# check for a valid list type
	case "$list_type" in whitelist|blacklist) ;; *) die "Unexpected geoip mode '$list_type'!"; esac

	unset unexp_lists missing_lists
	getconfig "Lists" conf_lists
	sp2nl conf_lists
	force_read_geotable=1
	get_active_iplists active_lists || {
		nl2sp ips_l_str "$ipset_lists"; nl2sp ipr_l_str "$iprules_lists"
		echolog -warn "ip sets ($ips_l_str) differ from iprules lists ($ipr_l_str)."
		r_no_l
		return 1
	}
	force_read_geotable=

	get_difference "$active_lists" "$conf_lists" lists_difference
	case "$lists_difference" in
		'') debugprint "Successfully verified ip lists coherence."; r_no_l; return 0 ;;
		*) nl2sp active_l_str "$active_lists"; nl2sp config_l_str "$conf_lists"
			echolog -err "$_nl$FAIL verify ip lists coherence." "firewall ip lists: '$active_l_str'" "config ip lists: '$config_l_str'"
			subtract_a_from_b "$conf_lists" "$active_lists" unexp_lists; nl2sp unexpected_lists "$unexp_lists"
			subtract_a_from_b "$active_lists" "$conf_lists" missing_lists; nl2sp missing_lists
			r_no_l
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
		'') echolog -err "\$ccode_list variable is empty. Perhaps cca2.list is missing?"; return 1 ;;
		*" $1 "*) return 0 ;;
		*) return 2
	esac
}

# detects all network interfaces known to the kernel, except the loopback interface
# returns 1 if nothing detected
detect_ifaces() {
	[ -r "/proc/net/dev" ] && sed -n '/^[[:space:]]*[^[:space:]]*:/{s/^[[:space:]]*//;s/:.*//p}' < /proc/net/dev | grep -vx 'lo'
}

# format: '[tcp|udp]:[allow|block]:[ports]'
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
		[ "$ranges_cnt" = 0 ] && { usage; echolog -err "no ports specified for protocol $_proto."; return 1; }
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
			*) { usage; echolog -err "expected 'allow' or 'block' instead of '$proto_act'"; return 1; }
		esac
		# check for valid protocol
		case $_proto in
			udp|tcp) case "$reg_proto" in *"$_proto"*) usage; echolog -err "can't add protocol '$_proto' twice"; return 1; esac
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
	cron_rv=1 cron_reboot=
	[ "$initsys" = systemd ] &&
			{ systemctl is-enabled cron.service || systemctl is-enabled crond.service; } 1>/dev/null 2>/dev/null && cron_rv=0
	# check for cron or crond in running processes
	[ "$cron_rv" != 0 ] && { pidof cron || pidof crond; } 1>/dev/null && cron_rv=0

	cron_cmd="$(command -v crond || command -v cron)" || cron_rv=1
	export cron_rv
	# check for busybox cron
	[ "$cron_cmd" ] && case "$(ls -l "$cron_cmd")" in *busybox*) ;; *) export cron_reboot=1; esac

	return "$cron_rv"
}

check_cron_compat() {
	unset cr_p1 cr_p2 no_cr_persist
	[ ! "$_OWRTFW" ] && { cr_p1="s '-n'"; cr_p2="persistence and "; }
	[ "$no_persist" ] || [ "$_OWRTFW" ] && no_cr_persist=1
	if [ "$schedule" != "disable" ] || [ ! "$no_cr_persist" ] ; then
		# check cron service
		check_cron || die "cron is not running." "Enable and start the cron service before using this script." \
				"Or install $p_name with option$cr_p1 '-s disable' which will disable ${cr_p2}autoupdates."
		[ ! "$cron_reboot" ] && [ ! "$no_persist" ] && [ ! "$_OWRTFW" ] &&
			die "cron-based persistence doesn't work with Busybox cron." \
			"If you want to install without persistence support, install with option '-n'"
	fi
}

OK() { echo "Ok."; }
FAIL() { echo "Failed."; }

mk_lock() {
	[ "$1" != '-f' ] && check_lock
	touch "$lock_file" || die "$FAIL set lock '$lock_file'"
	nodie=1
	die_unlock=1
}

rm_lock() {
	[ -f "$lock_file" ] && { rm -f "$lock_file" 2>/dev/null; unset nodie die_unlock; }
}

check_lock() {
	[ -f "$lock_file" ] && die 254 "Lock file $lock_file exists, which means $p_name is doing something in the background."
}

kill_geo_pids() {
	for i in 1 2; do
		for script in run fetch apply cronsetup backup; do
			_pids="$(pgrep -fa "geoip-shell-$script.sh" | grep -v pgrep | grep -Eo "^[0-9]+")"
			for _pid in $_pids; do kill "$_pid"; done
		done
	done
}

export install_dir="/usr/bin" conf_dir="/etc/$p_name" iplist_dir="/tmp" p_script="$script_dir/${p_name}" _nl='
'
export LC_ALL=C POSIXLY_CORRECT=yes default_IFS="	 $_nl"
export lock_file="/tmp/$p_name.lock" conf_file="$conf_dir/$p_name.conf" i_script="$install_dir/${p_name}"

valid_sources="ripe ipdeny"
valid_families="ipv4 ipv6"

# set some vars for debug and logging
: "${me:="${0##*/}"}"
me_short="${me#"${p_name}-"}"
me_short="${me_short%.sh}"
_no_l="$nolog"

set -f

if [ -z "$geotag" ]; then
	# not assuming a compatible shell at this point
	# check for supported grep
	_no_grep="Error: grep not found."
	command -v grep >/dev/null || { echo "$_no_grep" >&2; exit 1; }
	if [ $? != 0 ]; then echo "$_no_grep" >&2; exit 1; fi
	_g_test=`echo 0112 | grep -oE '1{2}'`
	if [ "$_g_test" != 11 ]; then echo "Error: grep doesn't support the required options." >&2; exit 1; fi

	# check for supported shell
	if command -v readlink >/dev/null; then
		curr_shell=`readlink /proc/$$/exe`
	else
		curr_shell=`ls -l /proc/$$/exe | grep -oE '/[^[:space:]]+$'`
	fi
	ok_shell=`echo $curr_shell | grep -E '/(bash|dash|yash|ash|busybox|ksh93)'`
	if [ -z "$curr_shell" ]; then
		echo "Warning: failed to identify current shell. $p_name may not work correctly. Please notify the developer." >&2
	elif [ -z "$ok_shell" ]; then
		bad_shell=`echo $curr_shell | grep -E 'zsh|csh'`
		if [ -n "$bad_shell" ]; then echo "Error: unsupported shell $curr_shell." >&2; exit 1; fi
		echo "Warning: whether $p_name works with your shell $curr_shell is currently unknown. Please test and notify the developer." >&2
	fi
	case "$curr_shell" in *busybox*) curr_shell="/bin/sh"; esac

	# check for proc
	if [ ! -d "/proc" ]; then echo "Error: /proc not found."; exit 1; fi

	# export some vars
	set_ascii
	export geotag="$p_name"
	export WARN="${red}Warning${n_c}:" ERR="${red}Error${n_c}:" FAIL="${red}Failed${n_c} to" IFS="$default_IFS"

	if [ -f "${p_script}-setvars.sh" ]; then
		. "${p_script}-setvars.sh"
	else
		. "${conf_dir}/${p_name}-setvars.sh"
	fi

	# check common deps
	check_deps tr cut sort wc awk sed logger pgrep || die
	{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
	{ check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset && export _fw_backend=ipt
	} || die "neither nftables nor iptables+ipset found."
	export geochain="$(toupper "$geotag")"
fi

:
