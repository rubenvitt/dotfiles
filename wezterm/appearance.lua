local wezterm = require 'wezterm'
local module = {}

function module.is_dark()
    if wezterm.gui then
        return wezterm.gui.get_appearance():find("Dark")
    end
    return true
end

module.font = {
    firacode_retina = {
        family = "FiraCode Nerd Font Mono",
        weight = 450,
        stretch = "Normal",
        italic = false,
    }
}

return module
