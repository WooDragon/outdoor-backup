#!/bin/sh
# Behavior tests for the LuCI target-storage selector. The delivered CBI model
# is loaded under a real LuCI Map and isolated UCI confdir/savedir.
set -eu

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        -v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
        /bin/ash /src/test-luci-target-selection.sh --inside
fi

mkdir -p /var/lock
opkg update >/dev/null
opkg install lua luci-compat uci libuci-lua >/dev/null

lua - /src/luci-app-outdoor-backup/luasrc/model/cbi/outdoor-backup/config.lua <<'LUA'
local model = assert(arg[1], "missing config model")
local luasrc = assert(model:match("^(.*)/model/cbi/outdoor%-backup/config%.lua$"), "invalid model path")
package.preload["luci.model.outdoor-backup.target"] = function()
    return assert(loadfile(luasrc .. "/model/outdoor-backup/target.lua"))()
end
_G.L = {
    http = {},
    ctx = { authsession = "test", request_path = {}, request_args = {} },
    dispatcher = {
        lang = "en",
        build_url = function() return "" end,
        menu_json = function() return {} end,
        error404 = function() end,
        error500 = function() end,
        is_authenticated = function() return nil end
    }
}
package.preload["luci.config"] = function()
    return {}
end
local uci = require "luci.model.uci"
local cbi = require "luci.cbi"
Map, TypedSection, Flag, Value, ListValue, DummyValue = cbi.Map, cbi.TypedSection, cbi.Flag, cbi.Value, cbi.ListValue, cbi.DummyValue
local http = require "luci.http"

local cases, assertions, failed = 0, 0, 0
local forms, helper_outputs, helper_commands = {}, {}, {}
local original_popen = io.popen

local function fail(message)
    io.stderr:write("FAIL: " .. message .. "\n")
    failed = failed + 1
end

local function check(value, message)
    assertions = assertions + 1
    if not value then fail(message) end
end

local function begin(id, description)
    cases = cases + 1
    print("CASE " .. id .. ": " .. description)
end

local function json(targets, target_mount, backup_root)
    local parts = {}
    for _, target in ipairs(targets) do
        parts[#parts + 1] = string.format('{"device":"%s","uuid":"%s","mount":"%s","fstype":"%s"}',
            target.device, target.uuid, target.mount, target.fstype)
    end
    return string.format('{"targets":[%s],"current":{"target_mount":"%s","backup_root":"%s"}}',
        table.concat(parts, ","), target_mount, backup_root)
end

local one_target = { { device = "/dev/sdb1", uuid = "SSD-ONE", mount = "/mnt/target-one", fstype = "ext4" } }
local same_uuid_targets = {
    { device = "/dev/sdb1", uuid = "SSD-SAME", mount = "/mnt/old-mount", fstype = "ext4" },
    { device = "/dev/sdc1", uuid = "SSD-SAME", mount = "/mnt/new-mount", fstype = "xfs" }
}

io.popen = function(command, mode)
    helper_commands[#helper_commands + 1] = { command = command, mode = mode }
    local fixture = table.remove(helper_outputs, 1)
    if not fixture then return nil end
    return {
        read = function(_, format)
            check(format == "*a", "helper is read as a complete document")
            return fixture.output
        end,
        close = function()
            return fixture.ok
        end
    }
end

http.formvalue = function(key)
    return forms[key]
end
http.formvaluetable = function()
    return {}
end

function translate(value) return value end

local native_uci = require "uci"
local original_cursor = native_uci.cursor
local current_confdir, current_savedir
uci.cursor = function()
    return original_cursor(current_confdir, current_savedir)
end

local function temporary_dir(label)
    local path = "/tmp/luci-target-selection-" .. label .. "-" .. tostring(math.random(1000000))
    assert(os.execute("mkdir -p " .. path .. "/conf " .. path .. "/save") == 0, "create fixture directories")
    return path
end

local function write_config(confdir, values)
    local file = assert(io.open(confdir .. "/outdoor-backup", "w"))
    file:write("config outdoor-backup 'config'\n")
    for key, value in pairs(values) do
        file:write(string.format("\toption %s '%s'\n", key, value))
    end
    file:close()
end

local function queue(...)
    helper_outputs = {}
    for _, fixture in ipairs({ ... }) do
        helper_outputs[#helper_outputs + 1] = fixture
    end
end

local function helper(output, ok)
    return { output = output, ok = ok ~= false }
end

local function form_value(name)
    return "cbid.outdoor-backup.config." .. name
end

local function load_map(label, stored, page_output, parse_output)
    local root = temporary_dir(label)
    current_confdir, current_savedir = root .. "/conf", root .. "/save"
    write_config(current_confdir, stored)
    forms = {}
    queue(helper(page_output, true), helper(parse_output or page_output, true))
    local map = assert(dofile(model), "delivered model did not return a Map")
    return map, root
end

local function render_target_template(contents, selector)
    local template = require "luci.template"
    local chunks = {}
    local compiled = template.Template(nil, contents)
    compiled.viewns = setmetatable({
        write = function(chunk)
            chunks[#chunks + 1] = chunk
        end,
        include = function(name)
            assert(name == "cbi/valueheader" or name == "cbi/valuefooter", "unexpected template include: " .. tostring(name))
        end
    }, { __index = template.context.viewns })
    compiled:render({
        self = selector,
        section = "config",
        cbid = "cbid.outdoor-backup.config._target_selector",
        luci = { util = require "luci.util" }
    })
    return table.concat(chunks)
end

local function submit(map, values)
    forms = { ["cbi.submit"] = "1" }
    for name, value in pairs(values) do
        if name == "enabled" or name == "debug" then
            forms["cbi.cbe.outdoor-backup.config." .. name] = "1"
            if value == "1" then
                forms[form_value(name)] = "1"
            end
        else
            forms[form_value(name)] = value
        end
    end
    map:parse()
end

local function reloaded(root, option)
    local cursor = original_cursor(root .. "/conf", root .. "/save")
    assert(cursor:load("outdoor-backup"), "reload saved UCI")
    return cursor:get("outdoor-backup", "config", option)
end

local function saved_config(root)
    local file = io.open(root .. "/save/outdoor-backup", "r")
    if not file then return "" end
    local content = file:read("*a")
    file:close()
    return content
end

local function apply_saved_config(root)
    local staged = original_cursor(root .. "/conf", root .. "/save")
    assert(staged:load("outdoor-backup"), "load staged UCI")
    assert(staged:commit("outdoor-backup"), "commit staged UCI")
    local cursor = original_cursor(root .. "/conf")
    assert(cursor:load("outdoor-backup"), "reload applied saved UCI")
    return cursor
end

assert(os.execute("mkdir -p /mnt/old-target/CustomMirrors /mnt/old-target/SDMirrors /mnt/old-target/Legacy /mnt/new-mount/SDMirrors /mnt/sdcard /mnt/offline-ssd/OldRoot") == 0, "create directory datatype fixtures")

local function base_values()
    return {
        enabled = "1",
        target_mount = "/mnt/old-target",
        target_uuid = "OLD-UUID",
        backup_root = "/mnt/old-target/CustomMirrors",
        mount_point = "/mnt/sdcard",
        debug = "0"
    }
end

begin("S01", "manual selector preserves existing stored values")
do
    local map, root = load_map("manual", base_values(), json(one_target, "/mnt/old-target", "/mnt/old-target/CustomMirrors"))
    submit(map, { _target_selector = "manual", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/CustomMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S01 manual submission remains valid")
    check(reloaded(root, "target_mount") == "/mnt/old-target", "S01 mount changed")
    check(reloaded(root, "target_uuid") == "OLD-UUID", "S01 UUID changed")
    check(reloaded(root, "backup_root") == "/mnt/old-target/CustomMirrors", "S01 root changed")
end

begin("S02", "first selected candidate enables backup without a preexisting root")
do
    local initial = base_values()
    initial.target_uuid = ""
    local map, root = load_map("selected-first", initial, json(one_target, "/mnt/old-target", "/mnt/old-target/CustomMirrors"))
    submit(map, { _target_selector = "7:SSD-ONE/mnt/target-one", enabled = "1", target_mount = "", target_uuid = "", backup_root = "/forged/root", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S02 first selected candidate invalid")
    check(reloaded(root, "target_mount") == "/mnt/target-one", "S02 mount was not selected")
    check(reloaded(root, "target_uuid") == "SSD-ONE", "S02 UUID was not selected")
    check(reloaded(root, "backup_root") == "/mnt/target-one/CustomMirrors", "S02 root suffix not preserved")
    check(not io.open("/mnt/target-one/CustomMirrors", "r"), "S02 form created the selected backup root")
    check(reloaded(root, "_target_selector") == nil, "S02 virtual selector became a UCI option")
end

begin("S03", "legacy-only normalized root suffix is retained")
do
    local stored = base_values()
    local map, root = load_map("legacy", stored, json(one_target, "/mnt/old-target", "/mnt/old-target/Legacy/"), json(one_target, "/mnt/old-target", "/mnt/old-target/Legacy/"))
    submit(map, { _target_selector = "7:SSD-ONE/mnt/target-one", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/ignored", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S03 legacy-only selection invalid")
    check(reloaded(root, "backup_root") == "/mnt/target-one/Legacy/", "S03 normalized legacy suffix not retained")
end

begin("S04", "same UUID candidates remain distinguished by mount")
do
    local map, root = load_map("same-uuid", base_values(), json(same_uuid_targets, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "8:SSD-SAME/mnt/new-mount", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S04 same-UUID selection invalid")
    check(reloaded(root, "target_mount") == "/mnt/new-mount", "S04 matched first UUID rather than UUID+mount")
end

begin("S05", "forged or stale selector saves no fields")
do
    local map, root = load_map("forged", base_values(), json(one_target, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "7:SSD-ONE/mnt/forged", enabled = "1", target_mount = "/mnt/attacker", target_uuid = "ATTACKER", backup_root = "/mnt/attacker/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(not map.save, "S05 forged selector accepted")
    check(reloaded(root, "target_mount") == "/mnt/old-target", "S05 invalid submission leaked into savedir")
    check(reloaded(root, "target_uuid") == "OLD-UUID", "S05 invalid UUID leaked into savedir")
end

begin("S06", "later invalid field prevents the whole selected transaction")
do
    local map, root = load_map("transaction", base_values(), json(one_target, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "7:SSD-ONE/mnt/target-one", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/SDMirrors", mount_point = "", debug = "0" })
    check(not map.save, "S06 invalid later field accepted")
    check(reloaded(root, "target_mount") == "/mnt/old-target", "S06 partial target mount saved")
    check(reloaded(root, "backup_root") == "/mnt/old-target/CustomMirrors", "S06 partial backup root saved")
end

begin("S07", "empty helper result remains manual and writes no partial target")
do
    local map, root = load_map("empty", base_values(), json({}, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "manual", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S07 empty discovery broke manual form")
    check(reloaded(root, "target_uuid") == "OLD-UUID", "S07 empty discovery changed UUID")
end

begin("S08", "bad helper JSON is not partially consumed")
do
    local map, root = load_map("bad-json", base_values(), "{\"targets\":[", "{\"targets\":[")
    submit(map, { _target_selector = "7:SSD-ONE/mnt/target-one", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(not map.save, "S08 malformed helper output accepted")
    check(reloaded(root, "target_mount") == "/mnt/old-target", "S08 malformed helper leaked target")
end

begin("S09", "failed or truncated helper stdout is not consumed")
do
    local map, root = load_map("failed-helper", base_values(), json(one_target, "/mnt/old-target", "/mnt/old-target/SDMirrors"), "{\"targets\":[")
    helper_outputs[1].ok = false
    submit(map, { _target_selector = "7:SSD-ONE/mnt/target-one", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(not map.save, "S09 failed helper stdout accepted")
    check(reloaded(root, "target_uuid") == "OLD-UUID", "S09 failed helper leaked UUID")
end

begin("S10", "manual offline legacy configuration remains editable")
do
    local values = base_values()
    local map, root = load_map("offline", values, json({}, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "manual", enabled = "1", target_mount = "/mnt/offline-ssd", target_uuid = "OFFLINE-UUID", backup_root = "/mnt/offline-ssd/OldRoot", mount_point = "/mnt/sdcard", debug = "1" })
    check(map.save, "S10 manual offline config rejected")
    check(reloaded(root, "target_mount") == "/mnt/offline-ssd", "S10 offline mount not saved")
    check(reloaded(root, "debug") == "1", "S10 other manual field not saved")
end

begin("S11", "disabled empty UUID removes the option and inherits later")
do
    local values = base_values()
    local map, root = load_map("disabled", values, json({}, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "manual", enabled = "0", target_mount = "/mnt/old-target", target_uuid = "", backup_root = "/mnt/old-target/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S11 disabled empty UUID rejected")
    check(not saved_config(root):find("option target_uuid", 1, true), "S11 savedir retained removed UUID")
    check(apply_saved_config(root):get("outdoor-backup", "config", "target_uuid") == nil, "S11 applied config did not inherit UUID")
end

begin("S12", "selected root cannot intersect the source mount")
do
    local target = { { device = "/dev/sdb1", uuid = "SSD-SOURCE", mount = "/mnt/sdcard", fstype = "ext4" } }
    local map, root = load_map("intersection", base_values(), json(target, "/mnt/old-target", "/mnt/old-target/SDMirrors"))
    submit(map, { _target_selector = "10:SSD-SOURCE/mnt/sdcard", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/SDMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(not map.save, "S12 source and selected root intersection accepted")
    check(reloaded(root, "target_mount") == "/mnt/old-target", "S12 intersecting target saved")
end

begin("S13", "invalid old root falls back to SDMirrors")
do
    local map, root = load_map("fallback", base_values(), json(one_target, "/mnt/old-target", "/mnt/unrelated/OldRoot"))
    submit(map, { _target_selector = "7:SSD-ONE/mnt/target-one", enabled = "1", target_mount = "/mnt/old-target", target_uuid = "OLD-UUID", backup_root = "/mnt/old-target/CustomMirrors", mount_point = "/mnt/sdcard", debug = "0" })
    check(map.save, "S13 fallback selection invalid")
    check(reloaded(root, "backup_root") == "/mnt/target-one/SDMirrors", "S13 invalid old root did not use SDMirrors")
end

begin("S14", "selected mode presents the actual derived root and hides manual inputs")
do
    local map = load_map("presentation", base_values(), json(one_target, "/mnt/old-target", "/mnt/old-target/CustomMirrors"))
    local selector
    for _, candidate in ipairs(map.children[1].children) do
        if candidate.option == "_target_selector" then
            selector = candidate
            break
        end
    end
    check(selector and selector.template == "outdoor-backup/target-selection", "S14 selector does not use the target-selection template")
    check(selector and selector.selection_roots["7:SSD-ONE/mnt/target-one"] == "/mnt/target-one/CustomMirrors", "S14 selected root differs from server derivation")
    check(selector and selector.vallist[2]:find("Backup root /mnt/target-one/CustomMirrors", 1, true), "S14 candidate label omits derived root")

    local template = assert(io.open(luasrc .. "/view/outdoor-backup/target-selection.htm", "r"))
    local contents = template:read("*a")
    template:close()
    check(contents:find('attr("data-roots", luci.util.serialize_json(self.selection_roots))', 1, true), "S14 root mapping does not use an escaped attribute")
    check(contents:find("summary.textContent", 1, true), "S14 selected root display is not text-only")
    check(not contents:find("innerHTML", 1, true), "S14 target template injects HTML")
    check(contents:find("row.style.display = manual ? '' : 'none'", 1, true), "S14 selected mode leaves manual inputs editable")
end

begin("S15", "helper invocation is fixed and receives no browser input")
for _, invocation in ipairs(helper_commands) do
    check(invocation.command == "/opt/outdoor-backup/scripts/target-list.sh 9>&-", "S15 helper command was not fixed")
    check(invocation.mode == "r", "S15 helper was not opened read-only")
end

begin("S16", "real LuCI template renders a native selector and escapes values")
do
    local page = json(one_target, "/mnt/target-one", "/mnt/target-one/SDMirrors")
    local previous_invocations = #helper_commands
    local map = load_map("runtime-template", base_values(), page)
    local invocation = helper_commands[previous_invocations + 1]
    check(invocation and invocation.command == "/opt/outdoor-backup/scripts/target-list.sh 9>&-",
        "S16 helper command was not fixed")
    check(invocation and invocation.mode == "r", "S16 helper was not opened read-only")
    local selector
    for _, candidate in ipairs(map.children[1].children) do
        if candidate.option == "_target_selector" then
            selector = candidate
            break
        end
    end
    assert(selector, "S16 Map has no real target selector")

    local template_file = assert(io.open(luasrc .. "/view/outdoor-backup/target-selection.htm", "r"))
    local contents = template_file:read("*a")
    template_file:close()
    local cbid = "cbid.outdoor-backup.config._target_selector"
    local rendered = render_target_template(contents, selector)

    check(rendered:find("<select", 1, true), "S16 rendered template has no native select")
    check(rendered:find('id="' .. cbid .. '"', 1, true) and rendered:find('name="' .. cbid .. '"', 1, true), "S16 native select id/name are incorrect")
    local manual_option
    for option_tag in rendered:gmatch("<option[^>]*>") do
        if option_tag:find('value="manual"', 1, true) then
            manual_option = option_tag
            break
        end
    end
    check(manual_option and manual_option:find("selected", 1, true), "S16 Manual option is not selected")
    check(rendered:find('value="7:SSD-ONE/mnt/target-one"', 1, true), "S16 current SSD option is missing")
    check(not rendered:find("data-ui-widget", 1, true), "S16 rendered template retains the legacy widget")
    check(not rendered:find(" style=", 1, true), "S16 template statically hides manual fields")

    local load_listener = rendered:find("window.addEventListener('load', function()", 1, true)
    local first_update = rendered:find("updateTargetFields();", 1, true)
    local next_update = first_update and rendered:find("updateTargetFields();", first_update + 1, true)
    check(rendered:find("var fieldNames = [ 'target_mount', 'target_uuid', 'backup_root' ]", 1, true)
        and load_listener and first_update and first_update > load_listener and not next_update,
        "S16 manual fields are not updated only by the load handler")

    local hostile_label = [[' " & <img src=x>]]
    local target_key = "7:SSD-ONE/mnt/target-one"
    selector.vallist[2] = hostile_label
    selector.selection_roots[target_key] = hostile_label
    local escaped = render_target_template(contents, selector)
    local escaped_option
    for option_text in escaped:gmatch("<option[^>]*>.-</option>") do
        if option_text:find('value="' .. target_key .. '"', 1, true) then
            escaped_option = option_text
            break
        end
    end
    local xml = require "luci.xml"
    local expected_label = xml.pcdata(hostile_label)
    -- Compare with LuCI's encoding; valid numeric entities need not be named entities.
    check(not escaped:find("<img", 1, true) and escaped_option
        and expected_label ~= hostile_label
        and escaped_option:find(expected_label, 1, true),
        "S16 untrusted option label is not escaped by LuCI")
    local expected_roots = xml.pcdata(require("luci.util").serialize_json(selector.selection_roots))
    check(escaped:find('data-roots="' .. expected_roots .. '"', 1, true),
        "S16 data-roots attribute differs from LuCI pcdata serialization")
end

check(cases == 16, "all required cases executed")
if assertions ~= 125 then
    fail(string.format("all required assertions executed (expected=125, actual=%d)", assertions))
end
if failed ~= 0 then
    print(string.format("cases=%d assertions=%d failed=%d", cases, assertions, failed))
    os.exit(1)
end
print(string.format("cases=%d assertions=%d failed=0", cases, assertions))
LUA
