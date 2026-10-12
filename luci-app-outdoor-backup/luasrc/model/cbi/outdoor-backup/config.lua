-- Copyright (C) 2024 Outdoor Backup Project
-- Licensed under GPL-2.0-only

local target_discovery = require "luci.model.outdoor-backup.target"
local media = require "luci.model.outdoor-backup.media"
local effective = media.config()
local m, s, o
local selected_values = {}

-- Derive conventional children from a normalized mount, never from timezone or
-- browser selector text. Args: mount and child name. Returns a path or nil.
local function child_root(mount, child)
    return type(mount) == "string" and mount:gsub("/+$", "") .. "/" .. child or nil
end

local function configured(value)
    return type(value) == "string" and value ~= ""
end

local function submitted_or_saved(option, section)
    local value = option:formvalue(section)
    if value ~= nil then
        return value
    end
    return option:cfgvalue(section)
end

local function valid_uuid(value)
    return type(value) == "string" and value:match("^[A-Za-z0-9-]+$") ~= nil
end

local function valid_mount(value)
    return type(value) == "string" and value ~= "" and value ~= "/" and value:match("^/") and
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
o.selection_mounts = {}

local initial_document, initial_error = target_discovery.list()
if initial_document then
    local initial_suffix = backup_root_suffix(initial_document.current) or "/SDMirrors"
    for _, candidate in ipairs(initial_document.targets) do
        local selection = selector_value(candidate)
        local root = candidate.mount .. initial_suffix
        o.selection_roots[selection] = root
        o.selection_mounts[selection] = candidate.mount
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
o.rmempty = false
o.validate = function(self, value)
    if valid_mount(value) then
        return value
    end
    return nil, translate("SD card mount point must be an absolute path without unsafe segments")
end

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

-- Keep backup_root a mirror root; date has its own explicitly chosen root.
o = s:option(ListValue, "backup_layout", translate("Backup Layout"),
    translate("Mirror remains the default. Date requires the optional date package, ExifTool and Perl modules; saving checks the real helper schema. Runtime admission remains authoritative. Configuration changes never rewrite a running task snapshot."))
o:value("mirror", translate("Mirror (default)"))
o:value("date", translate("Date library"))
o.default = "mirror"
o.rmempty = false
local layout = o

o = s:option(Value, "library_root", translate("Date Library Root"),
    translate("A separate direct child of the target mount, never equal to, inside or above the mirror root. Use a new empty library; no automatic migration. Do not manually rename managed dates, source directories or media paths."))
o.placeholder = "/mnt/ssd/MediaLibrary"
-- Empty means inherit the date-only derived root, not explicit root intent.
o.default = (effective and effective.library_root) or ""
o.rmempty = true
-- cfgvalue may already reflect target_mount staged earlier in native parse.
-- Date defaults must still be written; absent mirror intent has empty formvalue.
o.forcewrite = true
local library_root = o

o = s:option(Value, "archive_offset_minutes", translate("Fixed Archive Offset (minutes)"),
    translate("Canonical integer -840..840; new date libraries default to 480 (UTC+08:00). An unconfigured offset inherits an existing library policy, which cannot be changed online; changing UCI cannot rewrite it or a running snapshot. No travel timezone or DST guessing."))
o.rmempty = true
local offset = o

-- Missing UCI values inherit the same runtime effective legacy/default values,
-- without parsing or sourcing legacy shell in Lua.
for _, field in ipairs({target_mount, target_uuid, backup_root, source_mount, layout, library_root, offset}) do
    field.cfgvalue = function(self, section)
        local saved = self.map.uci:get("outdoor-backup", section, self.option)
        return saved or (effective and effective[self.option]) or self.default
    end
end

-- Display defaults are not date intent. Preserve explicit UCI/legacy values;
-- only untouched conventional roots follow a manually changed target mount.
local initial_target = target_mount:cfgvalue("config")
local initial_library = library_root:cfgvalue("config")
local initial_backup = backup_root:cfgvalue("config")
local library_intent = configured(initial_library)

library_root.cfgvalue = function(self, section)
    local saved = self.map.uci:get("outdoor-backup", section, self.option)
    return configured(saved) and saved or
        (configured(initial_library) and initial_library or child_root(target_mount:cfgvalue(section), "MediaLibrary"))
end
library_root.formvalue = function(self, section)
    local value = self.map:formvalue(self:cbid(section))
    local target = submitted_or_saved(target_mount, section)
    local conventional = child_root(initial_target, "MediaLibrary")
    if (not library_intent or initial_library == conventional) and
        (value == "" or value == conventional or value == child_root(target, "MediaLibrary")) then
        local date_intent = library_intent or submitted_or_saved(layout, section) == "date"
        return date_intent and child_root(target, "MediaLibrary") or ""
    end
    return value
end

local original_backup_formvalue = backup_root.formvalue
backup_root.formvalue = function(self, section)
    local value = original_backup_formvalue(self, section)
    if not selected_values[section] and initial_backup == child_root(initial_target, "SDMirrors") and
        value == initial_backup then
        return child_root(submitted_or_saved(target_mount, section), "SDMirrors")
    end
    return value
end

-- Marker I/O is a read-only UI concern; runtime config_load remains pure. Empty
-- configured offset adopts an existing policy (including 0), not the new default.
local initial_offset = offset:cfgvalue("config")
-- Freeze the display baseline during model construction, before native parse
-- can stage target/library changes. Args: none. Returns canonical offset text.
local function initial_display_offset()
    if configured(initial_offset) then return initial_offset end
    local root = configured(initial_library) and initial_library or child_root(initial_target, "MediaLibrary")
    local marker = root and require("nixio.fs").lstat(root .. "/.outdoor-backup/library.json")
    local policy = marker and media.library(root)
    return policy and tostring(policy.archive_offset_minutes) or "480"
end
local displayed_offset = initial_display_offset()
offset.cfgvalue = function(self, section)
    return displayed_offset
end
offset.formvalue = function(self, section)
    local value = self.map:formvalue(self:cbid(section))
    if not configured(initial_offset) and (value == nil or value == displayed_offset) then return "" end
    return value
end

offset.validate = function(self, value)
    if value == "" then return value end
    local number = type(value) == "string" and tonumber(value)
    if number and number >= -840 and number <= 840 and number == math.floor(number) and
        tostring(number) == value then return value end
    return nil, translate("Offset must be a canonical integer from -840 to 840")
end

-- Validate the complete submitted layout before Map.save(), including fields
-- later in the form. No preview/status document is accepted as authorization.
layout.validate = function(self, value, section)
    if value ~= "mirror" and value ~= "date" then
        return nil, translate("Unknown backup layout")
    end
    if value == "mirror" then return value end
    local capability, reason = media.probe()
    if not capability then return nil, translate(reason) end
    local target = submitted_or_saved(target_mount, section)
    local mirror = submitted_or_saved(backup_root, section)
    local library = submitted_or_saved(library_root, section)
    if library == "" or library == nil then
        library = child_root(target, "MediaLibrary")
    end
    local source = submitted_or_saved(source_mount, section)
    if not valid_mount(target) or not valid_mount(library) or not valid_mount(mirror) or
        not valid_mount(source) or library:match("^(.*)/[^/]+$") ~= target or
        paths_intersect(library, mirror) or paths_intersect(library, source) then
        return nil, translate("Date root must be a direct target child, disjoint from mirror and source roots")
    end
    local configured_offset = submitted_or_saved(offset, section) or ""
    if type(configured_offset) ~= "string" then
        return nil, translate("Offset must be a canonical integer from -840 to 840")
    end
    local fs = require "nixio.fs"
    local marker = library .. "/.outdoor-backup/library.json"
    if fs.lstat(marker) then
        local policy = media.library(library)
        if not policy then return nil, translate("Existing library policy is invalid or unsupported") end
        if configured_offset ~= "" and tonumber(configured_offset) ~= policy.archive_offset_minutes then
            return nil, translate("Existing library offset cannot be changed online")
        end
    end
    return value
end

library_root.validate = function(self, value, section)
    local date_layout = submitted_or_saved(layout, section) == "date"
    if (value == "" or value == nil) and not date_layout then return value end
    if value == "" or value == nil then
        local target = submitted_or_saved(target_mount, section)
        value = child_root(target, "MediaLibrary")
    end
    local mirror = submitted_or_saved(backup_root, section)
    local source = submitted_or_saved(source_mount, section)
    if not valid_mount(value) or not valid_mount(mirror) or not valid_mount(source) then
        return nil, translate("Library root must be an absolute path without unsafe segments")
    end
    if paths_intersect(value, mirror) or paths_intersect(value, source) then
        return nil, translate("Library root must be disjoint from mirror and source roots")
    end
    return value
end

local original_backup_validate = backup_root.validate
backup_root.validate = function(self, value, section)
    local checked, reason = original_backup_validate(self, value)
    local target = submitted_or_saved(target_mount, section)
    if not checked then return nil, reason end
    if not valid_mount(target) or value:sub(1, #target + 1) ~= target .. "/" then
        return nil, translate("Mirror root must be a strict child of the target mount")
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

-- A CBI submit is also a write, even when called through a direct adapter.
local original_parse = m.parse
m.parse = function(self, ...)
    if self:formvalue("cbi.submit") and
        not require("luci.model.outdoor-backup.security").allow(true) then
        self.save = false
        return require("luci.cbi").FORM_INVALID
    end
    return original_parse(self, ...)
end

return m
