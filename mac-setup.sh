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
  defaults write com.apple.dock expose-animation-duration -float 0.12 # Set animation duration
  defaults write com.apple.dock mineffect -string suck                # Use the suck animation for minimization
  defaults write com.apple.dock show-recents -bool NO                 # Disable recent apps
  defaults write com.apple.dock autohide-delay -float 0; killall Dock
  defaults write com.apple.dock autohide-time-modifier -float 0.15; killall Dock
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

  gum style --foreground 111  'Installing asdf & latest Temurin'
  mkdir -p ~/.config/fish && touch ~/.config/fish/config.fish
  grep -q 'asdf.fish' ~/.config/fish/config.fish || (gum style --foreground 210 'Add asdf-config to fish' && echo -e "\nsource "$(brew --prefix asdf)"/libexec/asdf.fish" >> "~/.config/fish/config.fish")
  gum confirm "Setup latest Java?" && asdf plugin-add java && asdf install java $(asdf list-all java |fzf)
  gum confirm "Setup latest Node?" && asdf plugin-add nodejs && asdf install nodejs latest
  askToInstall 'Safari Technology Preview' 'https://developer.apple.com/safari/technology-preview/'
  gum style --foreground 190 'Setup Dev folders' && mkdir -p ~/dev/{personal,work,edu} && open ~/dev
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
    "/Applications/Safari Technology Preview.app"
    "/Applications/Arc.app"
    "/Applications/Warp.app"
    "/Applications/Notion.app"
    "/Applications/BusyCal.app"
    "/System/Applications/Mail.app"
    "/System/Applications/Music.app"
    "/Users/rubeen/Applications/Fleet.app"
    "/Users/rubeen/Applications/IntelliJ IDEA Ultimate.app"
  )

  for dockItem in "${dockItems[@]}"; do
    defaults write com.apple.dock persistent-apps -array-add "$(__dock_item ${dockItem})"
  done

  gum style --foreground 190 'Restart the Dock'
  killall Dock
}

setupSymlinks() {
  echo "Setting up Symlinks..."

  mkdir -p ~/.ssh/configs
  ln -s ~/.dotfiles/ssh/config ~/.ssh/config
  ln -s ~/.dotfiles/git/.gitconfig ~/.gitconfig
  ln -s ~/.dotfiles/testcontainers.properties ~/.testcontainers.properties
  ln -s ~/.dotfiles/fish ~/.config/
  ln -s ~/.dotfiles/vimrc ~/.vimrc
}

# Executing functions
installBrewAndGum
setDefaults
setComputername
setEnergy
softwareInstall
manualSoftwareInstall
setDefaultShell
setupSymlinks
gum confirm "Do you like to reinitialize the Dock?" && setDock

echo "Setup complete!"
