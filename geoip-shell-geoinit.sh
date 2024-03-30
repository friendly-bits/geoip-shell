#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154

# geoip-shell-init.sh

# initialization for the main geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# the install script makes a new version of this file


curr_ver="0.4.1"
export install_dir="/usr/bin" lib_dir="$script_dir/lib" iplist_dir="/tmp" lock_file="/tmp/$p_name.lock"
export _lib="$lib_dir/$p_name-lib" p_script="$script_dir/${p_name}" i_script="$inst_root_gs$install_dir/${p_name}" _nl='
'
export LC_ALL=C POSIXLY_CORRECT=yes default_IFS="	 $_nl"

. "${_lib}-check-compat.sh" || exit 1
[ "$root_ok" ] || { [ "$(id -u)" = 0 ] && export root_ok="1"; }
. "${_lib}-common.sh" || exit 1

# check the firewall backend if we are root
[ "$fwbe_ok" ] || [ ! "$root_ok" ] && return 0
_no_l="$nolog"
{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
{ check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset && export _fw_backend=ipt
} || die "neither nftables nor iptables+ipset found."
export fwbe_ok=1
r_no_l
:
