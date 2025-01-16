alias bathelp='bat --plain --language=help --theme ansi'

function help
    $argv --help 2>&1 | bathelp
end
