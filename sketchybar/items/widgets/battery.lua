local svg = require("helpers.svg_icon")
local colors = require("colors")
local settings = require("settings")
local popup = require("helpers.popup")

-- Off the charger the battery widget blinks in two stages: slow and orange
-- as an early warning, fast and red when it is nearly empty.
local BLINK_STAGES = {
  { threshold = 10, color = colors.red, interval = 0.6 },
  { threshold = 20, color = colors.orange, interval = 1.5 },
}

-- While it actually charges, the icon breathes gently between full and dim.
local CHARGING_PULSE = { interval = 2.5, frames = 120, dim = 0.65 }

local battery = sbar.add("item", "widgets.battery", {
  display = settings.primary_display,
  position = "right",
  icon = {
    font = {
      style = settings.font.style_map["Regular"],
      size = 19.0,
    }
  },
  label = { font = { family = settings.font.numbers } },
  update_freq = 180,
  popup = popup.host("center"),
})

-- Popup wie das Akkumenü von macOS (helpers/popup.lua).
local P = battery.name
popup.gap(P, "widgets.battery.gap.top", 6, { drawing = true })
local header = popup.header(P, "widgets.battery.header", { drawing = true })
header:set({ icon = { string = "Akku" } })
popup.rule(P, "widgets.battery.rule.state", { drawing = true })
local source_row = popup.row(P, "widgets.battery.source", { drawing = true })
source_row:set({ icon = { string = "Stromquelle" } })
local remaining_time = popup.row(P, "widgets.battery.remaining", { drawing = true })
remaining_time:set({ icon = { string = "Restzeit" }, label = { string = "…" } })
popup.rule(P, "widgets.battery.rule.settings", { drawing = true })
popup.action(P, "widgets.battery.settings", "Batterieeinstellungen …",
  "open 'x-apple.systempreferences:com.apple.Battery-Settings.extension'; " ..
  "sketchybar --set " .. P .. " popup.drawing=off")
popup.gap(P, "widgets.battery.gap.bottom", 6, { drawing = true })

local bracket = sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  display = settings.primary_display,
  background = { color = colors.bg1 }
})

-- The running animation: a BLINK_STAGES entry, CHARGING_PULSE or nil.
-- Each start bumps the generation, so a stale loop from an earlier start
-- stops on its next tick instead of running twice as fast.
local animation_generation = 0
local animation = nil
local normal_color = colors.red
-- Name des angezeigten Symbols, für Farbwechsel ohne neues Bild.
local icon_name = "battery._100"

local function blink_stage_for(charge)
  for _, stage in ipairs(BLINK_STAGES) do
    if charge <= stage.threshold then return stage end
  end
  return nil
end

local function blink_tick(generation, lit)
  if generation ~= animation_generation then return end
  bracket:set({ background = { color = lit and animation.color or colors.bg1 } })
  battery:set({
    icon = svg.color(icon_name, lit and colors.black or normal_color),
    label = { color = lit and colors.black or colors.white },
  })
  sbar.delay(animation.interval, function() blink_tick(generation, not lit) end)
end

local function pulse_tick(generation, dim)
  if generation ~= animation_generation then return end
  sbar.animate("sin", CHARGING_PULSE.frames, function()
    battery:set({
      icon = svg.color(icon_name, dim and colors.with_alpha(normal_color, CHARGING_PULSE.dim) or normal_color),
    })
  end)
  sbar.delay(CHARGING_PULSE.interval, function() pulse_tick(generation, not dim) end)
end

local function set_animation(next_animation)
  if next_animation == animation then return end
  animation = next_animation
  animation_generation = animation_generation + 1
  bracket:set({ background = { color = colors.bg1 } })
  battery:set({ label = { color = colors.white } })
  if animation == CHARGING_PULSE then
    pulse_tick(animation_generation, true)
  elseif animation then
    blink_tick(animation_generation, true)
  end
end

battery:subscribe({"routine", "power_source_change", "system_woke"}, function()
  sbar.exec("pmset -g batt", function(batt_info)
    local icon = "battery._0"
    local label = "?"

    local found, _, charge = batt_info:find("(%d+)%%")
    if found then
      charge = tonumber(charge)
      label = charge .. "%"
    end

    local color = colors.green
    local charging, _, _ = batt_info:find("AC Power")

    if charging then
      icon = "battery.charging"
    else
      if found and charge > 80 then
        icon = "battery._100"
      elseif found and charge > 60 then
        icon = "battery._75"
      elseif found and charge > 40 then
        icon = "battery._50"
      elseif found and charge > 20 then
        icon = "battery._25"
        color = colors.orange
      else
        icon = "battery._0"
        color = colors.red
      end
    end

    local lead = ""
    if found and charge < 10 then
      lead = "0"
    end

    normal_color = color
    local next_animation = nil
    if charging then
      -- "; discharging" does not match, "AC attached; not charging" neither.
      if batt_info:find("; charging") then next_animation = CHARGING_PULSE end
    elseif found then
      next_animation = blink_stage_for(charge)
    end
    icon_name = icon
    -- A running animation owns the icon colour.
    local owned = next_animation and next_animation == animation
    local icon_props = svg.icon(icon, not owned and color or nil)
    battery:set({
      icon = icon_props,
      label = { string = lead .. label },
    })
    set_animation(next_animation)
  end)
end)

battery:subscribe("mouse.clicked", function(env)
  local drawing = battery:query().popup.drawing
  if drawing == "off" then popup.close_others(P) end
  battery:set( { popup = { drawing = "toggle" } })

  if drawing == "off" then
    sbar.exec("pmset -g batt", function(batt_info)
      local charge = batt_info:match("(%d+)%%")
      local remaining = batt_info:match(" (%d+:%d+) remaining")
      local on_ac = batt_info:find("AC Power") ~= nil
      header:set({ label = { string = charge and (charge .. " %") or "" } })
      source_row:set({ label = { string = on_ac and "Netzteil" or "Akku" } })
      -- 0:00 meldet pmset, solange es noch rechnet.
      remaining_time:set({
        drawing = not on_ac or (remaining ~= nil and remaining ~= "0:00"),
        icon = { string = on_ac and "Bis voll" or "Restzeit" },
        label = { string = (remaining and remaining ~= "0:00") and (remaining .. " h") or "wird berechnet" },
      })
    end)
  end
end)

sbar.add("item", "widgets.battery.padding", {
  display = settings.primary_display,
  position = "right",
  width = settings.group_paddings
})
