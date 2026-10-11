-- Fixed runtime adapters. No browser-provided command, source path or argv.
local json = require 'luci.jsonc'
local util = require 'luci.util'
local M = {}
local base = '/opt/outdoor-backup/scripts/'

-- Lua 5.1 popen:close() does not reliably expose the exit status. A shell-owned
-- trailing status record avoids interpreting nonzero stdout as successful JSON.
-- Args: internally constructed shell command. Returns stdout/code or nil/3.
local function run(command)
    local pipe = io.popen('exec 9>&-; (' .. command .. ') 2>/dev/null; printf "\\nOB_LUCI_EXIT:%s\\n" "$?"', 'r')
    if not pipe then return nil, 3 end
    local output = pipe:read('*a')
    pipe:close()
    if type(output) ~= 'string' then return nil, 3 end
    local body, code = output:match('^(.*)\nOB_LUCI_EXIT:(%d+)\n$')
    code = tonumber(code) or 3
    if code ~= 0 then return nil, code end
    return body, 0
end

-- Exact objects prevent accidental metadata or future schema leakage into UI.
local function exact(object, keys)
    if type(object) ~= 'table' then return false end
    local expected = {}
    for _, key in ipairs(keys) do expected[key] = true end
    for key in pairs(object) do if not expected[key] then return false end end
    for key in pairs(expected) do if object[key] == nil then return false end end
    return true
end
local function integer(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value) and value < math.huge
end
local function text(value)
    return type(value) == 'string' and value ~= ''
end

-- Args: decoded probe. Returns boolean; accepts the delivered v1 contract only.
function M.valid_probe(document)
    if not exact(document, {'version','parser_profile','modules','limits','metadata_profile','mountinfo_required'}) or
        document.version ~= 1 or document.parser_profile ~= 'media-date-v1' or
        document.metadata_profile ~= 'fast-whitelist-v1' or document.mountinfo_required ~= true then return false end
    if not exact(document.modules, {'Image::ExifTool','JSON::PP','Digest::SHA','Time::Local'}) or
        not exact(document.limits, {'files','routes_bytes','xml_bytes'}) then return false end
    for _, version in pairs(document.modules) do if not text(version) then return false end end
    return document.limits.files == 50000 and document.limits.routes_bytes == 67108864 and
        document.limits.xml_bytes == 8388608
end

-- Read-only, actual module-loading capability probe, never just an existence test.
function M.probe()
    local output = run('/usr/bin/perl ' .. base .. 'media-date-plan.pl probe')
    local document = output and json.parse(output)
    if not M.valid_probe(document) then return nil, 'Date capability unavailable or invalid; install the optional date package and its ExifTool/Perl modules' end
    return document
end

-- Source only fixed root-managed runtime config code. config_load applies the
-- exact defaults < legacy < explicit UCI precedence and validates effective roots.
-- No values are interpolated into this script, and no output is ever evaluated.
function M.config()
    local script = [[. /opt/outdoor-backup/scripts/config.sh || exit 3
config_load || exit 2
jq -cn --arg layout "$BACKUP_LAYOUT" --arg root "$BACKUP_ROOT" --arg target "$TARGET_MOUNT" --arg uuid "$TARGET_UUID" --arg library "$LIBRARY_ROOT" --arg offset "$ARCHIVE_OFFSET_MINUTES" --arg source "$MOUNT_POINT" '{backup_layout:$layout,backup_root:$root,target_mount:$target,target_uuid:$uuid,library_root:$library,archive_offset_minutes:$offset,mount_point:$source}' ]]
    local output, code = run('/bin/sh -c ' .. util.shellquote(script))
    local document = output and json.parse(output)
    if not exact(document, {'backup_layout','backup_root','target_mount','target_uuid','library_root','archive_offset_minutes','mount_point'}) then return nil, code ~= 0 and code or 3 end
    for _, value in pairs(document) do if type(value) ~= 'string' then return nil, 3 end end
    if document.backup_layout ~= 'mirror' and document.backup_layout ~= 'date' then return nil, 2 end
    return document, 0
end

-- Args: preview JSON object and effective config. Returns boolean.
function M.valid_preview(document, config)
    if not exact(document, {'version','layout','backup_root','target_uuid','cards','total_size_bytes','total_cards'}) or
        document.version ~= 1 or document.layout ~= 'mirror' or document.backup_root ~= config.backup_root or
        document.target_uuid ~= config.target_uuid or type(document.cards) ~= 'table' or
        not integer(document.total_size_bytes) or not integer(document.total_cards) then return false end
    local total, count, seen = 0, 0, {}
    for index, card in pairs(document.cards) do
        if not integer(index) or index < 1 or index > #document.cards or
            not exact(card, {'uuid','display_name','size_bytes','path'}) or not text(card.uuid) or
            not card.uuid:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') or
            seen[card.uuid] or type(card.display_name) ~= 'string' or not integer(card.size_bytes) or
            card.path ~= config.backup_root .. '/' .. card.uuid then return false end
        seen[card.uuid] = true
        count, total = count + 1, total + card.size_bytes
    end
    return count == #document.cards and count == document.total_cards and total == document.total_size_bytes
end

-- jsonc loses the distinction between [] and {}. Check top-level lexical shape
-- after decoding, ignoring all quoted values; never infer array type from ipairs.
-- Args: valid JSON text. Returns true for unique top-level keys and cards array.
local function preview_shape(output)
    local depth, index, cards, seen = 0, 1, false, {}
    while index <= #output do
        local char = output:sub(index, index)
        if char == '"' then
            local start = index
            index = index + 1
            while index <= #output and output:sub(index, index) ~= '"' do
                if output:sub(index, index) == '\\' then index = index + 1 end
                index = index + 1
            end
            local token = output:sub(start, index)
            local suffix = output:sub(index + 1):match('^%s*:%s*(.)')
            if depth == 1 and suffix then
                local key = json.parse('[' .. token .. ']')[1]
                if seen[key] then return false end
                seen[key] = true
                if key == 'cards' then
                    if suffix ~= '[' then return false end
                    cards = true
                end
            end
        elseif char == '{' or char == '[' then
            depth = depth + 1
        elseif char == '}' or char == ']' then
            depth = depth - 1
        end
        index = index + 1
    end
    return cards
end

-- Args: boolean preview, effective validated config. No user root or force argv.
-- Each manager invocation independently rechecks admission, ownership and roots.
function M.cleanup(preview, config)
    if config.backup_layout ~= 'mirror' then return nil, 4 end
    local command = '/bin/sh ' .. base .. 'backup-manager.sh ' ..
        (preview and 'cleanup-preview ' or 'cleanup ') .. util.shellquote(config.backup_root) ..
        (preview and '' or ' 1')
    local output, code = run(command)
    if code ~= 0 then return nil, code end
    if not preview then return {success=true}, 0 end
    local document = json.parse(output)
    if not M.valid_preview(document, config) or not preview_shape(output) then return nil, 3 end
    return document, 0
end

-- Args: decoded library marker. Returns true only for the delivered v1 schema.
function M.valid_library(document)
    return exact(document, {'version','library_id','layout','parser_profile','archive_offset_minutes'}) and
        document.version == 1 and document.layout == 'date' and document.parser_profile == 'media-date-v1' and
        text(document.library_id) and
        document.library_id:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil and
        type(document.archive_offset_minutes) == 'number' and
        math.abs(document.archive_offset_minutes) <= 840 and
        document.archive_offset_minutes == math.floor(document.archive_offset_minutes)
end

-- Read only an existing library marker through the delivered schema validator.
-- Args: validated library path. Returns marker or nil; does not initialize anything.
function M.library(path)
    local output = run('/usr/bin/perl ' .. base .. 'media-date-plan.pl validate-library ' ..
        util.shellquote(path .. '/.outdoor-backup/library.json'))
    local document = output and json.parse(output)
    if not M.valid_library(document) then return nil end
    return document
end
M.exit_http = {[0]=200,[1]=400,[2]=400,[3]=500,[4]=409,[5]=409,[130]=409,[143]=409}
return M
