-- Droplet: trascina sopra l'icona la "Cattura Brano.app" esportata
-- dall'Organizer e ottieni il DMG di distribuzione nella stessa cartella.
on open theItems
	repeat with anItem in theItems
		set appPath to POSIX path of anItem
		try
			do shell script "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH " & ¬
				quoted form of "/Users/emi/workspace/cattura brano/scripts/crea-dmg.sh" & ¬
				" " & quoted form of appPath
			display notification "DMG creato accanto all'app" with title "Crea DMG" sound name "Glass"
		on error errorMessage
			display dialog "Creazione DMG non riuscita: " & errorMessage buttons {"OK"} with icon stop
		end try
	end repeat
end open

on run
	display dialog "Trascina qui sopra la \"Cattura Brano.app\" esportata dall'Organizer per creare il DMG di distribuzione." buttons {"OK"} default button "OK"
end run
