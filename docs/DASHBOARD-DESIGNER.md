# Dashboard Designer · Mac 0.20 / Runtime 0.9

Ein eigenständiges Toolbox-Werkzeug mit eigener Dashboard-Darstellung. Es verändert keine Lovelace-Konfiguration und erstellt keine HA-Automationen.

## Gestalten

In der Werkzeugauswahl **Dashboard Designer** öffnen und ein Dashboard erstellen. Links Seiten und Komponenten wählen, in der Mitte platzieren und an der unteren rechten Ecke skalieren. Rechts stehen Bezeichnung, Datenquelle und Eigenschaften. Handy (4 Spalten), Tablet (8) und Desktop (12) besitzen eigene Rasterpositionen. Bei Änderungen an einer Ansicht bleiben die anderen erhalten. Über Dashboard-Einstellungen lassen sich System-/runde-/Serifenschrift, Schriftgröße, Farben, Abstände, Rundungen und Hell/Dunkel wählen. Rückgängig/Wiederholen und lokale Sicherung sind vorhanden.

Die Mac-Vorschau zeigt dieselbe Web-Komponente wie das fertige Dashboard. Sie liest Werte; ihre Gerätebedienung ist gesperrt. Designer-Dokumente werden separat von Automationsentwürfen gespeichert. Das Original einer nicht lesbaren lokalen Datei wird nicht überschrieben.

## Komponenten

- **Licht:** feste HA-Lichtentität, Ein/Aus und Helligkeit. Geräteaktionen nur im veröffentlichten Dashboard nach Betätigung. Bestätigung durch HA und tatsächlicher Gerätezustand sind getrennt dargestellt.
- **Schalter:** switch, input_boolean oder light mit Ein/Aus.
- **Wertanzeige:** Entitätszustand/-attribut oder Runtime-Block (Signal, Zahlenwert, Restzeit). Unbekannt, nicht verfügbar und veraltet werden kenntlich gemacht. Keine geheimen Kamera-Attribute im Dashboard.
- **Text/Bild:** frei formulierter Text, PNG/JPEG-Import im Mac; Bilder werden auf maximal 1200 Pixel und 512 KB begrenzt und als PNG mit dem Dokument gespeichert. Keine externen Bild-URLs oder Skripte.
- **Kamera:** camera-Entität auswählen. Im Browser MJPEG-Livestream oder Einzelbilder alle zwei Sekunden. Die Mac-Vorschau zeigt aktualisierte Einzelbilder. Abhängig von der HA-Kameraintegration; HLS, WebRTC, Audio und direkte RTSP-Adressen sind noch nicht umgesetzt. Bei nicht unterstütztem MJPEG den Einzelbild-Modus wählen.
- **Livegraph:** Zahlen aus einer Entität, einem Attribut oder einem Runtime-Block. Bis zu 120 Messpunkte seit dem Öffnen; unbekannte Werte bilden Lücken. Min/Max und aktueller Wert. Diese Version lädt keine historischen Recorder-Daten. Neue Werte lassen sich sanft animieren.

Leuchten und sanfter Statusimpuls sind optionale Effekte. Sie reagieren bei gebundenen Komponenten auf aktive Signale beziehungsweise verfügbare Kamera-/Graphwerte. Standard: kein Effekt. Systemoption „Bewegung reduzieren“ schaltet Bewegung ab.

Kameras pausieren bei ausgeblendeter Seite, beim Seitenwechsel und außerhalb des sichtbaren Bereichs. Pro Runtime maximal vier parallele Kameraabfragen/-streams. Ingress authentifiziert den Nutzer, die Runtime ruft ausschließlich die konfigurierte Kamera über HA ab; Schlüssel bleiben auf dem Server. Streams erneuern ihre Zugangsprüfung spätestens nach 45 Sekunden. Veröffentlichungsänderungen werden zusätzlich während des Streams geprüft. Kein Tablet-Direktzugang ohne HA-Anmeldung.

## Sichern, veröffentlichen und wiederherstellen

1. **Auf Runtime sichern:** überträgt einen Entwurf mit erwarteter Revision. Ein gleichzeitig geänderter Serverstand wird nicht überschrieben.
2. **Veröffentlichen:** nach Prüfung wird genau die gesicherte Fassung im Browser sichtbar. Spätere Entwurfsänderungen bleiben unsichtbar.
3. In Home Assistant die **Nodivra Runtime → Dashboard öffnen** wählen. „In Seitenleiste anzeigen“ bleibt die native Option unter Einstellungen → Apps → Nodivra Runtime. Aktuell ist ein HA-Administratorkonto nötig; noch keine getrennten Dashboard-Benutzerrollen.
4. **Versionen:** eine frühere Fassung als neuen Entwurf wiederherstellen und danach bei Bedarf veröffentlichen. **Veröffentlichung zurücknehmen** entfernt die Browserfreigabe; Entwurf und Verlauf bleiben erhalten.
5. Ein neuer Mac verbindet dieselbe Runtime, lädt die Übersicht und öffnet ein Dokument vollständig mit Bildern, Seiten und Layouts. Bei lokalen Änderungen bietet die App zunächst eine lokale Kopie an.

Geräteaktionen sind feste, veröffentlichte Ziele. Der Browser kann keine beliebigen Dienste oder Ziel-URLs übertragen. Aktionskennungen verhindern die Wiederholung desselben Auftrags, auch nach einem Neustart. Bei fehlender Bestätigung steht „nicht bestätigt“; es gibt keine automatische Wiederholung. Bedienung setzt bekannte, aktuelle HA-Zustände voraus.

## Speicher und Wiederherstellung

Die Runtime verwendet **dashboards.sqlite** getrennt von **runtime.sqlite**. Vor Dokumentänderungen wird eine konsistente Dashboard-Datenbanksicherung angelegt; die letzten drei bleiben unter `dashboard-backups` erhalten. Änderungen an Entwurf und Veröffentlichung erfolgen transaktional. Bis zu 20 neueste Versionen plus die veröffentlichte Fassung bleiben pro Dokument erhalten. Vollständige HA-Sicherung vor einem Runtime-Update weiterhin über den vorhandenen Assistenten durchführen.

Grenzen des Schemas: 50 Dashboards, 20 Seiten, 200 Komponenten pro Dokument, zwölf Bilder, maximal 4 MB je Dokument. Übersichts-/Verlaufsabfragen enthalten Metadaten; große Bilder werden erst beim Öffnen geladen. Kameras und Bilder werden nicht in der Automationsengine verarbeitet. JSON-/Renderer-Version 1, Runtime-Protokoll weiterhin 5, Fähigkeit `dashboards.documents.v1`.

Für eine manuelle Datenbankwiederherstellung die Runtime stoppen, den gesamten aktuellen Datenordner sichern, eine ausgewählte konsistente `dashboard-backups/*.sqlite` als `dashboards.sqlite` einsetzen und vorhandene `dashboards.sqlite-wal`/`-shm` erst nach der Sicherung entfernen. Danach Runtime starten. Die zugehörige Mac-Fassung neu laden, bevor erneut geschrieben wird. Automationsdateien nicht ersetzen.

## Anordnung pro Gerät (Mac 0.20.1)

Oben **Desktop**, **Tablet** oder **Handy** auswählen. Jede Ansicht speichert Position und Größe der Komponenten unabhängig; Verschieben und Skalieren ändern nur die gewählte Ansicht. Inhalte, Entitätszuordnungen und gemeinsame Designvorgaben gelten weiterhin für alle drei Ansichten. Die Runtime wählt das passende Raster anhand der verfügbaren Breite (unter 560 px Handy, unter 880 px Tablet, sonst Desktop).

Komponenten aus der linken Liste direkt auf das Raster ziehen. Beim Loslassen wird ihre Position in der aktuellen Ansicht gespeichert; die anderen Ansichten erhalten jeweils eine freie Stelle. Ein Klick auf Plus sucht ebenfalls je Gerät eine freie Rasterposition. Bereits gespeicherte Komponenten werden dabei nicht verschoben.

**Anordnung übernehmen → Von Desktop/Tablet/Handy übernehmen** kopiert die aktuelle Seite in die gerade ausgewählte Ansicht. Breite und Position werden an das Zielraster angepasst; entstandene Überschneidungen werden in freie Rasterzellen verlegt. Andere Geräteansichten bleiben erhalten. Rückgängig stellt die vorherige Anordnung wieder her. Im Vorschau-Modus ist das Hinzufügen gesperrt.
