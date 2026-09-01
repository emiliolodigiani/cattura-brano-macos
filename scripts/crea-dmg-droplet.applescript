-- Droplet "Crea DMG": crea il DMG di distribuzione di Cattura Brano.
-- Doppio clic: chiede quale app impacchettare. Drag & drop: la impacchetta.

on open theItems
	repeat with anItem in theItems
		creaDMG(POSIX path of anItem)
	end repeat
end open

on run
	set theApp to choose file of type {"com.apple.application-bundle"} ¬
		with prompt "Scegli la \"Cattura Brano.app\" esportata dall'Organizer:"
	creaDMG(POSIX path of theApp)
end run

on creaDMG(appPath)
	try
		do shell script "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH " & ¬
			quoted form of "/Users/emi/workspace/cattura brano/scripts/crea-dmg.sh" & ¬
			" " & quoted form of appPath
		display notification "DMG creato accanto all'app" with title "Crea DMG" sound name "Glass"
		display dialog "DMG creato accanto all'app." buttons {"OK"} default button "OK" giving up after 6
	on error errorMessage
		display dialog "Creazione DMG non riuscita: " & errorMessage buttons {"OK"} with icon stop
	end try
end creaDMG
