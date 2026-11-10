local colors = require("colors")
local icons = require("icons")
local svg = require("helpers.svg_icon")
local settings = require("settings")
local popup = require("helpers.popup")

local MAX_DEVICES = 8

-- Kompakt-Modus: nur das Lautsprecher-Icon, die Prozentzahl steckt im Popup-Slider.
local volume_percent = sbar.add("item", "widgets.volume1", {
  display = settings.primary_display,
  position = "right",
  drawing = not settings.compact,
  icon = { drawing = false },
  label = {
    string = "??%",
    padding_left = -1,
    font = { family = settings.font.numbers }
  },
})

local volume_icon = sbar.add("item", "widgets.volume2", {
  display = settings.primary_display,
  position = "right",
  padding_right = settings.compact and 4 or -1,
  -- Grauer voller Lautsprecher als Hintergrund, der aktuelle Stand liegt
  -- weiß im Label darüber.
  icon = svg.icon("volume._100", colors.grey, {
    width = 0,
    align = "left",
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  }),
  label = {
    width = 25,
    align = "left",
    font = {
      style = settings.font.style_map["Regular"],
      size = 14.0,
    },
  },
})

local volume_bracket = sbar.add("bracket", "widgets.volume.bracket", {
  volume_icon.name,
  volume_percent.name
}, {
  display = settings.primary_display,
  background = { color = colors.bg1 },
  popup = popup.host("center"),
})

sbar.add("item", "widgets.volume.padding", {
  display = settings.primary_display,
  position = "right",
  width = settings.group_paddings
})

-- Popup wie das Tonmenü von macOS (helpers/popup.lua): Regler, darunter die
-- Ausgabegeräte mit Haken am aktiven.
local P = volume_bracket.name
popup.gap(P, "widgets.volume.gap.top", 6, { drawing = true })
popup.header(P, "widgets.volume.header", { drawing = true }):set({ icon = { string = "Ton" } })

local volume_slider = sbar.add("slider", popup.WIDTH - 2 * popup.INSET, {
  position = "popup." .. P,
  padding_left = popup.INSET,
  padding_right = popup.INSET,
  slider = {
    highlight_color = colors.white,
    background = {
      height = 6,
      corner_radius = 3,
      color = colors.popup.hairline,
    },
    knob = {
      string = "􀀁",
      drawing = true,
    },
  },
  background = { drawing = true, color = colors.transparent, border_width = 0, height = 32 },
  click_script = 'osascript -e "set volume output volume $PERCENTAGE"'
})

popup.rule(P, "widgets.volume.rule.devices", { drawing = true })
popup.section(P, "widgets.volume.section", { drawing = true }):set({ icon = { string = "Ausgabe" } })

-- Feste Reserve statt neuer Items je Öffnen (siehe items/menus.lua): neu
-- angelegte Zeilen landeten hinter den Einstellungen am Ende des Popups.
local device_rows, device_names = {}, {}
for i = 1, MAX_DEVICES do
  device_rows[i] = popup.row(P, "widgets.volume.device." .. i, {
    caption_width = popup.WIDTH - 2 * popup.INSET - 30,
    caption_color = colors.white,
  })
  device_rows[i]:subscribe("mouse.clicked", function()
    local name = device_names[i]
    if not name then return end
    -- Der Gerätename landet in einer Shell: in einfache Anführungszeichen,
    -- eingebettete ' als '\''.
    sbar.exec("SwitchAudioSource -s '" .. name:gsub("'", "'\\''") .. "'")
    for j = 1, MAX_DEVICES do
      device_rows[j]:set({ label = { string = j == i and "✓" or "" } })
    end
  end)
end

popup.rule(P, "widgets.volume.rule.settings", { drawing = true })
popup.action(P, "widgets.volume.settings", "Toneinstellungen …",
  "open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'; " ..
  "sketchybar --set " .. P .. " popup.drawing=off")
popup.gap(P, "widgets.volume.gap.bottom", 6, { drawing = true })

volume_icon:subscribe("volume_change", function(env)
  local volume = tonumber(env.INFO)
  local icon = "volume._0"
  if volume > 60 then
    icon = "volume._100"
  elseif volume > 30 then
    icon = "volume._66"
  elseif volume > 10 then
    icon = "volume._33"
  elseif volume > 0 then
    icon = "volume._10"
  end

  local lead = ""
  if volume < 10 then
    lead = "0"
  end

  -- Das Lautsprechersymbol steht im Label, das Icon ist nur ein Platzhalter.
  volume_icon:set({ label = svg.icon(icon, colors.white) })
  volume_percent:set({ label = lead .. volume .. "%" })
  volume_slider:set({ slider = { percentage = volume } })
end)

local function volume_collapse_details()
  volume_bracket:set({ popup = { drawing = false } })
end

local function volume_toggle_details(env)
  if env.BUTTON == "right" then
    sbar.exec("open /System/Library/PreferencePanes/Sound.prefpane")
    return
  end

  if volume_bracket:query().popup.drawing == "on" then
    volume_collapse_details()
    return
  end
  volume_bracket:set({ popup = { drawing = true } })
  sbar.exec("SwitchAudioSource -t output -c", function(result)
    local current = result:sub(1, -2)
    sbar.exec("SwitchAudioSource -a -t output", function(available)
      local n = 0
      for device in string.gmatch(available, "[^\r\n]+") do
        n = n + 1
        if n > MAX_DEVICES then break end
        device_names[n] = device
        device_rows[n]:set({
          drawing = true,
          icon = { string = device },
          label = { string = device == current and "✓" or "" },
        })
      end
      for i = n + 1, MAX_DEVICES do
        device_names[i] = nil
        device_rows[i]:set({ drawing = false })
      end
    end)
  end)
end

local function volume_scroll(env)
  local delta = env.SCROLL_DELTA
  sbar.exec('osascript -e "set volume output volume (output volume of (get volume settings) + ' .. delta .. ')"')
end

volume_icon:subscribe("mouse.clicked", volume_toggle_details)
volume_icon:subscribe("mouse.scrolled", volume_scroll)
volume_percent:subscribe("mouse.clicked", volume_toggle_details)
volume_percent:subscribe("mouse.exited.global", volume_collapse_details)
volume_percent:subscribe("mouse.scrolled", volume_scroll)

