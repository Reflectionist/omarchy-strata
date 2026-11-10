-- Regression check, no Hyprland needed: lua tests/pip_reuse.lua
--
-- Hyprland hands window addresses out again. A PiP entry saved for a YouTube
-- window must not move whatever window gets that address next (on 2026-11-10
-- a Helium restart gave it to a Genius Search tab, which Strata then "returned"
-- to Media). Also: closing a window drops its PiP entry.

local ROOT = arg[0]:match("^(.*)/tests/[^/]*$") or "."
local RUN = os.getenv("XDG_RUNTIME_DIR")
assert(RUN and RUN:match("pip_reuse"), "run via tests/pip_reuse.sh (it sets a scratch XDG_RUNTIME_DIR)")
local SIG = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local PIP_OUT = RUN .. "/strata-pip-out-" .. SIG .. ".json"

-- Stand-in hl: windows from a table, every dispatch recorded, anything else a no-op.
local windows, dispatched, handlers = {}, {}, {}
local function permissive()
  return setmetatable({}, {
    __index = function(t, k)
      local f = function(...) return { k, ... } end
      rawset(t, k, f)
      return f
    end,
  })
end
-- Callable and indexable: hl.plugin.strata.match(...) and friends do nothing.
function anything()
  return setmetatable({}, {
    __index = function(t, k) local v = anything() rawset(t, k, v) return v end,
    __call = function() return nil end,
  })
end
local dsp = permissive()
dsp.window = permissive()
dsp.event = function(s) return { "event", s } end
_G.hl = setmetatable({
  dsp = dsp,
  dispatch = function(d) dispatched[#dispatched + 1] = d end,
  get_window = function(sel) return windows[(sel:gsub("^address:", ""))] end,
  get_windows = function() local l = {} for _, w in pairs(windows) do l[#l + 1] = w end return l end,
  get_active_workspace = function() return { id = 1, name = "1" } end,
  get_active_monitor = function() return { width = 2880, height = 1800, scale = 2 } end,
  on = function(name, fn) handlers[name] = fn return {} end,
  timer = function() return {} end,
}, { __index = function(t, k) local v = anything() rawset(t, k, v) return v end })

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local function read(path)
  local f = io.open(path)
  if not f then return "" end
  local t = f:read("a")
  f:close()
  return t
end

local fails = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then fails = fails + 1 end
end
local function moved(addr)
  for _, d in ipairs(dispatched) do
    for _, v in ipairs(d) do
      if type(v) == "table" and v.window == "address:" .. addr then return true end
    end
  end
  return false
end

local function fresh_module()
  _G.__strata = nil
  dispatched = {}
  return assert(loadfile(ROOT .. "/lua/strata.lua"))(ROOT)
end

-- 1. The address now belongs to another app: entry dropped, window left alone.
windows = { ["0xA"] = { address = "0xA", class = "helium", workspace = { id = 3, name = "name:browser" } } }
write(PIP_OUT, '{"0xA":{"ws":"name:media","x":0,"class":"chrome-youtube.com__-Default"}}\n')
local M = fresh_module()
M.pip_in("0xA")
check("reused address: the other window isn't moved", not moved("0xA"))
check("reused address: entry dropped from the saved list", not read(PIP_OUT):find("0xA", 1, true))

-- 2. Same window (same class): it still comes home.
windows = { ["0xB"] = { address = "0xB", class = "chrome-youtube.com__-Default", workspace = { id = 1, name = "1" } } }
write(PIP_OUT, '{"0xB":{"ws":"name:media","x":0,"class":"chrome-youtube.com__-Default"}}\n')
M = fresh_module()
M.pip_in("0xB")
check("same window: it is moved home", moved("0xB"))

-- 3. Closing a window that's out forgets it.
windows = { ["0xC"] = { address = "0xC", class = "mpv", workspace = { id = 1, name = "1" } } }
write(PIP_OUT, '{"0xC":{"ws":"name:media","x":0,"class":"mpv"}}\n')
M = fresh_module()
handlers = {}
pcall(M.setup)
local close = handlers["window.close"]
if close then
  M.pip_in("0xZ") -- loads the saved list (0xZ isn't in it)
  windows["0xC"] = nil
  close({ address = "0xC" })
  check("closed window: entry dropped", not read(PIP_OUT):find("0xC", 1, true))
else
  print("skip closed-window check: setup() didn't subscribe outside Hyprland")
end

os.exit(fails == 0 and 0 or 1)
