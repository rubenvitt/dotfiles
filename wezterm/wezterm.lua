local wezterm = require 'wezterm'
local appearance = require 'appearance'
local config = wezterm.config_builder()

-- CONFIG BELOW

if appearance.is_dark() then
    config.color_scheme = 'Argonaut'
else
    --config.color_scheme = 'CLRS'
    config.color_scheme = 'Material'
end
config.font = wezterm.font(appearance.font.firacode_retina)
config.font_size = 12

config.window_background_opacity = 0.9
config.macos_window_background_blur = 50
config.window_decorations = 'RESIZE'
config.window_frame = {
    font = wezterm.font(appearance.font.firacode_retina),
    font_size = 11
}

config.keys = {
    {
        key = 'LeftArrow',
        mods = 'CMD',
        action = wezterm.action.SendString '\x01', -- CTRL + A to go to the beginning of the line
    },
    {
        key = 'RightArrow',
        mods = 'CMD',
        action = wezterm.action.SendString '\x05', -- CTRL + E to go to the end of the line
    },
    {
        key = ',',
        mods = 'SUPER',
        action = wezterm.action.SpawnCommandInNewTab {
            cwd = wezterm.home_dir,
            args = { 'zed', wezterm.config_file },
        },
    },
}


config.initial_cols = 150
config.initial_rows = 50
config.initial_cols = 150
config.initial_rows = 50


local function segments_for_right_status(window)
    return {
        window:active_workspace(),
        wezterm.strftime('%d%H%M%b%y'),
        wezterm.hostname(),
    }
end

wezterm.on('update-status', function(window, _)
    local SOLID_LEFT_ARROW = utf8.char(0xe0b2)
    local segments = segments_for_right_status(window)

    local color_scheme = window:effective_config().resolved_palette
    local bg = wezterm.color.parse(color_scheme.background)
    local fg = color_scheme.foreground

    local gradient_to, gradient_from = bg
    if appearance.is_dark() then
        gradient_from = gradient_to:lighten(0.2)
    else
        gradient_from = gradient_to:darken(0.2)
    end

    local gradient = wezterm.color.gradient(
        {
            orientation = 'Horizontal',
            colors = { gradient_from, gradient_to },
        },
        #segments -- only gives us as many colours as we have segments.
    )

    local elements = {}
    for i, seg in ipairs(segments) do
        local is_first = i == 1

        if is_first then
            table.insert(elements, { Background = { Color = 'none' } })
        end
        table.insert(elements, { Foreground = { Color = gradient[i] } })
        table.insert(elements, { Text = SOLID_LEFT_ARROW })

        table.insert(elements, { Foreground = { Color = fg } })
        table.insert(elements, { Background = { Color = gradient[i] } })
        table.insert(elements, { Text = ' ' .. seg .. ' ' })
    end

    window:set_right_status(wezterm.format(elements))
end)

--- CONFIG ABOVE

return config
