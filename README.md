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

4. Sobald das Master-Device erstellt worden ist, kann der AUTHORIZATION_LINK (zu finden als INTERNAL im Master-Device) aufgerufen werden, um den Authorisierungsprozess zu starten. Ihr werdet auf die Seite von Navimow geleitet, müsst euch dort einloggen und das Captcha lösen. Anschließend werdet ihr auf die REDIRECT_URI weitergeleitet, um den einmaligen Authorisierungscode zu bekommen.

5. Wenn ihr eine individuelle REDIRECT_URI für FHEM konfiguriert habt, wird der Authorisierungscode automatisch an FHEM übergeben. Wenn ihr die oben genannten Standardwerte verwendet habt, wird euer Browser versuchen die lokale Seite "http://localhost/callback?code=xxxxx" zu öffnen und sagen das die Verbindung fehlgeschlagen ist. Das ist nicht schlimm, denn ihr benötigt lediglich den kompletten Link der Internetseite aus dem Browser. Kopiert also den vollständigen Link "http://localhost/callback?code=xxxxx" in die Zwischenablage und gebt manuell in FHEM als set-command ein:
   ```
   set Navimow_Bridge AuthCode <kompletter Link der Rückgabe-URL>
   ```

6. Mit dem Setzen des Authorisierungscodes bekommt FHEM die erforderlichen Token für den Zugriff auf die Navimow-Cloud übermittelt. Die Einrichtung des Master-Devices ist damit abgeschlossen. Die Mähroboter werden standardmäßig beim Abruf der Daten aus der Cloud als Device in FHEM angelegt. Im Anschluss wird automatisch eine MQTT-Verbindung zum Navimow-Server hergestellt, damit die Real-Time-Daten per MQTT empfangen werden können.

## Readings im Master-Device / Bridge

Aus den Readings im Master-Device kann abgelesen werden, ob der Authorisierungsprozess ordnungsgemäß durchlaufen ist bzw. ob die MQTT-Verbindung erfolgreich hergestellt worden ist:

| Reading | Bedeutung |
| :--- | :--- |
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

| Reading | Herkunft | Bedeutung |
| :--- | :--- | :--- |
| capacityRemaining_rawValue | HTTP | Ladezustand Batterie |
| capacityRemaining_unit | HTTP | Einheit zum Ladezustand |
| cmdNum | HTTP | Rückgabenummer wenn Cmd über FHEM gesetzt wurde  |
| descriptiveCapacityRemaining | HTTP | verbleibender Ladezustand der Batterie in Textform |
| firmware | HTTP | Firmware-Version des Gerätes |
| id | HTTP | Seriennummer des Gerätes |
| model | HTTP | Modellbezeichnung des Gerätes |
| name | HTTP | Name des Gerätes |
| vehicleState | HTTP | Status des Gerätes  |
| | | |
| action | MQTT | |
| battery| MQTT | Ladezustand Batterie in Prozent |
| currentMowBoundary | MQTT | aktuelle Mähzone (Nummerierung lt. Navimow-App |
| currentMowProgress| MQTT | aktueller Mähfortschritt in der aktuellen Mähzone (10.000 = 100%) |
| device_id | MQTT | Seriennummer des Gerätes |
| mapWorkPosition | MQTT |  |
| mowStartType | MQTT |  |
| mowingPercentage | MQTT | Mähfortschritt insgesamt in % |
| mowingWeekArea | MQTT | gemähte Fläche diese Woche im qm |
| postureTheta | MQTT | Ausrichtung des Gerätes / Radiant |
| postureX | MQTT | Position relativ zur Dockingstation (Ost-West), ggf. noch Offset-Bereinigung erforderlich |
| postureY | MQTT | Position relativ zur Dockingstation (Nord-Süd), ggf. noch Offset-Bereinigung erforderlich |
| state | MQTT | Status des Gerätes in Klartext |
| subAction | MQTT |  |
| subtotalArea | MQTT | (?) Mähfortschritt in der aktuellen Mähzone in %|
| taskDelay | MQTT |  (?) Verzögerung durch Nacht oder Wetter (Regen, Schnee, Heißes Wetter, Frost, Wind)  |
| time | MQTT | letzter Zeitstempel von "realtimeDate/location" |
| timestamp | MQTT | letzter Zeitstempel von "realtimeDate/state" |
| type | MQTT | Type der MQTT-Message mit der Angabe welche Werte aktualisiert worden (1=postureX/postureY, 2=currentMowBoundary/currentMowProgress, 3=partitionIds, 4=taskDelay) |
| vehicleState | MQTT | Status des Gerätes |
