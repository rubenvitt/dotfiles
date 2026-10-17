local colors = require("colors")
local settings = require("settings")

-- Einsatzalarm: solange der apager-Dialog offen ist, blinkt die ganze Bar rot,
-- die Statussymbole rechts weichen dem Alarmtext, nur Uhr und Privacy-Punkt
-- bleiben. So fällt der Alarm auch aus ein paar Metern Abstand auf. Der
-- Listener (r-tools/apager-listener.py) triggert apager_alarm mit ACTIVE=1 und
-- TEXT bei jedem Alarm, mit ACTIVE=0, sobald quittiert ist.
-- shortcut: ein --reload mitten im Alarm vergisst ihn, die Bar zeigt ihn erst
-- beim nächsten wieder -- der Dialog bleibt ja offen. Nachrüsten, falls das stört.

local BLINK_SECONDS = 0.6
-- Eigenes Signalrot: colors.red ist für die Bar zu rosa.
local ALARM_RED = 0xffd7141e

-- Rechte Items, die während des Alarms bleiben. __mbar.* sind die anonymen
-- Abstandshalter.
local KEEP = { "^clock", "^privacy", "^apager", "^__mbar%." }

sbar.add("event", "apager_alarm")

-- Rechts nach der Uhr angelegt, steht es links neben ihr.
local item = sbar.add("item", "apager", {
  position = "right",
  display = settings.primary_display,
  drawing = false,
  updates = "on",
  icon = { string = "EINSATZ", color = colors.white, padding_left = 10,
    font = { style = settings.font.style_map["Black"], size = 14.0 } },
  label = { color = colors.white, padding_right = 10,
    font = { style = settings.font.style_map["Bold"], size = 14.0 } },
})

local function kept(name)
  for _, pattern in ipairs(KEEP) do
    if name:find(pattern) then return true end
  end
  return false
end

local active = false
-- Rechte Items, die beim Alarmbeginn sichtbar waren und danach zurückkommen.
local hidden = {}
-- Alle anderen rechten Items: werden bei jedem Blinken erneut versteckt, falls
-- sich eines zwischendurch selbst einblendet.
local others = {}
-- Jeder Alarm startet eine neue Blinkschleife; ältere Schleifen erkennen an
-- der Generation, dass sie abgelöst sind, und hören auf.
local generation = 0

local function hide_status()
  hidden, others = {}, {}
  for _, name in ipairs(sbar.query("bar").items) do
    if not kept(name) then
      local q = sbar.query(name)
      if q.geometry.position == "right" then
        others[#others + 1] = name
        if q.geometry.drawing == "on" then hidden[#hidden + 1] = name end
      end
    end
  end
end

local function blink(gen, red)
  if not active or gen ~= generation then return end
  sbar.bar({ color = red and ALARM_RED or colors.bar.bg })
  for _, name in ipairs(others) do sbar.set(name, { drawing = false }) end
  sbar.delay(BLINK_SECONDS, function() blink(gen, not red) end)
end

item:subscribe("apager_alarm", function(env)
  local was_active = active
  active = env.ACTIVE == "1"
  generation = generation + 1
  if active then
    if not was_active then hide_status() end
    item:set({ drawing = true, label = { string = env.TEXT or "" } })
    blink(generation, true)
  elseif was_active then
    item:set({ drawing = false })
    sbar.bar({ color = colors.bar.bg })
    for _, name in ipairs(hidden) do sbar.set(name, { drawing = true }) end
    -- Items, die während des Alarms ihren Zustand geändert haben, rechnen neu.
    sbar.exec("sketchybar --update")
  end
end)
