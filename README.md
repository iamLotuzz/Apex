# Apex – Fahrten, Rundenzeiten, Pixel-Garage

Native iOS-App (Swift, SwiftUI, iOS 26, Liquid Glass) nach dem Vorbild von Enroad und Pixelgarage.

## Funktionen

- **Fahrten automatisch**: Ab 10 km/h startet die Aufzeichnung im Hintergrund (einstellbar). Ende nach 4 min Stillstand oder wenn du losläufst.
- **Fahrt-Details**: Karte nach Tempo eingefärbt, Strecke, Dauer, Fahr- und Standzeit, Stopps, Ø- und Höchsttempo, 0–50, 0–100, 80–120, max. Beschleunigung und Bremsung in g, Kurvigkeit, Höhenprofil, Tempo-Verteilung, Zeit über 100/130 km/h, Verbrauch, Kosten, CO₂, Wetter beim Start, GPX-Export.
- **Übersicht**: Fahrten nach Monat, Wochen-Zusammenfassung, Favoriten, Filter, Wischen zum Löschen, Mehrfachauswahl.
- **Strecken & Sessions**: Rennstrecke anlegen (Name, Start/Ziel-Linie auf der Satellitenkarte antippen, auch Sprint A → B). Live-Session im Querformat mit großem Delta zur vorherigen (oder besten) Runde, Tempo, Rundenzeiten und Prognose. Danach Auswertung mit Rundenzeit-Diagramm, Konstanz, Karte pro Runde und Tempo-Vergleich.
- **Garage**: mehrere Autos (Auto-Leiste mit Symbolen, „+ Auto“), pro Auto zwei Bilder als PNG oder Foto → Pixel-Art mit Hintergrund-Entfernung:
  - Seitenansicht: fährt durch die animierte Pixel-Szene mit Live-Wetter.
  - Schräg von vorne: Widget, Auto-Auswahl und Symbole neben Fahrten und Sessions.
  - Dazu Fahrzeugdaten, Statistik pro Auto oder für alle Autos, Kilometerstand. Fahrten lassen sich nachträglich einem anderen Auto zuordnen.
- **Wetter & Fahrbedingungen**: Grip-Index, Glätte-, Regen-, Nebel- und Windwarnungen, Stundenvorhersage (Open-Meteo).
- **Tankstellen**: Günstigste Preise im Umkreis für deinen Kraftstoff (Tankerkönig).
- **Widget**: Sperrbildschirm (Pixel-Auto links, drei günstigste Tankstellen rechts) sowie klein und mittel für den Homescreen.

## Bauen ohne Mac (GitHub Actions)

1. Auf github.com ein neues Repository anlegen (z. B. `Apex`).
   - Öffentlich: unbegrenzte Build-Minuten.
   - Privat: ca. 200 macOS-Minuten im Monat gratis (etwa 20 Builds).
2. „uploading an existing file“ wählen und den **Inhalt** dieses Ordners hineinziehen, inklusive `.github`. Commit auf `main`.
3. Tab **Actions** → „Build IPA“ läuft automatisch (ca. 8–12 min).
4. Wenn der Build grün ist: unten bei **Artifacts** `Apex-ipa` laden und entpacken.
5. Wenn der Build rot ist: auf der Seite des Laufs steht unter **Compile errors** die Fehlerliste. Diese Liste an Claude schicken.

## Installieren mit AltStore

1. AltServer läuft auf dem PC, AltStore ist auf dem iPhone, beide im selben WLAN.
2. `Apex.ipa` aufs iPhone bringen (z. B. iCloud Drive oder Google Drive → „In Dateien sichern“).
3. AltStore → **My Apps** → **+** → `Apex.ipa` wählen.
4. Mit kostenloser Apple-ID läuft die App 7 Tage. AltStore erneuert sie automatisch, wenn AltServer erreichbar ist.

Hinweise zur kostenlosen Apple-ID:
- Maximal 3 aktive Apps (AltStore zählt mit).
- App und Widget brauchen zusammen 2 App-IDs (Limit: 10 pro Woche).

## Nach der Installation

1. Beim Start Standort **„Immer“** erlauben, dazu Bewegung & Fitness und Mitteilungen.
2. Garage → Auto bearbeiten: Pixel-PNG, Modell, Leistung, Verbrauch und Kraftstoff eintragen.
3. Einstellungen → eigenen **Tankerkönig-API-Key** eintragen (kostenlos unter creativecommons.tankerkoenig.de). Ohne Key zeigt die App Demo-Preise.
4. Widget hinzufügen: Sperrbildschirm lange drücken → Anpassen → Widgets → Apex.
5. Zum Testen ohne Fahrt: Einstellungen → „Demo-Daten erzeugen“.

## Grenzen

- Das iPhone-GPS liefert Apps 1 Messung pro Sekunde. Apex gleicht das so aus:
  - Positionen werden mit der genaueren Doppler-Geschwindigkeit gefiltert.
  - Linien-Durchfahrten werden mit einem Beschleunigungsmodell interpoliert.
  - Starts misst der Beschleunigungssensor mit 50 Hz.
  - Ergebnis: Rundenzeiten etwa ±0,05–0,1 s, 0–100 etwa ±0,1 s. Für Hundertstel braucht es einen externen 10–25-Hz-GPS-Empfänger.
- Sofort-Start (Standard an) hält stromsparendes Orten aktiv. Apex erkennt die Abfahrt so in Sekunden, und die Fahrt beginnt am Parkplatz. Das kostet etwas Akku.
- Wurde die App per Wischen beendet, weckt iOS sie erst nach einigen hundert Metern. Den Start rechnet Apex dann trotzdem auf den Parkplatz zurück.
- Sperrbildschirm-Widgets zeigt iOS einfarbig. Das Pixel-Auto erscheint dort in Graustufen, auf dem Homescreen in Farbe.
- Tankerkönig liefert nur Preise für Deutschland.

## Projektaufbau

- `project.yml`: XcodeGen-Projekt (App und Widget-Extension)
- `Apex/`: App (Models, Services, Views)
- `ApexWidget/`: Widget
- `Shared/`: Code für App und Widget (App Group, Tankerkönig, Pixel-Auto)
- `Config/`: Info.plist- und Entitlements-Dateien
- `.github/workflows/build.yml`: baut die unsignierte `Apex.ipa`

Datenquellen: Open-Meteo.com (CC BY 4.0), Tankerkönig / MTS-K (CC BY 4.0), Apple Maps.
