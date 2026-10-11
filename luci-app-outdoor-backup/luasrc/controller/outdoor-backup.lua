--[[
Outdoor Backup - LuCI Controller
Purpose: Provides web interface and API endpoints for outdoor backup system
Author: Claude
License: GPL-2.0-only
]]--

module("luci.controller.outdoor-backup", package.seeall)

-- Fixed runtime adapters and handler-level session authorization.
local security = require 'luci.model.outdoor-backup.security'
local media = require 'luci.model.outdoor-backup.media'

function index()
    -- Main menu entry: Services > Outdoor Backup
    entry({"admin", "services", "outdoor-backup"}, firstchild(), _("Outdoor Backup"), 60).dependent = false

    -- Page routes
    entry({"admin", "services", "outdoor-backup", "status"},
          template("outdoor-backup/status"), _("Status"), 1)

    entry({"admin", "services", "outdoor-backup", "config"},
          cbi("outdoor-backup/config"), _("Configuration"), 2)

    entry({"admin", "services", "outdoor-backup", "log"},
          call("action_log"), _("Logs"), 3)

    -- Data API routes
    entry({"admin", "services", "outdoor-backup", "api", "status"},
          call("api_status"))

    entry({"admin", "services", "outdoor-backup", "api", "aliases"},
          call("api_aliases"))

    -- Alias management API routes
    entry({"admin", "services", "outdoor-backup", "api", "alias", "update"},
          post("api_update_alias"))

    entry({"admin", "services", "outdoor-backup", "api", "alias", "delete"},
          post("api_delete_alias"))

    -- Batch cleanup API routes
    entry({"admin", "services", "outdoor-backup", "api", "cleanup", "preview"},
          call("api_cleanup_preview"))

    entry({"admin", "services", "outdoor-backup", "api", "cleanup", "execute"},
          post("api_cleanup_execute"))
end

-------------------------------------------------------------------------------
-- Page Action Functions
-------------------------------------------------------------------------------

--[[
action_log - Display recent backup logs
Reads last 100 lines from backup.log and renders log page template
]]--
function action_log()
    if not security.allow(false) then return end
    local fs = require "nixio.fs"
    local log_file = "/opt/outdoor-backup/log/backup.log"

    local content = fs.readfile(log_file)
    local log_content = "Log file not found"

    if content then
        -- Extract last 100 lines
        local lines = {}
        for line in content:gmatch("[^\n]+") do
            table.insert(lines, line)
        end

        local start = math.max(1, #lines - 99)
        local tail_lines = {}
        for i = start, #lines do
            table.insert(tail_lines, lines[i])
        end

        log_content = table.concat(tail_lines, "\n")
    end

    luci.template.render("outdoor-backup/log", {
        log_content = log_content
    })
end

-------------------------------------------------------------------------------
-- Data API Functions
-------------------------------------------------------------------------------

--[[
api_status - GET /api/status
Returns: status.json content with backup progress and history
Response: JSON object with current_backup, storage, history fields
]]--
function api_status()
    if not security.allow(false) then return end
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local status_file = "/opt/outdoor-backup/var/status.json"
    local content = fs.readfile(status_file)

    luci.http.prepare_content("application/json")
    if content then
        luci.http.write(content)
    else
        luci.http.status(404)
        luci.http.write_json({error = "Status file not found"})
    end
end

--[[
api_aliases - GET /api/aliases
Returns: All UUID-to-alias mappings from aliases.json
Response: JSON object with version and aliases fields
]]--
function api_aliases()
    if not security.allow(false) then return end
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local content = fs.readfile(alias_file)

    luci.http.prepare_content("application/json")
    if content then
        luci.http.write(content)
    else
        -- Return empty alias table if file doesn't exist
        luci.http.write_json({version = "1.0", aliases = {}})
    end
end

-------------------------------------------------------------------------------
-- Alias Management API Functions
-------------------------------------------------------------------------------

--[[
api_update_alias - POST /api/alias/update
Request body: {uuid: "xxx", alias: "Card Name", notes: "Optional notes"}
Creates or updates alias mapping for a UUID
Uses atomic write (temp file + rename) to prevent corruption
]]--
function api_update_alias()
    if not security.allow(true) then return end
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- LuCI XHR posts application/x-www-form-urlencoded objects, not JSON strings.
    local data = {uuid=luci.http.formvalue("uuid"), alias=luci.http.formvalue("alias"),
        notes=luci.http.formvalue("notes")}
    if (data.alias ~= nil and type(data.alias) ~= "string") or
        (data.notes ~= nil and type(data.notes) ~= "string") or
        (type(data.alias) == "string" and #data.alias > 256) or
        (type(data.notes) == "string" and #data.notes > 1024) then
        security.reject(400, "Invalid alias fields")
        return
    end

    -- Validate input
    if type(data.uuid) ~= "string" or data.uuid == "" then
        luci.http.status(400)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Missing or empty uuid field"})
    end

    -- Validate UUID format (basic check)
    if not data.uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
        luci.http.status(400)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Invalid UUID format"})
    end

    -- Read existing aliases
    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local aliases = {}
    local existing_content = fs.readfile(alias_file)
    if existing_content then
        local parsed = json.parse(existing_content)
        if parsed and parsed.aliases then
            aliases = parsed.aliases
        end
    end

    -- Update or create alias entry
    local now = os.time()
    if not aliases[data.uuid] then
        -- Create new entry
        aliases[data.uuid] = {
            created_at = now,
            last_seen = now
        }
    end

    -- Update fields
    aliases[data.uuid].alias = data.alias or ""
    aliases[data.uuid].notes = data.notes or ""
    -- Preserve existing last_seen if not updating it
    if not aliases[data.uuid].last_seen then
        aliases[data.uuid].last_seen = now
    end

    -- Atomic write: write to temp file then rename
    local temp_file = alias_file .. ".tmp"
    local new_content = json.stringify({
        version = "1.0",
        aliases = aliases
    }, true)  -- true = pretty print

    local success = false
    if fs.writefile(temp_file, new_content) then
        if fs.rename(temp_file, alias_file) then
            success = true
        else
            fs.unlink(temp_file)  -- Clean up temp file on rename failure
        end
    end

    if success then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true})
    else
        fs.unlink(temp_file)  -- Ensure cleanup
        luci.http.status(500)
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "Failed to write alias file"})
    end
end

--[[
api_delete_alias - DELETE /api/alias/delete?uuid=xxx
Removes alias mapping from aliases.json
NOTE: Does NOT delete backup data, only removes the alias mapping
]]--
function api_delete_alias()
    if not security.allow(true) then return end
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local uuid = luci.http.formvalue("uuid")

    -- Validate input
    if type(uuid) ~= "string" or not uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
        luci.http.status(400)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Missing uuid parameter"})
    end

    -- Read existing aliases
    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local aliases = {}
    local existing_content = fs.readfile(alias_file)
    if existing_content then
        local parsed = json.parse(existing_content)
        if parsed and parsed.aliases then
            aliases = parsed.aliases
        end
    end

    -- Check if alias exists
    if not aliases[uuid] then
        luci.http.status(404)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Alias not found"})
    end

    -- Delete alias mapping (not backup data)
    aliases[uuid] = nil

    -- Atomic write
    local temp_file = alias_file .. ".tmp"
    local new_content = json.stringify({
        version = "1.0",
        aliases = aliases
    }, true)

    local success = false
    if fs.writefile(temp_file, new_content) then
        if fs.rename(temp_file, alias_file) then
            success = true
        else
            fs.unlink(temp_file)  -- Clean up temp file on rename failure
        end
    end

    if success then
        luci.http.prepare_content("application/json")
        luci.http.write_json({success = true})
    else
        fs.unlink(temp_file)  -- Ensure cleanup
        luci.http.status(500)
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "Failed to write alias file"})
    end
end

-------------------------------------------------------------------------------
-- Batch Cleanup API Functions
-------------------------------------------------------------------------------

-- Args: preview boolean. Manager is the sole root/lease/precheck authority.
-- Nonzero stdout and private stderr never reach shared UI.
local function cleanup_response(preview)
    local config, code = media.config()
    local result
    if config then result, code = media.cleanup(preview, config) end
    luci.http.prepare_content("application/json")
    if code ~= 0 then
        local messages = {[1]="Invalid cleanup arguments", [2]="Invalid configured mirror root",
            [3]="Cleanup failed", [4]="Cleanup is unsupported for date layout",
            [5]="Backup service busy or unavailable", [130]="Cleanup cancelled", [143]="Cleanup cancelled"}
        luci.http.status(media.exit_http[code] or 500)
        return luci.http.write_json({error=messages[code] or "Cleanup failed", exit_code=code})
    end
    luci.http.write_json(result)
end

-- GET preview; read permission only, no arbitrary root request parameter.
function api_cleanup_preview()
    if not security.allow(false) then return end
    cleanup_response(true)
end

-- POST form: token, confirm_text. Preview is not an authorization capability.
function api_cleanup_execute()
    if not security.allow(true) then return end
    if luci.http.formvalue("confirm_text") ~= "清空备份数据" then
        security.reject(400, "Invalid confirmation text")
        return
    end
    cleanup_response(false)
end
