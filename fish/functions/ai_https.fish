function ai_https
    set curl_arg $argv[1]
    set fabric_arg $argv[2]

    # Check if curl_arg is provided, if not, prompt with gum
    if test -z "$curl_arg"
        set curl_arg (gum input --placeholder "Enter curl argument:")
    end

    # Execute curl with the provided argument and save the result to curl_result
    set curl_result (https -F "$curl_arg" | pandoc -f html -t markdown)

    # Check if fabric_arg is provided, if not, prompt with gum and list selections
    if test -z "$fabric_arg"
        set fabric_arg (fabric --listpatterns | sed '1,2d' | tr -d ' ' | tr -d '\t' | gum filter --placeholder "Select fabric argument:")
    end


    # Create a temporary file
    set temp_file (mktemp)

    # Execute fabric -p with the selected argument and append the yt_result, then save to temp_file
    fabric -p "$fabric_arg" "$curl_arg:\n$curl_result" | fabric -p r_translate > $temp_file

        cat $temp_file | glow

        # Copy the contents of the processed file to clipboard
        cat $temp_file | pbcopy

        # Remove the temporary files
        rm $temp_file
end
