## 0.12.1

- Gemeinsames Logo entspricht der Mac-App: flaches Haus neben Nodivra, Untertitel darunter.

## 0.12.0

- Dashboard-Oberfläche ausschließlich in der separaten App „Nodivra Dashboards“. Gemeinsame Daten bleiben erhalten.

- Wetterkarten mit aktuellen Wetterdaten, Einheiten und klaren Verfügbarkeitszuständen.
- Drei Darstellungen: Minimal, Kompakt und Detail; benötigt Nodivra Dashboards 0.3.0.

## 0.11.0

- Vier auswählbare Dashboard-Designs: Schiefer, Wolke, Sand und Nacht, jeweils mit Hell-/Dunkel-Darstellung.
- Dashboard-Szenen und Raumklima mit festen Zielen und Temperaturgrenzen.
- Frische Runtime-Zahlenwerte als Helligkeit beim Einschalten verwenden.
- Gemeinsame Darstellung mit Hintergrundbildern, leichter Typografie, Datum und Uhrzeit.
- Alte Dashboard-Entwürfe bleiben kompatibel.

# 0.10.0

- Unterstützt die separate HA-App „Nodivra Dashboards“ mit eigenem Webdienst.
- Begrenzte Display-API nur für veröffentlichte Dashboards, Werte, Kameras und deren Bedienaktionen.
- Eigener abgeleiteter Verbindungsschlüssel; kein Zugriff auf Automationen, Entwürfe oder Veröffentlichung.
- Einrichtung der Dashboard-Verbindung aus der Mac-App ohne Abtippen von Schlüsseln.
- Gemeinsame Speicherung und bestehende Wiederanlaufregeln bleiben erhalten. Die integrierte Dashboard-Ansicht bleibt erreichbar.
- Die gemeinsame Runtime erscheint als „Nodivra Automationen“ in der HA-Seitenleiste.

# 0.9.2

- Korrigiert den direkten Dashboard-Einstieg über Home Assistant Ingress: kein doppelter Schrägstrich im Einstiegspfad.

# 0.9.1

- Home-Assistant-Seitenleiste: „Nodivra Dashboards“ öffnet die Dashboard-Auswahl direkt.
- Feste Navigation für Dashboards, Automationen und Runtime; Dashboard-Seiten stehen links.
- Komponenten ohne generische Typüberschriften und Editor-Symbole; eigene Titel bleiben erhalten.
- Kamera zeigt „Live“ erst nach Bildempfang und blendet defekte Bilder aus.
- Kompakte Navigation auf Smartphones. Bestehende Entwürfe, Automationen und Zugangsschlüssel bleiben erhalten.

# 0.9.0

- Eigenständige Dashboards mit Seiten, gemeinsamen Designvorgaben und derselben Darstellung wie die Mac-Vorschau.
- Getrennter Dokumentenspeicher: Entwürfe sichern, ausdrücklich veröffentlichen, Veröffentlichung zurücknehmen und Versionen als Entwurf wiederherstellen.
- Revisionsprüfung für mehrere Macs, idempotente Änderungsaufträge und automatische Datenbanksicherungen vor Dokumentänderungen.
- Licht/Schalter, Werte, Text, Bilder, Kameras und Livegraphen. Livegraphen enthalten bis zu 120 Messpunkte seit dem Öffnen; keine Recorder-Historie.
- Kamera-MJPEG und Einzelbilder über authentifiziertes Ingress. Keine Kamera- oder HA-Zugangsschlüssel im Browser. Höchstens vier parallele Kameraverbindungen.
- Abschaltbare Diagrammanimation und Status-Effekte; respektiert „Bewegung reduzieren“. Ausgeblendete Kameras pausieren.
- Zugriff auf Dashboards in dieser Version mit HA-Administratorkonto. Separate Tablet-Anmeldung, Ton, HLS/WebRTC und weitere Steuerelemente folgen später.
- Ein beschädigter oder nicht lesbarer Dashboard-Speicher blockiert den Start der Automations-Runtime nicht; die Originaldatei bleibt erhalten.
- Bestehende Automationsdaten und Wiederanlaufregeln bleiben erhalten. Ein Runtime-Update startet den Dienst wie üblich neu; vorher über den Updateassistenten sichern.

# 0.8.0

- Live-Diagnose für Logikeingänge: Ein/Aus, unbekannte Werte, fehlende und neutral unbeschaltete Eingänge, Negierung.
- Timerdiagnose mit übernommener Zeitvorgabe, vergangener Zeit, Restzeit und Reset-/Abbruchursache; mit Remanenz erhalten.
- Aktionsstatus unterscheidet gesendete, bestätigte, beobachtete und fehlgeschlagene Aufrufe. Eine HA-Bestätigung ist kein Nachweis des Gerätezustands.
- Blockbezogene Sende-/Fehlerereignisse für die Navigation aus dem Mac-Protokoll. Nodivra 0.17 zeigt die Details; bestehende Programme und Protokoll 5 bleiben kompatibel.

- Updatehinweis im Runtime-Dashboard vereinfacht: „Führe das Update aus, um die neusten Funktionen nutzen zu können.“

# 0.7.0

- „Neustart & Speicher“ je Automation: optionale Remanenz für Merker, Relais, Zähler, Funktionszustände, virtuelle Eingänge und laufende Timer.
- Optional automatisch fortsetzen nach Runtime-Neustart oder HA-Verbindungsabbruch; erst nach frischem Zustandsabgleich, im zuvor freigegebenen Modus. Standard bleibt deaktiviert.
- Timer behalten ihre Restzeit; Unterbrechungszeit wird nicht mitgezählt. Keine nachgeholten Eingangsflanken.
- Dauerhafte Sperre vor externen Aktionen schützt vor Wiederholung bei unklarer Bestätigung. Gespeicherter Zustand kann nach Prüfung zurückgesetzt werden.
- Einstellungen direkt im HA-Dashboard und in Nodivra 0.16. Ältere Mac-Apps bleiben für bisherige Funktionen kompatibel.
- Sicherung vor additiver Datenbankmigration und vor Änderungen an der Neustartregel. Neue Programmfassungen verwerfen alte Laufzustände und bleiben deaktiviert.

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
