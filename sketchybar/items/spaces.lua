local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

-- AeroSpace-Workspaces statt macOS-Spaces.
--
-- macOS-Spaces gibt es unter AeroSpace praktisch nicht mehr: alle Fenster
-- liegen auf einem einzigen Space, die Verteilung verwaltet AeroSpace selbst.
-- Damit fallen sketchybars 'space'-Item-Typ und die Events 'space_change' /
-- 'space_windows_change' aus. Ersatz:
--   * Highlight  → Custom-Event 'aerospace_workspace_change', gefeuert aus
--                  exec-on-workspace-change in aerospace.toml.
--   * App-Icons  → 'aerospace list-windows --all' abfragen.
--
-- Die Items heißen weiter space.<N>, damit die Regex-Selektoren in
-- items/menus.lua ("/space\\..*/") unverändert greifen.

local AEROSPACE = "/opt/homebrew/bin/aerospace"
local WORKSPACES = { "1", "2", "3", "4", "5", "6", "7", "8", "9" }

sbar.add("event", "aerospace_workspace_change")

local spaces = {}
local brackets = {}
local paddings = {}

-- Sichtbarkeit: leere Workspaces werden ausgeblendet, der fokussierte immer
-- gezeigt. Der Stand wird zwischengespeichert, weil items/menus.lua beim
-- Zurückschalten auf die Spaces-Ansicht pauschal alle space.*-Items einblendet
-- und wir ihn dann sofort wieder herstellen müssen.
local visible = {}
local focused_workspace = nil
-- Spaces- oder Menü-Ansicht? In der Menü-Ansicht darf hier nichts eingeblendet
-- werden, sonst schiebt sich bei jedem front_app_switched ein Workspace ins Menü.
local spaces_shown = true

for _, sid in ipairs(WORKSPACES) do
  local space = sbar.add("item", "space." .. sid, {
    -- Startet unsichtbar; die erste aerospace-Abfrage blendet ein, was belegt
    -- ist — sonst blitzen bei jedem Neustart alle neun Workspaces auf.
    drawing = false,
    icon = {
      font = { family = settings.font.numbers },
      string = sid,
      padding_left = 15,
      padding_right = 8,
      color = colors.white,
      highlight_color = colors.red,
    },
    label = {
      padding_right = 20,
      color = colors.grey,
      highlight_color = colors.white,
      font = "sketchybar-app-font:Regular:16.0",
      y_offset = -1,
      string = " —",
    },
    padding_right = 1,
    padding_left = 1,
    background = {
      color = colors.bg1,
      border_width = 1,
      height = 26,
      border_color = colors.black,
    },
    click_script = AEROSPACE .. " workspace " .. sid,
  })

  spaces[sid] = space

  -- Einzel-Item-Bracket für den doppelten Rahmen im Highlight-Zustand
  brackets[sid] = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      border_width = 2
    }
  })

  -- Abstandshalter
  paddings[sid] = sbar.add("item", "space.padding." .. sid, {
    drawing = false,
    script = "",
    width = settings.group_paddings,
  })
end

-- Zwischengespeicherten Sichtbarkeitsstand auf die Bar schreiben.
-- Das Bracket bleibt unangetastet: es enthält nur das eine Workspace-Item und
-- klappt von selbst weg, sobald das ausgeblendet ist (per --query verifiziert).
local function apply_visibility()
  if not spaces_shown then return end
  for _, sid in ipairs(WORKSPACES) do
    local on = visible[sid] or false
    spaces[sid]:set({ drawing = on })
    paddings[sid]:set({ drawing = on })
  end
end

-- Highlight des fokussierten Workspace setzen.
local function highlight(focused)
  focused_workspace = focused
  for _, sid in ipairs(WORKSPACES) do
    local selected = (sid == focused)
    spaces[sid]:set({
      icon = { highlight = selected },
      label = { highlight = selected },
      background = { border_color = selected and colors.black or colors.bg2 },
    })
    brackets[sid]:set({
      background = { border_color = selected and colors.grey or colors.bg2 }
    })
  end
  -- Sofort einblenden, ohne auf die aerospace-Abfrage zu warten: sonst ist die
  -- Bar beim Wechsel auf einen frischen Workspace kurz ohne Anzeige.
  if focused then visible[focused] = true end
  apply_visibility()
end

-- App-Icons und Belegung je Workspace aus der aktuellen Fensterliste ableiten.
-- Dieselbe Abfrage liefert beides; 'list-workspaces --empty no' wäre ein
-- zweiter aerospace-Aufruf für eine Information, die hier schon vorliegt.
local function update_windows()
  sbar.exec(AEROSPACE .. " list-windows --all --format '%{workspace}|%{app-name}'", function(out)
    local per_workspace = {}
    for line in string.gmatch(out or "", "[^\r\n]+") do
      local ws, app = string.match(line, "^(.-)|(.*)$")
      if ws then
        local entry = per_workspace[ws]
        if not entry then
          entry = { seen = {}, icons = {} }
          per_workspace[ws] = entry
        end
        -- Jede App nur einmal, Reihenfolge wie von aerospace geliefert
        if app and app ~= "" and not entry.seen[app] then
          entry.seen[app] = true
          table.insert(entry.icons, app_icons[app] or app_icons["default"])
        end
      end
    end

    for _, sid in ipairs(WORKSPACES) do
      local entry = per_workspace[sid]
      local icon_line = " —"
      if entry and #entry.icons > 0 then
        icon_line = " " .. table.concat(entry.icons, " ")
      end
      -- Belegt zählt am Fenster, nicht am Icon: ein Fenster ohne app-name
      -- macht den Workspace trotzdem nicht leer.
      visible[sid] = (entry ~= nil) or (sid == focused_workspace)
      sbar.animate("tanh", 10, function()
        spaces[sid]:set({ label = icon_line })
      end)
    end

    apply_visibility()
  end)
end

local space_window_observer = sbar.add("item", {
  drawing = false,
  updates = true,
})

space_window_observer:subscribe("aerospace_workspace_change", function(env)
  highlight(env.FOCUSED_WORKSPACE)
  update_windows()
end)

-- Fenster wechseln den Workspace auch ohne Workspace-Wechsel (neue Fenster,
-- geschlossene Fenster, move-node-to-workspace). front_app_switched ist der
-- billigste Aufhänger, den sketchybar dafür bietet.
space_window_observer:subscribe("front_app_switched", update_windows)

-- exec-on-workspace-change feuert beim Start nicht — Initialzustand selbst holen.
sbar.exec(AEROSPACE .. " list-workspaces --focused", function(out)
  local focused = string.match(out or "", "[^\r\n]+")
  if focused then highlight(focused) end
  update_windows()
end)

local spaces_indicator = sbar.add("item", {
  padding_left = -3,
  padding_right = 0,
  icon = {
    padding_left = 8,
    padding_right = 9,
    color = colors.grey,
    string = icons.switch.on,
  },
  label = {
    width = 0,
    padding_left = 0,
    padding_right = 8,
    string = "Spaces",
    color = colors.bg1,
  },
  background = {
    color = colors.with_alpha(colors.grey, 0.0),
    border_color = colors.with_alpha(colors.bg1, 0.0),
  }
})

spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
  local currently_on = spaces_indicator:query().icon.value == icons.switch.on
  spaces_indicator:set({
    icon = currently_on and icons.switch.off or icons.switch.on
  })
end)

-- Welche Ansicht gilt, meldet items/menus.lua -- dort hängt der maßgebliche
-- Zustand. Auf swap_menus_and_spaces mitzuhören ginge auch, hinge dann aber an
-- der Reihenfolge zweier Handler am selben Event: menus.lua würde die leeren
-- Workspaces sichtbar setzen und wir sie je nach Ausgang des Rennens wieder aus.
space_window_observer:subscribe("spaces_visibility", function(env)
  spaces_shown = env.SPACES == "on"
  if spaces_shown then
    apply_visibility()
    update_windows()
  end
end)

spaces_indicator:subscribe("mouse.entered", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 1.0 },
        border_color = { alpha = 1.0 },
      },
      icon = { color = colors.bg1 },
      label = { width = "dynamic" }
    })
  end)
end)

spaces_indicator:subscribe("mouse.exited", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 0.0 },
        border_color = { alpha = 0.0 },
      },
      icon = { color = colors.grey },
      label = { width = 0, }
    })
  end)
end)

spaces_indicator:subscribe("mouse.clicked", function(env)
  sbar.trigger("swap_menus_and_spaces")
end)
