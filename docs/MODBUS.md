# Modbus über Home Assistant

Ab Runtime 0.18.0 gibt es keine eigene Modbus-Verbindung, Netzwerksuche oder Geräteprofilverwaltung mehr. Richte Modbus-Geräte in Home Assistant ein und verwende deren vorhandene Entitäten in Nodivra.

- Zustände/Kontakte: Digitaler Eingang → Home Assistant → Entität auswählen.
- Messwerte: Analoger Eingang → Home Assistant → Sensor auswählen; bei Bedarf ein numerisches Attribut wählen.
- Schalten: Digitaler Ausgang oder HA-Aktion mit der passenden switch-/light-Entität. Ein Befehlsschalter ist kein tatsächlicher Positionssensor.

Bestehende HA-Entitäten und Integrationen werden nicht verändert. Frühere direkte `nodivra_modbus.*`-Eingänge müssen ausdrücklich einer HA-Entität zugeordnet werden; keine automatische Zuordnung oder Umdeutung zu Aus/0. Alte lokale Modbus-Datenbanken bleiben für eine mögliche Rückkehr zur vorherigen Version unverändert, werden aber nicht mehr geöffnet oder abgefragt. Ein Update kann die Verbindung zur Runtime kurz unterbrechen; die vorhandene Wiederanlauf-Einstellung gilt weiterhin.
