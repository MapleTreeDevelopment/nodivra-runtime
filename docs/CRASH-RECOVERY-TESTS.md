# Isolierte Ausfalltests – Runtime 0.7.0

Stand: 9. Oktober 2026. Ergänzt die bisherigen Engine-, API- und geordneten Neustarttests um echte Prozessabbrüche. Am ausführbaren Runtime-Code und an der Mac-App wurde dafür nichts geändert.

## Aufbau

Jeder Test startet `server.py` als eigenen Prozess mit der echten kompilierten Swift-Engine. Eine HA-Nachbildung liefert Zustände, Dienstbeschreibungen und Aktionsbestätigungen über WebSocket auf `127.0.0.1`. Ausschließlich zufällige lokale Ports, temporäre Datenverzeichnisse und Testschlüssel werden verwendet. Geerbte Supervisor- und Runtime-Verbindungsvariablen werden entfernt.

Der Test sendet `SIGKILL` an die eigens angelegte Prozessgruppe. Runtime und Engine können dabei keinen geordneten Abschluss und keinen letzten Speicherzyklus ausführen. Anschließend wird dieselbe SQLite-Datenbank einschließlich WAL wieder geöffnet. Die Tests prüfen den Signal-Abbruchstatus und die Datenbankintegrität; alle Testprozesse werden auch bei fehlgeschlagenen Prüfungen beendet.

## Geprüfte Fälle

| Fall | Erwartetes und geprüftes Verhalten |
|---|---|
| Laufender Nachlauf, zweimal hart unterbrochen | Gespeicherte Restzeit läuft weiter; Wartezeit während der Unterbrechung wird nicht abgezogen. Ausgang fällt nach Ablauf ab. Serverkennung, Programmfassung und Modus bleiben erhalten. |
| Virtuelle Eingänge, M/AM, Zähler, RS-Relais | Werte und Relaiszustand bleiben erhalten. Ein bereits aktiver Eingang zählt beim Wiederanlauf nicht erneut; eine neue Flanke zählt, Reset funktioniert. |
| HA erhält Aktion, Bestätigung bleibt aus | Die Sperre ist über eine unabhängige Datenbankverbindung bereits beim Empfang des Aufrufs sichtbar. Auch nach zwei Neustarts keine Wiederholung und keine Aktivierung ohne Zustandsprüfung. Ein unabhängiges Programm läuft weiter. |
| HA bestätigt Aktion, neuer Laufzustand gespeichert | Keine erneute Ausführung beim Neustart. Erst eine neue Eingangsflanke erzeugt den nächsten Aufruf. |
| Erster HA-Zustandsabgleich verzögert | Automation bleibt wartend. Erst nach vollständigem frischem Abgleich wird fortgesetzt. Ein während des Ausfalls geänderter Eingang erzeugt keinen nachgeholten Flankenaufruf. |
| Standardmodus, nur Remanenz oder manuell pausiert | Kein automatischer Start. Nur das ausdrücklich für Wiederanlauf freigegebene, zuvor laufende Programm startet. |
| Warten-Block in Aktionskette | Restzeit bleibt erhalten; Folgeaktion wird genau einmal gesendet. Ein weiterer Neustart nach Bestätigung wiederholt sie nicht. |

Die sieben neuen Tests bestanden lokal mit Python 3.12 und echter Swift-Engine (rund 32 Sekunden). Die gesamte API-Suite und die beiden Linux-Architekturen werden zusätzlich geprüft; der abschließende Prüfbericht hält deren Ergebnis fest.

## Wiederholen

Im vollständigen Mac-/Engine-Projekt:

```sh
swift build --product NodivraEngine
NODIVRA_TEST_ENGINE="$PWD/.build/debug/NodivraEngine" python3 -m unittest discover -s Runtime/tests -v
```

Die Python-Umgebung benötigt die Abhängigkeiten aus `Runtime/server/requirements.txt`. Im öffentlichen Runtime-Repository führt der vorhandene Linux-Workflow dieselben Tests unter `tests/` im gebauten Container aus, jeweils auf AMD64 und ARM64. Einzeln auswählbar mit `-p test_crash_recovery.py`.

## Grenzen

Ein Prozessabbruch ist kein Stromausfall der VM oder des Datenträgers: Betriebssystem und Dateisystem laufen bei diesen Tests weiter. Sie belegen weder die Dauerhaftigkeit physischer Schreibbestätigungen noch die Ausführung an echten Geräten. Ein gezielter HA-VM-Ausfall, Langzeittests unter Last und eine Geräteabnahme bleiben separate Schritte auf einer Testinstanz.

Der Speicherzyklus beträgt ungefähr eine Sekunde; ein noch nicht gespeicherter Zählerstand kann bei abruptem Abbruch verloren gehen. Unbestätigte Aktionen bleiben zur manuellen Prüfung gesperrt. Die lokale Prüfung setzt keine Geräte zurück und verändert keine produktive Installation.
