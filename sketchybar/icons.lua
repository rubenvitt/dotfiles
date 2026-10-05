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
    -- Amtliche Warnung. Die Stufe steckt in der Farbe, nicht im Symbol:
    -- der DWD faerbt seine vier Stufen, er zeichnet sie nicht verschieden.
    warning = "􀇿",   -- exclamationmark.triangle.fill
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
    tailscale = {
      connected    = "􀙧",   -- shield.fill
      disconnected = "􀙦",   -- shield
      exit_node    = "􀙨",   -- shield.lefthalf.filled
    },
    -- Phönix-Progression (items/phoenix.lua): ein eigenes Symbol je Zustand,
    -- damit die Bar Feuer, Aschezeit und Urlaub auch ohne Popup trennt. Der
    -- Funke ist die Glut, aus der der nächste Feuersturm entsteht; die Flamme
    -- im Umriss bleibt für "kein Feuersturm".
    phoenix = {
      fire     = "􀙭",   -- flame.fill           U+10066D
      ash      = "􀫸",   -- sparkle              U+100AF8
      vacation = "􁋻",   -- beach.umbrella.fill  U+1012FB
      rest     = "􀙬",   -- flame                U+10066C
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
    warning = "󰀦",   -- mdi:alert
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
    tailscale = {
      connected    = "󰒘",
      disconnected = "󰒙",
      exit_node    = "󰦝",
    },
    phoenix = {
      fire     = "󰈸",   -- mdi:fire              U+F0238
      ash      = "󰫢",   -- mdi:star-four-points  U+F0AE2
      vacation = "󰂒",   -- mdi:beach             U+F0092
      rest     = "󰈸",   -- mdi:fire (Farbe unterscheidet Feuer und Leerlauf)
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
