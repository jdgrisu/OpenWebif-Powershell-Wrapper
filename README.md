[Kurzes HowTo:]

1. Anpassen der e2-config.ini an die eigene Infrastruktur
2. Ablegen der e2.ps1 sowie der e2-config.ini unter 'C:\Program Files\TV-Browser'
3. Zuweisen der Programmekanalnamen in die Aufnahmesteuerung
4. e2.ps1 Skript aus dem Aufnahmesteuerung-Plugin mittles Powershell.exe aufrufen

[Pflichtangaben in e2-config.ini - Receiver]
- IP und Port vom Enigma2 Server in url eintragen - Beispiel 'url=http://192.1.2.3:80'

[Pflichtangaben in e2-config.ini - Timer]
- Für Aufnahmen die Vorlaufzeiten in Sekunden festlegen - Beispiel 'PrePadding=300'
- Für Aufnahmen die Nachlaufzeiten in Sekunden festlegen - Beispiel 'PostPadding=480'

[Pflichtangaben in e2-config.ini - System]
- Den Loglevel festlegen - Zulässige Werte sind 'DEBUG', 'INFO', 'WARN', 'ERROR' - Beispiel 'loglevel=INFO'
- Den Ort der Logfile festlegen - Beispiel 'logfile=%APPDATA%\TV-Browser\e2.log'
- Für die EPG-Suche die EPG Tolerance in Sekunden anpassen - Beispiel 'epg_tolerance=180'

[Pflichtangaben in e2-config.ini - Channels]
- Programmkanäle werde nicht per Name sondern per ChannelId aufgelöst
- Auslesen per Aufruf von 'http://192.1.2.3:80/api/getallservices'
- Übertragen aller gewünschten Kanäle in den Channels Abschnitt - Beispiel 'Das Erste HD=1:0:12:3456:789:1:FFFF0000:0:0:0:'
- Hinweis: Eintragen der exakt gleichen Kanal-Namen in die Aufnahmesteuerung notwendig

[Aufruf aus der Aufnahmesteuerung im TV-Browser]

Aufnahmesteuerung ADD-Eingabe:
powershell.exe -ExecutionPolicy Bypass -File "e2.ps1" -Action add -channel_name "{channel_name_external}" -title "{title}" -start_unix {start_unix} -end_unix {end_unix} -description "{maxlength(replace(replace(cleanLess(description), "_______::_,______::_,_____::_,____::_,___::_,__::_"), "_:: "), "255")}" -AfterEvent "2"

Aufnahmesteuerung ADD-Beispiel:
powershell.exe -ExecutionPolicy Bypass -File "e2.ps1" -Action add -channel_name "Das Erste HD" -title "Tagesschau" -start_unix 1784570400 -end_unix 1784571300 -description "Die Nachrichten der ARD by DasErste" -AfterEvent "2"

Aufnahmesteuerung DELETE-Eingabe:
powershell.exe -Executionpolicy Bypass -File "e2.ps1" -Action "delete" -channel_name "{channel_name_external}" -title "{title}" -start_unix {start_unix}

Aufnahmesteuerung DELETE-Eingabe:
powershell.exe -Executionpolicy Bypass -File "e2.ps1" -Action "delete" -channel_name "Das Erste HD" -title "Tagesschau" -start_unix 1784570400

[Vorlagen für TV-Browser - Aufnahmesteuerung für den Zugriff auf Enigma2-Receivern]

Aufnamesteuerung - Einstellungen - Gerät importieren - e2-Auto.tcf oder e2-DeepStandby.tcf wählen

[Infos zur OpenWebif-API auf Enigma2-Receivern]

https://github.com/E2OpenPlugins/e2openplugin-OpenWebif/wiki/OpenWebif-API-documentation
