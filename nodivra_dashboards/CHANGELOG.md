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
