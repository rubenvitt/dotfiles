local colors = require("colors")
local icons = require("icons")
local svg = require("helpers.svg_icon")
local settings = require("settings")
local otp = require("helpers.otp")

-- Einmalcode aus der letzten SMS, links neben der Uhr. Unsichtbar, bis eine
-- Nachricht mit Code ankommt; dann liegt er sofort in der Zwischenablage.
-- Linksklick kopiert ihn noch einmal und blendet ihn aus, Rechtsklick blendet
-- ihn nur aus. Nach MAX_AGE verschwindet er von selbst --
-- ein Einmalcode ist dann ohnehin abgelaufen.
--
-- Quelle ist die Nachrichten-Datenbank, in die die SMS-Weiterleitung vom
-- iPhone schreibt. chat.db ist durch den Festplattenvollzugriff geschützt, und
-- macOS rechnet den Zugriff dem verantwortlichen Prozess zu: sqlite3 darf hier
-- lesen, wenn mbar.app in Systemeinstellungen → Datenschutz & Sicherheit →
-- Festplattenvollzugriff eingetragen ist. Ein Neustart der Bar ist danach
-- nicht nötig. Fehlt die Freigabe, steht das einmal in ~/Library/Logs/mbar.log.
--
-- Was ein Code ist, entscheidet helpers/otp.lua (Selbsttest: otp_test.lua).
-- Nachrichtentexte verlassen dieses Item nie; auf der Platte liegt nur die
-- Nummer der zuletzt weggeklickten Nachricht, damit ein --reload sie nicht
-- zurückholt.

local DB = os.getenv("HOME") .. "/Library/Messages/chat.db"
local STATE_DIR = os.getenv("HOME") .. "/.cache/sketchybar"
local STATE_FILE = STATE_DIR .. "/sms_code_dismissed"

-- Ein Code gilt bei den meisten Absendern 5 bis 10 Minuten.
local MAX_AGE = 600
-- Abfrage per ROWID über den Primärschlüssel; meist kommt nichts zurück.
-- Höchstens so viele Nachrichten zurück wird gesucht: ohne Untergrenze läse
-- jede Abfrage vor der ersten neuen Nachricht die ganze Tabelle (~150 ms).
local LOOKBACK_ROWS = 200
local POLL = 3
local COPIED_SECONDS = 1.5

-- Datum in chat.db: Nanosekunden seit 2001-01-01.
local APPLE_EPOCH = 978307200

local function read_dismissed()
  local f = io.open(STATE_FILE, "r")
  if not f then return 0 end
  local n = tonumber(f:read("l") or "") or 0
  f:close()
  return n
end

local function write_dismissed(rowid)
  local f = io.open(STATE_FILE, "w")
  if not f then return end
  f:write(tostring(rowid), "\n")
  f:close()
end

sbar.exec("mkdir -p '" .. STATE_DIR .. "'")

local last_seen = read_dismissed()
local current     -- { rowid, at, code }
local copied = false
local last_error
-- Erst ab der zweiten Abfrage wird automatisch kopiert: die erste holt nach
-- einem --reload Codes der letzten Minuten zurück, und die sollen die
-- Zwischenablage nicht überschreiben.
local primed = false

local item = sbar.add("item", "sms_code", {
  position = "right",
  display = settings.primary_display,
  drawing = false,
  updates = "on",
  update_freq = POLL,
  icon = svg.icon("sms", colors.green, { padding_left = 8 }),
  label = {
    color = colors.white,
    padding_right = 8,
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
    },
  },
  background = {
    color = colors.bg2,
    border_color = colors.black,
    border_width = 1,
  },
})

local function render()
  local now = os.time()
  if current and now - current.at >= MAX_AGE then current = nil end
  if not current then
    item:set({ drawing = false })
    return
  end
  local label = copied and "kopiert" or current.code
  item:set({ drawing = true, label = { string = label } })
end

-- -ascii trennt Felder mit 0x1F und Zeilen mit 0x1E: SMS-Text darf
-- Zeilenumbrüche enthalten, ohne die Ausgabe zu zerlegen.
-- shortcut: nur m.text; Nachrichten, deren Text allein in attributedBody
-- steht (manche iMessages), werden übersprungen -- erst nachrüsten, wenn ein
-- Code deshalb fehlt.
local function query()
  return "/usr/bin/sqlite3 -readonly -ascii -cmd '.timeout 500' '" .. DB .. "' \""
    .. "SELECT m.ROWID, m.date / 1000000000 + " .. APPLE_EPOCH .. ", m.text"
    .. " FROM message m"
    .. " WHERE m.ROWID > max(" .. last_seen .. ","
    .. " (SELECT max(ROWID) FROM message) - " .. LOOKBACK_ROWS .. ")"
    .. " AND m.is_from_me = 0 AND m.text IS NOT NULL"
    .. " AND m.date > (strftime('%s', 'now') - " .. (APPLE_EPOCH + MAX_AGE) .. ") * 1000000000"
    .. " ORDER BY m.ROWID\" 2>&1"
end

-- otp.extract liefert nur [%w-]+, das Zitat bleibt also dicht.
local function copy(code)
  sbar.exec("printf %s '" .. code .. "' | pbcopy")
  copied = true
  sbar.delay(COPIED_SECONDS, function()
    copied = false
    render()
  end)
end

local function apply(_, out)
  out = out or ""
  if out:find("^Error") or out:find("authorization denied") then
    local msg = out:gsub("%s+$", "")
    if msg ~= last_error then
      print("sms_code: " .. msg .. " -- fehlt mbar.app der Festplattenvollzugriff?")
      last_error = msg
    end
    return
  end
  last_error = nil
  local fresh
  for rec in out:gmatch("([^\30]*)\30") do
    local rowid, at, text = rec:match("^(%d+)\31(%d+)\31(.*)$")
    rowid = tonumber(rowid)
    if rowid then
      last_seen = math.max(last_seen, rowid)
      local code = otp.extract(text)
      if code then
        current = { rowid = rowid, at = tonumber(at), code = code }
        fresh = primed
      end
    end
  end
  primed = true
  if fresh then copy(current.code) end
  render()
end

local function update()
  sbar.exec(query(), apply)
end

local function dismiss()
  if current then write_dismissed(current.rowid) end
  current = nil
  render()
end

item:subscribe({ "routine", "forced", "system_woke" }, update)

item:subscribe("mouse.clicked", function(env)
  if not current then return end
  if env.BUTTON == "right" then
    dismiss()
    return
  end
  copy(current.code)
  render()
  local rowid = current.rowid
  -- Nur den kopierten Code ausblenden, nicht einen inzwischen neueren.
  sbar.delay(COPIED_SECONDS, function()
    if current and current.rowid == rowid then dismiss() end
  end)
end)

update()
