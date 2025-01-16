function ai_yt_de
    set yt_arg $argv[1]
    set fabric_arg $argv[2]

    if test -z "$yt_arg"
        set yt_arg (gum input --placeholder "Enter yt argument:")
    end

    set yt_result (yt --transcript "$yt_arg")

    if test -z "$yt_result"
        echo "Fehler: Das Ergebnis von yt ist leer. Überprüfe das yt Argument."
        return
    end

    if test -z "$fabric_arg"
        set fabric_arg (fabric --listpatterns | sed '1,2d' | tr -d ' ' | gum filter --placeholder "Select fabric argument:")
    end

    set processing_method (gum choose "r_translate" "tana_paste" --header "Select processing method:")

    set temp_file (mktemp)

    if not fabric -p "$fabric_arg" "$yt_result" | fabric -p $processing_method > $temp_file
        echo "Fehler: fabric Befehl fehlgeschlagen."
        return
    end

    cat $temp_file | glow
    cat $temp_file | pbcopy
    rm $temp_file
end
