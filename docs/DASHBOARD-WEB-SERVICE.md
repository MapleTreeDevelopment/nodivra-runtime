# Eigenständige Dashboard-App

Nodivra Dashboards 0.2.0 ist eine zusätzliche HA-OS-App. Sie enthält einen eigenen Python-Webdienst und denselben Renderer wie die Mac-Vorschau. Die gemeinsame Runtime ab 0.11.0 bleibt Eigentümerin aller Dashboard-Dokumente, Veröffentlichungen, Versionen und Geräteaktionen. Eine zweite Ausführungsengine oder Datenbank wird nicht angelegt.

## Einrichtung

1. Vor dem Runtime-Update eine vollständige Home-Assistant-Sicherung erstellen.
2. Gemeinsame Runtime auf 0.11.0 aktualisieren. Vorhandene Wiederanlaufregeln der Automationen gelten weiterhin.
3. Aus derselben Nodivra-Repositoryquelle die zusätzliche App **Nodivra Dashboards** installieren.
4. In Nodivra für Mac 0.23 unter **Runtime → Dashboard-Webdienst → Verbinden** die installierte App verbinden. Die Mac-App übernimmt den begrenzten Verbindungsschlüssel, die Serverkennung und den internen Hostnamen automatisch. Bestehende Optionen bleiben erhalten. Nur der Dashboard-Webdienst wird bei geänderter Verbindung neu gestartet.
5. **In Seitenleiste anzeigen** direkt auf der Info-Seite der Dashboard-App in Home Assistant einschalten. Der Eintrag öffnet die veröffentlichten Dashboards.

Es werden keine Automationen aktiviert und keine Dashboards automatisch veröffentlicht. Die erste Installation wird bewusst über Home Assistant bestätigt; der Mac-Knopf installiert keine unbekannte Software im Hintergrund.

## Trennung und Zugriff

- Der Webdienst nutzt standardmäßig Ingress. Optional kann Port 8669 für gekoppelte Browser freigegeben werden. Er besitzt keine Supervisor-Verwaltungsrechte und keinen eigenen Home-Assistant-Token.
- Der abgeleitete Verbindungsschlüssel erlaubt nur veröffentlichte Dashboards, Livewerte, Kameras und Bedienaktionen der veröffentlichten Licht-/Schalterkomponenten. Entwürfe, Veröffentlichung und Automationen sind damit nicht erreichbar.
- Die Runtime prüft zusätzlich die über Ingress übermittelte HA-Administratoridentität. Der Schlüssel allein erlaubt keine Bedienung ohne diese Prüfung.
- Der Browser erhält weder Runtime- noch HA-Zugangsschlüssel. Schreibzugriffe brauchen außerdem den CSRF-Wert der aktuellen Webdienst-Sitzung.
- Der Webdienst prüft die gespeicherte Runtime-Serverkennung vor Weiterleitung. Weiterleitungen auf andere Hosts und frei wählbare Proxy-Ziele sind ausgeschlossen. Fehlgeschlagene Bedienaktionen werden nicht automatisch wiederholt.
- Ein Wechsel des Hauptschlüssels macht den abgeleiteten Display-Schlüssel ungültig; anschließend in der Mac-App erneut verbinden. Eine Verbindung zu einer anderen Serverkennung wird nicht still überschrieben.

## Wiederherstellung

Die bisherige integrierte Dashboard-Ansicht bleibt über die gemeinsame Runtime erreichbar. Wenn der separate Webdienst ausfällt, kann man ihn stoppen oder deinstallieren, ohne Dashboard- oder Automationsdaten zu verlieren. Dokumente und deren Sicherungen liegen weiterhin in der Runtime; ihre vollständige HA-Sicherung ist der Wiederherstellungspunkt. Eine erneute Installation wird mit derselben Runtime verbunden. Änderungen am Webdienst benötigen keinen Neustart der Automationsengine.

## Aktuelle Grenzen

HA-Administratorkonto erforderlich. Tablet-Zugang über die optionale Browser-Kopplung, keine eigene Benutzerverwaltung. Kamera-Funktionen entsprechen der gemeinsamen Runtime (Einzelbilder/MJPEG, kein HLS/WebRTC oder Audio). Ein fehlender Kamerastream wird durch die Trennung nicht behoben. Der Dashboard-Webdienst ist ohne erreichbare Runtime nicht bedienbar; der Mac darf ausgeschaltet sein.

## Eigene Browser-Seite ab 0.2.0

Die HA-App liefert auf Wunsch eine eigenständige Seite aus. Der Mac muss nicht laufen.

1. In den Einstellungen von Nodivra Dashboards den Netzwerk-Port 8669 freigeben.
2. `standalone_host` auf den verwendeten Hostnamen setzen (Standard `homeassistant.local`).
3. `standalone_mode` auf `https` setzen, wenn `/ssl/fullchain.pem` und `/ssl/privkey.pem` vorhanden sind. Alternativ `http` für das vertrauenswürdige Heimnetz ausdrücklich wählen; dabei ist die Übertragung unverschlüsselt.
4. Den Dashboard-Webdienst neu starten; die Automations-Runtime bleibt davon unabhängig.
5. In der HA-Seitenleiste Nodivra Dashboards öffnen und **Browser verbinden** wählen. Am Mac oder Tablet die angezeigte Adresse öffnen und den fünf Minuten gültigen Einmalcode eingeben.

Jeder Browser wird einzeln gekoppelt. Die Anmeldung gilt 30 Tage, überlebt Webdienst-Neustarts und kann über **Alle Browser abmelden** widerrufen werden. Der Runtime-Zugangsschlüssel bleibt auf dem Server. HA-Administratorrechte werden bei Datenabrufen erneut geprüft. Keine Router-Portfreigabe einrichten.

## Dashboard-Designs

Mac-App 0.23 bietet Schiefer, Wolke, Sand und Nacht als Farbvorschauen. Das Design gehört zum Dashboard und wird mit Entwurf, Veröffentlichung und Versionen gespeichert. Jedes Design unterstützt Hell, Dunkel und System. Die App-Darstellung ist davon unabhängig; Geräteanordnungen bleiben beim Designwechsel erhalten.
