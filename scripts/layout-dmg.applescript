on run argv
    set volumeName to item 1 of argv

    tell application "Finder"
        tell disk volumeName
            open
            set containerWindow to container window
            set current view of containerWindow to icon view
            set toolbar visible of containerWindow to false
            set statusbar visible of containerWindow to false
            set pathbar visible of containerWindow to false
            set sidebar width of containerWindow to 0
            set bounds of containerWindow to {120, 120, 720, 512}

            set viewOptions to icon view options of containerWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 14
            set background picture of viewOptions to file ".background:background.png"

            set position of item "MacDrop.app" to {150, 185}
            set position of item "Applications" to {450, 185}
            set extension hidden of item "MacDrop.app" to true

            update without registering applications
            delay 2
            close containerWindow
        end tell
    end tell
end run
