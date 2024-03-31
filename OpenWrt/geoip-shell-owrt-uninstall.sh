#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154

# geoip-shell-owrt-uninstall.sh

# trimmed down uninstaller specifically for the OpenWrt geoip-shell package

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

p_name="geoip-shell"
manmode=1
nolog=1

lib_dir="/usr/lib"
_lib="$lib_dir/$p_name-lib"

geoinit="${p_name}-geoinit.sh"
geoinit_path="/usr/bin/$geoinit"

[ -f "$geoinit_path" ] && . "$geoinit_path"
[ -f "$_lib-owrt-common.sh" ] && . "$_lib-owrt-common.sh"
[ -f "$_lib-uninstall.sh" ] && . "$_lib-uninstall.sh"
[ -f "$_lib-$_fw_backend.sh" ] && . "$_lib-$_fw_backend.sh"

: "${conf_dir:=/etc/$p_name}"
[ -d "$conf_dir" ] && : "${conf_file:="$conf_dir/$p_name.conf"}"
[ -f "$conf_file" ] && getconfig datadir
: "${datadir:=/tmp/$p_name-data}"

rm_iplists_rules
rm_cron_jobs
rm_data
rm_owrt_fw_include
rm_config
rm_symlink
