#
# Copyright (C) 2025 OpenWrt.org
#
# This is free software, licensed under the GPL-2.0-only.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-outdoor-backup
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

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
	echo '{ "admin/services/outdoor-backup": { "title": "Outdoor Backup", "order": 60, "action": { "type": "alias", "path": "admin/services/outdoor-backup/status" }, "depends": { "acl": [ "luci-app-outdoor-backup" ] } } }' > $(1)/usr/share/luci/menu.d/luci-app-outdoor-backup.json

	# Install uHTTPd ACL
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/outdoor-backup.json $(1)/usr/share/rpcd/acl.d/
endef

$(eval $(call BuildPackage,luci-app-outdoor-backup))
