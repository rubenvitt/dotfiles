local colors = require("colors")
local settings = require("settings")
local icons = require("icons")

-- Privacy-Insel. Bei ausgeblendeter Menüleiste zeichnet macOS seinen
-- Privacy-Punkt (Mikrofon, Kamera, Bildschirm, Systemaudio) über die Bar.
-- bar.lua rückt die rechten Items per privacy_indicator_inset links neben den
-- Punkt; diese Datei legt eine Kapsel um ihn, die zeigt, wer ihn auslöst:
-- Sensor-Symbole in Apples Farben plus App-Icons. Neue Apps klappen kurz ihren
-- Namen aus, Hover zeigt alle Namen, Klick listet jede App mit ihrem Sensor.
--
-- Muss vor items.calendar geladen werden: rechte Items liegen in
-- Ladereihenfolge von rechts nach links, die Kapsel gehört direkt an den Punkt.

-- Dauerquellen halten den Punkt ständig an, ohne dass jemand aufnimmt
-- (SoundSource greift über seinen ARK-Daemon das Systemaudio ab). In der Bar
-- bleiben sie still, im Popup stehen sie mit „dauerhaft“.
local QUIET = {
  ["com.rogueamoeba.arkaudiod"] = true,
}

-- Bundle-IDs ohne eigenes .app-Bundle: Anzeigename und Icon-Quelle.
local KNOWN = {
  ["com.rogueamoeba.arkaudiod"] = { name = "SoundSource", icon = "com.rogueamoeba.soundsource" },
}

-- Reihenfolge der Symbole in der Bar und Vorrang für die Kapselfarbe. Die
-- Farben folgen Apples Punkt, angepasst an colors.lua.
local KINDS = {
  { key = "camera",   title = "Kamera",      color = colors.green,
    pane = "Privacy_Camera" },
  { key = "mic",      title = "Mikrofon",    color = colors.orange,
    pane = "Privacy_Microphone" },
  { key = "screen",   title = "Bildschirm",  color = colors.magenta,
    pane = "Privacy_ScreenCapture" },
  { key = "audio",    title = "Systemaudio", color = colors.magenta,
    pane = "Privacy_ScreenCapture" },
  { key = "location", title = "Standort",    color = colors.blue,
    pane = "Privacy_LocationServices" },
}

local MAX_APPS = 3            -- App-Icons in der Bar
local POPUP_ROWS = 8
local POPUP_WIDTH = 300
local CAP = 26                -- Kapselhöhe; das rechte Ende ist ein Kreis um den Punkt
local BAR_PADDING_RIGHT = 2   -- padding_right aus bar.lua
local APP_WIDTH = 20
local NAME_SECONDS = 5        -- so lange bleibt der Name einer neuen App ausgeklappt

-- Der Inset setzt die rechte Kante der Items auf den linken Rand des Punkts.
-- Dieses unsichtbare Item ganz rechts schiebt den Cursor mit negativem
-- padding_right (in render gesetzt) wieder nach rechts, bis der Kreis danach
-- mittig um den Punkt liegt. Es gehört nicht zur Klammer: deren Länge rechnet
-- das padding_right ihres rechten Mitglieds mit ein.
local shift = sbar.add("item", "privacy.shift", {
  position = "right",
  drawing = false,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  -- Breite über ein leeres Label statt width=: Bei fester Breite rückt der
  -- Cursor immer um die volle Breite weiter, egal wie die Paddings stehen.
  label = { string = "", width = 0, padding_left = 0, padding_right = 0 },
})

-- Kreis um den Punkt, rechtes Ende der Insel.
local cap = sbar.add("item", "privacy", {
  position = "right",
  drawing = false,
  updates = true,   -- das Event muss auch das unsichtbare Item erreichen
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { string = "", width = CAP, padding_left = 0, padding_right = 0 },
  -- Ohne sichtbaren Inhalt hätte das Item kein Fenster und die Klammer
  -- keine Breite.
  background = { color = colors.transparent, height = CAP, border_width = 0 },
  popup = { align = "right", height = 28 },
})

local pill_items = { cap }

-- Je App ein Icon, auch wenn sie mehrere Sensoren nutzt. Rechts angeordnet,
-- also rückwärts anlegen: in der Bar stehen sie dann in Reihenfolge.
local apps = {}
for i = MAX_APPS, 1, -1 do
  apps[i] = sbar.add("item", "privacy.app" .. i, {
    position = "right",
    drawing = false,
    width = APP_WIDTH,
    padding_left = 0,
    padding_right = 0,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      color = colors.transparent,
      border_width = 0,
      image = { scale = 0.5, border_width = 0, corner_radius = 0 },   -- app.* liefert 32 pt
    },
  })
  pill_items[#pill_items + 1] = apps[i]
end

-- Namen links neben den Icons, nur ausgeklappt sichtbar.
local app_names = sbar.add("item", "privacy.names", {
  position = "right",
  drawing = false,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = {
    color = colors.white,
    padding_left = 2,
    padding_right = 4,
    -- Kompakt-Modus: Die rechte Seite muss vor der Notch bleiben. Mit drei
    -- Apps, drei Sensoren und 14 Zeichen endet sie gemessen gut 40 pt davor.
    max_chars = settings.compact and 14 or 32,
    font = { style = settings.font.style_map["Semibold"], size = 12.0 },
  },
})
pill_items[#pill_items + 1] = app_names

-- Ein Symbol je aktivem Sensor, links in der Insel, in KINDS-Reihenfolge.
local glyphs = {}
for i = #KINDS, 1, -1 do
  local kind = KINDS[i]
  glyphs[kind.key] = sbar.add("item", "privacy." .. kind.key, {
    position = "right",
    drawing = false,
    padding_left = 0,
    padding_right = 0,
    icon = {
      string = icons.privacy[kind.key],
      color = kind.color,
      padding_left = 3,
      padding_right = 3,
      font = { style = settings.font.style_map["Bold"], size = 13.0 },
    },
    label = { drawing = false },
  })
  pill_items[#pill_items + 1] = glyphs[kind.key]
end

-- Punkt sichtbar, aber keine Zuordnung (Log-Stream fehlt oder Apple hat das
-- Log-Format geändert).
local unknown = sbar.add("item", "privacy.unknown", {
  position = "right",
  drawing = false,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = icons.privacy.unknown,
    color = colors.grey,
    padding_left = 4,
    padding_right = 4,
    font = { style = settings.font.style_map["Bold"], size = 13.0 },
  },
  label = {
    drawing = false,
    string = "Unbekannt",
    color = colors.grey,
    padding_left = 0,
    padding_right = 6,
    font = { style = settings.font.style_map["Semibold"], size = 12.0 },
  },
})
pill_items[#pill_items + 1] = unknown

local lead = sbar.add("item", "privacy.lead", {
  position = "right",
  drawing = false,
  width = 4,
  background = { color = colors.transparent, height = CAP, border_width = 0 },
})
pill_items[#pill_items + 1] = lead

local member_names = {}
for i, item in ipairs(pill_items) do member_names[i] = item.name end

local pill = sbar.add("bracket", "privacy.pill", member_names, {
  drawing = false,
  background = {
    color = colors.bg1,
    height = CAP,
    corner_radius = CAP / 2,
    border_width = 1,
    border_color = colors.transparent,
  },
})

-- Popup: Kopfzeile, eine Zeile je App, Hinweis bei fehlender Zuordnung.
local popup_pos = "popup." .. cap.name

sbar.add("item", "privacy.popup.header", {
  position = popup_pos,
  width = POPUP_WIDTH,
  icon = {
    string = icons.privacy.unknown,
    font = { style = settings.font.style_map["Bold"], size = 14.0 },
  },
  label = {
    string = "Sensorzugriffe",
    font = { style = settings.font.style_map["Bold"], size = 14.0 },
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

local rows = {}
local row_kind = {}
for i = 1, POPUP_ROWS do
  rows[i] = sbar.add("item", "privacy.popup.row" .. i, {
    position = popup_pos,
    drawing = false,
    icon = {
      width = 130,
      align = "left",
      font = { style = settings.font.style_map["Semibold"], size = 13.0 },
    },
    label = {
      width = POPUP_WIDTH - 130,
      align = "right",
      max_chars = 26,
    },
  })
  -- Klick auf eine Zeile öffnet die passende Datenschutz-Einstellung.
  rows[i]:subscribe("mouse.clicked", function()
    local kind = row_kind[i]
    if not kind then return end
    sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?" .. kind.pane .. "'")
    cap:set({ popup = { drawing = false } })
  end)
end

local note = sbar.add("item", "privacy.popup.note", {
  position = popup_pos,
  drawing = false,
  width = POPUP_WIDTH,
  icon = { drawing = false },
  label = {
    color = colors.grey,
    max_chars = 40,
    font = { size = 12.0 },
  },
})

-- Bundle-ID → Anzeigename und Icon-Quelle. mdfind läuft asynchron über
-- sbar.exec (io.popen hängt nach dem ersten Fork, siehe system_info.lua).
local names = {}
local icon_source = {}   -- Bundle-ID → ID für app.*, false = kein Icon
local pending = {}

local function display_name(id)
  return names[id] or id:match("([^%.]+)$") or id
end

local state = nil         -- letztes INFO von privacy_indicator_change
local render              -- vorwärts deklariert (resolve rendert nach)

local function resolve(id)
  if names[id] or pending[id] then return end
  local known = KNOWN[id]
  if known then
    names[id], icon_source[id] = known.name, known.icon
    return
  end
  -- Die IDs stammen aus Control Centers Log; trotzdem nichts Unerwartetes in
  -- die Shell geben.
  if not id:match("^[%w%.%-_]+$") then
    names[id], icon_source[id] = id, false
    return
  end
  pending[id] = true
  sbar.exec("mdfind \"kMDItemCFBundleIdentifier == '" .. id .. "'\" | grep '\\.app$' | head -1",
    function(out)
      pending[id] = nil
      local path = type(out) == "string" and out:gsub("%s+$", "") or ""
      local app = path:match("([^/]+)%.app$")
      names[id] = app or id:match("([^%.]+)$") or id
      icon_source[id] = app and id or false
      render()
    end)
end

local function display_of(frame)
  local displays = sbar.query("displays")
  local cx, cy = frame.x + frame.w / 2, frame.y + frame.h / 2
  for _, d in ipairs(type(displays) == "table" and displays or {}) do
    local f = d.frame
    if cx >= f.x and cx < f.x + f.w and cy >= f.y and cy < f.y + f.h then
      return d["arrangement-id"]
    end
  end
  return 1
end

local hovering = false
local names_until = 0     -- bis dahin bleiben die Namen ausgeklappt (os.time)
local shown_image = {}    -- Item-Name → gesetztes app.*-Bild

local function set_app(item, source, display)
  if not source then
    item:set({ drawing = false })
    shown_image[item.name] = nil
    return
  end
  local image = "app." .. source
  if shown_image[item.name] == image then
    item:set({ drawing = true, display = display })
    return
  end
  local appearing = shown_image[item.name] == nil
  shown_image[item.name] = image
  item:set({
    drawing = true,
    display = display,
    width = appearing and 0 or APP_WIDTH,
    background = { image = { string = image } },
  })
  if appearing then
    sbar.animate("tanh", 12, function() item:set({ width = APP_WIDTH }) end)
  end
end

local function hide_all()
  shift:set({ drawing = false })
  for _, item in ipairs(pill_items) do item:set({ drawing = false }) end
  pill:set({ drawing = false })
  cap:set({ popup = { drawing = false } })
  for k in pairs(shown_image) do shown_image[k] = nil end
end

render = function()
  local info = state
  if not info or info.visible ~= "on" or type(info.frame) ~= "table" then
    hide_all()
    return
  end

  local frame = info.frame
  local display = display_of(frame)
  local attribution = info.attribution == "on"
  local show_names = hovering or os.time() < names_until
  local tint = nil
  local content = false

  shift:set({
    drawing = true,
    display = display,
    padding_right = -math.floor(frame.w / 2 + CAP / 2 + BAR_PADDING_RIGHT + 0.5),
  })
  cap:set({ drawing = true, display = display })

  local loud, quiet, seen = {}, {}, {}
  for _, kind in ipairs(KINDS) do
    local loud_kind, quiet_kind = false, false
    for _, id in ipairs(attribution and info[kind.key] or {}) do
      resolve(id)
      if QUIET[id] then quiet_kind = true else loud_kind = true end
      if not seen[id] then
        seen[id] = true
        table.insert(QUIET[id] and quiet or loud, id)
      end
    end
    if loud_kind and not tint then tint = kind.color end
    -- Dauerquellen zeigen sich nur beim Hovern, dann grau.
    local show = loud_kind or (hovering and quiet_kind)
    content = content or show
    glyphs[kind.key]:set({
      drawing = show,
      display = display,
      icon = { color = loud_kind and kind.color or colors.grey },
    })
  end

  local shown = {}
  for _, id in ipairs(loud) do shown[#shown + 1] = id end
  if hovering then
    for _, id in ipairs(quiet) do shown[#shown + 1] = id end
  end
  local labels, missing_icon = {}, false
  for i, id in ipairs(shown) do
    labels[i] = display_name(id)
    if i <= MAX_APPS and not icon_source[id] then missing_icon = true end
  end
  for i, app in ipairs(apps) do
    local id = shown[i]
    set_app(app, id and icon_source[id] or nil, display)
  end
  app_names:set({
    -- Ohne Icon steht der Name immer da, sonst sähe man nur das Symbol.
    drawing = #shown > 0 and (show_names or missing_icon),
    display = display,
    label = {
      string = table.concat(labels, ", "),
      color = #loud > 0 and colors.white or colors.grey,
    },
  })

  unknown:set({
    drawing = not attribution,
    display = display,
    label = { drawing = show_names },
  })
  content = content or not attribution
  lead:set({ drawing = content, display = display })

  sbar.animate("tanh", 15, function()
    pill:set({
      drawing = true,
      display = display,
      background = {
        color = tint and colors.with_alpha(tint, 0.18) or colors.bg1,
        border_color = tint and colors.with_alpha(tint, 0.7) or colors.transparent,
      },
    })
  end)
end

local function render_popup()
  local info = state or {}
  local n = 0
  for _, kind in ipairs(KINDS) do
    for _, id in ipairs(info.attribution == "on" and info[kind.key] or {}) do
      n = n + 1
      if n <= POPUP_ROWS then
        local quiet = QUIET[id]
        row_kind[n] = kind
        rows[n]:set({
          drawing = true,
          icon = {
            string = icons.privacy[kind.key] .. "  " .. kind.title,
            color = quiet and colors.grey or kind.color,
          },
          label = {
            string = display_name(id) .. (quiet and " · dauerhaft" or ""),
            color = quiet and colors.grey or colors.white,
          },
        })
      end
    end
  end
  for i = n + 1, POPUP_ROWS do
    row_kind[i] = nil
    rows[i]:set({ drawing = false })
  end

  local text = nil
  if info.attribution ~= "on" then
    text = "Zuordnung nicht verfügbar"
  elseif n == 0 then
    text = "Kein Zugriff"
  elseif n > POPUP_ROWS then
    text = "… und " .. (n - POPUP_ROWS) .. " weitere"
  end
  note:set({ drawing = text ~= nil, label = { string = text or "" } })
end

cap:subscribe("privacy_indicator_change", function(env)
  -- Ein manuelles --trigger ohne INFO ändert nichts.
  if type(env.info) ~= "table" then return end
  local before = {}
  for _, kind in ipairs(KINDS) do
    for _, id in ipairs(state and state[kind.key] or {}) do before[id] = true end
  end
  state = env.info
  -- Neue App an einem Sensor: Namen kurz ausklappen.
  for _, kind in ipairs(KINDS) do
    for _, id in ipairs(state[kind.key] or {}) do
      if not before[id] and not QUIET[id] then
        names_until = os.time() + NAME_SECONDS
        sbar.delay(NAME_SECONDS + 0.2, render)
      end
    end
  end
  render()
  render_popup()
end)

-- Hover über die Kapsel klappt alle Namen aus. Der Wechsel zwischen zwei
-- Kapsel-Items löst exited/entered aus; erst ein kurzes Nachfassen entscheidet.
local hover_token = 0

local function hover_on()
  hover_token = hover_token + 1
  if not hovering then
    hovering = true
    render()
  end
end

local function hover_off()
  hover_token = hover_token + 1
  local token = hover_token
  sbar.delay(0.3, function()
    if token == hover_token and hovering then
      hovering = false
      render()
    end
  end)
end

local function toggle_popup(env)
  if env.BUTTON == "right" then
    sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy'")
    return
  end
  local open = cap:query().popup.drawing == "off"
  if open then render_popup() end
  cap:set({ popup = { drawing = open } })
end

for _, item in ipairs(pill_items) do
  item:subscribe("mouse.entered", hover_on)
  item:subscribe("mouse.exited", hover_off)
  item:subscribe("mouse.clicked", toggle_popup)
end

cap:subscribe("mouse.exited.global", function()
  cap:set({ popup = { drawing = false } })
end)
