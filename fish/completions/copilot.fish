function _copilot_completions
    set -l cmd (commandline -opc)
    set -e cmd[1]
    switch $cmd
        case "--version"
            echo "Version for copilot\t'Zeigt die Version von copilot an'"
        case "config"
            complete -c copilot -n '__fish_seen_subcommand_from config' -a set -d 'Set a configuration option'
            complete -c copilot -n '__fish_seen_subcommand_from config' -a get -d 'Get a configuration option'
        case "explain"
            complete -c copilot -n '__fish_seen_subcommand_from explain' -a "--help" -d 'Explain a command'
        case "suggest"
            complete -c copilot -n '__fish_seen_subcommand_from suggest' -a "--help" -d 'Suggest a command'
        case "*"
            complete -c copilot -a "config" -d 'Configure options'
            complete -c copilot -a "explain" -d 'Explain a command'
            complete -c copilot -a "suggest" -d 'Suggest a command'
            complete -c copilot -a "--help" -d 'Help for copilot'
            complete -c copilot -a "--version" -d 'Version for copilot'
    end
end

complete -f -c copilot -n '_copilot_completions'

