# Oberfläche: Runtime 0.18.1 und Dashboards 0.6.1

Beide Dienste verwenden das identische, lokal gebündelte Modul-Logo. Es werden dafür keine externen Bilder oder Schriften geladen. Navigation, Fokusmarkierungen und Typografie entsprechen der Mac-App. Die Runtime zeigt kompaktere Status- und Automationszeilen. Die Browser-Kopplung unterstützt helles und dunkles Systemdesign.

Die Standardflächen des gemeinsamen Dashboard-Renderers haben keinen dekorativen Verlauf oder Schatten mehr. Explizite Kartenstile und eigene Einstellungen bleiben erhalten. Die sechs vorhandenen Sprachkataloge aus der Mac-Vorschau werden nun auch in beiden Dienstpaketen mitgeliefert; die Standardsprache bleibt Deutsch. Verfasste Texte und rohe Entitätsdaten bleiben unverändert.

## Verhalten und Kompatibilität

- Keine Migration der Datenbanken oder Automationspakete.
- Keine Änderung der Swift-Ausführungsengine, des Protokolls oder der Geräteaktionen.
- HA Ingress, CSRF-Prüfung, eingeschränkte Dashboard-Schlüssel und Browser-Kopplung bleiben unverändert.
- Dashboard-Navigation bleibt am Desktop einklappbar und mobil ein Drawer. Escape schließt ihn. Bei ausgeblendetem Logo bleibt der Schalter am Seitentitel erreichbar.
- Gespeicherte Anordnungen, Gruppierung, Inhaltspositionen und Geräteansichten bleiben erhalten.
- Der Runtime-Eintrag verwaltet weiterhin nur Automationen und Runtime-Einstellungen; Dashboards werden separat geöffnet.

## Prüfung

114 Python-Tests mit echter Swift-Engine und lokaler Home-Assistant-Nachbildung bestanden. Diese prüfen unter anderem Wiederanlauf, unbestätigte Aktionen, Authentifizierung, Rechte, CSRF, Datenzugriff und Browser-Kopplung. Native WebKit-Prüfungen bestanden für mobile/Desktop-Navigation, ausgeblendete Logos, Geräteansichten und Teilfehler bei Sammelaktionen. Die Renderer-Prüfung testet 139 Texte und sechs Sprachen einschließlich Zuständen, Wetter, Zahlenformat und unveränderten eigenen Beschriftungen.

GitHub Actions baut und testet beide Linux-Images auf amd64 und aarch64. Der Status des jeweiligen Commits ist die maßgebliche Bestätigung. Eine Installation oder Abnahme an realen Geräten wird durch diese Tests nicht ersetzt.

## Update

Vorher eine vollständige Home-Assistant-Sicherung erstellen. Beide Updates können getrennt eingespielt werden. Die vorhandene Auswahl zum Fortsetzen aktiver Automationen gilt weiterhin; das Update schaltet keine pausierten Programme frei. Nach dem Webdienst-Update die Browser-Seite neu laden.
