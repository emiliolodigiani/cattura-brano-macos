-- Droplet "Crea DMG": crea il DMG di distribuzione di Cattura Brano.
--
-- Doppio clic: trova da solo l'app esportata più recente (Scrivania e
-- Download, anche in sottocartelle) e chiede conferma; altrimenti lascia
-- scegliere a mano. Nota: macOS non consegna mai un'app trascinata sopra
-- un'altra app, quindi il drag & drop di una .app non può funzionare —
-- il doppio clic è la via.

on run
	set candidate to do shell script "ls -td \"$HOME/Desktop/Cattura Brano.app\" \"$HOME/Downloads/Cattura Brano.app\" $HOME/Desktop/*/\"Cattura Brano.app\" $HOME/Downloads/*/\"Cattura Brano.app\" 2>/dev/null | head -1"
	if candidate is not "" then
		set theChoice to button returned of (display dialog ¬
			"App esportata trovata:" & return & candidate & return & return & ¬
			"Creare il DMG di distribuzione?" ¬
			buttons {"Annulla", "Scegli un'altra…", "Crea DMG"} default button "Crea DMG")
		if theChoice is "Crea DMG" then
			creaDMG(candidate)
			return
		else if theChoice is "Annulla" then
			return
		end if
	end if
	set theApp to choose file of type {"com.apple.application-bundle"} ¬
		with prompt "Scegli la \"Cattura Brano.app\" esportata dall'Organizer:"
	creaDMG(POSIX path of theApp)
end run

on open theItems
	repeat with anItem in theItems
		creaDMG(POSIX path of anItem)
	end repeat
end open

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
