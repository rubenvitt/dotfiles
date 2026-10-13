-- Selbsttest für helpers/svg_icon.lua:  lua ~/.config/sketchybar/helpers/svg_icon_test.lua

package.path = arg[0]:gsub("[^/]+$", "") .. "?.lua;" .. package.path
package.preload["colors"] = function() return { transparent = 0 } end
package.preload["icons"] = function()
  return { battery = { _75 = "B75", _25 = "B25" }, warning = "W" }
end
local svg = require("svg_icon")

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p " .. dir)
svg.dir = dir .. "/"
local f = assert(io.open(svg.dir .. "battery._75.svg", "w"))
f:write("<svg/>")
f:close()

local failed = 0
local function check(what, got, want)
  if got ~= want then
    failed = failed + 1
    print(string.format("FAIL %s: %s (erwartet %s)", what, tostring(got), tostring(want)))
  end
end

local with = svg.icon("battery._75", 0xffff0000, { padding_right = 4 })
check("svg: string leer", with.string, "")
check("svg: Bild", with.background.image.string, svg.dir .. "battery._75.svg")
check("svg: Farbe am Bild", with.background.image.color, 0xffff0000)
check("svg: keine icon.color", with.color, nil)
check("svg: extra übernommen", with.padding_right, 4)

local without = svg.icon("battery._25", 0xff00ff00)
check("glyphe: string", without.string, "B25")
check("glyphe: Farbe", without.color, 0xff00ff00)
check("glyphe: Hintergrund aus", without.background.drawing, false)

check("unbekannter Name", svg.icon("gibt.es_nicht", 1).string, "")
check("color mit svg", svg.color("battery._75", 7).background.image.color, 7)
check("color ohne svg", svg.color("warning", 7).color, 7)

os.remove(svg.dir .. "battery._75.svg")
os.remove(dir)
print(failed == 0 and "ok" or (failed .. " Fehler"))
os.exit(failed == 0)
