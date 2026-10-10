# Live-Diagnose – Nodivra 0.17 / Runtime 0.8

Im Dashboard bei einer laufenden Automation **Live** wählen und einen Block anklicken. Rechts erscheinen Eingangswerte, Erklärung, Timerdetails und der letzte Aktionsstatus. Die lokale Simulation verwendet dieselbe Engine und dieselben Erklärungen, sendet aber keine Geräteaktionen.

## Eingänge und Logik

Ein und Aus sind bekannte Zustände. Ein verbundener Eingang ohne auswertbaren Wert ist **unbekannt**. Ein erforderlicher, unverbundener Anschluss hat einen **fehlenden Wert**. Unbeschaltete optionale oder neutrale SPS-Eingänge werden ausdrücklich so bezeichnet. Die dargestellten Werte berücksichtigen Eingangsnegierung; eine Ausgangsnegierung wird gesondert genannt.

Die Erklärung folgt dem tatsächlichen Engine-Verhalten. Zum Beispiel: „I2 ist Aus – Ausgang: Aus.“ Ist ein benötigter Wert unbekannt, wird daraus kein Aus-Zustand erfunden. Bei UND/ODER lässt die aktuelle Engine einen verbundenen unbekannten Wert als unbekannt weiterlaufen, auch wenn ein anderer Eingang das Ergebnis theoretisch bestimmen könnte.

## Zeiten

- **Aktuelle Zeitvorgabe:** fest eingestellter Wert oder derzeit an T anliegender Wert, soweit erfasst.
- **Beim Start übernommen:** die tatsächlich für die laufende Zeit erfasste Dauer. Ein später geänderter T-Wert verändert einen begonnenen Nachlauf nicht.
- **Vergangen / Verbleibend:** Zeitstand aus der Engine; die App zählt ihn nicht unabhängig weiter.
- **Reset / Abbruch:** R aktiv, unbekannter Eingang, geändertes Eingangssignal oder regulärer Ablauf werden unterschieden. Der letzte Zeitstatus bleibt bis zum nächsten Start sichtbar.

Bei mehrphasigen Sonderfunktionen beziehen sich Angaben auf die laufende Zeitphase. Nicht erfasste Werte erscheinen als „—“. Beim Fortsetzen eines alten Laufzustands ohne Diagnosedaten bleibt die echte Restzeit sichtbar; eine vergangene Zeit wird nicht geschätzt. Neu gespeicherte Timerdiagnosen bleiben mit der Remanenz erhalten. Ausfallzeit zählt weiterhin nicht mit.

## Aktionen

**Aufruf gesendet** bedeutet, dass die WebSocket-Nachricht versendet wurde; die Bestätigung steht aus. **Von Home Assistant bestätigt** bedeutet einen erfolgreichen Dienstaufruf. Ob eine Lampe physisch leuchtet oder ein Gerät seinen Zielwert erreicht hat, wird dadurch nicht nachgewiesen.

**Fehlgeschlagen oder nicht bestätigt** umfasst abgelehnte Aufrufe, verlorene Verbindungen und ausbleibende Antworten. Es erfolgt keine automatische Wiederholung. In der Beobachtung steht **Nur beobachtet**, im Simulator **Lokal simuliert**. Protokollaktionen sind ausdrücklich als solche gekennzeichnet.

Der angezeigte Aktionsstatus ist der letzte Aufruf dieses Blocks, mit Zeitstempel im Inspektor. Veraltete Live-Signale werden weiterhin verworfen. Fehler bleiben im begrenzten Runtime-Protokoll nachvollziehbar, auch wenn der Ablauf pausiert wurde.

## Vom Protokoll zum Block

Eine Meldung im Dashboard oder unter der Live-Ansicht anklicken. Nodivra öffnet die zugehörige Serverfassung, wählt den Block aus, scrollt zu ihm und zeigt den vollständigen Eintrag mit Zeitpunkt. Der Eintrag ist als historisch gekennzeichnet; die Blockansicht zeigt die aktuelle Programmfassung. Wurde der Block inzwischen entfernt, erscheint ein entsprechender Hinweis statt einer Zuordnung zu einem anderen Block. Die lokale Simulation erlaubt denselben Sprung aus ihren Meldungen.

Eine ältere Runtime bleibt für bisherige Funktionen kompatibel. Detaillierte Diagnosen benötigen Runtime 0.8. Fehlende Diagnosedaten werden nicht als aktuelle Informationen dargestellt. Ein Runtime-Update startet den Dienst neu und unterliegt den bestehenden Neustartregeln; es wird durch die neue Mac-App nicht automatisch installiert.
