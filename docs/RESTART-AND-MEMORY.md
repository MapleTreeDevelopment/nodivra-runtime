# Neustart & Speicher – Nodivra 0.16 / Runtime 0.7

Im Runtime-Dashboard bei einer Automation **Neustart & Speicher** öffnen (Mac: Speicherchip-Symbol). Vor Änderungen pausieren. Die Einstellung gilt für das ganze Programm und ist standardmäßig ausgeschaltet.

- **Zustände behalten:** M/AM-Merker, Relais, Zähler, Schieberegister, analoge Funktionszustände, virtuelle Eingänge sowie aktive Timer und Wartezeiten bleiben für dieselbe Programmfassung erhalten.
- **Automatisch fortsetzen:** Eine zuvor laufende Automation darf nach Runtime-Neustart oder HA-Verbindungsabbruch im selben Modus weiterlaufen. Home-Assistant-Eingänge müssen aus einem frischen Abgleich vorliegen. Manuelles Pausieren widerruft den Wiederanlauf. Ohne diese Option erfolgt das Fortsetzen manuell.
- **Gespeicherten Zustand zurücksetzen:** löscht den Laufzustand, nicht das Programm und nicht die Zustände echter Geräte. Erforderlich beim Wechsel zwischen Beobachten und Ausführen oder nach einem unklaren Aktionsausgang. Vorher wird die Datenbank gesichert.

## Zeitverhalten

Alle laufenden relativen Zeiten werden während der Unterbrechung angehalten. Beispiel: Nachlauf 3 Minuten, davon 1 Minute vergangen → nach Wiederanlauf noch 2 Minuten. Stoppuhr, Betriebsstunden, Rampen und Reglerintegration zählen keine Ausfallzeit. Kalender-/Sonnenbedingungen werden anhand der aktuellen Uhrzeit neu bewertet. Es werden keine vergangenen Ereignisse oder Eingangsflanken nachgeholt. Pegelgesteuerte Ausgänge können sich nach dem Zustandsabgleich an den aktuellen Eingang anpassen; ein gespeicherter Ein-Zustand kann dadurch wieder ausgeschaltet werden. Ein Anlaufimpuls wird bei Fortsetzung nicht erneut erzeugt.

Die Runtime speichert etwa jede Sekunde und zusätzlich beim Pausieren/Beenden. Bei abruptem Stromausfall kann der letzte Speicherzyklus fehlen. Das ist keine exakt verlustfreie Zähleraufzeichnung. Die HA-VM und der Datenträger müssen SQLite-Schreibbestätigungen zuverlässig umsetzen.

## Unklare Aktionen

Vor externen Aktionen wird eine dauerhafte Sperre geschrieben. Sie wird erst an einer bestätigten, abgeschlossenen Ausführungsgrenze mit neuem Laufzustand aufgehoben. Bei Prozessabbruch zwischen Geräteaufruf und Bestätigung sowie bei noch nicht vollständig weitergereichten Abschlussimpulsen erfolgt kein automatischer Wiederanlauf. Erst Gerätezustand prüfen, dann gespeicherten Zustand zurücksetzen und neu aktivieren. Die Runtime kann keine bereits ausgeführte Geräteaktion rückgängig machen.

Laufzustände sind an die exakte Programmfassung und den Modus gebunden. Neue Übertragungen und das Wiederherstellen einer anderen Fassung bleiben deaktiviert und beginnen ohne alten Laufzustand. Beschädigte oder unpassende gespeicherte Zustände werden nicht stillschweigend verworfen und neu gestartet.

## Speicherung und Rückkehr

Additive Tabelle `program_recovery` in `/data/runtime.sqlite`, SQLite WAL mit `synchronous=FULL`. Zugangsschlüssel werden nicht in Laufzuständen abgelegt. Die bisherigen Tabellen bleiben lesbar; ältere Runtime-Versionen ignorieren Remanenz. Vor Migration und Einstellungsänderung wird eine Datenbanksicherung unter `/data/backups` erstellt (letzte zehn Stände). Eine Rückkehr zur alten Version garantiert keine Zustandsfortsetzung. Nur bei gestoppter Runtime aus einer passenden Sicherung wiederherstellen.

Lokale Engine-/API-Tests verwenden ausschließlich eine isolierte HA-Nachbildung. Zusätzlich prüfen [isolierte Ausfalltests](CRASH-RECOVERY-TESTS.md) echte harte Prozessabbrüche während laufender Timer und unbestätigter Aktionen. Tests auf einer dedizierten HA-VM einschließlich hartem VM-Ausfall und realen Geräten sind vor produktivem automatischem Wiederanlauf separat nötig. Keine Echtzeit- oder Sicherheits-SPS-Zusage.
