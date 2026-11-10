local colors = require("colors")
local icons = require("icons")
local svg = require("helpers.svg_icon")
local settings = require("settings")
local popup = require("helpers.popup")

-- Speicherdruck und freier Plattenplatz, zweizeilig und bewusst leise: beides
-- sind Zahlen, die man selten braucht und nie übersehen will, wenn sie kippen.
--
-- Oben steht der Druck, nicht der freie Speicher. macOS füllt ungenutztes RAM
-- mit Cache, "frei" ist auf einer großen Maschine dauerhaft klein und sagt
-- nichts über Knappheit. Der Druck ist der Wert, den auch die Aktivitätsanzeige
-- zeichnet: (wired + Kompressor) geteilt durch alle Seiten.
--
-- Quelle ist vm_stat und nicht memory_pressure, weil derselbe Aufruf zusätzlich
-- die Zahlen für die Popup-Zeile liefert; in Stichproben lagen beide rund einen
-- Punkt auseinander. sysctl kern.memorystatus_vm_pressure_level scheidet aus:
-- es kennt nur 1/2/4 und stand bei 40 % Druck unverändert auf 1.

-- Popup im Stil der Systemmenüs (helpers/popup.lua). Prozessnamen werden
-- gekürzt: ein "Microsoft Teams WebView Helper (Renderer)" liefe sonst in die
-- Zahlenspalte.
local NAME_WIDTH = 190
local NAME_CHARS = 26
local PROC_ROWS = 4

-- LC_ALL=C muss an jedem awk hängen, nicht nur am ersten Kommando der Pipe:
-- unter einer deutschen Locale schreibt printf "%.1f" ein Komma, und daran
-- scheitert tonumber() auf der Lua-Seite lautlos.
local RAM_CMD = [[LC_ALL=C vm_stat | LC_ALL=C awk -v total="$(sysctl -n hw.memsize)" '
/page size of/ { psz = $8 }
/^Pages wired down:/ { wired = $4 }
/^Pages occupied by compressor:/ { comp = $5 }
/^Anonymous pages:/ { anon = $3 }
/^Pages purgeable:/ { purge = $3 }
END {
  gsub(/\./, "", wired); gsub(/\./, "", comp); gsub(/\./, "", anon); gsub(/\./, "", purge)
  if (psz == 0 || total == 0) exit 1
  pages = total / psz
  printf "%d %.1f %.0f\n", (wired + comp) * 100 / pages,
    ((anon - purge) + wired + comp) * psz / 1073741824, total / 1073741824
}']]

-- Nicht df /: das ist seit Big Sur das schreibgeschützte System-Volume und
-- meldet einen Füllstand, der mit dem Alltag nichts zu tun hat.
local DISK_CMD = [[LC_ALL=C df -k /System/Volumes/Data | LC_ALL=C awk '
NR == 2 { printf "%.0f %.0f %d\n", $4 / 1048576, $3 / 1048576, $4 * 100 / ($3 + $4) }']]

-- -m sortiert nach Speicher; das naheliegende -r sortiert nach CPU-Anteil.
local PROC_CMD = [[LC_ALL=C ps -Aceo rss,comm -m | LC_ALL=C awk '
NR > 1 && NR <= ]] .. (PROC_ROWS + 1) .. [[ { rss = $1; $1 = ""; sub(/^ +/, "")
  printf "%s|%.1f\n", $0, rss / 1024 }']]

-- Skala der Aktivitätsanzeige, nicht die der CPU-Balken: unter 60 % arbeitet
-- das System entspannt, ab 90 % wird ausgelagert statt verdrängt.
local function pressure_color(percent)
  if percent >= 90 then return colors.red end
  if percent >= 80 then return colors.orange end
  if percent >= 60 then return colors.yellow end
  return colors.blue
end

local function disk_color(free_percent)
  if free_percent < 5 then return colors.red end
  if free_percent < 10 then return colors.yellow end
  return colors.grey
end

local function gigabytes(mb)
  if mb >= 1024 then return string.format("%.1f G", mb / 1024) end
  return string.format("%.0f M", mb)
end

-- Zweizeiliges Muster aus wifi.lua: das obere Item ist null Punkt breit und legt
-- sich über das untere, die y_offsets ziehen die Zeilen auseinander.
local ram = sbar.add("item", "widgets.memory.ram", {
  display = settings.primary_display,
  position = "right",
  padding_left = -5,
  width = 0,
  update_freq = 8,
  icon = svg.icon("memory.ram", colors.grey, {
    padding_right = 3,
    font = { style = settings.font.style_map["Bold"], size = 9.0 },
  }),
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.grey,
    string = "--%",
  },
  y_offset = 4,
})

local disk = sbar.add("item", "widgets.memory.disk", {
  display = settings.primary_display,
  position = "right",
  padding_left = -5,
  -- Der Plattenplatz ändert sich in Minuten nicht messbar; häufiger zu fragen
  -- weckt nur die Platte.
  update_freq = 300,
  icon = svg.icon("memory.disk", colors.grey, {
    padding_right = 3,
    font = { style = settings.font.style_map["Bold"], size = 9.0 },
  }),
  label = {
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    color = colors.grey,
    string = "---G",
  },
  y_offset = -4,
})

-- Linker Innenrand des Brackets: die beiden Zeilen ziehen sich mit
-- padding_left = -5 nach links und stünden sonst am Hintergrundrand.
local pad = sbar.add("item", "widgets.memory.padding", {
  display = settings.primary_display,
  position = "right",
  width = 6,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
  background = { drawing = false },
})

local bracket = sbar.add("bracket", "widgets.memory.bracket", {
  pad.name,
  ram.name,
  disk.name,
}, {
  display = settings.primary_display,
  background = { color = colors.bg1 },
  popup = popup.host("center"),
})

sbar.add("item", "widgets.memory.group_padding", {
  display = settings.primary_display,
  position = "right",
  width = settings.group_paddings,
})

-- Feste Reserve statt Items im Callback: sonst legt jeder Durchlauf neue an.
local P = bracket.name
local function popup_row(name, opts)
  local o = { caption_width = NAME_WIDTH }
  for k, v in pairs(opts or {}) do o[k] = v end
  return popup.row(P, name, o)
end

popup.gap(P, "widgets.memory.gap.top", 6, { drawing = true })
local header = popup.header(P, "widgets.memory.header", { drawing = true })
header:set({ icon = { string = "Speicher" } })
popup.rule(P, "widgets.memory.rule.procs", { drawing = true })
popup.section(P, "widgets.memory.section", { drawing = true })
  :set({ icon = { string = "Größter Speicherbedarf" } })

local proc_rows = {}
for i = 1, PROC_ROWS do
  proc_rows[i] = popup_row("widgets.memory.proc." .. i, { caption_color = colors.white })
  proc_rows[i]:set({ icon = { max_chars = NAME_CHARS } })
end

popup.rule(P, "widgets.memory.rule.totals", { drawing = true })
local ram_row = popup_row("widgets.memory.total.ram", { drawing = true })
ram_row:set({ icon = { string = "RAM belegt / gesamt" } })

local disk_row = popup_row("widgets.memory.total.disk", { drawing = true })
disk_row:set({ icon = { string = "Platte belegt / frei" } })

popup.rule(P, "widgets.memory.rule.open", { drawing = true })
popup.action(P, "widgets.memory.open", "Aktivitätsanzeige öffnen",
  "open -a 'Activity Monitor'; sketchybar --set " .. P .. " popup.drawing=off")
popup.gap(P, "widgets.memory.gap.bottom", 6, { drawing = true })

local function update_ram()
  sbar.exec(RAM_CMD, function(out)
    local percent, used, total = string.match(out or "", "(%d+)%s+([%d%.]+)%s+(%d+)")
    if not percent then return end
    percent = tonumber(percent)
    ram:set({
      icon = svg.color("memory.ram", pressure_color(percent)),
      label = { string = percent .. "%", color = pressure_color(percent) },
    })
    ram_row:set({ label = { string = used .. " / " .. total .. " G" } })
    header:set({ label = { string = "Druck " .. percent .. " %" } })
  end)
end

local function update_disk()
  sbar.exec(DISK_CMD, function(out)
    local free, used, free_percent = string.match(out or "", "(%d+)%s+(%d+)%s+(%d+)")
    if not free then return end
    local color = disk_color(tonumber(free_percent))
    disk:set({
      icon = svg.color("memory.disk", color),
      label = { string = free .. "G", color = color },
    })
    disk_row:set({ label = { string = used .. " / " .. free .. " G" } })
  end)
end

local function update_processes()
  sbar.exec(PROC_CMD, function(out)
    local index = 0
    for line in string.gmatch(out or "", "[^\r\n]+") do
      -- Gieriges .* trifft das letzte Trennzeichen, damit ein Prozessname mit
      -- Pipe im Namen die Zahl dahinter nicht verschluckt.
      local name, mb = string.match(line, "^(.*)|([%d%.]+)$")
      index = index + 1
      local row = proc_rows[index]
      if row and name then
        row:set({
          drawing = true,
          icon = { string = name },
          label = { string = gigabytes(tonumber(mb) or 0) },
        })
      end
    end
    for i = index + 1, PROC_ROWS do
      proc_rows[i]:set({ drawing = false })
    end
  end)
end

local function hide_details()
  bracket:set({ popup = { drawing = false } })
end

local function toggle_details()
  if bracket:query().popup.drawing == "off" then
    popup.close_others(P)
    bracket:set({ popup = { drawing = true } })
    update_processes()
  else
    hide_details()
  end
end

ram:subscribe({ "routine", "forced", "system_woke" }, update_ram)
disk:subscribe({ "routine", "forced", "system_woke" }, update_disk)

ram:subscribe("mouse.clicked", toggle_details)
disk:subscribe("mouse.clicked", toggle_details)
pad:subscribe("mouse.clicked", toggle_details)
-- Das Padding-Item zeichnet nichts; das globale Verlassen-Event holt sich
-- deshalb eine der beiden sichtbaren Zeilen.
ram:subscribe("mouse.exited.global", hide_details)

update_ram()
update_disk()
