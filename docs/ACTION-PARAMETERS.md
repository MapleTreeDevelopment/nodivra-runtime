# Verknüpfbare Aktionsparameter

Nodivra 0.15 / Runtime 0.5. Ein/Aus bzw. Start bleibt der erste Eingang einer Aktion. Über das Verbindungssymbol neben einem Konfigurationsfeld wird ein zusätzlicher, benannter Anschluss eingeblendet. Der bisherige feste Wert bleibt für die spätere Rückkehr erhalten. Das Entfernen eines Anschlusses mit seiner Verbindung wird bestätigt und ist rückgängig machbar.

## Beispiel Licht

1. `Licht steuern` aus der Bibliothek hinzufügen.
2. Unter Ziel einen oder mehrere Bereiche oder Entitäten wählen. Geräte, Etagen und Labels sind ebenfalls möglich.
3. `Helligkeit (%)` über das Verbindungssymbol als Anschluss einblenden.
4. `Ausschaltverzögerung.Q → Ein/Aus`; `Wertauswahl.AQ → Helligkeit`.
5. Weitere Felder (beispielsweise Farbtemperatur, Übergang, RGB-Farbe) unter Weitere Einstellungen hinzufügen und bei Bedarf genauso verbinden.

Ein schon vorhandener Analogausgang für eine Leuchte kann im Inspector in diesen Aktionsblock umgewandelt werden. Ziel und Helligkeitsverbindung bleiben erhalten; Q muss anschließend noch mit Ein/Aus verbunden werden. Bei ausgehenden Analogverbindungen ist die Umwandlung gesperrt, um deren Bedeutung nicht zu verändern.

## Datentypen

Die Verknüpfung gilt für alle Daten- und Zielfelder einer unterstützten HA-Dienstaktion, nicht nur für eine Liste vorgegebener Lichtparameter. Verfügbare Felder und Auswahlwerte werden aus den Dienstbeschreibungen der verbundenen HA-Instanz übernommen. Eigene Datenfelder sind ergänzbar. Zahlen, Ein/Aus, Texte, Listen und Objekte behalten ihre JSON-Typen. Auch verschachtelte Felder oder ein vollständiges Datenobjekt sind verknüpfbar. Ein übergeordnetes Objekt und seine Unterfelder können nicht gleichzeitig verbunden sein.

Die bestehende Wertauswahl unterstützt zusätzlich Ganzzahl, Ein/Aus, Text, Liste und Objekt. Kein zusätzlicher Auswahlbaustein nötig. Ein/Aus-Eingänge bestimmen wie bisher den jeweiligen Wert; freie Eingänge gelten als Aus, die niedrigste aktive Eingangsnummer gewinnt. Ganzzahlen verwenden den Zahlenkanal und werden als ganze Zahlen geprüft (±1 Milliarde); bestehende Zahlen- und Zeitprogramme bleiben unverändert.

Beispiele: Helligkeit/Temperatur → Zahl; MQTT retain → Ein/Aus; Nachricht/Effekt → Text; RGB-Farbe → Liste; komplexe Aktionsdaten → Objekt. `Warten (Dauer)` kann Sekunden über einen Zahlenanschluss übernehmen. Bezeichnungen und Aktionsnamen sind Konfiguration, keine dynamischen Nutzparameter. Verschachtelte HA-Ablaufkonstrukte, Templates und Aktionsrückgabewerte erhalten durch diese Änderung keine zusätzliche Runtime-Unterstützung.

## Ausführung

- Flankenaktionen übernehmen alle verbundenen Werte gemeinsam beim Start. Parameteränderungen allein lösen sie nicht aus.
- Ein/Aus-Folgeaktionen übernehmen Datenänderungen während Ein. Während Aus wird keine Aktion wegen einer Datenänderung gesendet. Die Aktivierung eines Programms sendet weiterhin keine unveränderten Ausgangswerte.
- Bei einer ausstehenden Antwort werden neue Folgewerte zusammengefasst. Ein zwischenzeitliches Aus bleibt als gewünschter Zustand erhalten und wird nach Bestätigung ausgeführt. Nach unbestätigtem/fehlgeschlagenem Geräteaufruf wird weiterhin pausiert und nicht automatisch wiederholt.
- Ein dynamisches Ziel wird beim Einschalten übernommen und bis zum Ausschalten beibehalten. Das Ausschalten geht an dieses Ziel, auch bei inzwischen geänderter Zielauswahl oder unbekannten Datenwerten. Ein neues Ziel wird beim nächsten Einschalten verwendet.
- Warten übernimmt die Dauer beim Start; spätere Änderungen verändern den laufenden Countdown nicht.
- Fehlende Verbindungen, falsche Typen und überlappende Feldpfade werden vorab geprüft. Ein beim Start ungültiger Wert pausiert die Ausführung, ohne Ersatzwert oder Geräteaufruf in diesem Zyklus. Eine Pause schaltet zuvor eingeschaltete Geräte nicht automatisch aus.
- Übernommene HA-Wertebereiche/Auswahlwerte sowie häufige Lichtparameter werden lokal geprüft. Integrationsspezifische Kombinationen und Gerätefähigkeiten validiert letztlich Home Assistant. Diese Prüfung ersetzt keine vollständige HA-Serviceschema-Auswertung.

Neue Parameterprogramme benötigen Protokoll 5 / Graphformat 6. Die App verhindert ihre Übertragung an eine ältere Runtime. Alte Programme bleiben ausführbar. Lokale Simulation und Server verwenden dieselbe Engine; neue Werttypen sind auch im Live-Snapshot enthalten. Das frühere YAML-Backend lehnt diese Programme ausdrücklich ab.

Grenzen: höchstens 32 verknüpfte Parameter pro Aktion, Feldpfad maximal 16 Ebenen, einzelner Wert maximal 64 KiB; bisherige Programm- und Aktionsratenbegrenzungen gelten weiter. Ganze Objektverbindungen werden nicht automatisch in einzelne Pins zerlegt. Für Text/Listen/Objekte ist die Wertauswahl die Quelle; analoge und digitale Merker bleiben ihre bisherigen Zahlen-/Bool-Speicher.

HA-Grundlagen: [Ziele und Aktionsparameter](https://www.home-assistant.io/docs/scripts/perform-actions/), [Dienstbeschreibungen](https://developers.home-assistant.io/docs/dev_101_services/).
