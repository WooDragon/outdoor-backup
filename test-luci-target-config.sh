#!/bin/sh
# Model-level BDD tests for the LuCI target-storage form. This directly loads
# the delivered CBI model; it is not browser or device E2E coverage.
set -eu

IMAGE="openwrt/rootfs:x86_64-24.10.8"
IMAGE_DIGEST="sha256:9972a4b4747cd136abd597475d7b88c51a49fd849d0d53f069a2f4bf446061b9"

if [ "${1:-}" != "--inside" ]; then
    REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
    exec docker run --rm --platform linux/amd64 --network bridge \
        -v "$REPO_ROOT:/src:ro" "$IMAGE@$IMAGE_DIGEST" \
        /bin/ash /src/test-luci-target-config.sh --inside
fi

mkdir -p /var/lock
opkg update >/dev/null
opkg install lua luci-compat >/dev/null
CBI=/usr/lib/lua/luci/cbi.lua
[ -r "$CBI" ] || { printf '%s\n' 'FAIL: luci-compat did not provide cbi.lua' >&2; exit 1; }
grep -Fq 'return self.map:formvalue(self:cbid(section))' "$CBI" || {
    printf '%s\n' 'FAIL: installed CBI formvalue contract changed' >&2
    exit 1
}
grep -Fq 'if self.rmempty or self.optional then' "$CBI" || {
    printf '%s\n' 'FAIL: installed CBI empty-option contract changed' >&2
    exit 1
}

lua - /src/luci-app-outdoor-backup/luasrc/model/cbi/outdoor-backup/config.lua <<'LUA'
local model = assert(arg[1], "missing config model")
local cases, assertions, failed = 0, 0, 0

local function fail(message)
    io.stderr:write("FAIL: " .. message .. "\n")
    failed = failed + 1
end

local function check(value, message)
    assertions = assertions + 1
    if not value then fail(message) end
end

function translate(value) return value end
TypedSection, Flag, Value, DummyValue = "TypedSection", "Flag", "Value", "DummyValue"

function Map(config)
    local map = { config = config, submitted = {}, saved = {}, sections = {} }
    function map:formvalue(key) return self.submitted[key] end
    function map:section(kind, name)
        local section = { kind = kind, name = name, map = self, options = {} }
        function section:option(option_kind, option_name, title, description)
            local option = { kind = option_kind, option = option_name, title = title,
                description = description, map = self.map, section = self }
            function option:cbid(section_name)
                return "cbid." .. self.map.config .. "." .. section_name .. "." .. self.option
            end
            function option:formvalue(section_name)
                return self.map:formvalue(self:cbid(section_name))
            end
            function option:cfgvalue(section_name)
                return self.map.saved[section_name] and self.map.saved[section_name][self.option]
            end
            -- Match CBI's empty-value branch: rmempty permits removal without
            -- calling validate; non-empty values must pass the option validator.
            function option:can_save(section_name)
                local value = self:formvalue(section_name)
                if value and #value > 0 then
                    return self:validate(value, section_name) ~= nil
                end
                return self.rmempty == true
            end
            self.options[option_name] = option
            return option
        end
        self.sections[#self.sections + 1] = section
        return section
    end
    return map
end

local map = assert(dofile(model), "model did not return Map")
local section = map.sections[1]
local function option(name) return section.options[name] end
local function submit(name, value)
    map.submitted["cbid.outdoor-backup.config." .. name] = value
end
local function validate(name, value)
    local configured = option(name)
    if not configured or not configured.validate then return nil end
    return configured.validate(configured, value, "config")
end
local function begin(id, description)
    cases = cases + 1
    print("CASE " .. id .. ": " .. description)
end

begin("L01", "target fields have safe defaults and existing fields remain")
local target_mount_option = option("target_mount")
local target_uuid_option = option("target_uuid")
check(target_mount_option and target_mount_option.kind == Value, "L01 target_mount Value missing")
check(target_mount_option and target_mount_option.default == "/mnt/ssd", "L01 target_mount default")
check(target_uuid_option and target_uuid_option.kind == Value, "L01 target_uuid Value missing")
check(target_uuid_option and target_uuid_option.default == "", "L01 target_uuid default")
check(target_uuid_option and target_uuid_option.placeholder:find("block info", 1, true), "L01 UUID source placeholder")
check(target_mount_option and target_mount_option.description:find("never formats", 1, true), "L01 no-disk-operation explanation")
check(option("backup_root").description:find("strict child", 1, true), "L01 backup root boundary description")
check(option("led_green").rmempty and option("led_red").rmempty, "L01 optional LEDs changed")
if not target_mount_option or not target_uuid_option then
    print(string.format("cases=%d assertions=%d failed=%d", cases, assertions, failed))
    os.exit(1)
end

begin("L02", "valid submitted target enables backup")
submit("target_mount", "/mnt/ssd")
submit("target_uuid", "ABCD-1234")
check(validate("enabled", "1") == "1", "L02 enabled rejected valid submitted target")
check(validate("target_uuid", "ABCD-1234") == "ABCD-1234", "L02 valid UUID rejected")
check(validate("target_mount", "/mnt/ssd") == "/mnt/ssd", "L02 valid mount rejected")

begin("L03", "enabled empty UUID rejects")
submit("target_uuid", "")
check(validate("enabled", "1") == nil, "L03 enabled accepted empty UUID")

begin("L04", "disabled empty UUID saves")
submit("target_uuid", "")
check(validate("enabled", "0") == "0", "L04 disabled rejected empty UUID")
check(option("target_uuid").rmempty, "L04 UUID is removable when disabled")
check(option("target_uuid"):can_save("config"), "L04 disabled empty UUID cannot save")

begin("L05", "unsafe UUID rejects even when disabled")
check(validate("target_uuid", "bad uuid") == nil, "L05 unsafe UUID accepted")

begin("L06", "saved fallback applies only when the field is absent")
map.saved.config = { target_uuid = "OLD-UUID", target_mount = "/mnt/ssd" }
map.submitted["cbid.outdoor-backup.config.target_uuid"] = nil
check(validate("enabled", "1") == "1", "L06 missing form value did not use saved UUID")
submit("target_uuid", "")
check(option("target_uuid"):formvalue("config") == "", "L06 double lost explicit empty submission")
check(validate("enabled", "1") == nil, "L06 enabled fell back to saved UUID")

begin("L07", "mount lexical boundary rejects unsafe paths")
for _, value in ipairs({ "relative", "/", "/mnt//ssd", "/mnt/./ssd", "/mnt/../ssd", "/mnt/ssd\n" }) do
    check(validate("target_mount", value) == nil, "L07 accepted unsafe mount: " .. value)
end

begin("L08", "existing named-section form contract remains")
check(map.config == "outdoor-backup" and section.name == "outdoor-backup", "L08 named section changed")
check(option("enabled").kind == Flag and option("backup_root") and option("mount_point"), "L08 existing options missing")

check(cases == 8, "all required cases executed")
if assertions ~= 28 then
    fail(string.format("all required assertions executed (expected=28, actual=%d)", assertions))
end
if failed ~= 0 then
    print(string.format("cases=%d assertions=%d failed=%d", cases, assertions, failed))
    os.exit(1)
end
print(string.format("cases=%d assertions=%d failed=0", cases, assertions))
LUA
