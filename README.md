# ShellyLanMan (macOS Menüleisten-App)

Native macOS-**Menüleisten-App**, die [ShellyLanMan](https://github.com/wimmme/shellylanman)
(Shelly-Geräte im LAN finden, überwachen, konfigurieren, Firmware verwalten) direkt auf
dem Mac betreibt — **ohne Docker**. Upstream liefert nur Docker-Images und eine
Home-Assistant-App; diese App baut den Go-Server selbst und steuert ihn.

Stack: Swift · SwiftUI `MenuBarExtra` · Go-Binary (Upstream, Weboberfläche eingebettet) · `SMAppService`.

- Starten / Stoppen / Neu starten, Auto-Restart bei Absturz, Mitteilung bei Absturz/Erholung.
- „Weboberfläche öffnen“ → `http://localhost:3082/`.
- Protokoll als Live-Fenster und als Datei, optional Start beim Anmelden.
- **Firmware-Hinweise per Mail:** die App fragt alle 12 h (einstellbar) `GET /api/v1/firmware/index` des lokalen Servers ab. Den Index holt der Server selbst, die Shellies brauchen dafür kein Internet. Neue Updates werden einmalig per Mail an ein lokales Mail-Relay (Klartext-SMTP) gemeldet, dazu eine macOS-Mitteilung. Mit UI-Passwort braucht die App einen API-Token mit Stufe „read“ (liegt im Schlüsselbund).
- Übernimmt eine verwaiste eigene Instanz, die nach einem App-Absturz noch den Port belegt.

## Bauen

```bash
./Scripts/build-server.sh                                  # Go + Node holen (verifiziert), Upstream bauen
CODESIGN_IDENTITY="nicx Selfsign" ./Scripts/make-app.sh    # → dist/ShellyLanMan.app
```

`build-server.sh` lädt Go und Node als offizielle Tarballs nach `.toolchain/` (kein
Homebrew) und baut den Upstream-Stand `UPSTREAM_REF` (Standard `v1.0.0`).
Update = `UPSTREAM_REF=<Tag> ./Scripts/build-server.sh`, danach neu bauen.

## Speicherort

```
~/Library/Application Support/ShellyLanMan/   Einstellungen, Archiv, Backups, Firmware-Cache
~/Library/Logs/ShellyLanMan/shellylanman.log
```

## Sicherheit

ShellyLanMan lauscht auf allen Schnittstellen (Shellies laden lokal ausgelieferte
Firmware von dort) und hat standardmäßig **kein UI-Passwort**. Passwort in der
Weboberfläche unter Settings → Security setzen.

## Lizenz

App: MIT. Der gebündelte Server steht unter GPL-3.0-or-later (Upstream, wimmme/shellylanman).
