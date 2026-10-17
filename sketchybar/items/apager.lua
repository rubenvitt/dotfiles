local colors = require("colors")

-- Einsatzalarm: die ganze Bar blinkt rot, solange der apager-Dialog offen ist,
-- damit der Alarm auch aus ein paar Metern Abstand auffällt. Der Listener
-- (r-tools/apager-listener.py) triggert apager_alarm mit ACTIVE=1 bei jedem
-- Alarm und ACTIVE=0, sobald quittiert ist.
-- shortcut: ein --reload mitten im Alarm vergisst ihn, die Bar blinkt erst beim
-- nächsten wieder -- der Dialog bleibt ja offen. Nachrüsten, falls das stört.

local BLINK_SECONDS = 0.6

sbar.add("event", "apager_alarm")

local watch = sbar.add("item", "apager", {
  drawing = false,
  updates = true,
})

local active = false
-- Jeder Alarm startet eine neue Blinkschleife; ältere Schleifen erkennen an
-- der Generation, dass sie abgelöst sind, und hören auf.
local generation = 0

local function blink(gen, red)
  if not active or gen ~= generation then return end
  sbar.bar({ color = red and colors.red or colors.bar.bg })
  sbar.delay(BLINK_SECONDS, function() blink(gen, not red) end)
end

watch:subscribe("apager_alarm", function(env)
  active = env.ACTIVE == "1"
  generation = generation + 1
  if active then
    blink(generation, true)
  else
    sbar.bar({ color = colors.bar.bg })
  end
end)
