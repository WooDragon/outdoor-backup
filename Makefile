#
# Copyright (C) 2024 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=outdoor-backup
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Your Name <your.email@example.com>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/outdoor-backup
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Outdoor Backup - SD card auto backup system
  DEPENDS:=+rsync +block-mount +kmod-usb-storage +kmod-fs-ext4 +kmod-fs-exfat +kmod-fs-ntfs3
  PKGARCH:=all
endef

define Package/outdoor-backup/description
  Outdoor Backup - Automatic incremental backup system for SD cards on OpenWrt.
  Designed for outdoor photography, drone flights, and field data collection.

  Monitors SD card insertion via hotplug and performs automatic
  rsync-based backups to internal storage (SSD/HDD).

  Features:
  - Automatic hotplug-triggered backups
  - Incremental rsync with --ignore-existing
  - LED status indication
  - Concurrent backup protection (PID lock)
  - Support for multiple filesystems (ext4/exFAT/NTFS/FAT32)
  - Primary and Replica backup modes
endef

define Package/outdoor-backup/conffiles
/opt/sdcard-backup/conf/backup.conf
/etc/config/sdcard-backup
endef

define Build/Prepare
	# No source to prepare - pure shell script package
endef

define Build/Compile
	# No compilation needed - pure shell script package
endef

define Package/outdoor-backup/install
	# Install core scripts
	$(INSTALL_DIR) $(1)/opt/sdcard-backup/scripts
	$(INSTALL_BIN) ./files/opt/sdcard-backup/scripts/*.sh $(1)/opt/sdcard-backup/scripts/

	# Install configuration
	$(INSTALL_DIR) $(1)/opt/sdcard-backup/conf
	$(INSTALL_DATA) ./files/opt/sdcard-backup/conf/backup.conf $(1)/opt/sdcard-backup/conf/

	# Install hotplug script
	$(INSTALL_DIR) $(1)/etc/hotplug.d/block
	$(INSTALL_BIN) ./files/etc/hotplug.d/block/90-sdcard-backup $(1)/etc/hotplug.d/block/

	# Install init script
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/sdcard-backup $(1)/etc/init.d/

	# Install UCI config template
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/sdcard-backup $(1)/etc/config/

	# Create runtime directories (will be populated by postinst)
	$(INSTALL_DIR) $(1)/opt/sdcard-backup/var/lock
	$(INSTALL_DIR) $(1)/opt/sdcard-backup/log
endef

define Package/outdoor-backup/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Create backup storage directory
mkdir -p /mnt/ssd/SDMirrors/.logs

# Set proper permissions
chmod 755 /opt/sdcard-backup/scripts/*.sh
chmod 755 /etc/hotplug.d/block/90-sdcard-backup
chmod 644 /opt/sdcard-backup/conf/backup.conf

# Enable service
/etc/init.d/sdcard-backup enable

echo "======================================"
echo "Outdoor Backup Installed"
echo "======================================"
echo ""
echo "Backup location: /mnt/ssd/SDMirrors/"
echo "Configuration: /opt/sdcard-backup/conf/backup.conf"
echo "or UCI: /etc/config/sdcard-backup"
echo ""
echo "The system will automatically backup SD cards when inserted."
echo "Monitor logs: logread -f | grep sdcard-backup"
echo ""
exit 0
endef

define Package/outdoor-backup/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Disable service
/etc/init.d/sdcard-backup stop
/etc/init.d/sdcard-backup disable

# Kill any running backup processes
pkill -f "backup-manager.sh" 2>/dev/null || true

echo "Outdoor Backup system disabled"
echo "Note: Backup data in /mnt/ssd/SDMirrors/ was preserved"
exit 0
endef

$(eval $(call BuildPackage,outdoor-backup))
