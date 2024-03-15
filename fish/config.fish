set -gx PATH $PATH /opt/homebrew/anaconda3/bin
set -gx PATH $PATH /Users/rubeen/dev/general/tools/bin
eval "$(/opt/homebrew/bin/brew shellenv)"
source /opt/homebrew/opt/asdf/libexec/asdf.fish


if status is-interactive
    atuin init fish | source
    alias ls="eza"
    alias ll="eza -ll"
    alias la="eza -la"
    eval "$(orb completion fish)"
    eval "$(docker completion fish)"
    # Commands to run in interactive sessions can go here
end

# pnpm
set -gx PNPM_HOME "/Users/rubeen/Library/pnpm"
if not string match -q -- $PNPM_HOME $PATH
  set -gx PATH "$PNPM_HOME" $PATH
end
# pnpm end

# Setting PATH for Python 3.12
# The original version is saved in /Users/rubeen/.config/fish/config.fish.pysave
set -x MAVEN_OPTS "-Duser.language=en_US.UTF-8"
set -x LANG "en_US.UTF-8"
set -x LC_ALL "en_US.UTF-8"
set -x PATH "/Library/Frameworks/Python.framework/Versions/3.12/bin" "$PATH"
alias copilot='gh copilot'
zoxide init --cmd cd fish | source
