-- Copyright (C) 2024 Outdoor Backup Project
-- Licensed under GPL-2.0-only

local target_discovery = require "luci.model.outdoor-backup.target"
local m, s, o
local selected_values = {}

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

local function paths_intersect(left, right)
    return left == right or left:sub(1, #right + 1) == right .. "/" or
        right:sub(1, #left + 1) == left .. "/"
end

-- Return the former backup-root suffix only when it is a strict child of the
-- effective current target. Invalid legacy data gets the safe conventional root.
local function backup_root_suffix(current)
    local target_mount = current.target_mount
    local backup_root = current.backup_root
    if not valid_mount(target_mount) or not valid_mount(backup_root) then
        return nil
    end
    if backup_root:sub(1, #target_mount + 1) ~= target_mount .. "/" then
        return nil
    end
    return backup_root:sub(#target_mount + 1)
end

-- Encode the immutable candidate identity without parsing browser data later.
-- UUID length separates the UUID from the mount path unambiguously.
local function selector_value(candidate)
    return string.format("%d:%s%s", #candidate.uuid, candidate.uuid, candidate.mount)
end

local function selected_formvalue(option)
    return function(self, section)
        local values = selected_values[section]
        if values then
            return values[self.option]
        end
        return self.map:formvalue(self:cbid(section))
    end
end

-- Top-level Map: bind to UCI config "outdoor-backup".
m = Map("outdoor-backup",
        translate("Outdoor Backup Configuration"),
        translate("SD card automatic backup system for outdoor photography and field data collection"))

-- A single TypedSection avoids duplicate rendering.
s = m:section(TypedSection, "outdoor-backup", translate("Settings"))
s.anonymous = true
s.addremove = false

-- This virtual selector is intentionally not a UCI option. Its parse step only
-- supplies ordinary field formvalues; those existing fields remain the writers.
o = s:option(ListValue, "_target_selector", translate("Target Storage"),
    translate("Keep manual settings, or choose a mounted writable target. Choosing a target replaces mount, UUID, and backup root; it preserves a valid old root suffix or uses /SDMirrors. With JavaScript disabled, the manual-only fields remain visible but a chosen target still overrides them on save. It never mounts, formats, changes fstab, migrates backup data, or reads backup status. Refresh this page to rescan."))
o.default = "manual"
o:value("manual", translate("Manual / keep current settings"))
o.template = "outdoor-backup/target-selection"
o.selection_roots = {}

local initial_document, initial_error = target_discovery.list()
if initial_document then
    local initial_suffix = backup_root_suffix(initial_document.current) or "/SDMirrors"
    for _, candidate in ipairs(initial_document.targets) do
        local selection = selector_value(candidate)
        local root = candidate.mount .. initial_suffix
        o.selection_roots[selection] = root
        o:value(selection, string.format("%s — UUID %s — %s — %s — Backup root %s",
            candidate.device, candidate.uuid, candidate.mount, candidate.fstype, root))
    end
    if #initial_document.targets == 0 then
        o.description = o.description .. " " .. translate("No eligible mounted writable target was found; existing manual settings are unchanged.")
    end
else
    o.description = o.description .. " " .. translate(initial_error)
end

local target_selector = o

-- Register this after the selector so selected_values exists before enabled
-- validates a first-time selection with no saved UUID.
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
o.formvalue = selected_formvalue(o)

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
o.formvalue = selected_formvalue(o)

local target_uuid = o

o = s:option(Value, "backup_root", translate("Backup Root Directory"),
    translate("Directory where all SD card backups will be stored; it must be a strict child of the target SSD mount."))
o.default = "/mnt/ssd/SDMirrors"
o.placeholder = "/mnt/ssd/SDMirrors"
o.rmempty = false
o.validate = function(self, value)
    if valid_mount(value) then
        return value
    end
    return nil, translate("Backup root must be an absolute path without unsafe segments")
end
o.formvalue = selected_formvalue(o)

local backup_root = o

o = s:option(Value, "mount_point", translate("SD Card Mount Point"),
             translate("Temporary mount point for SD cards during backup"))
o.default = "/mnt/sdcard"
o.placeholder = "/mnt/sdcard"
o.datatype = "directory"
o.rmempty = false

local source_mount = o

target_selector.parse = function(self, section)
    selected_values[section] = nil
    local selected = self:formvalue(section)
    if selected == nil or selected == "manual" then
        return
    end

    local document, discovery_error = target_discovery.list()
    if not document then
        self:add_error(section, "invalid", translate(discovery_error))
        return
    end

    local chosen
    for _, candidate in ipairs(document.targets) do
        if selector_value(candidate) == selected then
            chosen = candidate
            break
        end
    end
    if not chosen then
        self:add_error(section, "invalid", translate("Selected target is no longer an eligible mounted writable target"))
        return
    end

    local suffix = backup_root_suffix(document.current) or "/SDMirrors"
    local final_backup_root = chosen.mount .. suffix
    local source = submitted_or_saved(source_mount, section)
    if not valid_mount(final_backup_root) or not valid_mount(source) or
        paths_intersect(final_backup_root, source) then
        self:add_error(section, "invalid", translate("Selected target backup root must not intersect the SD card mount point"))
        return
    end

    selected_values[section] = {
        target_mount = chosen.mount,
        target_uuid = chosen.uuid,
        backup_root = final_backup_root
    }
end

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

o = s:option(Flag, "debug", translate("Debug Mode"),
             translate("Enable verbose logging for troubleshooting"))
o.default = "0"
o.rmempty = false

-- LED indicators.
o = s:option(DummyValue, "_led_separator", translate("LED Indicators"))
o.rawhtml = true
o.value = "<hr style='margin: 15px 0; border: none; border-top: 1px solid #ccc;'>"

-- NOTE (PR #41 review finding 4): raw UCI cannot persist a genuinely empty
-- option value regardless of rmempty -- `option led_green ''` is dropped at
-- UCI's own parse/load time and is indistinguishable from the option never
-- having been set (verified against the real UCI CLI, not just this form).
-- So "no LED wired for this slot" is expressed with the literal string
-- "none", which config_load's config_resolve_led_sentinel() folds back to
-- an actual empty path before use. rmempty stays true only so that leaving
-- the field untouched still falls back to the board default, not so that a
-- deliberately blanked field can persist as empty -- it cannot, at the UCI
-- layer, no matter what this form does.

o = s:option(Value, "led_green", translate("Green LED 1 Path"),
    translate("Sysfs path for the first progress/status indicator (e.g., /sys/class/leds/green:wan). Enter \"none\" if no LED is wired for this slot."))
o.default = "/sys/class/leds/green:wan"
o.placeholder = "/sys/class/leds/green:wan"
o.rmempty = true

o = s:option(Value, "led_green2", translate("Green LED 2 Path"),
    translate("Sysfs path for the second progress/status indicator (e.g., /sys/class/leds/green:lan-1). Enter \"none\" if no LED is wired for this slot."))
o.default = "/sys/class/leds/green:lan-1"
o.placeholder = "/sys/class/leds/green:lan-1"
o.rmempty = true

o = s:option(Value, "led_green3", translate("Green LED 3 Path"),
    translate("Sysfs path for the third progress/status indicator (e.g., /sys/class/leds/green:lan-2). Enter \"none\" if no LED is wired for this slot."))
o.default = "/sys/class/leds/green:lan-2"
o.placeholder = "/sys/class/leds/green:lan-2"
o.rmempty = true

o = s:option(Value, "led_red", translate("Red LED Path"),
    translate("Sysfs path for error indicator (e.g., /sys/class/leds/red:power). Enter \"none\" if no LED is wired for this slot."))
o.default = "/sys/class/leds/red:power"
o.placeholder = "/sys/class/leds/red:power"
o.rmempty = true

return m
