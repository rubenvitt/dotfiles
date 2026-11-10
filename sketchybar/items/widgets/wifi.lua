local icons = require("icons")
local svg = require("helpers.svg_icon")
local colors = require("colors")
local settings = require("settings")
local popup = require("helpers.popup")

-- Execute the event provider binary which provides the event "network_update"
-- for the network interface "en0", which is fired every 2.0 seconds.
sbar.exec("killall network_load >/dev/null; $CONFIG_DIR/helpers/event_providers/network_load/bin/network_load en0 network_update 2.0")
-- Das Event selbst anlegen, bevor ein Item es abonniert: der Helfer meldet es
-- erst nach seinem Start an, und unter mbar geht die ganze Config vorher in
-- einem Rutsch raus ("Event not found", das Abo fehlt dann still).
sbar.add("event", "network_update")


local wifi_up = sbar.add("item", "widgets.wifi1", {
  display = settings.primary_display,
  position = "right",
  padding_left = -5,
  width = 0,
  icon = svg.icon("wifi.upload", colors.white, {
    padding_right = 0,
    font = {
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
  }),
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.red,
    string = "??? Bps",
  },
  y_offset = 4,
})

local wifi_down = sbar.add("item", "widgets.wifi2", {
  display = settings.primary_display,
  position = "right",
  padding_left = -5,
  icon = svg.icon("wifi.download", colors.white, {
    padding_right = 0,
    font = {
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
  }),
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.blue,
    string = "??? Bps",
  },
  y_offset = -4,
})

-- Kompakt-Modus: nur das Wifi-Icon, die Raten bleiben dem Popup vorbehalten.
if settings.compact then
  wifi_up:set({ drawing = false })
  wifi_down:set({ drawing = false })
end

local wifi = sbar.add("item", "widgets.wifi.padding", {
  display = settings.primary_display,
  position = "right",
  label = { drawing = false },
})

-- Background around the item
local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
  wifi_up.name,
  wifi_down.name
}, {
  display = settings.primary_display,
  background = { color = colors.bg1 },
  popup = popup.host("center"),
})

-- Popup wie das WLAN-Menü von macOS (helpers/popup.lua).
local P = wifi_bracket.name
local CAPTION = 134
local VALUE = popup.WIDTH - 2 * popup.INSET - CAPTION

local function info_row(name, caption, opts)
  local o = { caption_width = CAPTION, drawing = true }
  for k, v in pairs(opts or {}) do o[k] = v end
  local row = popup.row(P, "widgets.wifi." .. name, o)
  row:set({ icon = { string = caption }, label = { string = "…" } })
  return row
end

local function switch(on)
  local name = on and "switch.on" or "switch.off"
  return svg.align_right(svg.icon(name, on and colors.green or colors.grey, {
    width = VALUE + popup.INSET,
    align = "right",
  }), name, VALUE + popup.INSET, popup.INSET)
end

popup.gap(P, "widgets.wifi.gap.top", 6, { drawing = true })
local power = popup.header(P, "widgets.wifi.power", { drawing = true, caption_width = CAPTION })
power:set({ icon = { string = "WLAN" }, label = switch(false) })
popup.rule(P, "widgets.wifi.rule.network", { drawing = true })
local ssid = info_row("ssid", "Netzwerk", { caption_color = colors.white })
ssid:set({ label = { string = "????????????", max_chars = 24 } })
popup.rule(P, "widgets.wifi.rule.details", { drawing = true })
local hostname = info_row("hostname", "Hostname")
hostname:set({ label = { max_chars = 20 } })
local ip = info_row("ip", "IP-Adresse")
local mask = info_row("mask", "Subnetzmaske")
local router = info_row("router", "Router")
popup.rule(P, "widgets.wifi.rule.settings", { drawing = true })
popup.action(P, "widgets.wifi.settings", "WLAN-Einstellungen …",
  "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'; " ..
  "sketchybar --set " .. P .. " popup.drawing=off")
popup.gap(P, "widgets.wifi.gap.bottom", 6, { drawing = true })

sbar.add("item", {
  display = settings.primary_display, position = "right", width = settings.group_paddings })

wifi_up:subscribe("network_update", function(env)
  local up_color = (env.upload == "000 Bps") and colors.grey or colors.red
  local down_color = (env.download == "000 Bps") and colors.grey or colors.blue
  wifi_up:set({
    icon = { color = up_color },
    label = {
      string = env.upload,
      color = up_color
    }
  })
  wifi_down:set({
    icon = { color = down_color },
    label = {
      string = env.download,
      color = down_color
    }
  })
end)

-- macOS 14+ liefert die SSID nur noch an Prozesse mit Standort-Freigabe;
-- ipconfig/networksetup/scutil geben sonst "<redacted>" zurueck. system_profiler
-- kennt den Namen weiterhin, braucht dafuer aber mehrere Sekunden. Deshalb wird
-- die SSID im Hintergrund bei Netzwerkwechseln geholt und im Popup gecached.
local SSID_CMD = "system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{getline; gsub(/^ *| *$/, \"\"); sub(/:$/, \"\"); print; exit}'"

local function update_ssid()
  sbar.exec("ipconfig getifaddr en0", function(addr)
    if addr:gsub("%s+", "") == "" then
      ssid:set({ label = "Not connected" })
      return
    end
    sbar.exec(SSID_CMD, function(name)
      name = name:gsub("%s+$", "")
      ssid:set({ label = (name == "" or name == "<redacted>") and "Wi-Fi" or name })
    end)
  end)
end

local wifi_on = false

local function update_power()
  sbar.exec("networksetup -getairportpower en0", function(result)
    wifi_on = result:match(": On") ~= nil
    power:set({ label = switch(wifi_on) })
  end)
end

-- setairportpower kehrt zurück, bevor das Interface umgeschaltet ist; der
-- Rest (Bar-Icon, SSID) zieht über wifi_change nach.
power:subscribe("mouse.clicked", function()
  local target = wifi_on and "off" or "on"
  sbar.exec("networksetup -setairportpower en0 " .. target, function()
    update_power()
    sbar.delay(1, update_power)
  end)
end)

wifi:subscribe({"wifi_change", "system_woke"}, function(env)
  update_power()
  sbar.exec("ipconfig getifaddr en0", function(ip)
    local connected = not (ip == "")
    wifi:set({
      icon = svg.icon(connected and "wifi.connected" or "wifi.disconnected",
        connected and colors.white or colors.red),
    })
  end)
  update_ssid()
end)

update_ssid()

local function hide_details()
  wifi_bracket:set({ popup = { drawing = false } })
end

local function toggle_details()
  local should_draw = wifi_bracket:query().popup.drawing == "off"
  if should_draw then
    wifi_bracket:set({ popup = { drawing = true }})
    update_power()
    sbar.exec("networksetup -getcomputername", function(result)
      hostname:set({ label = result })
    end)
    sbar.exec("ipconfig getifaddr en0", function(result)
      ip:set({ label = result })
    end)
    -- SSID nur nachladen, wenn noch nie ermittelt: der Scan dauert Sekunden
    if ssid:query().label.value == "????????????" then update_ssid() end
    sbar.exec("networksetup -getinfo Wi-Fi | awk -F 'Subnet mask: ' '/^Subnet mask: / {print $2}'", function(result)
      mask:set({ label = result })
    end)
    sbar.exec("networksetup -getinfo Wi-Fi | awk -F 'Router: ' '/^Router: / {print $2}'", function(result)
      router:set({ label = result })
    end)
  else
    hide_details()
  end
end

wifi_up:subscribe("mouse.clicked", toggle_details)
wifi_down:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.exited.global", hide_details)

local function copy_label_to_clipboard(env)
  local label = sbar.query(env.NAME).label.value
  sbar.exec("echo \"" .. label .. "\" | pbcopy")
  sbar.set(env.NAME, { label = { string = icons.clipboard, align="center" } })
  sbar.delay(1, function()
    sbar.set(env.NAME, { label = { string = label, align = "right" } })
  end)
end

ssid:subscribe("mouse.clicked", copy_label_to_clipboard)
hostname:subscribe("mouse.clicked", copy_label_to_clipboard)
ip:subscribe("mouse.clicked", copy_label_to_clipboard)
mask:subscribe("mouse.clicked", copy_label_to_clipboard)
router:subscribe("mouse.clicked", copy_label_to_clipboard)
