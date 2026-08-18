function claude --description 'Claude Code – folgt dem aktiven ccp-Profil'
    set -l profile (command ccp active 2>/dev/null | string trim)
    test -z "$profile"; and set profile personal

    if functions -q _ccp_launch
        _ccp_launch $profile $argv
    else
        # Notfall-Fallback: _ccp_launch nicht geladen — direkt starten, damit `claude`
        # niemals unbenutzbar wird.
        set -l dir (command ccp dir $profile 2>/dev/null | string trim)
        test -z "$dir"; and set dir "$HOME/.claude"
        env CLAUDE_CONFIG_DIR="$dir" claude $argv
    end
end
