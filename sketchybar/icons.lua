local settings = require("settings")

local icons = {
  sf_symbols = {
    plus = "􀅼",
    loading = "􀖇",
    apple = "􀣺",
    gear = "􀍟",
    cpu = "􀫥",
    clipboard = "􀉄",

    switch = {
      on = "􁏮",
      off = "􁏯",
    },
    volume = {
      _100="􀊩",
      _66="􀊧",
      _33="􀊥",
      _10="􀊡",
      _0="􀊣",
    },
    battery = {
      _100 = "􀛨",
      _75 = "􀺸",
      _50 = "􀺶",
      _25 = "􀛩",
      _0 = "􀛪",
      charging = "􀢋"
    },
    wifi = {
      upload = "􀄨",
      download = "􀄩",
      connected = "􀙇",
      disconnected = "􀙈",
      router = "􁓤",
    },
    memory = {
      ram = "􀫦",
      disk = "􀥾",
    },
    media = {
      back = "􀊊",
      forward = "􀊌",
      play_pause = "􀊈",
    },
    -- Wetterlagen. Die Schluessel sind Zustaende, keine WMO-Codes: welcher
    -- Code auf welchen Zustand faellt, entscheidet items/weather.lua. Tag und
    -- Nacht werden nur dort getrennt, wo Sonne oder Mond im Symbol steckt.
    weather = {
      clear_day     = "􀆮",   -- sun.max.fill
      clear_night   = "􀇁",   -- moon.stars.fill
      partly_day    = "􀇕",   -- cloud.sun.fill
      partly_night  = "􀇛",   -- cloud.moon.fill
      cloudy        = "􀇃",   -- cloud.fill
      fog           = "􀇋",   -- cloud.fog.fill
      drizzle       = "􀇅",   -- cloud.drizzle.fill
      rain          = "􀇇",   -- cloud.rain.fill
      heavy_rain    = "􀇉",   -- cloud.heavyrain.fill
      sleet         = "􀇑",   -- cloud.sleet.fill
      snow          = "􀇏",   -- cloud.snow.fill
      snow_grains   = "􀇥",   -- snowflake
      showers_day   = "􀇗",   -- cloud.sun.rain.fill
      showers_night = "􀇝",   -- cloud.moon.rain.fill
      thunder       = "􀇟",   -- cloud.bolt.rain.fill
      hail          = "􀇍",   -- cloud.hail.fill
    },
  },

  -- Alternative NerdFont icons
  nerdfont = {
    plus = "",
    loading = "",
    apple = "",
    gear = "",
    cpu = "",
    clipboard = "Missing Icon",

    switch = {
      on = "󱨥",
      off = "󱨦",
    },
    volume = {
      _100="",
      _66="",
      _33="",
      _10="",
      _0="",
    },
    battery = {
      _100 = "",
      _75 = "",
      _50 = "",
      _25 = "",
      _0 = "",
      charging = ""
    },
    wifi = {
      upload = "",
      download = "",
      connected = "󰖩",
      disconnected = "󰖪",
      router = "Missing Icon"
    },
    memory = {
      ram = "󰍛",
      disk = "󰋊",
    },
    media = {
      back = "",
      forward = "",
      play_pause = "",
    },
    -- Gegenstuecke zum sf-symbols-Block aus der Material-Design-Reihe der
    -- Nerd Fonts. Wo dort keine eigene Tag/Nacht- oder Staerkevariante
    -- existiert, teilen sich mehrere Zustaende ein Symbol.
    weather = {
      clear_day     = "󰖙",
      clear_night   = "󰖔",
      partly_day    = "󰖕",
      partly_night  = "󰼱",
      cloudy        = "󰖐",
      fog           = "󰖑",
      drizzle       = "󰖗",
      rain          = "󰖖",
      heavy_rain    = "󰖖",
      sleet         = "󰼶",
      snow          = "󰖘",
      snow_grains   = "󰜗",
      showers_day   = "󰖖",
      showers_night = "󰖖",
      thunder       = "󰙾",
      hail          = "󰖒",
    },
  },
}

if not (settings.icons == "NerdFont") then
  return icons.sf_symbols
else
  return icons.nerdfont
end
