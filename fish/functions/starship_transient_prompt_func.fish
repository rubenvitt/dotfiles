# Alte Prompts schrumpfen auf das Zeichen aus [character] in starship.toml
function starship_transient_prompt_func
    starship module character $argv
end
