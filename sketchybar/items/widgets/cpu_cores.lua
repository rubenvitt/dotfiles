local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- Auslastung je CPU-Kern als Balkenreihe (wie die Kern-Ansicht in iStat Menus).
-- Datenquelle ist der Event-Provider cpu_cores, der host_processor_info()
-- auswertet und "cpu_cores_update" mit einer komma-separierten Liste feuert.

-- Die sysctl-Werte holt helpers/system_info ganz am Anfang der Config; ein
-- io.popen an dieser Stelle haengt in pclose(), sobald sbar.exec den Prozess
-- einmal geforkt hat (Details dort).
local system_info = require("helpers.system_info")

local CORE_COUNT = system_info.cpu_count

-- Auf Apple Silicon liefert host_processor_info die Efficiency-Kerne zuerst
-- (auf dem M3 Max empirisch Index 0..3). Die breitere Lücke trennt sie optisch
-- von den Performance-Kernen; auf homogenen CPUs existiert perflevel1 nicht.
local EFFICIENCY_CORES = system_info.efficiency_cores

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
-- Das Event selbst anlegen, bevor ein Item es abonniert: der Helfer meldet es
-- erst nach seinem Start an, und unter mbar geht die ganze Config vorher in
-- einem Rutsch raus ("Event not found", das Abo fehlt dann still).
sbar.add("event", "cpu_cores_update")

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

-- Popup: die fünf Prozesse mit der höchsten CPU-Last. Kompaktes Raster wie in
-- items/weather.lua, sonst erbt jede Zeile die Bar-Höhe von 40 Punkt.
local ROW_FONT = 11.0
local ROW_HEIGHT = 20
local ROW_PAD = 7
local NAME_WIDTH = 152
local VALUE_WIDTH = 54
local TOP_ROWS = 5
-- Ein Punkt je Provider-Tick (2 s): gut zwei Minuten Rueckblick.
local HISTORY_POINTS = 64

-- `ps` formatiert pcpu nach LC_NUMERIC; unter de_DE kommt "69,7" zurück, was
-- tonumber() nicht lesen kann. Das Präfix deckt den Normalfall ab, greift aber
-- nicht gegen ein gesetztes LC_ALL — verlassen wir uns auf das gsub unten.
local TOP_PROCS = "LC_NUMERIC=C ps -Aceo pcpu,comm -r | head -" .. (TOP_ROWS + 1)

-- Ein Prozess summiert über alle Kerne und kann die 100 überschreiten. Die
-- Ampel bleibt trotzdem auf einen voll ausgelasteten Kern skaliert: alles
-- darüber ist ohnehin rot, und ein Teiler durch CORE_COUNT würde 400 % noch
-- gelb einfärben.
local function color_for_proc(load)
  return color_for(math.min(load, 100))
end

-- Jenseits von 100 % ist die Nachkommastelle Rauschen.
local function format_load(load)
  if load >= 100 then return string.format("%.0f%%", load) end
  return string.format("%.1f%%", load)
end

-- position = "right" ordnet in Hinzufüge-Reihenfolge von rechts nach links an.
-- Damit Kern 0 links steht, läuft der Aufbau rückwärts: erst der rechte Rand,
-- dann die Kerne absteigend, zuletzt das Icon ganz links.
local members = {}

local trailing = sbar.add("item", "widgets.cpu_cores.trailing", {
  display = settings.primary_display,
  position = "right",
  width = 6,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = false },
})
members[#members + 1] = trailing.name

-- Gesamtauslastung als Zahl. Sie stand vorher im separaten cpu-Widget mit
-- Verlaufsgraph; das ist entfallen, damit es nur eine CPU-Anzeige gibt. Der
-- Mittelwert ueber alle Kerne ist dieselbe Groesse, die host_statistics als
-- total_load liefert -- ein zweiter Event-Provider dafuer waere unnoetig.
local total = sbar.add("item", "widgets.cpu_cores.total", {
  display = settings.primary_display,
  position = "right",
  icon = { drawing = false },
  label = {
    string = "--%",
    width = settings.compact and 34 or 40,
    align = "right",
    padding_left = settings.compact and 0 or 6,
    padding_right = 0,
    color = colors.white,
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 12.0,
    },
  },
  padding_left = 0,
  padding_right = 0,
  background = { drawing = false },
})
members[#members + 1] = total.name

local bars = {}

-- Im Kompakt-Modus (nur MBP-Panel) entfallen die Kern-Balken; die
-- Gesamtzahl bleibt, der Handler ueberspringt fehlende bars[index].
for index = (settings.compact and -1 or CORE_COUNT - 1), 0, -1 do
  -- Explizites background.padding_right statt Item-Padding: bei gesetztem
  -- width zählt das Item-Padding zur Gesamtbreite und verschiebt die Balken
  -- ineinander; der Background-Rand lässt sie dagegen sauber bündig stehen.
  local gap = (EFFICIENCY_CORES > 0 and index == EFFICIENCY_CORES - 1)
              and CLUSTER_GAP or BAR_GAP
  local name = "widgets.cpu_cores.core." .. index

  bars[index] = sbar.add("item", name, {
  display = settings.primary_display,
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
  })

  members[#members + 1] = name
end

local cpu_cores = sbar.add("item", "widgets.cpu_cores", {
  display = settings.primary_display,
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
})
members[#members + 1] = cpu_cores.name

-- Wird erst nach dem Bracket angelegt (es traegt das Popup), aber schon hier
-- im Handler gebraucht -- daher die Vorab-Deklaration.
local history

cpu_cores:subscribe("cpu_cores_update", function(env)
  local index = 0
  local sum = 0
  for value in string.gmatch(env.loads or "", "[^,]+") do
    local load = math.max(0, math.min(100, tonumber(value) or 0))
    local bar = bars[index]
    if bar then
      local height = height_for(load)
      bar:set({
        background = {
          height = height,
          y_offset = offset_for(height),
          color = color_for(load),
        }
      })
    end
    sum = sum + load
    index = index + 1
  end

  if index > 0 then
    local average = sum / index
    local color = color_for(average)
    total:set({
      label = {
        string = string.format("%d%%", math.floor(average + 0.5)),
        color = color,
      }
    })
    if history then
      history:push({ average / 100 })
      history:set({ graph = { color = color, fill_color = colors.with_alpha(color, 0.25) } })
    end
  end
end)

local bracket = sbar.add("bracket", "widgets.cpu_cores.bracket", members, {
  display = settings.primary_display,
  background = { color = colors.bg1 },
  popup = { align = "right", height = ROW_HEIGHT },
})

-- Der Verlauf der Gesamtauslastung, frueher ein eigenes Widget in der Bar.
-- Im Popup stoert er nicht und beantwortet trotzdem die Frage, ob die aktuelle
-- Last eine Spitze oder ein Dauerzustand ist. Ein Punkt je Provider-Tick, also
-- gut zwei Minuten Historie.
--
-- updates = true ist Pflicht: Popup-Items gelten bei geschlossenem Popup als
-- nicht sichtbar, und mit dem geerbten when_shown bliebe der Graph leer, bis
-- man ihn aufklappt -- also genau dann, wenn man ihn braucht.
history = sbar.add("graph", "widgets.cpu_cores.history", HISTORY_POINTS, {
  position = "popup." .. bracket.name,
  updates = true,
  width = NAME_WIDTH + VALUE_WIDTH,
  padding_left = ROW_PAD,
  padding_right = ROW_PAD,
  graph = { color = colors.blue, fill_color = colors.with_alpha(colors.blue, 0.25) },
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = false },
})

-- Zeilen einmal anlegen und später nur beschriften: im Update-Callback erzeugt
-- jeder Durchlauf sonst neue Items.
local proc_rows = {}
for i = 1, TOP_ROWS do
  proc_rows[i] = sbar.add("item", "widgets.cpu_cores.proc." .. i, {
    position = "popup." .. bracket.name,
    drawing = false,
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = "",
      width = NAME_WIDTH,
      align = "left",
      color = colors.white,
      padding_left = ROW_PAD,
      padding_right = 0,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      width = VALUE_WIDTH,
      align = "right",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = settings.font.numbers, size = ROW_FONT },
    },
  })
end

-- Der frühere click_script des Widgets lebt als letzte Popup-Zeile weiter.
sbar.add("item", "widgets.cpu_cores.activity", {
  position = "popup." .. bracket.name,
  padding_left = ROW_PAD,
  padding_right = ROW_PAD,
  icon = {
    string = "Aktivitätsanzeige öffnen",
    width = NAME_WIDTH,
    align = "left",
    color = colors.grey,
    padding_left = ROW_PAD,
    padding_right = 0,
    font = { family = settings.font.text, size = ROW_FONT },
  },
  label = {
    string = "􀄯",
    width = VALUE_WIDTH,
    align = "right",
    color = colors.grey,
    padding_left = 0,
    padding_right = ROW_PAD,
    font = { family = settings.font.text, size = ROW_FONT },
  },
  click_script = "sketchybar --set " .. bracket.name ..
    " popup.drawing=off; open -a 'Activity Monitor'",
})

local function fill_rows()
  sbar.exec(TOP_PROCS, function(out)
    local row = 0
    for line in string.gmatch(out or "", "[^\r\n]+") do
      -- Der Prozessname darf Leerzeichen enthalten ("Raycast Beta Backend"),
      -- die Kopfzeile "%CPU COMM" scheitert am Zahlenmuster und fällt raus.
      local value, name = string.match(line, "^%s*([%d.,]+)%s+(.-)%s*$")
      local load = value and tonumber((string.gsub(value, ",", ".")))
      if load and row < TOP_ROWS then
        row = row + 1
        proc_rows[row]:set({
          drawing = true,
          icon = { string = name },
          label = { string = format_load(load), color = color_for_proc(load) },
        })
      end
    end
    for i = row + 1, TOP_ROWS do
      proc_rows[i]:set({ drawing = false })
    end
  end)
end

-- sbar.exec ist asynchron: das Popup geht sofort auf, die Zeilen tragen sich
-- nach. Deshalb wird beim Öffnen geladen und nicht dauerhaft gepollt.
local function toggle_popup()
  -- Auf "off" prüfen wie in wifi.lua: nur dieser Wert ist in dieser Config
  -- belegt, ein unerwarteter Zustand schließt dann statt neu zu öffnen.
  if bracket:query().popup.drawing == "off" then
    bracket:set({ popup = { drawing = true } })
    fill_rows()
  else
    bracket:set({ popup = { drawing = false } })
  end
end

-- Jeder Balken ist nur wenige Punkt breit; erst alle zusammen ergeben eine
-- Klickfläche über die ganze Widget-Breite.
cpu_cores:subscribe("mouse.clicked", toggle_popup)
total:subscribe("mouse.clicked", toggle_popup)
trailing:subscribe("mouse.clicked", toggle_popup)
for _, bar in pairs(bars) do
  bar:subscribe("mouse.clicked", toggle_popup)
end

sbar.add("item", "widgets.cpu_cores.padding", {
  display = settings.primary_display,
  position = "right",
  width = settings.group_paddings,
})
