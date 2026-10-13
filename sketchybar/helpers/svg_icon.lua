-- Icons8-Symbole als eingefärbte SVGs, mit der Glyphe aus icons.lua als Rückfall.
--
-- Die SVGs liegen außerhalb des öffentlichen Repos in ~/.config/mbar/icons/<name>.svg;
-- welches Icons8-Symbol hinter einem Namen steht, sagt icons8.tsv. Entwurf:
-- docs/2026-10-13-icons8-design.md. mbar (ab 0.8) färbt das Bild über
-- background.image.color ein, deshalb steht die Farbe dort statt in icon.color.

local colors = require("colors")
local icons = require("icons")

local M = {}

M.dir = (os.getenv("HOME") or "") .. "/.config/mbar/icons/"

-- Einmal je Name beim Laden der Config; neue Dateien wirken nach `sbar`.
local found = {}

function M.path(name)
  if found[name] == nil then
    local p = M.dir .. name .. ".svg"
    local f = io.open(p)
    found[name] = f and p or false
    if f then f:close() end
  end
  return found[name] or nil
end

-- "battery._75" -> icons.battery._75
function M.glyph(name)
  local v = icons
  for part in string.gmatch(name, "[^.]+") do
    v = type(v) == "table" and v[part] or nil
  end
  return type(v) == "string" and v or ""
end

-- Vollständige icon-Tabelle für `name` in `color`; `extra` (Schrift, Abstände …)
-- wird übernommen. Beide Varianten setzen string und background ausdrücklich,
-- damit ein Wechsel zwischen SVG und Glyphe keine Reste stehen lässt.
function M.icon(name, color, extra)
  local t = {}
  for k, v in pairs(extra or {}) do t[k] = v end
  local p = M.path(name)
  if p then
    t.string = ""
    t.background = {
      drawing = true,
      color = colors.transparent,
      image = { string = p, color = color },
    }
  else
    t.string = M.glyph(name)
    t.color = color
    t.background = { drawing = false }
  end
  return t
end

-- Breite des SVG in pt (width-Attribut, beim Abruf gesetzt); 0 ohne Datei.
local sizes = {}
function M.size(name)
  if sizes[name] == nil then
    local p, w = M.path(name), 0
    local f = p and io.open(p)
    if f then
      w = tonumber(string.match(f:read(512) or "", 'width="([%d.]+)"')) or 0
      f:close()
    end
    sizes[name] = w
  end
  return sizes[name]
end

-- Das Bild steht immer am linken Rand des Hintergrunds (SketchyBar ignoriert
-- align dafür). Für rechtsbündige Felder fester Breite schiebt das hier es
-- nach rechts; `pad` ist der Abstand zum rechten Rand.
function M.align_right(t, name, width, pad)
  if t.string == "" then
    t.background.image.padding_left = math.max(0, width - M.size(name) - (pad or 0))
  end
  return t
end

-- Nur die Farbe, für Zustandswechsel ohne neues Bild.
function M.color(name, color)
  if M.path(name) then
    return { background = { image = { color = color } } }
  end
  return { color = color }
end

return M
