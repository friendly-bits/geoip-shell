#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154,SC3040

# geoip-shell-init.sh

# initialization for the main geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# the install script makes a new version of this file

curr_ver="0.8.0-pre2"
export _nl='
'
export LC_ALL=C POSIXLY_CORRECT=YES default_IFS="	 $_nl"
export p_name=geoip-shell
export GEORUN_DIR="${GEORUN_DIR:-"/tmp/$p_name-run"}" GEOTEMP_DIR="${GEOTEMP_DIR:-"/tmp/$p_name-tmp"}"

export CONF_DIR="/etc/$p_name" \
	INSTALL_DIR="/usr/bin" \
	LIB_DIR="/usr/lib/$p_name" \
	IPLIST_DIR="$GEORUN_DIR/iplists" \
	STAGING_LOCAL_DIR="$GEORUN_DIR/staging"

export LOCK_FILE="$GEORUN_DIR/lock" \
	GS_LOG_FILE="$GEORUN_DIR/log" \
	FETCH_RES_FILE="$GEORUN_DIR/fetch-res" \
	EXCL_FILE="$script_dir/iplist-exclusions.conf" \
	CONF_FILE="$CONF_DIR/$p_name.conf"

export _lib="$LIB_DIR/$p_name-lib" p_script="${script_dir:?}/$p_name" i_script="$INSTALL_DIR/$p_name"
set -o | grep '^posix[ 	]' 1>/dev/null && set -o posix
set -f

. "$script_dir/lib/${p_name}-lib-non-owrt.sh" || exit 1
check_common_deps
check_shell

[ "$root_ok" ] || { [ "$(id -u)" = 0 ] && export root_ok=1; }
. "$script_dir/lib/${p_name}-lib-common.sh" || exit 1

:
