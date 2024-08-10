use scripting additions

set destination to "/Users/rubeen/.config/fabric/patterns/"
set logFile to (path to home folder as text) & "Desktop:folder_action_log.txt"

on add_to_log(message)
    try
        do shell script "echo " & quoted form of ((current date) as string) & ": " & quoted form of message & " >> " & quoted form of POSIX path of logFile
    on error
        display dialog "Fehler beim Schreiben in die Log-Datei: " & logFile
    end try
end add_to_log

on adding folder items to theAttachedFolder after receiving theNewItems
    add_to_log("Neue Elemente erkannt in: " & POSIX path of theAttachedFolder)

    -- Überprüfen, ob der Zielordner existiert
    try
        do shell script "test -d " & quoted form of destination
    on error
        display dialog "Zielordner existiert nicht: " & destination
        add_to_log("Fehler: Zielordner existiert nicht: " & destination)
        return
    end try

    tell application "Finder"
        repeat with anItem in theNewItems
            set itemPath to POSIX path of anItem
            set fileName to name of anItem
            set destPath to destination & fileName

            add_to_log("Versuche Link zu erstellen für: " & itemPath)

            try
                do shell script "ln -s " & quoted form of itemPath & " " & quoted form of destPath
                display notification "Symbolischer Link erstellt" message "Von: " & itemPath & " Nach: " & destPath
                add_to_log("Link erfolgreich erstellt: " & destPath)
            on error errMsg
                display dialog "Fehler beim Erstellen des symbolischen Links für " & fileName & ": " & errMsg
                add_to_log("Fehler beim Erstellen des Links: " & errMsg)
            end try
        end repeat
    end tell
end adding folder items to

on removing folder items from theAttachedFolder
    tell application "Finder"
        set theName to POSIX path of theAttachedFolder
        display notification "Elemente entfernt" message "Aus dem Ordner: " & theName
        add_to_log("Elemente entfernt aus: " & theName)
    end tell
end removing folder items from

add_to_log("Skript geladen und bereit")
