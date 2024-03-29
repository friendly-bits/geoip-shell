include $(TOPDIR)/rules.mk

PKG_NAME:=$p_name$ipt
PKG_VERSION:=$curr_ver
PKG_RELEASE:=$pkg_ver
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/$p_name$ipt
	SECTION:=net
	CATEGORY:=Network
	TITLE:=$p_name$ipt
	DEPENDS:=$depends +ca-bundle
	$variant
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
	exit 0
endef

define Package/$p_name$ipt/prerm
	#!/bin/sh
	sh $install_dir/$p_name-owrt-uninstall.sh
	exit 0
endef

define Package/$p_name$ipt/postrm
	#!/bin/sh
	sleep 1
	echo "Restarting the firewall..."
	fw$_OWRTFW -q restart
	exit 0
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef
