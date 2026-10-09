# 0.6.1

- „In Seitenleiste anzeigen“ wird ausschließlich in den von Home Assistant bereitgestellten App-Einstellungen konfiguriert: Einstellungen → Apps → Nodivra Runtime.
- Doppelten Schalter und zugehörigen Schreibendpunkt aus dem Runtime-Dashboard entfernt. Die bestehende HA-Seitenleisten-Einstellung bleibt erhalten.
- Dashboard, Automationsverwaltung und Zugangsschlüssel bleiben verfügbar. Keine Änderung am Ausführungsprotokoll oder Datenformat.

# 0.6.0

- Neues Dashboard direkt in Home Assistant: Runtime-/HA-Version, Verbindung, Engine-Status und Übersicht gespeicherter Nodivra-Automationen.
- Suche, Statusfilter und Sortierung; Erstellungsdatum, letzte Änderung und letzte bestätigte Ausführung. Aktivierung und Beobachtung werden separat ausgewiesen.
- Automationen direkt aktivieren, beobachten und deaktivieren. Gleichzeitige Änderungen aus der Mac-App oder einem zweiten Fenster werden erkannt.
- „In Seitenleiste anzeigen“ bindet das Dashboard in die Home-Assistant-Seitenleiste ein.
- Zugangsschlüssel weiterhin unter „Zugang & Einstellungen“ erzeugen und verwalten. Bestehende Schlüssel bleiben erhalten.
- Zeitangaben bleiben nach Neustarts und Protokollkürzungen erhalten. Bei älteren Programmen wird ein unbekanntes Erstellungsdatum als nicht erfasst angezeigt.
- Additive Datenbankerweiterung mit vorheriger Sicherung. Protokoll 5 bleibt unverändert; die vorhandene Mac-App 0.15.1 ist kompatibel. Programme bleiben nach dem Update pausiert.

# 0.5.0

- Verknüpfbare Aktionsparameter: Zahlen, Ein/Aus, Texte, Listen und Objekte, einschließlich verschachtelter Felder und Ziele.
- Ein/Aus-Folgeaktionen übernehmen geänderte Parameter während Ein. Bei Aus bleiben Wertänderungen ohne Geräteaktion.
- Ausschalten verwendet das tatsächlich eingeschaltete Ziel, auch wenn die Zielauswahl inzwischen geändert wurde. Neue Ziele gelten beim nächsten Einschalten.
- Wertauswahl um Ganzzahlen, Ein/Aus, Text, Listen und Objekte erweitert.
- Verknüpfte Wartezeiten werden bei Start übernommen. Typen, Wertebereiche und fehlende Verbindungen werden geprüft.
- Protokoll 5; ältere Programme bleiben kompatibel. Neue Parameterprogramme benötigen diese Version. Bestehende Programme bleiben nach Runtime-Neustart pausiert.

# 0.4.0

- Wertauswahl mit 2–8 unabhängigen Bedingungen, konfigurierbaren Zeit-/Zahlenwerten und Standardwert. Kleinere Eingangsnummer hat Vorrang; unbekannte höher priorisierte Bedingungen werden nicht als Aus behandelt.
- Variabler Eingang T für Ein-/Ausschaltverzögerung und Zeitimpuls. Zeitwert in Sekunden, auch über AM-Merker/Kontakte. Übernahme beim Beginn der Laufzeit, laufende Zeiten bleiben unverändert. R bricht weiterhin ab.
- Ungültiges T beim Start pausiert das Programm mit einer verständlichen Meldung. Bereich: 0,1 Sekunden bis 24 Stunden.
- Protokoll 4 / Graphformat 5 für diese Funktionen, frühere Programme bleiben unterstützt. Benötigt Nodivra 0.14. Nach dem Runtime-Neustart bleiben Programme zur Prüfung pausiert.

# 0.3.0

- 40 neue Grund-/Sonderfunktionen: Zeit-, Kalender-, Zähl-, Speicher-, Analog- und Reglerbausteine sowie Anlaufimpuls, Entprellung und Begrenzung.
- Logik mit bis zu acht Eingängen und fünf Q-Abgängen; getrennte digitale und analoge Zählerausgänge.
- Zusätzliche Reset-Pins und wählbarer S/R-Vorrang. Gleiches Verhalten in Simulation und Runtime.
- Live-Snapshots mit Zahlenwerten und verbleibenden Zeiten der neuen Zeitbausteine.
- Protokoll 3 / Graphformat 4; ältere Programme bleiben unterstützt. Neue Blöcke benötigen Nodivra 0.13.
- Programme bleiben nach dem Update pausiert. Timer und Merker sind noch nicht remanent.
- Erweiterung des Software-Funktionsumfangs; keine vollständige LOGO!-Hardware- oder Dateiformat-Nachbildung.

# 0.2.0

- SPS-Programme mit digitalen und analogen Ein-/Ausgängen.
- M/AM-Merker und Kontakte mit definiertem Zyklusverhalten.
- Virtuelle Eingänge pro Programm über die App bedienbar.
- Analoge Entitätsattribute, Zahlenvergleich und Zahlenwerte in der Live-Ansicht.
- Bestehende Programme im Protokoll 1 bleiben unterstützt. Neue SPS-Programme verwenden Protokoll 2.
- Nach einem Neustart bleiben Programme pausiert. Merker sind noch nicht remanent.

# Änderungen

## 0.1.1

- Neue Runtime-Konfiguration direkt in Home Assistant über „Weboberfläche öffnen“.
- Sichere Zugangsschlüssel mit einem Klick erzeugen, kopieren und speichern.
- Die Einrichtung bleibt bei leerem oder zu kurzem Schlüssel erreichbar; die externe API bleibt gesperrt.
- Bestehende Schlüssel werden nur nach ausdrücklicher Bestätigung ersetzt.
- Gleiche Blocklogik und API wie 0.1.0. Laufende Programme bleiben nach einem Neustart pausiert.

## 0.1.0

- Erste Runtime mit Blockengine, Simulation, geschützter API, Übertragung und Versionssicherungen.
