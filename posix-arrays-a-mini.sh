#!/bin/sh
# shellcheck disable=SC2154,SC2086

# Copyright: blunderful scripts
# github.com/blunderful-scripts

# posix-arrays-a-mini.sh

# emulates associative arrays in POSIX shell

# NOTE: this is a stripped down to a minimum and optimized for very small arrays version,
# which includes a minimal subset of functions from the main project:
# https://github.com/blunderful-scripts/POSIX-arrays


# get keys from an associative array
# whitespace-delimited output is set as a value of a global variable
# 1 - array name
# 2 - var name for output
get_a_arr_keys() {
	___me="get_a_arr_keys"
	case $# in 2) ;; *) wrongargs "$@"; return 1; esac
	_arr_name="$1"; _out_var="$2"
	_check_vars "$_arr_name" "$_out_var" || return 1

	eval "$_out_var=\"\$(printf '%s ' \$_a_${_arr_name}___keys)\""

	return 0
}

# 1 - array name
# 2 - 'key=value' pair
set_a_arr_el() {
	___me="set_a_arr_el"
	_arr_name="$1"; ___pair="$2"
	case "$#" in 2) ;; *) wrongargs "$@"; return 1; esac
	check_pair || return 1
	___key="${___pair%%=*}"
	___new_val="${___pair#*=}"
	_check_vars "$_arr_name" "$___key" || return 1

	eval "___keys=\"\${_a_${_arr_name}___keys}\"
			_a_${_arr_name}_${___key}"='${_el_set_flag}${___new_val}'

	case "$___keys" in
		*"$_nl$___key"|*"$_nl$___key$_nl"* ) ;;
		*) eval "_a_${_arr_name}___keys=\"$___keys$_nl$___key\""
	esac

	return 0
}

# 1 - array name
# 2 - key
# 3 - var name for output
get_a_arr_val() {
	___me="get_a_arr_val"
	case "$#" in 3) ;; *) wrongargs "$@"; return 1; esac
	_arr_name="$1"; ___key="$2"; _out_var="$3"
	_check_vars "$_arr_name" "$___key" "$_out_var" || return 1

	eval "___val=\"\$_a_${_arr_name}_${___key}\""
	eval "$_out_var"='${___val#"${_el_set_flag}"}'
}


## Backend functions

_check_vars() {
	case "$1$2$3" in *[!A-Za-z0-9_]* )
		for _test_seq in "_arr_name|array name" "_out_var|output variable name" "___key|key"; do
			eval "_var_val=\"\$${_test_seq%%|*}\""; _var_desc="${_test_seq#*|}"
			case "$_var_val" in *[!A-Za-z0-9_]* ) printf '%s\n' "$___me: Error: invalid $_var_desc '$_var_val'." >&2; esac
		done
		return 1
	esac
}

check_pair() {
	case "$___pair" in *=* ) ;; *) printf '%s\n' "$___me: Error: '$___pair' is not a 'key=value' pair." >&2; return 1; esac
}

wrongargs() {
	echo "$___me: Error: '$*': wrong number of arguments '$#'." >&2
}

set -f
export LC_ALL=C
___nl='
'
: "${_el_set_flag:="$(printf '\35')"}"
