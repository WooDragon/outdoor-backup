-- One synthetic convergence suite. Actual LuCI HTTP/CBI/UCI/rpcd; no real media.
local root = '/src/luci-app-outdoor-backup/luasrc/'
local cases, assertions, failures = 0, 0, 0
local function check(value, message)
    assertions = assertions + 1
    assert(value, message)
end
local function scenario(name, run)
    cases = cases + 1
    local ok, err = pcall(run)
    if not ok then failures = failures + 1 end
    print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
end
_G.L = { ctx = {authsession='synthetic', authtoken='test-token', request_path={}, request_args={}},
    http = {}, dispatcher={lang='en', build_url=function() return '' end, menu_json=function() return {} end} }
package.preload['luci.config'] = function() return {} end
for _, name in ipairs({'target','media','security'}) do
    package.preload['luci.model.outdoor-backup.' .. name] = function()
        return assert(loadfile(root .. 'model/outdoor-backup/' .. name .. '.lua'))()
    end
end
local json = require 'luci.jsonc'
local util = require 'luci.util'
local fs = require 'nixio.fs'
local http = require 'luci.http'
local dispatcher = require 'luci.dispatcher'
local media = require 'luci.model.outdoor-backup.media'
local original_popen = io.popen
local original_probe = media.probe
local function file(path, value)
    check(fs.writefile(path,value), 'write synthetic fixture ' .. path)
end
local config = {backup_layout='mirror',backup_root='/tmp/luci-ssd/SDMirrors',target_mount='/tmp/luci-ssd',target_uuid='SSD-TEST',
    library_root='/tmp/luci-ssd/MediaLibrary',archive_offset_minutes='',mount_point='/tmp/luci-card'}
local uuid='11111111-2222-3333-4444-555555555555'
local probe = {version=1,parser_profile='media-date-v1',metadata_profile='fast-whitelist-v1',mountinfo_required=true,
    modules={['Image::ExifTool']='13.59',['JSON::PP']='4.0',['Digest::SHA']='6.0',['Time::Local']='1.3'},
    limits={files=50000,routes_bytes=67108864,xml_bytes=8388608}}
local function clone(value) return json.parse(json.stringify(value)) end
local helper_calls={}
-- Strict process double: models stdout + reliable shell status marker only;
-- command assertion is mandatory, rejecting changed argv or arbitrary commands.
local function helper(expected, body, code)
    io.popen = function(command, mode)
        helper_calls[#helper_calls+1]=command
        check(mode=='r', 'read-only pipe')
        check(command==expected, 'exact frozen argv: ' .. command)
        return {read=function(_, format)
            check(format=='*a', 'complete JSON read')
            return body .. '\nOB_LUCI_EXIT:' .. (code or 0) .. '\n'
        end,close=function() return true end}
    end
end
local function wrapped(command)
    return 'exec 9>&-; (' .. command .. ') 2>/dev/null; printf "\\nOB_LUCI_EXIT:%s\\n" "$?"'
end
scenario('L01 actual missing optional helper cannot enable date', function()
    io.popen=original_popen
    local result=media.probe()
    check(result==nil, 'missing helper accepted')
end)
scenario('L02 exact probe schema and modules', function()
    check(media.valid_probe(probe), 'valid delivered probe rejected')
    for _, key in ipairs({'version','modules','limits','metadata_profile','parser_profile','mountinfo_required'}) do
        local bad=clone(probe); bad[key]=nil
        check(not media.valid_probe(bad), 'missing ' .. key .. ' accepted')
    end
    local bad=clone(probe); bad.modules['GPS']='private'
    check(not media.valid_probe(bad), 'extra metadata accepted')
    bad=clone(probe);bad.version=2
    check(not media.valid_probe(bad), 'future schema accepted')
end)
scenario('L03 failed stdout discarded, successful schema required', function()
    local cmd=wrapped('/usr/bin/perl /opt/outdoor-backup/scripts/media-date-plan.pl probe')
    helper(cmd,json.stringify(probe),1)
    check(not media.probe(), 'nonzero success-looking stdout accepted')
    helper(cmd,'{"version":1}',0)
    check(not media.probe(), 'partial JSON accepted')
    helper(cmd,json.stringify(probe),0)
    check(media.probe(), 'valid probe rejected')
    io.popen=original_popen
end)
scenario('L04 actual runtime legacy/UCI config and child FD9 boundary', function()
    file('/opt/outdoor-backup/conf/backup.conf', 'BACKUP_ROOT="/tmp/luci-ssd/LegacyMirrors"\nTARGET_MOUNT="/tmp/luci-ssd"\nTARGET_UUID="LEGACY"\n')
    file('/etc/config/outdoor-backup', "config outdoor-backup 'config'\n option target_uuid 'SSD-TEST'\n")
    check(fs.access('/proc/self/fd/9'), 'parent FD9 fixture missing')
    local result,code=media.config()
    check(code==0 and result.backup_root=='/tmp/luci-ssd/LegacyMirrors', 'legacy root not effective')
    check(result.target_uuid=='SSD-TEST' and result.backup_layout=='mirror', 'UCI/default precedence wrong')
    check(fs.access('/proc/self/fd/9'), 'parent FD9 was closed')
    check(fs.readfile('/tmp/luci-child-fd')=='closed\n', 'child inherited FD9')
end)
local preview={version=1,layout='mirror',backup_root=config.backup_root,target_uuid=config.target_uuid,
    cards={{uuid=uuid,display_name='<img src=x> "card"',size_bytes=0,path=config.backup_root .. '/' .. uuid}},
    total_size_bytes=0,total_cards=1}
scenario('L05 exact cleanup preview schema and root identity', function()
    check(media.valid_preview(preview,config), 'valid preview rejected')
    for _, key in ipairs({'version','layout','backup_root','target_uuid','cards','total_size_bytes','total_cards'}) do
        local bad=clone(preview);bad[key]=nil
        check(not media.valid_preview(bad,config), 'missing preview key accepted: ' .. key)
    end
    local bad=clone(preview);bad.cards[1].path='/foreign/' .. uuid
    check(not media.valid_preview(bad,config), 'foreign card path accepted')
    bad=clone(preview);bad.total_cards=2
    check(not media.valid_preview(bad,config), 'incorrect counts accepted')
    bad=clone(preview);bad.metadata={GPS='private'}
    check(not media.valid_preview(bad,config), 'extra metadata leaked')
end)
for _, exit in ipairs({0,1,2,3,4,5,130,143}) do
    scenario('L06 cleanup-preview exit=' .. exit, function()
        helper(wrapped('/bin/sh /opt/outdoor-backup/scripts/backup-manager.sh cleanup-preview ' .. util.shellquote(config.backup_root)),json.stringify(preview),exit)
        local result,code=media.cleanup(true,config)
        check(code==exit, 'exit mismatch')
        check((result~=nil)==(exit==0), 'nonzero stdout not discarded')
        check(media.exit_http[exit]==({[0]=200,[1]=400,[2]=400,[3]=500,[4]=409,[5]=409,[130]=409,[143]=409})[exit], 'HTTP map mismatch')
        io.popen=original_popen
    end)
end
scenario('L07 execute exact manager arguments and date backend rejection', function()
    helper(wrapped('/bin/sh /opt/outdoor-backup/scripts/backup-manager.sh cleanup ' .. util.shellquote(config.backup_root) .. ' 1'),'',0)
    check(media.cleanup(false,config).success, 'manager success lost')
    io.popen=function() error('date must not invoke manager') end
    local date=clone(config);date.backup_layout='date'
    for _, is_preview in ipairs({true,false}) do
        local result,code=media.cleanup(is_preview,date)
        check(result==nil and code==4, 'date accepted')
    end
    io.popen=original_popen
end)
-- Real rpcd session grant/access shape. No hand-written access boolean mock.
local function session(permission)
    local created=assert(util.ubus('session','create',{timeout=3600}))
    if permission then
        util.ubus('session','grant',{ubus_rpc_session=created.ubus_rpc_session,scope='uci',objects={{'outdoor-backup',permission}}})
        local access=util.ubus('session','access',{ubus_rpc_session=created.ubus_rpc_session,scope='uci',object='outdoor-backup',['function']=permission})
        check(type(access)=='table' and access.access==true,'actual RPC grant/access schema')
    end
    return created.ubus_rpc_session
end
local reader,writer,denied=session('read'),session('write'),session(nil)
local forms,method,response,status,read_count,write_count={},{},nil,nil,0,0
-- HTTP pseudo-adapter uses real luci.http exports and real lucihttp form decoder.
local codec=require 'lucihttp'
local function request(sid,verb,values)
    _G.L.ctx.authsession=sid; _G.L.ctx.authtoken='test-token'
    method=verb; forms={};response=nil;status=200
    local body=http.urlencode_params(values or {})
    for key,value in body:gmatch('([^&=]+)=([^&]*)') do forms[codec.urldecode(key)]=codec.urldecode(value) end
end
_G.L.http={getenv=function(_,key) check(key=='REQUEST_METHOD','unexpected HTTP env'); return method end,
    formvalue=function(_,key) return forms[key] end,
    status=function(_,code) status=code end, header=function() end, prepare_content=function() end}
_G.L.printf=function(format,value) check(format=='%J','unexpected JSON format');response=value end
_G.L.print=function(value) response=value end
local controller=assert(loadfile(root .. 'controller/outdoor-backup.lua'))()
controller=package.loaded['luci.controller.outdoor-backup']
local original_read,original_write=fs.readfile,fs.writefile
local old_config,old_cleanup=media.config,media.cleanup
media.config=function() read_count=read_count+1;return clone(config),0 end
media.cleanup=function(is_preview,effective)
    write_count=write_count+1
    check(effective.backup_root==config.backup_root,'request root reached manager')
    return is_preview and clone(preview) or {success=true},0
end
for _, handler in ipairs({'api_cleanup_execute','api_update_alias','api_delete_alias'}) do
    for _, state in ipairs({{'GET',writer,'test-token',405},{'POST',reader,'test-token',403},
        {'POST',denied,'test-token',403},{'POST','invalid-session','test-token',403},
        {'POST',writer,nil,403},{'POST',writer,'wrong-token',403}}) do
        scenario('L08 ' .. handler .. ' rejects ' .. state[1] .. '/' .. state[2] .. '/' .. tostring(state[3]),function()
            request(state[2],state[1],{token=state[3],confirm_text='清空备份数据',uuid=uuid})
            local before_read,before_write=read_count,write_count
            fs.readfile=function() error('unauthorized file read') end
            fs.writefile=function() error('unauthorized mutation') end
            controller[handler]()
            fs.readfile,fs.writefile=original_read,original_write
            check(status==state[4],'wrong rejection status ' .. status)
            check(read_count==before_read and write_count==before_write,'helper side effect before authorization')
        end)
    end
end
scenario('L09 authorized form cleanup and current config only', function()
    request(writer,'POST',{token='test-token',confirm_text='清空备份数据',backup_root='/foreign'})
    controller.api_cleanup_execute()
    check(status==200 and response.success,'authorized POST rejected')
    request(writer,'POST',{token='test-token',confirm_text='wrong'})
    local before=write_count
    controller.api_cleanup_execute()
    check(status==400 and before==write_count,'invalid confirmation invoked helper')
end)
for _, handler in ipairs({'api_status','api_aliases','action_log','api_cleanup_preview'}) do
    scenario('L10 read account ' .. handler,function()
        fs.readfile=function(path)
            read_count=read_count+1
            check(path=='/opt/outdoor-backup/var/status.json' or path=='/opt/outdoor-backup/conf/aliases.json' or path=='/opt/outdoor-backup/log/backup.log','unexpected read')
            return path:find('backup.log',1,true) and '[INFO] <synthetic>' or '{}'
        end
        local template=require 'luci.template';local render=template.render
        template.render=function(name,context) check(name=='outdoor-backup/log' and type(context.log_content)=='string','log render contract') end
        request(reader,'GET',{});controller[handler]();check(status==200,'reader rejected')
        request(denied,'GET',{});local before=read_count;controller[handler]()
        check(status==403 and before==read_count,'denied read executed')
        template.render=render;fs.readfile=original_read
    end)
end
scenario('L11 real post route metadata', function()
    local routes={}
    controller.entry=function(path,target) routes[table.concat(path,'/')]=target;return {} end
    controller.firstchild=function() return {} end
    controller.template=function() return {} end
    controller.cbi=function() return {} end
    controller.call=dispatcher.call;controller.post=dispatcher.post;controller._=function(value) return value end
    controller.index()
    for _, path in ipairs({'alias/update','alias/delete','cleanup/execute'}) do
        check(routes['admin/services/outdoor-backup/api/' .. path].post==true,'mutation not a framework POST route')
    end
end)
for _, code in ipairs({0,1,2,3,4,5,130,143}) do
    scenario('L20 actual handler HTTP exit mapping=' .. code,function()
        media.cleanup=function() return code==0 and {success=true} or nil,code end
        request(writer,'POST',{token='test-token',confirm_text='清空备份数据'})
        controller.api_cleanup_execute()
        check(status==media.exit_http[code],'controller HTTP mapping incorrect')
        check(code==0 and response.success or code~=0 and response.exit_code==code,'public response contract incorrect')
    end)
end
scenario('L21 real authorized alias form update/delete roundtrip',function()
    request(writer,'POST',{token='test-token',uuid=uuid,alias='<synthetic> "alias"',notes='text'})
    controller.api_update_alias()
    check(status==200 and response.success,'alias form update failed')
    local stored=json.parse(original_read('/opt/outdoor-backup/conf/aliases.json'))
    check(stored.aliases[uuid].alias=='<synthetic> "alias"','alias literal text not preserved')
    request(writer,'POST',{token='test-token',uuid=uuid})
    controller.api_delete_alias()
    check(status==200 and response.success,'alias form delete failed')
    stored=json.parse(original_read('/opt/outdoor-backup/conf/aliases.json'))
    check(not stored.aliases[uuid],'alias mapping not deleted')
end)
media.config,media.cleanup=old_config,old_cleanup
io.popen=original_popen
scenario('L22 empty cards object and duplicate keys rejected',function()
    local command=wrapped('/bin/sh /opt/outdoor-backup/scripts/backup-manager.sh cleanup-preview ' .. util.shellquote(config.backup_root))
    local object='{"version":1,"layout":"mirror","backup_root":"' .. config.backup_root .. '","target_uuid":"SSD-TEST","cards":{},"total_size_bytes":0,"total_cards":0}'
    helper(command,object,0)
    local result,code=media.cleanup(true,config)
    check(not result and code==3,'cards object accepted as array')
    helper(command,object:gsub('"cards":{}','"cards":[],"cards":[]'),0)
    result,code=media.cleanup(true,config)
    check(not result and code==3,'duplicate cards accepted')
    helper(command,object:gsub('"cards":{}','"cards":[]'),0)
    check(media.cleanup(true,config),'empty actual cards array rejected')
    io.popen=original_popen
end)
-- Real Map.parse/save/commit/reload using private UCI directories.
local uci=require 'luci.model.uci'
local cbi=require 'luci.cbi'
Map,TypedSection,Flag,Value,ListValue,DummyValue=cbi.Map,cbi.TypedSection,cbi.Flag,cbi.Value,cbi.ListValue,cbi.DummyValue
translate=function(value) return value end
local native=require 'uci';local original_cursor=native.cursor
local target=require 'luci.model.outdoor-backup.target'
local fixture_index=0
fs.mkdirr(config.mount_point)
fs.mkdirr(config.target_mount)
local function map_fixture(values)
    fixture_index=fixture_index+1
    local dir='/tmp/luci-date-map-' .. require('nixio').getpid() .. '-' .. fixture_index
    fs.mkdirr(dir .. '/conf');fs.mkdirr(dir .. '/save')
    local stored="config outdoor-backup 'config'\n"
    for key,value in pairs(values or {}) do stored=stored .. " option " .. key .. " '" .. value .. "'\n" end
    file(dir .. '/conf/outdoor-backup',stored)
    uci.cursor=function() return original_cursor(dir .. '/conf',dir .. '/save') end
    media.config=function() return clone(config),0 end
    target.list=function() return {targets={{device='/dev/synthetic',uuid='SSD-NEW',mount='/tmp/new-ssd',fstype='ext4'}},
        current={target_mount=config.target_mount,backup_root=config.backup_root}} end
    media.probe=function() check(media.valid_probe(probe),'strict probe fixture');return clone(probe) end
    forms={}
    local map=assert(dofile(root .. 'model/cbi/outdoor-backup/config.lua'))
    return map,dir
end
http.formvalue=function(key) return forms[key] end
http.formvaluetable=function() return {} end
local function submit(map,overrides)
    _G.L.ctx.authsession=writer; _G.L.ctx.authtoken='test-token'; method='POST'
    forms={['cbi.submit']='1', token='test-token'}
    local values={_target_selector='manual',enabled='1',debug='0',target_mount=config.target_mount,target_uuid=config.target_uuid,
        backup_root=config.backup_root,mount_point=config.mount_point,backup_layout='mirror',library_root=config.library_root,
        archive_offset_minutes='',led_green='none',led_green2='none',led_green3='none',led_red='none'}
    for key,value in pairs(overrides or {}) do values[key]=value end
    for key,value in pairs(values) do
        if key=='enabled' or key=='debug' then
            forms['cbi.cbe.outdoor-backup.config.' .. key]='1'
            if value=='1' then forms['cbid.outdoor-backup.config.' .. key]=value end
        else
            forms['cbid.outdoor-backup.config.' .. key]=value
        end
    end
    map:parse()
    if not map.save then return nil end
    map.uci:save('outdoor-backup');map.uci:commit('outdoor-backup')
    local reload=original_cursor(map.uci:get_confdir(),map.uci:get_savedir())
    return reload
end
scenario('L12 default mirror manual selector none LED compatibility', function()
    local map=map_fixture({enabled='1',target_uuid=config.target_uuid})
    local saved=submit(map,{})
    check(saved and (saved:get('outdoor-backup','config','backup_layout') or config.backup_layout)=='mirror','mirror effective default changed')
    check((saved:get('outdoor-backup','config','backup_root') or config.backup_root)==config.backup_root,'manual effective root changed')
    check(saved:get('outdoor-backup','config','led_green')=='none','none LED changed')
    check(saved:get('outdoor-backup','config','_target_selector')==nil,'virtual selector persisted')
    check(saved:get('outdoor-backup','config','comparison_mode')==nil,'comparison mode persisted')
end)
scenario('L13 selected target mirror root suffix remains compatible', function()
    local map=map_fixture({})
    local saved=submit(map,{_target_selector='7:SSD-NEW/tmp/new-ssd'})
    check(saved and saved:get('outdoor-backup','config','backup_root')=='/tmp/new-ssd/SDMirrors','selector root wrong')
end)
scenario('L14 real date save requires actual capability', function()
    local map=map_fixture({})
    media.probe=function() return nil,'missing optional package' end
    check(not submit(map,{backup_layout='date',archive_offset_minutes='480'}),'missing date package saved')
end)
scenario('L15 valid date/direct child/display default offset save', function()
    local map=map_fixture({})
    local saved=submit(map,{backup_layout='date',archive_offset_minutes='480'})
    check(saved and (saved:get('outdoor-backup','config','library_root') or config.library_root)==config.library_root,'date effective root changed')
    check(saved:get('outdoor-backup','config','backup_layout')=='date','date layout not persisted')
    check(saved:get('outdoor-backup','config','archive_offset_minutes')==nil,'display default became explicit offset')
end)
for _, invalid in ipairs({'/tmp/luci-ssd','/tmp/luci-ssd/a/b','/tmp/luci-ssd/SDMirrors','/tmp/luci-ssd/SDMirrors/sub','/tmp/luci-ssd/../bad'}) do
    scenario('L16 date root rejects ' .. invalid,function()
        local map=map_fixture({})
        check(not submit(map,{backup_layout='date',library_root=invalid,archive_offset_minutes='480'}),'invalid date root saved')
    end)
end
for _, invalid in ipairs({'','841','-841','01','1.5','+480','-0'}) do
    scenario('L17 offset partition ' .. invalid,function()
        local map=map_fixture({})
        local saved = submit(map,{backup_layout='date',archive_offset_minutes=invalid})
        check((saved ~= nil) == (invalid == ''),'blank must default; malformed offset must reject')
    end)
end
scenario('L18 existing policy cannot change online', function()
    fs.mkdirr(config.library_root .. '/.outdoor-backup')
    file(config.library_root .. '/.outdoor-backup/library.json','{}')
    local previous=media.library
    media.library=function(path)
        check(path==config.library_root,'library query path')
        local policy={version=1,library_id=uuid,layout='date',parser_profile='media-date-v1',archive_offset_minutes=480}
        check(media.valid_library(policy),'strict library policy double schema')
        return policy
    end
    local map=map_fixture({})
    check(not submit(map,{backup_layout='date',archive_offset_minutes='0'}),'existing offset changed')
    map=map_fixture({})
    check(submit(map,{backup_layout='date',archive_offset_minutes='480'}),'same policy rejected')
    media.library=previous
    fs.unlink(config.library_root .. '/.outdoor-backup/library.json')
end)
for _, state in ipairs({{'GET',writer,'test-token'}, {'POST',reader,'test-token'}, {'POST',writer,nil}, {'POST',writer,'wrong-token'}}) do
    scenario('L23 direct CBI submit requires POST/token/write access ' .. state[1] .. '/' .. tostring(state[3]),function()
        local map=map_fixture({})
        request(state[2],state[1],{token=state[3]})
        forms['cbi.submit']='1'
        forms['cbid.outdoor-backup.config.backup_layout']='date'
        local before=0
        media.probe=function() before=before+1;error('unauthorized capability command') end
        map:parse()
        check(map.save==false and before==0,'CBI mutation ran before authorization')
    end)
end
for _, boundary in ipairs({'-840','0','840'}) do
    scenario('L24 canonical offset boundary accepted ' .. boundary,function()
        local map=map_fixture({})
        check(submit(map,{backup_layout='date',archive_offset_minutes=boundary}),'valid offset boundary rejected')
    end)
end
scenario('L25 date library cannot contain mirror root',function()
    local map=map_fixture({})
    check(not submit(map,{backup_layout='date',library_root='/tmp/luci-ssd/Parent',backup_root='/tmp/luci-ssd/Parent/Mirrors',archive_offset_minutes='0'}),'date ancestor of mirror accepted')
end)
scenario('L26 date target selector and explicit separate root',function()
    local map=map_fixture({})
    local saved=submit(map,{_target_selector='7:SSD-NEW/tmp/new-ssd',backup_layout='date',library_root='/tmp/new-ssd/MediaLibrary',archive_offset_minutes='0'})
    check(saved and saved:get('outdoor-backup','config','target_mount')=='/tmp/new-ssd','date target selection failed')
    check(saved:get('outdoor-backup','config','backup_root')=='/tmp/new-ssd/SDMirrors','date selector changed mirror-root meaning')
end)
scenario('L27 malformed actual probe blocks real Map save',function()
    local map=map_fixture({})
    media.probe=original_probe
    helper(wrapped('/usr/bin/perl /opt/outdoor-backup/scripts/media-date-plan.pl probe'),'{"version":1}',0)
    check(not submit(map,{backup_layout='date',archive_offset_minutes='480'}),'wrong probe schema allowed date save')
    io.popen=original_popen
end)
scenario('L28 disabled manual mirror preserves empty UUID behavior',function()
    local map=map_fixture({enabled='0',target_uuid='OLD'})
    local saved=submit(map,{enabled='0',target_uuid=''})
    check(saved and not saved:get('outdoor-backup','config','target_uuid'),'empty UUID not removed')
    check(saved:get('outdoor-backup','config','enabled')=='0','disabled flag lost')
end)
scenario('L29 invalid existing policy cannot be treated as new library',function()
    fs.mkdirr(config.library_root .. '/.outdoor-backup')
    file(config.library_root .. '/.outdoor-backup/library.json','{}')
    local previous=media.library
    local map=map_fixture({})
    media.library=function() return nil end
    check(not submit(map,{backup_layout='date',archive_offset_minutes='480'}),'invalid existing policy accepted')
    media.library=previous
    fs.unlink(config.library_root .. '/.outdoor-backup/library.json')
end)
scenario('L30 real legacy effective values rendered by CBI without rewriting',function()
    map_fixture({})
    media.config=old_config
    local effective=assert(media.config())
    local map=assert(dofile(root .. 'model/cbi/outdoor-backup/config.lua'))
    local fields={}
    for _, field in ipairs(map.children[1].children) do fields[field.option]=field end
    check(fields.backup_root:cfgvalue('config')==effective.backup_root,'legacy mirror root not rendered')
    check(fields.target_mount:cfgvalue('config')==effective.target_mount,'legacy target not rendered')
    local displayed_root = effective.library_root ~= '' and effective.library_root or effective.target_mount .. '/MediaLibrary'
    check(fields.library_root:cfgvalue('config')==displayed_root,'effective/default date root not rendered')
    local saved=submit(map,{backup_root=effective.backup_root,target_mount=effective.target_mount,mount_point=config.mount_point})
    check(saved and not saved:get('outdoor-backup','config','backup_root'),'unchanged effective legacy root overwritten')
end)
scenario('L31 mirror still rejects intersecting retained library root',function()
    local map=map_fixture({})
    check(not submit(map,{library_root=config.backup_root}),'mirror/date roots can coincide')
end)
scenario('L32 fixed read-only library adapter exact schema',function()
    local policy={version=1,library_id=uuid,layout='date',parser_profile='media-date-v1',archive_offset_minutes=480}
    local command=wrapped('/usr/bin/perl /opt/outdoor-backup/scripts/media-date-plan.pl validate-library ' .. util.shellquote(config.library_root .. '/.outdoor-backup/library.json'))
    helper(command,json.stringify(policy),0)
    check(media.library(config.library_root),'valid library marker rejected')
    helper(command,json.stringify(policy),1)
    check(not media.library(config.library_root),'nonzero library output accepted')
    for _, mutate in ipairs({function(value) value.library_id='invalid' end,function(value) value.archive_offset_minutes=1.5 end,
        function(value) value.version=2 end,function(value) value.rawUMID='private' end}) do
        local bad=clone(policy);mutate(bad)
        check(not media.valid_library(bad),'bad library schema accepted')
    end
    io.popen=original_popen
end)
-- Real template compiler: hostile text must not cross HTML or JS contexts.
scenario('L19 real log template escaping',function()
    local template=require 'luci.template'
    local source=assert(original_read(root .. 'view/outdoor-backup/log.htm'))
    local chunks={}
    local compiled=template.Template(nil,source)
    compiled.viewns=setmetatable({write=function(chunk) chunks[#chunks+1]=chunk end,include=function() end}, {__index=template.context.viewns})
    compiled:render({log_content='[WARN] </pre><script>evil()</script> "alias"\n'})
    local output=table.concat(chunks)
    check(not output:find('<script>evil()',1,true),'raw log injected')
    check(output:find(require('luci.xml').pcdata('[WARN] </pre><script>evil()</script> "alias"\n'),1,true),'escaped log missing')
    check(output:find("document.getElementById('log-content').textContent",1,true),'raw JS log retained')
end)
scenario('L33 real status template CSRF attribute encoding',function()
    local template=require 'luci.template'
    local source=assert(original_read(root .. 'view/outdoor-backup/status.htm'))
    local chunks={}
    local compiled=template.Template(nil,source)
    compiled.viewns=setmetatable({write=function(chunk) chunks[#chunks+1]=chunk end,include=function() end}, {__index=template.context.viewns})
    local old=_G.L.ctx.authtoken
    _G.L.ctx.authtoken='"><script>synthetic()</script>'
    compiled:render({})
    _G.L.ctx.authtoken=old
    local output=table.concat(chunks)
    check(output:find('id="outdoor-backup-token"',1,true),'token attribute not rendered')
    check(not output:find('<script>synthetic()',1,true),'token escaped into markup')
    check(output:find(require('luci.xml').pcdata('"><script>synthetic()</script>'),1,true),'escaped token missing')
end)
print(string.format('ran=%d passed=%d failed=%d assertions=%d',cases,cases-failures,failures,assertions))
assert(cases==82,'unexpected actual case count: ' .. cases)
assert(failures==0,'scenario failures')
