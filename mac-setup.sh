#!/bin/zsh

trap "echo 'Script interrupted by user'; exit" INT

# Check for exactly one argument: "computername"
if [ $# -ne 1 ]; then
  echo "Usage: $0 computername - currently $(hostname)"
  exit 1
fi

echo "Starting setup for $1..."
computername=$1

# Close System Preferences to prevent conflicts
echo "Closing System Preferences..."
osascript -e 'tell application "System Preferences" to quit'

# Function to install Homebrew and Gum
installBrewAndGum() {
  echo "Checking for Homebrew..."
  if hash brew 2>/dev/null; then
        echo "Homebrew is already installed."
        brew -v
  else
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh')"
  fi
  echo "Disabling Homebrew analytics..."
  brew analytics off
  echo "Installing Gum..."
  brew install gum
}

# Function to ask user for installation confirmation
askToInstall() {
  gum confirm "Do you like to install $1?" && open $2
}

# Function to ask user for setup confirmation
askToSetup() {
  gum confirm "Do you like to setup $1?" && open -a "$2"
}

# Function to set system defaults
setDefaults() {
  echo "Applying system defaults..."
  set -x

  # Dock
  defaults write com.apple.dock showAppExposeGestureEnabled -bool YES # Enable the Expose gesture
  defaults write com.apple.dock mru-spaces -bool NO                   # Disable reordering Spaces based on use
  defaults write com.apple.dock expose-group-apps -bool YES           # Group apps in Expose
  defaults write com.apple.dock expose-animation-duration -float 0.05 # Set animation duration
  defaults write com.apple.dock springboard-show-duration -float 0.1  # Set animation duration
  defaults write com.apple.dock springboard-hide-duration -float 0.1  # Set animation duration
  defaults write com.apple.dock mineffect -string suck                # Use the suck animation for minimization
  defaults write com.apple.dock show-recents -bool NO                 # Disable recent apps
  defaults write com.apple.dock autohide-delay -float 0               # Remove delay before showing
  defaults write com.apple.dock autohide-time-modifier -float 0.15    # Set animation duration

  echo "Restarting Dock to apply changes..."
  killall Dock 2>/dev/null

  # The rest of the defaults go here...
  # Finder
  defaults write com.apple.finder QLEnableTextSelection -bool YES              # Enable text selection from Quick Look
  defaults write com.apple.finder ShowStatusBar -bool YES                      # Show the status bar
  defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool YES    # Show external hard drives on the desktop
  defaults write com.apple.finder QuitMenuItem -bool YES                       # Show the Quit menu item
  defaults write com.apple.finder ShowPathbar -bool YES                        # Show the path bar
  defaults write com.apple.finder FXEnableExtensionChangeWarning -bool NO      # Disable the extension change warning
  defaults write com.apple.finder QuitMenuItem -bool true                      # Enable quit Finder (will hide desktop icons)
  defaults write com.apple.finder NewWindowTarget -string "PfLo"               # Set custom target for new Finder windows
  defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}" # Set custom path for new Finder windows
  defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"          # Search current folder by default
  defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true # Disable creation of .DS_Store files on network volumes
  defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true     # Disable creation of .DS_Store files on USB volumes
  defaults write com.apple.finder WarnOnEmptyTrash -bool false                 # Disable the warning before emptying the Trash
  # Fenster-Animationen schneller
  defaults write NSGlobalDomain NSWindowResizeTime -float 0.1                  # Set window resize time to 0.1 seconds
  chflags nohidden ~/Library && xattr -d com.apple.FinderInfo ~/Library        # Show the ~/Library folder

  sudo chflags nohidden /Volumes # Show the /Volumes folder

  killall Finder 2>/dev/null

  # Safari
  killall Safari 2>/dev/null
  killall "Safari Technology Preview" 2>/dev/null
  { set +x; } 2>/dev/null
  for app in ~/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari ~/Library/Containers/com.apple.SafariTechnologyPreview/Data/Library/Preferences/com.apple.SafariTechnologyPreview; do
    set -x
    defaults write $app IncludeDevelopMenu -bool YES                        # Show the Develop menu
    defaults write $app WebKitDeveloperExtrasEnabledPreferenceKey -bool YES # Show the Develop menu
    defaults write $app WebKitPreferences.developerExtrasEnabled -bool YES  # Show the Develop menu
    defaults write $app IncludeDevelopMenu -bool YES                        # Show the Develop menu
    defaults write $app ShowOverlayStatusBar -bool YES                      # Show the status bar
    defaults write $app HistoryAgeInDaysLimit -int 365000                   # Keep history "forever"
    defaults write $app SearchProviderIdentifier -string "com.duckduckgo"
    defaults write $app ShowIconsInTabs -bool YES
    defaults write com.apple.Safari WarnAboutFraudulentWebsites -bool true # Warn about fraudulent websites
    { set +x; } 2>/dev/null
  done

  for app in com.apple.Safari.SandboxBroker com.apple.SafariTechnologyPreview.SandboxBroker; do
    set -x
    defaults write $app ShowDevelopMenu -bool YES
    { set +x; } 2>/dev/null
  done
  set -x

  # Mail
  killall Mail 2>/dev/null
  defaults write ~/Library/Containers/com.apple.Mail/Data/Library/Preferences/com.apple.mail NumberOfSnippetLines 5 # Show 5 lines of mail preview
  defaults write com.apple.mail AddressesIncludeNameOnPasteboard -bool false                                        # Don't include full names in pasteboard

  # Activity Monitor
  killall Activity\ Monitor 2>/dev/null
  defaults write com.apple.ActivityMonitor UpdatePeriod -int 1           # Update frequently
  defaults write com.apple.ActivityMonitor IconType -int 5               # Set the dock icon to CPU usage
  defaults write com.apple.ActivityMonitor DisplayType -int 4            # Samples show percentage of thread
  defaults write com.apple.ActivityMonitor ShowCategory -int 100         # Show All Process
  defaults write com.apple.ActivityMonitor SortColumn -string "CPUUsage" # Sort by CPU usage
  defaults write com.apple.ActivityMonitor SortDirection -int 0

  # Disk Utility
  killall Disk\ Utility 2>/dev/null
  defaults write com.apple.DiskUtility SidebarShowAllDevices -bool YES      # Show all devices in the sidebar
  defaults write com.apple.DiskUtility WorkspaceShowAPFSSnapshots -bool YES # Show APFS shapshots

  # Clock
  defaults write com.apple.menuextra.clock DateFormat -string "EEE MMM d  h:mm:ss"

  # Global
  defaults write -g AppleKeyboardUIMode -int 3         # Full keyboard access in controls
  defaults write -g NSQuitAlwaysKeepsWindows -bool YES # Keep windows on quit

  # Time Machine
  defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true # Prevent Time Machine from prompting to use new hard drives as backup volume

  # Automatically quit printer app once the print jobs complete
  defaults write com.apple.print.PrintingPrefs "Quit When Finished" -bool true

  # Increase sound quality for Bluetooth headphones/headsets
  defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 40

  # Enable full keyboard access for all controls
  # (e.g. enable Tab in modal dialogs)
  defaults write NSGlobalDomain AppleKeyboardUIMode -int 3

  echo "System defaults applied."
  { set +x; } 2>/dev/null
}

# Function to configure system keyboard shortcuts
# Modifier-Maske (NSEvent flags):
#   Cmd     = 1048576 (0x100000)
#   Shift   =  131072 (0x020000)
#   Option  =  524288 (0x080000)
#   Control =  262144 (0x040000)
# Keycodes: Left=123, Right=124, Down=125, Up=126
setKeyboardShortcuts() {
  echo "Configuring system keyboard shortcuts..."
  set -x

  # Screenshot-Shortcuts deaktivieren
  #   28 = Save picture of screen as a file       (Cmd+Shift+3)
  #   29 = Copy picture of screen to clipboard    (Cmd+Ctrl+Shift+3)
  #   30 = Save picture of selected area as file  (Cmd+Shift+4)
  #   31 = Copy selected area to clipboard        (Cmd+Ctrl+Shift+4)
  #  184 = Screenshot and recording options       (Cmd+Shift+5)
  for id in 28 29 30 31 184; do
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$id" \
      '<dict><key>enabled</key><false/></dict>'
  done

  # Native Space-Navigation deaktivieren — AeroSpace übernimmt die Workspaces.
  # Achtung: pro Richtung gibt es ZWEI Einträge, die zweite ist die
  # Shift-Variante ("Fenster mitnehmen"). Nur 79/80 zu deaktivieren lässt
  # den Rechts-Wechsel aktiv:
  #   79 = Move left a space           80 = Move left a space + Shift
  #   81 = Move right a space          82 = Move right a space + Shift
  # Ohne das kollidiert jede Ctrl+Alt+Pfeil-Bindung von AeroSpace mit macOS.
  for id in 79 80 81 82; do
    defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$id" \
      '<dict><key>enabled</key><false/></dict>'
  done

  # Services-Shortcuts entfernen (key_equivalent leeren — Service bleibt im Menü, nur das Tastenkürzel verschwindet)
  for service in \
    "com.apple.Terminal - Open man Page in Terminal - openManPage" \
    "com.apple.Terminal - Search man Page Index in Terminal - searchManPages" \
    "com.apple.Stickies - Make Sticky - makeStickyFromTextService" \
    "com.apple.ChineseTextConverterService - Convert Text from Simplified to Traditional Chinese - convertTextToTraditionalChinese" \
    "com.apple.ChineseTextConverterService - Convert Text from Traditional to Simplified Chinese - convertTextToSimplifiedChinese"
  do
    defaults write pbs NSServicesStatus -dict-add "$service" \
      '<dict><key>key_equivalent</key><string></string></dict>'
  done

  { set +x; } 2>/dev/null
  echo "Keyboard shortcuts configured. Re-login required for full effect."
  # cfprefsd killen, damit die Änderung beim nächsten Logout nicht überschrieben wird
  killall cfprefsd 2>/dev/null
  # Services-Cache aktualisieren
  /System/Library/CoreServices/pbs -flush 2>/dev/null
}

# Function to set the computer name
setComputername() {
  echo "Setting computer name to $computername..."
  sudo scutil --set ComputerName "$computername"
  sudo scutil --set HostName "$computername"
  sudo scutil --set LocalHostName "$computername"
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$computername"
}

# Function to configure energy settings
setEnergy() {
  echo "Configuring energy settings..."
  # Restart automatically on power loss
  sudo pmset -a autorestart 1
}

# Function to install software using Homebrew
softwareInstall() {
  echo "Installing software from Brewfile..."
  echo "Hinweis: Xcode und Logic Pro im Brewfile sind große Downloads — kann dauern."
  brew bundle --file ~/.dotfiles/Brewfile
}

# Placeholder for cloneAppDaten function
cloneAppDaten() {
  git clone
  # Additional commands for cloning app data
}

# Function for manual software installation
manualSoftwareInstall() {
  echo "Starting manual software installation..."

  gum style --foreground 111 'Setup mise (runtime manager — replaces asdf)'
  if ! command -v mise >/dev/null 2>&1; then
    brew install mise
  fi
  mkdir -p ~/.config/fish/conf.d && touch ~/.config/fish/config.fish
  if ! grep -q 'mise activate' ~/.config/fish/config.fish; then
    gum style --foreground 210 'Add mise-activation to fish'
    echo -e "\n# mise — runtime manager\nmise activate fish | source" >> ~/.config/fish/config.fish
  fi
  gum confirm "Setup latest Java (Temurin)?" && mise use --global java@latest
  gum confirm "Setup latest Node?" && mise use --global node@latest
  gum confirm "Setup latest Python?" && mise use --global python@latest

  gum style --foreground 190 'Setup Dev folders' && mkdir -p ~/dev/{personal,work,edu} && open ~/dev

  echo ""
  gum style --foreground 213 --bold 'Backup einrichten?'
  echo "  Wenn die Backup-Platte 'Backups' angeschlossen ist, hier den Bootstrap starten."
  gum confirm "Kopia-Backup-Continuity jetzt einrichten?" && bash /Volumes/Backups/RESTORE-HOWTO/bootstrap.sh

  if [ -d /Volumes/Backups/kopia-r-mac ]; then
    gum confirm "Kopia-Ignore-Regeln (Photos Library, iCloud-Mirror, Caches…) jetzt anwenden?" \
      && bash ~/.dotfiles/launchd/kopia-policy.sh
  fi
}

# Function to set the default shell
setDefaultShell() {
  echo "Setting the default shell..."
  FISH_PATH=$(which fish)
  if ! grep -q "$FISH_PATH" /etc/shells; then
    echo "Adding $FISH_PATH to /etc/shells"
    sudo sh -c "echo $FISH_PATH >> /etc/shells"
  else
    echo "$FISH_PATH is already in /etc/shells"
  fi
  chsh -s "$FISH_PATH"
  echo "Default shell changed to $FISH_PATH"
}

__dock_item() {
    printf '%s%s%s%s%s' \
           '<dict><key>tile-data</key><dict><key>file-data</key><dict>' \
           '<key>_CFURLString</key><string>' \
           "$1" \
           '</string><key>_CFURLStringType</key><integer>0</integer>' \
           '</dict></dict></dict>'
}

# Function to configure the Dock
setDock() {
  echo "Configuring the Dock..."

  gum style --foreground 190 'Clear Dock' && defaults write com.apple.dock persistent-apps -array

  gum style --foreground 190 'Update Dock'

  declare -a dockItems=(
    "/Applications/Safari.app"
    "/Applications/Firefox.app"
    "/Applications/Ghostty.app"
    "/Applications/Obsidian.app"
    "/Applications/BusyCal.app"
    "/Applications/ChatGPT.app"
    "/Applications/Claude.app"
    "/Applications/Slack.app"
    "/Applications/Microsoft Outlook.app"
    "/System/Applications/Music.app"
    "/Users/rubeen/Applications/IntelliJ IDEA.app"
  )

for dockItem in "${dockItems[@]}"; do
  [[ -e "$dockItem" ]] && defaults write com.apple.dock persistent-apps -array-add "$(__dock_item ${dockItem})"
done

  gum style --foreground 190 'Restart the Dock'
  killall Dock
}

setupSymlinks() {
  echo "Setting up Symlinks..."

  mkdir -p ~/.ssh/configs ~/.config

  # link: idempotent + sicher
  #   - missing source → skip
  #   - existing symlink → atomic replace (ln -sfn)
  #   - existing file/dir → backup, dann symlink (verhindert Datenverlust bei Re-Run)
  link() {
    local src="$1" dst="$2"
    if [ ! -e "$src" ]; then
      gum style --foreground 196 "  skip: source missing — $src"
      return
    fi
    if [ -L "$dst" ]; then
      ln -sfn "$src" "$dst"
      gum style --foreground 040 "  ✓ $dst → $src"
    elif [ -e "$dst" ]; then
      local backup="${dst}.backup-$(date +%Y%m%d-%H%M%S)"
      mv "$dst" "$backup"
      ln -sfn "$src" "$dst"
      gum style --foreground 040 "  ✓ $dst → $src  (alte Version: $backup)"
    else
      mkdir -p "$(dirname "$dst")"
      ln -sfn "$src" "$dst"
      gum style --foreground 040 "  ✓ $dst → $src"
    fi
  }

  # Shell + Git + SSH
  link ~/.dotfiles/ssh/config             ~/.ssh/config
  link ~/.dotfiles/git/.gitconfig         ~/.gitconfig
  link ~/.dotfiles/testcontainers.properties ~/.testcontainers.properties
  link ~/.dotfiles/fish                   ~/.config/fish

  # Prompt + Terminal-Tools
  link ~/.dotfiles/starship.toml          ~/.config/starship.toml
  link ~/.dotfiles/ghostty                ~/.config/ghostty
  link ~/.dotfiles/atuin                  ~/.config/atuin
  link ~/.dotfiles/btop                   ~/.config/btop
  link ~/.dotfiles/topgrade.toml          ~/.config/topgrade.toml

  # Dev/CLI
  link ~/.dotfiles/jj                     ~/.config/jj
  link ~/.dotfiles/fabric                 ~/.config/fabric

  # Window/Status
  link ~/.dotfiles/aerospace              ~/.config/aerospace
  link ~/.dotfiles/borders                ~/.config/borders
  link ~/.dotfiles/sketchybar             ~/.config/sketchybar

  # Raycast / Docker
  link ~/.dotfiles/raycast                ~/.config/raycast
  link ~/.dotfiles/docker/canary.json     ~/.docker/canary.json

  # r-tools (eigene Skripte): Symlink zur stabilen Location.
  # PATH wird in fish/config.fish via `fish_add_path $HOME/.dotfiles/r-tools` gesetzt
  # (funktioniert auch ohne Symlink — der Symlink ist Konsistenz-Halber dabei).
  link ~/.dotfiles/r-tools                ~/.local/share/r-tools

  # LaunchAgents (das Plist verweist intern auf den Skript-Pfad in ~/.dotfiles/launchd)
  link ~/.dotfiles/launchd/dev.rubeen.kopia.snapshot.plist       ~/Library/LaunchAgents/dev.rubeen.kopia.snapshot.plist
  link ~/.dotfiles/launchd/dev.rubeen.clean-ica-downloads.plist  ~/Library/LaunchAgents/dev.rubeen.clean-ica-downloads.plist
}

# Executing functions
installBrewAndGum
setDefaults
setKeyboardShortcuts
setComputername
setEnergy
softwareInstall
manualSoftwareInstall
setDefaultShell
setupSymlinks
gum confirm "Do you like to reinitialize the Dock?" && setDock

echo "Setup complete!"
