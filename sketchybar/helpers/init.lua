-- Add the sketchybar module to the package cpath
package.cpath = package.cpath .. ";/Users/" .. os.getenv("USER") .. "/.local/share/sketchybar_lua/?.so"

os.execute("(cd helpers && make)")

-- Muss hier stehen, nicht erst beim Item, das die Werte braucht: sobald der
-- erste sbar.exec den Lua-Prozess geforkt hat, haengt io.popen in pclose().
-- Begruendung ausfuehrlich in helpers/system_info.lua.
require("helpers.system_info")
