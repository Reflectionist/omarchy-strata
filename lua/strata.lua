-- Strata: your workspaces as one 2D grid. Each workspace is a stratum,
-- stacked top to bottom; every stratum shares one horizontal axis, so moving
-- up or down keeps your exact x, and rows can have blank space between
-- windows.
--
-- The grid itself is the `strata` layout from the hypr-strata Hyprland plugin
-- (built by bin/strata-setup into ~/.local/share/strata). This file loads it,
-- binds the keys and knows the order of the stack. Without the built plugin
-- it does nothing, and Hyprland keeps its own layout.
--
--   SUPER+LEFT/RIGHT            next window, or on into blank space; at the end of
--                               the row, hold (or press again) to wrap if enabled
--   SUPER+UP/DOWN               up/down a column, then on to the stratum above/below
--   SUPER+SHIFT+LEFT/RIGHT      step the window through blank space; stack into /
--                               pop out of a neighbour it touches
--   SUPER+CTRL+SHIFT+LEFT/RIGHT fine nudge
--   SUPER+SHIFT+UP/DOWN         up/down a column, then carry the window to the
--                               stratum above/below at the same x
--   SUPER+CTRL+HOME             back to the window that has keyboard focus
--   SUPER+wheel                 like SUPER+LEFT/RIGHT; SUPER+SHIFT+wheel up/down
--
-- Loading: ~/.config/hypr/strata.lua (written by bin/strata-setup, required
-- at the end of hyprland.lua) runs this file with the plugin folder as its
-- argument, then calls setup().

local M = {}
M.settings = {}

local HOME = os.getenv("HOME") or ""
-- The plugin folder (config/defaults.json, bin/ helpers): the loader's
-- argument (an absolute path; `require` would pass a module name instead).
local ARG = ...
local ROOT = os.getenv("STRATA_ROOT")
  or (type(ARG) == "string" and ARG:sub(1, 1) == "/" and ARG)
  or (HOME .. "/.config/omarchy/plugins/io.github.reflectionist.strata")
M.ROOT = ROOT
local DATA_HOME = os.getenv("XDG_DATA_HOME") or (HOME .. "/.local/share")
local SO = os.getenv("STRATA_SO") or (DATA_HOME .. "/strata/hypr-strata.so")

-- A helper from the plugin's bin/, quoted for a shell command line.
local function helper(name)
  return "'" .. (ROOT .. "/bin/" .. name):gsub("'", "'\\''") .. "'"
end

-- Hyprland keeps Lua globals across reloads only in this table's slot.
local S = _G.__strata or {}
_G.__strata = S
S.parse = (S.parse or 0) + 1

-- Settings live in ~/.config/strata/strata.json (the Strata settings panel
-- writes it); the plugin's config/defaults.json fills in anything missing.
local CONFIG_DIR = os.getenv("STRATA_CONFIG_DIR") or (HOME .. "/.config/strata")
local DEFAULTS = os.getenv("STRATA_CONFIG_DIR") and (CONFIG_DIR .. "/defaults.json") or (ROOT .. "/config/defaults.json")

-- A small JSON reader: enough for strata.json (objects, arrays, strings with
-- escapes, numbers, booleans; null reads as nil).
local function json_decode(text)
  local pos = 1
  local function ws()
    pos = text:find("[^ \t\r\n]", pos) or #text + 1
  end
  local value
  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = text:sub(i, i)
      if c == "" then
        error("unterminated string")
      elseif c == '"' then
        pos = i + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = text:sub(i + 1, i + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if e == "u" then
          local cp = tonumber(text:sub(i + 2, i + 5), 16)
          i = i + 6
          if cp >= 0xD800 and cp <= 0xDBFF and text:sub(i, i + 1) == "\\u" then
            local lo = tonumber(text:sub(i + 2, i + 5), 16)
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
          out[#out + 1] = utf8.char(cp)
        else
          out[#out + 1] = map[e] or e
          i = i + 2
        end
      else
        local j = text:find('["\\]', i)
        if not j then
          error("unterminated string")
        end
        out[#out + 1] = text:sub(i, j - 1)
        i = j
      end
    end
  end
  function value()
    ws()
    local c = text:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1
      ws()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return t
      end
      while true do
        ws()
        local k = str()
        ws()
        pos = pos + 1 -- :
        t[k] = value()
        ws()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return t
        end
      end
    elseif c == "[" then
      local t = {}
      pos = pos + 1
      ws()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return t
      end
      while true do
        t[#t + 1] = value()
        ws()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return t
        end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      local n = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      pos = pos + #n
      return tonumber(n)
    end
  end
  return value()
end

-- And the other way, for the state files Strata writes. A table with a [1],
-- or one made with json_array (for an empty list), is an array; an object's
-- keys come out sorted.
local ARRAY = {}
local function json_array(t)
  return setmetatable(t or {}, ARRAY)
end

local function json_encode(v)
  local t = type(v)
  if t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      return "null"
    end
    return math.type(v) == "integer" and tostring(v) or string.format("%.14g", v)
  elseif t == "string" then
    local escaped = v:gsub('[%c"\\]', function(c)
      return c == '"' and '\\"' or c == "\\" and "\\\\" or string.format("\\u%04x", c:byte())
    end)
    return '"' .. escaped .. '"'
  elseif t == "table" then
    local out = {}
    if getmetatable(v) == ARRAY or v[1] ~= nil then
      for _, x in ipairs(v) do
        out[#out + 1] = json_encode(x)
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = json_encode(tostring(k)) .. ":" .. json_encode(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("a")
  f:close()
  local ok, v = pcall(json_decode, text)
  return ok and v or nil
end

local function is_array(t)
  return type(t) == "table" and (t[1] ~= nil or next(t) == nil)
end

-- defaults under user: tables merge, arrays and values are replaced.
local function merge(defaults, user)
  if type(defaults) ~= "table" or type(user) ~= "table" or is_array(defaults) or is_array(user) then
    if user == nil then
      return defaults
    end
    return user
  end
  local out = {}
  for k, v in pairs(defaults) do
    out[k] = v
  end
  for k, v in pairs(user) do
    out[k] = merge(defaults[k], v)
  end
  return out
end

-- Without defaults.json (a broken install): one stratum of numbered workspaces.
local FALLBACK = {
  stack = { "games", "@free" },
  strata = { games = { name = "Games", icon = "󰺷", iconActive = "󰊗", workspace = "name:games" } },
  free = { dynamic = false, count = 10 },
  navigation = {},
}

function M.config()
  if S.config_cache and S.config_parse == S.parse then
    return S.config_cache
  end
  local defaults = read_json(DEFAULTS)
  local user = read_json(CONFIG_DIR .. "/strata.json")
  local cfg = merge(defaults or FALLBACK, user)
  local nav = cfg.navigation or {}
  M.settings = {
    wrap_vertical = nav.wrap_vertical ~= false,
    wrap_horizontal = nav.wrap_horizontal == true,
    wrap_hold = nav.wrap_hold == true, -- wrap only when held (or pressed again) at the edge
    step = nav.step or 0.5,
    view_step = nav.view_step or 0.5,
    fine_step = nav.fine_step or 0.125,
    jump_near = nav.jump_near or 2,
    margin = nav.margin or 0,
    land_focus = nav.land_focus or "grid",
    land_past = nav.land_past == "nearest" and "nearest" or "blank",
    close_gap = nav.close_gap == true,
  }
  S.config_cache, S.config_parse = cfg, S.parse
  return cfg
end


-- Run fn once, ms from now.
local function later(ms, fn)
  hl.timer(fn, { timeout = ms, type = "oneshot" })
end

-- Tools that read this config with stand-in hl functions (SUPER+K's
-- keybinding list) hand back proxies; only touch the real thing.
local function live()
  return type(hl) == "table" and rawget(hl, "get_windows") ~= nil
end

local function api()
  if not live() then
    return nil
  end
  local p = rawget(hl, "plugin")
  local s = type(p) == "table" and rawget(p, "strata") or nil
  if s == nil and type(p) == "table" then
    -- hl.plugin may resolve namespaces lazily.
    local ok, v = pcall(function()
      return p.strata
    end)
    s = ok and v or nil
  end
  return type(s) == "table" and s or nil
end

local function plugin_file()
  local f = io.open(SO, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- Load on EVERY parse: Hyprland's plugin list is declarative, and a parse
-- that doesn't ask for it unloads it.
if live() and plugin_file() then
  hl.plugin.load(SO)
end

-- The column move animation as configured (speed, curve), so strata slide
-- vertically the way columns scroll horizontally.
local function move_animation()
  local a = api()
  local m = a and a.move_animation and a.move_animation()
  if type(m) ~= "table" or not m.speed then
    return nil
  end
  return m
end

local function bind(keys, description, fn, opts)
  if type(o) == "table" and o.bind then
    o.bind(keys, description, fn, opts)
  else
    local options = opts or {}
    options.description = description
    hl.bind(keys, fn, options)
  end
end

local function unbind(keys)
  pcall(hl.unbind, keys)
end

-- ── The stack ────────────────────────────────────────────────────────────

-- Free strata are the numbered workspaces. Dynamic: the ones with windows,
-- the one you're on, and one empty one waiting at the bottom of the block
-- (Hyprland drops empty workspaces as you leave them). Fixed: 1..count.
local function free_block()
  local cfg = M.config()
  local free = cfg.free or {}
  local out = {}
  if free.dynamic == false then
    for i = 1, free.count or 5 do
      out[#out + 1] = i
    end
    return out
  end
  local active = live() and hl.get_active_workspace() or nil
  local taken = {}
  for _, ws in ipairs(live() and hl.get_workspaces() or {}) do
    if ws.id > 0 and not ws.special and ws.windows > 0 then
      taken[ws.id] = true
      out[#out + 1] = ws.id
    end
  end
  table.sort(out)
  -- The one waiting empty stratum: the one you're on if it's an empty free
  -- one, else the lowest free number. It always sits at the bottom.
  local waiting
  if active and active.id > 0 and not active.special and not taken[active.id] then
    waiting = active.id
  else
    waiting = 1
    while taken[waiting] do
      waiting = waiting + 1
    end
  end
  out[#out + 1] = waiting
  return out
end

-- Top to bottom, as workspace selectors.
local function stack()
  local cfg = M.config()
  local s = {}
  for _, id in ipairs(cfg.stack or {}) do
    if id == "@free" then
      for _, n in ipairs(free_block()) do
        s[#s + 1] = tostring(n)
      end
    elseif cfg.strata and cfg.strata[id] and cfg.strata[id].workspace then
      s[#s + 1] = cfg.strata[id].workspace
    end
  end
  return s
end
M.stack = stack

-- A stratum id's place in the configured stack.
local function stack_index(cfg, id)
  for i, s in ipairs(cfg.stack or {}) do
    if s == id then
      return i
    end
  end
  return nil
end

local function matches(ws, sel)
  if sel:sub(1, 5) == "name:" then
    return ws.name == sel:sub(6)
  end
  return tostring(ws.id) == sel
end

local function position(ws)
  for i, sel in ipairs(stack()) do
    if matches(ws, sel) then
      return i
    end
  end
  return nil
end

local function wrap_vertical()
  return M.settings.wrap_vertical == true
end

-- Holding a direction at an edge: the first press there arms, a key repeat
-- (or a second press soon after) fires. Without wrap_hold it fires at once.
local function edge_fires(key)
  if not M.settings.wrap_hold then
    return true
  end
  if S.edge == key then
    S.edge = nil
    return true
  end
  S.edge = key
  S.edge_gen = (S.edge_gen or 0) + 1
  local gen = S.edge_gen
  later(900, function()
    if S.edge_gen == gen then
      S.edge = nil
    end
  end)
  return false
end

-- The stratum one step up (-1) or down (+1) from ws: selector, wrapped.
local function neighbour(ws, step)
  local s = stack()
  local i = position(ws)
  if not i then
    -- Outside the stack (workspace 11+): plain numeric neighbours.
    local t = ws.id + step
    if t < 1 then
      return nil, false
    end
    return tostring(t), false
  end
  local t = i + step
  if t >= 1 and t <= #s then
    return s[t], false
  end
  if not wrap_vertical() or not edge_fires("v" .. step) then
    return nil, false
  end
  return s[t < 1 and #s or 1], true
end


-- ── Helpers ──────────────────────────────────────────────────────────────

local function in_column(w)
  local l = w and w.layout
  return w ~= nil
    and not w.floating
    and type(l) == "table"
    and (l.name == "strata" or l.name == "scrolling")
    and l.column ~= nil
end

local function at_edge(w, step)
  local l = w.layout
  if step < 0 then
    return l.index_in_column == 0
  end
  return l.index_in_column >= #l.column.windows - 1
end

-- Dispatch with the wraparound animation on when the move wraps, so the top
-- stratum slides in from below the bottom one (and vice versa).
local function dispatch_wrapping(d, wrapped)
  if not wrapped then
    hl.dispatch(d)
    return
  end
  local saved = hl.get_config("animations:workspace_wraparound")
  hl.config({ animations = { workspace_wraparound = true } })
  local ok, err = pcall(hl.dispatch, d)
  hl.config({ animations = { workspace_wraparound = saved } })
  if not ok then
    error(err, 0)
  end
end

local function column_x(ws_id, address)
  local a = api()
  for _, c in ipairs(a.columns(ws_id)) do
    for _, addr in ipairs(c.windows) do
      if addr == address then
        return c.x
      end
    end
  end
  return nil
end

-- ── Actions ──────────────────────────────────────────────────────────────

function M.nav(dir)
  local a = api()
  if not a then
    hl.dispatch(hl.dsp.focus({ direction = dir }))
    return
  end
  local r = a.nav(dir, false)
  if r == "edge" then
    if M.settings.wrap_horizontal and edge_fires("h" .. dir) then
      a.nav(dir, true)
    end
  elseif r == "window" or r == "blank" then
    S.edge = nil
  elseif r == "none" then
    -- Special workspaces and other layouts: plain directional focus.
    hl.dispatch(hl.dsp.focus({ direction = dir }))
  end
end

local function focus_vertical(step)
  local direction = step < 0 and "u" or "d"
  local w = hl.get_active_window()
  local ws = hl.get_active_workspace()

  if w and w.workspace and w.workspace.special then
    hl.dispatch(hl.dsp.focus({ direction = direction }))
    return
  end

  if w and w.fullscreen == 0 then
    if in_column(w) then
      if not at_edge(w, step) then
        hl.dispatch(hl.dsp.focus({ direction = direction }))
        return
      end
    else
      -- Floating windows: move focus normally, and only change stratum when
      -- nothing lies that way. Overlapping floats can pass focus back and
      -- forth, so only a window whose centre lies that way counts.
      hl.dispatch(hl.dsp.focus({ direction = direction }))
      local now = hl.get_active_window()
      if now and now.address ~= w.address then
        if ((now.at.y + now.size.y / 2) - (w.at.y + w.size.y / 2)) * step > 0 then
          return
        end
        hl.dispatch(hl.dsp.focus({ window = "address:" .. w.address }))
      end
    end
  end

  if not ws then
    return
  end
  local target, wrapped = neighbour(ws, step)
  if not target then
    return
  end
  local a = api()
  if a then
    -- Going up lands on the bottom of the column above; going down, on top.
    a.hint(step)
  end
  dispatch_wrapping(hl.dsp.focus({ workspace = target }), wrapped)
end

local function move_vertical(step)
  local direction = step < 0 and "u" or "d"
  local w = hl.get_active_window()
  if not w then
    return
  end
  local ws = w.workspace
  if not ws or ws.special or w.fullscreen ~= 0 or not in_column(w) or not at_edge(w, step) then
    hl.dispatch(hl.dsp.window.swap({ direction = direction }))
    return
  end

  local target, wrapped = neighbour(ws, step)
  if not target then
    return
  end

  local a = api()
  if a then
    -- Same x one stratum over: stacked into the column there, or in its own.
    local x = column_x(ws.id, w.address)
    if x then
      a.expect(w.address, x, true, step)
    end
    a.hint(step)
  end
  dispatch_wrapping(hl.dsp.window.move({ workspace = target, follow = true }), wrapped)
end

function M.focus_up()
  focus_vertical(-1)
end

function M.focus_down()
  focus_vertical(1)
end

function M.move_up()
  move_vertical(-1)
end

function M.move_down()
  move_vertical(1)
end

function M.home()
  local a = api()
  if a then
    a.home()
  end
end

function M.nudge(dir)
  local a = api()
  if a then
    a.move(dir, true)
  end
end

-- Defined further down, with the overview and picture in picture.
local stack_ids
local pips


-- ── Routing ──────────────────────────────────────────────────────────────
--
-- Exact app rules become silent Hyprland window rules (the window maps
-- straight onto its stratum); app types and learned title patterns are
-- matched here when a window opens. Following a window to its stratum (or
-- keeping one launched with SUPER+Enter where you are) happens here too, so
-- the view never jumps twice.

local APPS_INDEX = HOME .. "/.cache/strata/apps.json" -- written by the shell plugin
local STATE_DIR = HOME .. "/.local/state/strata"

local function re(pattern, subject)
  local a = api()
  return a ~= nil and pattern ~= nil and pattern ~= "" and a.match(pattern, subject or "")
end

local function stratum_list(cfg)
  local out = {}
  for _, id in ipairs(cfg.stack or {}) do
    if id ~= "@free" and cfg.strata and cfg.strata[id] then
      out[#out + 1] = id
    end
  end
  return out
end

-- class -> { categories... }, from the shell's desktop-entry index.
local function categories_of(class)
  if not S.apps or S.apps_parse ~= S.parse then
    S.apps = {}
    S.apps_parse = S.parse
    for _, app in ipairs(read_json(APPS_INDEX) or {}) do
      for _, key in ipairs({ app.class, app.id }) do
        if key and key ~= "" then
          S.apps[string.lower(key)] = app.categories or {}
        end
      end
    end
  end
  return S.apps[string.lower(class or "")]
end

local function exact_target(cfg, class)
  for _, id in ipairs(stratum_list(cfg)) do
    for _, pat in ipairs(((cfg.strata[id].match or {}).apps) or {}) do
      if re(pat, class) then
        return id
      end
    end
  end
  return nil
end

local function learned_target(cfg, class, title)
  for _, rule in ipairs(cfg.learned or {}) do
    if rule.stratum and cfg.strata[rule.stratum] and re(rule.class, class) and (not rule.title or rule.title == "" or re(rule.title, title)) then
      return rule.stratum
    end
  end
  return nil
end

local function type_target(cfg, class)
  local cats = categories_of(class)
  if not cats then
    return nil
  end
  local have = {}
  for _, c in ipairs(cats) do
    have[c] = true
  end
  for _, id in ipairs(stratum_list(cfg)) do
    for _, t in ipairs(((cfg.strata[id].match or {}).types) or {}) do
      if have[t] then
        return id
      end
    end
  end
  return nil
end

-- Hyprland moves done by Strata (so they aren't mistaken for yours).
local function ours(addr, fn)
  S.moving = S.moving or {}
  S.moving[addr] = true
  local ok, err = pcall(fn)
  later(400, function()
    S.moving[addr] = nil
  end)
  if not ok then
    error(err, 0)
  end
end

local function follow(id, w)
  local cfg = M.config()
  local st = cfg.strata[id]
  if not st or not st.follow or S.booting then
    return
  end
  -- An app opening is worth going to; a popup of one isn't. A floating window
  -- (a Steam notification, a dialog) has no column to land on either, so you'd
  -- only be sent to whatever else is on that stratum. Unless the stratum
  -- floats all its windows.
  if w.floating and not (((st.profile or {}).windows or {}).float) then
    return
  end
  local ws = hl.get_active_workspace()
  if ws and matches(ws, st.workspace) then
    return
  end
  local a = api()
  if a then
    a.hint(0)
  end
  hl.dispatch(hl.dsp.focus({ workspace = st.workspace }))
  later(60, function()
    local a2 = api()
    if a2 then
      a2.reveal(w.address)
    end
  end)
end

local function send_to(id, w)
  local cfg = M.config()
  local st = cfg.strata[id]
  if not st or (w.workspace and matches(w.workspace, st.workspace)) then
    return
  end
  ours(w.address, function()
    local a = api()
    if a and a.opening then
      a.opening(w.address) -- still opening: it gets that stratum's window width
    end
    hl.dispatch(hl.dsp.window.move({ window = "address:" .. w.address, workspace = st.workspace, follow = false }))
  end)
end

local function on_open(w)
  if not w or not w.address or (w.workspace and w.workspace.special) then
    return
  end
  local cfg = M.config()
  local class, title = w.class or "", w.title or ""

  -- Launched here with SUPER+Enter: stays here, whatever its rules say.
  local lh = S.launch_here
  if lh and not lh.used then
    lh.used = true
    if w.workspace and not matches(w.workspace, lh.ws) then
      ours(w.address, function()
        local a = api()
        if a and a.opening then
          a.opening(w.address)
        end
        hl.dispatch(hl.dsp.window.move({ window = "address:" .. w.address, workspace = lh.ws, follow = false }))
      end)
      later(60, function()
        local a = api()
        if a then
          a.reveal(w.address)
        end
      end)
    end
    return
  end

  local id = exact_target(cfg, class)
  if id then
    -- Its window rule already put it there.
    follow(id, w)
    return
  end
  id = learned_target(cfg, class, title) or type_target(cfg, class)
  if id then
    send_to(id, w)
    follow(id, w)
  end
end

-- Titles often arrive after the window maps: learned title rules get a
-- second look for a few seconds.
local function on_title(w)
  if not w or not w.address or not S.fresh or not S.fresh[w.address] then
    return
  end
  local cfg = M.config()
  local id = learned_target(cfg, w.class or "", w.title or "")
  if id then
    S.fresh[w.address] = nil
    send_to(id, w)
  end
end

-- You moved a routed app somewhere else yourself: remember it as a
-- suggestion (app + title) for the settings to offer as a rule.
local function on_moved(w, ws)
  if not w or not w.address or not ws or ws.special or (S.moving and S.moving[w.address]) then
    return
  end
  -- A pinned window (PiP, a Steam toast) rides along to every stratum you
  -- visit: not a move of yours. Each hop used to be logged as one.
  if w.pinned or pips()[w.address] then
    return
  end
  local cfg = M.config()
  local class = w.class or ""
  local from = exact_target(cfg, class) or learned_target(cfg, class, w.title or "") or type_target(cfg, class)
  if not from then
    return
  end
  local to
  for _, id in ipairs(stratum_list(cfg)) do
    if matches(ws, cfg.strata[id].workspace) then
      to = id
    end
  end
  if to == from then
    return
  end
  os.execute("mkdir -p '" .. STATE_DIR .. "'")
  local f = io.open(STATE_DIR .. "/suggestions.jsonl", "a")
  if f then
    f:write(json_encode({ class = class or "", title = w.title or "", to = to or "", from = from, workspace = ws.name or "" }) .. "\n")
    f:close()
  end
end

-- Exact rules: one silent window rule per pattern, bottom of the stack
-- first so a stratum higher up wins a tie.
local function route_rules(cfg)
  local list = stratum_list(cfg)
  for i = #list, 1, -1 do
    local st = cfg.strata[list[i]]
    for _, pat in ipairs(((st.match or {}).apps) or {}) do
      pcall(hl.window_rule, { match = { class = pat }, workspace = st.workspace .. " silent" })
    end
  end
end

-- ── Profiles ─────────────────────────────────────────────────────────────

-- Static parts: looks (workspace rules) and window defaults (window rules).
local function profile_rules(cfg)
  for _, id in ipairs(stratum_list(cfg)) do
    local st = cfg.strata[id]
    local p = st.profile or {}
    local look = p.look or {}
    local wsrule = { workspace = st.workspace }
    local any = false
    for _, k in ipairs({ "gaps_in", "gaps_out", "border_size", "rounding" }) do
      if look[k] ~= nil then
        wsrule[k] = look[k]
        any = true
      end
    end
    if any then
      pcall(hl.workspace_rule, wsrule)
    end
    local sel = { workspace = st.workspace }
    if look.opacity then
      pcall(hl.window_rule, { match = sel, opacity = string.format("%s %s", look.opacity, look.opacity) })
    end
    if p.fullscreen and p.fullscreen ~= "" then
      pcall(hl.window_rule, { match = { class = p.fullscreen, workspace = st.workspace }, fullscreen = true })
    end
    local wd = p.windows or {}
    if wd.float then
      pcall(hl.window_rule, { match = sel, float = true })
    end
    if wd.maximize then
      pcall(hl.window_rule, { match = sel, maximize = true })
    end
    -- Window width: the plugin gives it to windows that open on this
    -- stratum (widths()). A window rule can't: it matches the workspace a
    -- window maps on, so windows opened here and routed elsewhere took it too.
    -- (A plugin not rebuilt yet has no widths(): the old rule.)
    local a = api()
    if wd.column_width and not (a and a.widths) then
      pcall(hl.window_rule, { match = sel, scrolling_width = wd.column_width })
    end
  end
end

-- Each stratum's window width, by workspace name, for the plugin.
local function stratum_widths(cfg)
  local out = {}
  for _, id in ipairs(stratum_list(cfg)) do
    local st = cfg.strata[id]
    local w = (((st.profile or {}).windows) or {}).column_width
    if type(w) == "number" and w > 0 and type(st.workspace) == "string" then
      out[st.workspace] = w
    end
  end
  return out
end

local function stratum_of(cfg, ws)
  if not ws then
    return nil
  end
  for _, id in ipairs(stratum_list(cfg)) do
    if matches(ws, cfg.strata[id].workspace) then
      return id
    end
  end
  if ws.id and ws.id > 0 then
    return "@free"
  end
  return nil
end

-- Switching themes as you move between strata. Passing through strata only
-- themes the one you stop on (a short debounce); the borders change at once
-- from the cached theme, the rest (shell, terminals, then apps) in
-- bin/strata-theme.
local THEME_CACHE = HOME .. "/.cache/strata/themes"

local function current_theme()
  local f = io.open(HOME .. "/.local/state/omarchy/current/theme.name", "r")
  if not f then
    return nil
  end
  local name = f:read("l")
  f:close()
  return name
end

function M.theme_to(theme, settle)
  -- Already on it, and nothing else pending.
  if S.theme_target == nil and current_theme() == theme then
    return
  end
  S.theme_target = theme
  S.theme_gen = (S.theme_gen or 0) + 1
  local gen = S.theme_gen
  later(140, function()
    if S.theme_gen ~= gen then
      return
    end
    S.theme_target = nil
    if current_theme() == theme then
      return
    end
    local borders = THEME_CACHE .. "/" .. theme .. "/hyprland.lua"
    local f = io.open(borders, "r")
    if f then
      f:close()
      pcall(dofile, borders)
    end
    hl.dispatch(hl.dsp.exec_cmd(string.format("%s apply '%s' %d", helper("strata-theme"), theme, settle)))
  end)
end

-- A reload forgets S, and with it where you were, but a profile that's on stays
-- on: this file says so, and leaving has to undo it.
local function profile_on()
  local f = io.open((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/strata-profile/active", "r")
  if f then
    f:close()
  end
  return f ~= nil
end

-- Arriving on a stratum: its runtime parts (the audio output via
-- bin/strata-profile, autostart), its theme, and its wallpaper.
local function on_stratum(ws)
  local cfg = M.config()
  local id = stratum_of(cfg, ws)
  if id == S.current_stratum then
    return
  end
  local prev = S.current_stratum
  S.current_stratum = id
  -- Only when leaving or entering a stratum whose profile does something
  -- outside Hyprland (no process per stratum change otherwise).
  local function runtime(k)
    local p = k and k ~= "@free" and cfg.strata[k] and cfg.strata[k].profile or nil
    return p and p.audio_output and p.audio_output ~= ""
  end
  if runtime(prev) or runtime(id) or S.profile_active or profile_on() then
    S.profile_active = runtime(id) and true or false
    hl.dispatch(hl.dsp.exec_cmd(string.format("%s switch '%s' '%s'", helper("strata-profile"), prev or "", id or "")))
  end

  local st = id and cfg.strata[id] or nil

  -- Its theme (or the base, for strata without one of their own), unless
  -- theme switching is off.
  local th = cfg.themes or {}
  local own = (id == "@free" and (cfg.free or {}).theme) or (st and st.theme) or nil
  local theme = own or th.base
  if th.switching ~= false and theme and theme ~= "" then
    M.theme_to(theme, th.settle_ms or 1500)
  end

  -- Autostart: once per login, the first time you get there.
  if st and st.profile and st.profile.autostart then
    local mark = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/strata-autostarted-" .. id
    local f = io.open(mark, "r")
    if f then
      f:close()
    else
      f = io.open(mark, "w")
      if f then
        f:close()
      end
      for _, cmd in ipairs(st.profile.autostart) do
        hl.dispatch(hl.dsp.exec_cmd(cmd))
      end
    end
  end
end

-- ── Wallpapers ───────────────────────────────────────────────────────────

local function expand(path)
  return path and (path:gsub("^~", HOME)) or nil
end

-- A theme's first background, wherever Omarchy keeps it.
-- Where a theme's backgrounds are, first match wins: your own backgrounds for
-- it, your own copy of the theme, Omarchy's, then Strata's cached copy.
local OMARCHY = os.getenv("OMARCHY_PATH") or "/usr/share/omarchy"
local function theme_dirs(theme)
  return {
    HOME .. "/.config/omarchy/backgrounds/" .. theme,
    HOME .. "/.config/omarchy/themes/" .. theme .. "/backgrounds",
    OMARCHY .. "/themes/" .. theme .. "/backgrounds",
    THEME_CACHE .. "/" .. theme .. "/backgrounds",
  }
end
-- The same places for every theme at once.
local THEME_ROOTS = { HOME .. "/.config/omarchy/backgrounds", HOME .. "/.config/omarchy/themes", OMARCHY .. "/themes", THEME_CACHE }

local function theme_background(theme)
  if not theme or theme == "" then
    return nil
  end
  S.theme_bg = S.theme_bg or {}
  if S.theme_bg[theme] ~= nil then
    return S.theme_bg[theme] or nil
  end
  local found = false
  for _, d in ipairs(theme_dirs(theme)) do
    local p = io.popen("find -L '" .. d .. "' -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) 2>/dev/null | sort | head -1")
    if p then
      local line = p:read("l")
      p:close()
      if line and line ~= "" then
        found = line
        break
      end
    end
  end
  S.theme_bg[theme] = found
  return found or nil
end

local function exists(path)
  local f = path and io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

-- A picture saved from ~/.local/state/omarchy/current/theme/backgrounds
-- moves with every theme switch; find it again by name where themes keep
-- their backgrounds (and Strata's theme cache).
local function stable(path)
  if not path or exists(path) then
    return path
  end
  S.found = S.found or {}
  if S.found[path] ~= nil then
    return S.found[path] or nil
  end
  local name = path:match("([^/]+)$") or ""
  local p = io.popen(string.format("find -L '%s' -name '%s' -type f 2>/dev/null | head -1", table.concat(THEME_ROOTS, "' '"), (name:gsub("'", ""))))
  local hit = p and p:read("l") or nil
  if p then
    p:close()
  end
  S.found[path] = hit or false
  return hit
end

local function wallpaper_of(st)
  if not st then
    return nil
  end
  if st.wallpaper and st.wallpaper ~= "" then
    return stable(expand(st.wallpaper))
  end
  return theme_background(st.theme)
end

-- Wallpapers from the current theme, one per stratum (theme switching off,
-- "auto_wallpapers" on): each stratum gets a different one, going down the
-- stack. The stratum you're on shows the one Omarchy's picker set, and the
-- others follow on from it, so picking one turns the whole stack.
local AUTO_STATE = HOME .. "/.local/state/strata/auto-wallpapers"

-- The current theme's wallpapers in Omarchy's own order: what its picker and
-- "next background" go through (your backgrounds for the theme, then the
-- theme's own, via current/theme), so the stack follows the picker.
local function theme_backgrounds(theme)
  S.auto_list = S.auto_list or {}
  if S.auto_list[theme] then
    return S.auto_list[theme]
  end
  local list = {}
  local p = io.popen(string.format(
    "find -L '%s/.config/omarchy/backgrounds/%s/' '%s/.local/state/omarchy/current/theme/backgrounds/' -maxdepth 1 -type f "
      .. "\\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \\) 2>/dev/null | sort",
    HOME, theme:gsub("'", ""), HOME))
  if p then
    for line in p:lines() do
      list[#list + 1] = line
    end
    p:close()
  end
  S.auto_list[theme] = list
  return list
end

-- Where the theme keeps a wallpaper for good: what's under current/theme is
-- swapped out by the next theme switch (and drawn pictures are cached by path).
local function pinned(path, theme)
  if not path:find("/.local/state/omarchy/current/", 1, true) then
    return path
  end
  local name = path:match("([^/]+)$") or ""
  for _, d in ipairs(theme_dirs(theme)) do
    if exists(d .. "/" .. name) then
      return d .. "/" .. name
    end
  end
  return path
end

-- How far along the theme's list the top of the stack starts, saved per theme.
local function auto_offset(cfg, theme, list, reanchor)
  if not reanchor then
    local f = io.open(AUTO_STATE, "r")
    if f then
      local t, o = (f:read("a") or ""):match("^(.-)\n(%-?%d+)")
      f:close()
      if t == theme and o then
        return tonumber(o)
      end
    end
  end
  -- Anchor on the stratum you're on: it shows Omarchy's current wallpaper.
  local offset = 0
  local p = io.popen("readlink '" .. HOME .. "/.local/state/omarchy/current/background' 2>/dev/null")
  local cur = p and p:read("l") or nil
  if p then
    p:close()
  end
  local at
  for i, path in ipairs(list) do
    if cur and (path == cur or path:match("([^/]+)$") == cur:match("([^/]+)$")) then
      at = i
      break
    end
  end
  local si = stack_index(cfg, stratum_of(cfg, hl.get_active_workspace()) or "")
  if at and si then
    offset = (at - si) % #list
  end
  local f = io.open(AUTO_STATE, "w")
  if f then
    f:write(theme, "\n", offset, "\n")
    f:close()
  end
  return offset
end

-- Omarchy's pickers set a theme or wallpaper (strata-capture, switching off).
function M.wallpaper_picked()
  S.auto_list = nil
  local cfg = M.config()
  local th = cfg.themes or {}
  local theme = current_theme()
  if th.switching == false and th.auto_wallpapers == true and theme then
    local list = theme_backgrounds(theme)
    if #list > 0 then
      auto_offset(cfg, theme, list, true)
    end
  end
  M.update_wallpapers()
end

function M.update_wallpapers()
  local a = api()
  if not a then
    return
  end
  local cfg = M.config()
  local th = cfg.themes or {}
  -- Each stratum's wallpaper by its id in the stack ("@free" for the free
  -- block). Wallpapers go with themes: its own while themes switch between
  -- strata; with switching off, none, or one of the current theme's each.
  local switching = th.switching ~= false
  local per = {}
  if switching then
    for _, id in ipairs(stratum_list(cfg)) do
      per[id] = wallpaper_of(cfg.strata[id])
    end
    per["@free"] = wallpaper_of(cfg.free)
  end
  local theme = not switching and th.auto_wallpapers == true and current_theme() or nil
  local list = theme and theme_backgrounds(theme) or {}
  if #list > 0 then
    local offset = auto_offset(cfg, theme, list, false)
    for i, id in ipairs(cfg.stack or {}) do
      per[id] = pinned(list[(i - 1 + offset) % #list + 1], theme)
    end
  end

  -- Handed over three ways: by workspace id; by name, for a stratum whose
  -- workspace is made before this runs again (switching to an empty one);
  -- and in stack order, for strata with no workspace (overview, cross).
  local paths, rows, any = {}, {}, false
  local by_sel = {}
  for id, path in pairs(per) do
    any = true
    if id == "@free" then
      paths["@free"] = path
      for _, ws in ipairs(hl.get_workspaces()) do
        if ws.id > 0 and not ws.special then
          paths[ws.id] = path
        end
      end
    elseif cfg.strata[id] then
      local sel = cfg.strata[id].workspace
      by_sel[sel] = id
      local w = hl.get_workspace(sel)
      if w then
        paths[w.id] = path
      end
      local name = sel:match("^name:(.+)$")
      if name then
        paths[name] = path
      end
    end
  end
  for i, sel in ipairs(stack()) do
    rows[i] = per[by_sel[sel] or "@free"] or ""
  end
  -- Strata without their own show the base: set explicitly, the base
  -- theme's, or (when some stratum has its own) Omarchy's current one.
  local base = switching and (stable(expand(th.base_wallpaper)) or theme_background(th.base)) or nil
  -- Parallax and the sliding transitions need Strata to draw the wallpaper
  -- even where no stratum has one of its own.
  any = any or th.wallpaper_parallax == true or (th.wallpaper_vertical and th.wallpaper_vertical ~= "crossfade")
  if not base and any then
    local p = io.popen("readlink -f '" .. HOME .. "/.local/state/omarchy/current/background' 2>/dev/null")
    if p then
      base = p:read("l")
      p:close()
    end
  end
  a.wallpapers(paths, base or "", th.wallpaper_vertical or "crossfade", th.wallpaper_parallax == true, th.parallax_strength or 0.08, rows)
end

-- ── First run: route the windows already open ────────────────────────────

local MIGRATION = STATE_DIR .. "/migration.json"

local function sel_of(ws)
  return ws.id > 0 and tostring(ws.id) or ("name:" .. ws.name)
end

function M.migrate()
  local cfg = M.config()
  local back = json_array()
  for _, w in ipairs(hl.get_windows()) do
    if w.address and w.workspace and not w.workspace.special then
      local id = exact_target(cfg, w.class or "") or learned_target(cfg, w.class or "", w.title or "") or type_target(cfg, w.class or "")
      if id and not matches(w.workspace, cfg.strata[id].workspace) then
        back[#back + 1] = { a = w.address, ws = sel_of(w.workspace) }
        send_to(id, w)
      end
    end
  end
  os.execute("mkdir -p '" .. STATE_DIR .. "'")
  local f = io.open(MIGRATION, "w")
  if f then
    f:write(json_encode(back) .. "\n")
    f:close()
  end
  hl.dispatch(hl.dsp.exec_cmd(string.format("omarchy-notification-send 'Strata' 'Routed %d windows to their strata' -t 4000", #back)))
end

function M.unmigrate()
  local list = read_json(MIGRATION) or {}
  local n = 0
  for _, e in ipairs(list) do
    local w = hl.get_window("address:" .. e.a)
    if w and w.workspace and not matches(w.workspace, e.ws) then
      n = n + 1
      ours(e.a, function()
        hl.dispatch(hl.dsp.window.move({ window = "address:" .. e.a, workspace = e.ws, follow = false }))
      end)
    end
  end
  hl.dispatch(hl.dsp.exec_cmd(string.format("omarchy-notification-send 'Strata' 'Restored %d windows to their previous workspaces' -t 4000", n)))
end


-- ── Picture in picture ───────────────────────────────────────────────────
--
-- The plugin does it (native/src/pip.cpp): while a window on the stratum
-- you're on plays video (the shell says which, by its MPRIS player), it
-- learns where the picture is in it; leaving that stratum, or opening the
-- overview, shrinks the picture into a card that stays on screen, and coming
-- back grows it home. The window never moves. The shell draws the card's
-- controls and calls the functions below.
--
-- 1.11's first cut moved nothing either but sent the page "f"; a window still
-- out that way when this loads is brought back by pip_in (and older ones,
-- floated and pinned, too).

local PIP_OUT = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/strata-pip-out-" .. (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "") .. ".json"

-- Is the window at addr still the one recorded (same class)?
local function same_window(addr, class)
  local w = hl.get_window("address:" .. addr)
  return w ~= nil and (class == nil or class == "" or w.class == class)
end

local function pip_save()
  local out = {}
  for addr, e in pairs(S.pip or {}) do
    out[addr] = { ws = e.ws or "", x = e.x, class = e.class or "", mode = e.mode, fs = e.fs }
  end
  local f = io.open(PIP_OUT, "w")
  if f then
    f:write(json_encode(out) .. "\n")
    f:close()
  end
end

pips = function()
  if not S.pip then
    S.pip = {}
    local dropped = false
    for addr, e in pairs(read_json(PIP_OUT) or {}) do
      -- Hyprland reuses window addresses: after the app restarts, another
      -- window (a browser tab) can have this one's address. Same class or drop.
      if type(e) == "table" and same_window(addr, e.class) then
        S.pip[addr] = { ws = e.ws, x = e.x, class = e.class, mode = e.mode, fs = e.fs }
      else
        dropped = true
      end
    end
    if dropped then
      pip_save()
    end
  end
  return S.pip
end

local function chromium(class)
  return class == "helium" or class == "chromium" or class == "Chromium" or class == "google-chrome" or class == "brave-browser" or (class or ""):find("^chrome%-") ~= nil
end

-- The shell's calls.
function M.pip_watch(addr, playing)
  local a = api()
  if a and a.pip_watch then
    a.pip_watch(addr, playing == true)
  end
end

function M.pip_config(corner, width, accent)
  local a = api()
  if a and a.pip_config then
    a.pip_config(corner or "bottom-right", width or 0.25, accent or "#8cb4ff")
  end
end

function M.pip_card(x, y, w, h)
  local a = api()
  return a and a.pip_card and a.pip_card(x, y, w, h)
end

function M.pip_scale(f)
  local a = api()
  return a and a.pip_scale and a.pip_scale(f)
end

function M.pip_drag(edges)
  local a = api()
  return a and a.pip_drag and a.pip_drag(edges or 0)
end

function M.pip_drag_end()
  local a = api()
  if a and a.pip_drag_end then
    a.pip_drag_end()
  end
end

-- X: home without going there (it keeps playing there).
function M.pip_home()
  local a = api()
  return a and a.pip_home and a.pip_home()
end

-- The card's stratum button: go there (arriving brings it home).
function M.pip_go()
  local a = api()
  local name = a and a.pip_workspace and a.pip_workspace() or ""
  if name == "" then
    return
  end
  a.hint(0)
  hl.dispatch(hl.dsp.focus({ workspace = tonumber(name) and name or ("name:" .. name) }))
end

function M.pip_crop(addr, x0, y0, x1, y1)
  local a = api()
  if a and a.pip_crop then
    a.pip_crop(addr, x0, y0, x1, y1)
  end
end

function M.pip_announce()
  local a = api()
  if a and a.pip_announce then
    a.pip_announce()
  end
end

function M.pip_in(addr)
  local e = pips()[addr]
  if not e then
    return
  end
  S.pip[addr] = nil
  pip_save()
  local w = hl.get_window("address:" .. addr)
  hl.dispatch(hl.dsp.event(string.format('strata-pip>>{"open":false,"a":"%s","class":"%s"}', addr, e.class or "")))
  if not w or not same_window(addr, e.class) then
    return
  end
  local win = "address:" .. addr
  if e.mode == "mirror" then
    pcall(function()
      hl.dispatch(hl.dsp.window.set_prop({ prop = "focus_on_activate", value = "unset", window = win }))
    end)
    if e.fs then
      hl.dispatch(hl.dsp.send_shortcut({ mods = "", key = "f", window = win }))
      later(400, function()
        pcall(function()
          hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 0, window = win }))
        end)
      end)
    end
    return
  end
  -- Out the 1.1 way (the window itself floated and pinned): back in its tile.
  local a = api()
  ours(addr, function()
    hl.dispatch(hl.dsp.window.fullscreen_state({ internal = 0, client = 0, window = win }))
    if chromium(e.class) then
      hl.dispatch(hl.dsp.send_shortcut({ mods = "", key = "Escape", window = win }))
    end
    hl.dispatch(hl.dsp.window.pin({ action = "disable", window = win }))
    if a and e.x then
      a.expect(addr, e.x, false, 0)
    end
    hl.dispatch(hl.dsp.window.float({ action = "disable", window = win }))
    local cur = hl.get_window(win)
    if cur and cur.workspace and not matches(cur.workspace, e.ws) then
      hl.dispatch(hl.dsp.window.move({ window = win, workspace = e.ws, follow = false }))
    elseif a and e.x then
      a.place(addr, e.x)
    end
  end)
end

-- Arriving on a stratum: its PiP windows come home.
local function pip_return(ws)
  for addr, e in pairs(pips()) do
    if ws and matches(ws, e.ws) then
      M.pip_in(addr)
    end
  end
end

-- ── SUPER+Enter: the stratum's own app ───────────────────────────────────

local PRIMARY = {
  terminal = "omarchy-launch-terminal",
  browser = "omarchy-launch-browser",
  steam = "omarchy-launch-or-focus steam 'uwsm-app -- steam'",
}

function M.primary()
  local cfg = M.config()
  local ws = hl.get_active_workspace()
  local id = stratum_of(cfg, ws)
  local st = id == "@free" and (cfg.free or {}) or (id and cfg.strata[id]) or {}
  local primary = st.primary
  if not primary or primary == "" then
    primary = "terminal"
  end
  local cmd = PRIMARY[primary] or primary
  local cwd = st.cwd
  if primary == "terminal" and cwd and cwd ~= "" then
    cmd = "uwsm-app -- xdg-terminal-exec --dir=" .. cwd:gsub("^~", HOME)
  end
  -- Whatever it opens stays here (routing would send a terminal on Code off
  -- to the Terminal stratum otherwise).
  if ws then
    local sel = ws.id > 0 and tostring(ws.id) or ("name:" .. ws.name)
    S.launch_here = { ws = sel }
    later(4000, function()
      S.launch_here = nil
    end)
  end
  hl.dispatch(hl.dsp.exec_cmd(cmd))
end

-- ── Setup ────────────────────────────────────────────────────────────────

-- Not built yet, or built for another Hyprland: Hyprland keeps its own
-- layout. Say so once per login.
local function notify_not_loaded()
  local mark = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/strata-not-loaded"
  if not exists(mark) then
    local f = io.open(mark, "w")
    if f then
      f:close()
    end
    hl.dispatch(hl.dsp.exec_cmd("omarchy-notification-send 'Strata is not running' 'Its Hyprland plugin is not built for this Hyprland. Open Strata settings > Setup and choose Rebuild.' -t 10000"))
  end
end

-- The layout, its options and the vertical slide.
local function apply_layout(cfg)
  local st = M.settings
  hl.config({
    general = { layout = "strata" },
    plugin = {
      strata = {
        step = st.step,
        view_step = st.view_step,
        fine_step = st.fine_step,
        jump_near = st.jump_near,
        margin = st.margin,
        land_focus = st.land_focus,
        close_gap = st.close_gap,
        wrap = false, -- wrapping is decided here (hold-to-wrap)
        cross_trigger = (cfg.cross or {}).trigger or "move",
        cross_placement = (cfg.cross or {}).placement or "bottom",
        cross_size = (cfg.cross or {}).size or 0.16,
        cross_fade_ms = (cfg.cross or {}).fade_ms or 800,
      },
    },
  })
  -- Options added in 1.1, on their own: a plugin not rebuilt yet (which
  -- doesn't know them) still gets everything above.
  pcall(hl.config, { plugin = { strata = { land_past = st.land_past } } })

  -- Strata slide vertically with the column-scroll animation.
  local m = move_animation()
  if m then
    hl.animation({ leaf = "workspaces", enabled = m.enabled, speed = m.speed, bezier = m.bezier, style = "slidevert" })
  end
end

-- Strata's keys, by group (Settings > Navigation > Key bindings can hand each
-- group back to Omarchy), the gestures and SUPER+RETURN.
local function bind_keys(cfg)
  local groups = cfg.keys or {}
  local function on(group)
    return groups[group] ~= false
  end
  local keys = {
    { "grid", "SUPER + LEFT", "Focus left (or move into empty space)", function() M.nav("l") end, { repeating = true } },
    { "grid", "SUPER + RIGHT", "Focus right (or move into empty space)", function() M.nav("r") end, { repeating = true } },
    { "grid", "SUPER + UP", "Focus up / stratum above", M.focus_up, { repeating = true } },
    { "grid", "SUPER + DOWN", "Focus down / stratum below", M.focus_down, { repeating = true } },
    { "grid", "SUPER + SHIFT + UP", "Move window up / to the stratum above", M.move_up },
    { "grid", "SUPER + SHIFT + DOWN", "Move window down / to the stratum below", M.move_down },
    { "grid", "SUPER + CTRL + SHIFT + LEFT", "Nudge window left", function() M.nudge("l") end, { repeating = true } },
    { "grid", "SUPER + CTRL + SHIFT + RIGHT", "Nudge window right", function() M.nudge("r") end, { repeating = true } },
    { "grid", "SUPER + CTRL + Home", "Back to the focused window", M.home },
    { "overview", "SUPER + TAB", "Overview of all strata", function() M.overview(false) end },
    { "overview", "SUPER + SHIFT + TAB", "Overview, searching", M.overview_search },
    { "wheel", "SUPER + mouse_down", "Focus right (or move into empty space)", function() M.nav("r") end },
    { "wheel", "SUPER + mouse_up", "Focus left (or move into empty space)", function() M.nav("l") end },
    { "wheel", "SUPER + SHIFT + mouse_down", "Stratum below", M.focus_down },
    { "wheel", "SUPER + SHIFT + mouse_up", "Stratum above", M.focus_up },
  }
  for _, k in ipairs(keys) do
    if on(k[1]) then
      unbind(k[2])
      bind(k[2], k[3], k[4], k[5])
    end
  end

  if on("strata") then
    M.bind_hotkeys(cfg)
  end

  -- Three fingers: sideways pans the grid (settling on the step grid when you
  -- let go), up/down moves a stratum.
  local function usable_width()
    local mon = hl.get_active_monitor()
    return mon and (mon.width / (mon.scale or 1)) or 1800
  end
  if on("gestures") then
    pcall(hl.gesture, {
      fingers = 3,
      direction = "horizontal",
      action = {
        update = function(e)
          local api_ = api()
          if api_ and e and e.delta and e.delta.x then
            api_.pan(-e.delta.x / usable_width())
          end
        end,
        ["end"] = function()
          local api_ = api()
          if api_ then
            api_.settle()
          end
        end,
      },
    })
    pcall(hl.gesture, {
      fingers = 3,
      direction = "vertical",
      action = {
        start = function()
          S.vswipe, S.vdone = 0, false
        end,
        update = function(e)
          S.vswipe = (S.vswipe or 0) + ((e and e.delta and e.delta.y) or 0)
          if not S.vdone and math.abs(S.vswipe) > 140 then
            S.vdone = true
            if S.vswipe < 0 then
              M.focus_down()
            else
              M.focus_up()
            end
          end
        end,
      },
    })
  end

  if on("launch") then
    unbind("SUPER + RETURN")
    bind("SUPER + RETURN", "Launch the current stratum's app", M.primary)
  end
end

-- Private strata: previews show cards, not windows. By name: a stratum's
-- workspace gets a new id each time it's made, and ids are reused.
local function private_names(cfg)
  local priv = {}
  for _, id in ipairs(stratum_list(cfg)) do
    if (cfg.strata[id].profile or {}).private then
      priv[#priv + 1] = cfg.strata[id].workspace
    end
  end
  return priv
end

-- Hyprland's events: stratum changes (the stack order for the cross and the
-- slides, profiles, themes, picture in picture), new windows (routing), titles
-- (learned rules), moves (suggestions); and the stack's free block, which
-- changes as windows come and go.
local function subscribe(a)
  for _, sub in ipairs(S.subscriptions or {}) do
    pcall(function()
      sub:remove()
    end)
  end
  local function soon()
    later(30, function()
      pcall(M.update_wallpapers)
      pcall(function()
        a.order((stack_ids()), wrap_vertical())
      end)
      -- Free strata come and go with their windows: the overview's rows
      -- must stay the stack Lua picks from (Enter, drops), row for row.
      pcall(function()
        if a.overview_is_open() then
          a.overview_rows((stack_ids()))
        end
      end)
    end)
  end
  -- A reload while the overview is open (the stack was reordered there).
  if a.overview_is_open() then
    later(50, function()
      local ids = stack_ids()
      a.overview_rows(ids)
    end)
  end

  S.fresh = S.fresh or {}
  S.subscriptions = {
    hl.on("workspace.active", function(ws)
      -- Right away, so the cross shows the right strata above and below.
      pcall(function()
        a.order((stack_ids()), wrap_vertical())
      end)
      soon()
      pcall(on_stratum, ws)
      pcall(pip_return, ws)
    end),
    hl.on("window.open", function(w)
      soon()
      if w and w.address then
        S.fresh[w.address] = true
        later(4000, function()
          S.fresh[w.address] = nil
        end)
      end
      -- A moment later: the window has its class, title and workspace.
      later(30, function()
        local live_w = w and w.address and hl.get_window("address:" .. w.address)
        pcall(on_open, live_w)
      end)
    end),
    hl.on("window.close", function(w)
      -- A window closed while out: forget it, or its address (which Hyprland
      -- hands out again) would pull some other window home later.
      if w and w.address and S.pip and S.pip[w.address] then
        S.pip[w.address] = nil
        pip_save()
      end
      soon()
    end),
    hl.on("window.title", function(w)
      pcall(on_title, w)
    end),
    hl.on("window.move_to_workspace", function(w, ws)
      soon()
      pcall(on_moved, w, ws)
    end),
  }
  soon()
end

-- Call after every other config file: Omarchy's defaults (and anything else)
-- set the workspace animation, layout and keys, and these must win.
function M.setup()
  if not live() then
    return
  end
  local a = api()
  if not a then
    notify_not_loaded()
    return
  end
  local cfg = M.config()
  apply_layout(cfg)
  bind_keys(cfg)
  route_rules(cfg)
  profile_rules(cfg)
  a.private(private_names(cfg))
  if a.widths then
    a.widths(stratum_widths(cfg))
  end
  -- Nothing follows windows to their strata while a session starts up.
  if S.booting == nil then
    S.booting = true
    later(10000, function()
      S.booting = false
    end)
  end
  subscribe(a)
end

-- ── Per-stratum hotkeys ──────────────────────────────────────────────────

-- "1".."9","0" are the number row by keycode (layout independent, like
-- Omarchy's own workspace keys); anything else is a key name.
local function keyname(k)
  local d = tonumber(k)
  if d and #tostring(k) == 1 then
    return "code:" .. tostring(d == 0 and 19 or d + 9)
  end
  return k
end

local function stratum_selector(cfg, id)
  if id == "@free" then
    local block = free_block()
    -- The first free stratum, or the waiting one when there are none.
    return tostring(block[1])
  end
  local st = cfg.strata and cfg.strata[id]
  return st and st.workspace or nil
end

function M.go(id)
  local cfg = M.config()
  local sel = stratum_selector(cfg, id)
  if not sel then
    return
  end
  local a = api()
  if a then
    a.hint(0)
  end
  hl.dispatch(hl.dsp.focus({ workspace = sel }))
end

-- ── Overview (SUPER+TAB) ─────────────────────────────────────────────────

-- The stack as workspace ids (0 where a stratum has no workspace yet) and
-- the row you're on.
stack_ids = function()
  local ids, cur = {}, 1
  local ws = hl.get_active_workspace()
  for i, sel in ipairs(stack()) do
    local w = hl.get_workspace(sel)
    ids[i] = w and w.id or 0
    if ws and matches(ws, sel) then
      cur = i
    end
  end
  return ids, cur
end

-- Toggle; search: open with the search field focused (SUPER+SHIFT+TAB).
function M.overview(search)
  local a = api()
  if not a then
    return
  end
  if a.overview_is_open() then
    a.overview_close(0)
    return
  end
  local ids, cur = stack_ids()
  a.overview_open(ids, cur, search == true)
end

function M.overview_search()
  M.overview(true)
end

-- From the overview: go to stratum `index` (1-based, stack order), onto
-- window `addr` if given, else to the blank slot [x, x + w] (w nil: the slot
-- at x on the view-step grid), else wherever switching there lands.
function M.overview_go(index, x, addr, w)
  local a = api()
  local sel = stack()[index]
  if not a then
    return
  end
  if not sel then
    a.overview_close(0)
    return
  end
  local ws = hl.get_active_workspace()
  if not (ws and matches(ws, sel)) then
    a.hint(0)
    hl.dispatch(hl.dsp.focus({ workspace = sel }))
  end
  -- After the switch has landed (land() runs a moment later).
  later(40, function()
    if addr and addr ~= "" then
      -- A floating window has no column to reveal: focus it.
      if not a.reveal(addr) then
        hl.dispatch(hl.dsp.focus({ window = "address:" .. addr }))
      end
    elseif x then
      a.aim(x, w or 0)
    end
    a.overview_close(index)
  end)
end

-- Dragging a window in the overview: the shell says start, drop and cancel;
-- the plugin does everything in between. A drop on another stratum comes
-- back here to be a normal move (rules and the rest see it), and lands where
-- the drag showed.
function M.overview_drag(addr, edge, fx, fy)
  local a = api()
  if a then
    a.overview_drag(addr, edge or 0, fx or 0.5, fy or 0.5)
  end
end

local function overview_rows_later()
  later(40, function()
    local a = api()
    if a then
      a.overview_rows(stack_ids())
    end
  end)
end

function M.overview_drag_end()
  local a = api()
  if not a then
    return
  end
  local row, addr = a.overview_drag_end()
  if not row then
    return
  end
  local sel = stack()[row]
  if sel then
    hl.dispatch(hl.dsp.window.move({ window = "address:" .. addr, workspace = sel, follow = false }))
  end
  a.overview_drag_finish()
  overview_rows_later()
end

function M.overview_drag_cancel()
  local a = api()
  if a then
    a.overview_drag_cancel()
  end
end

-- The overview's SHIFT+arrows on the selected window: SUPER+SHIFT+arrows'
-- moves, without following it.
function M.overview_move(addr, dir)
  local a = api()
  local w = hl.get_window("address:" .. addr)
  if not a or not w or a.move_window(addr, dir) ~= "edge" then
    return
  end
  -- Up or down off its column: the same x one stratum over, stacked into
  -- the column there or in its own.
  local step = dir == "u" and -1 or 1
  local ws = w.workspace
  local target = ws and neighbour(ws, step)
  if not target then
    return
  end
  local x = column_x(ws.id, addr)
  if x then
    a.expect(addr, x, true, step)
  end
  hl.dispatch(hl.dsp.window.move({ window = "address:" .. addr, workspace = target, follow = false }))
  overview_rows_later()
end

-- CTRL+Left/Right: its column a fine step narrower or wider.
function M.overview_widen(addr, dir)
  local a = api()
  if a then
    a.widen(addr, dir)
  end
end

-- From anywhere: go to the stratum; from that stratum: back where you were.
function M.toggle(id)
  local cfg = M.config()
  local sel = stratum_selector(cfg, id)
  local ws = hl.get_active_workspace()
  if sel and ws and matches(ws, sel) then
    hl.dispatch(hl.dsp.focus({ workspace = "previous" }))
  else
    M.go(id)
  end
end

function M.send(id, follow)
  local cfg = M.config()
  local sel = stratum_selector(cfg, id)
  local w = hl.get_active_window()
  if not sel or not w then
    return
  end
  local a = api()
  if a and in_column(w) then
    -- It lands at the same x on the grid.
    local x = column_x(w.workspace.id, w.address)
    if x then
      a.expect(w.address, x, false, 0)
    end
  end
  hl.dispatch(hl.dsp.window.move({ workspace = sel, follow = follow }))
end

function M.bind_hotkeys(cfg)
  -- Omarchy's numbered workspace keys give way to the strata's own.
  for n = 1, 10 do
    local key = "code:" .. tostring(n + 9)
    unbind("SUPER + " .. key)
    unbind("SUPER + SHIFT + " .. key)
    unbind("SUPER + SHIFT + ALT + " .. key)
  end

  local entries = {}
  for _, id in ipairs(cfg.stack or {}) do
    if id == "@free" then
      local f = cfg.free or {}
      entries[#entries + 1] = { id = "@free", name = f.name or "Free", hotkey = f.hotkey }
    elseif cfg.strata and cfg.strata[id] then
      local st = cfg.strata[id]
      entries[#entries + 1] = { id = id, name = st.name or id, hotkey = st.hotkey, extra = st.extraHotkeys }
    end
  end

  for _, e in ipairs(entries) do
    local keys = {}
    if e.hotkey and e.hotkey ~= "" then
      keys[#keys + 1] = { keyname(e.hotkey), false }
    end
    for _, k in ipairs(e.extra or {}) do
      keys[#keys + 1] = { keyname(k), true }
    end
    for _, k in ipairs(keys) do
      local key, toggles = k[1], k[2]
      local id = e.id
      unbind("SUPER + " .. key)
      unbind("SUPER + SHIFT + " .. key)
      unbind("SUPER + SHIFT + ALT + " .. key)
      if toggles then
        bind("SUPER + " .. key, "Toggle " .. e.name, function() M.toggle(id) end)
      else
        bind("SUPER + " .. key, "Go to " .. e.name, function() M.go(id) end)
      end
      bind("SUPER + SHIFT + " .. key, "Move window to " .. e.name, function() M.send(id, true) end)
      bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to " .. e.name, function() M.send(id, false) end)
    end
  end
end

return M
