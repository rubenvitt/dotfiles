fish_add_path $HOME/.dotfiles/r-tools
fish_add_path $HOME/dev/common/tools
set -gx PATH $PATH /opt/homebrew/anaconda3/bin
set -gx PATH $PATH /Users/rubeen/dev/common/tools/bin
set -gx PUPPETEER_SKIP_CHROMIUM_DOWNLOAD true
set -gx PUPPETEER_EXECUTABLE_PATH `which chromium`
eval (/opt/homebrew/bin/brew shellenv)
#source /opt/homebrew/opt/asdf/libexec/asdf.fish
#set -gx PATH /Users/rubeen/.asdf/shims $PATH
starship init fish | source
if status is-interactive
    atuin init fish | sed "s/-k up/up/g" | source
    # Commands to run in interactive sessions can go here
end
zoxide init --cmd cd fish | source
# Added by LM Studio CLI (lms)
set -gx PATH $PATH /Users/rubeen/.lmstudio/bin
# End of LM Studio CLI section
# pnpm
set -gx PNPM_HOME "/Users/rubeen/Library/pnpm"
if not string match -q -- "$PNPM_HOME/bin" $PATH
  set -gx PATH "$PNPM_HOME/bin" $PATH
end
# pnpm end
set -gx PATH $HOME/.pnpm-global/bin $PATH
# Added by OrbStack: command-line tools and integration
# This won't be added again if you remove it.
source ~/.orbstack/shell/init2.fish 2>/dev/null || :
set -gx PATH ~/.local/bin $PATH
# Added by Windsurf
mise activate | source

# Workaround for Claude Code shopt issue
function shopt
    return 0
end

# Pi
fish_add_path "/Users/rubeen/.local/share/mise/installs/node/24.16.0/bin"
source /Users/rubeen/.config/op/plugins.sh
