# Stechuhr

Native macOS-Zeiterfassung für Arbeit mit viel Kontextwechsel. Alles läuft lokal.

- **Vordergrund ("Ich")**: Stechuhr zeichnet selbst auf, welche App, welches Fenster und welcher Browser-Tab aktiv ist (alle 2 s). Ohne Maus/Tastatur ab 3 min (einstellbar), bei Bildschirmsperre oder Ruhezustand zählt die Zeit als abwesend.
- **Hintergrund**: manuell markierte Hintergrundaufgaben und automatisch erfasste Claude-Code-Sessions (über Hooks).
- **Zuordnung nach Inhalt**: gruppierte Aktivitätsliste (App → Fenstertitel, Browser → Domain → Seitentitel), Gruppen mit einem Klick zuweisen, daraus Regeln machen, Mehrfachauswahl in Liste und Timeline.
- **Auswertung pro Projekt und Tag**: Vordergrund, Hintergrund (manuell / Claude Code), Überlappung, abrechenbar, Anzahl Arbeitsblöcke, längster Block. Die doppelt gezählte Zeit wird separat ausgewiesen.

## Automatische Zuordnung

Zwei Ebenen, wie bei Timing: Stechuhr zeichnet **App-Nutzung** fein auf und schlägt daraus **Zeiteinträge**
(Blöcke) vor. Bestätigte Blöcke zählen ganz für ihr Projekt, kurze Abstecher zu Werkzeugen fragmentieren nichts mehr.

Reihenfolge pro Schnipsel, die erste passende Stufe gewinnt:
1. **Von Hand** zugewiesen
2. **Regeln** (App, Titel, Domain, URL, Dateipfad; ist / enthält / beginnt mit / endet mit / Regex)
3. **Ordner**: Dokumentpfad liegt in einem zugeordneten Ordner (z. B. `~/Kunden/Acme`)
4. **Stichwörter**: Projektname + Stichwörter als ganze Wörter in Titel, URL, Pfad; mehrere Treffer → „mehrdeutig“
5. **Claude-Code-Session**: Claude-App/Terminal → Projekt der Session. Bei mehreren offenen Sessions: gehören alle
   zum selben Projekt (z. B. Worktrees eines Repos), gilt dieses; sonst die Session mit dem letzten Prompt
6. **Umfeld**: Werkzeug-Apps (Claude, GitKraken, Terminal, Finder, …) ohne eigenen Hinweis übernehmen das Projekt
   der Arbeit davor/danach (bis 5 min)

**Zeiteinträge**: In der Timeline oben erscheinen Vorschläge gestrichelt. Klick prüft und übernimmt, ⌥-Klick übernimmt
direkt, „Vorschläge übernehmen“ bestätigt alle mit erkanntem Projekt. Innerhalb eines Zeiteintrags zählt alles für
dessen Projekt, außer Schnipseln, die eindeutig zu einem anderen Projekt gehören.

**Projekte aus Ordnern**: Stechuhr schlägt Projekte aus `~/repos` (einstellbar) und Claude-Code-Ordnern vor; Klone
desselben Git-Repos und Ordner mit gleichem Namensanfang werden zusammengefasst. Ordner aus dem Finder auf die
Projektseite ziehen legt ebenfalls Projekte mit Ordner-Zuordnung an.

**Lernen**: Wiederholte manuelle Zuweisungen (≥ 3×, ≥ 90 % eindeutig) ergeben Regel-Vorschläge unter „Regeln“.

## Nachfragen und laufende Einträge

- **Woran arbeitest du gerade?** Erkennt Stechuhr ≥ 3 min lang kein Projekt, erscheint ein kleines Fenster unter der
  Menüleiste (stiehlt keinen Fokus). Die Antwort wird ein Zeiteintrag, der weiterläuft.
- **Nach Abwesenheit** (≥ 15 min): Projekt und Notiz (z. B. „Besprechung“) für die Zeit.
- **Timer per Klick**: Hover oder Klick auf das Menüleisten-Icon zeigt alle Projekte (heute bearbeitete zuerst). Ein Klick startet
  den Timer, ein Klick auf ein anderes Projekt wechselt, ein Klick auf das laufende stoppt. Im Feld „+“ ein neues
  Projekt eintippen und Enter: angelegt und gestartet. Selbst gestartete Timer laufen, bis du wechselst, stoppst
  oder länger weg bist.
- Laufende Einträge enden erst nach ≥ 3 min eindeutig anderer Projektarbeit oder einer längeren Pause;
  kurze Blicke in andere Projekte zählen nicht.

## Auswertung und Export

„Auswertung“ zeigt Woche, Monat oder einen Zeitraum mit Summen pro Projekt. CSV-Export (Excel, deutsches Format:
Semikolon, Dezimalkomma, Stunden dezimal):
- **Projekte pro Tag**: Vordergrund, bestätigt, Hintergrund, Claude Code, Überlappung, abrechenbar, Blöcke
- **Zeiteinträge und Hintergrundaufgaben**: Datum, Von, Bis, Dauer, Projekt, Titel/Notiz

## Export für KI

„Für KI exportieren“ (Tagesansicht) bzw. „Heute für KI kopieren“ (Menüleiste) erzeugt den ganzen Tag als Markdown:
Übersicht pro Projekt, Zeiteinträge, Claude-Code-Sessions, Browser nach Website und Seite (mit Profil), Apps nach
Fenster/Dokument und einen chronologischen Verlauf. URLs ohne Query-Parameter und Fragmente. Bei Firefox-basierten
Browsern (Firefox, Waterfox, Zen, LibreWolf) liest Stechuhr die URL über die Bedienungshilfen; sonst wird die
Website aus dem Fenstertitel geschätzt.

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

## Lizenz

MIT – siehe [LICENSE](LICENSE). Nutzung, Änderung und Weitergabe sind frei, solange der Copyright-Hinweis erhalten bleibt.
