# My Hub

**Deine Apps, Kategorien und Shortcuts in einem Radmenü für macOS.**

My Hub legt einen kleinen, frei verschiebbaren Knopf über den Schreibtisch. Ein Klick öffnet deine Favoriten im Kreis. Von dort wechselst du zu Kategorien und ihren Apps. Das Rad lässt sich mit Trackpad oder Maus drehen und rastet an den Einträgen ein.

## Download und Installation

1. Lade **My Hub.dmg** unter [Releases](https://github.com/Harryerdtz/my-hub/releases) herunter.
2. Öffne die DMG und ziehe **My Hub.app** in **Programme**.
3. Starte My Hub. Da die App derzeit ohne Apple Developer ID signiert ist, musst du den Start gegebenenfalls unter **Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen** bestätigen.

Benötigt macOS 14 oder neuer. Auf macOS 26 verwendet das Radmenü native Liquid-Glass-Effekte; auf älteren Versionen erscheint eine angepasste Darstellung.

## Das kannst du tun

- Apps und Ordner hinzufügen, aus My Hub entfernen und in Kategorien organisieren
- Eigene Kategorien erstellen, umbenennen und löschen
- Favoriten festlegen und ihre Reihenfolge im Kreis anpassen
- Shortcuts erstellen, die mehrere Apps oder Ordner öffnen
- Laufende Apps erkennen und über das Kontextmenü schließen
- Mit **⌘ ⇧ Leertaste** das Radmenü öffnen; mit Pfeiltasten, Return und Esc bedienen
- Kreisgröße, Scrolltempo und Animationen in den Einstellungen anpassen

Die Bibliothek und Einstellungen werden lokal in den macOS-Benutzereinstellungen gespeichert. My Hub benötigt keinen Account.

## Aus dem Quellcode bauen

Xcode Command Line Tools und Swift 6 werden benötigt.

```bash
swift build -c release
./scripts/build-dmg.sh
```

Danach liegen `My Hub.app` und `My Hub.dmg` im Ordner `dist/`. Das Build-Skript signiert die App lokal mit einer Ad-hoc-Signatur; für eine allgemein vertrauenswürdige Verteilung wäre zusätzlich eine Developer-ID-Signatur samt Notarisierung nötig.

## Projektstruktur

- `Sources/WidgetDesk/main.swift` – App-Bibliothek und Hauptfenster
- `Sources/WidgetDesk/FloatingHub.swift` – schwebendes Radmenü und Interaktion
- `Assets/MyHub.icns` – App-Icon
- `scripts/build-dmg.sh` – Release-Paket und DMG
