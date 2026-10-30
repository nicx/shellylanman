# ShellyLanMan macOS Menüleisten-App — Project Guide

Menüleisten-App (SwiftUI `MenuBarExtra`, SwiftPM) um den Upstream-Server
`wimmme/shellylanman` (Go, GPL-3.0). Klon der Piper-App ([[piper-server]]-Familie:
bei Problemen zuerst Schwester-Apps greppen). Autor: nicx. Keine IPs/Hostnamen/Pfade committen.

- `Scripts/build-server.sh`: Go + Node als geprüfte Tarballs nach `.toolchain/`, Upstream
  (`UPSTREAM_REF`) nach `.upstream/`, Binary nach `Vendored/` (alles gitignored).
- `Scripts/make-app.sh`: SDK auf MacOSX26 gepinnt, Binary nach `Contents/Helpers/`, Version in
  Info.plist (`ShellyLanManServerVersion`), Build-Guard gegen laufende App. Bauen mit
  `CODESIGN_IDENTITY="nicx Selfsign"`.
- Server-Konfiguration nur per Env: `SHELLYLANMAN_DATA`, `SHELLYLANMAN_PORT` (3082). Lauscht auf `[::]`.
- Läuft produktiv aus `dist/` — nicht aus der Sandbox starten (Port 3082, Geister-Instanz).
- Kein Login-Item-Auto-Opt-in beim ersten Start (anders als Piper).
