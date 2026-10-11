# Stechuhr

Native macOS-Zeiterfassung für Arbeit mit viel Kontextwechsel. Alles läuft lokal.

- **Vordergrund ("Ich")**: Stechuhr zeichnet selbst auf, welche App, welches Fenster und welcher Browser-Tab aktiv ist (alle 2 s). Ohne Maus/Tastatur ab 3 min (einstellbar), bei Bildschirmsperre oder Ruhezustand zählt die Zeit als abwesend.
- **Hintergrund**: manuell markierte Hintergrundaufgaben und automatisch erfasste Claude-Code-Sessions (über Hooks).
- **Zuordnung nach Inhalt**: gruppierte Aktivitätsliste (App → Fenstertitel, Browser → Domain → Seitentitel), Gruppen mit einem Klick zuweisen, daraus Regeln machen, Mehrfachauswahl in Liste und Timeline.
- **Auswertung pro Projekt und Tag**: Vordergrund, Hintergrund (manuell / Claude Code), Überlappung, abrechenbar, Anzahl Arbeitsblöcke, längster Block. Die doppelt gezählte Zeit wird separat ausgewiesen.

## Automatische Zuordnung

Reihenfolge, die erste passende Stufe gewinnt:
1. **Von Hand** zugewiesen (Liste, Timeline, Mehrfachauswahl)
2. **Regeln** (z. B. „App ist Figma und Titel enthält Acme“)
3. **Stichwörter**: Projektname plus eigene Stichwörter pro Projekt, als ganze Wörter gesucht in Fenstertitel,
   Seitentitel und URL. Passen mehrere Projekte, bleibt der Schnipsel „mehrdeutig“ und unzugeordnet.
4. sonst **nicht zugeordnet**

Claude-Code-Ordner: feste Ordner-Zuordnung, sonst Projektname/Stichwort im Pfad (z. B. `~/repos/acme-website` → Acme).

**Lernen:** Weist du ähnliche Schnipsel mehrmals von Hand demselben Projekt zu (≥ 3×, an ≥ 2 Tagen oder ≥ 30 min,
≥ 90 % eindeutig), schlägt Stechuhr unter „Regeln“ eine passende Regel vor. Sie gilt erst, wenn du sie übernimmst.

## Bauen und starten

```bash
scripts/build-app.sh            # baut dist/Stechuhr.app
scripts/build-app.sh --install  # zusätzlich nach /Applications kopieren
swift test                      # Tests der Zeitlogik
```

Daten liegen in `~/Library/Application Support/Stechuhr/` (`stechuhr.sqlite`).

### Berechtigungen
- **Bedienungshilfen** (Systemeinstellungen → Datenschutz & Sicherheit): nötig für Fenstertitel. Ohne sie erfasst Stechuhr nur App-Namen.
- **Automation** pro Browser (fragt macOS beim ersten Mal): für URL und Titel des aktiven Tabs in Safari, Chrome, Arc, Brave, Edge, Vivaldi und Opera. Private Fenster werden ohne Titel und URL erfasst. Firefox liefert nur den Fenstertitel.
- Die App ist ad-hoc signiert. Nach einem Neubau mit `build-app.sh` kann macOS die Freigaben deshalb wieder verlangen.

## Claude-Code-Erfassung

Beim Start kopiert die App den Helfer `stechuhr-hook` nach
`~/Library/Application Support/Stechuhr/bin/stechuhr-hook`. Globale Hooks in `~/.claude/settings.json`
rufen ihn auf bei `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `Notification`,
`PermissionRequest`, `PostToolUse` (alle `async`) und `SessionEnd` (synchron, Timeout 2 s).

Der Helfer schickt nur `session_id`, Ereignisname, `cwd`, Zeitstempel und ggf. `notification_type` / `source` /
`reason` / `session_title` an `127.0.0.1:47600`. Prompt-Texte und Antworten werden nie übertragen oder gespeichert.
Läuft die App nicht, hängt er das Ereignis an `claude-events.jsonl` an; die App liest die Datei beim nächsten Start ein.
Er bricht nach spätestens ~1 s ab und gibt immer Exit-Code 0 zurück.

**Arbeitszeit einer Session** = von `UserPromptSubmit` bis `Stop`/`StopFailure`/`SessionEnd`. Wartet Claude auf
Eingabe (`PermissionRequest`, `Notification` mit `permission_prompt`/`idle_prompt`/`elicitation_dialog`), pausiert die
Zeit; die nächste Tool-Aktivität setzt sie fort. Ist ein Terminal mit dieser Session im Vordergrund, zählt die Zeit
als Vordergrund und wird nicht zusätzlich als Hintergrund gewertet.

## Sicherheit und Datenschutz

- Alle Daten bleiben lokal in `~/Library/Application Support/Stechuhr/`. Es gibt keine Verbindung ins Internet.
- Der Hook-Empfang lauscht nur auf `127.0.0.1:47600` und verlangt einen geheimen Schlüssel
  (`hook-token`, Dateirechte 0600), den die App beim ersten Start erzeugt. Anfragen mit `Origin`-Header
  (Browser) oder fremdem `Host` (DNS-Rebinding) werden abgewiesen.
- Der Hook-Helfer überträgt nie Prompt-Texte oder Antworten von Claude, nur Zeitstempel, Session-ID, Ereignis und Arbeitsordner.
- Aufgezeichnet werden App-Namen, Fenstertitel und URLs aktiver Browser-Tabs. Private Browserfenster werden ohne Titel und URL erfasst.
  Die Datenbank ist nicht verschlüsselt; sie ist so geschützt wie dein Benutzerkonto (FileVault empfohlen).
