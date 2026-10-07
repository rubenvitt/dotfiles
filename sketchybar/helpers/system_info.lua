-- Systemwerte, die die Config beim Aufbau der Items synchron braucht.
--
-- Warum das hier steht und nicht dort, wo es gebraucht wird:
-- `sbar.exec` forkt den Lua-Prozess (im Callback-Fall forkt es sogar ohne
-- exec und laesst das Kind als Kopie weiterlaufen). Sobald das einmal
-- passiert ist, haengt ein spaeteres `io.popen(...):close()` im selben
-- Prozess reproduzierbar in `pclose()` -> `wait4()`: gemessen am 25.08.2026
-- kostete der `sysctl`-Aufruf in items/widgets/cpu_cores.lua so 6-7 Sekunden
-- pro Reload, in schlechten Faellen kam die Config gar nicht mehr durch und
-- die Bar blieb bei den Werkseinstellungen stehen — ohne Fehlermeldung.
--
-- helpers/init.lua zieht dieses Modul deshalb ganz am Anfang herein, bevor
-- `sbar` ueberhaupt geladen ist und damit vor dem ersten Fork. Der require-
-- Cache sorgt dafuer, dass der Aufruf genau einmal passiert.

local function sysctl(key)
  local handle = io.popen("sysctl -n " .. key .. " 2>/dev/null")
  if not handle then return nil end
  local out = handle:read("*a")
  handle:close()
  return tonumber(out)
end

local cpu_count = sysctl("hw.ncpu") or 8

-- Auf homogenen CPUs existiert perflevel1 nicht; ein Wert, der alle Kerne
-- umfasst, waere ebenso unbrauchbar wie keiner.
local efficiency_cores = sysctl("hw.perflevel1.logicalcpu") or 0
if efficiency_cores >= cpu_count then efficiency_cores = 0 end

-- Breite des breitesten Displays in Punkten. Am Schreibtisch haengt ein
-- externer Monitor (>= 2560), unterwegs nur das MBP-Panel (2056 auf dem 16").
-- Daraus leitet settings.lua den Kompakt-Modus ab, damit die rechte Seite
-- der Bar nicht in die Notch laeuft.
-- Unter mbar läuft die Config im Daemon selbst: ein io.popen auf den eigenen
-- Client bricht dort sofort ab, die Abfrage geht direkt über mbar.query.
local has_mbar, mbar = pcall(require, "mbar")

local function display_width()
  if has_mbar then
    local widest
    for _, display in ipairs(mbar.query("displays") or {}) do
      local w = display.frame and tonumber(display.frame.w)
      if w and (not widest or w > widest) then widest = w end
    end
    return widest
  end

  local handle = io.popen("sketchybar --query displays 2>/dev/null")
  if not handle then return nil end
  local out = handle:read("*a")
  handle:close()
  local widest
  for w in out:gmatch('"w":%s*([%d%.]+)') do
    local n = tonumber(w)
    if n and (not widest or n > widest) then widest = n end
  end
  return widest
end

local width = display_width() or 3000

return {
  cpu_count = cpu_count,
  efficiency_cores = efficiency_cores,
  display_width = width,
  compact = width < 2500,
}
