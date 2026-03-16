#!/bin/sh
# shellcheck disable=SC2034,SC2154,SC2254,SC2086,SC2015,SC2046,SC2016,SC1090,SC2317

# geoip-shell-lib-common.sh

# Library of common functions and variables for geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

[ -z "$FORCE_SOURCE_LIBS" ] && case " $GS_SOURCED " in *" common "*) return 0; esac

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

is_def_ifs() { idi_rv=$?; [ "$IFS" = "$default_IFS" ] && echo "${1}${1:+: }DEF_IFS:YES" || echo "${1}${1:+: }DEF_IFS:NO"; return $idi_rv; }

dump_args() {
	du_func="$1"
	du_args=
	shift
	du_i=1
	for du_arg in "$@"; do
		du_args="${du_args}${du_args:+${_nl}}${du_i}:${_nl}${du_arg}"
		du_i=$((du_i+1))
	done
	printf '\n%s\n%s\n\n' "${du_func}():" "$du_args"
}
#@

# kills specified pid's and their offspring
# 1 - whitespace-separated starting list of pid's
# 2 - pid's to exclude
kill_pids_recursive()
{
	get_running_pids() {
		eval "$1="
		r_pids=
		for r_pid in ${2}
		do
			[ -d "/proc/${r_pid}" ] && r_pids="${r_pids}${r_pid} "
		done
		eval "${1}"='${r_pids}'
	}

	# recursively add child pid's of pid $2 to whitespace-separated list stored in var $1
	# 1 - var name for output
	# 2 - pid
	add_child_pids()
	{
		pid_scan_depth="${pid_scan_depth:=0}"
		pid_scan_depth=$((pid_scan_depth+1))
		prev_pids=
		child_pids=
		[ "$pid_scan_depth" -lt "$max_pid_scan_depth" ] || return 0

		child_pids="$(pgrep -P "$2")" &&
			[ -n "$child_pids" ] || return 0

		eval "prev_pids=\"\${$1}\""

		for c_pid in $child_pids; do
			is_included "$c_pid" "$prev_pids" " " || eval "$1=\"\${${1}}\${c_pid} \""
			add_child_pids "$1" "$c_pid"
		done
	}

	newifs "$default_IFS" kp

	initial_pids=
	running_pids=
	exclude_pids="$2"
	max_pid_scan_depth=10
	max_k_attempts=10

	# compile a list of initial pids and recursively child pids
	for kp_pid in ${1}
	do
		is_uint "$kp_pid" || continue
		is_included "$kp_pid" "$exclude_pids" " " && continue

		initial_pids="${initial_pids}${kp_pid} "
	done
	[ -n "$initial_pids" ] || { oldifs kp; return 0; }

	running_pids="$initial_pids"
	k_attempt=0

	while :
	do
		for kp_pid in $running_pids
		do
			add_child_pids running_pids "$kp_pid"
		done

		[ -n "$running_pids" ] && kill $running_pids 2>/dev/null

		get_running_pids running_pids "$running_pids"

		[ -n "$running_pids" ] || { oldifs kp; return 0; }

		k_attempt=$((k_attempt+1))
		[ ${k_attempt} -le ${max_k_attempts} ] || break
		sleep 1
	done

	[ -n "$running_pids" ] && { kill -9 $running_pids 2>/dev/null; sleep 1; }

	oldifs kp
	get_running_pids running_pids "$running_pids"
	[ -n "$running_pids" ] && return 1
	:
}


# kills any running geoip-shell scripts and downloads
kill_geo_pids() {
	printf '\n%s\n' "Killing any running $p_name processes..."

	# Get self PID's
	self_pids="${$}|"
	last_pid="${$}"
	i_gpp=0
	while [ $i_gpp -le 24 ]; do
		i_gpp=$((i_gpp+1))

		[ -f "/proc/$last_pid/stat" ] || break
		read -r ppid_line < "/proc/$last_pid/stat"
		ppid_rem="${ppid_line##*") "}"
		ppid_rem="${ppid_rem#*[!\ ] }"
		ppid_rem="${ppid_rem#"${ppid_rem%%[!\ ]*}"}"
		SPPID="${ppid_rem%% *}"

		[ -n "$SPPID" ] || break
		last_pid="$SPPID"
		self_pids="${self_pids}${SPPID}|"
	done
	self_pids="${self_pids%|}"


	debugprint "self pids: '$self_pids'"

	_geo_ps="$(
		pgrep -fa "$p_name" |
		grep -Ev "(pgrep|^${self_pids}|(/usr/bin/)*$p_name(-manage.sh)*${blanks}stop)(${blank}|$)" |
		grep -E "(^${blank}*[0-9][0-9]*${blanks}(sudo )*${p_name}|/usr/bin/${p_name}(${notblank}*sh)*)(${blank}|$)" |
		sed 's/ .*//' |
		tr '\n' ' '
	)"

	[ "$debugmode" ] && debugprint "_geo_ps:${_nl}$(printf %s "$_geo_ps")"

	kill_pids_recursive "$_geo_ps" "$$"
}

rm_cron_jobs() {
	case "$(crontab -u root -l 2>/dev/null)" in *"${p_name}-run.sh"*)
		echo "Removing cron jobs..."
		crontab -u root -l 2>/dev/null | grep -v "${p_name}-run.sh" | crontab -u root -
	esac
	:
}

rm_all_data() {
	rm_data
	rm_geodir "$local_iplists_dir" "local IP lists"
	rm_dir_if_empty "$datadir"
}

rm_data() {
	[ -n "$datadir" ] || return 0
	rm_geodir "$datadir"/backup backup
	rm -f "$datadir"/status "$datadir"/ips_cnt
	rm_dir_if_empty "$datadir"
	:
}

rm_setupdone() {
	rm -f "$CONF_DIR/setupdone"
}

is_uint()
{
	for _v in "${@}"; do
		case "${_v}" in
			''|*[!0-9]*) return 1
		esac
	done
	:
}

bad_args() {
	ba_func="$1" ba_args=
	shift
	for ba_arg in "$@"; do
		ba_args="${ba_args}${ba_args:+ ,}'${ba_arg}'"
	done
	echolog -err "${ba_func}(): bad args $ba_args"
}

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
		[ -n "$inst_root_gs" ] || [ "$ROOT_OK" != 1 ] || { chmod -R 600 "$1" && chown -R root:root "$1"; }
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
	[ -n "$IFS" ] || { IFS="$default_IFS"; echolog -err "Internal error: old IFS for '$1' is not set."; }
}

is_root_ok() {
	[ "$ROOT_OK" = 1 ] && return 0
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
	command -v "$1" 1>/dev/null
}

checkvars() {
	for chkvar; do
		eval "[ -n \"\$$chkvar\" ]" || {
			echolog -err "The '\$$chkvar' variable is not set."
			die
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
			die
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

	case "$1" in
		*[!a-zA-Z0-9_\|-]*) bad_args pick_opt "$@"; die
	esac

	while :; do
		printf %s "$1: "
		read -r REPLY
		is_alphanum "$REPLY" || { wrong_opt "$1"; continue; }
		tolower REPLY
		eval "case \"\$REPLY\" in
				$1) return ;;
				*) wrong_opt \"$1\"
			esac"
	done
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

# outputs random int between 0 and $2. max 99 with dd, 65535 with hexdump
# output via var $1
get_random_int() {
    gri_int=
    if checkutil hexdump; then
        gri_int="$(hexdump -n 2 -e '"%u"' </dev/urandom)"
        gri_int_scaled=$(( gri_int * $2 / 65535))
    elif checkutil dd; then
        gri_int="$(tr -cd 0-9 < /dev/urandom 2>/dev/null | dd bs=2 count=1 2>/dev/null)"
        gri_int_scaled=$(($(printf "%.0f" "$gri_int") * $2 / 99))
    fi
    eval "$1"='${gri_int_scaled:-0}'
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
	[ ! "$script_to_call" ] && { bad_args call_script "$@"; return 1 ; }

	[ "$use_lock" ] && rm_lock
	$use_shell "$script_to_call" "$@"
	call_rv=$?
	debugexitmsg
	[ -z "$use_lock" ] || mk_lock -f || return 1
	use_lock=

	# load cached config
	if [ -s "$CONF_FILE_TMP" ]; then
		load_config main "$CONF_FILE_TMP" ||
			{ rm -f "$CONF_FILE_TMP"; echolog -err "Failed to reload config from file '$CONF_FILE_TMP'."; return 1; }
	fi

	return "$call_rv"
}

source_lib() {
	[ -n "$1" ] || { bad_args source_lib "$@"; return 1; }
	[ "$1" = common ] && die "source_lib: call loop"
	sl_name="$1"
	[ -z "$FORCE_SOURCE_LIBS" ] && is_included "$sl_name" "$GS_SOURCED" " " && { debugprint "Already sourced: '$sl_name'"; return 0; }
	src_file="${p_name}-lib-${sl_name}.sh"
	shift
	[ -n "$*" ] || set -- "$LIB_DIR"
	for dir in "$@"; do
		[ -f "$dir/$src_file" ] && {
			debugprint "Sourcing '$sl_name'"
			. "$dir/$src_file" && return 0
		}
	done
	echolog -err "Failed to source '$src_file'."
	return 1
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
		[ -n "$GS_DAEMON_MODE" ] && date +"[%b %d %Y %H:%M:%S] ${el_msg}" >> "${GS_LOG_FILE}"
		logger -t "$me" -p "user.$2" "$el_msg"
	}

	unset msg_args nl_print msg_prefix o_nolog el_msg

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
		nl_print="$_nl"
		msg_args="${msg_args#"$_nl"}"
	esac

	newifs "$delim" ecl
	set -- $msg_args
	oldifs ecl

	first_prefix="${nl_print}${highlight}${me_short}${n_c}: "
	for arg in "$@"; do
		[ ! "$noecho" ] && {
			_msg="${first_prefix}${msg_prefix}${arg}"
			case "$err_l" in
				info) printf '%s\n' "$_msg" ;;
				err|warn) printf '%s\n' "$_msg" >&2
			esac
		}

		if [ ! "$nolog" ] && [ ! "$o_nolog" ]; then
			write_entry "$msg_prefix$arg" "$err_l"
		fi
		unset first_prefix msg_prefix
		err_l=info
	done
}

get_session_log() {
	i=1
	while [ $i -le 5 ] && ! cat "$GS_LOG_FILE" 2>/dev/null; do
		sleep 1
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

	if [ -n "$GS_CONFIG_OWNER" ] && [ -s "$CONF_FILE_TMP" ]; then
		[ -s "$CONF_FILE" ] && compare_files "$CONF_FILE_TMP" "$CONF_FILE" ||
		{
			printf_s "Updating the config file... "
			if mv "$CONF_FILE_TMP" "$CONF_FILE"; then
				OK
			else
				FAIL
			fi
		}
		rm -f "$CONF_FILE_TMP"
	fi

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
	case "$i" in *[!0-9]*) bad_args num2human "$@"; return 1; esac
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
	case "${1}" in *[!"${_fs_ii}"]*"${_fs_ii}"*[!"${_fs_ii}"]*) false ;; *) :; esac &&
	case "${_fs_ii}${2}${_fs_ii}" in *"${_fs_ii}${1}${_fs_ii}"*) : ;; *) false; esac &&
		return 0
	return 1
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
	eval "$1=\"\${$1}\""'${a2l_fs}$2'"; $1=\"\${$1#$a2l_fs}\""
	return 0
}

# checks if string $1 is safe to use with eval
is_str_safe() {
	case "$1" in *'\'*|*'"'*|*\'*|*'$'*|*'`'*) echolog -err "Invalid string '$1'"; return 1; esac
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

# sets $_FW_BACKEND_DEF, $IPT_OK, $NFT_OK, $NFT_PRESENT, $IPT_PRESENT, $IPSET_PRESENT, $IPT_RULES_PRESENT
detect_fw_backends() {
	unset IPT_OK IPT_LIB_PRESENT IPT_PRESENT IPT_RULES_PRESENT IPSET_PRESENT \
		NFT_OK NFT_LIB_PRESENT NFT_PRESENT _FW_BACKEND_DEF

	echolog "${_nl}Detecting firewall backends..."

	check_fw_backend -nolog ipt && IPT_OK=1
	check_fw_backend -nolog nft && NFT_OK=1

	[ "${IPT_PRESENT}" ] && { iptables-save; ip6tables-save; } | grep '^-A[ \t]' 1>/dev/null &&
		{ IPT_RULES_PRESENT=1; echolog "Found existing iptables rules"; }

	if [ -n "$IPT_OK" ] && [ -n "$NFT_OK" ]; then
		_FW_BACKEND_DEF=ask
	elif [ -n "$NFT_OK" ]; then
		_FW_BACKEND_DEF=nft
	elif [ -n "$IPT_OK" ]; then
		_FW_BACKEND_DEF=ipt
	elif [ -n "$IPT_PRESENT" ] && [ -n "$IPT_LIB_PRESENT" ] && [ -z "$IPSET_PRESENT" ]; then
		echolog -err "Found iptables but required utility 'ipset' not found. Use your package manager to install it."
		return 1
	else
		echolog -err "Found neither nftables + $p_name nftables library nor iptables + $p_name iptables library."
		return 1
	fi

	:
}

# return codes:
# 0 - backend and library found
# 1 - error
# 2 - main backend not found (for ipt, iptables not found)
# 3 - for ipt, ipset not found
# 4 - library not found
check_fw_backend() {
	be_notify() {
		notify_dest=/dev/stdout be_err_l=
		[ "$1" = '-e' ] && {
			[ -z "$el_nolog" ] && { be_err_l=-err notify_dest=/dev/stderr; }
			shift
		}
		echolog $el_nolog $be_err_l "$1" > "$notify_dest"
	}

	unset el_nolog nochecklibs
	for __arg; do
		case "$__arg" in
			-nolog) el_nolog="$1"; shift ;;
			-nochecklibs) nochecklibs=1; shift
		esac
	done

	[ "$1" = '-nolog' ] && { el_nolog="$1"; shift; }
	case "$1" in
		nft)
			check_deps nft 2>/dev/null || { be_notify -e "nftables not found."; return 2; }
			NFT_PRESENT=1
			be_notify "nftables found." ;;
		ipt)
			check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore 2>/dev/null ||
				{ be_notify -e "iptables not found."; return 2; }
			IPT_PRESENT=1
			be_notify "iptables found."
			check_deps ipset 2>/dev/null || { be_notify -e "ipset utility not found."; return 3; }
			IPSET_PRESENT=1
			be_notify "ipset utility found." ;;
		*) echolog -err "Unsupported firewall backend '$1'."; return 1
	esac

	[ -z "$nochecklibs" ] && {
		[ -s "${_lib}-${1}.sh" ] || { be_notify -e "$p_name ${1}ables library not found."; return 4; }
		be_notify "$p_name ${1}ables library found."
		eval "${1}_lib_present=1"
	}
	:
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

		for gai_local_iplists_dir in "$STAGING_LOCAL_DIR" "$local_iplists_dir"; do
			for iplist_type in allow block; do
				iplist_path="${local_iplists_dir}/local_${iplist_type}_${family}"

				[ -s "${iplist_path}.ip" ] || [ -s "${iplist_path}.net" ] &&
					exp_iplists_gai="${exp_iplists_gai} local_${iplist_type}_${family}"
			done
		done

		[ "$2" = outbound ] && eval "[ \"\${source_ips_${family}}\" ]" &&
			exp_iplists_gai="${exp_iplists_gai} allow_$family"
	done

	ipset_iplists="$(get_ipsets | sed "s/${geotag}_//;s/_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].*//;s/_4/_ipv4/;s/_6/_ipv6/")"
	fwrules_iplists="$(get_fwrules_iplists "$direction")"

	# debugprint "$_nl$2 ipset_iplists: ${_nl}$ipset_iplists${_nl}${_nl}fwrules_iplists: $_nl$fwrules_iplists"

	nl2sp ipset_iplists_sp "$ipset_iplists"
	nl2sp fwrules_iplists_sp "$fwrules_iplists"

	get_exclusions excl_lists country

	inc=0
	subtract_a_from_b "$ipset_iplists_sp" "$exp_iplists_gai" missing_ipsets ||
		ignore_allow missing_ipsets ipset_iplists_sp "$direction" ||
		subtract_a_from_b "$excl_lists" "$missing_ipsets" missing_ipsets || inc=1

	subtract_a_from_b "$exp_iplists_gai" "$fwrules_iplists_sp" unexpected_lists ||
		ignore_allow unexpected_lists exp_iplists_gai "$direction"|| inc=1

	subtract_a_from_b "$fwrules_iplists_sp" "$exp_iplists_gai" missing_lists ||
		ignore_allow missing_lists fwrules_iplists_sp "$direction" ||
		subtract_a_from_b "$excl_lists" "$missing_lists" missing_lists || inc=1

	get_intersection "$ipset_iplists" "$fwrules_iplists" active_iplists_nl "$_nl"
	nl2sp "$gai_out_var" "$active_iplists_nl"

	return $inc
}

# checks whether current ipsets and iptables rules match ones in the config file
check_lists_coherence() {
	_no_l=
	[ "$1" = '-n' ] && _no_l=1

	debugprint "Verifying IP lists coherence..."

	nodie=1 nolog="${_no_l:-"$nolog"}" load_config main || return 1

	iplists_incoherent=
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue

		eval "exp_iplists=\${${direction}_iplists}"
		for family in $families; do
			[ "$direction" = outbound ] && eval "[ \"\$source_ips_${family}\" ]" && exp_iplists="${exp_iplists} allow_$family"
			case "$geomode" in
				whitelist)
					exp_iplists="${exp_iplists} allow_$family"
					[ "$family" = ipv4 ] && exp_iplists="${exp_iplists} dhcp_ipv4" ;;
				blacklist) eval "[ \"\${trusted_$family}\" ]" && exp_iplists="${exp_iplists} allow_$family" ;;
				*) echolog -err "Unexpected geoblocking mode '$geomode'!"; return 1
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
		echolog -warn "${_nl}Unexpected ipsets detected: '$unexpected_ipsets'."
		iplists_incoherent=1
		debugprint "all_exp_iplists: '$all_exp_iplists'${_nl}ipset_iplists: '$ipset_iplists_sp'"
	}

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

# 1 - dir path
# 2 - dir description
rm_geodir() {
	[ "${1%/}" ] && [ "${1%/}" != '/' ] && [ -d "${1%/}" ] && {
		printf '%s\n' "Deleting the $2 directory '$1'..."
		rm -rf "${1%/}"
	}
}

rm_iplists() { set +f; rm -f "${IPLIST_DIR:-???}"/*.iplist; set -f; }

rm_iplists_rules() {
	case "$IPLIST_DIR" in
		*"$p_name"*) rm_geodir "$IPLIST_DIR" iplist ;;
		*)
			# remove individual iplist files if IPLIST_DIR is shared with non-geoip-shell files
			[ "$IPLIST_DIR" ] && [ -d "$IPLIST_DIR" ] && {
				echo "Removing $p_name IP lists..."
				rm_iplists
			}
	esac

	### Remove geoip firewall rules
	if [ "$_fw_backend" ]; then
		(
			source_lib "${_fw_backend}" "${LIB_SRC_DIR:-"$LIB_DIR"}" &&
			rm_all_georules || exit 1
		)
	elif checkutil "$p_name"; then
		echolog -err "Firewall backend is unknown."
		false
	else
		:
	fi || { echolog -err "Cannot remove geoblocking rules."; return 1; }
	:
}

get_exclusions() {
	case "$2" in country|asn) : ;; *) bad_args get_exclusions "$@"; return 1; esac
	eval "ge_lists=\${EXCL_LISTS_${2}}"
	[ "$ge_lists" ] ||
	{
		[ -s "$EXCL_FILE" ] &&
			nodie=1 load_config exclusions "$EXCL_FILE" "exclude_iplists_${2}=ge_lists"
	} &&
	export "EXCL_LISTS_${2}=$ge_lists" &&
	eval "$1"='$ge_lists' ||
		{ echolog -err "$FAIL get exclusions from file '$EXCL_FILE'."; return 1; }
}

load_cca2() {
	[ "$ALL_CCODES" ] && return 0
	for cca2_path in "$@" "$CONF_DIR/cca2.list"; do
		[ -n "$cca2_path" ] || continue
		[ -s "$cca2_path" ] && { cca2_found=1; break; }
	done
	[ -n "$cca2_found" ] || { echolog -err "Can not find cca2.list or it is empty."; return 1; }

	EXPORT_CONF=1 getstatus cca2 "$cca2_path" || return 1
	export ${VALID_REGISTRIES?} \
		ALL_CCODES="$RIPENCC $ARIN $APNIC $AFRINIC $LACNIC"
}

validate_ccode() {
	vc_ccode="$2"
	eval "${1:-_}="
	toupper vc_ccode &&
	load_cca2 "$CONF_DIR/cca2.list" || die
	case "$vc_ccode" in ''|*" "*) false ;; *) :; esac &&
	is_included "$vc_ccode" "$ALL_CCODES" || {
		echolog -err "Invalid 2-letter country code: '$vc_ccode'."
		return 1
	}
	eval "${1:-_}"='$vc_ccode'
}

# normalizes to 'AA_ipv[4|6]', validates format, validates against prefixes list (country codes), removes excluded list ID's, deduplicates
# outputs space-separated list
san_list_ids() {
	sli_out_var="$1" sli_lists="$2" sli_type="$3"
	excl_reg_file="${GEOTEMP_DIR:-"/tmp"}/$p_name-excluded"
	eval "$sli_out_var="
	case "$sli_type" in
		country)
			[ -n "$ALL_CCODES" ] || die "san_list_ids: \$ALL_CCODES is empty."
			val_prefixes="$ALL_CCODES"
			prefix_case="uc"
			val_suffixes="ipv[46]"
			suffix_case="lc"
			sli_id_delim=_ ;;
		asn)
			val_prefixes=""
			prefix_case="lc"
			val_suffixes="AS[0-9]+"
			suffix_case="uc"
			sli_id_delim='' ;;
		*) bad_args san_list_ids "$@"; die ;;
	esac
	get_exclusions excl_lists "$sli_type" || return 1

	dir_mk -n "${excl_reg_file%/*}" || return 1
	rm -f "$excl_reg_file"
	res_ids="$(
		$awk_cmd \
			-v main_ids_str="$sli_lists" \
			-v val_prefixes="$val_prefixes" \
			-v prefix_case="$prefix_case" \
			-v val_suffixes="$val_suffixes" \
			-v suffix_case="$suffix_case" \
			-v id_delim="$sli_id_delim" \
			-v excl_ids_str="$excl_lists" \
			-v excl_reg_file="$excl_reg_file" \
			'
			function san_spaces(line,san_delim) {
				if (!san_delim) san_delim=" "
				sub(/^[ 	]+/, "", line); sub(/[ 	]+$/, "", line); gsub(/[ 	]+/,san_delim,line); return line
			}
			function norm_ids(ids_str, type,        ids_arr_uc, ids_arr_lc, seen, cnt) {
				ids_str=san_spaces(ids_str)
				ids_str_uc=toupper(ids_str)
				ids_str_lc=tolower(ids_str)
				split(ids_str,ids_arr_orig," ")
				split(ids_str_lc,ids_arr_lc," ")
				cnt=split(ids_str_uc,ids_arr_uc," ")

				for (i=1; i <= cnt; i++) {
					uc_id=ids_arr_uc[i]
					lc_id=ids_arr_lc[i]

					match(ids_str,id_delim)

					if (prefix_case == "lc") prefix=substr(lc_id,1,RSTART-1)
					else prefix=substr(uc_id,1,RSTART-1)

					if (suffix_case == "lc") suffix=substr(lc_id,RSTART+RLENGTH)
					else suffix=substr(uc_id,RSTART+RLENGTH)

					id = prefix id_delim suffix
					if ( id !~ val_regex ) {
						if (type == "main") {
							bad_cnt=i
							bad_ids[i]=ids_arr_orig[i]
							rv=1
						}
					}
					else if (!seen[id]) {
						seen[id]=1
						if (type == "main" && id in excl_arr) {excluded=excluded " " id}
						else if (type == "main") res_arr[i]=id
						else excl_arr[id]
					}
				}
				if (type == "main") {main_cnt=cnt}
			}

			BEGIN {
				rv=0
				i=0
				e=0
				main_cnt=0
				if (val_prefixes) prefix_regex = "(" san_spaces(val_prefixes,"|") ")"
				if (val_suffixes) suffix_regex = "(" san_spaces(val_suffixes,"|") ")"
				val_regex = "^" prefix_regex id_delim suffix_regex "$"

				norm_ids(excl_ids_str,"excl")
				norm_ids(main_ids_str,"main")
				exit
			}

			END {
				if (rv == 1 || main_cnt == 0) {
					for (n=1; n <= bad_cnt; n++) {
						if (! bad_ids[n]) continue
						printf "%s ",bad_ids[n]
					}
					exit 1
				}
				for (n=1; n <= i; n++) {
					if (! res_arr[n]) continue
					printf "%s ",res_arr[n]
				}
				if (excluded) {
					print excluded > excl_reg_file
				}
				printf "\n"
				exit 0
			}'
	)" && {
		eval "$sli_out_var"='${res_ids% }'
		[ -s "$excl_reg_file" ] && {
			sli_excluded="$(cat "$excl_reg_file")"
			echolog -nolog "${_nl}${yellow}NOTE:${n_c} Following IP lists are in the exclusions file, skipping: '${sli_excluded# }'"
		}
		rm -f "$excl_reg_file"
		return 0
	}
	rm -f "$excl_reg_file"
	res_ids="${res_ids% }"
	echolog -err "Invalid $sli_type list ID's '${res_ids:-"$sli_lists"}' or no list ID's specified."
	return 1
}

# detects all network interfaces known to the kernel, except the loopback interface
# returns 1 if nothing detected
detect_ifaces() {
	[ -r "/proc/net/dev" ] && sed -n '/^[[:space:]]*[^[:space:]]*:/{s/^[[:space:]]*//;s/:.*//p}' < /proc/net/dev | grep -vx 'lo'
}

try_read_crontab() {
	crontab -u root -l 1>/dev/null 2>/dev/null
}

OK() { printf '%s\n' "${green}OK${n_c}"; }
FAIL() { printf '%s\n' "${red}Failed${n_c}." >&2; }

mk_lock() {
	[ "$1" != '-f' ] && check_lock
	[ "$LOCK_FILE" ] && dir_mk -n "${LOCK_FILE%/*}" && printf '%s\n' "$$" > "$LOCK_FILE" || {
		echolog -err "$FAIL set lock '$LOCK_FILE'"
		return 1
	}
	nodie=1
	die_unlock=1
}

rm_lock() {
	[ -f "$LOCK_FILE" ] && { unset nodie die_unlock; rm -f "$LOCK_FILE" || return 1; }
	:
}

check_lock() {
	checkvars LOCK_FILE
	[ ! -f "$LOCK_FILE" ] && return 0
	read -r used_pid < "$LOCK_FILE"
	case "$used_pid" in
		''|*![0-9]*) echolog -err "Lock file '$LOCK_FILE' is empty or contains unexpected string." ;;
		*) kill -0 "$used_pid" 2>/dev/null &&
			die 0 "$p_name (PID $used_pid) is doing something in the background. Refusing to open another instance."
	esac
	echolog "Removing stale lock file ${LOCK_FILE}."
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

setup_ipinfo() {
	checkutil "gzip" || { echolog -err "IPinfo source requires the 'gzip' utility but it is not found."; return 1; }

	[ "$ipinfo_token" ] ||
		printf '%s\n' "IPinfo requires a license. You will need to provide IPinfo token."
	printf '%s\n' "Which IPinfo license do you have: [l]ite, [c]ore or [p]lus? Or type in [a] to abort."
	pick_opt "l|c|p|a"
	case "$REPLY" in
		l) export ipinfo_license_type=lite ;;
		c) export ipinfo_license_type=core ;;
		p) export ipinfo_license_type=plus ;;
		a) return 1
	esac

	curr_token_msg=
	[ "$ipinfo_token" ] && curr_token_msg=" or press Enter to use current token '$ipinfo_token'"
	while :; do
		printf '%s\n' "Type in IPinfo token${curr_token_msg}: "
		read -r REPLY
		case "$REPLY" in
			'')
				[ "$ipinfo_token" ] || { printf '%s\n' "Invalid token '$REPLY'."; continue; }
				break ;;
			*[!a-zA-Z0-9]*) printf '%s\n' "Invalid token '$REPLY'."; continue
		esac
		export ipinfo_token="$REPLY"
		break
	done
}

setup_maxmind() {
	for util in unzip gzip; do
		checkutil "$util" || { echolog -err "MaxMind source requires the '$util' utility but it is not found."; return 1; }
	done

	[ "$mm_acc_id" ] && [ "$mm_acc_license" ] ||
		printf '%s\n' "MaxMind requires a license. You will need account ID and license key."
	printf '%s\n' "Which MaxMind license do you have: [f]ree (for GeoLite2) or [p]aid (for GeoIP2)? Or type in [a] to abort."
	pick_opt "f|p|a"
	case "$REPLY" in
		f) export mm_license_type=free ;;
		p) export mm_license_type=paid ;;
		a) return 1
	esac

	curr_acc_msg=
	[ "$mm_acc_id" ] && curr_acc_msg=" or press Enter to use current account ID '$mm_acc_id'"
	while :; do
		printf '%s\n' "Type in MaxMind account ID (numerical)${curr_acc_msg}: "
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

	curr_key_msg=
	[ "$mm_license_key" ] && curr_key_msg=" or press Enter to use current license key '$mm_license_key'"
	while :; do
		printf '%s\n' "Type in MaxMind License key${curr_key_msg}: "
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

# 1 - input IP addresses/ranges
# 2 - output via return code (0: all valid; 1: 1 or more invalid)
# if a range is detected in addresses of a particular family, sets ipset_type to 'net', otherwise to 'ip'
# expects the $family var to be set
validate_ip() {
	ipset_type=ip family="$2" o_ips=
	sp2nl i_ips "$1"
	[ -n "$i_ips" ] &&
	case "$family" in
		inet|ipv4) family=ipv4 ip_len=32 ;;
		inet6|ipv6) family=ipv6 ip_len=128 ;;
		*) false
	esac || { bad_args validate_ip "$@"; return 1; }
	eval "ip_regex=\"\$${family}_regex\""

	newifs "$_nl"
	for i_ip in $i_ips; do
		oldifs
		case "$i_ip" in */*)
			ipset_type=net
			_mb="${i_ip#*/}"
			case "$_mb" in ''|*[!0-9]*)
				echolog -err "Invalid mask bits '$_mb' in IP range '$i_ip'."; return 1; esac
			i_ip="${i_ip%%/*}"
			case $(( (_mb<8) | (_mb>ip_len) )) in 1) echolog -err "Invalid $family mask bits '$_mb'."; return 1; esac
		esac

		ip route get "$i_ip" 1>/dev/null 2>/dev/null
		case $? in 0|2) ;; *) echolog -err "IP address '$i_ip' failed kernel validation."; return 1; esac
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
	esac && [ "$counter_strings" ] &&
		EXPORT_CONF=1 set_config_vars "variable \$counter_strings" "$counter_strings" &&
		counters_set=1
	# debugprint "counter strings:${_nl}$counter_strings"
	:
}

# sleeps for 0.1s on systems which support this, or 1s on systems which don't
unisleep() {
	$unisleep_cmd
}

VALID_REGISTRIES="RIPENCC ARIN APNIC AFRINIC LACNIC"
valid_families="ipv4 ipv6"
VALID_SRCS_COUNTRY="ripe ipdeny maxmind ipinfo"
DEF_SRC_COUNTRY="ripe"
VALID_SRCS_ASN=ipinfo_app
DEF_SRC_ASN="ipinfo_app"

ripe_url_stats=ftp.ripe.net/pub/stats
ripe_url_api="stat.ripe.net/data/country-resource-list/data.json?"
ipdeny_ipv4_url=www.ipdeny.com/ipblocks/data/aggregated
ipdeny_ipv6_url=www.ipdeny.com/ipv6/ipaddresses/aggregated
maxmind_url=download.maxmind.com/geoip/databases
ipinfo_url=ipinfo.io/data
ipinfo_app_url=ipinfo.app/api/text/list

# set some vars for debug and logging
: "${me:="${0##*/}"}"
me_short="${me#"${p_name}-"}"
me_short="${me_short%.sh}"
p_name_cap=GEOIP-SHELL

# vars for common usage() functions
sp8="        "
sp16="$sp8$sp8"
direction_syn="<inbound|outbound>"
direction_usage="direction (inbound|outbound). Only valid for actions add|remove and in combination with the '-l' option."
list_ids_usage="iplist IDs in the format <country_code>_<family> (if specifying multiple list IDs, use double quotes)"
nointeract_usage="Non-interactive setup. Will not ask any questions."

# IP regex
export ipv4_regex='((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])' \
	ipv6_regex='([0-9a-f]{0,4})(:[0-9a-f]{0,4}){2,7}' \
	maskbits_regex_ipv4='(3[0-2]|([1-2][0-9])|[6-9])' \
	maskbits_regex_ipv6='(12[0-8]|((1[0-1]|[1-9])[0-9])|[6-9])'
export \
	ip_or_range_regex_ipv4="${ipv4_regex}(/${maskbits_regex_ipv4}){0,1}" \
	ip_or_range_regex_ipv6="${ipv6_regex}(/${maskbits_regex_ipv6}){0,1}"\
	range_regex_ipv4="${ipv4_regex}/${maskbits_regex_ipv4}" \
	range_regex_ipv6="${ipv6_regex}/${maskbits_regex_ipv6}"\
	inbound_geochain="${p_name_cap}_IN" outbound_geochain="${p_name_cap}_OUT" \
	inbound_dir_short=in outbound_dir_short=out

blank="[ 	]"
notblank="[^ 	]"
blanks="${blank}${blank}*"
export _nl='
'
export default_IFS="	 $_nl"
export IFS="$default_IFS"

[ -z "$geotag" ] && {
	set_ansi
	export WARN="${yellow}Warning${n_c}:" ERR="${red}Error${n_c}:" FAIL="${red}Failed${n_c} to"

	if checkutil mawk; then
		awk_cmd=mawk
	elif checkutil gawk; then
		awk_cmd="gawk"
	else
		awk_cmd="awk"
	fi
	unisleep_cmd="sleep 1"
	sleep 0.1 2>/dev/null && unisleep_cmd="sleep 0.1"
	export awk_cmd
	export geotag="$p_name"
}

add2list GS_SOURCED "common" " "
source_lib config "$script_dir/lib" "$LIB_DIR" || return 1

:
