-- Handler-level authorization; menu dependencies alone do not protect calls.
local http = require 'luci.http'
local dispatcher = require 'luci.dispatcher'
local util = require 'luci.util'
local M = {}

-- Args: HTTP status and stable public error. Returns false, writes JSON error.
function M.reject(code, message)
    http.status(code)
    http.prepare_content('application/json')
    http.write_json({error=message})
    return false
end

-- Args: write=true for mutations. Returns true only for an authorized session.
-- Matches the installed LuCI CBI session.access RPC shape, fails closed on errors.
function M.allow(write)
    local context = dispatcher.context
    if type(context.authsession) ~= 'string' or context.authsession == '' then
        return M.reject(403, 'Session access denied')
    end
    local ok, result = pcall(util.ubus, 'session', 'access', {
        ubus_rpc_session=context.authsession, scope='uci', object='outdoor-backup',
        ['function']=write and 'write' or 'read'
    })
    if not ok or type(result) ~= 'table' or result.access ~= true then
        return M.reject(403, 'Session access denied')
    end
    if not write then return true end
    if http.getenv('REQUEST_METHOD') ~= 'POST' then
        http.header('Allow', 'POST')
        return M.reject(405, 'POST required')
    end
    local token = http.formvalue('token')
    if type(context.authtoken) ~= 'string' or context.authtoken == '' or
        type(token) ~= 'string' or token ~= context.authtoken then
        return M.reject(403, 'Invalid CSRF token')
    end
    return true
end
return M
