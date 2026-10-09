# Nodivra Runtime 0.7.0

HA-OS-App-Paket für amd64 und aarch64. Runtime 0.6 ergänzt ein Dashboard direkt in Home Assistant mit Versionsinformationen, dauerhaften Zeitangaben, Aktivierung/Deaktivierung. Nodivra 0.16 ergänzt Neustartregeln und Remanenz; die Mac-App 0.15.1 bleibt für bisherige Funktionen kompatibel. Seit Runtime 0.5 gibt es verknüpfbare Aktionsparameter und eine Wertauswahl für Zahlen, Ganzzahlen, Ein/Aus, Texte, Listen und Objekte. Diese Funktionen verwenden Protokoll 5 / Graphformat 6 und benötigen Nodivra 0.15; Protokolle 1–4 bleiben unterstützt. Engine und API besitzen automatisierte Tests mit isoliertem HA-Testserver. Die Abnahme auf einer echten HA-Installation und unter Dauerlast ist separat erforderlich. Automatische Einrichtung über https://github.com/MapleTreeDevelopment/nodivra-runtime; das lokale ZIP bleibt als manueller Weg erhalten.

## Installation aus Nodivra

Dashboard → **Installation**. Home Assistant mit einem Administratorkonto verbinden. Der Assistent zeigt die Installationsquelle und die Runtime-Adresse. Lokales HTTP muss ausdrücklich erlaubt werden. **Mit Sicherung installieren** führt acht Schritte aus:

1. HA OS, unterstützte Architektur, Systemzustand und Administratorzugriff prüfen.
2. Vollständige lokale HA-Sicherung einschließlich Datenbank erstellen.
3. Sicherungskennung, Typ, Umfang und Größe zurücklesen. Die Prüfung bestätigt Metadaten; sie ist kein Wiederherstellungstest.
4. Runtime-Repository einrichten und die erwartete Paketversion prüfen.
5. Runtime installieren oder die passende vorhandene Installation übernehmen.
6. Zugangsschlüssel erzeugen und im Mac-Schlüsselbund sichern; vorhandene Schlüssel und weitere Optionen bleiben erhalten.
7. Runtime starten. Bei einer Neuinstallation gibt es noch keine Abläufe; bei bestehenden Programmen gelten die freigegebenen Neustartregeln.
8. API, Engine und HA-Verbindung prüfen.

Der Gesamtbalken zeigt abgeschlossene Schritte. Prozentwerte innerhalb eines Schritts stammen vom Supervisor-Auftrag. Verstrichene Zeit wird zusätzlich angezeigt. Die geschätzte Restzeit beschreibt nur diesen Auftrag, nicht die komplette Installation. Sie setzt mehrere gleichmäßige Fortschrittssprünge voraus und wird bei Phasenwechseln oder länger unverändertem Fortschritt ausgeblendet. Bei 0 % bleibt die Aktivitätsanzeige mit „Restzeit noch nicht abschätzbar“ sichtbar. Schließen lässt die Beobachtung weiterlaufen; **Später fortsetzen** unterbricht nur die Beobachtung. HA-Aufträge können weiterlaufen. **Status prüfen & fortsetzen** liest zuerst den Zustand zurück und sendet unbestätigte Schreibaufträge nicht erneut. Protokolle liegen im App-Datenordner unter `Nodivra/Installations`; sie enthalten keine Zugangsschlüssel. Ein nicht lesbares Protokoll blockiert einen neuen Auftrag, damit keine unbekannte Installation wiederholt wird.

Die Sicherung liegt zunächst auf dem HA-Datenträger. Unter Einstellungen → System → Sicherungen zusätzlich herunterladen. Nodivra aktualisiert das Betriebssystem nicht und übergeht keine Supervisor-Sperre.

## Manueller Ersatzweg nach Freigabe des HA-OS-Updates

1. Vollständige HA-Sicherung erstellen und herunterladen. Bei einer VM zusätzlich einen Snapshot des ausgeschalteten Systems anlegen, bevor das Betriebssystem verändert wird.
2. `python3 Scripts/package-runtime.py` im Nodivra-Projekt erzeugt `Build/Nodivra-Runtime-0.7.0.zip`. Das ZIP enthält den Ordner `nodivra_runtime`. Unter `/addons/nodivra_runtime` müssen `config.yaml`, `Dockerfile`, `server` und `Engine` liegen. Vor dem Ersetzen eines vorhandenen Ordners diesen sichern. Später bei Updates das aktuelle Paket verwenden; vorbereitete ältere Dateien allein reichen nicht.
3. Auf einer von Supervisor unterstützten HA-OS-Version den App-Store neu laden. Nodivra Runtime erscheint unter den lokalen Apps. Installieren. Der erste Build lädt offizielle Swift-/Python-Abhängigkeiten und benötigt Zeit und freien Speicher. Die Architektur wird vom Build gewählt.
4. Runtime starten und **Weboberfläche öffnen** wählen. Unter **Zugang & Einstellungen** dort **Schlüssel generieren** und **Schlüssel speichern & verwenden** anklicken. 64 zufällige Zeichen werden erzeugt und in den HA-App-Optionen gespeichert; ein bisheriger gültiger Schlüssel wird erst nach Bestätigung ersetzt. Der Schlüssel lässt sich verborgen halten und kopieren. Ohne gültigen Schlüssel bleibt die externe Runtime-API gesperrt, die Einrichtung ist erreichbar.
5. Auf dem Mac Runtime-Adresse `http://homeassistant.local:8668` und denselben Schlüssel eintragen. Lokales HTTP muss ausdrücklich erlaubt werden. Schlüssel und Programme laufen bei HTTP unverschlüsselt über das lokale Netz; Port 8668 nicht öffentlich freigeben. Die aktuelle Runtime terminiert selbst kein TLS.
6. Dashboard → Testablauf öffnen → lokal simulieren → auf Runtime prüfen → deaktiviert übertragen → Beobachten. Das erste Programm schreibt nur Protokollmeldungen. Noch keine Geräteautomation zur ersten Abnahme verwenden.

Die Runtime bekommt HA-Zustände und Dienstzugriff über `homeassistant_api: true` und den vom Supervisor bereitgestellten `SUPERVISOR_TOKEN`. Dieser Token verlässt den Container nicht in Richtung Mac. Verbindung über `ws://supervisor/core/websocket`; kein Docker-Zugriff, Host-Dateisystemzugriff oder privilegierter Modus erforderlich.

## Updates direkt aus der Mac-App

Nodivra prüft beim Verbinden und danach stündlich die von Supervisor gemeldete verfügbare Runtime-Version. Dashboard → **Updates** lädt zusätzlich die Installationsquellen neu und zeigt den Änderungslog aus Home Assistant. **Update vorbereiten** öffnet den Assistenten. Erst **Mit Sicherung aktualisieren** erstellt einen neuen Auftrag mit Vollsicherung, Versionsprüfung, Update, Start und Verbindungsprüfung. Die angezeigte Zielversion wird festgehalten; wechselt das Angebot währenddessen, wird kein anderes Update stillschweigend installiert. Unklare Schreibausgänge werden zurückgelesen. Nach einem Neustart gilt die je Automation gespeicherte Wiederanlaufregel. Standard bleibt pausiert. Schlüssel und weitere Optionen bleiben erhalten.

Die Runtime-Konfiguration läuft getrennt vom API-Port über HA Ingress (intern 8099, ausschließlich Supervisor-IP 172.30.32.2). CSRF-Schutz, Bestätigung bei Schlüsselersatz, Konfliktprüfung und Rücklesen der gespeicherten Optionen verhindern unbeabsichtigte Änderungen. Es werden keine Supervisor-Manager-/Adminrechte zusätzlich angefordert.

## Dashboard direkt in Home Assistant

Bei der Runtime **Weboberfläche öffnen** wählen. Die Option **In Seitenleiste anzeigen** befindet sich ausschließlich in den von Home Assistant bereitgestellten App-Einstellungen unter **Einstellungen → Apps → Nodivra Runtime**, nicht im Runtime-Dashboard. Falls der neue Eintrag nicht sofort erscheint, Home Assistant neu laden. Die Ansicht und ihre Bedienung sind nur für Home-Assistant-Administratoren freigegeben.

Die Übersicht zeigt die auf dieser Runtime gespeicherten Nodivra-Automationen, keine lokalen Mac-Entwürfe oder gewöhnlichen HA-YAML-Automationen. Suche, Statusfilter und Sortierung erleichtern die Auswahl. Der aktuelle Stand wird alle fünf Sekunden abgerufen, solange die Seite sichtbar ist. Veraltete Anzeigen sind nicht bedienbar.

- **Erstellt auf dieser Runtime:** Zeitpunkt der ersten Übertragung seit Version 0.6. Bei bereits vorhandenen Programmen ist das ursprüngliche Datum nicht zuverlässig rekonstruierbar und wird als „Nicht erfasst · älterer Stand“ angezeigt.
- **Zuletzt aktualisiert:** letzte gespeicherte Übertragung der Konfiguration; Aktivieren und Deaktivieren ändern dieses Datum nicht.
- **Zuletzt ausgeführt:** letzte von HA bestätigte Geräteaktion oder Protokollaktion im Ausführungsmodus. Das Aktivieren oder reine Auswerten von Eingängen zählt nicht. Beobachtungsaktionen und Aktivierungszeitpunkte haben eigene Angaben.
- **Aktivieren:** wahlweise echte Ausführung oder Beobachtung ohne Geräteaktionen; validiert die aktuelle Fassung und verwendet je nach Remanenzeinstellung gespeicherte Zustände oder Anfangswerte. **Deaktivieren** stoppt den Ablauf, setzt bereits geschaltete Geräte jedoch nicht zurück.

Die Zeitangaben werden unabhängig vom begrenzten Ereignisprotokoll gespeichert. Alte bestätigte Geräteaktionen können aus noch vorhandenen Ereignissen übernommen werden. Fehlende historische Angaben werden nicht geschätzt. Beim ersten Start von 0.6 wird die vorhandene Datenbank vor der additiven Erweiterung gesichert; die bisherigen Tabellen bleiben für eine Rückkehr zur vorherigen Runtime lesbar. Seit 0.7 ist optionaler Wiederanlauf mit Remanenz möglich.

Der Schlüsselbereich ist eingeklappt unter **Zugang & Einstellungen** erreichbar. Dashboard-Abfragen enthalten keine Zugangsschlüssel, App-Optionen oder vollständigen Programmpakete. Statusänderungen werden gegen Konfigurationsrevision und Bedienversion geprüft; bei Konflikten zuerst neu laden. Die Runtime verändert die von Home Assistant verwaltete Seitenleisten-Einstellung nicht.

## Betrieb und Daten

- `/data/runtime.sqlite`: SQLite mit WAL und vollständiger Synchronisierung; Programme, Revisionen, begrenzte Protokolle und Wiederholungskennungen.
- `/data/backups`: zehn Datenbankstände; Sicherung vor jeder Übertragung. Pro Programm zusätzlich zehn Konfigurationsfassungen.
- Neustart & Speicher ist je Automation einstellbar. Standard: pausiert und neu initialisiert. Mit Remanenz bleiben Laufzustände und Timer-Restzeiten erhalten; optionaler Wiederanlauf wartet auf frische Eingänge. Manuelles Pausieren widerruft ihn. Unbestätigte Aktionen benötigen Prüfung und Zurücksetzen. Rein virtuelle Programme können bei HA-Ausfall weiterlaufen.
- Ein einzelner HA-WebSocket abonniert Zustandsänderungen vor dem ersten Gesamtbild. Protokoll 1 verarbeitet Ereignisframes wie bisher. SPS-Programme (Protokoll 2 und 3) werten pro Zyklus genau ein aktuelles Zustandsbild aus; Impulse kürzer als ein Zyklus können dabei unentdeckt bleiben. Überlauf pausiert. Zielintervall: 100 ms, keine garantierte Echtzeit; Dienstantworten können einen Zyklus verzögern.
- API und Engine begrenzen Nutzlast, Graphgröße, Aktionsrate und Wartezeiten. Fehler oder nicht bestätigte Dienstaufrufe werden nicht automatisch wiederholt.
- Eine Aktion kann physisch bereits erfolgt sein, bevor die Verbindung abbricht. Konfigurationswiederherstellung macht Geräteaktionen nicht rückgängig.

## API v1

Alle `/api/v1`-Anfragen benötigen `Authorization: Bearer <access_key>`. Browser-Origin-Anfragen werden abgelehnt. Nur `/health` ist öffentlich und enthält keine Programm- oder Zugangsdaten; ein ausgefallener Engine-Prozess ergibt HTTP 503 für den Watchdog.

| Aufruf | Zweck |
|---|---|
| GET `/api/v1/status` | Version, Instanz, HA-Verbindung, Engine und Ausführungszahl |
| GET `/api/v1/automations` | Programme mit Revision und Zustand |
| POST `/api/v1/validate` | RuntimePackage gegen gemeinsame Engine prüfen |
| PUT `/api/v1/automations/{id}` | Paket mit `expectedRevision` und `requestID` deaktiviert speichern |
| GET `/api/v1/automations/{id}` | Gespeicherten Inhalt zurücklesen |
| POST `/api/v1/automations/{id}/state` | Pausieren, beobachten oder ausdrücklich ausführen |
| GET `/api/v1/automations/{id}/revisions` | Frühere Fassungen |
| GET `/api/v1/live/{id}` | Signale, Restzeiten und offene Aktionen der laufenden Fassung |
| GET `/api/v1/events` | Begrenztes Ereignisprotokoll |

Änderungen sind revisionsgebunden. Identische Wiederholungen mit derselben requestID werden ohne erneutes Schreiben beantwortet; andere Daten unter derselben Kennung ergeben Konflikt. Bei unbekanntem Schreibausgang zuerst zurücklesen. Live-Daten älter als drei Sekunden werden verworfen.

## Lokale Entwicklung

Python 3.10+ und Swift 6. Runtime-Tests starten ausschließlich eigene HTTP-/WebSocket-Fixtures auf Loopback. `NODIVRA_TEST_ENGINE` auf den gebauten Swift-CLI-Pfad setzen. Für den manuellen Entwicklungsserver sind `NODIVRA_DATA`, `NODIVRA_ACCESS_KEY`, `NODIVRA_ENGINE`, `NODIVRA_HA_BASE`, `NODIVRA_HA_TOKEN`, `NODIVRA_HOST` und `NODIVRA_PORT` konfigurierbar. Testzugangsdaten aus den Fixtures sind keine produktiven Schlüssel. Keine echten Tokens in Skripten ablegen.

Quellen: [HA Apps](https://developers.home-assistant.io/docs/apps/), [App-Konfiguration](https://developers.home-assistant.io/docs/apps/configuration/), [Kommunikation](https://developers.home-assistant.io/docs/apps/communication/), [Swift Crypto](https://github.com/apple/swift-crypto).

## SPS und virtuelle Signale (Protokoll 2)

Digitale Ein-/Ausgänge, analoge Ein-/Ausgänge, M-/AM-Merker, Kontakte und Analogvergleiche werden direkt von der gemeinsamen Swift-Engine ausgeführt. Merker werden gleichzeitig am Zyklusende gespeichert und erst im nächsten Zyklus sichtbar. Anfangswert 0; mit aktivierter Remanenz wird der gespeicherte Wert übernommen. HA-Attribute werden zusammen mit dem Zustand eingelesen; unbekannte Werte propagieren als unbekannt. Ausgänge senden Aktionen bei Wertänderungen, beim Laden wird kein Ausgang gesendet. Virtuelle Ausgänge senden keine HA-Aktionen. Analoge Lichtausgänge verwenden 0–100 Prozent, number/input_number verwenden set_value. Maximal 30 Aktionen pro Minute und Programm, global 120.

GET `/api/v1/automations/{id}/inputs` liest virtuelle Eingänge eines laufenden Programms. POST `/api/v1/automations/{id}/inputs/{block-id}` setzt mit `expectedRevision` und typisiertem `value` einen solchen Eingang. Reale Entitäten, Merker und fremde Blöcke werden abgewiesen. Werte sind pro Programm getrennt und werden beim Aktivieren zurückgesetzt. Live-GET bleibt rein beobachtend.

## Erweiterte Bausteine (Protokoll 3)

40 neue Funktionen: NAND/NOR und Flankenauswertung, kombinierte und speichernde Verzögerungen, Wischrelais und Impulsfolge, asynchroner Takt und Zufallsverzögerung, Treppen-/Komfortlicht, Jahres-/Astroschaltuhr, Stoppuhr, Zähler/Betriebsstunden/Frequenz, Schwellwert-/Differenzschalter, Analogkomparator/Überwachung/Verstärker, Stromstoßrelais, Schieberegister, Multiplexer, Rampe, PI/PWM, Mathematik/Fehlererkennung, Filter/Max-Min/Mittelwert, Zahlenkonvertierung, Entprellen, Begrenzung und Anlaufimpuls.

Logikbausteine unterstützen zwei bis acht Eingänge und fünf identische Q-Abgänge. Unverbundene Gate-Eingänge sind neutral; verbundene unbekannte Werte bleiben unbekannt. `Wire.output` wählt den Ausgang, alte Dateien ohne dieses Feld verwenden Ausgang 0. Zähler, Betriebsstunden und Frequenz besitzen zusätzlich einen analogen AQ-Ausgang (Port 1).

Der Anlaufimpuls ist im ersten Zyklus nach dem ausdrücklich gestarteten Programm Ein und kann Initialisierungsaktionen auslösen. Alle anderen Wiederanlaufregeln und Aktionsgrenzen bleiben bestehen. Keine Remanenz oder garantierte Echtzeit. Hardwaregebundene LOGO!-Funktionen, VM-Adressierung und Soft-Comfort-Dateien sind nicht implementiert. Einige Sonderfunktionen sind auf das HA-Zyklusmodell reduziert: Zeitabtastung statt Hardwarezählung, jährliches Datumsfenster, parametrische PI-Regelung und numerische Konvertierung ohne VM-Bindung. Meldungen erfolgen zunächst als Protokolleintrag.

[Anleitung zu verknüpfbaren Parametern](docs/ACTION-PARAMETERS.md)

## Neustart & Speicher

[Regeln, Zeitverhalten und Wiederherstellung](docs/RESTART-AND-MEMORY.md). Einstellbar pro pausierter Automation im HA-Dashboard. Alle Timer pausieren während der Unterbrechung. Speicherzyklus etwa eine Sekunde; bei Stromausfall kann der letzte Zyklus fehlen. Programmübergreifende Merker sind noch nicht enthalten.
