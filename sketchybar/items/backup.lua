local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- Anzeige für das Kopia-Backup. Zwei Dinge stehen dahinter: der stündliche
-- lokale Snapshot (launchd/kopia-snapshot.sh) und der Offsite-Spiegel auf die
-- Hetzner Storage Box (r-tools/backup mirror).
--
-- Das Snapshot-Skript überspringt still, wenn die Backup-Platte fehlt, und
-- meldet sich erst nach fünf Tagen -- einmal täglich per Mitteilung, die man
-- wegwischt. Ein wochenlanger Ausfall fällt so niemandem auf. Dieses Item
-- bleibt deshalb unsichtbar, solange alles frisch ist, und wird erst zur
-- Warnung.
--
-- Der Spiegel bringt einen Zustand mit, den der Snapshot nicht kennt: er läuft
-- stundenlang. Während ein Upload läuft, ist das Item deshalb sichtbar, auch
-- wenn nichts zu warnen ist -- ein Backup, das gerade 189 GB hochlädt, will man
-- sehen. Das hat Vorrang vor jeder Warnfarbe.
--
-- Als Alter zählt der letzte *erfolgreiche* Snapshot, nicht der letzte
-- Mount-Versuch. Die Zahl steht in last-mounted: der Name führt in die Irre,
-- geschrieben wird die Datei ausschließlich direkt nach "snapshot complete".
-- Weder der Skip- noch der Fehlerpfad fassen sie an. Das Log wäre die
-- schlechtere Quelle -- es rotiert monatlich. `kopia snapshot list` scheidet
-- ganz aus: ohne gemountete Platte hängt der Aufruf oder verlangt ein Passwort.
--
-- Ob gerade gespiegelt wird, verrät der Prozess und nicht die Zustandsdatei:
-- ein hart getöteter Lauf käme sonst nie aus "running" heraus.

local SDIR = "$HOME/.local/state/kopia"
local LOG_GLOB = '"$HOME"/Library/Logs/kopia/snapshot-*.log'
local DISK = "/Volumes/Backups"

-- Schwellen in Tagen. Die mittlere ist kein runder Wert, sondern WARN_AFTER_DAYS
-- aus kopia-snapshot.sh: ab hier hält auch das Skript den Ausfall für meldenswert.
-- Zwei Tage davor genügt als erster Hinweis (die Platte hängt sonst täglich dran),
-- zehn Tage sind jenseits jedes Urlaubs und damit rot.
local WARN_DAYS = 2
local ALERT_DAYS = 5
local CRIT_DAYS = 10

-- Der Spiegel läuft nicht stündlich, sondern von Hand und über Stunden. Eine
-- Woche ohne Offsite-Kopie ist normal, ein Monat ist es nicht.
local OFF_WARN_DAYS = 7
local OFF_ALERT_DAYS = 14
local OFF_CRIT_DAYS = 30

-- Ein Backup-Job pro Stunde; alles unter fünf Minuten fragt nur Werte ab, die
-- sich gar nicht geändert haben können. Während eines Uploads ist das anders --
-- dann soll die Zahl sich sichtbar bewegen.
local UPDATE_FREQ = 300
local UPDATE_FREQ_RUNNING = 15

-- Popup-Raster wie in irrlicht.lua: die Bar-Defaults (13pt, 28px) erzeugen in
-- einer Liste aus mehreren Zeilen viel Leerraum.
local ROW_FONT = 11.0
local ROW_HEIGHT = 20
local ROW_PAD = 7
local CAPTION_WIDTH = 112
local MAX_TEXT_CHARS = 52

-- Ein Wert pro Zeile als key=value: die Fortschrittszeile von kopia enthält
-- Leerzeichen und Sonderzeichen, für ein Trennzeichen wäre sie zu unberechenbar.
--
-- pgrep bekommt das Muster mit Zeichenklasse ("sync[-]to"), sonst findet die
-- Probe sich selbst: ihre eigene Kommandozeile enthält den Suchbegriff ja.
local PROBE = table.concat({
  'S=' .. SDIR .. ';',
  'ts=$(cat $S/last-mounted 2>/dev/null);',
  'mounted=0; [ -d ' .. DISK .. ' ] && mounted=1;',
  'err=$(grep -h "error:" ' .. LOG_GLOB .. ' 2>/dev/null | tail -1);',
  'orun=0; pgrep -f "kopia repository sync[-]to" >/dev/null 2>&1 && orun=1;',
  'ost=$(cat $S/offsite-status 2>/dev/null);',
  'ostart=$(cat $S/offsite-started 2>/dev/null);',
  'osucc=$(cat $S/offsite-last-success 2>/dev/null);',
  'oprog=$(cat $S/offsite-progress 2>/dev/null);',
  'printf "ts=%s\\nmounted=%s\\norun=%s\\nostatus=%s\\nostarted=%s\\nosuccess=%s\\nerr=%s\\noprogress=%s\\n"',
  '  "$ts" "$mounted" "$orun" "$ost" "$ostart" "$osucc" "$err" "$oprog"',
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

local function truncate(text)
  if #text > MAX_TEXT_CHARS then
    return string.sub(text, 1, MAX_TEXT_CHARS - 1) .. "…"
  end
  return text
end

local function color_for(days, warn, alert, crit)
  if days >= crit then return colors.red end
  if days >= alert then return colors.orange end
  if days >= warn then return colors.yellow end
  return nil -- frisch genug, kein Grund zur Anzeige
end

-- Die Fortschrittszeile kommt roh aus kopia und sieht so aus:
--   Copied 120 blobs (603.2 MB), Speed: 4.6 MB/s, ETA: 11h16m58s (2026-08-22 …)
-- Interessant sind zwei Werte: wie viel schon oben ist und wie lange es noch
-- dauert. Das Format ist kein zugesicherter Vertrag -- passt es nicht mehr,
-- fällt die Anzeige auf die Laufzeit zurück, und die stimmt immer.
local function parse_progress(text)
  if not text or text == "" then return nil end
  local done = string.match(text, "%((%d+%.?%d*%s?[KMGT]?i?B)%)")
  local eta = string.match(text, "ETA:%s*(%S+)")
  -- Sekundengenaue Restzeit ist bei elf Stunden Rauschen.
  if eta then eta = string.gsub(eta, "(%dm)%d+s$", "%1") end
  return { done = done, eta = eta }
end

local function short_progress(text, started)
  local p = parse_progress(text)
  if p and p.done then return (string.gsub(p.done, "%s", "")) end
  if started then return short_age(os.time() - started) end
  return "…"
end

local backup = sbar.add("item", "backup", {
  display = settings.primary_display,
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
local row_offsite = popup_row("offsite", "Offsite")
local row_offsite_age = popup_row("offsiteage", "Letzte Kopie")
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
  local month, dom, time = string.match(stamp or "", "%d+%-(%d+)%-(%d+) (%d+:%d+)")
  if month then
    return dom .. "." .. month .. ". " .. time .. " · " .. truncate(text)
  end
  return truncate(text)
end

-- Zustand des Spiegels als Satz und Farbe. "unterbrochen" ist bewusst nicht
-- rot: abgestöpselt, zugeklappt, WLAN gewechselt -- der nächste Lauf macht
-- dort weiter, wo dieser aufgehört hat. Nur "error" ist ein Fehler.
local function offsite_line(status, running, started, progress)
  if running then
    local since = started and os.date("%H:%M", started) or "?"
    local text = "läuft seit " .. since
    local p = parse_progress(progress)
    if p then
      if p.done then text = text .. " · " .. p.done end
      if p.eta then text = text .. " · noch " .. p.eta end
    end
    return truncate(text), colors.blue
  end
  if status == "ok" then return "aktuell", colors.green end
  if status == "interrupted" then return "unterbrochen — setzt beim nächsten Lauf fort", colors.yellow end
  if status == "error" then return "Fehler — siehe offsite-Log", colors.red end
  -- "running" ohne laufenden Prozess: der Lauf wurde hart beendet (Strom weg,
  -- kill -9). Auch das ist kein Fehler, nur ein unvollständiger Stand.
  if status == "running" then return "abgebrochen ohne Abschluss", colors.grey end
  return "noch nie gelaufen", colors.grey
end

local function apply(out)
  local f = {}
  for k, v in string.gmatch(out or "", "(%w+)=([^\n]*)") do f[k] = v end

  local now = os.time()
  local ts = tonumber(f.ts)
  local running = f.orun == "1"
  local ostatus = f.ostatus or ""
  local ostarted = tonumber(f.ostarted)
  local osuccess = tonumber(f.osuccess)
  local oprogress = string.match(f.oprogress or "", "^%s*(.-)%s*$")

  -- --- Popup füllen (unabhängig davon, ob die Bar etwas zeigt) -------------
  if ts then
    local age = now - ts
    row_snapshot:set({
      label = {
        string = os.date("%d.%m. %H:%M", ts) .. " · vor " .. human_age(age),
        color = color_for(age / 86400, WARN_DAYS, ALERT_DAYS, CRIT_DAYS) or colors.white,
      },
    })
  else
    row_snapshot:set({ label = { string = "noch nie gelaufen", color = colors.grey } })
  end

  local is_mounted = f.mounted == "1"
  row_disk:set({
    label = {
      string = is_mounted and "angeschlossen" or "nicht angeschlossen",
      color = is_mounted and colors.green or colors.red,
    },
  })

  local off_text, off_color = offsite_line(ostatus, running, ostarted, oprogress)
  row_offsite:set({ label = { string = off_text, color = off_color } })

  local off_age = osuccess and (now - osuccess) or nil
  local off_warn = off_age and color_for(off_age / 86400, OFF_WARN_DAYS, OFF_ALERT_DAYS, OFF_CRIT_DAYS)
  row_offsite_age:set({
    label = {
      string = osuccess and (os.date("%d.%m. %H:%M", osuccess) .. " · vor " .. human_age(off_age))
        or "—",
      color = off_warn or colors.white,
    },
  })

  local err = string.match(f.err or "", "^%s*(.-)%s*$")
  row_error:set({
    drawing = err ~= "",
    label = { string = err ~= "" and format_error(err) or "", color = colors.grey },
  })

  row_log:set({ label = { string = os.date("snapshot-%Y-%m.log") } })

  -- --- Bar: läuft > Fehler > Alter -----------------------------------------
  -- Ein laufender Upload hat Vorrang. Er ist keine Warnung, sondern der
  -- einzige Zustand, in dem hier etwas passiert, das man verfolgen will.
  if running then
    backup:set({
      drawing = true,
      update_freq = UPDATE_FREQ_RUNNING,
      icon = { string = icons.wifi.upload, color = colors.blue },
      label = { string = short_progress(oprogress, ostarted), color = colors.blue },
    })
    return
  end

  if ostatus == "error" then
    backup:set({
      drawing = true,
      update_freq = UPDATE_FREQ,
      icon = { string = icons.wifi.upload, color = colors.red },
      label = { string = "Fehler", color = colors.red },
    })
    return
  end

  -- Ohne Zeitstempel gab es nie ein erfolgreiches Backup. Das ist ein frisch
  -- aufgesetzter Rechner, kein Ausfall -- dieselbe Unterscheidung trifft das
  -- Snapshot-Skript, bevor es überhaupt zu warnen anfängt.
  local snap_color = ts and color_for((now - ts) / 86400, WARN_DAYS, ALERT_DAYS, CRIT_DAYS) or nil

  if snap_color then
    backup:set({
      drawing = true,
      update_freq = UPDATE_FREQ,
      icon = { string = "􀤃", color = snap_color },
      label = { string = short_age(now - ts), color = snap_color },
    })
    return
  end

  -- Der lokale Stand ist frisch, die Offsite-Kopie nicht: der Pfeil statt der
  -- Platte sagt, welche der beiden gemeint ist.
  if off_warn then
    backup:set({
      drawing = true,
      update_freq = UPDATE_FREQ,
      icon = { string = icons.wifi.upload, color = off_warn },
      label = { string = short_age(off_age), color = off_warn },
    })
    return
  end

  backup:set({ drawing = false, update_freq = UPDATE_FREQ, popup = { drawing = false } })
end

local function update()
  sbar.exec(PROBE, apply)
end

-- system_woke zählt hier besonders: nach Tagen mit zugeklapptem Deckel soll die
-- Warnung sofort stimmen und nicht erst mit dem nächsten routine-Tick.
backup:subscribe({ "routine", "forced", "system_woke" }, update)

update()
