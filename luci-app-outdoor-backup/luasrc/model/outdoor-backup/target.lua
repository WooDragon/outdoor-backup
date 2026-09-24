-- Copyright (C) 2026 Outdoor Backup Project
-- Licensed under GPL-2.0-only

-- Read the fixed target-list helper contract for the LuCI configuration page.
-- The command intentionally has no parameters: browser values must never reach a shell.
local jsonc = require "luci.jsonc"

local M = {}
local TARGET_LIST = "/opt/outdoor-backup/scripts/target-list.sh"

local function valid_string(value)
    return type(value) == "string" and value ~= ""
end

local function valid_target(candidate)
    return type(candidate) == "table" and
        valid_string(candidate.device) and
        valid_string(candidate.uuid) and
        valid_string(candidate.mount) and
        valid_string(candidate.fstype)
end

local function valid_current(current)
    return type(current) == "table" and
        type(current.target_mount) == "string" and
        type(current.backup_root) == "string"
end

-- Validate the complete helper document before any value is consumed.
-- Returns: document table, or nil plus a stable reason for the CBI page.
local function parse_document(output)
    local document = jsonc.parse(output)
    if type(document) ~= "table" or type(document.targets) ~= "table" or
        not valid_current(document.current) then
        return nil, "Target discovery returned an invalid document"
    end

    for _, candidate in ipairs(document.targets) do
        if not valid_target(candidate) then
            return nil, "Target discovery returned an invalid candidate"
        end
    end

    return document
end

-- Run the unparameterized helper and reject stdout from a failed command.
-- Returns: document table, or nil plus a user-facing reason.
function M.list()
    -- Reserve the helper's anchor FD without changing the caller's descriptors.
    local process = io.popen(TARGET_LIST .. " 9>&-", "r")
    if not process then
        return nil, "Target discovery could not be started"
    end

    local output = process:read("*a")
    local closed = process:close()
    if closed ~= true then
        return nil, "Target discovery failed; existing manual settings were kept"
    end

    return parse_document(output)
end

return M
