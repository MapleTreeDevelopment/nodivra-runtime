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
