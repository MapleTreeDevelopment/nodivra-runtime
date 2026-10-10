# Dashboard-Entitäten, Symbole und Darstellung

Stand: lokale Version 0.26.0 / Runtime 0.14.0 / Dashboards 0.5.0. Keine Abfrage privater Gerätebestände: geprüft wurden der Quellcode, isolierte Beispieldaten und die öffentliche Home-Assistant-Dokumentation.

## Gemeinsamer Stil

Alle zehn Komponenten (`weather`, `light`, `climate`, `scene`, `switch`, `value`, `text`, `image`, `camera`, `graph`) verwenden Standard, Minimal, Kompakt oder Detail; gemeinsam vererbt oder pro Karte überschrieben. Flächen, Rahmen, Typografie, Symbole und Effekte verwenden Designfarben. Auswahlrahmen und Griffe im Editor bleiben absichtlich blau. Fotos und Kamerabilder behalten ihre eigenen Farben.

## Abdeckung

| Entitäten / Daten | Darstellung | Bedienung / Grenzen |
| --- | --- | --- |
| `light`, `switch`, `input_boolean` | Licht-/Schalterkarte; Zustand, Helligkeit | Ein/Aus, Helligkeit; Licht auch als Bereich. Nicht jede Lichtfunktion wie Farbtemperatur/Farbe ist bereits ein Bedienelement. |
| `climate` | Raumklima, Ist-/Solltemperatur | Einzelner Sollwert; noch keine vollständige HVAC-Modus-/Temperaturbereichs-Bedienung. |
| `weather` | Temperatur, Zustand, Luftfeuchtigkeit, Wind; 15 standardisierte Zustände mit Symbolen | Aktuelle Daten; keine Vorhersage. Fehlende Messwerte erscheinen als Strich. |
| `camera` | Kamerabild / MJPEG oder wiederholte Einzelbilder | Keine universelle WebRTC-/Audio-Unterstützung. |
| `scene` | Szenenkarte | Szene aktivieren. |
| `sensor`, `number`, `input_number`, `counter` | Wertkarte mit automatisch übernommener Einheit; Zahlen als Livegraph | Nur lesend. Graphen zeigen bis zu 120 Werte seit dem Öffnen, keine HA-Historienabfrage. |
| `binary_sensor` | Zustandskarte über Wertanzeige; Geräteklasse bestimmt Symbol und Begriffe | Alle dokumentierten binären Geräteklassen beschriftet, z. B. Offen/Geschlossen statt Ein/Aus. |
| `cover`, `lock`, `fan`, `humidifier`, `valve`, `water_heater` | Zustand/skalare Attribute mit passendem Symbol in Wertkarte | Noch keine spezialisierten Bedienelemente für Position, Schlosscode, Lüfterstufe usw. |
| `alarm_control_panel`, `siren` | Lesbarer Zustand / Symbol | Keine Scharf-/Unscharf-Bedienkarte. |
| `person`, `device_tracker`, `zone`, `sun` | Zustand/skalare Attribute; Zuhause/Abwesend etc. | Keine Karte mit Geoposition. |
| `media_player`, `vacuum`, `lawn_mower` | Zustand / passende Symbole | Keine Medienbibliothek, Transportsteuerung, Reinigungskarte. |
| `calendar`, `todo`, `event` | Nur einfacher Zustand bzw. einfaches Attribut | Termine, Aufgaben und Ereignislisten brauchen eigene Datenabfragen und Karten. Ein Zeitstempel ist kein Ereignisverlauf. |
| `date`, `datetime`, `time`, `input_datetime`, `timer` | Wertkarte / Uhr- oder Kalendersymbol, Rohwert bei nicht übersetzbarem Format | Keine spezialisierten Editoren. |
| `select`, `input_select`, `text`, `input_text` | Textzustand in Wertkarte; längere Texte umbrechend | Kein Auswahl-/Texteingabe-Widget. |
| `button`, `input_button`, `remote`, `update`, `automation`, `script` | Einfacher Zustand, soweit vorhanden | Kein universeller Aktionsknopf; Zeitstempel/Status ist nicht gleich Funktionsbereitschaft. |
| `image`, `geo_location`, Air-quality- und sonstige Integrationen | Einfacher Zustand / skalare Attribute | Remote-Bilder, Koordinatenkarten und strukturierte Inhalte nicht automatisch renderbar. |
| AI Task, Conversation, Assist Satellite, Notify, STT/TTS, Wake Word, Infrared, Radio Frequency | Generischer Status, falls die Integration einen Zustand bereitstellt | Keine spezialisierten Bedienoberflächen. |
| Runtime-Werte | Signal, Zahl oder Timerrest aus aktivem Ablauf | Veraltete / inaktive Werte bleiben unbekannt. |

`unknown`, `unavailable`, fehlende Entitäten und Verbindungsverlust werden nicht als Aus/Null dargestellt. Regeln und Animationen sind dabei inaktiv. Listen/Objekte werden nicht als `[object Object]` ausgegeben; im Attribut-Picker werden nur unterstützte einfache Werte angeboten. Zugangsdaten bleiben ausgefiltert.

## Symbole und Regeln

37 explizite Motive plus Automatisch/Kein Symbol. Handgezeichnete, skalierbare Linien-SVGs; keine externen Bilddienste oder unkontrollierten SVG-Uploads. Sonne, Mond, Wolken, Regen, Schnee, Hagel, Gewitter, Nebel, Wind; Tür, Fenster, Garage, Schloss, Licht, Temperatur, Feuchtigkeit, Ventilator, Energie, Batterie, Bewegung, Anwesenheit, Rauch, Wasser, Sicherheit, Rollladen, Steckdose, Musik, Staubsauger, Kalender, Uhr, Klingel, Kamera, Blatt, Warnung.

Farben: Dashboard, Dezent, Warm, Kühl, Positiv, Hinweis, Warnung. Bewegung: passend zum Symbol, keine, drehen, atmen, wiegen, heben/senken, Änderungsimpuls. Tempo: ruhig, normal, lebhaft. Auslöser: Aktivität/passende Regel, solange verfügbar oder nur bei Wertänderung.

Bis zu acht geordnete Regeln: Gleich/Ungleich für Originalzustände; größer/mindestens/kleiner/höchstens für Zahlen. Dezimalkomma möglich. Erste passende Regel gewinnt. Wetter: Gleich/Ungleich vergleicht den Wetterzustand, Zahlenvergleiche die Temperatur in der gelieferten Einheit. Keine stillschweigende Umrechnung Celsius/Fahrenheit. Regeln ändern nur Darstellung, nie Geräte oder Automationen.

Beispiele: `on` → offene Tür; Temperatur `>= 28` → Warnfarbe + Atmen, darunter `>= 22` → Warm. Unbekannt bleibt ruhig. Bewegung reduzieren wird respektiert, CSS-Animationen pausieren außerhalb des sichtbaren Bereichs und in verborgenen Dokumenten. Regelgrenzen haben derzeit keine Hysterese.

## Quellen

- [HA Entity-Typen](https://developers.home-assistant.io/docs/core/entity/)
- [Binäre Geräteklassen und Zustände](https://www.home-assistant.io/integrations/binary_sensor/)
- [Sensoren und Geräteklassen](https://developers.home-assistant.io/docs/core/entity/sensor/)
- [Wetterzustände und Attribute](https://www.home-assistant.io/integrations/weather/)
