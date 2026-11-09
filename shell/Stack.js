.pragma library

// The stack of strata, top to bottom, the same way lua/strata.lua builds it:
// themed strata are named workspaces, free strata the numbered ones.

// Defaults under user: objects merge, arrays and values are replaced.
function merge(defaults, user) {
  if (user === undefined) return defaults
  if (!defaults || typeof defaults !== "object" || Array.isArray(defaults)
      || !user || typeof user !== "object" || Array.isArray(user)) return user
  var out = {}
  for (var k in defaults) out[k] = defaults[k]
  for (var u in user) out[u] = merge(defaults[u], user[u])
  return out
}

// Numbered boxes for free strata: outline when not on it, filled when on it.
var numberOutline = ["󰎣", "󰎦", "󰎩", "󰎬", "󰎮", "󰎰", "󰎵", "󰎸", "󰎻", "󰎾"]
var numberFilled = ["󰎡", "󰎤", "󰎧", "󰎪", "󰎭", "󰎱", "󰎳", "󰎶", "󰎹", "󰎼"]

function freeIds(cfg, workspaces, focusedId) {
  var free = cfg.free || {}
  var ids = []
  if (free.dynamic === false) {
    for (var i = 1; i <= (free.count || 5); i++) ids.push(i)
    return ids
  }
  var taken = {}
  for (var j = 0; j < workspaces.length; j++) {
    var ws = workspaces[j]
    if (ws.id > 0 && !ws.special && ws.windows > 0) { ids.push(ws.id); taken[ws.id] = true }
  }
  ids.sort(function(a, b) { return a - b })
  // The one waiting empty stratum: the one you're on if it's an empty free
  // one, else the lowest free number. It always sits at the bottom.
  var waiting = 1
  if (focusedId > 0 && !taken[focusedId]) waiting = focusedId
  else while (taken[waiting]) waiting++
  ids.push(waiting)
  return ids
}

// workspaces: [{ id, name, windows }]
function entries(cfg, workspaces, focusedId) {
  var out = []
  var stack = cfg.stack || []
  for (var i = 0; i < stack.length; i++) {
    var id = stack[i]
    if (id === "@free") {
      var free = cfg.free || {}
      var ids = freeIds(cfg, workspaces, focusedId)
      for (var k = 0; k < ids.length; k++) {
        var n = ids[k]
        out.push({
          id: "free:" + n, kind: "free", key: "@free", wsId: n, wsName: String(n),
          selector: String(n),
          name: (free.name || "Free") + " " + n,
          icon: n <= 9 ? numberOutline[n] : "󰏁",
          iconActive: n <= 9 ? numberFilled[n] : "󰎿",
          accent: free.accent || "accent",
          stratum: free
        })
      }
    } else if (cfg.strata && cfg.strata[id]) {
      var st = cfg.strata[id]
      var sel = String(st.workspace || ("name:" + id))
      out.push({
        id: id, kind: "themed", key: id, wsId: null,
        wsName: sel.indexOf("name:") === 0 ? sel.slice(5) : sel,
        selector: sel,
        name: st.name || id,
        icon: st.icon || "󱓼",
        iconActive: st.iconActive || st.icon || "󱓻",
        accent: st.accent || "accent",
        stratum: st
      })
    }
  }
  return out
}

// Index of a Hyprland workspace (id, name) in the stack, or -1.
function indexOf(list, wsId, wsName) {
  for (var i = 0; i < list.length; i++) {
    var e = list[i]
    if (e.kind === "free" ? e.wsId === wsId : e.wsName === wsName) return i
  }
  return -1
}
