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
            case '*'
                echo "ccp: unbekanntes Profil '$profile'" >&2
                return 1
        end
    end

    if test "$profile" != personal; and not test -d "$dir"
        echo "ccp: Profil '$profile' ist noch nicht eingerichtet — 'ccp setup $profile'." >&2
        return 1
    end

    # Gleichzeitigkeits-Guard: dasselbe Config-Dir nicht doppelt öffnen — zwei Claude-
    # Prozesse im selben Dir können beim Schreiben von .claude.json die Datei beschädigen.
    set -l lock "$dir/.ccp.lock"
    if test -f "$lock"
        set -l oldpid (cat "$lock" 2>/dev/null | string trim)
        if test -n "$oldpid"; and kill -0 $oldpid 2>/dev/null
            # Live-Session gefunden. Nur interaktiv nachfragen; Skripte/`-p` nie blockieren.
            if status is-interactive
                echo "⚠️  In Profil '$profile' läuft bereits eine Session (PID $oldpid)." >&2
                echo "   Dasselbe Profil zweimal im selben Config-Dir kann .claude.json beschädigen." >&2
                read -l -P "   Trotzdem starten? [y/N] " ans
                if not string match -qi 'y' -- "$ans"
                    return 1
                end
            end
        end
    end

    echo $fish_pid >"$lock"
    env CLAUDE_CONFIG_DIR="$dir" claude $argv
    set -l rc $status
    # Lock nur entfernen, wenn er noch uns gehört (parallele Starts nicht überschreiben).
    if test -f "$lock"; and test (cat "$lock" 2>/dev/null | string trim) = "$fish_pid"
        rm -f "$lock"
    end
    return $rc
end
