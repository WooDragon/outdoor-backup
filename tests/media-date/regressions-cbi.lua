-- Actual delivered CBI validators with explicit saved/effective/form boundaries.
local root = arg[1]
local ran = 0
local function run(name, effective, saved, form, value, accepted)
    local options = {}
    package.loaded['luci.model.outdoor-backup.target'] = {list=function() return nil, 'synthetic unavailable' end}
    package.loaded['luci.model.outdoor-backup.media'] = {
        config=function() return effective end, probe=function() return true end
    }
    local map = {uci={get=function(_, _, _, key) return saved[key] end}}
    function map:formvalue(key) return form[key] end
    function map:parse() return 0 end
    function map:section()
        return {option=function(_, _, key)
            local option = {map=map, option=key, description=''}
            function option:value() end
            function option:cbid() return self.option end
            function option:formvalue() return form[self.option] end
            function option:cfgvalue() return saved[self.option] or self.default end
            function option:validate(input) return input end
            options[key] = option
            return option
        end}
    end
    Map = function() return map end
    translate = function(text) return text end
    TypedSection = {}; Value = {}; ListValue = {}; Flag = {}; DummyValue = {}
    dofile(root .. '/luci-app-outdoor-backup/luasrc/model/cbi/outdoor-backup/config.lua')
    local library = options.library_root
    local checked = library:validate(value == false and library:cfgvalue('config') or value, 'config')
    assert((checked ~= nil) == accepted, name .. ': ' .. tostring(checked))
    if not saved.library_root and effective.library_root == '' then
        assert(library:cfgvalue('config') == '', 'default presence became explicit root')
        assert(library.rmempty, 'blank root would be persisted as explicit derived root')
    end
    ran = ran + 1
    print('PASS ' .. name)
end
local function effective(library)
    return {backup_layout='mirror', library_root=library or '', target_mount='/mnt/ssd',
        backup_root='/mnt/ssd/MediaLibrary', mount_point='/mnt/sdcard'}
end
run('CBI mirror absent legacy/UCI library intent', effective(), {}, {}, false, true)
run('CBI mirror blank submitted root remains absent', effective(), {}, {library_root=''}, '', true)
run('CBI mirror explicit submitted overlap rejected', effective(), {}, {}, '/mnt/ssd/MediaLibrary', false)
run('CBI mirror explicit legacy overlap rejected', effective('/mnt/ssd/MediaLibrary'), {}, {}, false, false)
run('CBI explicit UCI disjoint overrides legacy', effective('/mnt/ssd/DateLibrary'), {library_root='/mnt/ssd/DateLibrary'}, {}, false, true)
run('CBI date derived overlap rejected', effective(), {}, {backup_layout='date'}, '', false)
run('CBI date derived disjoint root allowed', effective(), {}, {backup_layout='date',backup_root='/mnt/ssd/SDMirrors'}, '', true)
assert(ran == 7)
print('ran=7 passed=7 failed=0; actual CBI validators; synthetic form adapter, not browser E2E')
