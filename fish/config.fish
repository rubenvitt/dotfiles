fish_add_path $HOME/.dotfiles/r-tools
fish_add_path $HOME/dev/common/tools
set -gx PATH $PATH /opt/homebrew/anaconda3/bin
set -gx PATH $PATH /Users/rubeen/dev/common/tools/bin
set -gx PUPPETEER_SKIP_CHROMIUM_DOWNLOAD true

# Homebrew: Ausgabe von `brew shellenv fish` fest eingetragen, spart den Prozessstart
set -gx HOMEBREW_PREFIX /opt/homebrew
set -gx HOMEBREW_CELLAR /opt/homebrew/Cellar
set -gx HOMEBREW_REPOSITORY /opt/homebrew
fish_add_path --global --move --path /opt/homebrew/bin /opt/homebrew/sbin
if test -n "$MANPATH"
    set -gx MANPATH (string replace --regex '^:*(.*?):*$' ':$1' -- "$MANPATH")
end
set -q INFOPATH; or set INFOPATH ''
set -gx INFOPATH /opt/homebrew/share/info $INFOPATH

if command -q chromium
    set -gx PUPPETEER_EXECUTABLE_PATH (command -s chromium)
end

#source /opt/homebrew/opt/asdf/libexec/asdf.fish
#set -gx PATH /Users/rubeen/.asdf/shims $PATH
if status is-interactive
    starship init fish | source
    atuin init fish | sed "s/-k up/up/g" | source
    zoxide init --cmd cd fish | source
end
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
# mise aktiviert sich über /opt/homebrew/share/fish/vendor_conf.d selbst

# Workaround for Claude Code shopt issue
function shopt
    return 0
end

source /Users/rubeen/.config/op/plugins.sh
