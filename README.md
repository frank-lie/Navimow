# Navimow Cloud Support für FHEM (58_Navimow.pm)

Es handelt sich um ein Modul für FHEM, um Navimow Mähroboter von Segway über die Navimow-Cloud in FHEM zu integrieren. Die Schnittstelle ist offiziell von Navimow unter https://github.com/segwaynavimow/navimow-sdk veröffentlicht. Unterstützt werden sowohl die Abfragen über die REST API (HTTP-Requests) als auch die MQTT-basierte Anbindung für Echtzeitinformationen.

## Vorbereitung

Die Navimow-App muss eingerichtet und die Mähroboter mit dieser App bzw. diesem Account verbunden sein.

## Installation und Verwendung 

1. Damit das Modul in FHEM verwendet werden kann, ist der folgende update-Befehl in FHEM auszuführen:
   
   ```
   update all https://raw.githubusercontent.com/frank-lie/Navimow/main/controls_Navimow.txt
   ```
   Alternativ kann auch die Datei "FHEM/58_Navimow.pm" manuell in den Ordner fhem/FHEM kopiert werden.   
> [!TIP]
> Um automatisch immer die aktuelle Version des Moduls im Rahmen des FHEM-Befehls `update` zu erhalten, kann man den Link auch generell als Update-Quelle hinzufügen:
>```
>update add https://raw.githubusercontent.com/frank-lie/Navimow/main/controls_Navimow.txt
>``` 

2. Nach einem Update von FHEM sollte in der Regel ein Neustart von FHEM gemacht werden, damit alle Änderungen ordnungsgemäß geladen werden:
   ```
   shutdown restart
   ```

3. Für die Kommunikation mit der Navimow-Cloud ist in FHEM zunächst ein Master-Device anzulegen, welches als Bridge fungiert: 
   ```
   define Navimow_Bridge Navimow [<CLIENT_ID> <CLIENT_SECRET> <REDIRECT_URI>]
   ```
   CLIENT_ID, CLIENT_SECRET, REDIRECT_URI brauchen nicht angegeben werden. In diesem Fall werden Standardwerte benutzt, die ebenfalls bei der Anbindung an Home-Assistant Anwendung finden (vgl. auch offizielle Seite von Navimow for Home Assistant https://github.com/segwaynavimow/NavimowHA).

4. Sobald das Master-Device erstellt worden ist, kann der AUTHORIZATION_LINK (zu finden als INTERNAL im Master-Device) aufgerufen werden, um den Autorisierungsprozess zu starten. Ihr werdet auf die Seite von Navimow geleitet, müsst euch dort einloggen und das Captcha lösen. Anschließend werdet ihr auf die REDIRECT_URI weitergeleitet, um den einmaligen Autorisierungscode zu bekommen.

5. Wenn ihr eine individuelle REDIRECT_URI für FHEM konfiguriert habt, wird der Autorisierungscode automatisch an FHEM übergeben. Wenn ihr die oben genannten Standardwerte verwendet habt, wird euer Browser versuchen die lokale Seite "http://localhost/callback?code=xxxxx" zu öffnen und sagen das die Verbindung fehlgeschlagen ist. Das ist nicht schlimm, denn ihr benötigt lediglich den kompletten Link der Internetseite aus dem Browser. Kopiert also den vollständigen Link "http://localhost/callback?code=xxxxx" in die Zwischenablage und gebt manuell in FHEM als set-command ein:
   ```
   set Navimow_Bridge AuthCode <kompletter Link der Rückgabe-URL>
   ```

6. Mit dem Setzen des Autorisierungscodes bekommt FHEM die erforderlichen Token für den Zugriff auf die Navimow-Cloud übermittelt. Die Einrichtung des Master-Devices ist damit abgeschlossen. Die Mähroboter werden standardmäßig beim Abruf der Daten aus der Cloud als Device in FHEM angelegt. Im Anschluss wird automatisch eine MQTT-Verbindung zum Navimow-Server hergestellt, damit die Real-Time-Daten per MQTT empfangen werden können.

## Hinweise für die Benutzung einer individuellen REDIRECT_URI

Es besteht auch die Möglichkeit, eine individuelle `REDIRECT_URI` für FHEM zu definieren. Diese muss nach folgendem Schema erstellt/definiert werden: `http(s)://<IP-FHEM-Server>:8083/fhem?cmd=set%20<Master-Device-Name>%20AuthCode%20`. Hierbei ist zu beachten, dass wenn ihr euer FHEM mit SSL benutzt, die REDIRECT_URI natürlich zwingend mit `https://` beginnen muss. IP-FHEM-Server und Master-Device-Name sind durch die entsprechende IP und Device-Namen zu ersetzen. Der Device-Name muss urlEncoded sein! Ferner ist zu beachten, dass bei Nutzung des csrfToken in FHEM (Standard ab FHEM-Version 5.8) noch ein `&fwcsrf=<dein CSRF-Token>` angehangen wird (zu ersetzen durch den jeweiligen CSRF-Token -> vgl. INTERNAL CSRFTOKEN im Device FHEMWEB). Das ganze macht natürlich nur Sinn, wenn man ein statisches CSRF-Token verwendet.

Beispiel für eine individuelle REDIRECT_URI könnte damit sein: `https://192.168.178.100:8083/fhem?cmd=set%20Navimow%5FBridge%20AuthCode%20&fwcsrf=csrf_1234`

Da der Autorisierungsprozess jedoch nur einmal absolviert werden muss, ist der Aufwand für das definieren der individuellen REDIRECT_URI recht hoch und birgt verschiedene Fallstricke. Daher würde ich jedem Einsteiger emfpfehlen, das Master-Device einfach mit `define Navimow_Bridge Navimow` zu erstellen und den Autorisierungscode manuell aus der Browserzeile in die Zwischenablage zu kopieren und mit `set Navimow_Bridge AuthCode <Zwischenablage>` an FHEM zu übergeben.

## Readings im Master-Device / Bridge

Aus den Readings im Master-Device kann abgelesen werden, ob der Autorisierungsprozess ordnungsgemäß durchlaufen ist bzw. ob die MQTT-Verbindung erfolgreich hergestellt worden ist:

| Reading | Bedeutung |
| :--- | :--- |
| code | Rückgabe-Code des HTTP-Requests |
| desc | Rückgabe-Beschreibung des HTTP-Requests |
| expires_in | Gültigkeit des Access-Tokens (in der Regel 3600 Sekunden gültig, wird immer automatisch vor Ablauf erneuert) |
| mqtt_connect | Status der MQTT-Anmeldung |
| mqtt_keepalive | letzter MQTT-Ping |
| mqtt_subscribe | Angabe, ob MQTT-Topics erfolgreich abonniert wurden |
| polling | Angabe, ob HTTP-Request regelmäßig erfolgen |
| state | Status der MQTT-Verbindung  |
| token_status | Tokenstatus (für HTTP-Requests)  |
| token_type | Der Token-Type ist standardmäßig "Bearer" |
| update_response | Angabe, ob die JSON mittels JSON_XS oder anderweitig geparsed werden. |

## Readings Mähroboter-Device

Die Readings in den Mähroboter-Devices fallen je nach Gerät ggf. unterschiedlich aus. Es sind auch noch nicht bei allen Daten die Inhalte hinreichend bekannt bzw. genau genug definiert. Hier beispielhaft ein paar Angaben:

| Reading | Protokoll | HTTP-Request/MQTT-Topic | Type  | Bedeutung |
| :--- | :--- | :--- |:--- |:--- |
| firmware | HTTP | get devices |-| Firmware-Version des Gerätes |
| id | HTTP | get devices |-| Seriennummer des Gerätes |
| model | HTTP | get devices |-| Modellbezeichnung des Gerätes |
| name | HTTP | get devices |-| Name des Gerätes |
| | | | |
| capacityRemaining_rawValue | HTTP | get devicestatus |-| Ladezustand Batterie |
| capacityRemaining_unit | HTTP | get devicestatus |-| Einheit zum Ladezustand |
| descriptiveCapacityRemaining | HTTP | get devicestatus |-| verbleibender Ladezustand der Batterie in Textform |
| vehicleState | HTTP | get devicestatus |-| Status des Gerätes in Textform |
| | | | |
| cmdNum | HTTP | set (cmd) |-| Rückgabe zum letzten von FHEM gesendeten Befehl |
| set_cmd | HTTP | set (cmd) |-| letzter von FHEM gesendeter Befehl |
| | | | |
| action | MQTT | location | 2 |  |
| currentMowBoundary | MQTT | location | 2 | aktuelle Mähzone (Nummerierung lt. Navimow-App |
| currentMowProgress| MQTT | location | 2 | aktueller Mähfortschritt in der aktuellen Mähzone (10.000 = 100%) |
| mapWorkPosition | MQTT | location | 2 |  |
| mowStartType | MQTT| location | 2 |  |
| mowingPercentage | MQTT | location | 2 | Mähfortschritt insgesamt in % |
| mowingWeekArea | MQTT | location | 2 | gemähte Fläche diese Woche im qm |
| partitionIds | MQTT | location | 3 |  |
| postureTheta | MQTT | location | 1 | Ausrichtung des Gerätes / Radiant |
| postureX | MQTT | location | 1 | Position relativ zur Dockingstation (Ost-West), ggf. noch Offset-Bereinigung erforderlich |
| postureY | MQTT | location | 1 | Position relativ zur Dockingstation (Nord-Süd), ggf. noch Offset-Bereinigung erforderlich |
| subAction | MQTT | location | 2 |  |
| subtotalArea | MQTT | location | 2 | (?) Mähfortschritt in der aktuellen Mähzone in % |
| time | MQTT | location | 1,2,3 | letzter Zeitstempel von "realtimeDate/location" |
| vehicleState_Num | MQTT | location | 1 | Status des Gerätes |
| taskDelay | MQTT | location | 4 | (?) Verzögerung durch Nacht oder Wetter (Regen, Schnee, Heißes Wetter, Frost, Wind)  |
| type | MQTT | location | 1,2,3,4 | Type der Payload/Inhalt |
| | | | |
| battery| MQTT | state |-| Ladezustand Batterie in Prozent |
| device_id | MQTT | state |-| Seriennummer des Gerätes |
| state | MQTT | state |-| Status des Gerätes in Klartext |
| timestamp | MQTT | state |-| letzter Zeitstempel von "realtimeDate/state" |

MQTT mit dem Topic "location" werden regelmäßig nur gepublished, wenn das Gerät aktiv bzw. in Bewegung ist. MQTT mit dem Topic "state" werden regelmäßig mit Statusänderung des Gerätes gepublished bzw. wenn sich der Ladezustand der Batterie (in Prozent) verändert hat. Dadurch können sich Differenzen zu den zeitlich verzögerten Angaben aus den HTTP-Requests ergeben.
