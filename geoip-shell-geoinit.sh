#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154,SC3040

# geoip-shell-init.sh

# initialization for the main geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# the install script makes a new version of this file


curr_ver="0.6.2"
export install_dir="/usr/bin" lib_dir="$script_dir/lib" iplist_dir="/tmp/$p_name" lock_file="/tmp/$p_name.lock" \
	excl_file="$script_dir/iplist-exclusions.conf"

export _lib="$lib_dir/$p_name-lib" p_script="$script_dir/${p_name}" i_script="$install_dir/${p_name}" _nl='
'
export LC_ALL=C POSIXLY_CORRECT=YES default_IFS="	 $_nl"
set -o | grep '^posix[ \t]' 1>/dev/null && set -o posix

. "${_lib}-non-owrt.sh" || exit 1
check_common_deps
check_shell

[ "$root_ok" ] || { [ "$(id -u)" = 0 ] && export root_ok=1; }
. "${_lib}-common.sh" || exit 1

[ ! "$inst_root_gs" ] && { _fw_backend="$(detect_fw_backend)" || die; }

:
