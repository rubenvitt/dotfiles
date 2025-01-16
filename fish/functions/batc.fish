function batc
    if test (count $argv) -ne 1
        gum style --bold --foreground="#ff0000" --border="rounded" --align="center" --padding="1 2" "🔍 Error: Please provide exactly one file path 📁"
        return 1
    end
    cat $argv[1] | pbcopy
    bat $argv[1]
end
