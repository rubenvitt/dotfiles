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
    fabric -p "$fabric_arg" --text "$yt_result" | fabric -p tana_paste > $temp_file

        # Process the temp_file to remove quotes from lines with #quote
        set processed_file (mktemp)
        cat $temp_file | while read -l line
            if string match -q '*#quote*' -- $line
                set line (string replace -ra '"' '' -- $line)
            end
            echo $line
        end > $processed_file

        cat $processed_file | glow

        # Copy the contents of the processed file to clipboard
        cat $processed_file | pbcopy

        # Remove the temporary files
        rm $temp_file
        rm $processed_file
end
