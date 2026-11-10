return {
  black = 0xff181819,
  white = 0xffe2e2e3,
  red = 0xfffc5d7c,
  green = 0xff9ed072,
  blue = 0xff76cce0,
  -- Fokussierter Workspace; colors.blue ist eher Türkis.
  active_blue = 0xff4f7fe8,
  yellow = 0xffe7c664,
  orange = 0xfff39660,
  magenta = 0xffb39df3,
  grey = 0xff7f8490,
  transparent = 0x00000000,

  bar = {
    -- Deckend: die macOS-Menüleiste liegt direkt darunter (bar.lua).
    bg = 0xff2c2e34,
    border = 0xff2c2e34,
  },
  popup = {
    bg = 0xc02c2e34,
    border = 0xff7f8490,
    -- Auf Glas: der Hintergrund tönt nur, Rahmen und Trenner sind Haarlinien,
    -- Beschriftungen gedämpftes Weiß statt Schiefergrau (wie die Systemmenüs).
    glass_tint = 0x402c2e34,
    hairline = 0x1fffffff,
    caption = 0x99ffffff,
  },
  bg1 = 0xff363944,
  bg2 = 0xff414550,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
