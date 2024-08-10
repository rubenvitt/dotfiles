function ai_yt_de
    set yt_arg $argv[1]
    set fabric_arg $argv[2]

    # Check if yt_arg is provided, if not, prompt with gum
    if test -z "$yt_arg"
        set yt_arg (gum input --placeholder "Enter yt argument:")
    end

    # Execute yt --transcript and store the result
    set yt_result (yt --transcript "$yt_arg" --lang de)

    # Check if fabric_arg is provided, if not, prompt with gum and list selections
    if test -z "$fabric_arg"
        set fabric_arg (fabric --list | gum filter --placeholder "Select fabric argument:")
    end


    # Create a temporary file
    set temp_file (mktemp)

    # Execute fabric -p with the selected argument and append the yt_result, then save to temp_file
    fabric -p "$fabric_arg" --text "$yt_result" | fabric -p r_translate > $temp_file

        cat $temp_file | glow

        # Copy the contents of the processed file to clipboard
        cat $temp_file | pbcopy

        # Remove the temporary files
        rm $temp_file
end
