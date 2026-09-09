-- Copyright (C) 2024 Outdoor Backup Project
-- Licensed under GPL-2.0-only

local m, s, o

local function submitted_or_saved(option, section)
	local value = option:formvalue(section)
	if value ~= nil then
		return value
	end
	return option:cfgvalue(section)
end

local function valid_uuid(value)
	return value and value:match("^[A-Za-z0-9-]+$") ~= nil
end

local function valid_mount(value)
	return value and value ~= "" and value ~= "/" and value:match("^/") and
		not value:match("[%c]") and not value:find("//", 1, true) and
		not value:find("/./", 1, true) and not value:find("/../", 1, true) and
		value:sub(-2) ~= "/." and value:sub(-3) ~= "/.."
end

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

local enabled = o

o = s:option(Value, "target_mount", translate("Target SSD Mount Point"),
	translate("Persistent fstab mount for the target SSD. This form never formats or mounts disks."))
o.default = "/mnt/ssd"
o.placeholder = "/mnt/ssd"
o.rmempty = false
o.validate = function(self, value)
	if valid_mount(value) then
		return value
	end
	return nil, translate("Target mount must be an absolute, non-root path without unsafe segments")
end

local target_mount = o

o = s:option(Value, "target_uuid", translate("Target SSD UUID"),
	translate("Confirm the actual SSD UUID from block info; leave empty only while auto backup is disabled."))
o.default = ""
o.placeholder = "Actual SSD UUID from block info (do not generate a value)"
o.rmempty = true
o.validate = function(self, value)
	if valid_uuid(value) then
		return value
	end
	return nil, translate("Target SSD UUID may contain only letters, digits, and hyphens")
end

local target_uuid = o

enabled.validate = function(self, value, section)
	if value ~= "1" then
		return value
	end
	if not valid_uuid(submitted_or_saved(target_uuid, section)) then
		return nil, translate("Target SSD UUID is required when auto backup is enabled")
	end
	if not valid_mount(submitted_or_saved(target_mount, section)) then
		return nil, translate("Target mount must be an absolute, non-root path without unsafe segments")
	end
	return value
end

o = s:option(Value, "backup_root", translate("Backup Root Directory"),
	translate("Directory where all SD card backups will be stored; it must be a strict child of the target SSD mount."))
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
