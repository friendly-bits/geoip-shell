#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154,SC3040

# geoip-shell-init.sh

# initialization for the main geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# the install script makes a new version of this file

curr_ver="0.7.8.1"
export _nl='
'
export LC_ALL=C POSIXLY_CORRECT=YES default_IFS="	 $_nl"
export p_name=geoip-shell
export GEORUN_DIR="${GEORUN_DIR:-"/tmp/$p_name-run"}" GEOTEMP_DIR="${GEOTEMP_DIR:-"/tmp/$p_name-tmp"}"

export conf_dir="/etc/$p_name" \
	install_dir="/usr/bin" \
	lib_dir="/usr/lib/$p_name" \
	iplist_dir="$GEORUN_DIR/iplists" \
	staging_local_dir="$GEORUN_DIR/staging"

export lock_file="$GEORUN_DIR/lock" \
	GS_LOG_FILE="$GEORUN_DIR/log" \
	fetch_res_file="$GEORUN_DIR/fetch-res" \
	excl_file="$script_dir/iplist-exclusions.conf" \
	conf_file="$conf_dir/$p_name.conf"

export _lib="$lib_dir/$p_name-lib" p_script="${script_dir:?}/$p_name" i_script="$install_dir/$p_name"
set -o | grep '^posix[ 	]' 1>/dev/null && set -o posix
set -f

. "$script_dir/lib/${p_name}-lib-non-owrt.sh" || exit 1
check_common_deps
check_shell

[ "$root_ok" ] || { [ "$(id -u)" = 0 ] && export root_ok=1; }
. "$script_dir/lib/${p_name}-lib-common.sh" || exit 1

:
