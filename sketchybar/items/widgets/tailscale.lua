local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- Beide Binaries werden absolut adressiert: sketchybar startet unter launchd,
-- dessen PATH kennt weder /usr/local/bin noch /opt/homebrew/bin. Ohne das
-- liefert der Aufruf still nichts und das Widget saehe nur "aus" aus.
local TAILSCALE = "/usr/local/bin/tailscale"
local JQ = "/opt/homebrew/bin/jq"

local UPDATE_FREQ = 15
local POPUP_WIDTH = 250

-- Feste Anzahl Popup-Zeilen fuer die Exit-Node-Kandidaten. Items zur Laufzeit
-- anzulegen und wieder wegzuraeumen ist in SbarLua fragil, drawing umschalten
-- nicht. Gibt es mehr Kandidaten als Slots, werden die ersten gezeigt.
local MAX_EXIT_NODES = 8

-- Eine Abfrage pro Update: Zeile "S" traegt den Gesamtzustand, jede Zeile "E"
-- einen Peer, der sich als Exit-Node anbietet. Alle Peer-Zugriffe gehen ueber
-- (.Peer // {}), weil das Feld fehlt, sobald Tailscale gestoppt ist — sonst
-- bricht jq ab und der Fehlerfall waere von "keine Daten" nicht zu trennen.
-- Die CLI wird nur aufgerufen, wenn die Tailscale Network Extension laeuft.
-- Ohne laufende Extension versucht die CLI, die VPN-Konfiguration zu
-- "reparieren" (Removing/Saving configuration); auf einem kaputten nehelper
-- hat das im September 2026 hunderte doppelte VPN-Profile erzeugt und
-- nehelper auf 100 % CPU gehalten. Laeuft sie nicht, gibt es keine Ausgabe,
-- das Widget zeigt dann "Getrennt".
-- Das "[n]" verhindert, dass pgrep die eigene sh-Kommandozeile trifft.
local EXT_GUARD = "pgrep -qf 'io.tailscale.ipn.macsys.network-extensio[n]' && "

local STATUS_CMD = EXT_GUARD .. TAILSCALE .. " status --json 2>/dev/null | " .. JQ .. [==[ -r '
def peers: [(.Peer // {}) | .[]];
def ip: (.TailscaleIPs // [])[0] // "";
(["S", (.BackendState // "?"), (.Self | ip), (.CurrentTailnet.Name // ""),
  (peers | map(select(.Online)) | length | tostring), (peers | length | tostring),
  ((peers | map(select(.ExitNode)) | .[0].HostName) // "")] | @tsv),
(peers | map(select(.ExitNodeOption))
  | sort_by([(if .Online then 0 else 1 end), (.HostName | ascii_downcase)])
  | .[] | ["E", ip, (.HostName // "?"),
           (if .Online then "1" else "0" end),
           (if .ExitNode then "1" else "0" end)] | @tsv)
' 2>/dev/null]==]

local STATE_LABELS = {
  Running          = "Verbunden",
  Starting         = "Startet",
  Stopped          = "Getrennt",
  NoState          = "Getrennt",
  NeedsLogin       = "Login nötig",
  NeedsMachineAuth = "Freigabe nötig",
}

local state = { running = false, exit_nodes = {} }

local function fields(line)
  local out = {}
  for f in (line .. "\t"):gmatch("([^\t]*)\t") do out[#out + 1] = f end
  return out
end

local tailscale = sbar.add("item", "widgets.tailscale", {
  display = settings.primary_display,
  position = "right",
  update_freq = UPDATE_FREQ,
  icon = {
    string = icons.tailscale.disconnected,
    color = colors.grey,
    font = { style = settings.font.style_map["Regular"], size = 14.0 },
  },
  label = {
    string = "—",
    color = colors.grey,
    font = { family = settings.font.numbers, style = settings.font.style_map["Bold"], size = 12.0 },
  },
})

local bracket = sbar.add("bracket", "widgets.tailscale.bracket", { tailscale.name }, {
  display = settings.primary_display,
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 },
})

sbar.add("item", {
  display = settings.primary_display, position = "right", width = settings.group_paddings })

-- Popup-Zeilen entstehen in Anzeigereihenfolge: sketchybar zeichnet sie so,
-- wie sie hinzugefuegt wurden.
local tailnet = sbar.add("item", "widgets.tailscale.tailnet", {
  position = "popup." .. bracket.name,
  width = POPUP_WIDTH,
  align = "center",
  icon = { string = icons.tailscale.connected, font = { style = settings.font.style_map["Bold"] } },
  label = {
    string = "————",
    max_chars = 24,
    font = { size = 15, style = settings.font.style_map["Bold"] },
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

local function add_row(key, title)
  return sbar.add("item", "widgets.tailscale." .. key, {
    position = "popup." .. bracket.name,
    icon = { align = "left", string = title, width = POPUP_WIDTH / 2 },
    label = { align = "right", string = "—", width = POPUP_WIDTH / 2, max_chars = 20 },
  })
end

local status_row = add_row("status", "Status:")
local ip_row = add_row("ip", "IP:")
local peers_row = add_row("peers", "Peers:")
local power_row = add_row("power", "Verbindung:")

local exit_header = sbar.add("item", "widgets.tailscale.exit_header", {
  position = "popup." .. bracket.name,
  width = POPUP_WIDTH,
  align = "center",
  icon = { drawing = false },
  label = { string = "Exit-Node", align = "center", font = { style = settings.font.style_map["Bold"] } },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

local exit_off = sbar.add("item", "widgets.tailscale.exit_off", {
  position = "popup." .. bracket.name,
  icon = { align = "left", string = "Keiner", width = POPUP_WIDTH / 2 },
  label = { align = "right", string = icons.switch.off, width = POPUP_WIDTH / 2 },
})

local exit_slots = {}
for i = 1, MAX_EXIT_NODES do
  exit_slots[i] = sbar.add("item", "widgets.tailscale.exit_" .. i, {
    position = "popup." .. bracket.name,
    drawing = false,
    icon = { align = "left", string = "", width = POPUP_WIDTH / 2, max_chars = 18 },
    label = { align = "right", string = icons.switch.off, width = POPUP_WIDTH / 2 },
  })
end

local function apply(s, nodes)
  state.exit_nodes = nodes
  local backend    = s and s[2] or ""
  local self_ip    = s and s[3] or ""
  local tailnet_id = s and s[4] or ""
  local online     = s and s[5] or "0"
  local total      = s and s[6] or "0"
  local exit_name  = s and s[7] or ""

  state.running = (backend == "Running" or backend == "Starting")

  local icon_str, color, label_str, numeric
  if backend == "" or backend == "?" then
    -- Kein Output: CLI fehlt oder der Daemon antwortet nicht. Still ausgrauen,
    -- kein Fehlertext in der Bar.
    icon_str, color, label_str = icons.tailscale.disconnected, colors.grey, "—"
  elseif backend == "NeedsLogin" or backend == "NeedsMachineAuth" then
    icon_str, color, label_str = icons.tailscale.disconnected, colors.red, "Login"
  elseif not state.running then
    icon_str, color, label_str = icons.tailscale.disconnected, colors.grey, "aus"
  elseif exit_name ~= "" then
    icon_str, color, label_str = icons.tailscale.exit_node, colors.orange, exit_name
  else
    icon_str, color, label_str, numeric = icons.tailscale.connected, colors.white, online, true
  end

  tailscale:set({
    icon = { string = icon_str, color = color },
    label = {
      string = label_str,
      color = color,
      font = { family = numeric and settings.font.numbers or settings.font.text },
    },
  })

  tailnet:set({
    icon = { string = icon_str, color = color },
    label = tailnet_id ~= "" and tailnet_id or "Tailscale",
  })
  local known = (backend ~= "" and backend ~= "?")
  status_row:set({ label = { string = STATE_LABELS[backend] or (known and backend) or "unbekannt", color = color } })
  ip_row:set({ label = self_ip ~= "" and self_ip or "—" })
  peers_row:set({ label = known and (online .. " / " .. total .. " online") or "—" })
  power_row:set({
    label = {
      string = state.running and icons.switch.on or icons.switch.off,
      color = state.running and colors.green or colors.grey,
    },
  })

  -- Exit-Node-Auswahl ergibt nur Sinn, solange die Verbindung steht.
  exit_header:set({ drawing = state.running })
  exit_off:set({
    drawing = state.running,
    label = {
      string = exit_name == "" and icons.switch.on or icons.switch.off,
      color = exit_name == "" and colors.green or colors.grey,
    },
  })
  for i = 1, MAX_EXIT_NODES do
    local n = nodes[i]
    if n and state.running then
      exit_slots[i]:set({
        drawing = true,
        icon = { string = n.name, color = n.online and colors.white or colors.grey },
        label = {
          string = n.active and icons.switch.on or icons.switch.off,
          color = n.active and colors.green or colors.grey,
        },
      })
    else
      exit_slots[i]:set({ drawing = false })
    end
  end
end

local function update()
  sbar.exec(STATUS_CMD, function(out)
    local s, nodes = nil, {}
    for line in (out or ""):gmatch("[^\n]+") do
      local f = fields(line)
      if f[1] == "S" then
        s = f
      elseif f[1] == "E" and #nodes < MAX_EXIT_NODES then
        nodes[#nodes + 1] = { ip = f[2], name = f[3], online = f[4] == "1", active = f[5] == "1" }
      end
    end
    apply(s, nodes)
  end)
end

-- up/down/set kehren zurueck, bevor der Backend-Zustand steht. Einmal sofort
-- zeichnen, einmal nach einer Sekunde nachziehen — sonst wirkt ein Klick bis
-- zum naechsten Intervall wie wirkungslos.
local function refresh_soon()
  update()
  sbar.delay(1, update)
end

power_row:subscribe("mouse.clicked", function()
  local cmd = state.running and (TAILSCALE .. " down")
                            or (TAILSCALE .. " up --timeout=15s")
  sbar.exec(cmd .. " >/dev/null 2>&1", refresh_soon)
end)

local function set_exit_node(addr)
  -- Nur das, was aus dem Status-JSON kommt, geht an die Shell weiter.
  if addr ~= "" and not addr:match("^[%x%.:]+$") then return end
  sbar.exec(TAILSCALE .. " set --exit-node=" .. addr .. " >/dev/null 2>&1", refresh_soon)
end

exit_off:subscribe("mouse.clicked", function() set_exit_node("") end)
for i = 1, MAX_EXIT_NODES do
  exit_slots[i]:subscribe("mouse.clicked", function()
    -- Offline-Kandidaten sind grau und bleiben es auch beim Klick: wer den
    -- Traffic ueber einen Knoten leitet, der seit Tagen weg ist, ist ohne
    -- erkennbaren Grund offline.
    local n = state.exit_nodes[i]
    if n and n.online then set_exit_node(n.ip) end
  end)
end

local function hide_details()
  bracket:set({ popup = { drawing = false } })
end

local function toggle_details()
  if bracket:query().popup.drawing == "off" then
    update()
    bracket:set({ popup = { drawing = true } })
  else
    hide_details()
  end
end

tailscale:subscribe("mouse.clicked", toggle_details)
tailscale:subscribe("mouse.exited.global", hide_details)
tailscale:subscribe({ "routine", "forced", "wifi_change", "system_woke" }, update)

local function copy_label_to_clipboard(env)
  local label = sbar.query(env.NAME).label.value
  sbar.exec("echo \"" .. label .. "\" | pbcopy")
  sbar.set(env.NAME, { label = { string = icons.clipboard, align = "center" } })
  sbar.delay(1, function()
    sbar.set(env.NAME, { label = { string = label, align = "right" } })
  end)
end

tailnet:subscribe("mouse.clicked", copy_label_to_clipboard)
ip_row:subscribe("mouse.clicked", copy_label_to_clipboard)

update()
