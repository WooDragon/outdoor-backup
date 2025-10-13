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

LUCI_TITLE:=LuCI Support for Outdoor Backup
LUCI_DESCRIPTION:=Web interface for outdoor-backup SD card backup system. \
	Provides status monitoring, configuration management, alias management, and batch cleanup.
LUCI_DEPENDS:=+outdoor-backup +luci-base +luci-compat

include ../../luci.mk

# vim: set noexpandtab:
