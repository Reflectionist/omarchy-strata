-- Nested Hyprland for testing Strata: tests/start.sh (STRATA_ROOT is the
-- plugin folder, STRATA_SO the fresh build, STRATA_CONFIG_DIR a test config).
hl.monitor({ output = "", mode = "1440x900", position = "auto", scale = 1 })
-- start.sh adds a headless output (STRATATEST) and turns the window's own
-- output off; keep it that way across reloads.
hl.monitor({ output = "STRATATEST", mode = "1440x900@60", position = "0x0", scale = 1 })
-- (After the parse: a rule set while parsing doesn't turn an output off.)
hl.timer(function()
  local names = {}
  for _, m in ipairs(hl.get_monitors()) do
    names[#names + 1] = m.name
  end
  if table.concat(names, " "):find("STRATATEST", 1, true) then
    for _, n in ipairs(names) do
      if n:match("^WAYLAND%-") then
        hl.monitor({ output = n, disabled = true })
      end
    end
  end
end, { timeout = 300, type = "oneshot" })
hl.permission({ binary = "/usr/(bin|local/bin)/hyprctl", type = "plugin", mode = "allow" })
hl.permission({ binary = "/usr/bin/grim", type = "screencopy", mode = "allow" })

-- Nothing started from here may change the live session: no profiles
-- (audio output), no theme switches, no notifications.
if not rawget(_G, "__strata_exec_guard") then
  local exec = hl.dsp.exec_cmd
  _G.__strata_exec_guard = true
  hl.dsp.exec_cmd = function(cmd, ...)
    if type(cmd) == "string" and (cmd:find("strata%-profile") or cmd:find("strata%-theme") or cmd:find("omarchy%-")) then
      return exec("true")
    end
    return exec(cmd, ...)
  end
end

local strata = assert(loadfile(os.getenv("STRATA_ROOT") .. "/lua/strata.lua"))(os.getenv("STRATA_ROOT"))
strata.theme_to = function() end

hl.config({
  general = {
    gaps_in = 5, gaps_out = 20, border_size = 2,
    col = { active_border = "rgba(8aadf4ff)", inactive_border = "rgba(595959aa)" },
    layout = "scrolling",
  },
  scrolling = { column_width = 0.5, fullscreen_on_one_column = true, focus_fit_method = 1 },
  decoration = { rounding = 4, shadow = { enabled = false }, blur = { enabled = false } },
  animations = { enabled = true },
  input = { follow_mouse = 1 },
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true, background_color = 0xff000000 },
})
hl.curve("hf_snap", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.2, bezier = "hf_snap" })
hl.workspace_rule({ workspace = "name:games", persistent = true })
-- A stratum with a wide left gap (a sidebar), whose columns sit off the grid.
hl.workspace_rule({ workspace = "name:agents", gaps_out = { top = 20, right = 20, bottom = 20, left = 250 } })

_G.__strata_test = strata
package.loaded["hypr.strata"] = strata
strata.setup()
