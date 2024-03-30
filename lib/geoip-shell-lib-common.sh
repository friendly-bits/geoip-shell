#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2155,SC2018,SC2019,SC2012,SC2254,SC2086,SC2015,SC2046,SC1090,SC2181,SC3040,SC2016

# geoip-shell-lib-common.sh

# Library of common functions and variables for geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


### Functions

setdebug() {
	export debugmode="${debugmode_arg:-$debugmode}"
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
	[ "$manualmode" ] && { rv=0; tip=" For usage, run '$me -h'."; } || rv=1
	die $rv "$me needs to be run as root.$tip"
}

extra_args() {
	[ "$*" ] && die "Invalid arguments. First unexpected argument: '$1'."
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
	printf '\n%s\n' "Ip lists in the final $geomode: '${blue}$verified_lists${n_c}'."
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
	toupper U_1 "$1"
	_opts="$1|$U_1"
	while true; do
		printf %s "$1: "
		read -r REPLY
		is_alphanum "$REPLY" || { printf '\n%s\n\n' "Please enter $1"; continue; }
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
	[ "$missing_deps" ] && { echolog -err "missing dependencies: ${missing_deps%, }"; return 1; }
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

	[ "$die_args" ] && {
		newifs "$delim" die
		for arg in $die_args; do
			echolog "$msg_type" "$arg"
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
		conf_gac="$(cat "$2")"
		[ "$2" = "$conf_file" ] && export main_config="$conf_gac"
	}
	eval "$1=\"$conf_gac\""
	:
}

# gets all config from file $1 or $conf_file if unsecified, and assigns to vars named same as keys in the file
get_config_vars() {
	inval_e() {
		echolog -err "Invalid entry '$entry' in config."
		[ ! "$nodie" ] && die
	}

	target_f_gcv="${1:-"$conf_file"}"

	getallconf all_config "$target_f_gcv" || {
		echolog -err "$FAIL get config from '$target_f_gcv'."
		[ ! "$nodie" ] && die
		return 1
	}

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
		eval "$key_conf"='${entry#${key_conf}=}'
	done
	oldifs gcv
	:
}

# Accepts key=value pairs and writes them to (or replaces in) config file specified in global variable $conf_file
# if no '=' included, gets value of var with named the same as the key
# if one of the value pairs is "target_file=[file]" then writes to $file instead
setconfig() {
	unset args_lines args_target_file keys_test_str newconfig
	IFS_OLD_sc="$IFS"
	IFS="$_nl"
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
				*) newconfig=\"$newconfig$config_line$_nl\"
			esac"
	done
	oldifs sc

	newconfig="$newconfig$args_lines"
	[ -f "$target_file" ] && compare_file2str "$target_file" "$newconfig" && return 0
	printf %s "$newconfig" > "$target_file" || { sc_failed "$FAIL write to '$target_file'"; return 1; }
	[ "$target_file" = "$conf_file" ] && export main_config="$newconfig"
	:
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
	[ ! -d "${target_file%/*}" ] && mkdir -p "${target_file%/*}"
	[ ! -f "$target_file" ] && touch "$target_file"
	setconfig target_file "$@"
}

awk_cmp() {
	awk 'NF==0{next} NR==FNR {A[$0]=1;a++;next} {b++} !A[$0]{r=1;exit} END{if(!a&&!b){exit 0};if(!a||!b){exit 1};exit r}' r=0 "$1" "$2"
}

# compares lines in files $1 and $2, regardless of order
# discards empty lines
# returns 0 for no diff, 1 for diff, 2 for error
compare_files() {
	[ -f "$1" ] && [ -f "$2" ] || { echolog -err "compare_conf: file '$1' or '$2' does not exist."; return 2; }
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
	eval "$1=\"\${$1}$a2l_fs$2\"; $1=\"\${$1#$a2l_fs}\""
	return 0
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
	subtract_a_from_b "$1" "$2" "_diff1" "$_fs_gd"
	subtract_a_from_b "$2" "$1" "_diff2" "$_fs_gd"
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
		trimsp arg
		[ "$arg" ] && _args="$_args$arg$delim"
	done
}

# restores the nolog var prev value
r_no_l() { nolog="$_no_l"; }

# checks current ipsets and firewall rules for geoip-shell
# returns a whitespace-delimited list of active ip lists
# (optional: 1 - '-f' to force re-read of the table - nft-specific)
# 1 - var name for output
get_active_iplists() {
	unset force_read iplists_incoherent
	[ "$1" = "-f" ] && { force_read="-f"; shift; }
	case "$geomode" in
		whitelist) ipt_target=ACCEPT nft_verdict=accept ;;
		blacklist) ipt_target=DROP nft_verdict=drop ;;
		*) die "get_active_iplists: unexpected geoip mode '$geomode'."
	esac

	ipset_iplists="$(get_ipset_iplists)"
	fwrules_iplists="$(get_fwrules_iplists)"

	# debugprint "ipset_iplists: '$ipset_iplists', fwrules_iplists: '$fwrules_iplists'"

	get_difference "$ipset_iplists" "$fwrules_iplists" lists_difference "$_nl"
	get_intersection "$ipset_iplists" "$fwrules_iplists" "active_iplists_nl" "$_nl"
	nl2sp "$1" "$active_iplists_nl"

	case "$lists_difference" in
		'') return 0 ;;
		*) iplists_incoherent=1; return 1
	esac
}

# checks whether current ipsets and iptables rules match ones in the config file
check_lists_coherence() {
	_no_l="$nolog"
	[ "$1" = '-n' ] && nolog=1
	debugprint "Verifying ip lists coherence..."

	# check for a valid list type
	case "$geomode" in whitelist|blacklist) ;; *) r_no_l; echolog -err "Unexpected geoip mode '$geomode'!"; return 1; esac

	unset unexp_lists missing_lists
	getconfig iplists

	get_active_iplists -f active_lists || {
		nl2sp ips_l_str "$ipset_iplists"; nl2sp ipr_l_str "$fwrules_iplists"
		echolog -warn "ip sets ($ips_l_str) differ from iprules lists ($ipr_l_str)."
		report_incoherence
		r_no_l
		return 1
	}

	get_difference "$active_lists" "$iplists" lists_difference
	case "$lists_difference" in
		'') debugprint "Successfully verified ip lists coherence."; rv_clc=0 ;;
		*)
			echolog -err "$_nl$FAIL verify ip lists coherence." "Firewall ip lists: '$active_lists'" "Config ip lists: '$iplists'"
			subtract_a_from_b "$iplists" "$active_lists" unexpected_lists
			subtract_a_from_b "$active_lists" "$iplists" missing_lists
			report_incoherence
			rv_clc=1
	esac
	r_no_l
	return $rv_clc
}

report_incoherence() {
	discr="Discrepancy detected between"
	[ "$iplists_incoherent" ] && echolog -warn "$discr geoip ipsets and geoip firewall rules!"
	echolog -warn "$discr the firewall state and the config file."
	for opt_ri in unexpected missing; do
		eval "[ \"\$${opt_ri}_lists\" ] && echolog -warn \"$opt_ri ip lists in the firewall: '\$${opt_ri}_lists'\""
	done
}

# validates country code in $1 against cca2.list
# must be in upper case
# optional $2 may contain path to cca2.list
# returns 0 if validation successful, 2 if not, 1 if cca2 list is empty
validate_ccode() {
	cca2_path="${2:-"$conf_dir/cca2.list"}"
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

check_cron() {
	[ "$cron_rv" ] && return "$cron_rv"
	# check if cron service is enabled
	cron_rv=1; unset cron_reboot cron_cmd cron_path
	# check for cron or crond in running processes
	[ "$cron_rv" != 0 ] && {
		for cron_cmd in cron crond; do
			pidof "$cron_cmd" 1>/dev/null && cron_path="$(command -v "$cron_cmd")" && ls -l "$cron_path" 1>/dev/null 2>/dev/null &&
				{ cron_rv=0; break; }
		done
	}

	export cron_rv
	# check for busybox cron
	[ "$cron_rv" = 0 ] && [ "$cron_path" ] && case "$(ls -l "$cron_path")" in *busybox*) ;; *) export cron_reboot=1; esac

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

OK() { printf '%s\n' "${green}Ok${n_c}."; }
FAIL() { printf '%s\n' "${red}Failed${n_c}." >&2; }

mk_lock() {
	[ "$1" != '-f' ] && check_lock
	echo $$ > "$lock_file" || die "$FAIL set lock '$lock_file'"
	nodie=1
	die_unlock=1
}

rm_lock() {
	[ -f "$lock_file" ] && { rm -f "$lock_file" 2>/dev/null; unset nodie die_unlock; }
}

check_lock() {
	[ ! -f $lock_file ] && return 0
	used_pid="$(cat ${lock_file})"
	[ "$used_pid" ] && kill -0 "$used_pid" 2>/dev/null &&
	die 254 "Lock file $lock_file claims that $p_name (PID $used_pid) is doing something in the background. Refusing to open another instance."
	echolog "Removing stale lock file ${lock_file}."
	rm_lock
	return 0
}

kill_geo_pids() {
	i_kgp=0 _parent="$(grep -o "${p_name}[^[:space:]]*" "/proc/$PPID/comm")"
	while true; do
		i_kgp=$((i_kgp+1)); _killed=
		_geo_ps="$(pgrep -fa "(${p_name}\-|$ripe_url_stats|$ripe_url_api|$ipdeny_ipv4_url|$ipdeny_ipv6_url)" | grep -v pgrep)"
		newifs "$_nl" kgp
		for _p in $_geo_ps; do
			pid="${_p% *}"
			_p="$p_name${_p##*"$p_name"}"
			_p="${_p%% *}"
			case "$_pid" in $$|$PPID|*[!0-9]*) continue; esac
			[ "$_p" = "$_parent" ] && continue
			IFS=' '
			for g in run fetch apply cronsetup backup detect-lan; do
				case "$_p" in *${p_name}-$g*)
					kill "$_pid" 2>/dev/null
					_killed=1
				esac
			done
		done
		oldifs kgp
		[ ! "$_killed" ] || [ $i_kgp -gt 10 ] && break
	done
	unisleep
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
			ipset_type="net"
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

# trap var
trap_args_unlock='[ -f $lock_file ] && [ $$ = $(cat $lock_file 2>/dev/null) ] && rm -f $lock_file 2>/dev/null; exit;'

# vars for common usage() functions
sp8="        "
sp16="$sp8$sp8"
ccodes_usage="<\"country_codes\"> : 2-letter country codes to include in whitelist/blacklist. If passing multiple country codes, use double quotes."
sources_usage="<ripe|ipdeny> : Use this ip list source for download. Supported sources: ripe, ipdeny."
fam_syn="<ipv4|ipv6|\"ipv4 ipv6\">"
families_usage="$fam_syn : Families (defaults to 'ipv4 ipv6'). Use double quotes for multiple families."
list_ids_usage="<\"list_ids\">  : iplist id's in the format <country_code>_<family> (if specifying multiple list id's, use double quotes)"

set -f

if [ -z "$geotag" ]; then
	# export some vars
	set_ansi
	export WARN="${red}Warning${n_c}:" ERR="${red}Error${n_c}:" FAIL="${red}Failed${n_c} to" IFS="$default_IFS"
	[ ! "$in_install" ] && [ "$conf_file" ] && [ "$root_ok" ] && {
		getconfig datadir
		export datadir status_file="$datadir/status"
	}
	geotag="$p_name"
	toupper geochain "$geotag"
	export geotag geochain
fi

:
