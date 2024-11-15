function tana_format
    set temp_file (mktemp)

    if test (count $argv) -eq 0
        # Wenn keine Argumente übergeben wurden, verwende pbpaste
        if type -q pbpaste
            pbpaste | fabric -p tana_paste > $temp_file
        else
            # Wenn pbpaste nicht verfügbar ist, frage mit gum
            gum input --placeholder "Geben Sie den Inhalt ein:" | fabric -p tana_paste > $temp_file
        end
    else
        # Wenn Argumente übergeben wurden, verwende sie alle
        printf '%s\n' $argv | fabric -p tana_paste > $temp_file
    end

    # Zeige den Inhalt der verarbeiteten Datei an
    cat $temp_file | glow

    # Kopiere den Inhalt der verarbeiteten Datei in die Zwischenablage
    cat $temp_file | pbcopy

    # Entferne die temporäre Datei
    rip $temp_file
end
