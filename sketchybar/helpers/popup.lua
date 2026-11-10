-- Bausteine für Popups im Stil der macOS-Systemmenüs (Wetter, Akku, WLAN):
-- feste Breite, 16 Punkt Einzug, Listenzeilen in SF Pro, gedämpfte
-- Beschriftung links, Wert rechts, Haarlinien zwischen den Abschnitten.
--
-- Eine Zeile ist ein Item: Beschriftung im icon-Feld, Wert im label. Die
-- Zeilenhöhe ist bei mbar max(Item, popup.height); M.host() setzt
-- popup.height deshalb auf 1, und jede Zeile bringt ihre Höhe über einen
-- unsichtbaren Hintergrund selbst mit. Nur so können Kopf, Listen und
-- Haarlinien verschieden hoch sein.

local colors = require("colors")
local settings = require("settings")

local M = {}

M.INSET = 16
M.WIDTH = 300
M.ROW_HEIGHT = 26
M.FONT_SIZE = 13.0

function M.font(style, size)
  return { family = settings.font.text, style = style or "Regular", size = size or M.FONT_SIZE }
end

-- popup-Tabelle für das Eltern-Item.
function M.host(align)
  return { align = align or "right", height = 1 }
end

local function merge(dst, src)
  for k, v in pairs(src or {}) do dst[k] = v end
  return dst
end

-- Listenzeile. opts: width (ganze Zeile), caption_width, height, drawing,
-- caption_font, value_font, caption_color, value_color, click_script.
-- Die Feldbreiten schließen ihr Polster ein.
function M.row(parent, name, opts)
  opts = opts or {}
  local width = opts.width or M.WIDTH
  local caption = opts.caption_width or math.floor((width - 2 * M.INSET) / 2)
  return sbar.add("item", name, {
    position = "popup." .. parent,
    drawing = opts.drawing or false,
    width = width,
    padding_left = 0,
    padding_right = 0,
    -- Rahmen und Rundung aus default.lua gelten Bar-Items, nicht Zeilen.
    background = {
      drawing = true,
      color = colors.transparent,
      border_width = 0,
      corner_radius = 0,
      height = opts.height or M.ROW_HEIGHT,
      image = { border_width = 0, corner_radius = 0 },
    },
    icon = {
      string = "",
      width = M.INSET + caption,
      align = "left",
      color = opts.caption_color or colors.popup.caption,
      padding_left = M.INSET,
      padding_right = 0,
      font = opts.caption_font or M.font(),
      background = { drawing = false },
    },
    label = {
      string = "",
      width = width - M.INSET - caption,
      align = "right",
      color = opts.value_color or colors.white,
      padding_left = 0,
      padding_right = M.INSET,
      font = opts.value_font or M.font(),
    },
    click_script = opts.click_script,
  })
end

-- Kopfzeile: fetter Titel links, Zusatz rechts (Prozent, Anzahl, Zustand).
function M.header(parent, name, opts)
  return M.row(parent, name, merge({
    height = 30,
    caption_color = colors.white,
    caption_font = M.font("Bold", 14.0),
    value_font = M.font("Semibold", 12.0),
    value_color = colors.popup.caption,
  }, opts))
end

-- Abschnittstitel wie "Bevorzugte Netzwerke": klein, fett, gedämpft.
function M.section(parent, name, opts)
  return M.row(parent, name, merge({
    height = 22,
    caption_font = M.font("Semibold", 11.0),
    value_font = M.font("Semibold", 11.0),
    value_color = colors.popup.caption,
  }, opts))
end

-- Zeile, die etwas öffnet ("Aktivitätsanzeige öffnen …"): weißer Text, kein Wert.
function M.action(parent, name, text, click_script, opts)
  local item = M.row(parent, name, merge({
    drawing = true,
    caption_color = colors.white,
    click_script = click_script,
  }, opts))
  item:set({ icon = { string = text } })
  return item
end

-- Haarlinie, links und rechts eingerückt; ohne Farbe ein Abstandhalter.
-- opts: width (ganze Zeile), color, height, drawing.
function M.rule(parent, name, opts)
  opts = opts or {}
  return sbar.add("item", name, {
    position = "popup." .. parent,
    drawing = opts.drawing or false,
    width = (opts.width or M.WIDTH) - 2 * M.INSET,
    padding_left = M.INSET,
    padding_right = M.INSET,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      drawing = true,
      color = opts.color or colors.popup.hairline,
      border_width = 0,
      corner_radius = 0,
      height = opts.height or 1,
      image = { drawing = false },
    },
  })
end

-- Unsichtbarer Abstand, oben und unten im Popup (8 bzw. 6 Punkt).
function M.gap(parent, name, height, opts)
  return M.rule(parent, name, merge({ color = colors.transparent, height = height }, opts))
end

return M
