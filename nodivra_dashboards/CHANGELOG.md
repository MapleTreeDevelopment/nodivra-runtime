# 0.6.1

- Modul-Logo der Mac-App im Dashboard und beim Verbinden eines Browsers.
- Ruhigere Navigation, klare Typografie und flache Standardkarten.
- Browser-Anmeldung unterstützt helles und dunkles Systemdesign.
- Einklappen, mobiler Drawer, Seiten ohne Logo sowie eigene Designs bleiben erhalten.
- Keine Änderung an Berechtigungen, Kopplung oder Geräteaktionen.

## 0.6.0

- Freie Inhaltspositionen, Sichtbarkeit, Ausrichtung und Schriftgröße je Geräteansicht.
- Gestaltbare Rahmen und Flächen, Linien/Trenner, Abstandselemente und Gruppen zum gemeinsamen Verschieben.
- Gruppen und Inhaltslayout werden zentral gespeichert und mit der gemeinsamen Darstellung wiedergegeben.

## 0.5.0

- Gemeinsame, palettenabhängige SVG-Symbole und dezente Wetter-/Zustandsanimationen.
- Einstellbare Symbole, Farben, Tempo und bis zu acht Zustands-/Schwellenwertregeln pro Karte.
- Geräteklassen, Einheiten und lesbare Zustände für Wertkarten. Unbekannte Werte bleiben ohne aktive Effekte.

## 0.4.0

- Logo je Seite ausblendbar; Navigationsschalter bleibt rechts auf Höhe des Dashboard-Titels erreichbar.

- Einklappbare Navigation mit Menü-Symbol rechts im Header; auf dem Handy standardmäßig geschlossen. Farben folgen dem Dashboard.
- Ansicht ohne HA-Rahmen im eigenen Tab öffnen. Normalen Verbindungsstatus ausgeblendet. Zahlen und Einheiten bleiben auf einer Zeile.

- Gemeinsame Kartenstile für alle Komponenten: Dashboard-Vorgabe mit optionalen individuellen Abweichungen. Standard, Minimal, Kompakt und Detail.
- Wetter- und Wertkarten nutzen identische Typografie und Abstände. Bestehende Darstellungen bleiben erhalten.

## 0.3.1

- Logo wie in der Mac-App, mit korrekt ausgerichtetem Haus und Untertitel.

- Dashboard beginnt oben: eigener Header mit Titel, optionalem Untertitel und Uhr. Kein vertikales Zentrieren kurzer Seiten.

## 0.3.0

- Wetterkarten in drei Designs, mit optionalem Zustand, Luftfeuchtigkeit und Wind.
- Benötigt Runtime 0.12.0 für Wetterdaten.

## 0.2.0

- Vier auswählbare Dashboard-Designs: Schiefer, Wolke, Sand und Nacht, jeweils mit Hell-/Dunkel-Darstellung.
- Optionale eigenständige Browser-Seite auf Port 8669, standardmäßig deaktiviert.
- Einmalcode-Kopplung über HA, 30 Tage gültige widerrufbare Browser-Anmeldung.
- HTTPS mit /ssl/fullchain.pem und /ssl/privkey.pem; lokales HTTP muss ausdrücklich ausgewählt werden.

- Überarbeitete Dashboard-Darstellung passend zum neuen Mac-Designer.
- Szenen, Raumklima, Hintergrundbilder und optionale Titel.
- Benötigt für die neuen Komponenten Runtime 0.11.0.

# 0.1.0

- Eigene Home-Assistant-App mit eigenem Webdienst und Sidebar-Eintrag.
- Gleiche Darstellung wie Mac-Vorschau und bisherige Runtime-Dashboards.
- Entwürfe, veröffentlichte Fassungen, Versionen, Zustände und Geräteaktionen bleiben auf der gemeinsamen Runtime.
- Begrenzter Verbindungsschlüssel: kein Zugriff auf Automationen oder Entwürfe.
- HA-Administratorprüfung, CSRF-Schutz und keine zusätzlichen LAN-Ports.
- Einrichtung der installierten Dashboard-App aus der Mac-App, ohne einen Schlüssel abzutippen.
- Die bisherige Runtime-Ansicht bleibt als Rückfallmöglichkeit erhalten.
