#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154,SC3040

# geoip-shell-init.sh

# initialization for the main geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# the install script makes a new version of this file

curr_ver="0.8.0-pre7"

set -o | grep '^posix[ 	]' 1>/dev/null && set -o posix
set -f

export p_name=geoip-shell \
	LC_ALL=C POSIXLY_CORRECT=YES \
	_nl='
'
export default_IFS="	 $_nl"
IFS="$default_IFS"

for dep in grep tr cut sort wc awk sed logger pgrep pidof; do
	hash "$dep" 2>/dev/null || { echo "Error: missing dependency: '$dep'" >&2; exit 1; }
done

. "$script_dir/lib/${p_name}-lib-non-owrt.sh" || exit 1

check_shell

if [ "$ROOT_OK" = 1 ] || [ "$(id -u)" = 0 ]; then
	export ROOT_OK=1 \
		GEOTEMP_DIR="/tmp/$p_name-tmp" \
		GEORUN_DIR="${GEORUN_DIR:-"/tmp/$p_name-run"}"
else
	export ROOT_OK=0 \
		GEOTEMP_DIR="/tmp/$p_name-tmp-noroot" \
		GEORUN_DIR="${GEORUN_DIR:-"/tmp/$p_name-run-noroot"}"
fi

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

. "$script_dir/lib/${p_name}-lib-common.sh" || exit 1

:
