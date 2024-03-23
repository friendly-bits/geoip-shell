#!/bin/sh
# the install script makes a new version of this file

export install_dir="/usr/bin" lib_dir="$script_dir/lib" iplist_dir="/tmp" lock_file="/tmp/$p_name.lock"
export _lib="$lib_dir/$p_name-lib" p_script="$script_dir/${p_name}" i_script="$inst_root_gs$install_dir/${p_name}" _nl='
'
export LC_ALL=C POSIXLY_CORRECT=yes default_IFS="	 $_nl"

. "${_lib}-check-compat.sh" &&
. "${_lib}-common.sh" || exit 1
[ "$root_ok" ] || [ "$(id -u)" != 0 ] && return 0
{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
{ check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset && export _fw_backend=ipt
} || die "neither nftables nor iptables+ipset found."
nolog=
:
