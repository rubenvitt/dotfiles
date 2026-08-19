local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- Auslastung je CPU-Kern als Balkenreihe (wie die Kern-Ansicht in iStat Menus).
-- Datenquelle ist der Event-Provider cpu_cores, der host_processor_info()
-- auswertet und "cpu_cores_update" mit einer komma-separierten Liste feuert.

local function sysctl(key)
  local handle = io.popen("sysctl -n " .. key .. " 2>/dev/null")
  if not handle then return nil end
  local out = handle:read("*a")
  handle:close()
  return tonumber(out)
end

local CORE_COUNT = sysctl("hw.ncpu") or 8

-- Auf Apple Silicon liefert host_processor_info die Efficiency-Kerne zuerst
-- (auf dem M3 Max empirisch Index 0..3). Die breitere Lücke trennt sie optisch
-- von den Performance-Kernen; auf homogenen CPUs existiert perflevel1 nicht.
local EFFICIENCY_CORES = sysctl("hw.perflevel1.logicalcpu") or 0
if EFFICIENCY_CORES >= CORE_COUNT then EFFICIENCY_CORES = 0 end

local BAR_WIDTH = 3
local BAR_GAP = 2
local CLUSTER_GAP = 6
local MAX_HEIGHT = 20
local MIN_HEIGHT = 2
-- Nur gerade Höhen: das y_offset muss ganzzahlig bleiben, sonst rutscht die
-- Unterkante bei ungerader Höhe um einen halben Punkt nach unten und die
-- Balken stehen nicht mehr auf einer Linie.
local HEIGHT_STEP = 2

sbar.exec("killall cpu_cores >/dev/null; $CONFIG_DIR/helpers/event_providers/cpu_cores/bin/cpu_cores cpu_cores_update 2.0")

-- Der Balken wächst von unten: die Unterkante bleibt fix, wenn das y_offset um
-- die halbe fehlende Höhe mitwandert.
local function offset_for(height)
  return math.floor((height - MAX_HEIGHT) / 2)
end

local function height_for(load)
  local steps = math.floor(load / 100 * MAX_HEIGHT / HEIGHT_STEP + 0.5)
  return math.max(MIN_HEIGHT, steps * HEIGHT_STEP)
end

-- Leerlauf-Sockel: sichtbar genug, dass die Balkenreihe auch bei kaltem
-- System als solche erkennbar bleibt, aber ohne Aufmerksamkeit zu ziehen.
local EMPTY_COLOR = colors.with_alpha(colors.grey, 0.55)

local function color_for(load)
  if load >= 80 then return colors.red end
  if load >= 60 then return colors.orange end
  if load >= 30 then return colors.yellow end
  if load >= 8 then return colors.blue end
  return EMPTY_COLOR
end

-- position = "right" ordnet in Hinzufüge-Reihenfolge von rechts nach links an.
-- Damit Kern 0 links steht, läuft der Aufbau rückwärts: erst der rechte Rand,
-- dann die Kerne absteigend, zuletzt das Icon ganz links.
local members = {}

local trailing = sbar.add("item", "widgets.cpu_cores.trailing", {
  position = "right",
  width = 6,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = false },
})
members[#members + 1] = trailing.name

local bars = {}

for index = CORE_COUNT - 1, 0, -1 do
  -- Explizites background.padding_right statt Item-Padding: bei gesetztem
  -- width zählt das Item-Padding zur Gesamtbreite und verschiebt die Balken
  -- ineinander; der Background-Rand lässt sie dagegen sauber bündig stehen.
  local gap = (EFFICIENCY_CORES > 0 and index == EFFICIENCY_CORES - 1)
              and CLUSTER_GAP or BAR_GAP
  local name = "widgets.cpu_cores.core." .. index

  bars[index] = sbar.add("item", name, {
    position = "right",
    width = BAR_WIDTH + gap,
    padding_left = 0,
    padding_right = 0,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      drawing = true,
      height = MIN_HEIGHT,
      corner_radius = 1,
      border_width = 0,
      color = EMPTY_COLOR,
      padding_left = 0,
      padding_right = gap,
      y_offset = offset_for(MIN_HEIGHT),
    },
    click_script = "open -a 'Activity Monitor'",
  })

  members[#members + 1] = name
end

local cpu_cores = sbar.add("item", "widgets.cpu_cores", {
  position = "right",
  icon = {
    string = icons.cpu,
    padding_left = 8,
    padding_right = 6,
    color = colors.white,
  },
  label = { drawing = false },
  padding_left = 0,
  padding_right = 0,
  background = { drawing = false },
  click_script = "open -a 'Activity Monitor'",
})
members[#members + 1] = cpu_cores.name

cpu_cores:subscribe("cpu_cores_update", function(env)
  local index = 0
  for value in string.gmatch(env.loads or "", "[^,]+") do
    local bar = bars[index]
    if bar then
      local load = math.max(0, math.min(100, tonumber(value) or 0))
      local height = height_for(load)
      bar:set({
        background = {
          height = height,
          y_offset = offset_for(height),
          color = color_for(load),
        }
      })
    end
    index = index + 1
  end
end)

sbar.add("bracket", "widgets.cpu_cores.bracket", members, {
  background = { color = colors.bg1 }
})

sbar.add("item", "widgets.cpu_cores.padding", {
  position = "right",
  width = settings.group_paddings,
})
