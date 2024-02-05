#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2155,SC2018,SC2019,SC2012,SC2254,SC2086,SC2015

# geoip-shell-common.sh

# Common functions and variables for geoip-shell suite


### Functions

setdebug() {
	export debugmode="${debugmode_args:-$debugmode}"
}

set_colors() {
	all_C="$(printf '\033[0;31m \033[0;32m \033[1;34m \033[1;33m \033[0;35m \033[0m')"
	set -- $all_C
	export red="$1" green="$2" blue="$3" yellow="$4" purple="$5" n_c="$6"
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
		die "Error: $me needs to be run as root."
	esac
}

extra_args() {
	[ "$*" ] && { usage; echolog "Error in arguments. First unexpected argument: '$1'." >&2; exit 1; }
}

checkutil() {
	command -v "$1" 1>/dev/null
}

unknownopt() {
	usage; die "Unknown option: '-$OPTARG'."
}

unknownact() {
	specifyact="Specify action in the 1st argument!"
	case "$action" in
		'') usage; die "$specifyact" ;;
		*) usage; die "Error: Unknown action: '$action'." "$specifyact"
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
	script_to_call="$1"
	shift

	# call the daughter script, then reset $config_var to force re-read of the config file
	[ ! "$script_to_call" ] && { echolog -err "call_script: Error: received empty string."; return 1 ; }
	sh "$script_to_call" "$@"; call_rv=$?; export config_var=""
	debugexitmsg
	return "$call_rv"
}

# sets some strings for debug and logging
init_geoscript(){
	me=$(basename "$0")
	me_short="${me#"${proj_name}-"}"
	me_short="${me_short%.sh}"
	me_short_cap="$(toupper "$me_short")"
	set -f
}

check_deps() {
	missing_deps=''
	for dep; do ! checkutil "$dep" && missing_deps="${missing_deps}'$dep', "; done
	[ "$missing_deps" ] && { echolog -err "Error: missing dependencies: ${missing_deps%, }"; return 1; }
	return 0
}

get_json_lines() {
	sed -n -e /"$1"/\{:1 -e n\;/"$2"/q\;p\;b1 -e \}
}

# outputs arguments to stdout and writes them to syslog
# if one of the arguments is "-err" then redirect output to stderr
echolog() {
	unset msg_args msg_is_err noecho _new_line

	for arg in "$@"; do
		case "$arg" in
			"-err" ) msg_is_err="true" ;;
			"-noecho" ) noecho="true" ;;
			'') ;;
			* ) msg_args="$msg_args$arg$delim"
		esac
	done

	# check for newline in the biginning of the line and strip it
	case "$msg_args" in "$_nl"* )
		_new_line="$_nl"
		msg_args="${msg_args#"$_nl"}"
	esac

	newifs "$delim" ecl
	set -- $msg_args; oldifs ecl

	for arg in "$@"; do
		[ ! "$noecho" ] && {
			_msg="${_new_line}$me_short: $arg"
			case "$msg_is_err" in
				'') printf '%s\n' "$_msg" ;;
				*) printf '%s\n' "$_msg" >&2
			esac
		}
		[ ! "$nolog" ] && logger -t "$me" "$(printf %s "$arg" | sed -e 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
	done
}

# prints a debug message
debugprint() {
	[ ! "$debugmode" ] && return
	_new_line=
	dbg_args="$*"
	case "$dbg_args" in "\n"* )
		_new_line="$_nl"
		dbg_args="${dbg_args#"\n"}"
	esac

	printf '%s\n' "${_new_line}Debug: ${me_short}: $dbg_args" >&2
}

debugentermsg() {
	[ ! "$debugmode" ] || [ ! "$me_short_cap" ] && return 0
	printf %s "${yellow}Started *${me_short_cap}* with args: "
	newifs "$delim" dbn
	for arg in $arguments; do printf %s "'$arg' "; done
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

	die_args=''
	for die_arg in "$@"; do
		case "$die_arg" in -nolog) nolog="1" ;; '') ;; *) die_args="$die_args$die_arg$delim"; esac
	done

	[ "$die_args" ] && {
		echo >&2
		newifs "$delim" die
		for arg in $die_args; do
			printf '%s\n' "$yellow$me_short$n_c: $arg" >&2
			[ ! "$nolog" ] && logger -t "$me" "$(printf %s "$arg" | sed -e 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ')"
		done
		oldifs die
	}
	echo >&2
	exit "$die_rv"
}

# 1 - key
# 2 - var name for output
# 3 - optional path to config file
# 4 - optional '-nodie'
getconfig() {
	getconfig_failed() {
		eval "$outvar_gc"=''
		[ ! "$nodie" ] && die "Error: Failed to read value for '$key_conf' from file '$target_file'."
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
	return 0
}

# 1 - input
# 2 - leading '*' wildcard (if required)
# 3 - filter string
# 4 - trailing '*' wildcard (if required)
# 5 - var name for output
# outputs only the 1st match
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
	[ ! "$target_file" ] && die "Error: getstatus: target file not specified!" ||
		getconfig "$2" "status_value" "$target_file" "-nodie"; rv_gs=$?
	eval "$3"='$status_value'
	return $rv_gs
}

# Accepts key=value pairs and writes them to (or replaces in) config file specified in global variable $conf_file
# if one of the value pairs is "target_file=[file]" then writes to $file instead
setconfig() {
	unset args_lines args_target_file keys_test_str newconfig
	IFS_OLD_sc="$IFS"
	for argument_conf in "$@"; do
		# separate by newline and process each line (support for multi-line arguments)
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

	[ ! "$target_file" ] && die "setconfig: '\$target_file' variable is not set!"

	[ -f "$target_file" ] && { oldconfig="$(cat "$target_file")" || { die "setconfig: Error: failed to read '$target_file'."; }; }
	# join old and new config
	for config_line in $oldconfig; do
		eval "case \"$config_line\" in
				''|$keys_test_str ) ;;
				* ) newconfig=\"$newconfig$config_line$_nl\"
			esac"
	done
	printf %s "$newconfig$args_lines" > "$target_file" || { die "setconfig: failed to overwrite '$target_file'"; }
	oldifs sc
	return 0
}

# utilizes setconfig() for writing to status files
# 1 - path to the status file
# extra arguments are passed as is to setconfig
setstatus() {
	target_file="$1"
	shift 1
	[ ! "$target_file" ] && die "setstatus: Error: target file not specified!" || setconfig "target_file=$target_file" "$@"
}

# 1 - string
# 2 - var name for output
trim_spaces() {
	trim_var="$2"
	newifs "$trim_IFS" trim
	set -- $1
	eval "$trim_var"='$*'
	oldifs trim
}

# 1 - var name for output
# 2 - optional input string (otherwise uses prev value)
# 3 - optional delimiter
sanitize_str() {
	[ "$2" ] && inp_str="$2" || eval "inp_str=\"\$$1\""

	san_delim="${3:- }"
	_words=''
	newifs "$default_IFS" san
	for _word in $inp_str; do
		case "$_words" in *"$_word"*) ;; *) _words="$_words$_word$san_delim"; esac
	done
	eval "$1"='${_words%$san_delim}'
	oldifs san
}

get_intersection() {
	[ ! "$1" ] || [ ! "$2" ] && { eval "$3"=''; return 1; }
	_fs_gi="${4:-"$_nl"}"
	_intersect=''
	for e in $2; do
		case "$1" in "$e"|"$e$_fs_gi"*|*"$_fs_gi$e"|*"$_fs_gi$e$_fs_gi"*)
			case "$_intersect" in
				"$e"|"$e$_fs_gi"*|*"$_fs_gi$e"|*"$_fs_gi$e$_fs_gi"*) ;;
				*) _intersect="$_intersect$e$_fs_gi"
			esac
		esac
	done
	eval "$3"='${_intersect%$_fs_gi}'
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
	var_stn="$2"
	newifs "$trim_IFS" stn
	set -- $1
	IFS="$_nl"
	eval "$var_stn"='$*'
	oldifs stn
}

nl2sp() {
	var_nts="$2"
	newifs "$_nl" nts
	set -- $1
	IFS=' '
	eval "$var_nts"='$*'
	oldifs nts
}

# trims extra whitespaces, discards empty arguments
# output string is delimited with $delim
sanitize_args() {
	arguments=''
	for arg in "$@"; do
		trim_spaces "$arg" "arg"
		[ "$arg" ] && arguments="$arguments$arg$delim"
	done
}

# validates country code in $1 against cca2.list
# must be in upper case
# optional $2 may contain path to cca2.list
# returns 0 if validation successful, 2 if not, 1 if cca2 list is empty
validate_ccode() {
	cca2_path="${2:-"$script_dir/cca2.list"}"
	[ -s "$cca2_path" ] && export ccode_list="${ccode_list:-"$(cat "$cca2_path")"}"
	case "$ccode_list" in
		'') echo "Error: \$ccode_list variable is empty. Perhaps cca2.list is missing?" >&2; return 1 ;;
		*" $1 "*) return 0 ;;
		*) return 2
	esac
}

detect_init() {
	# init process is pid 1
	_pid1="$(ls -l /proc/1/exe)"
	for init_sys in systemd procd initctl busybox upstart; do
		case "$_pid1" in *"$init_sys"* ) printf %s "$init_sys"; return 0; esac
	done
	case "$_pid1" in *"/sbin/init"* )
		for init_sys in systemd upstart; do
			case "$_pid1" in *"$init_sys"* ) printf %s "$init_sys"; return 0; esac
		done
	esac
	printf %s "unknown"
	return 1
}

check_cron() {
	[ "$cron_rv" ] && return "$cron_rv"
	cron_rv=0
	case "$(detect_init)" in
		systemd )
			# check if cron service is enabled
			(systemctl is-enabled cron.service) 1>/dev/null 2>/dev/null; cron_rv=$? ;;
		* )
			# check for cron or crond in running processes
			if ! pidof cron 1>/dev/null && ! pidof crond 1>/dev/null; then cron_rv=1; else cron_rv=0; fi ;;
	esac
	export cron_rv
	return "$cron_rv"
}

[ ! "$_nl" ] && {
	export LC_ALL=C proj_name="geoip-shell"
	export conf_dir="/etc/${proj_name}"
	export conf_file="${conf_dir}/${proj_name}.conf" delim="$(printf '\35')" default_IFS="$IFS" trim_IFS="$(printf ' \t')" _nl='
'
	set_colors

	dir="/usr/local/bin"
	case "$PATH" in *:"$dir":*|"$dir"|*:"$dir"|"$dir":* );;	*) export PATH="$PATH:$dir"; esac

	check_deps tr cut sort wc awk sed grep logger || die
	checkutil "uclient-fetch" && export ucl_f_exists="true"
	checkutil "curl" && export curl_exists="true"
	checkutil "wget" && export wget_exists="true"

	[ ! "$ucl_f_exists" ] && [ ! "$curl_exists" ] && [ ! "$wget_exists" ] && die "Error: Compatible download utilites unavailable."

}

init_geoscript