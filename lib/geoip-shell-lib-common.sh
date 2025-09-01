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
		printf %s "${yellow}Started *$blue$me_short_cap$yellow* with args: "
		newifs "$delim" dbn
		for arg in $_args; do printf %s "'$arg' "; done
		printf '%s\n' "${n_c}"
	} >&2
	oldifs dbn
}

debugexitmsg() {
	[ ! "$debugmode" ] || [ ! "$me_short" ] && return 0
	toupper me_short_cap "$me_short"
	printf '%s\n' "${yellow}Back to *$blue$me_short_cap$yellow*...${n_c}" >&2
}
#@

printf_s() {
	printf %s "$1"
	case "$debugmode" in '') ;; *) echo >&2; esac
}

is_dir_empty() {
	[ "$1" ] && [ -d "$1" ] || return 0
	{ find "$1" | head -n2 | grep -v "^$1\$"; } 1>/dev/null 2>/dev/null && return 1
	:
}

rm_dir_if_empty() {
	[ "$1" ] && [ -d "$1" ] || return 0
	is_dir_empty "$1" &&
	{
		printf %s "Deleting directory '$1'... "
		rm -rf "$1" || { echolog -err "$FAIL delete directory '$1'."; return 1; }
		OK
	}
	:
}

dir_mk() {
	dmk_nolog=
	[ "$1" = '-n' ] && { dmk_nolog=1; shift; }
	[ ! "$1" ] && die "dir_mk: received empty path."
	[ -d "$1" ] && return 0
	[ -z "$dmk_nolog" ] && printf %s "Creating directory '$1'... "
	mkdir -p "$1" && {
		[ -n "$inst_root_gs" ] || [ ! "$root_ok" ] || { chmod -R 600 "$1" && chown -R root:root "$1"; }
	} || { echolog -err "$FAIL create '$1'."; return 1; }
	[ -z "$dmk_nolog" ] && OK
	:
}

get_md5() {
	md5sum "$1" | cut -d' ' -f1
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
	[ "$manmode" = 1 ] && { rv=0; tip=" For usage, run '$me -h'."; }
	die $rv "$me needs to be run as root.$tip"
}

extra_args() {
	[ "$*" ] && {
		# [ "$debugmode" ] && {
		# 	printf %s "${yellow}Debug:${n_c} Args: "
		# 	newifs "$delim" ea
		# 	for arg in $_args; do printf %s "'$arg' "; done
		# 	printf '%s\n' "${n_c}"
		# 	oldifs ea
		# } >&2

		die "Invalid arguments. First unexpected argument: '$1'."
	}
}

checkutil() {
	hash "$1" 2>/dev/null
}

checkvars() {
	for chkvar; do
		eval "[ -n \"\$$chkvar\" ]" || {
			logger -s -t "${me:-"$p_name"}" -p user.err "Error: The '\$$chkvar' variable is unset."
			exit 1
		}
	done
}

check_custom_script() {
	[ -f "$1" ] || { echolog -err "Custom script '$1' not found."; return 1; }
	ccs_res="$(
		. "$1" 1>/dev/null
		custom_f_found=
		for r_func in gs_success gs_failure; do
			command -v "$r_func" 1>/dev/null && custom_f_found=1
		done
		[ -n "$custom_f_found" ] || {
			printf '%s\n' "Custom script '$1' must define functions 'gs_success' and/or 'gs_failure' but it defines neither."
			exit 1
		}
	)" && return 0
	[ -n "$ccs_res" ] && { echolog -err "$ccs_res"; return 1; }
	echolog -err "Failed to source custom script '$1'."
	return 1
}

unknownopt() {
	usage; die "Unknown option '-$OPTARG' or it requires an argument."
}

statustip() {
	printf '\n%s\n\n' "View geoblocking status with '${blue}${p_name} status${n_c}' (may require 'sudo')."
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
	wrong_opt() {
		printf '\n%s' "Please enter "
		printf '%s\n' "$1" | sed "s/^/\'/;s/$/\'./;s/|/\' or \'/g"
		printf '\n'
	}

	while :; do
		printf %s "$1: "
		read -r REPLY
		is_alphanum "$REPLY" || { wrong_opt "$1"; continue; }
		tolower REPLY
		eval "case \"$REPLY\" in
				$1) return ;;
				*) wrong_opt \"$1\"
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
	eval "$outvar_cc"='$conv_res'
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
	$use_shell "$script_to_call" "$@"
	call_rv=$?
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

# outputs args to stdout and writes them to syslog
# if one of the args is '-err' or '-warn' then redirect output to stderr
echolog() {
	write_entry() {
		el_msg="$(printf %s "$1" | awk '{gsub(/\033\[[0-9;]*m/,"")};1' ORS=' ')"
		[ -n "$daemon_mode" ] && date +"[%b %d %Y %H:%M:%S] ${el_msg}" >> "${GS_LOG_FILE}"
		logger -t "$me" -p "user.$2" "$el_msg"
	}

	unset msg_args __nl msg_prefix o_nolog el_msg

	highlight="$blue"; err_l=info
	for arg in "$@"; do
		case "$arg" in
			-err) highlight="$red"; err_l=err; msg_prefix="$ERR " ;;
			-warn) highlight="$yellow"; err_l=warn; msg_prefix="$WARN " ;;
			-nolog) o_nolog=1 ;;
			'') ;;
			*) msg_args="$msg_args$arg$delim"
		esac
	done

	# check for newline in the biginning of the line and strip it
	case "$msg_args" in "$_nl"*)
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
		}

		if [ ! "$nolog" ] && [ ! "$o_nolog" ]; then
			write_entry "$msg_prefix$arg" "$err_l" &
		fi
		unset __nl highlight msg_prefix err_l
	done
}

get_session_log() {
	i=1
	while [ $i -le 5 ] && ! cat "$GS_LOG_FILE" 2>/dev/null; do
		sleep 1 &
		wait $!
		i=$((i+1))
	done
}

die() {
	# if first arg is a number, assume it's the exit code
	case "$1" in
		''|*[!0-9]*) die_rv="1" ;;
		*) die_rv="$1"; shift
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

# converts unsigned integer to either [x|xK|xM|xB|xT] or [xB|xKiB|xMiB|xGiB|xTiB], depending on $2
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

# primitive alternative to grep, may not work correctly if too many lines are provided as input
# outputs only the 1st match
# return status is 0 for match, 1 for no match
# 1 - input
# 2 - leading '*' wildcard (if required, otherwise use empty string)
# 3 - filter string
# 4 - trailing '*' wildcard (if required, otherwise use empty string)
# 5 - optional var name for output
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
		conf_gac="$(grep -vE "^(${blank}*#.*\$|\$)" "$2")"
		[ "$2" = "$conf_file" ] && export main_config="$conf_gac"
	}
	eval "$1"='$conf_gac'
	:
}

# gets all config from file $1 or $conf_file if unsecified, and assigns to vars named same as keys in the file
# 1 - (optional) -v to load from variable $2
# 1 - (optional) path to config/status file
# if $export_conf is set, exports the vars
get_config_vars() {
	inval_e() {
		oldifs gcv
		echolog -err "Invalid entry '$entry' in $src_gcv."
		[ ! "$nodie" ] && die
	}

	unset entries_gcv _exp
	[ "$export_conf" ] && _exp="export "

	if [ "$1" = '-v' ]; then
		eval "entries_gcv=\"\$${2}\""
		[ "$entries_gcv" ] || return 1
		src_gcv="variable '$2'"
	else
		target_f_gcv="${1:-"$conf_file"}"
		src_gcv="file '$2'"
		getallconf entries_gcv "$target_f_gcv" || {
			echolog -err "$FAIL get config from '$target_f_gcv'."
			[ ! "$nodie" ] && die
			return 1
		}
	fi

	newifs "$_nl" gcv
	for entry in $entries_gcv; do
		case "$entry" in
			'') continue ;;
			*=*=*) { inval_e; return 1; } ;;
			*=*) ;;
			*) { inval_e; return 1; } ;;
		esac
		key_conf="${entry%=*}"
		! is_alphanum "$key_conf" || [ ${#key_conf} -gt 128 ] && { inval_e; return 1; }
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
				*) newconfig="'$newconfig$config_line$_nl'"
			esac"
	done
	oldifs sc
	newconfig="$newconfig$args_lines"
	# don't write to file if config didn't change
	[ -f "$target_file" ] && old_conf_exists=1 || old_conf_exists=
	if [ ! "$old_conf_exists" ] || ! compare_file2str "$target_file" "$newconfig"; then
		[ "$target_file" = "$conf_file" ] && printf %s "Updating the config file... " >&2
		printf %s "$newconfig" > "$target_file" || { sc_failed "$FAIL write to '$target_file'"; return 1; }
		[ "$target_file" = "$conf_file" ] && OK >&2
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
	setconfig $ALL_CONF_VARS
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
	$awk_cmd '
		NF==0{next}
		NR==FNR {A[$0];a=1;next}
		{if (!($0 in A)){r=1;exit}; B[$0];b=1;next}
		END{
			if(r==1){exit 1}
			if(!a&&!b){exit 0}
			if(!a||!b){exit 1}
			for (a in A) if (!(a in B)){exit 1}
			exit 0
		}
	' "$1" "$2"
}

# compares lines in files $1 and $2, regardless of order
# discards empty lines
# returns 0 for no diff, 1 for diff, 2 for error
compare_files() {
	[ -f "$1" ] && [ -f "$2" ] || { echolog -err "compare_files: file '$1' or '$2' does not exist."; return 2; }
	awk_cmp "$1" "$2"
}

# compares lines in file $1 and string $2, regardless of order
# discards empty lines
# returns 0 for no diff, 1 for diff, 2 for error
compare_file2str() {
	[ -f "$1" ] || { echolog -err "compare_file2str: file '$1' does not exist."; return 2; }
	printf '%s\n' "$2" | awk_cmp - "$1"
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
	:
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

# 1 - input delimiter
# 2 - output delimiter
# 3 - var name for output
# input via $4, if not specified then uses current value of $3
conv_delim() {
    out_del="$2"
    var_cd="$3"
    [ $# -ge 4 ] && _inp="$4" || eval "_inp=\"\$$3\""
    newifs "$1" cd
    set -- $_inp
    IFS="$out_del"
    eval "$var_cd"='$*'
    oldifs cd
}

# converts whitespace-separated list to newline-separated list
# 1 - var name for output
# input via $2, if not specified then uses current value of $1
sp2nl() {
	conv_delim ' ' "$_nl" "$@"
}

# converts newline-separated list to whitespace-separated list
# 1 - var name for output
# input via $2, if not specified then uses current value of $1
nl2sp() {
	conv_delim "$_nl" ' ' "$@"
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
		inbound) dir_cap=IN ;;
		outbound) dir_cap=OUT ;;
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

# sets $nft_present, $ipt_present, $ipset_present, $ipt_rules_present, $_fw_backend_def
detect_fw_backends() {
	ipt_present='' ipset_present='' nft_present='' ipt_rules_present='' _fw_backend_def=''

	echolog "${_nl}Detecting firewall backends..."

	check_fw_backend ipt 2>/dev/null
	case $? in
		0) ipt_present=1 ipset_present=1; echolog "Found iptables and the 'ipset' utility." ;;
		2) echolog "Did not find iptables." ;;
		3) ipt_present=1; echolog "Found iptables."
	esac

	if check_fw_backend nft 2>/dev/null; then
		nft_present=1
		echolog "Found nftables."
	else
		echolog "Did not find nftables."
	fi

	[ "${ipt_present}" ] && { iptables-save; ip6tables-save; } | grep '^-A[ \t]' 1>/dev/null &&
		{ ipt_rules_present=1; echolog "Found existing iptables rules"; }

	if [ "$ipt_present" ]; then
		if [ "$nft_present" ]; then
			_fw_backend_def=ask
		elif [ "$ipset_present" ]; then
			_fw_backend_def=ipt
		else
			echolog -err "Found iptables but required utility 'ipset' not found. Use your package manager to install it."
			return 1
		fi
	elif [ -n "$nft_present" ]; then
		_fw_backend_def=nft
	else
		echolog -err "Neither nftables nor iptables not found."
		return 1
	fi

	:
}

# return codes:
# 0 - backend found
# 1 - error
# 2 - main backend not found (for ipt, iptables not found)
# 3 - for ipt, ipset not found
check_fw_backend() {
	case "$1" in
		nft) check_deps nft || return 2 ;;
		ipt) check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore || return 2
			check_deps ipset || return 3 ;;
		*) echolog -err "Unsupported firewall backend '$1'."; return 1
	esac
}

ignore_allow() {
	inc_ia=0
	var1_ia="$1"
	eval "list1_ia=\"\${$var1_ia}\""
	eval "list2_ia=\"\${$2}\""
	res_ia="$list1_ia"
	for entry_ia in $list1_ia; do
		for f_ia in $families; do
			case "$entry_ia" in allow*"${f_ia}")
				case "$list2_ia" in *allow_"${f_ia}"*|*allow_"${3%bound}_${f_ia}"*)
					subtract_a_from_b "$entry_ia" "$res_ia" res_ia; continue 2
				esac ;;
			esac
		done
		inc_ia=1
	done
	eval "$var1_ia"='$res_ia'
	return $inc_ia
}

# checks current ipsets and firewall rules for geoip-shell
# returns a whitespace-delimited list of active IP lists
# (optional: 1 - '-f' to force re-read of the table - nft-specific)
# 1 - var name for output
# 2 - direction (inbound|outbound)
get_active_iplists() {
	force_read=
	[ "$1" = "-f" ] && { force_read="-f"; shift; }
	[ "$2" ] || die "get_active_iplists: direction not specified"
	gai_out_var="$1" direction="$2"
	eval "geomode=\"\$${direction}_geomode\" exp_iplists_gai=\"\$${direction}_iplists\""
	for family in $families; do
		case "$geomode" in
			whitelist)
				ipt_target=ACCEPT nft_verdict=accept
				exp_iplists_gai="${exp_iplists_gai} allow_$family"
				[ "$family" = ipv4 ] && exp_iplists_gai="${exp_iplists_gai} dhcp_ipv4" ;;
			blacklist)
				ipt_target=DROP nft_verdict=drop
				eval "[ \"\${trusted_$family}\" ]" && exp_iplists_gai="${exp_iplists_gai} allow_$family" ;;
			*) die "get_active_iplists: unexpected geoblocking mode '$geomode'."
		esac

		for iplist_type in allow block; do
			iplist_path="${local_iplists_dir}/local_${iplist_type}_${family}"

			[ -s "${iplist_path}.ip" ] || [ -s "${iplist_path}.net" ] &&
				exp_iplists_gai="${exp_iplists_gai} local_${iplist_type}_${family}"
		done

		[ "$2" = outbound ] && eval "[ \"\${source_ips_${family}}\" ]" &&
			exp_iplists_gai="${exp_iplists_gai} allow_$family"
	done

	ipset_iplists="$(get_ipsets | sed "s/${geotag}_//;s/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].*//;s/_4/_ipv4/;s/_6/_ipv6/")"
	fwrules_iplists="$(get_fwrules_iplists "$direction")"

	# debugprint "$_nl$2 ipset_iplists: ${_nl}$ipset_iplists${_nl}${_nl}fwrules_iplists: $_nl$fwrules_iplists"

	nl2sp ipset_iplists_sp "$ipset_iplists"
	nl2sp fwrules_iplists_sp "$fwrules_iplists"

	load_exclusions

	inc=0
	subtract_a_from_b "$ipset_iplists_sp" "$exp_iplists_gai" missing_ipsets ||
		ignore_allow missing_ipsets ipset_iplists_sp "$direction" ||
		subtract_a_from_b "$excl_file_lists" "$missing_ipsets" missing_ipsets || inc=1

	subtract_a_from_b "$exp_iplists_gai" "$fwrules_iplists_sp" unexpected_lists ||
		ignore_allow unexpected_lists exp_iplists_gai "$direction"|| inc=1

	subtract_a_from_b "$fwrules_iplists_sp" "$exp_iplists_gai" missing_lists ||
		ignore_allow missing_lists fwrules_iplists_sp "$direction" ||
		subtract_a_from_b "$excl_file_lists" "$missing_lists" missing_lists || inc=1

	get_intersection "$ipset_iplists" "$fwrules_iplists" active_iplists_nl "$_nl"
	nl2sp "$gai_out_var" "$active_iplists_nl"

	return $inc
}

# checks whether current ipsets and iptables rules match ones in the config file
check_lists_coherence() {
	_no_l="$nolog"

	no_reload_conf=
	for arg in "$@"; do
		case "$arg" in
			-n) nolog=1 ;;
			-nr) no_reload_conf=1 ;;
		esac
	done

	debugprint "Verifying IP lists coherence..."

	[ -z "$no_reload_conf" ] && {
		main_config=
		nodie=1 get_config_vars || { r_no_l; return 1; }
	}

	iplists_incoherent=
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue

		getconfig exp_iplists "${direction}_iplists"
		for family in $families; do
			[ "$direction" = outbound ] && eval "[ \"\$source_ips_${family}\" ]" && exp_iplists="${exp_iplists} allow_$family"
			case "$geomode" in
				whitelist)
					exp_iplists="${exp_iplists} allow_$family"
					[ "$family" = ipv4 ] && exp_iplists="${exp_iplists} dhcp_ipv4" ;;
				blacklist) eval "[ \"\${trusted_$family}\" ]" && exp_iplists="${exp_iplists} allow_$family" ;;
				*) r_no_l; echolog -err "Unexpected geoblocking mode '$geomode'!"; return 1
			esac

			for iplist_type in allow block; do
				iplist_path="${local_iplists_dir}/local_${iplist_type}_${family}"
				[ -s "${iplist_path}.ip" ] || [ -s "${iplist_path}.net" ] &&
					exp_iplists="${exp_iplists} local_${iplist_type}_${family}"
			done
		done


		eval "${direction}_exp_iplists"='$exp_iplists'

		get_active_iplists -f "${direction}_active_lists" "$direction"; get_a_i_rv=$?
		[ "$get_a_i_rv" != 0 ] &&
		{
			iplists_incoherent=1
			eval "active_lists=\"\$${direction}_active_lists\""
			report_incoherence "$direction"
			debugprint "$direction $geomode expected IP lists: '$exp_iplists'"
			debugprint "Firewall IP lists: '$active_lists'"
			debugprint "ipsets: $ipset_iplists_sp"
		}
	done

	all_exp_iplists="$inbound_exp_iplists $outbound_exp_iplists"
	subtract_a_from_b "$all_exp_iplists" "$ipset_iplists_sp" unexpected_ipsets ||
		ignore_allow unexpected_ipsets all_exp_iplists "$direction"

	[ "$unexpected_ipsets" ] && {
		echolog -warn "Unexpected ipsets detected: '$unexpected_ipsets'."
		iplists_incoherent=1
		debugprint "all_exp_iplists: '$all_exp_iplists'${_nl}ipset_iplists: '$ipset_iplists_sp'"
	}

	r_no_l
	[ "$iplists_incoherent" ] && return 1
	debugprint "Successfully verified IP lists coherence."
	:
}

# 1 - direction (inbound|outbound)
report_incoherence() {
	[ "$1" ] || die "report_incoherence: direction not specified"
	echolog -warn "${_nl}Discrepancy detected between $1 geoblocking state and the config file."
	for opt_ri in unexpected missing; do
		eval "[ \"\$${opt_ri}_lists\" ] && echolog -warn \"$opt_ri IP lists in the firewall: '\$${opt_ri}_lists'\""
		eval "[ \"\$${opt_ri}_ipsets\" ] && echolog -warn \"$opt_ri IP sets in the firewall: '\$${opt_ri}_ipsets'\""
	done
}

load_exclusions() {
	[ -n "$excl_file_lists" ] && return 0
	[ -s "$excl_file" ] &&
		nodie=1 getconfig excl_file_lists exclude_iplists "$excl_file" &&
			export excl_file_lists
}

separate_excl_iplists() {
	unset _excl_lists _ok_lists
	load_exclusions

	for _list_id in $2; do
		case "$_list_id" in
			*_*) toupper cc_up "${_list_id%%_*}"; tolower fml_lo "_${_list_id#*_}" ;;
			*) echolog -err "invalid list ID '$_list_id'."; return 1
		esac
		_list_id="$cc_up$fml_lo"
		case "$excl_file_lists" in *"$_list_id"*)
			add2list _excl_lists "$_list_id"
			continue
		esac
		add2list _ok_lists "$_list_id"
	done

	[ "$_excl_lists" ] && {
		fast_el_cnt "$_excl_lists" ' ' excl_cnt
		excl_list_pr="list" excl_verb="is"
		[ "$excl_cnt" != 1 ] && excl_list_pr="lists" excl_verb="are"
		echolog -nolog "${yellow}NOTE:${n_c} Ip $excl_list_pr '$_excl_lists' $excl_verb in the exclusions file, skipping."
	}
	eval "$1=\"$_ok_lists\""
	:
}

# validate reg. name or country code against cca2.list, translate reg. name to country code
# 1 - var name for output
# 2 - input
# return codes:
# 0 - country code
# 1 - error
# 2 - registry name
# 3 - neither
normalize_ccode() {
	cca2_path="$conf_dir/cca2.list" nc_in="$2"
	if [ -z "$ccode_list" ]; then
		[ -s "$cca2_path" ] || cca2_path="$script_dir/cca2.list"
		[ -s "$cca2_path" ] || { echolog -err "File 'cca2.list' does not exist or is empty."; return 1; }
		getstatus "$cca2_path" || return 1
		RIPE="$RIPENCC"
		export RIPE ARIN APNIC AFRINIC LACNIC \
			ccode_list="$RIPE$ARIN$APNIC$AFRINIC$LACNIC"
	fi

	toupper nc_in
	case "$nc_in" in ''|*" "*) return 3; esac
	# shellcheck disable=SC2194
	case " RIPE ARIN APNIC AFRINIC LACNIC " in *" $nc_in "*)
		eval "nc_out=\"\${$nc_in% }\"
			$1=\"\${nc_out# }\""
		return 2
	esac

	case "$ccode_list" in
		'') echolog -err "Failed to load country codes list from '$cca2_path'."; return 1 ;;
		*" $nc_in "*) eval "$1=\"$nc_in\""; return 0 ;;
		*) return 3
	esac
	:
}

# detects all network interfaces known to the kernel, except the loopback interface
# returns 1 if nothing detected
detect_ifaces() {
	[ -r "/proc/net/dev" ] && sed -n '/^[[:space:]]*[^[:space:]]*:/{s/^[[:space:]]*//;s/:.*//p}' < /proc/net/dev | grep -vx 'lo'
}

try_read_crontab() {
	crontab -u root -l 1>/dev/null 2>/dev/null
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
	[ -f "$lock_file" ] && { unset nodie die_unlock; rm -f "$lock_file" || return 1; }
	:
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
	:
}

# 1 - family (ipv4|ipv6)
# 2 - newline-separated domains
# shellcheck disable=SC2329
resolve_domain_ips() {
	res_host() { host -t "$2" "$1" | awk "/has${blanks}(IPv6${blanks})?address${blanks}${regex}(${blank}|$)/{print \$NF}"; }
	res_nslookup() { nslookup -q="$2" "$1" | awk "/^Address:${blanks}${regex}(${blank}|$)/{print \$2}"; }
	res_dig() { dig "$1" "$2" | sed -n "/^;;${blanks}ANSWER SECTION/{n;:1 /^$/q;/^\;\;/q;s/^.*${blanks}//;p;n;b1;}"; }
	res_ping() { ipv=4; [ "$2" = AAAA ] && ipv=6; ping -c 1 -w 1  "-$ipv" "$1" | grep -m1 -oE "\($regex\)" | sed 's/(//;s/)//'; }

	printf_s "Resolving $1 addresses for domains: $(printf %s "$2" | tr '\n' ' ' | sed "s/^${blanks}//;s/${blanks}$//;")... " >&2

	A=A
	[ "$1" = ipv6 ] && A=AAAA
	eval "regex=\"\$${1}_regex\""

	req_ips_cnt="$(printf %s "$2" | wc -w)"

	if checkutil host; then
		ns_cmd=res_host
	elif checkutil nslookup; then
		ns_cmd=res_nslookup
	elif checkutil dig; then
		ns_cmd=res_dig
	elif checkutil ping; then
		ns_cmd=res_ping
	else
		echolog -err "No available supported utility to resolve domain names to IPs. Supported utilities: host, nslookup, dig, ping."
		return 1
	fi

	dom_ips="$(
		IFS="${_nl}"
		for dom in $2; do
			$ns_cmd "$dom" "$A"
		done
	)"

	rdi_ips_cnt="$(printf %s "$dom_ips" | wc -w)"
	[ "$debugmode" ] && debugprint "${ns_cmd#res_} resolved $rdi_ips_cnt $1 IPs for domains '$(printf %s "$2" | tr '\n' ' ')': $(printf %s "$dom_ips" | tr '\n' ' ')"
	[ "$rdi_ips_cnt" -ge "$req_ips_cnt" ] || { FAIL >&2; return 1; }
	OK >&2
	printf '%s\n' "$dom_ips"
	:
}

# outpus newline-separated list of ips
# 1 - family
resolve_geosource_ips() {
	case "$geosource" in
		ripe) src_domains="${ripe_url_api%%/*}${_nl}${ripe_url_stats%%/*}" ;;
		ipdeny) src_domains="${ipdeny_ipv4_url%%/*}" ;;
		maxmind) src_domains="download.maxmind.com${_nl}www.maxmind.com${_nl}mm-prod-geoip-databases.a2649acb697e2c09b632799562c076f2.r2.cloudflarestorage.com"
	esac
	resolve_domain_ips "$family" "$src_domains"
}

setup_maxmind() {
	checkutil unzip || { echolog -err "MaxMind source requires the 'unzip' utility but it is not found."; return 1; }
	checkutil gzip && checkutil gunzip ||
		{ echolog -err "MaxMind source requires the 'gzip' and 'gunzip' utilities but either or both are not found."; return 1; }

	[ "$mm_acc_id" ] && [ "$mm_acc_license" ] ||
		printf '%s\n' "MaxMind requires a license. You will need account ID and license key."
	printf '%s\n' "Which MaxMind license do you have: [f]ree (for GeoLite2) or [p]aid (for GeoIP2)? Or type in [a] to abort."
	pick_opt "f|p|a"
	case "$REPLY" in
		f) export mm_license_type=free ;;
		p) export mm_license_type=paid ;;
		a) return 1
	esac

	curr_mm_acc_msg=
	[ "$mm_acc_id" ] && curr_mm_acc_msg=" or press Enter to use current account ID '$mm_acc_id'"
	while :; do
		printf '%s\n' "Type in MaxMind account ID (numerical)${curr_mm_acc_msg}: "
		read -r REPLY
		case "$REPLY" in
			'')
				[ ! "$mm_acc_id" ] && { printf '%s\n' "Invalid account ID '$REPLY'."; continue; }
				break ;;
			*[!0-9]*) printf '%s\n' "Invalid account ID '$REPLY'."; continue
		esac
		export mm_acc_id="$REPLY"
		break
	done

	curr_mm_license_msg=
	[ "$mm_license_key" ] && curr_mm_license_msg=" or press Enter to use current license key '$mm_license_key'"
	while :; do
		printf '%s\n' "Type in MaxMind License key${curr_mm_license_msg}: "
		read -r REPLY
		case "$REPLY" in
			'')
				[ "$mm_license_key" ] || { printf '%s\n' "Invalid license key '$REPLY'."; continue; }
				break ;;
			*[!a-zA-Z0-9_]*) printf '%s\n' "Invalid license key '$REPLY'."; continue
		esac
		export mm_license_key="$REPLY"
		break
	done
	:
}

# 1 - input IPs/subnets
# 2 - output via return code (0: all valid; 1: 1 or more invalid)
# if a subnet detected in ips of a particular family, sets ipset_type to 'net', otherwise to 'ip'
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
		case $? in 0|2) ;; *) echolog -err "IP address '$i_ip' failed kernel validation."; oldifs; return 1; esac
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
	unset counter_strings
	export counters_set

	case "$_fw_backend" in
		ipt) get_counters_ipt ;;
		nft) get_counters_nft
	esac && [ "$counter_strings" ] && export_conf=1 nodie=1 get_config_vars -v counter_strings && counters_set=1
	# debugprint "counter strings:${_nl}$counter_strings"
	:
}

# sleeps for 0.1s on systems which support this, or 1s on systems which don't
unisleep() {
	sleep 0.1 2>/dev/null || sleep 1
}

# config variables
ALL_CONF_VARS="inbound_tcp_ports inbound_udp_ports outbound_tcp_ports outbound_udp_ports \
	inbound_geomode outbound_geomode inbound_iplists outbound_iplists \
	custom_script geosource lan_ips_ipv4 lan_ips_ipv6 autodetect trusted_ipv4 trusted_ipv6 \
	nft_perf ifaces datadir local_iplists_dir nobackup no_persist noblock http user_ccode schedule families \
	_fw_backend max_attempts reboot_sleep force_cron_persist source_ips_ipv4 source_ips_ipv6 source_ips_policy \
	mm_license_type mm_acc_id mm_license_key keep_mm_db"

valid_sources="ripe ipdeny maxmind"
valid_families="ipv4 ipv6"

ripe_url_stats="ftp.ripe.net/pub/stats"
ripe_url_api="stat.ripe.net/data/country-resource-list/data.json?"
ipdeny_ipv4_url="www.ipdeny.com/ipblocks/data/aggregated"
ipdeny_ipv6_url="www.ipdeny.com/ipv6/ipaddresses/aggregated"
maxmind_url="download.maxmind.com/geoip/databases"

# set some vars for debug and logging
: "${me:="${0##*/}"}"
me_short="${me#"${p_name}-"}"
me_short="${me_short%.sh}"
p_name_cap=GEOIP-SHELL

# vars for common usage() functions
sp8="        "
sp16="$sp8$sp8"
srcs_syn="<ripe|ipdeny|maxmind>"
direction_syn="<inbound|outbound>"
direction_usage="direction (inbound|outbound). Only valid for actions add|remove and in combination with the '-l' option."
list_ids_usage="iplist IDs in the format <country_code>_<family> (if specifying multiple list IDs, use double quotes)"
nointeract_usage="Non-interactive setup. Will not ask any questions."

# IP regex
export ipv4_regex='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])' \
	ipv6_regex='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}' \
	maskbits_regex_ipv4='(3[0-2]|([1-2][0-9])|[6-9])' \
	maskbits_regex_ipv6='(12[0-8]|((1[0-1]|[1-9])[0-9])|[6-9])'
export subnet_regex_ipv4="${ipv4_regex}/${maskbits_regex_ipv4}" \
	subnet_regex_ipv6="${ipv6_regex}/${maskbits_regex_ipv6}"\
	inbound_geochain="${p_name_cap}_IN" outbound_geochain="${p_name_cap}_OUT" \
	inbound_dir_short=in outbound_dir_short=out

export fetch_res_file="/tmp/${p_name}-fetch-res"
export staging_local_dir="/tmp/${p-name}-staging"
export GS_LOG_FILE="/tmp/${p-name}-log"

blank="[ 	]"
notblank="[^ 	]"
blanks="${blank}${blank}*"
export _nl='
'
export default_IFS="	 $_nl"
export IFS="$default_IFS"

set -f

[ -z "$geotag" ] && {
	set_ansi
	export WARN="${yellow}Warning${n_c}:" ERR="${red}Error${n_c}:" FAIL="${red}Failed${n_c} to"

	if checkutil gawk; then
		awk_cmd="gawk"
	else
		awk_cmd="awk"
	fi
	export awk_cmd

	[ "$conf_file" ] && [ -s "$conf_file" ] && [ "$root_ok" ] && {
		getconfig datadir
		export datadir status_file="$datadir/status"
	}

	export geotag="$p_name"
}

:
