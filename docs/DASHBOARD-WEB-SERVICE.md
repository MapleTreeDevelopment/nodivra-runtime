# Eigenständige Dashboard-App

Nodivra Dashboards 0.1.0 ist eine zusätzliche HA-OS-App. Sie enthält einen eigenen Python-Webdienst und denselben Renderer wie die Mac-Vorschau. Die gemeinsame Runtime ab 0.10.0 bleibt Eigentümerin aller Dashboard-Dokumente, Veröffentlichungen, Versionen und Geräteaktionen. Eine zweite Ausführungsengine oder Datenbank wird nicht angelegt.

## Einrichtung

1. Vor dem Runtime-Update eine vollständige Home-Assistant-Sicherung erstellen.
2. Gemeinsame Runtime auf 0.10.0 aktualisieren. Vorhandene Wiederanlaufregeln der Automationen gelten weiterhin.
3. Aus derselben Nodivra-Repositoryquelle die zusätzliche App **Nodivra Dashboards** installieren.
4. In Nodivra für Mac 0.21 unter **Runtime → Dashboard-Webdienst → Verbinden** die installierte App verbinden. Die Mac-App übernimmt den begrenzten Verbindungsschlüssel, die Serverkennung und den internen Hostnamen automatisch. Bestehende Optionen bleiben erhalten. Nur der Dashboard-Webdienst wird bei geänderter Verbindung neu gestartet.
5. **In Seitenleiste anzeigen** direkt auf der Info-Seite der Dashboard-App in Home Assistant einschalten. Der Eintrag öffnet die veröffentlichten Dashboards.

Es werden keine Automationen aktiviert und keine Dashboards automatisch veröffentlicht. Die erste Installation wird bewusst über Home Assistant bestätigt; der Mac-Knopf installiert keine unbekannte Software im Hintergrund.

## Trennung und Zugriff

- Der Webdienst hat ausschließlich Ingress-Zugang und keinen freigegebenen LAN-Port, keine Supervisor-Verwaltungsrechte und keinen eigenen Home-Assistant-Token.
- Der abgeleitete Verbindungsschlüssel erlaubt nur veröffentlichte Dashboards, Livewerte, Kameras und Bedienaktionen der veröffentlichten Licht-/Schalterkomponenten. Entwürfe, Veröffentlichung und Automationen sind damit nicht erreichbar.
- Die Runtime prüft zusätzlich die über Ingress übermittelte HA-Administratoridentität. Der Schlüssel allein erlaubt keine Bedienung ohne diese Prüfung.
- Der Browser erhält weder Runtime- noch HA-Zugangsschlüssel. Schreibzugriffe brauchen außerdem den CSRF-Wert der aktuellen Webdienst-Sitzung.
- Der Webdienst prüft die gespeicherte Runtime-Serverkennung vor Weiterleitung. Weiterleitungen auf andere Hosts und frei wählbare Proxy-Ziele sind ausgeschlossen. Fehlgeschlagene Bedienaktionen werden nicht automatisch wiederholt.
- Ein Wechsel des Hauptschlüssels macht den abgeleiteten Display-Schlüssel ungültig; anschließend in der Mac-App erneut verbinden. Eine Verbindung zu einer anderen Serverkennung wird nicht still überschrieben.

## Wiederherstellung

Die bisherige integrierte Dashboard-Ansicht bleibt über die gemeinsame Runtime erreichbar. Wenn der separate Webdienst ausfällt, kann man ihn stoppen oder deinstallieren, ohne Dashboard- oder Automationsdaten zu verlieren. Dokumente und deren Sicherungen liegen weiterhin in der Runtime; ihre vollständige HA-Sicherung ist der Wiederherstellungspunkt. Eine erneute Installation wird mit derselben Runtime verbunden. Änderungen am Webdienst benötigen keinen Neustart der Automationsengine.

## Aktuelle Grenzen

HA-Administratorkonto erforderlich. Kein unabhängiger Tablet-Zugang und keine eigene Benutzerverwaltung. Kamera-Funktionen entsprechen der gemeinsamen Runtime (Einzelbilder/MJPEG, kein HLS/WebRTC oder Audio). Ein fehlender Kamerastream wird durch die Trennung nicht behoben. Der Dashboard-Webdienst ist ohne erreichbare Runtime nicht bedienbar; der Mac darf ausgeschaltet sein.
