#!/bin/sh
# shellcheck disable=SC2034,SC1090,SC2154

# geoip-shell-owrt-uninstall.sh

# trimmed down uninstaller specifically for the OpenWrt geoip-shell package

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

p_name="geoip-shell"
manmode=1
nolog=1
in_uninstall=1

lib_dir="/usr/lib/$p_name"
_lib="$lib_dir/$p_name-lib"

geoinit="${p_name}-geoinit.sh"
geoinit_path="/usr/bin/$geoinit"
init_script="/etc/init.d/${p_name}-init"

[ -f "$geoinit_path" ] && . "$geoinit_path"

for lib_f in owrt uninstall; do
	[ -f "$_lib-$lib_f.sh" ] && . "$_lib-$lib_f.sh"
done

[ "$_fw_backend" ] && [ -f "$_lib-$_fw_backend.sh" ] && . "$_lib-$_fw_backend.sh" ||
echolog -err "$FAIL load the firewall-specific library. Cannot remove firewall rules." \
	"Please restart the machine after uninstalling."


: "${conf_dir:=/etc/$p_name}"
[ -d "$conf_dir" ] && : "${conf_file:="$conf_dir/$p_name.conf"}"
[ -f "$conf_file" ] && nodie=1 getconfig datadir
: "${datadir:=/tmp/$p_name-data}"

rm_setupdone
[ -s "$init_script" ] && $init_script disable
rm_owrt_fw_include
kill_geo_pids
rm_lock
rm_iplists_rules
rm_cron_jobs
rm_data
rm_symlink
