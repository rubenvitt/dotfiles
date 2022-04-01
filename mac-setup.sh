#!/bin/zsh

#requrire one argument "computername"
if [ $# -ne 1 ]; then
  echo "Usage: $0 computername"
  exit 1
fi

computername=$1

osascript -e 'tell application "System Preferences" to quit'

setDefaults() {
  set -x

  # Dock
  defaults write com.apple.dock showAppExposeGestureEnabled -bool YES # Enable the Expose gesture
  defaults write com.apple.dock mru-spaces -bool NO                   # Disable reordering Spaces based on use
  defaults write com.apple.dock expose-group-apps -bool YES           # Group apps in Expose
  defaults write com.apple.dock mineffect -string suck                # Use the suck animation for minimization
  defaults write com.apple.dock show-recents -bool NO                 # Disable recent apps
  killall Dock 2>/dev/null

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

  # AppKit
  defaults write -g _NS_4445425547 -bool YES # Show an internal AppKit debug menu

  # Orion
  killall Orion 2>/dev/null
  defaults write com.kagi.kagimacOS HomePageURL "https://kagi.com"

  # Time Machine
  defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true # Prevent Time Machine from prompting to use new hard drives as backup volume

  # Automatically quit printer app once the print jobs complete
  defaults write com.apple.print.PrintingPrefs "Quit When Finished" -bool true

  # Increase sound quality for Bluetooth headphones/headsets
  defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 40

  # Enable full keyboard access for all controls
  # (e.g. enable Tab in modal dialogs)
  defaults write NSGlobalDomain AppleKeyboardUIMode -int 3

  { set +x; } 2>/dev/null
}

setComputername() {
  echo "Setting computer name to $computername"
  exit 2
  sudo scutil --set ComputerName "$computername"
  sudo scutil --set HostName "$computername"
  sudo scutil --set LocalHostName "$computername"
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$computername"
}

setEnergy() {
  # Restart automatically on power loss
  sudo pmset -a autorestart 1
}

setDefaults
setComputername
setEnergy
