if status is-interactive
  # code for interactive sessions
end


source /usr/local/opt/asdf/libexec/asdf.fish
zoxide init fish | source
thefuck --alias | source
starship init fish | source

set -gx PNPM_HOME "/Users/rubeen/Library/pnpm"
set -gx PATH "$PNPM_HOME" $PATH
