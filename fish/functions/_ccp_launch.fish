function _ccp_launch --description 'intern (ccp): Claude Code in einem bestimmten Profil starten'
    set -l profile $argv[1]
    set -e argv[1]

    # Config-Dir auflösen — ccp ist die Quelle der Wahrheit; Fallback, falls ccp fehlt.
    set -l dir (command ccp dir $profile 2>/dev/null | string trim)
    if test -z "$dir"
        switch $profile
            case personal
                set dir "$HOME/.claude"
            case work
                set dir "$HOME/.claude-work"
            case innoq
                set dir "$HOME/.claude-innoq"
            case dev
                set dir "$HOME/.claude-dev"
            case '*'
                echo "ccp: unbekanntes Profil '$profile'" >&2
                return 1
        end
    end

    if test "$profile" != personal; and not test -d "$dir"
        echo "ccp: Profil '$profile' ist noch nicht eingerichtet — 'ccp setup $profile'." >&2
        return 1
    end

    # dev teilt alles außer dem Login mit personal: neue Einträge aus ~/.claude verlinken und
    # MCP-/Projekt-State übernehmen. Schlägt das fehl, startet dev trotzdem.
    if test "$profile" = dev; and command -q ccp
        command ccp sync dev
    end

    env CLAUDE_CONFIG_DIR="$dir" claude $argv
end
