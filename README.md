Aufnahmesteuerung ADD-Eingabe:
powershell.exe -ExecutionPolicy Bypass -File "e2.ps1" -Action add -channel_name "{channel_name_external}" -title "{title}" -start_unix {start_unix} -end_unix {end_unix} -description "{maxlength(replace(replace(cleanLess(description), "_______::_,______::_,_____::_,____::_,___::_,__::_"), "_:: "), "255")}" -AfterEvent "2"

Aufnahmesteuerung ADD-Beispiel:
powershell.exe -ExecutionPolicy Bypass -File "e2.ps1" -Action add -channel_name "Das Erste HD" -title "Tagesschau" -start_unix 1784570400 -end_unix 1784571300 -description "Die Nachrichten der ARD by DasErste" -AfterEvent "2"

Aufnahmesteuerung DELETE-Eingabe:
powershell.exe -Executionpolicy Bypass -File "e2.ps1" -Action "delete" -channel_name "{channel_name_external}" -title "{title}" -start_unix {start_unix}

Aufnahmesteuerung DELETE-Eingabe:
powershell.exe -Executionpolicy Bypass -File "e2.ps1" -Action "delete" -channel_name "Das Erste HD" -title "Tagesschau" -start_unix 1784570400
