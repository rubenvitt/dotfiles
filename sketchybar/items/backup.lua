local colors = require("colors")
local settings = require("settings")

-- Warnanzeige für das stündliche Kopia-Backup (launchd/kopia-snapshot.sh).
--
-- Das Skript überspringt still, wenn die Backup-Platte fehlt, und meldet sich
-- erst nach fünf Tagen -- einmal täglich per Mitteilung, die man wegwischt.
-- Ein wochenlanger Ausfall fällt so niemandem auf. Dieses Item bleibt deshalb
-- unsichtbar, solange das Backup frisch ist, und wird erst zur Warnung.
--
-- Als Alter zählt der letzte *erfolgreiche* Snapshot, nicht der letzte
-- Mount-Versuch. Die Zahl steht in last-mounted: der Name führt in die Irre,
-- geschrieben wird die Datei ausschließlich in Zeile 77 des Skripts, direkt
-- nach "snapshot complete". Weder der Skip- noch der Fehlerpfad fassen sie an.
-- Das Log wäre die schlechtere Quelle -- es rotiert monatlich, und der
-- laufende Monat enthält hier derzeit gar keinen Erfolg, aus dem sich ein
-- Datum lesen ließe. `kopia snapshot list` scheidet ganz aus: ohne gemountete
-- Platte hängt der Aufruf oder verlangt ein Passwort.

local STATE = "$HOME/.local/state/kopia/last-mounted"
local LOG_GLOB = '"$HOME"/Library/Logs/kopia/snapshot-*.log'
local DISK = "/Volumes/Backups"

-- Schwellen in Tagen. Die mittlere ist kein runder Wert, sondern WARN_AFTER_DAYS
-- aus kopia-snapshot.sh: ab hier hält auch das Skript den Ausfall für meldenswert.
-- Zwei Tage davor genügt als erster Hinweis (die Platte hängt sonst täglich dran),
-- zehn Tage sind jenseits jedes Urlaubs und damit rot.
local WARN_DAYS = 2
local ALERT_DAYS = 5
local CRIT_DAYS = 10

-- Ein Backup-Job pro Stunde; alles unter fünf Minuten fragt nur Werte ab, die
-- sich gar nicht geändert haben können.
local UPDATE_FREQ = 300

-- Popup-Raster wie in irrlicht.lua: die Bar-Defaults (13pt, 28px) erzeugen in
-- einer Liste aus vier Zeilen viel Leerraum.
local ROW_FONT = 11.0
local ROW_HEIGHT = 20
local ROW_PAD = 7
local CAPTION_WIDTH = 112
local MAX_ERROR_CHARS = 52

-- Eine Zeile, drei Felder: Zeitstempel (oder "-"), Mount-Flag, letzte
-- Fehlerzeile. Nur "error:" wird gesucht -- die "warning:"-Zeilen melden die
-- fehlende Platte und wiederholten damit nur, was die Mount-Zeile schon sagt.
local PROBE = table.concat({
  'ts=$(cat ' .. STATE .. ' 2>/dev/null || echo -);',
  'mounted=0; [ -d ' .. DISK .. ' ] && mounted=1;',
  'err=$(grep -h "error:" ' .. LOG_GLOB .. ' 2>/dev/null | tail -1);',
  'printf "%s|%s|%s\\n" "$ts" "$mounted" "$err"',
}, " ")

-- Alter grob, aber in ganzen Sätzen: „vor 6 Tagen" liest sich schneller als
-- „6d 3h". Vorbild ist human_eta in irrlicht.lua.
local function human_age(seconds)
  local function unit(n, one, many)
    return n .. " " .. (n == 1 and one or many)
  end
  if seconds >= 86400 then
    return unit(math.floor(seconds / 86400), "Tag", "Tagen")
  elseif seconds >= 3600 then
    return unit(math.floor(seconds / 3600), "Stunde", "Stunden")
  end
  return unit(math.max(0, math.floor(seconds / 60)), "Minute", "Minuten")
end

-- In der Bar zaehlt Kuerze: das Icon sagt bereits, worum es geht, und neben
-- "1/6" und "31°" faellt eine ganze Textzeile aus dem Rahmen. Der ausgeschriebene
-- Satz steht im Popup.
local function short_age(seconds)
  if seconds >= 86400 then return math.floor(seconds / 86400) .. "d" end
  if seconds >= 3600 then return math.floor(seconds / 3600) .. "h" end
  return math.max(0, math.floor(seconds / 60)) .. "m"
end

local function age_color(days)
  if days >= CRIT_DAYS then return colors.red end
  if days >= ALERT_DAYS then return colors.orange end
  if days >= WARN_DAYS then return colors.yellow end
  return nil -- frisch genug, das Item bleibt unsichtbar
end

local backup = sbar.add("item", "backup", {
  position = "right",
  -- default.lua setzt updates = "when_shown"; ohne diese Zeile bekäme das Item
  -- nach dem ersten drawing = false keine Events mehr und käme nie zurück.
  updates = true,
  drawing = false,
  icon = {
    string = "􀤃",
    color = colors.yellow,
  },
  label = {
    font = { family = settings.font.text },
    color = colors.yellow,
  },
  update_freq = UPDATE_FREQ,
  popup = {
    align = "right",
    height = ROW_HEIGHT,
  },
  click_script = "sketchybar --set backup popup.drawing=toggle",
})

-- Zeilen einmalig anlegen: im Update-Callback erzeugt jeder Durchlauf neue
-- Items (siehe items/menus.lua).
local function popup_row(name, caption)
  return sbar.add("item", "backup." .. name, {
    position = "popup.backup",
    padding_left = ROW_PAD,
    padding_right = ROW_PAD,
    icon = {
      string = caption,
      width = CAPTION_WIDTH,
      align = "left",
      color = colors.grey,
      padding_left = ROW_PAD,
      padding_right = 0,
      font = { family = settings.font.text, size = ROW_FONT },
    },
    label = {
      string = "",
      align = "left",
      padding_left = 0,
      padding_right = ROW_PAD,
      font = { family = settings.font.text, size = ROW_FONT },
    },
  })
end

local row_snapshot = popup_row("snapshot", "Letzter Snapshot")
local row_disk = popup_row("disk", "Platte")
local row_error = popup_row("error", "Letzter Fehler")
local row_log = popup_row("log", "Log öffnen")

-- Im click_script darf der Monat als Shell-Einsetzung stehen -- der Klick geht
-- durch eine Shell und trifft damit auch nach einem Monatswechsel das richtige
-- Log. Die Beschriftung nicht: Label-Werte gehen unausgewertet an sketchybar,
-- sie wird in apply() gesetzt.
row_log:set({
  label = { color = colors.grey },
  click_script = 'open "$HOME/Library/Logs/kopia/snapshot-$(date +%Y-%m).log"; ' ..
    "sketchybar --set backup popup.drawing=off",
})

-- Fehlerzeilen sehen so aus: "[2026-08-19 14:23:44] error: snapshot failed".
-- Das Datum bleibt stehen, weil ein Fehler auch älter sein kann als der letzte
-- erfolgreiche Snapshot -- ohne Datum läse er sich als aktuell.
local function format_error(line)
  local stamp, message = string.match(line, "^%[(%d+%-%d+%-%d+ %d+:%d+):%d+%] (.*)$")
  local text = string.gsub(message or line, "^error:%s*", "")
  if #text > MAX_ERROR_CHARS then
    text = string.sub(text, 1, MAX_ERROR_CHARS - 1) .. "…"
  end
  local month, dom, time = string.match(stamp or "", "%d+%-(%d+)%-(%d+) (%d+:%d+)")
  if month then
    return dom .. "." .. month .. ". " .. time .. " · " .. text
  end
  return text
end

local function apply(out)
  local ts, mounted, err = string.match(out or "", "^([^|]*)|([^|]*)|(.*)$")
  ts = tonumber(ts)

  -- Ohne Zeitstempel gab es nie ein erfolgreiches Backup. Das ist ein frisch
  -- aufgesetzter Rechner, kein Ausfall -- dieselbe Unterscheidung trifft das
  -- Skript in Zeile 43, bevor es überhaupt zu warnen anfängt.
  if not ts then
    backup:set({ drawing = false, popup = { drawing = false } })
    return
  end

  local age = os.time() - ts
  local color = age_color(age / 86400)
  if not color then
    backup:set({ drawing = false, popup = { drawing = false } })
    return
  end

  backup:set({
    drawing = true,
    icon = { color = color },
    label = { string = short_age(age), color = color },
  })

  row_snapshot:set({
    label = {
      string = os.date("%d.%m. %H:%M", ts) .. " · vor " .. human_age(age),
      color = color,
    },
  })

  local is_mounted = mounted == "1"
  row_disk:set({
    label = {
      string = is_mounted and "angeschlossen" or "nicht angeschlossen",
      color = is_mounted and colors.green or colors.red,
    },
  })

  -- Das dritte Feld reicht bis zum Zeilenende der Probe-Ausgabe und schleppt
  -- deren Umbruch mit; in Lua-Mustern deckt "." auch den ab.
  err = string.match(err or "", "^%s*(.-)%s*$")
  row_error:set({
    drawing = err ~= "",
    label = { string = err ~= "" and format_error(err) or "", color = colors.grey },
  })

  row_log:set({ label = { string = os.date("snapshot-%Y-%m.log") } })
end

local function update()
  sbar.exec(PROBE, apply)
end

-- system_woke zählt hier besonders: nach Tagen mit zugeklapptem Deckel soll die
-- Warnung sofort stimmen und nicht erst mit dem nächsten routine-Tick.
backup:subscribe({ "routine", "forced", "system_woke" }, update)

update()
