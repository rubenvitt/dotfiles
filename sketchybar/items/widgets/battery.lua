local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- Off the charger the battery widget blinks in two stages: slow and orange
-- as an early warning, fast and red when it is nearly empty.
local BLINK_STAGES = {
  { threshold = 10, color = colors.red, interval = 0.6 },
  { threshold = 20, color = colors.orange, interval = 1.5 },
}

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
  popup = { align = "center" }
})

local remaining_time = sbar.add("item", {
  position = "popup." .. battery.name,
  icon = {
    string = "Time remaining:",
    width = 100,
    align = "left"
  },
  label = {
    string = "??:??h",
    width = 100,
    align = "right"
  },
})

local bracket = sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  display = settings.primary_display,
  background = { color = colors.bg1 }
})

-- Each start bumps the generation, so a stale loop from an earlier start
-- stops on its next tick instead of blinking twice as fast.
local blink_generation = 0
local blink_stage = nil
local normal_color = colors.red

local function blink_stage_for(charge)
  for _, stage in ipairs(BLINK_STAGES) do
    if charge <= stage.threshold then return stage end
  end
  return nil
end

local function blink_tick(generation, lit)
  if generation ~= blink_generation then return end
  bracket:set({ background = { color = lit and blink_stage.color or colors.bg1 } })
  battery:set({
    icon = { color = lit and colors.black or normal_color },
    label = { color = lit and colors.black or colors.white },
  })
  sbar.delay(blink_stage.interval, function() blink_tick(generation, not lit) end)
end

local function set_blink_stage(stage)
  if stage == blink_stage then return end
  blink_stage = stage
  blink_generation = blink_generation + 1
  if stage then
    blink_tick(blink_generation, true)
  else
    bracket:set({ background = { color = colors.bg1 } })
    battery:set({ label = { color = colors.white } })
  end
end

battery:subscribe({"routine", "power_source_change", "system_woke"}, function()
  sbar.exec("pmset -g batt", function(batt_info)
    local icon = "!"
    local label = "?"

    local found, _, charge = batt_info:find("(%d+)%%")
    if found then
      charge = tonumber(charge)
      label = charge .. "%"
    end

    local color = colors.green
    local charging, _, _ = batt_info:find("AC Power")

    if charging then
      icon = icons.battery.charging
    else
      if found and charge > 80 then
        icon = icons.battery._100
      elseif found and charge > 60 then
        icon = icons.battery._75
      elseif found and charge > 40 then
        icon = icons.battery._50
      elseif found and charge > 20 then
        icon = icons.battery._25
        color = colors.orange
      else
        icon = icons.battery._0
        color = colors.red
      end
    end

    local lead = ""
    if found and charge < 10 then
      lead = "0"
    end

    normal_color = color
    local stage = (found and not charging) and blink_stage_for(charge) or nil
    local icon_props = { string = icon }
    -- While blinking, blink_tick owns the colour.
    if not (stage and blink_stage) then icon_props.color = color end
    battery:set({
      icon = icon_props,
      label = { string = lead .. label },
    })
    set_blink_stage(stage)
  end)
end)

battery:subscribe("mouse.clicked", function(env)
  local drawing = battery:query().popup.drawing
  battery:set( { popup = { drawing = "toggle" } })

  if drawing == "off" then
    sbar.exec("pmset -g batt", function(batt_info)
      local found, _, remaining = batt_info:find(" (%d+:%d+) remaining")
      local label = found and remaining .. "h" or "No estimate"
      remaining_time:set( { label = label })
    end)
  end
end)

sbar.add("item", "widgets.battery.padding", {
  display = settings.primary_display,
  position = "right",
  width = settings.group_paddings
})
