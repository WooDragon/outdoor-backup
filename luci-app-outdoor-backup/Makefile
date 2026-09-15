#
# Copyright (C) 2025 OpenWrt.org
#
# This is free software, licensed under the GPL-2.0-only.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-outdoor-backup
PKG_VERSION:=1.0.0
PKG_RELEASE:=3

PKG_MAINTAINER:=Your Name <your.email@example.com>
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-outdoor-backup
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Support for Outdoor Backup
  DEPENDS:=+outdoor-backup +luci-base +luci-compat
  PKGARCH:=all
endef

define Package/luci-app-outdoor-backup/description
  Web interface for outdoor-backup SD card backup system.
  Provides status monitoring, configuration management,
  alias management, and batch cleanup.
endef

define Build/Prepare
	# No source to prepare - pure Lua/HTML package
endef

define Build/Compile
	# No compilation needed
endef

define Package/luci-app-outdoor-backup/install
	# Install controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/*.lua $(1)/usr/lib/lua/luci/controller/

	# Install CBI model
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/outdoor-backup
	$(INSTALL_DATA) ./luasrc/model/cbi/outdoor-backup/*.lua $(1)/usr/lib/lua/luci/model/cbi/outdoor-backup/

	# Install views
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/outdoor-backup
	$(INSTALL_DATA) ./luasrc/view/outdoor-backup/*.htm $(1)/usr/lib/lua/luci/view/outdoor-backup/

	# Install menu entry
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-outdoor-backup.json $(1)/usr/share/luci/menu.d/

	# Install rpcd ACL
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/outdoor-backup.json $(1)/usr/share/rpcd/acl.d/
endef

define Package/luci-app-outdoor-backup/postinst
#!/bin/sh
# This package includes package.mk rather than luci.mk, so luci.mk's default
# cache-flush postinst does not apply. Without this, an opkg install leaves a
# stale menu index and the new menu entry stays invisible.
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache/ 2>/dev/null
	/etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-outdoor-backup))
