#!/bin/sh /etc/rc.common
# shellcheck disable=SC2034
# OpenWrt init script for geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

START=99
STOP=01
USE_PROCD=1

service_triggers() {
	procd_add_reload_trigger firewall
}

start_service() {
	/bin/sh "/usr/bin/geoip-shell-mk-fw-include.sh"
}
