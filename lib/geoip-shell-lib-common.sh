#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2254,SC2086,SC2015,SC2046,SC2016,SC1090,SC2317

# geoip-shell-lib-common.sh

# Library of common functions and variables for geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


### Functions

#@
setdebug() {
	export debugmode="${debugmode_arg:-$debugmode}"
}

# prints a debug message
debugprint() {
	[ ! "$debugmode" ] && return
	__nl=
	dbg_args="$*"
	case "$dbg_args" in "\n"*)
		__nl="$_nl"
		dbg_args="${dbg_args#"\n"}"
	esac
	printf '%s\n' "${__nl}${yellow}Debug: $blue${me_short}$n_c: $dbg_args" >&2
}

debugentermsg() {
	[ ! "$debugmode" ] || [ ! "$me_short" ] && return 0
	{
		toupper me_short_cap "$me_short"
		printf %s "${yellow}Started *$me_short_cap* with args: "
		newifs "$delim" dbn
		for arg in $_args; do printf %s "'$arg' "; done
		printf '%s\n' "${n_c}"
	} >&2
	oldifs dbn
}

debugexitmsg() {
	[ ! "$debugmode" ] || [ ! "$me_short" ] && return 0
	toupper me_short_cap "$me_short"
	printf '%s\n' "${yellow}Back to *$me_short_cap*...${n_c}" >&2
}
#@

get_md5() {
	printf %s "$1" | md5sum | cut -d' ' -f1
}

# sets some variables for colors, symbols and delimiter
set_ansi() {
	set -- $(printf '\033[0;31m \033[0;32m \033[1;34m \033[1;33m \033[0;35m \033[0m \35 \342\234\224 \342\234\230 \t')
	export red="$1" green="$2" blue="$3" yellow="$4" purple="$5" n_c="$6" delim="$7" _V="$8" _X="$9" trim_IFS=" ${10}"
	export _V="$green$_V$n_c" _X="$red$_X$n_c"
}

# set IFS to $1 while saving its previous value to variable tagged $2
newifs() {
	eval "IFS_OLD_$2"='$IFS'; IFS="$1"
}

# restore IFS value from variable tagged $1
oldifs() {
	eval "IFS=\"\$IFS_OLD_$1\""
}

is_root_ok() {
	[ "$root_ok" ] && return 0
	rv=1
	[ "$manmode" ] && { rv=0; tip=" For usage, run '$me -h'."; }
	die $rv "$me needs to be run as root.$tip"
}

extra_args() {
	[ "$*" ] && {
		[ "$debugmode" ] && {
			printf %s "${yellow}Debug:${n_c} Args: "
			newifs "$delim" ea
			for arg in $_args; do printf %s "'$arg' "; done
			printf '%s\n' "${n_c}"
			oldifs ea
		} >&2

		die "Invalid arguments. First unexpected argument: '$1'."
	}
}

checkutil() {
	hash "$1" 2>/dev/null
}

checkvars() {
	for chkvar; do
		eval "[ \"\$$chkvar\" ]" || { printf '%s\n' "Error: The '\$$chkvar' variable is unset."; exit 1; }
	done
}

unknownopt() {
	usage; die "Unknown option '-$OPTARG' or it requires an argument."
}

statustip() {
	printf '\n%s\n\n' "View geoip status with '${blue}${p_name} status${n_c}' (may require 'sudo')."
}

report_lists() {
	unset iplists_incoherent lists_reported
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue
		get_active_iplists verified_lists "$direction"
		nl2sp verified_lists
		if [ -n "$verified_lists" ]; then
			verified_lists="${blue}$verified_lists${n_c}"
		else
			verified_lists="${red}None${n_c}"
		fi
		[ ! "$lists_reported" ] && printf '\n'
		printf '%s\n' "Final ip lists in $direction $geomode: '${blue}$verified_lists${n_c}'."
		lists_reported=1
	done
}

unknownact() {
	specifyact="Specify action in the 1st argument!"
	case "$action" in
		-V|-h) ;;
		'') usage; die "$specifyact" ;;
		*) usage; die "Unknown action: '$action'." "$specifyact"
	esac
}

# asks the user to pick an option
# $1 - input in the format 'a|b|c'
# output via the $REPLY var
pick_opt() {
	while :; do
		printf %s "$1: "
		read -r REPLY
		is_alphanum "$REPLY" || { printf '\n%s\n\n' "Please enter $1"; continue; }
		tolower REPLY
		eval "case \"$REPLY\" in
				$1) return ;;
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

# checks if $1 is alphanumeric (underlines allowed)
# optional '-n' in $2 silences error messages
is_alphanum() {
	case "$1" in *[!A-Za-z0-9_]*)
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

# 1 - var name for output
# 2 - toupper|tolower
# 3 - string
conv_case() {
	outvar_cc="$1"
	case "$2" in
		toupper) tr_1='a-z' tr_2='A-Z' ;;
		tolower) tr_1='A-Z' tr_2='a-z'
	esac
	newifs "$default_IFS" conv
	case "$3" in
		*[$tr_1]*) conv_res="$(printf %s "$3" | tr "$tr_1" "$tr_2")" ;;
		*) conv_res="$3"
	esac
	eval "$outvar_cc=\"$conv_res\""
	oldifs conv
}

# 1 - var name for output
# 2 - optional string (otherwise uses prev value)
tolower() {
	in_cc="$2"
	[ $# = 1 ] && eval "in_cc=\"\$$1\""
	conv_case "$1" tolower "$in_cc"
}

# 1 - var name for output
# 2 - optional string (otherwise uses prev value)
toupper() {
	in_cc="$2"
	[ $# = 1 ] && eval "in_cc=\"\$$1\""
	conv_case "$1" toupper "$in_cc"
}

# calls another script and resets the config cache on exit
# if $use_lock is set, removes lock before calling daughter script and makes lock after
call_script() {
	[ "$1" = '-l' ] && { use_lock=1; shift; }
	script_to_call="$1"
	shift

	: "${use_shell:=$curr_sh_g}"
	: "${use_shell:=sh}"

	# call the daughter script, then forget cached config
	[ ! "$script_to_call" ] && { echolog -err "call_script: received empty string."; return 1 ; }

	[ "$use_lock" ] && rm_lock
	$use_shell "$script_to_call" "$@"; call_rv=$?; unset main_config
	debugexitmsg
	[ "$use_lock" ] && mk_lock -f
	use_lock=
	return "$call_rv"
}

check_deps() {
	missing_deps=
	for dep; do ! checkutil "$dep" && missing_deps="${missing_deps}'$dep', "; done
	[ "$missing_deps" ] && { echolog -err "Missing dependencies: ${missing_deps%, }"; return 1; }
	:
}

check_libs() {
	missing_libs=
	for lib; do [ ! -s "$lib" ] && missing_lib="${missing_libs}'$lib', "; done
	[ "$missing_libs" ] && { echolog -err "Missing libraries: ${missing_libs%, }"; return 1; }
	:
}

get_json_lines() {
	sed -n -e /"$1"/\{:1 -e n\;/"$2"/q\;p\;b1 -e \}
}

# outputs args to stdout and writes them to syslog
# if one of the args is '-err' or '-warn' then redirect output to stderr
echolog() {
	unset msg_args __nl msg_prefix o_nolog

	highlight="$blue"; err_l=info
	for arg in "$@"; do
		case "$arg" in
			"-err" ) highlight="$red"; err_l=err; msg_prefix="$ERR " ;;
			"-warn" ) highlight="$yellow"; err_l=warn; msg_prefix="$WARN " ;;
			"-nolog" ) o_nolog=1 ;;
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
			_msg="${__nl}$highlight$me_short$n_c: $msg_prefix$arg"
			case "$err_l" in
				info) printf '%s\n' "$_msg" ;;
				err|warn) printf '%s\n' "$_msg" >&2
			esac
			unset __nl msg_prefix
		}
		[ ! "$nolog" ] && [ ! "$o_nolog" ] &&
			logger -t "$me" -p user."$err_l" "$(printf %s "$msg_prefix$arg" | awk '{gsub(/\033\[[0-9;]*m/,"")};1' ORS=' ')"
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
	trap - INT TERM HUP QUIT

	[ "$die_args" ] && {
		newifs "$delim" die
		for arg in $die_args; do
			echolog "$msg_type" "$arg"
			msg_type=
		done
		oldifs die
	}
	exit "$die_rv"
}

# converts unsigned integer to either [x|xK|xM|xT|xQ] or [xB|xKiB|xMiB|xTiB|xPiB], depending on $2
# if result is not an integer, outputs up to 2 digits after decimal point
# 1 - int
# 2 - (optional) "bytes"
num2human() {
	i=${1:-0} s=0 d=0
	case "$2" in bytes) m=1024 ;; '') m=1000 ;; *) return 1; esac
	case "$i" in *[!0-9]*) echolog -err "num2human: Invalid unsigned integer '$i'."; return 1; esac
	for S in B KiB MiB GiB TiB; do
		[ $((i > m && s < 4)) = 0 ] && break
		d=$i
		i=$((i/m))
		s=$((s+1))
	done
	[ -z "$2" ] && { S=${S%B}; S=${S%i}; [ "$S" = G ] && S=B; }
	d=$((d % m * 100 / m))
	case $d in
		0) printf "%s%s\n" "$i" "$S"; return ;;
		[1-9]) fp="02" ;;
		*0) d=${d%0}; fp="01"
	esac
	printf "%s.%${fp}d%s\n" "$i" "$d" "$S"
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

# 1 - var name for output
# 2 - optional key (otherwise uses var name as key)
# 3 - optional path to config file
getconfig() {
	key_conf="$1"
	[ $# -gt 1 ] && key_conf="$2"
	target_file="${3:-$conf_file}"
	[ "$1" ] && [ "$target_file" ] &&
	getallconf conf "$target_file" &&
	get_matching_line "$conf" "" "$key_conf=" "*" "conf_line" || {
		eval "$1="
		[ ! "$nodie" ] && die "$FAIL read value for '$key_conf' from file '$target_file'."
		return 2
	}
	eval "$1"='${conf_line#"${key_conf}"=}'
	:
}

# 1 - var name for output
# 2 - conf file path
getallconf() {
	[ ! "$1" ] && return 1
	[ ! -f "$2" ] && { echolog -err "Config/status file '$2' is missing!"; return 1; }

	# check in cache first
	conf_gac=
	[ "$2" = "$conf_file" ] && conf_gac="$main_config"
	[ -z "$conf_gac" ] && {
		conf_gac="$(grep -vE '^([[:blank:]]*#.*$|$)' "$2" \
			| sed 's/^tcp_ports=/inbound_tcp_ports=/;s/^udp_ports=/inbound_udp_ports=/;s/^geomode=/inbound_geomode=/;s/^iplists=/inbound_iplists=/')"
		[ "$2" = "$conf_file" ] && export main_config="$conf_gac"
	}
	eval "$1=\"$conf_gac\""
	:
}

# gets all config from file $1 or $conf_file if unsecified, and assigns to vars named same as keys in the file
# 1 - (optional) -v to load from variable $2
# if $export_conf is set, exports the vars
get_config_vars() {
	inval_e() {
		oldifs gcv
		echolog -err "Invalid entry '$entry' in file '$target_f_gcv'."
		[ ! "$nodie" ] && die
	}

	_exp=
	[ "$export_conf" ] && _exp="export "

	if [ "$1" = '-v' ]; then
		eval "all_config=\"\$${2}\""
		[ -z "$all_config" ] && return 1
	else
		target_f_gcv="${1:-"$conf_file"}"
		getallconf all_config "$target_f_gcv" || {
			echolog -err "$FAIL get config from '$target_f_gcv'."
			[ ! "$nodie" ] && die
			return 1
		}
	fi

	newifs "$_nl" gcv
	for entry in $all_config; do
		case "$entry" in
			'') continue ;;
			*=*=*) { inval_e; return 1; } ;;
			*=*) ;;
			*) { inval_e; return 1; } ;;
		esac
		key_conf="${entry%=*}"
		is_alphanum "$key_conf" || { inval_e; return 1; }
		eval "$_exp$key_conf"='${entry#${key_conf}=}'
	done
	oldifs gcv
	:
}

# Accepts key=value pairs and writes them to (or replaces in) config file specified in global variable $conf_file
# if no '=' included, gets value of var with named the same as the key
# if one of the value pairs is "target_file=[file]" then writes to $file instead
setconfig() {
	unset args_lines args_target_file keys_test_str newconfig
	newifs "$_nl" sc
	for argument_conf in "$@"; do
		# separate by newline and process each line (support for multi-line args)
		for line in $argument_conf; do
			[ ! "$line" ] && continue
			case "$line" in
				'') continue ;;
				*[!A-Za-z0-9_]*=*) sc_failed "bad config line '$line'." ;;
				*=*) key_conf="${line%%=*}"; value_conf="${line#*=}" ;;
				*) key_conf="$line"; eval "value_conf=\"\$$line\"" || sc_failed "bad key '$line'."
			esac
			case "$key_conf" in
				'') ;;
				target_file) args_target_file="$value_conf" ;;
				*) args_lines="${args_lines}${key_conf}=$value_conf$_nl"
					keys_test_str="${keys_test_str}\"${key_conf}=\"*|"
			esac
		done
	done
	keys_test_str="${keys_test_str%\|}"
	[ ! "$keys_test_str" ] && { sc_failed "no valid args passed."; return 1; }
	target_file="${args_target_file:-$inst_root_gs$conf_file}"

	[ ! "$target_file" ] && { sc_failed "'\$target_file' variable is not set."; return 1; }

	[ -f "$target_file" ] && {
		getallconf oldconfig "$target_file" || { sc_failed "$FAIL read '$target_file'."; return 1; }
	}
	# join old and new config
	for config_line in $oldconfig; do
		eval "case \"$config_line\" in
				''|$keys_test_str) ;;
				*) newconfig=\"$newconfig\""'$config_line'"\"$_nl\"
			esac"
	done
	oldifs sc

	newconfig="$newconfig$args_lines"
	# don't write to file if config didn't change
	[ -f "$target_file" ] && old_conf_exists=1 || old_conf_exists=
	if [ ! "$old_conf_exists" ] || ! compare_file2str "$target_file" "$newconfig"; then
		printf %s "$newconfig" > "$target_file" || { sc_failed "$FAIL write to '$target_file'"; return 1; }
	fi

	[ "$target_file" = "$conf_file" ] && {
		export main_config="$newconfig"
		[ ! "$old_conf_exists" ] && {
			chmod 600 "$conf_file" && chown root:root "$conf_file" ||
				echolog -warn "$FAIL update permissions for file '$conf_file'."
		}
	}
	:
}

set_all_config() {
	setconfig inbound_tcp_ports inbound_udp_ports outbound_tcp_ports outbound_udp_ports \
		inbound_geomode outbound_geomode inbound_iplists outbound_iplists \
		geosource lan_ips_ipv4 lan_ips_ipv6 autodetect trusted_ipv4 trusted_ipv6 \
		nft_perf ifaces datadir nobackup no_persist noblock http user_ccode schedule families \
		_fw_backend max_attempts reboot_sleep force_cron_persist
}

sc_failed() {
	oldifs sc
	echolog -err "setconfig: $1"
	[ ! "$nodie" ] && die
}

# utilizes getconfig() but intended for reading status from status files
# 1 - status file
getstatus() {
	[ ! "$1" ] && {
		echolog -err "getstatus: target file not specified!"
		[ ! "$nodie" ] && die
		return 1
	}
	nodie=1 get_config_vars "$1"
}

# utilizes setconfig() for writing to status files
# 1 - path to the status file
# extra args are passed as is to setconfig
setstatus() {
	target_file="$1"
	shift 1
	[ ! "$target_file" ] && { echolog -err "setstatus: target file not specified!"; [ ! "$nodie" ] && die; return 1; }
	[ ! -d "${target_file%/*}" ] && mkdir -p "${target_file%/*}" &&
		[ "$root_ok" ] && chmod -R 600 "${target_file%/*}"
	[ ! -f "$target_file" ] && touch "$target_file" &&
		[ "$root_ok" ] && chmod 600 "$target_file"
	setconfig target_file "$@"
}

awk_cmp() {
	awk 'NF==0{next} NR==FNR {A[$0]=1;a++;next} {b++} !A[$0]{r=1;exit} END{if(!a&&!b){exit 0};if(!a||!b){exit 1};exit r}' r=0 "$1" "$2"
}

# compares lines in files $1 and $2, regardless of order
# discards empty lines
# returns 0 for no diff, 1 for diff, 2 for error
compare_files() {
	[ -f "$1" ] && [ -f "$2" ] || { echolog -err "compare_files: file '$1' or '$2' does not exist."; return 2; }
	awk_cmp "$1" "$2" && awk_cmp "$2" "$1"
}

# compares lines in file $1 and string $2, regardless of order
# discards empty lines
# returns 0 for no diff, 1 for diff, 2 for error
compare_file2str() {
	[ -f "$1" ] || { echolog -err "compare_file2str: file '$1' does not exist."; return 2; }
	printf '%s\n' "$2" | awk_cmp - "$1" && printf '%s\n' "$2" | awk_cmp "$1" -
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
	eval "$1=\"\${$1}$a2l_fs\""'$2'"; $1=\"\${$1#$a2l_fs}\""
	return 0
}

# checks if string $1 is safe to use with eval
is_str_safe() {
	case "$1" in *'\'*|*'"'*|*\'*) echolog -err "Invalid string '$1'"; return 1; esac
}

# removes duplicate words, removes leading and trailing delimiter, trims in-between extra delimiter characters
# by default expects a whitespace-delimited list
# (1) - optional -n to delimit both input and output by newline
# 1 - var name for output
# 2 - optional input string (otherwise uses prev value)
# 3 - optional input delimiter
# 4 - optional output delimiter
san_str() {
	[ "$1" = '-n' ] && { _del="$_nl"; shift; } || _del=' '
	[ "$2" ] && inp_str="$2" || eval "inp_str=\"\$$1\""
	is_str_safe "$inp_str" || { unset "$1"; return 1; }
	_sid="${3:-"$_del"}"
	_sod="${4:-"$_del"}"
	_words=
	newifs "$_sid" san
	for _w in $inp_str; do
		add2list _words "$_w" "$_sod"
	done

	eval "$1"='$_words'
	oldifs san
	:
}

# get intersection of lists $1 and $2, with optional field separator $4 (otherwise uses whitespace)
# output via variable with name $3
get_intersection() {
	gi_out="${3:-___dummy}"
	[ ! "$1" ] || [ ! "$2" ] && { unset "$gi_out"; return 1; }
	_fs_gi="${4:-" "}"
	_isect=
	newifs "$_fs_gi" _fs_gi
	for e in $2; do
		is_included "$e" "$1" "$_fs_gi" && add2list _isect "$e" "$_fs_gi"
	done
	eval "$gi_out"='$_isect'
	oldifs _fs_gi
}

# get difference between lists $1 and $2, with optional field separator $4 (otherwise uses whitespace)
# output via optional variable with name $3
# returns status 0 if lists match, 1 if not
get_difference() {
	gd_out="${3:-___dummy}"
	case "$1" in
		'') case "$2" in '') unset "$gd_out"; return 0 ;; *) eval "$gd_out"='$2'; return 1; esac ;;
		*) case "$2" in '') eval "$gd_out"='$1'; return 1; esac
	esac
	_fs_gd="${4:-" "}"
	subtract_a_from_b "$1" "$2" _diff1 "$_fs_gd"
	subtract_a_from_b "$2" "$1" _diff2 "$_fs_gd"
	_diff="$_diff1$_fs_gd$_diff2"
	_diff="${_diff#"$_fs_gd"}"
	eval "$gd_out"='${_diff%$_fs_gd}'
	[ "$_diff1$_diff2" ] && return 1 || return 0
}

# subtract list $1 from list $2, with optional field separator $4 (otherwise uses whitespace)
# output via optional variable with name $3
# returns status 0 if the result is null, 1 if not
subtract_a_from_b() {
	sab_out="${3:-___dummy}"
	case "$2" in '') unset "$sab_out"; return 0; esac
	case "$1" in '') eval "$sab_out"='$2'; [ ! "$2" ]; return; esac
	_fs_su="${4:-" "}"
	rv_su=0 _subt=
	newifs "$_fs_su" _fs_su
	for e in $2; do
		is_included "$e" "$1" "$_fs_su" || { add2list _subt "$e" "$_fs_su"; rv_su=1; }
	done
	eval "$sab_out"='$_subt'
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
		is_str_safe "$arg" || die
		trimsp arg
		[ "$arg" ] && _args="$_args$arg$delim"
	done
}

# restores the nolog var prev value
r_no_l() { nolog="$_no_l"; }

is_whitelist_present() {
	case "$inbound_geomode$outbound_geomode" in *whitelist*) return 0; esac
	return 1
}

set_dir_vars() {
	unset geomode geochain base_geochain iface_chain dir_short
	case "$1" in
		inbound|outbound) ;;
		'') echolog -err "set_dir_vars: direction not specified."; return 1 ;;
		*) echolog -err "set_dir_vars: invalid direction '$1'."; return 1
	esac
	eval "geomode=\"\$${1}_geomode\"
		geochain=\"\$${1}_geochain\"
		base_geochain=\"\$${1}_base_geochain\"
		iface_chain=\"\$${1}_iface_chain\"
		dir_short=\"\$${1}_dir_short\""
	:
}

# checks current ipsets and firewall rules for geoip-shell
# returns a whitespace-delimited list of active ip lists
# (optional: 1 - '-f' to force re-read of the table - nft-specific)
# 1 - var name for output
# 2 - direction (inbound|outbound)
get_active_iplists() {
	unset force_read
	[ "$1" = "-f" ] && { force_read="-f"; shift; }
	[ "$2" ] || die "get_active_iplists: direction not specified"
	gai_out_var="$1" direction="$2"
	eval "geomode=\"\$${direction}_geomode\" iplists=\"\$${direction}_iplists\""
	case "$geomode" in
		whitelist) ipt_target=ACCEPT nft_verdict=accept ;;
		blacklist) ipt_target=DROP nft_verdict=drop ;;
		*) die "get_active_iplists: unexpected geoblocking mode '$geomode'."
	esac

	ipset_iplists="$(get_ipset_iplists)"
	fwrules_iplists="$(get_fwrules_iplists "$direction")"

	# debugprint "$2 ipset_iplists: '$ipset_iplists', fwrules_iplists: '$fwrules_iplists'"

	nl2sp ipset_iplists_sp "$ipset_iplists"
	nl2sp fwrules_iplists_sp "$fwrules_iplists"

	inc=0
	subtract_a_from_b "$ipset_iplists_sp" "$fwrules_iplists_sp" missing_ipsets || inc=1

	subtract_a_from_b "$iplists" "$fwrules_iplists_sp" unexpected_lists || inc=1
	subtract_a_from_b "$fwrules_iplists_sp" "$iplists" missing_lists || inc=1

	get_intersection "$ipset_iplists" "$fwrules_iplists" active_iplists_nl "$_nl"
	nl2sp "$gai_out_var" "$active_iplists_nl"

	return $inc
}

# checks whether current ipsets and iptables rules match ones in the config file
check_lists_coherence() {
	_no_l="$nolog"
	[ "$1" = '-n' ] && nolog=1
	debugprint "Verifying ip lists coherence..."

	iplists_incoherent=
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue

		# check for a valid list type
		case "$geomode" in whitelist|blacklist) ;; *) r_no_l; echolog -err "Unexpected geoblocking mode '$geomode'!"; return 1; esac

		getconfig iplists "${direction}_iplists"
		get_active_iplists -f "${direction}_active_lists" "$direction"; get_a_i_rv=$?
		subtract_a_from_b "$inbound_iplists $outbound_iplists" "$ipset_iplists_sp" unexpected_ipsets || get_a_i_rv=1
		[ "$get_a_i_rv" != 0 ] &&
		{
			iplists_incoherent=1
			eval "active_lists=\"\$${direction}_active_lists\""
			report_incoherence "$direction"
			debugprint "Config ip lists: '$iplists'" "Firewall ip lists: '$active_lists'" "ipsets: $ipset_iplists_sp"
		}
	done
	r_no_l
	[ "$iplists_incoherent" ] && return 1
	debugprint "Successfully verified ip lists coherence."
	:
}

report_excluded_lists() {
	fast_el_cnt "$1" ' ' excl_cnt
	excl_list="list" excl_verb="is"
	[ "$excl_cnt" != 1 ] && excl_list="lists" excl_verb="are"
	echolog -nolog "Ip $excl_list '$1' $excl_verb in the exclusions file, skipping."
}

# 1 - direction (inbound|outbound)
report_incoherence() {
	[ "$1" ] || die "report_incoherence: direction not specified"
	echolog -warn "${_nl}Discrepancy detected between $1 geoblocking state and the config file."
	for opt_ri in unexpected missing; do
		eval "[ \"\$${opt_ri}_lists\" ] && echolog -warn \"$opt_ri ip lists in the firewall: '\$${opt_ri}_lists'\""
		eval "[ \"\$${opt_ri}_ipsets\" ] && echolog -warn \"$opt_ri ip sets in the firewall: '\$${opt_ri}_ipsets'\""
	done
}

# validates country code in $1 against cca2.list
# must be in upper case
# optional $2 may contain path to cca2.list
# returns 0 if validation successful, 2 if not, 1 if cca2 list is empty
validate_ccode() {
	cca2_path="$conf_dir/cca2.list"
	[ ! -s "$cca2_path" ] && cca2_path="$script_dir/cca2.list"
	[ -s "$cca2_path" ] && export ccode_list="${ccode_list:-"$(cat "$cca2_path")"}"
	case "$ccode_list" in
		'') die "\$ccode_list variable is empty. Perhaps cca2.list is missing?" ;;
		*" $1 "*) return 0 ;;
		*) return 2
	esac
}

# detects all network interfaces known to the kernel, except the loopback interface
# returns 1 if nothing detected
detect_ifaces() {
	[ -r "/proc/net/dev" ] && sed -n '/^[[:space:]]*[^[:space:]]*:/{s/^[[:space:]]*//;s/:.*//p}' < /proc/net/dev | grep -vx 'lo'
}

detect_fw_backend() {
	if [ "$_OWRTFW" ]; then
		case "$_OWRTFW" in
			3) printf ipt ;;
			4) printf nft ;;
			*) echolog -err "Invalid OpenWrt firewall version '$_OWRTFW'."; return 1
		esac
		return 0
	fi

	[ ! "$_fw_backend_arg" ] && {
		. "$_lib-check-compat.sh" || { echolog -err "Failed to source '$_lib-check-compat.sh'."; return 1; }
		if check_fw_backend nft 2>/dev/null; then
			printf nft
		else
			check_fw_backend ipt 2>/dev/null
			case $? in
				0) printf ipt ;;
				1) return 1 ;;
				2) echolog -err "Neither nftables nor iptables not found."; return 1 ;;
				3) echolog -err "Found iptables but utility 'ipset' not found."; return 1
			esac
		fi
	}
	:
}

try_read_crontab() {
	crontab -u root -l 1>/dev/null 2>/dev/null
}

# returns 0 if crontab is readable and cron or crond process is running, 1 otherwise
# sets $cron_reboot if above conditions are satisfied and cron is not implemented via the busybox binary
check_cron() {
	check_cron_path() {
		cron_rl_path="$(ls -l "$1" 2>/dev/null)" || {
			debugprint "Path '$1' not found"
			return 1
		}
		debugprint "check_cron: Found real path: '/${cron_rl_path#*/}'."
		# check for busybox cron
		case "$cron_rl_path" in
			*busybox*)
				debugprint "Detected Busybox cron."
				;;
			*)
				debugprint "Detected non-Busybox cron."
				cron_reboot=1
		esac
		[ "$force_cron_persist" = true ] && {
			debugprint "\$force_cron_persist is true."
			cron_reboot=1
		}
		cron_rv=0
		:
	}

	try_pidof() {
		pidof "$1" 1>/dev/null && cron_path="$(command -v "$1")"
	}

	try_pgrep() {
		cron_path="$(pgrep -af "/$1" | awk "BEGIN{rv=1} \$2 ~ /\/${1}\$/ {print \$2; rv=0; exit} END{exit rv}")"
	}

	debugprint "check_cron: \$no_persist is '$no_persist'. \$cron_rv is '$cron_rv'."
	[ "$cron_rv" = 0 ] && return 0

	unset cron_reboot cron_path
	export cron_reboot cron_rv=1

	# check for crontab command
	checkutil crontab || {
		debugprint "check_cron: crontab command not found."
		cron_rv=3
		return 3
	}

	# check reading crontab
	try_read_crontab || {
		debugprint "check_cron: $FAIL read crontab."
		cron_rv=2
		return 2
	}

	# check for cron or crond in running processes
	for try_cmd in try_pidof try_pgrep; do
		try_cmd_n="${try_cmd#try_}"
		debugprint "check_cron: Trying with '${try_cmd_n}'..."
		for cron_cmd in crond fcron cron; do
			debugprint "Checking '$cron_cmd'"
			if $try_cmd "$cron_cmd"; then
				debugprint "${try_cmd_n} found '$cron_cmd', path: '$cron_path'"
				check_cron_path "$cron_path"
				case $? in
					0) break 2 ;;
					1) continue
				esac
			else
				debugprint "${try_cmd_n} didn't find '$cron_cmd'"
				continue
			fi
		done
	done

	debugprint "check_cron: returning '$cron_rv'"
	return "$cron_rv"
}

# checks if the cron service is running and if it supports features required by the config
# if cron service is not running, implements dialog with the user and optional automatic correction
check_cron_compat() {
	unset no_cr_persist cr_p1 cr_p2
	[ ! "$_OWRTFW" ] && { cr_p1="s '-n true'"; cr_p2="persistence and "; }
	[ "$no_persist" = true ] || [ "$_OWRTFW" ] && no_cr_persist=1
	if [ "$schedule" != disable ] || [ ! "$no_cr_persist" ] ; then
		i=0
		while [ $i -le 1 ]; do
			i=$((i+1))
			# check if cron is running
			check_cron && {
				[ $i = 2 ] && {
					OK
					printf '%s\n%s\n%s' "Please restart the device after completing setup." \
						"Then run '$p_name configure' and $p_name will check the cron service again." \
						"Press Enter to continue "
					read -r dummy
				}
				break
			}
			[ $i = 2 ] && { FAIL; die; }
			case $cron_rv in
				1)
					cron_err_msg_1="cron is not running"
					cron_err_msg_2="The cron service needs to be enabled and started in order for ${cr_p2}automatic ip list updates to work"
					autosolution_msg="enable and start the cron service" ;;
				2)
					cron_err_msg_1="initial crontab file does not exist for user root"
					cron_err_msg_2="The initial crontab file must exist so geoip-shell can create cron jobs for ${cr_p2}automatic ip list updates"
					autosolution_msg="create the initial crontab file" ;;
				3)
					cron_err_msg_1="'crontab' utility not found. This usually means that cron is not installed."
					cron_err_msg_2="cron is required for ${cr_p2}automatic ip list updates"
			esac
			echo
			echolog -err "$cron_err_msg_1." "$cron_err_msg_2." \
				"If you want to use $p_name without ${cr_p2}automatic ip list updates," \
				"install/configure $p_name with option$cr_p1 '-s disable'."
			[ "$nointeract" ] && {
				[ ! "$_OWRTFW" ] && without_option=" without the option '-z'"
				echolog "Please run '$p_name configure'$without_option in order to have $p_name enable the cron service for you."
				die
			}
			[ "$cron_rv" = 3 ] && { echolog "Please install cron, then run '$p_name configure'."; die; }

			printf '\n%s\n' "Would you like $p_name to $autosolution_msg? [y|n]."
			pick_opt "y|n"
			[ "$REPLY" = n ] && die

			# if reading crontab fails, try to create an empty crontab
			try_read_crontab || {
				printf '\n%s' "Attempting to create a new crontab file for root... "
				printf '' | crontab -u root - || { FAIL; die "command \"printf '' | crontab -u root -\" returned error code $?."; }
				try_read_crontab || { FAIL; die "Issued crontab file creation command, still can not read crontab."; }
				OK
				if check_cron; then
					break
				else
					i=0
					continue
				fi
			}

			# try to enable and start cron service
			printf '\n%s' "Attempting to enable and start cron... "
			debugprint "check_cron_compat: initsys is '$initsys'"
			for cron_cmd in crond cron cronie fcron dcron; do
				debugprint "check_cron_compat: trying '$cron_cmd'"
				case "$initsys" in
					systemd) systemctl status $cron_cmd; [ $? = 4 ] && continue
							systemctl is-enabled "$cron_cmd" || systemctl enable "$cron_cmd"
							systemctl start "$cron_cmd" ;;
					sysvinit) checkutil update-rc.d && {
								update-rc.d $cron_cmd enable
								service $cron_cmd start; }
							checkutil chkconfig && {
								chkconfig $cron_cmd on
								service $cron_cmd start; } ;;
					upstart) rm -f "/etc/init/$cron_cmd.override" ;;
					openrc) rc-update add $cron_cmd default || continue
				esac

				[ -f "/etc/init.d/$cron_cmd" ] && {
					/etc/init.d/$cron_cmd enable
					/etc/init.d/$cron_cmd start
				}
				check_cron && break
			done 2>&1 |
			if [ -n "$debugmode" ]; then cat 1>&2; else cat 1>/dev/null; fi
		done

		[ ! "$cron_reboot" ] && [ "$no_persist" != true ] && [ ! "$_OWRTFW" ] && {
			echolog -err "Detected Busybox cron service. cron-based persistence may not work with Busybox cron on this device." \
			"If you want to use $p_name without persistence support, run '$p_name configure -n true'." \
			"If you want to force cron-based persistence support, run '$p_name configure -n false -P true'." \
			"Reboot after installation and run 'geoip-shell status' to verify that persistence is working."
			return 1
		}
	fi
	:
}

OK() { printf '%s\n' "${green}Ok${n_c}."; }
FAIL() { printf '%s\n' "${red}Failed${n_c}." >&2; }

mk_lock() {
	[ "$1" != '-f' ] && check_lock
	[ "$lock_file" ] && echo "$$" > "$lock_file" || die "$FAIL set lock '$lock_file'"
	nodie=1
	die_unlock=1
}

rm_lock() {
	[ -f "$lock_file" ] && { rm -f "$lock_file"; unset nodie die_unlock; }
}

check_lock() {
	checkvars lock_file
	[ ! -f "$lock_file" ] && return 0
	read -r used_pid < "$lock_file"
	case "$used_pid" in
		''|*![0-9]*) echolog -err "Lock file '$lock_file' is empty or contains unexpected string." ;;
		*) kill -0 "$used_pid" 2>/dev/null &&
			die 0 "$p_name (PID $used_pid) is doing something in the background. Refusing to open another instance."
	esac
	echolog "Removing stale lock file ${lock_file}."
	rm_lock
	return 0
}

# 1 - input ip's/subnets
# 2 - output via return code (0: all valid; 1: 1 or more invalid)
# if a subnet detected in ips of a particular family, sets ipset_type to 'net:', otherwise to 'ip:'
# expects the $family var to be set
validate_ip() {
	[ ! "$1" ] && { echolog -err "validate_ip: received an empty string."; return 1; }
	ipset_type=ip; family="$2"; o_ips=
	sp2nl i_ips "$1"
	case "$family" in
		inet|ipv4) family=ipv4 ip_len=32 ;;
		inet6|ipv6) family=ipv6 ip_len=128 ;;
		*) echolog -err "Invalid family '$family'."; return 1
	esac
	eval "ip_regex=\"\$${family}_regex\""

	newifs "$_nl"
	for i_ip in $i_ips; do
		case "$i_ip" in */*)
			ipset_type=net
			_mb="${i_ip#*/}"
			case "$_mb" in ''|*[!0-9]*)
				echolog -err "Invalid mask bits '$_mb' in subnet '$i_ip'."; oldifs; return 1; esac
			i_ip="${i_ip%%/*}"
			case $(( (_mb<8) | (_mb>ip_len) )) in 1) echolog -err "Invalid $family mask bits '$_mb'."; oldifs; return 1; esac
		esac

		ip route get "$i_ip" 1>/dev/null 2>/dev/null
		case $? in 0|2) ;; *) echolog -err "ip address '$i_ip' failed kernel validation."; oldifs; return 1; esac
		o_ips="$o_ips$i_ip$_nl"
	done
	oldifs
	printf '%s\n' "${o_ips%"$_nl"}" | grep -vE "^$ip_regex$" > /dev/null
	[ $? != 1 ] && { echolog -err "'$i_ips' failed regex validation."; return 1; }
	:
}

# Get counters from existing rules and set variables
get_counters() {
	[ "$counters_set" ] && return 0
	unset counter_strings ipt_save_ok
	export counters_set

	case "$_fw_backend" in
		ipt) get_counters_ipt ;;
		nft) get_counters_nft
	esac && [ "$counter_strings" ] && export_conf=1 nodie=1 get_config_vars -v counter_strings && counters_set=1
	:
}

# sleeps for 0.1s on systems which support this, or 1s on systems which don't
unisleep() {
	sleep 0.1 2>/dev/null || sleep 1
}

valid_sources="ripe ipdeny"
valid_families="ipv4 ipv6"

ripe_url_stats="ftp.ripe.net/pub/stats"
ripe_url_api="stat.ripe.net/data/country-resource-list/data.json?"
ipdeny_ipv4_url="www.ipdeny.com/ipblocks/data/aggregated"
ipdeny_ipv6_url="www.ipdeny.com/ipv6/ipaddresses/aggregated"

# set some vars for debug and logging
: "${me:="${0##*/}"}"
me_short="${me#"${p_name}-"}"
me_short="${me_short%.sh}"
p_name_cap=GEOIP-SHELL

# vars for common usage() functions
sp8="        "
sp16="$sp8$sp8"
srcs_syn="<ripe|ipdeny>"
direction_syn="<inbound|outbound>"
direction_usage="direction (inbound|outbound). Only valid for actions add|remove and in combination with the '-l' option."
list_ids_usage="iplist id's in the format <country_code>_<family> (if specifying multiple list id's, use double quotes)"
nointeract_usage="Non-interactive setup. Will not ask any questions."

# ip regex
export ipv4_regex='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])' \
	ipv6_regex='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}' \
	maskbits_regex_ipv4='(3[0-2]|([1-2][0-9])|[6-9])' \
	maskbits_regex_ipv6='(12[0-8]|((1[0-1]|[1-9])[0-9])|[6-9])'
export subnet_regex_ipv4="${ipv4_regex}/${maskbits_regex_ipv4}" \
	subnet_regex_ipv6="${ipv6_regex}/${maskbits_regex_ipv6}"\
	inbound_geochain="${p_name_cap}_IN" outbound_geochain="${p_name_cap}_OUT" \
	inbound_dir_short=in outbound_dir_short=out

export fetch_res_file="/tmp/${p_name}-fetch-res"

blanks="[[:blank:]][[:blank:]]*"

set -f

[ -z "$geotag" ] && {
	set_ansi
	export WARN="${yellow}Warning${n_c}:" ERR="${red}Error${n_c}:" FAIL="${red}Failed${n_c} to" IFS="$default_IFS"
	[ "$conf_file" ] && [ -s "$conf_file" ] && [ "$root_ok" ] && {
		getconfig datadir
		export datadir status_file="$datadir/status" counters_file="$datadir/counters"
	}
	export geotag="$p_name"
}

:
