function tana_format
    set input $argv[1]

    # Check if input is provided, if not, check if pbpaste is available, else ask with gum
    if test -z "$input"
        set input (gum input --placeholder "Enter content:")
    end

    # Create a temporary file
    set temp_file (mktemp)

    # Execute fabric -p with the selected argument and append the yt_result, then save to temp_file
    fabric -p tana_paste --text "$input" > $temp_file

    cat $temp_file | glow

    # Copy the contents of the processed file to clipboard
    cat $temp_file | pbcopy

    # Remove the temporary files
    rm $temp_file
end
