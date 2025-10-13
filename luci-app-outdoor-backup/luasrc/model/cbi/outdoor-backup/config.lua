-- Copyright (C) 2024 Outdoor Backup Project
-- Licensed under GPL-2.0-only

local m, s, o

-- 顶层 Map：绑定到 UCI config "outdoor-backup"
m = Map("outdoor-backup",
        translate("Outdoor Backup Configuration"),
        translate("SD card automatic backup system for outdoor photography and field data collection"))

-- 单一 TypedSection：避免重复渲染
s = m:section(TypedSection, "outdoor-backup", translate("Settings"))
s.anonymous = true
s.addremove = false

-- ========== 基本设置 ==========

o = s:option(Flag, "enabled", translate("Enable Auto Backup"),
             translate("Automatically backup SD cards when inserted"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "backup_root", translate("Backup Root Directory"),
             translate("Directory where all SD card backups will be stored"))
o.default = "/mnt/ssd/SDMirrors"
o.placeholder = "/mnt/ssd/SDMirrors"
o.datatype = "directory"
o.rmempty = false

o = s:option(Value, "mount_point", translate("SD Card Mount Point"),
             translate("Temporary mount point for SD cards during backup"))
o.default = "/mnt/sdcard"
o.placeholder = "/mnt/sdcard"
o.datatype = "directory"
o.rmempty = false

o = s:option(Flag, "debug", translate("Debug Mode"),
             translate("Enable verbose logging for troubleshooting"))
o.default = "0"
o.rmempty = false

-- ========== LED 指示灯设置 ==========

o = s:option(DummyValue, "_led_separator", translate("LED Indicators"))
o.rawhtml = true
o.value = "<hr style='margin: 15px 0; border: none; border-top: 1px solid #ccc;'>"

o = s:option(Value, "led_green", translate("Green LED Path"),
             translate("Sysfs path for success indicator (e.g., /sys/class/leds/green:lan)"))
o.default = "/sys/class/leds/green:lan"
o.placeholder = "/sys/class/leds/green:lan"
o.rmempty = true  -- LED 是可选的

o = s:option(Value, "led_red", translate("Red LED Path"),
             translate("Sysfs path for error indicator (e.g., /sys/class/leds/red:sys)"))
o.default = "/sys/class/leds/red:sys"
o.placeholder = "/sys/class/leds/red:sys"
o.rmempty = true  -- LED 是可选的

return m
