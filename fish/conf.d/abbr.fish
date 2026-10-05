status is-interactive; or return

# Dateien
abbr -a ls eza --icons=auto --group-directories-first
abbr -a ll eza -l --icons=auto --git --group-directories-first
abbr -a la eza -la --icons=auto --git --group-directories-first
abbr -a lt eza --tree --level=2 --icons=auto
abbr -a cat bat

# Git
abbr -a g git
abbr -a gs git status -sb
abbr -a gd git diff
abbr -a gds git diff --staged
abbr -a ga git add
abbr -a gc git commit
abbr -a gp git push
abbr -a gl git pull
abbr -a gsw git switch
abbr -a glog git log --oneline --graph --decorate -20
