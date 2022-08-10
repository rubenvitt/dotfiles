#!/bin/sh

set -e

#requrire one argument "appname"
if [ $# -ne 1 ]; then
  echo "Usage: $0 'appname'"
  exit 1
fi

__dock_item() {
    printf '%s%s%s%s%s' \
           '<dict><key>tile-data</key><dict><key>file-data</key><dict>' \
           '<key>_CFURLString</key><string>' \
           "$1" \
           '</string><key>_CFURLStringType</key><integer>0</integer>' \
           '</dict></dict></dict>'
}

printf '%s' 'Setting up Dock icons...'
# clear items
# defaults write com.apple.dock persistent-apps -array

# for dockItem in {/System/Applications/{"Mail","Notes","System Preferences","App Store","Preview"},/Applications/{"iTerm","Visual Studio Code"}}.app; do
#   defaults write com.apple.dock persistent-apps -array-add "$(__dock_item ${dockItem})"
# done

# persistent-apps -array "$(__dock_item /Applications/Safari.app)" \
#     "$(__dock_item /System/Applications/Utilities/Terminal.app)"

defaults write com.apple.dock persistent-apps -array-add "$(__dock_item /Applications/$1.app)"

killall Dock
printf '%s\n' ' done.'
