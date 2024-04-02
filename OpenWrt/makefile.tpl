# Copyright 2024 friendly-bits, antonk (antonk.d3v@gmail.com)
# This is free software, licensed under the GNU General Public License v3.

include $(TOPDIR)/rules.mk

PKG_NAME:=$p_name$ipt
PKG_VERSION:=$curr_ver
PKG_RELEASE:=$pkg_ver
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=antonk <antonk.d3v@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/$p_name$ipt
	CATEGORY:=Network
	TITLE:=$p_name$ipt
	URL:=https://github.com/friendly-bits/$p_name
	MAINTAINER:=antonk <antonk.d3v@gmail.com>
	DEPENDS:=$depends +ca-bundle
	$conflicts
	PKGARCH:=all
endef

define Package/$p_name$ipt/description
	Flexible geoip blocker with a user-friendly command line interface (currently no LuCi interface).
	For readme, please see
	https://github.com/friendly-bits/$p_name/README.md
	and
	https://github.com/friendly-bits/$p_name/OpenWrt/README.md
endef

define Package/$p_name$ipt/postinst
	#!/bin/sh
	rm "$install_dir/$p_name" 2>/dev/null
	ln -s "$install_dir/$p_name-manage.sh" "$install_dir/$p_name"
	echo "Please run '$p_name configure' to complete the setup."
	exit 0
endef

define Package/$p_name$ipt/prerm
	#!/bin/sh
	sh $lib_dir/$p_name-owrt-uninstall.sh
	exit 0
endef

define Package/$p_name$ipt/postrm
	#!/bin/sh
	sleep 1
	echo "Restarting the firewall..."
	fw$_OWRTFW -q restart
	exit 0
endef

define Package/conffiles
$conf_dir/$p_name.conf
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef
