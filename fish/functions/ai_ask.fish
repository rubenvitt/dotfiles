function ai_ask
    set content_arg $argv[1]
    set fabric_arg $argv[2]

    if test -z "$content_arg"
        set temp_input_file (mktemp)
        zed --wait $temp_input_file
        set content_arg (cat $temp_input_file)
        rip $temp_input_file
    end

    # Check if fabric_arg is provided, if not, prompt with gum and list selections
    if test -z "$fabric_arg"
        set fabric_arg (fabric --listpatterns | sed '1,2d' | tr -d ' ' | tr -d '\t' | gum filter --placeholder "Select fabric argument:")
    end

    # Prompt the user to choose between 'r_translate' or 'tana_paste'
    set processing_method (gum choose "r_translate" "tana_paste" --placeholder "Select processing method:")

    # Create a temporary file
    set temp_file (mktemp)

    # Execute fabric -p with the selected argument, apply the processing method, then save to temp_file
    fabric -p "$fabric_arg" "$content_arg" | fabric -p $processing_method > $temp_file

    cat $temp_file | glow
    cat $temp_file | pbcopy
    rip $temp_file
end
