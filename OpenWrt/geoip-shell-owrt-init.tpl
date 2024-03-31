#!/bin/sh /etc/rc.common
# shellcheck disable=SC2034,SC2154,SC2086

# OpenWrt init script for geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# the -install script replaces variables with values

START=99
STOP=01
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /bin/sh \"$install_dir/${p_name}-mk-fw-include.sh\"
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger \"firewall\"
}
