# Copyright 2024 friendly-bits, antonk (antonk.d3v@gmail.com)
# This is free software, licensed under the GNU General Public License v3.

include $(TOPDIR)/rules.mk

PKG_NAME:=$p_name
PKG_VERSION:=$curr_ver
PKG_RELEASE:=$pkg_ver
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=antonk <antonk.d3v@gmail.com>
PKG_SOURCE_PROTO:=git
PKG_SOURCE_VERSION:=$pkg_source_version
PKG_SOURCE_URL:=https://github.com/friendly-bits/geoip-shell-openwrt.git
PKG_MIRROR_HASH:=skip

include $(INCLUDE_DIR)/package.mk

define Package/$p_name/Default
	CATEGORY:=Network
	TITLE:=Flexible geoip blocker
	URL:=https://github.com/friendly-bits/$p_name
	MAINTAINER:=antonk <antonk.d3v@gmail.com>
	DEPENDS:=+ca-bundle
	PROVIDES:=$p_name
	PKGARCH:=all
endef

define Package/$p_name
$(call Package/$p_name/Default)
	TITLE+= with nftables support
	DEPENDS+= +kmod-nft-core +nftables
	DEFAULT_VARIANT:=1
	VARIANT:=nftables
endef

define Package/$p_name-iptables
$(call Package/$p_name/Default)
	TITLE+= with iptables support
	DEPENDS+= +kmod-ipt-ipset +IPV6:ip6tables +iptables +ipset
	VARIANT:=iptables
	CONFLICTS:=$p_name
endef

define Package/$p_name/description/Default
	Flexible geoip blocker with a user-friendly command line interface.
	For readme, please see
	https://github.com/openwrt/packages/blob/master/net/$p_name/OpenWrt-README.md
endef

define Package/$p_name/description
$(call Package/$p_name/description/Default)
endef

define Package/$p_name-iptables/description
$(call Package/$p_name/description/Default)
endef

define Package/$p_name/postinst/Default
#!/bin/sh
rm -f "$install_dir/$p_name"
ln -s "$install_dir/$p_name-manage.sh" "$install_dir/$p_name" ||
	{ logger -s -t "$p_name" -p err "Error: failed to create symlink '$install_dir/$p_name'."; exit 1; }
chmod 555 "$install_dir/$p_name" && chown root:root "$install_dir/$p_name" ||
	logger -s -t "$p_name" -p err "Error: failed to set permissions for '$install_dir/$p_name'."
if [ -s "$conf_dir/$p_name.conf" ]; then
	$install_dir/$p_name configure -z
else
	logger -s -t "$p_name" "Please run '$p_name configure' to complete the setup."
fi
return 0
endef

define Package/$p_name/postinst
$(call Package/$p_name/postinst/Default)
endef

define Package/$p_name-iptables/postinst
$(call Package/$p_name/postinst/Default)
endef

define Package/$p_name/prerm/Default
#!/bin/sh
sh $lib_dir/$p_name-owrt-uninstall.sh
return 0
endef

define Package/$p_name/prerm
$(call Package/$p_name/prerm/Default)
endef

define Package/$p_name-iptables/prerm
$(call Package/$p_name/prerm/Default)
endef

define Package/$p_name/postrm
#!/bin/sh
sleep 1
echo "Reloading the firewall..."
fw4 -q reload
return 0
endef

define Package/$p_name-iptables/postrm
#!/bin/sh
sleep 1
echo "Reloading the firewall..."
fw3 -q reload
return 0
endef

define Build/Configure
endef

define Build/Compile
endef
