function ai
    set content_arg $argv[1]
    set fabric_arg $argv[2]

    if test -z "$content_arg"
        set temp_input_file (mktemp)
        zed --wait $temp_input_file
        set content_arg (cat $temp_input_file)
        rm $temp_input_file
    end

    # Check if fabric_arg is provided, if not, prompt with gum and list selections
    if test -z "$fabric_arg"
        set fabric_arg (fabric --list | gum filter --placeholder "Select fabric argument:")
    end


    # Create a temporary file
    set temp_file (mktemp)

    # Execute fabric -p with the selected argument and append the yt_result, then save to temp_file
    fabric -p "$fabric_arg" --text "$content_arg" > $temp_file
        cat $temp_file | glow
        # Copy the contents of the processed file to clipboard
        cat $temp_file | pbcopy
        # Remove the temporary files
        rm $temp_file
end
