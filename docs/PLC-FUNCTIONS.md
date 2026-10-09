# Funktionsumfang · Nodivra 0.14 / Runtime 0.4

Eigenständige Softwareumsetzung nach dem Funktionsprinzip des bereitgestellten LOGO!-Systemhandbuchs (08/2024, A5E33039696-AM). Keine vollständige 1:1-Nachbildung von LOGO!-Hardware oder Soft Comfort. Die folgende Zuordnung macht reduzierte Optionen sichtbar.

## Anschlüsse und Bibliothek

Neue UND, ODER, XOR, NAND, NOR und die beiden Gate-Flankenauswertungen beginnen mit fünf Eingängen. Zwei bis acht sind im Inspector wählbar. Verbundene zusätzliche Eingänge müssen vor dem Verkleinern gelöst werden. Alte UND/ODER/XOR-Dateien behalten zunächst ihre zwei Eingänge.

Diese Logikbausteine und NICHT haben ein bis acht einstellbare sichtbare Q-Abgänge, zunächst fünf. Sie tragen dasselbe Ergebnis; jeder kann mehrere Ziele versorgen. Kein Duplizieren des Bausteins für einen Abzweig nötig. Ein Eingang nimmt genau eine Leitung auf. Freie UND-/NAND-Eingänge sind Ein, freie ODER-/NOR-/XOR-Eingänge Aus. Mindestens ein Eingang muss verbunden sein. Unbekannte verbundene Eingangswerte bleiben unbekannt. Eingänge und Q lassen sich digital negieren.

Q ist digital, AQ numerisch. Zähler, Frequenz- und Betriebsstundenzähler besitzen beide Ausgangstypen. Numerische Signale werden über Analogvergleich oder Schwellwertschalter in Schaltsignale umgewandelt. Rückführungen benötigen M-/AM-Merker.

Die Bibliothek gliedert sich in aufklappbare Gruppen: Ein-/Ausgänge, Grundfunktionen, Zeitfunktionen, Schaltuhren, Zähler, Speicher/Relais, Analogfunktionen, Regelung und HA-Abläufe. Die Suche öffnet passende Gruppen. Gleichwertige alte Katalogeinträge (Bewegung/Ein-Aus-Zustand, Zahlenvergleich mit Entität, alter Ausgang, Automatisch ausschalten und doppelte HA-Zeit-/Zustandsbedingungen) sind nicht nochmals aufgeführt; vorhandene Dateien bleiben lesbar.

## Grundfunktionen und virtuelle Signale

UND, NAND, ODER, NOR, XOR, NICHT, UND/NAND mit Flankenauswertung und freier Flankenimpuls (steigend/fallend/beide). XOR bedeutet bei mehr als zwei Eingängen ungerade Anzahl aktiver Eingänge.

Digitale/analoge Eingänge können virtuelle Werte oder HA-Entitäten/Attribute verwenden. Digitale/analoge Ausgänge können virtuell oder real zugeordnet werden. M-/AM-Merker und Kontakte übertragen Werte im folgenden Zyklus. Anlaufimpuls liefert genau im ersten Zyklus nach bewusstem Start Ein; damit angeschlossene Aktionen können beim Start ausgelöst werden. Optionale Remanenz seit Runtime 0.7; siehe [Neustart & Speicher](RESTART-AND-MEMORY.md).

## Zuordnung der 38 Sonderfunktionen

| Handbuchfunktion | Nodivra und aktueller Umfang |
|---|---|
| Einschaltverzögerung | Dauer, Trg und zusätzlicher Reset R |
| Ausschaltverzögerung | Nachlauf bei fallendem Trg, R bricht ab |
| Ein-/Ausschaltverzögerung | Getrennte Ein-/Ausschaltzeiten und R |
| Speichernde Einschaltverzögerung | Impuls startet; Zeit läuft trotz fallendem Trg weiter; Q bleibt bis R |
| Wischrelais | Zeitimpuls endet auch bei fallendem Trg |
| Flankengetriggertes Wischrelais | Verzögerung, Impulsdauer, Pause, Impulszahl und R |
| Asynchroner Impulsgeber | Ein-/Aus-Zeiten, En, R und Inv |
| Zufallsgenerator | Zufällige Ein-/Ausschaltverzögerung innerhalb der eingestellten Maximalzeiten |
| Treppenlichtschalter | Q beim Drücken, Nachlauf ab Loslassen, verlängerbar, Vorwarnunterbrechung, R |
| Komfortschalter | Kurzdruck mit Nachlauf ab Loslassen, Langdruck für Dauerlicht, erneuter Druck oder R schaltet aus |
| Wochenschaltuhr | Bestehendes Zeitfenster mit Wochentagen; ein Zeitfenster pro Block, weitere Fenster über ODER. Keine drei integrierten Nocken oder Feiertagsliste |
| Jahresschaltuhr | Jährlich wiederkehrendes Datumsfenster einschließlich beider Grenzen, auch über Jahreswechsel. Kein einmaliges Jahr-/Monatsprogramm |
| Astronomische Uhr | Breiten-/Längengrad, Auf-/Untergangsversatz; Näherungsrechnung des Tageslichtfensters, einschließlich Polartag/-nacht |
| Stoppuhr | En sammelt Sekunden, R setzt zurück; kein separater Rundenwert |
| Vor-/Rückwärtszähler | Flankenzählung, Richtung, Startwert, Reset, Q-Schwellen und AQ-Zählwert |
| Betriebsstundenzähler | Summierte Stunden, Wartungsschwelle, Q/AQ und gemeinsamer Reset. Kein zweiter separat remanenter Gesamtzähler |
| Schwellwertschalter | Frequenz erkannter Flanken im Messfenster, Q-Schwellen und AQ-Hz. Keine Hardware-Hochgeschwindigkeitszählung |
| Analoger Schwellwertschalter | Hysterese mit Ein-/Ausschaltschwelle; Skalierung über Analogverstärker |
| Differenzschwellwertschalter | Negative Differenz bildet Hysterese, positive Differenz ein Fenster [On, On+Delta). Skalierung vorgeschaltet |
| Analogkomparator | Differenz Ax−Ay mit Hysterese |
| Analogüberwachung | En speichert Referenz, Q bei Überschreitung der symmetrischen Abweichung |
| Analogverstärker | Verstärkung und Offset |
| Selbsthalterelais | Bestehendes Relais mit wählbarem RS-/SR-Vorrang |
| Stromstoßrelais | Trg schaltet um, S/R und wählbarer Vorrang |
| Meldetexte | Protokolleintrag und HA-Benachrichtigung über Dienstaktion; noch kein eigener mehrzeiliger LOGO!-Meldetexteditor mit Priorität/Quittierung |
| Softwareschalter | Virtueller digitaler Eingang und Taster/Schalter; lokal und Runtime-Eingänge bedienbar, keine identische Hardwaremenü-Umschaltung |
| Schieberegister | 1–32 Bits, In/Trg/Dir/R, wählbares Ausgangsbit |
| Analoger Multiplexer | En und zwei Auswahlpins wählen vier feste Werte |
| Rampensteuerung | Zwei Zielstufen, Startwert, Änderungsrate, En/Sel/R; keine separate Anfahr-/Auslaufkurve |
| PI-Regler | Fester Sollwert, Kp, Ti, Ausgangsgrenzen, begrenzter Integrator und Reset. Hand-/Automatik-Umschaltung noch nicht enthalten |
| Impulsdauermodulator | En, Analogwert, Eingangsbereich und Periode |
| Mathematische Funktion | Zwei Analogwerte und +/−/×/÷; komplexere Formeln durch verbundene Blöcke, keine freie Formelsprache |
| Fehlererkennung Mathe | Digitales Signal bei unbekanntem/ungültigem Analogwert, etwa Division durch null. Noch keine getrennten Fehlerklassen |
| Analogfilter | Gleitender Mittelwert über N zyklische Abtastwerte, 1–256 wählbar |
| Max/Min | Laufender Maximal- oder Minimalwert mit R; Modus im Inspector, kein S1-Moduswechsel |
| Mittelwert | N Werte mit einstellbarem Zeitabstand; Ergebnis nach vollständigem Messfenster, R beginnt neu. Fehlende Messungen werden nicht erfunden |
| Gleitpunkt/Ganzzahl | Auflösung, Rundung und vorzeichenbehafteter 16-/32-Bit-Ausgang; keine VM-Adressen |
| Ganzzahl/Gleitpunkt | Ganzzahliger Eingangsteil × Auflösung als AQ; keine VM-Adressen |

Zusätzlich: Signal entprellen, Analogwert begrenzen, freier Flankenimpuls und Anlaufimpuls. Die 40 neuen Einträge enthalten auch ergänzte Grundfunktionen; sie sind nicht als 40 zusätzliche LOGO!-Sonderfunktionen zu verstehen.

## Ausführung, Zeit und Grenzen

Alle neuen Funktionen laufen in derselben Swift-Engine auf dem Mac und in der Runtime. Zielzyklus 100 ms, keine harte Echtzeit. Timer liefern verbleibende Sekunden im Snapshot. Aktionsbestätigungen, systembedingte Verzögerungen und Eingangswerte begrenzen die Genauigkeit. Kurze Impulse zwischen zwei Zyklen können verloren gehen. PI/PWM und Frequenz sind für langsame HA-Signale vorgesehen; Aktionsratenbegrenzungen bleiben wirksam.

R bedeutet Rücksetzen. Beim RS/SR- und Stromstoßrelais ist der Vorrang wählbar; bei anderen Funktionen hat Reset Vorrang. Unbeschaltete digitale Sonderfunktionspins sind Aus, optionale En-Pins von Überwachung/PWM/Multiplexer sind Ein. Nicht vorhandene analoge Pflichtanschlüsse werden diagnostiziert. Zahlen-/Auswahlwerte werden vor Ausführung geprüft.

Seit Runtime 0.7 können Merker, Register, Zeit- und Zählstände erhalten und optional fortgesetzt werden. Ohne Remanenz bleiben Programme nach Neustart pausiert und werden neu initialisiert. Noch offen: programmübergreifende Merker, weitere Parameterreferenzen außerhalb der drei grundlegenden Zeitbausteine, Hardware-Spezialmerker, VM/S7/Modbus-Anbindung, Soft-Comfort-Dateiformate, wiederverwendbare Unterprogramme und der oben ausgewiesene zusätzliche Optionsumfang.

Erweiterte Programme verwenden Graphformat 4 / Runtime-Protokoll 3. Ältere Formate 2/3 und Protokolle 1/2 bleiben unterstützt. Eine ältere Runtime wird vor Transfer neuer Funktionen abgewiesen. Neue Dokumente nicht mit einer älteren App überschreiben; vorherige Projektdateien und unveränderte lokale Entwürfe bleiben gesichert.

## Variable Zeiten ab 0.14

Wertauswahl mit 2–8 unabhängigen Bedingungen, konfigurierbaren Werten, Standardwert und eindeutiger Priorität. Eingänge von oben nach unten: I1 gewinnt vor I2 usw. Zeitwerte werden in Sekunden an AQ ausgegeben. Zahlenmodus bleibt auch für andere Parameterverknüpfungen nutzbar.

Ein-/Ausschaltverzögerung und Zeitimpuls besitzen optional T (analog) neben Trg und R. Übernahme am Start der Laufzeit; laufende Zeit bleibt konstant. Ungültiges T beim Start pausiert die Ausführung. Diese Erweiterung benötigt Graphformat 5 / Protokoll 4. Feste Zeiten und andere bisherige Funktionen bleiben rückwärtskompatibel. Details: [Variable Zeiten](VARIABLE-TIMES.md).
