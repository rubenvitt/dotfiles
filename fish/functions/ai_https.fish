```fish
function ai_https
    set curl_arg $argv[1]
    set fabric_arg $argv[2]

    if test -z "$curl_arg"
        set curl_arg (gum input --placeholder "Enter curl argument:")
    end

    set curl_result (https -F "$curl_arg" | pandoc -f html -t markdown)

    if test -z "$fabric_arg"
        set fabric_arg (fabric --listpatterns | sed '1,2d' | tr -d ' ' | gum filter --placeholder "Select fabric argument:")
    end

    set processing_method (gum choose "r_translate" "tana_paste" --header "Select processing method:")

    set temp_file (mktemp)

    fabric -p "$fabric_arg" "$curl_arg:\n$curl_result" | fabric -p $processing_method > $temp_file

    cat $temp_file | glow
    cat $temp_file | pbcopy
    rip $temp_file
end
```
