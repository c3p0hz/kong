local meta = require "kong.meta"
local cjson = require "cjson"
local cache = require "kong.tools.database_cache"
local utils = require "kong.tools.utils"
local pl_utils = require "pl.utils"
local pl_stringx = require "pl.stringx"
local singletons = require "kong.singletons"
local constants = require "kong.constants"
local concat = table.concat
local udp_sock = ngx.socket.udp

local ping_handler, system_infos
local enabled = false
local unique_str = utils.random_string()

local PING_INTERVAL = 3600
local KEY = "events:reports"

local ngx_log = ngx.log
local ERR = ngx.ERR

local function log(lvl, ...)
  ngx_log(lvl, "[cluster] ", ...)
end

local function get_system_infos()
  local infos = {
    version = meta._VERSION
  }

  local ok, _, stdout = pl_utils.executeex("getconf _NPROCESSORS_ONLN")
  if ok then
    infos.cores = tonumber(stdout:sub(1, -2))
  end
  ok, _, stdout = pl_utils.executeex("hostname")
  if ok then
    infos.hostname = stdout:sub(1, -2)
  end
  ok, _, stdout = pl_utils.executeex("uname -a")
  if ok then
    infos.uname = stdout:gsub(";", ","):sub(1, -2)
  end
  return infos
end

system_infos = get_system_infos()

-------------
-- UDP logger
-------------

local function send(t, host, port)
  if not enabled then return end
  t = t or {}
  host = host or constants.SYSLOG.ADDRESS
  port = port or constants.SYSLOG.PORT

  local buf = {}
  for k, v in pairs(system_infos) do
    buf[#buf+1] = k.."="..v
  end

  -- entity formatting
  for k, v in pairs(t) do
    if not pl_stringx.endswith(k, "id") and k ~= "created_at" then
      if type(v) == "table" then
        v = cjson.encode(v)
      end

      buf[#buf+1] = k.."="..tostring(v)
    end
  end

  local msg = concat(buf, ";")

  local sock = udp_sock()
  local ok, err = sock:setpeername(host, port)
  if not ok then
    log(ERR, "could not set peer name for UDP socket: ", err)
    return
  end

  sock:settimeout(1000)

  ok, err = sock:send("<14>"..msg) -- syslog facility code 'log alert'
  if not ok then
    log(ERR, "could not send data: ", err)
  end

  ok, err = sock:close()
  if not ok then
    log(ERR, "could not close socket: ", err)
  end
end

---------------
-- ping handler
---------------

local function get_lock()
  -- the lock is held for the whole interval to prevent multiple
  -- worker processes from sending the test request simultaneously.
  -- here we substract the lock expiration time by 1ms to prevent
  -- a race condition with the next timer event.
  return cache.rawadd(KEY, true, PING_INTERVAL - 0.001)
end

local function create_ping_timer()
  local ok, err = ngx.timer.at(PING_INTERVAL, ping_handler)
  if not ok then
    log(ERR, "failed to create ping timer: ", err)
  end
end

ping_handler = function(premature)
  if premature then return end

  local ok, err = get_lock()
  if ok then
    local requests = cache.get(cache.requests_key()) or 0
    send {
      signal = "ping",
      requests = requests,
      unique_id = unique_str,
      database = singletons.configuration.database
    }
    cache.rawset(cache.requests_key(), -requests)
  elseif err ~= "exists" then
    log(ERR, err)
  end

  create_ping_timer()
end

return {
  -----------------
  -- plugin handler
  -----------------
  init_worker = function()
    if not enabled then return end
    cache.rawset(cache.requests_key(), 0)
    create_ping_timer()
  end,
  log = function()
    if not enabled then return end
    cache.incr(cache.requests_key(), 1)
  end,
  -----------------
  -- custom methods
  -----------------
  toggle = function(enable)
    enabled = enable
  end,
  get_system_infos = get_system_infos,
  send = send,
  api_signal = "api"
}
