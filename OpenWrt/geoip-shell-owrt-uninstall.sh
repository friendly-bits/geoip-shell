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

[ -f "$geoinit_path" ] && . "$geoinit_path" ||
{
	[ -f "${_lib}-owrt.sh" ] && . "${_lib}-owrt.sh" &&
	[ -f "${_lib}-common.sh" ] && . "${_lib}-common.sh" ||
	{ logger -s -t "owrt-uninstall" -p user.err "Failed to source essential libraries."; exit 1; }
}

for lib_f in owrt uninstall; do
	source_lib "$lib_f"
done

[ "$_fw_backend" ] ||
for _fw_backend in ipt nft; do
	checkutil check_fw_backend &&
		check_fw_backend -nolog "$_fw_backend" 1>/dev/null && break
	false
done || _fw_backend=''

[ "$_fw_backend" ] && source_lib "$_fw_backend" ||
	echolog -err "$FAIL load the firewall-specific library. Cannot remove firewall rules."

: "${conf_dir:=/etc/$p_name}"
[ -d "$conf_dir" ] && : "${conf_file:="$conf_dir/$p_name.conf"}"
[ -s "$conf_file" ] && nodie=1 getconfig datadir
: "${datadir:="$GEORUN_DIR/data"}"
[ -s "$conf_file" ] && nodie=1 getconfig local_iplists_dir
: "${local_iplists_dir:="/var/lib/$p_name/local_iplists"}"

rm_setupdone
[ -s "$init_script" ] && $init_script disable
rm_owrt_fw_include
kill_geo_pids
rm_lock
checkutil rm_iplists_rules && rm_iplists_rules
rm_cron_jobs
rm_data
rm_symlink
if is_dir_empty "$local_iplists_dir"; then
	rm_geodir "$local_iplists_dir" "local IP lists"
	rm_dir_if_empty "$datadir"
else
	echolog "NOTE: local IP lists are not removed." \
		"If you are not planning to re-install $p_name, manually remove the directory '$local_iplists_dir'."
fi
