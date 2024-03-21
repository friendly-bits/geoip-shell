#!/bin/sh
# the install script makes a new version of this file

export lib_dir="$script_dir/lib"
export _lib="$lib_dir/$p_name-lib"
. "${_lib}-check-compat.sh" || exit 1 # checks compatibility
. "${_lib}-common.sh" || exit 1
[ "$root_ok" ] || [ "$(id -u)" != 0 ] && return 0
{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
{ check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset && export _fw_backend=ipt
} || die "neither nftables nor iptables+ipset found."
nolog=
:
