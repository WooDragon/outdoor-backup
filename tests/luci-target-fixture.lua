-- Shared target-form fixture. Load delivered adapters; replace only fixed I/O.
local M = {}
local config_script = [[. /opt/outdoor-backup/scripts/config.sh || exit 3
config_load || exit 2
jq -cn --arg layout "$BACKUP_LAYOUT" --arg root "$BACKUP_ROOT" --arg target "$TARGET_MOUNT" --arg uuid "$TARGET_UUID" --arg library "$LIBRARY_ROOT" --arg offset "$ARCHIVE_OFFSET_MINUTES" --arg source "$MOUNT_POINT" '{backup_layout:$layout,backup_root:$root,target_mount:$target,target_uuid:$uuid,library_root:$library,archive_offset_minutes:$offset,mount_point:$source}' ]]

-- Args: delivered luasrc path, target-only popen, mutable forms accessor.
-- Returns fixture controls; unexpected commands/RPC arguments fail immediately.
function M.install(luasrc, target_popen, forms)
    for _, name in ipairs({"media", "security"}) do
        package.preload["luci.model.outdoor-backup." .. name] = function()
            return assert(loadfile(luasrc .. "/model/outdoor-backup/" .. name .. ".lua"))()
        end
    end
    local json = require "luci.jsonc"
    local util = require "luci.util"
    local http = require "luci.http"
    local dispatcher = require "luci.dispatcher"
    local fixture = { method = "POST", writable = true, status = nil, calls = 0 }
    local config_command = '/bin/sh -c ' .. util.shellquote(config_script)
    local probe_command = '/usr/bin/perl /opt/outdoor-backup/scripts/media-date-plan.pl probe'
    local function wrapped(command)
        return 'exec 9>&-; (' .. command .. ') 2>/dev/null; printf "\\nOB_LUCI_EXIT:%s\\n" "$?"'
    end
    local probe = {
        version = 1, parser_profile = "media-date-v1", metadata_profile = "fast-whitelist-v1",
        mountinfo_required = true,
        modules = { ["Image::ExifTool"] = "13.00", ["JSON::PP"] = "4.00",
            ["Digest::SHA"] = "6.00", ["Time::Local"] = "1.30" },
        limits = { files = 50000, routes_bytes = 67108864, xml_bytes = 8388608 }
    }
    fixture.probe = probe
    -- Args: optional explicit UCI/legacy values. Defaults mirror leaves date intent empty.
    function fixture:configure(values)
        values = values or {}
        self.effective = {
            backup_layout = values.backup_layout or "mirror",
            target_mount = values.target_mount or "/mnt/ssd", target_uuid = values.target_uuid or "",
            backup_root = values.backup_root or "/mnt/ssd/SDMirrors",
            mount_point = values.mount_point or "/mnt/sdcard",
            library_root = values.library_root or "",
            archive_offset_minutes = values.archive_offset_minutes or ""
        }
    end
    fixture:configure()
    io.popen = function(command, mode)
        assert(mode == "r", "fixture only permits read-only helper pipes")
        if command == "/opt/outdoor-backup/scripts/target-list.sh 9>&-" then
            assert(target_popen, "unexpected target discovery")
            return target_popen(command, mode)
        end
        local document
        if command == wrapped(config_command) then document = fixture.effective
        elseif command == wrapped(probe_command) then document = fixture.probe
        else error("unexpected runtime command: " .. tostring(command)) end
        fixture.calls = fixture.calls + 1
        return {
            read = function(_, format)
                assert(format == "*a", "media requires whole-document reads")
                return json.stringify(document) .. "\nOB_LUCI_EXIT:0\n"
            end,
            close = function() return true end
        }
    end
    http.getenv = function(name)
        assert(name == "REQUEST_METHOD", "unexpected request environment lookup")
        return fixture.method
    end
    http.formvalue = function(name) return forms()[name] end
    http.status = function(code) fixture.status = code end
    http.header = function(name, value)
        assert(name == "Allow" and value == "POST", "unexpected rejection header")
    end
    http.prepare_content = function(content)
        assert(content == "application/json", "unexpected rejection content type")
    end
    http.write_json = function(document)
        assert(type(document.error) == "string", "rejection must carry a public error")
        for key in pairs(document) do assert(key == "error", "unexpected rejection field") end
    end
    util.ubus = function(object, method, arguments)
        assert(object == "session" and method == "access", "unexpected RPC")
        assert(arguments.ubus_rpc_session == "target-fixture-session" and
            arguments.scope == "uci" and arguments.object == "outdoor-backup" and
            (arguments["function"] == "read" or arguments["function"] == "write"),
            "unexpected session.access schema/context")
        for key in pairs(arguments) do
            assert(key == "ubus_rpc_session" or key == "scope" or key == "object" or
                key == "function", "unexpected session.access field")
        end
        return { access = arguments["function"] == "read" or fixture.writable }
    end
    -- Restore an explicit authenticated POST context for each independent case.
    function fixture:authenticate()
        dispatcher.context.authsession = "target-fixture-session"
        dispatcher.context.authtoken = "target-fixture-token"
        self.method, self.writable, self.status = "POST", true, nil
    end
    fixture:authenticate()
    return fixture
end

-- Exercise delivered config/probe schema acceptance and rejection, not fake guards.
-- Args: installed fixture. Returns no value; failed contracts abort the suite.
function M.verify(fixture)
    local media = require "luci.model.outdoor-backup.media"
    local effective, code = media.config()
    assert(code == 0 and effective.backup_layout == "mirror" and effective.library_root == "" and
        effective.archive_offset_minutes == "", "mirror default must preserve empty date intent")
    for key, value in pairs(fixture.effective) do
        assert(effective[key] == value and type(value) == "string", "effective config schema mismatch")
    end
    fixture.effective.extra = "unrecognized"
    assert(media.config() == nil, "effective config accepted an unknown key")
    fixture.effective.extra = nil
    fixture.effective.library_root = false
    assert(media.config() == nil, "effective config accepted a non-string")
    fixture.effective.library_root = ""
    assert(media.probe(), "delivered capability schema rejected valid fixture")
    fixture.probe.limits.files = 49999
    assert(media.probe() == nil, "capability accepted incompatible limits")
    fixture.probe.limits.files = 50000
    fixture.probe.extra = true
    assert(media.probe() == nil, "capability accepted an unknown key")
    fixture.probe.extra = nil
    print("fixture-contract: effective config, empty mirror intent, exact capability schema verified")
end
return M
