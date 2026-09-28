.pragma library

// Pure helpers for the ExpressVPN bar widget: glyphs, state classification,
// region-slug pretty printing and status parsing. No QML types in here.

// Material Design Icons code points, as patched into the Nerd Font the bar uses.
var ICON = {
  connected: 0xF0565,     // shield-check
  transition: 0xF11A3,    // shield-sync-outline
  disconnected: 0xF099C,  // shield-off-outline
  interrupted: 0xF0ECC,   // shield-alert
  serviceDown: 0xF0ADD,   // shield-remove-outline
  login: 0xF0BC5,         // shield-key-outline
  unknown: 0xF0499,       // shield-outline
  star: 0xF04CE,
  starOutline: 0xF04D2,
  search: 0xF0349,
  refresh: 0xF0450,
  logout: 0xF0343,
  key: 0xF0306,
  smart: 0xF140B,         // lightning-bolt
  marker: 0xF034E,        // map-marker
  check: 0xF012C,
  close: 0xF0156
}

function glyph(name) {
  return String.fromCodePoint(ICON[name] || ICON.unknown)
}

var STATES = ["Disconnected", "Connecting", "Connected", "Interrupted", "Reconnecting",
              "DisconnectingToReconnect", "Disconnecting"]

function normalizeState(s) {
  var v = String(s || "").trim().replace(/[^A-Za-z]+$/, "")
  for (var i = 0; i < STATES.length; i++) if (STATES[i].toLowerCase() === v.toLowerCase()) return STATES[i]
  return ""
}

// "kind" drives the icon and color: connected | transition | disconnected |
// interrupted | serviceDown | login | unknown.
function kindFor(state, serviceDown, needsLogin) {
  if (serviceDown) return "serviceDown"
  if (needsLogin) return "login"
  switch (state) {
  case "Connected": return "connected"
  case "Connecting":
  case "Reconnecting":
  case "DisconnectingToReconnect":
  case "Disconnecting": return "transition"
  case "Interrupted": return "interrupted"
  case "Disconnected": return "disconnected"
  }
  return "unknown"
}

function stateLabel(state, serviceDown, needsLogin) {
  if (serviceDown) return "Service not running"
  if (needsLogin) return "Not logged in"
  switch (state) {
  case "DisconnectingToReconnect": return "Reconnecting"
  case "": return "Checking…"
  }
  return state
}

// True while the tunnel is up or on its way up — the big button should offer
// Disconnect in these states.
function isEngaged(state) {
  return state === "Connected" || state === "Connecting" || state === "Reconnecting"
    || state === "DisconnectingToReconnect" || state === "Interrupted"
}

// ---------------------------------------------------------------- regions

// Countries whose slug spans more than one dash-separated word. Everything
// else is "<country>-<city...>-<n>".
var MULTI_WORD_COUNTRIES = [
  "united-arab-emirates", "trinidad-and-tobago", "bosnia-and-herzegovina",
  "dominican-republic", "czech-republic", "cayman-islands", "puerto-rico",
  "costa-rica", "isle-of-man", "hong-kong", "north-macedonia", "south-korea",
  "new-zealand", "saudi-arabia", "sri-lanka", "south-africa"
]

var UPPER = { usa: "USA", uk: "UK", dc: "DC", uae: "UAE" }
var LOWER = { and: true, of: true, the: true, via: true }

function titleWord(w, first) {
  if (w === "") return w
  var open = ""
  var close = ""
  if (w.charAt(0) === "(") { open = "("; w = w.substring(1) }
  if (w.charAt(w.length - 1) === ")") { close = ")"; w = w.substring(0, w.length - 1) }
  var lw = w.toLowerCase()
  var out
  if (UPPER[lw]) out = UPPER[lw]
  else if (!first && LOWER[lw]) out = lw
  else out = lw.charAt(0).toUpperCase() + lw.substring(1)
  return open + out + close
}

function titleWords(words) {
  var out = []
  for (var i = 0; i < words.length; i++) out.push(titleWord(words[i], i === 0))
  return out.join(" ")
}

// "usa-los-angeles-2" -> "USA - Los Angeles - 2"; "india-(via-uk)" ->
// "India (via UK)"; "smart" -> "Smart location".
function prettyRegion(slug) {
  var s = String(slug || "").trim().toLowerCase()
  if (s === "") return ""
  if (s === "smart") return "Smart location"
  var country = ""
  var rest = s
  for (var i = 0; i < MULTI_WORD_COUNTRIES.length; i++) {
    var c = MULTI_WORD_COUNTRIES[i]
    if (s === c || s.indexOf(c + "-") === 0) { country = c; rest = s.substring(c.length + 1); break }
  }
  if (country === "") {
    var dash = s.indexOf("-")
    country = dash < 0 ? s : s.substring(0, dash)
    rest = dash < 0 ? "" : s.substring(dash + 1)
  }
  var parts = [titleWords(country.split("-"))]
  if (rest !== "") {
    // Parenthesized qualifiers stay attached: "India (via UK)".
    if (rest.charAt(0) === "(") {
      var q = rest.split("-")
      for (var k = 0; k < q.length; k++) q[k] = titleWord(q[k], false)
      return parts[0] + " " + q.join(" ")
    }
    var words = rest.split("-")
    var num = ""
    if (words.length > 0 && /^\d+$/.test(words[words.length - 1])) num = words.pop()
    if (words.length > 0) parts.push(titleWords(words))
    if (num !== "") parts.push(num)
  }
  return parts.join(" - ")
}

function parseRegions(text) {
  var lines = String(text || "").split("\n")
  var out = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var slug = lines[i].trim()
    if (slug === "" || slug === "smart" || seen[slug]) continue
    if (!/^[a-z0-9.()_-]+$/i.test(slug)) continue
    seen[slug] = true
    out.push({ slug: slug, name: prettyRegion(slug) })
  }
  out.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return out
}

function matches(region, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return true
  var hay = (region.name + " " + region.slug).toLowerCase().replace(/-/g, " ")
  var terms = q.split(/\s+/)
  for (var i = 0; i < terms.length; i++) if (hay.indexOf(terms[i]) === -1) return false
  return true
}

// ---------------------------------------------------------------- status

function looksNotLoggedIn(text) {
  return /not\s*logged\s*in/i.test(String(text || ""))
}

function looksServiceDown(text) {
  return /timed out|cannot connect|localsocket|daemon (is )?(not|in)active/i.test(String(text || ""))
}

// `expressvpnctl status` prints the connection state on its first line (or
// "Not logged in."), then "Key: value" lines such as Location, Network Lock
// and Split Tunnel.
function parseStatus(text) {
  var out = { state: "", notLoggedIn: false, location: "", networkLock: "", splitTunnel: "" }
  var raw = String(text || "")
  out.notLoggedIn = looksNotLoggedIn(raw)
  var lines = raw.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var kv = line.match(/^([A-Za-z ]+):\s*(.*)$/)
    if (kv) {
      var key = kv[1].trim().toLowerCase()
      if (key === "location") out.location = kv[2].trim()
      else if (key === "network lock") out.networkLock = kv[2].trim()
      else if (key === "split tunnel") out.splitTunnel = kv[2].trim()
      continue
    }
    if (out.state === "") {
      var st = normalizeState(line.split(/\s+/)[0])
      if (st !== "") out.state = st
    }
  }
  return out
}

function cleanIp(v) {
  var s = String(v || "").trim()
  if (s === "" || /^unknown$/i.test(s)) return ""
  return /^[0-9a-f.:]+$/i.test(s) ? s : ""
}

function tooltip(state, serviceDown, needsLogin, region, vpnIp, pubIp) {
  var lines = ["ExpressVPN: " + stateLabel(state, serviceDown, needsLogin)]
  if (!serviceDown && !needsLogin) {
    if (region) lines.push(prettyRegion(region))
    if (state === "Connected" && vpnIp) lines.push("VPN IP " + vpnIp)
    else if (pubIp) lines.push("Public IP " + pubIp)
  }
  return lines.join("\n")
}

function oneLine(text, max) {
  var v = String(text || "").replace(/\s+/g, " ").trim()
  var m = max || 160
  return v.length > m ? v.substring(0, m - 1) + "…" : v
}
