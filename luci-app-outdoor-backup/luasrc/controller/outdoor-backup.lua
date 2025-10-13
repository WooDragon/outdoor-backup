--[[
Outdoor Backup - LuCI Controller
Purpose: Provides web interface and API endpoints for outdoor backup system
Author: Claude
License: GPL-2.0-only
]]--

module("luci.controller.outdoor-backup", package.seeall)

-- Load UCI module globally
local uci = require "luci.model.uci".cursor()

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
          call("api_update_alias"))

    entry({"admin", "services", "outdoor-backup", "api", "alias", "delete"},
          call("api_delete_alias"))

    -- Batch cleanup API routes
    entry({"admin", "services", "outdoor-backup", "api", "cleanup", "preview"},
          call("api_cleanup_preview"))

    entry({"admin", "services", "outdoor-backup", "api", "cleanup", "execute"},
          call("api_cleanup_execute"))
end

-------------------------------------------------------------------------------
-- Page Action Functions
-------------------------------------------------------------------------------

--[[
action_log - Display recent backup logs
Reads last 100 lines from backup.log and renders log page template
]]--
function action_log()
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
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- Read POST data
    luci.http.setfilehandler()
    local content_length = tonumber(luci.http.getenv("CONTENT_LENGTH")) or 0
    if content_length == 0 then
        luci.http.status(400)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Empty request body"})
    end

    local post_data = luci.http.content()
    local data = json.parse(post_data)

    -- Validate input
    if not data or not data.uuid or data.uuid == "" then
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
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local uuid = luci.http.formvalue("uuid")

    -- Validate input
    if not uuid or uuid == "" then
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

--[[
api_cleanup_preview - GET /api/cleanup/preview
Scans backup root directory and returns list of all backup cards with sizes
Used for displaying confirmation dialog before cleanup
Returns: {cards: [{uuid, display_name, size_bytes, path}], total_size_bytes, total_cards, backup_root}
]]--
function api_cleanup_preview()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"
    local util = require "luci.util"

    -- Get backup root directory from UCI using Lua API
    local backup_root = uci:get("outdoor-backup", "config", "backup_root") or "/mnt/ssd/SDMirrors"

    -- Check if backup root exists
    local stat = fs.stat(backup_root)
    if not stat or stat.type ~= "dir" then
        luci.http.status(404)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Backup root directory not found"})
    end

    -- Read alias mappings
    local alias_file = "/opt/outdoor-backup/conf/aliases.json"
    local aliases = {}
    local existing_content = fs.readfile(alias_file)
    if existing_content then
        local parsed = json.parse(existing_content)
        if parsed and parsed.aliases then
            aliases = parsed.aliases
        end
    end

    -- Helper function for calculating directory size recursively
    local function calculate_dir_size(path)
        local total = 0
        local stat = fs.stat(path)
        if not stat then return 0 end

        if stat.type == "dir" then
            for entry in fs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    total = total + calculate_dir_size(path .. "/" .. entry)
                end
            end
        else
            total = stat.size or 0
        end

        return total
    end

    -- Scan backup directory for UUID directories
    local cards = {}
    local total_size = 0

    for entry in fs.dir(backup_root) do
        local full_path = backup_root .. "/" .. entry
        local entry_stat = fs.stat(full_path)

        -- Check if it's a directory and looks like a UUID
        if entry_stat and entry_stat.type == "dir" and entry:match("^%x%x%x%x%x%x%x%x%-") then
            -- Calculate directory size using Lua recursion
            local size = calculate_dir_size(full_path)

            -- Get display name (alias or UUID prefix)
            local display_name = "SD_" .. entry:sub(1, 8)
            if aliases[entry] and aliases[entry].alias and aliases[entry].alias ~= "" then
                display_name = aliases[entry].alias
            end

            table.insert(cards, {
                uuid = entry,
                display_name = display_name,
                size_bytes = size,
                path = full_path
            })

            total_size = total_size + size
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        cards = cards,
        total_size_bytes = total_size,
        total_cards = #cards,
        backup_root = backup_root
    })
end

--[[
api_cleanup_execute - POST /api/cleanup/execute
Request body: {confirm_text: "清空备份数据"}
Executes batch cleanup after confirmation
Validates confirmation text before calling cleanup-all.sh script
NOTE: Always preserves aliases.json
]]--
function api_cleanup_execute()
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"
    local util = require "luci.util"

    -- Read POST data
    luci.http.setfilehandler()
    local content_length = tonumber(luci.http.getenv("CONTENT_LENGTH")) or 0
    if content_length == 0 then
        luci.http.status(400)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Empty request body"})
    end

    local post_data = luci.http.content()
    local data = json.parse(post_data)

    -- Validate confirmation text
    if not data or data.confirm_text ~= "清空备份数据" then
        luci.http.status(400)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Invalid confirmation text"})
    end

    -- Get backup root directory using UCI Lua API
    local backup_root = uci:get("outdoor-backup", "config", "backup_root") or "/mnt/ssd/SDMirrors"

    -- Check if backup root exists
    local stat = fs.stat(backup_root)
    if not stat or stat.type ~= "dir" then
        luci.http.status(404)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Backup root directory not found"})
    end

    -- Execute cleanup script
    -- cleanup-all.sh <backup_root> <keep_aliases>
    -- keep_aliases=1 means preserve aliases.json
    local cleanup_script = "/opt/outdoor-backup/scripts/cleanup-all.sh"

    -- Check if script exists
    if not fs.access(cleanup_script, "x") then
        luci.http.status(500)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({error = "Cleanup script not found or not executable"})
    end

    -- Execute cleanup (preserve aliases)
    -- IMPORTANT: Must use --force flag to pass safety check in cleanup-all.sh
    -- Use luci.util.shellquote to properly escape backup_root
    local cmd = string.format("%s --force %s 1 2>&1",
                              cleanup_script,
                              util.shellquote(backup_root))

    -- CRITICAL FIX: Only call once, not twice!
    -- Use luci.sys.call to get exit code directly
    local exit_code = luci.sys.call(cmd)

    if exit_code ~= 0 then
        luci.http.status(500)
        luci.http.prepare_content("application/json")
        return luci.http.write_json({
            success = false,
            error = "Cleanup failed",
            exit_code = exit_code
        })
    end

    -- Success
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        message = "Backup data cleaned successfully"
    })
end
