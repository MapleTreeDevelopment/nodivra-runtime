# Dynamischer Bausteinkatalog · Runtime 0.19.0

Ab Mac-App 0.35.9 lädt Nodivra Bausteinbeschreibungen von der verbundenen Runtime. Spätere Runtime-Versionen können damit weitere feste PLC-Funktionen anbieten, ohne dass der Mac für jede Funktion ein Update benötigt. Neue Steuerelemente, Signaltypen oder grundsätzlich andere Ausführungsmodelle benötigen weiterhin ein App-Update.

## Bedienung und bestehende Programme

Die vorhandene Bausteinpalette, Suche, Verbindungsvorschläge, Karten und Anschlussleitungen bleiben erhalten. Der Katalog ergänzt die Palette nach dem Verbinden. Die App speichert zuletzt erfolgreich geladene Metadaten getrennt je Runtime-Adresse und prüft die Serverkennung beim Wiederverbinden. Bei einer fehlgeschlagenen Abfrage bleiben gespeicherte Beschreibungen verfügbar. Ein Wechsel zu einer Runtime ohne Katalog verwendet die lokale Palette.

Bestehende Bausteine werden nicht automatisch umgeschrieben. Ihre Positionen, IDs, Parameter und Verbindungen bleiben unverändert. Ein neu eingesetzter Katalogbaustein trägt seine vollständige versionierte Beschreibung im Programm. Spätere Katalogabfragen ersetzen diese Beschreibung nicht. Programme mit solchen Bausteinen verwenden Programmprotokoll 6. Ältere Programme verwenden weiterhin ihr bisheriges Protokoll; die Runtime unterstützt 1 bis 6.

Bekannte Definitionen können lokal simuliert werden. Funktionen, deren exakte Definition und Implementierung die App noch nicht kennt, lassen sich bearbeiten und strukturell prüfen. Die Funktionsprüfung und Ausführung erfolgen auf der passenden Runtime. Die lokale Simulation lehnt diese Funktionen ausdrücklich ab. Die App lädt keinen ausführbaren Code und keine Skripte nach.

## HTTP-Vertrag

`GET /api/v1/blocks/catalog` benötigt den normalen Runtime-Zugangsschlüssel. Ein Dashboard-Anzeigeschlüssel hat keinen Zugriff. Die Antwort wird aus der laufenden Swift-Engine erzeugt und nicht gecacht (`Cache-Control: no-store`). Statusmeldungen behalten `protocolVersion: 5` für vorhandene Clients und ergänzen `maxProgramProtocol: 6` sowie `blocks.catalog.v1` in `capabilities`.

Der Katalog enthält `schemaVersion: 1` und `definitions`. Jede Definition enthält:

- Stabile `id`, ganzzahlige `version` und den Funktionsnamen `function`.
- `title`, `category`, `summary` und einen SF-Symbolnamen `icon`.
- Feste `inputs` und `outputs` mit `label` und `type`.
- `fields` mit `key`, `label`, `kind`, `initial`, optional `minimum`/`maximum` und `choices`.

Die verfügbaren Feldarten sind `number`, `text`, `choice`, `toggle` und `entity`. Das erste Release verwendet die vorhandenen festen PLC-Funktionen. Variable Eingangsanzahlen und komplexe Konfigurationseditoren behalten ihre bisherigen nativen Editoren.

## Grenzen und Erweiterung

Schema 1 unterstützt maximal 512 Definitionen, 16 Eingänge, 8 Ausgänge und 32 Einstellfelder pro Definition. Jeder Ausgang muss einen anderen Signaltyp besitzen. Die vorhandene Engine hat einen digitalen, einen analogen und einen gemeinsamen Parameterwert pro Baustein; daher ist höchstens ein Parameter-Ausgang zulässig. Unbeschaltete Standardwerte sind in Schema 1 nur für digitale Eingänge erlaubt. Textlängen, IDs, Zahlenbereiche, Auswahlwerte und Entitätsnamen werden geprüft. Unbekannte Schema-Versionen werden abgelehnt.

Ein neuer Block benötigt eine echte Implementierung und Tests in der Swift-Runtime sowie eine gültige Beschreibung. Eine JSON-Datei allein erzeugt keine neue ausführbare Funktion. Die Runtime vergleicht gespeicherte Beschreibungen vollständig mit ihrem unterstützten Katalog, bevor sie ein Programm ausführt. Manipulierte Parametergrenzen, Ports oder unbekannte Versionen werden abgelehnt.

Veröffentlichte Definitionen und ihr Verhalten müssen erhalten bleiben. Für Änderungen an einem veröffentlichten Vertrag muss eine neue Version eingeführt werden; die Runtime muss die alte Beschreibung **und** deren Ausführung weiter unterstützen. Die aktuelle Registry enthält Version 1 der vorhandenen Funktionen. Das bloße Erhöhen einer Versionszahl migriert keine bestehenden Programme. Für unabhängige neue Funktionen wird eine neue ID verwendet. Bei Katalogänderungen die Runtime-Version erhöhen, damit verbundene Clients neu laden.

Katalogdaten enthalten keine Zugangsschlüssel, Home-Assistant-Zustände oder Benutzerprogramme. Der übliche Runtime-Zugriffsschutz gilt unverändert. Installation und Update aktivieren keine zuvor pausierten Automationen; vorhandene Wiederanlaufregeln gelten weiterhin.

## Aktivierungsrückmeldung in der Mac-App

Die App prüft die Antwort auf eine Aktivierung und liest den Zustand anschließend zurück. Ein abgelehnter Start oder sofortiger Stopp bleibt als Meldung bei der betreffenden Automation sichtbar. Der Aktivierungsdialog schließt nur nach bestätigtem Zustand. Überholte parallele Statusantworten werden verworfen. Die Wiederanlaufsperre und gespeicherte Zustände werden niemals automatisch zurückgesetzt.
