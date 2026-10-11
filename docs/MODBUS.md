# Modbus-Datenpunkte

Die Mac-App richtet Geräte über **Automationen → Datenpunkte** oder **Runtime → Modbus · Geräte und Datenpunkte** ein. Die gemeinsame Runtime übernimmt die Suche und das dauerhafte Lesen. Der Mac muss nicht eingeschaltet bleiben. Diese erste Fassung schreibt keine Register oder Coils.

## Einrichtung

1. Runtime verbinden. Eine Runtime mit der Fähigkeit `modbus.read.v1` ist erforderlich.
2. Private IPv4-Adresse eingeben, beispielsweise `192.168.1.20/32`, oder einen ausdrücklich gewünschten Netzbereich bis `/24`. Port (normalerweise 502) und Unit-ID passend zum Gerät einstellen. Pro Suche höchstens 256 Adress-/Unit-Kombinationen, vier gleichzeitige Prüfungen. Die Suche ist abbrechbar und läuft nur auf ausdrücklichen Start.
3. Gerät auswählen. Ein offener TCP-Port allein zählt nicht als Modbus-Gerät. Die Suche versucht Read Device Identification (43/14), SunSpec und nötigenfalls eine lesende Registerabfrage. Identifikation kann vom Gerät nicht unterstützt werden; Unit-ID und Port können abweichen.
4. Bei SunSpec die gewünschten Datenpunkte auswählen. Bei anderen Geräten ein zur Modell-/Firmwareversion passendes JSON-Profil importieren und auswählen. Es werden keine Registerbereiche blind nach vermeintlichen Temperaturen oder Kontakten abgesucht.
5. Namen und Abfragepause festlegen und die ausgewählten Datenpunkte einrichten. Die Live-Liste zeigt Wert, Einheit, letzte erfolgreiche Messung und Qualität.
6. Im Editor einen **Digitalen Eingang** oder **Analogen Eingang** hinzufügen, Quelle **Modbus** wählen und den Datenpunkt suchen. Vergleiche, Timer, Merker und die bisherigen Logikbausteine bleiben unverändert nutzbar.

## SunSpec

Suche nach der SunS-Signatur an den nullbasierten Adressen 40000, 0 und 50000. Modellketten sind auf 64 Modelle begrenzt. Modell 1 liefert Geräteinformationen; unterstützte Messmodelle: 101–103 (Wechselrichter), 201–204 (Zähler). Skalierungsfaktoren und Nicht-verfügbar-Kennungen werden ausgewertet. Unbekannte Modelle werden als solche erfasst, nicht als interpretierte Messwerte angeboten. Maximal 128 Datenpunkte je Geräteprofil. SunSpec ist keine universelle Geräteerkennung für alle Modbus-Geräte.

Definitionen: https://github.com/sunspec/models (Apache-2.0). Unveränderte JSON-Dateien und Lizenz liegen unter `Runtime/server/sunspec`.
Protokoll: https://www.modbus.org/file/secure/modbusprotocolspecification.pdf

## Geräteprofile

`Documentation/modbus-profile-example.json` ist ein **synthetisches Schema-Beispiel**, kein Profil für ein reales Gerät. Adressen und Datentypen müssen anhand des Gerätehandbuchs angepasst werden. Insbesondere sind in manchen Handbüchern beispielsweise 40001 und die nullbasierte Adresse 0 unterschiedliche Schreibweisen desselben Holding-Registers.

- `schemaVersion`: 1; `id`: stabile Profilkennung; `name`: Anzeigename.
- `match`: optionales Objekt mit exakten `manufacturer`- und `model`-Kennungen sowie optional `version`. Bei genau einem Treffer schlägt die App das Profil vor; Einrichtung bleibt ausdrücklich zu bestätigen.
- `points`: maximal 128 Datenpunkte mit je eindeutiger Kennung (Groß-/Kleinschreibung zählt nicht).
- `function`: 1 Coils, 2 diskrete Eingänge, 3 Holding-Register, 4 Input-Register; ausschließlich lesend.
- `address`: nullbasierte Protokolladresse, 0–65535.
- `type`: bool, uint16/int16, uint32/int32, uint64/int64, float32/float64. Große 64-Bit-Ganzzahlen können in der Double-basierten Automationsengine Genauigkeit verlieren; für exakte Zähler oberhalb 2^53 nicht geeignet.
- `scale`, `offset`: Ergebnis = Rohwert × scale + offset.
- `order`: ABCD normal, BADC Byte-Tausch innerhalb der Wörter, CDAB umgekehrte Wortreihenfolge, DCBA beides. Für 64-Bit-Werte wird die ganze Wortfolge umgedreht.
- `bit`: bei bool ein bestimmtes Registerbit 0–15. Coils/diskrete Eingänge liefern bool ohne Bitangabe.
- `unit`: Anzeigeeinheit. `invalid`: optionale Liste ungültiger Rohwerte.
- `sfAddress`: optionaler SunSpec-Skalierungsfaktor aus einem Holding-Register (int16, gültiger Exponent −10 bis 10).

Importe enthalten ausschließlich Daten, keine Skripte oder auszuführenden Ausdrücke. Änderungen an importierten Profilen ändern bestehende Geräte nicht: Jedes Gerät speichert seine ausgewählten Definitionen als Kopie. Zum Ändern eines eingerichteten Geräts dessen Automationen pausieren, das Gerät entfernen und neu einrichten; danach Eingänge neu zuordnen.

## Ausführung und Fehler

Ein konfiguriertes Gerät besitzt eine eigene serielle Abfrageschleife; alle Automationen teilen sich deren Messwerte. Es gibt keine Modbus-Abfrage pro Logikzyklus. Die eingestellte Pause liegt zwischen vollständigen Abfragerunden; Anzahl der Datenpunkte und Antwortzeiten verlängern den tatsächlichen Abstand. Fehler führen zu mindestens fünf Sekunden Pause. Maximal 32 Geräte.

Fehlende, ungültige und veraltete Werte werden nicht als 0 oder Aus eingespeist. Eine Automation mit einem nicht aktuellen Modbus-Eingang kann nicht gestartet werden; fällt ein Eingang später aus, pausiert die Automation vor dem nächsten Auswertungsschritt. Bestehende Ausgangszustände am Gerät werden dabei nicht aktiv zurückgestellt. Wiederanlauf folgt den vorhandenen, ausdrücklich eingestellten Neustartregeln und benötigt wieder aktuelle Eingänge. Rein lokale Modbus-/virtuelle Logik kann ohne HA laufen; HA-Geräteaktionen benötigen weiterhin die HA-Verbindung.

Daten liegen in `/data/modbus.sqlite` und gehören zur vollständigen HA-App-Sicherung. Aktuelle Messwerte werden nicht als gültige Werte über Neustarts gespeichert. Verknüpfungen gehören zur jeweiligen Runtime; beim Wechsel auf eine andere Runtime müssen ihre Datenpunkte dort eingerichtet und zugeordnet werden. Simulation nutzt eigene Testwerte und fragt keine Geräte ab.

Nicht enthalten: Modbus RTU/serielle Schnittstellen, IPv6/DNS-Suche, Schreibausgänge, alle SunSpec-Modelle, automatische PDF-Interpretation oder eine umfassende Herstellerprofil-Sammlung. Die erste Geräteabnahme muss mit einem konkreten Modell und dessen Registerbeschreibung erfolgen.

