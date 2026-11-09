.pragma library

// Theme palette roles for Strata's colours (stratum accents, names in the
// overview). Same rules as Icon Colors, so a stratum tinted "blue" matches
// every other blue icon on the bar:
//   - a role is a colors.toml key (blue, bright_red, accent, foreground...),
//     an ANSI fallback (color4...), or a literal "#rrggbb";
//   - monochrome themes give grays for every role; those get the role's usual
//     hue at a soft strength instead, raised to a share of the text contrast;
//   - every colour is raised to a minimum contrast with the background.

var roleHues = { red: 0.0, orange: 0.075, yellow: 0.13, green: 0.36, cyan: 0.5, blue: 0.6, magenta: 0.8 }
var grayChroma = 0.08
var minContrast = 3
var standInShare = 0.6

function parse(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

function mix(a, b, t) {
  return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
}

function luminance(c) {
  function channel(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

function contrast(a, b) {
  var la = luminance(a), lb = luminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function isGray(c) {
  return Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b) < grayChroma
}

// Walk a colour's lightness away from the background until it reads.
function legible(c, need, text, back) {
  var lighten = luminance(text) > luminance(back)
  var hue = Math.max(0, c.hslHue), sat = c.hslSaturation, light = c.hslLightness
  var out = Qt.rgba(c.r, c.g, c.b, 1)
  for (var i = 0; i < 50 && contrast(out, back) < need; i++) {
    light = lighten ? Math.min(1, light + 0.02) : Math.max(0, light - 0.02)
    out = Qt.hsla(hue, sat, light, 1)
  }
  return out
}

function raw(palette, role) {
  if (role === "accent") return palette.accent ? Qt.color(palette.accent) : null
  if (role === "foreground") return palette.foreground ? Qt.color(palette.foreground) : null
  var ansi = { red: "color1", green: "color2", yellow: "color3", blue: "color4", magenta: "color5", cyan: "color6",
               bright_red: "color9", bright_green: "color10", bright_yellow: "color11", bright_blue: "color12",
               bright_magenta: "color13", bright_cyan: "color14" }
  var hex = palette[role] || palette[ansi[role]]
  if (hex) return Qt.color(hex)
  if (role === "orange") {
    var red = palette.red || palette.color1, yellow = palette.yellow || palette.color3
    if (red && yellow) return mix(Qt.color(red), Qt.color(yellow), 0.5)
  }
  return null
}

// The finished colour for a role on a surface with this text/background.
function role(palette, name, text, back) {
  if (/^#[0-9A-Fa-f]{6}$/.test(String(name))) return Qt.color(name)
  var c = raw(palette, name)
  if (!c) return text
  var base = String(name).replace(/^bright_/, "")
  if (isGray(c)) {
    if (name === "accent" || name === "foreground" || !(base in roleHues)) return text
    var dark = luminance(text) > luminance(back)
    var need = Math.min(7, contrast(text, back) * standInShare)
    return legible(Qt.hsla(roleHues[base], 0.32, dark ? 0.6 : 0.4, 1), need, text, back)
  }
  return legible(c, minContrast, text, back)
}
