# AI-Patch-Gate für AAOS unter Linux

Benutzerhandbuch

## 1. Überblick

### Wozu das Werkzeug dient

Ein AAOS-Build dauert lange. Ein Tippfehler im Diff, ein vergessener Null-Check oder eine Änderung, die an der eigentlichen Absicht vorbeigeht, fällt oft erst nach vielen Minuten auf, wenn der Compiler abbricht oder das Image nicht tut, was es soll. Der AI-Patch-Gate schaltet eine kurze Vorprüfung vor den Build: Ein KI-Modell sieht sich die aktuellen Änderungen einmal pro `m` an und sagt, ob es einen Compile-Bruch, einen konkreten Laufzeitfehler oder eine verfehlte Absicht erwartet.

Der Compiler bleibt die eigentliche Prüfung. Das Modell kennt keine absolute Wahrheit, und der Gate hält Sie nie dauerhaft auf. Ein Urteil, eine abgelehnte Frage und ein früher fehlgeschlagener Stand sperren den nächsten Build nicht.

### Was der Gate tut

1. Sie rufen wie gewohnt `m` auf. Der Gate hängt an `build/soong/bin/m`.
2. Der Gate sammelt den Diff gegen `HEAD`, den obersten Stash und die Betreffzeilen Ihrer letzten Commits. Nur Dateien, die er noch nicht gesehen hat, gehen an das Modell.
3. Das Modell antwortet mit drei Einschätzungen: Compile (`ok`, `likely_fail`, `unknown`), Laufzeit (`ok`, `concern`, `unknown`) und Effekt (`likely`, `unlikely`, `unknown`). Wenn ein Mensch bestätigen sollte, stellt es eine Rückfrage in einem Satz.
4. Je nach Betriebsart fragt der Gate vor dem Build nach, oder er startet den Build sofort und zeigt den Hinweis nebenher im Terminal.
5. Nach dem Build merkt sich der Gate, ob dieser Stand kompiliert hat. Ein Stand, der schon einmal durchlief, wird nicht noch einmal geschickt.

### Was Sie brauchen

- Einen AAOS/AOSP-Quellbaum mit `build/soong/bin/m`, `build/soong/soong_ui.bash` und `build/envsetup.sh`.
- Die Pakete `jq` und `python3`. Für den Weg über ein API-Token oder eine eigene URL zusätzlich `curl`. Beispiel: `sudo apt install jq curl`. `git` liegt ohnehin im Checkout.
- Einen KI-Anbieter: Claude, Microsoft Copilot oder Antigravity. Entweder ist dessen Kommandozeile (`claude`, `copilot`, `agy`) installiert und angemeldet, oder Sie haben ein API-Token. Microsoft Copilot braucht die Kommandozeile `copilot` auch mit Token. Claude und Antigravity kommen mit einem Token ohne ihre Kommandozeile aus.

### In fünf Minuten einsatzbereit

1. Wechseln Sie in das Verzeichnis `aaos-ai-gate` neben diesem Handbuch und starten Sie den Installer:

   ```bash
   bash install-linux.sh
   ```

2. Beantworten Sie die Fragen nach Quellbaum, Betriebsart, Anbieter und Anmeldung. Die Eingabetaste übernimmt jeweils den Vorschlag. Der Installer hat vorher nachgesehen, welche Kommandozeile installiert ist.
3. Lesen Sie die Zusammenfassung am Ende. Sie nennt den Baum, die Betriebsart, den Anbieter und den Ort der Konfiguration.
4. Bauen Sie wie immer:

   ```bash
   source build/envsetup.sh
   lunch sdk_car_x86_64-userdebug
   m
   ```

Beim ersten `m` mit Änderungen meldet sich der Gate mit Zeilen, die mit `ai-patch-gate:` beginnen. In der blockierenden Betriebsart erscheint die Frage `So beabsichtigt? [j/N]`, wenn das Modell etwas auszusetzen hat.

## 2. So arbeitet der Gate

### Zwei Betriebsarten

**Blockierend, Vorabtest** ist die Voreinstellung. Frage und Urteil erscheinen, bevor Ninja startet.

- `j`, `ja`, `y` oder `yes` lässt den Build zu, auch wenn das Modell `likely_fail` sagt. Dieses Ja wird für genau diesen Stand gemerkt.
- Die Eingabetaste, `n` oder jede andere Eingabe stoppt nur diesen Lauf. Sie wird nicht gemerkt, der nächste `m` fragt wieder.
- Sieht das Modell einen Compile-Bruch, ohne selbst eine Frage zu stellen, lautet die Frage `Sieht nicht kompilierbar aus. Trotzdem bauen?`.
- Ein Stand, der schon einmal fehlgeschlagen ist, startet trotzdem. Der Gate sagt das und fragt das Modell dafür nicht noch einmal.
- Läuft `m` ohne Terminal, etwa aus einer IDE-Aufgabe ohne Eingabe, wird die Frage nur gedruckt, und der Build startet.

**Parallel, nur Hinweis** startet den Build sofort, zusammen mit der Anfrage, und bricht ihn von selbst nie ab.

- Hinweise erscheinen im Terminal und können im Ninja-Log nach oben rutschen. Nach dem Build stehen sie noch einmal gesammelt zwischen `----- ai-patch-gate -----`.
- Wird der Build fertig, während die Anfrage noch läuft, bricht der Gate die Anfrage ab. Der nächste `m` prüft erneut. Es gibt keine Wartezeit und keine Sperre.
- Strg-C im Terminal und der Stop-Knopf der IDE beenden den Build. Der Gate gibt dem Build dabei bis zu zehn Sekunden, um sauber zu enden.
- `suggest` und `suggest-only` sind andere Namen für dieselbe Betriebsart. Unter Windows öffnet derselbe Modus zusätzlich ein Hinweisfenster, unter Linux bleibt es beim Terminal.

Die einzige harte Weigerung ist `AAOS_AI_GATE=stop`. Sie gilt nur in der blockierenden Betriebsart und nur bei `likely_fail`. Dann startet der Build nicht, und es wird nicht gefragt. Die vom Installer geschriebene Konfiguration setzt `AAOS_AI_GATE=on`, also nie die harte Weigerung.

### Was der Gate sich merkt

| Was | Wo | Wann es verschwindet |
|---|---|---|
| Ihr Ja auf eine Rückfrage, gebunden an den genauen Stand | `out/.aaos-ai-gate/answers` im Build-Baum | `m clean` löscht nur dieses Verzeichnis. |
| Welche Dateien das Modell schon gesehen hat und ob ein Stand kompiliert hat | `~/.cache/aaos-ai-gate` | Bleibt erhalten, auch bei `m clean` und nach dem Entfernen des Gates. `AAOS_AI_GATE_CACHE` wählt ein anderes Verzeichnis. |

Die gemerkten Antworten liegen unter `OUT_DIR` oder, wenn das nicht gesetzt ist, unter `out` im Baum. `OUT_DIR_COMMON_BASE` liest der Gate nicht. Ein Abbruch mit Strg-C oder ein Rückgabewert ab 128 wird nicht als Compile-Fehler gemerkt. Eine abgebrochene Modellanfrage ebenfalls nicht: der nächste `m` prüft erneut.

### Was an den Anbieter geht

Der Gate schickt den Diff mit 20 Zeilen Kontext, den obersten Stash in gekürzter Form (`git stash show -p`) und die Betreffzeilen der letzten Commits desselben Autors. Daraus leitet das Modell die Absicht ab.

- Claude mit API-Token spricht `api.anthropic.com` an, Antigravity mit Token die Google-Schnittstelle.
- Microsoft Copilot und jedes Abonnement laufen über die jeweilige Kommandozeile und deren bestehende Anmeldung.
- Eine eigene URL ersetzt den Anbieter. Dann geht alles an diese URL, und ein Token ist Pflicht.

Die eigenen Dateien des Gates schickt er nicht mit: das Skript, das Dialogskript, die Konfiguration und ein `m`, das nur den Hook enthält. Eine echte Änderung an `m` geht dagegen mit. Fehlt `jq`, prüft der Gate nichts, sagt das, und der Build startet trotzdem. Ein Baum ohne Änderung, den der Gate schon kennt, läuft nicht erneut über alle Repo-Projekte.

## 3. Der Installer

### Interaktiv

Im Verzeichnis `aaos-ai-gate`:

```bash
bash install-linux.sh
```

Der Installer fragt nacheinander:

1. **Quellbaum.** Das Verzeichnis mit `build/envsetup.sh`.
2. **Betriebsart.** Voreinstellung blockierend.
3. **Anbieter.** Claude, Microsoft Copilot oder Antigravity. Vorher sucht der Installer `claude`, `copilot` und `agy` und zeigt, was installiert ist. Die Eingabetaste übernimmt die erste gefundene Kommandozeile in der Reihenfolge Claude, Microsoft Copilot, Antigravity. Ist keine da, bleibt Claude vorausgewählt. Fehlt die Kommandozeile zum gewählten Abonnement, sagt der Installer das und installiert trotzdem.
4. **Anmeldung.** Abonnement, also die vorhandene Anmeldung der Kommandozeile, oder ein API-Token. Das Token wird verdeckt eingegeben und darf keinen Zeilenumbruch enthalten.
5. **Abweichende Verbindung.** Nur wer das ausdrücklich bejaht, kann danach ein Modell und eine Chat-Completions-URL eintragen. Beides darf leer bleiben. Eine eingetragene URL ersetzt den Anbieter und braucht ein API-Token, weil die Anmeldung der Kommandozeile dort nicht gilt.
6. **Umgebung selbst eintragen.** Voreinstellung nein. Bei ja entsteht keine Konfigurationsdatei, siehe Abschnitt 3.2.
7. **ccache.** Nur zusammen mit „Umgebung selbst eintragen“, siehe Abschnitt 3.3.

Vor dem Schreiben prüft der Installer `jq`. Fehlt es, ändert er den Baum nicht und nennt `sudo apt install jq`.

### Ohne Terminal

Alle Fragen lassen sich über Umgebungsvariablen vorab beantworten. Dann läuft der Installer ohne Rückfrage, etwa in einem Skript:

| Variable | Bedeutung |
|---|---|
| `AAOS_INSTALL_TREE` | Quellbaum. Pflicht. |
| `AAOS_INSTALL_MODE` | `blocking` oder `parallel`. |
| `AAOS_INSTALL_PROVIDER` | `claude`, `copilot` oder `antigravity`. Fehlt die Angabe, gilt die erste gefundene Kommandozeile. Ist keine da, bricht der Installer ab und schreibt nichts. |
| `AAOS_INSTALL_AUTH` | `subscription` oder `token`. |
| `AAOS_INSTALL_TOKEN` | Nur bei `token`. |
| `AAOS_INSTALL_ADVANCED` | `yes`, um `AAOS_INSTALL_URL` und `AAOS_INSTALL_MODEL` zu verwenden. Eine gesetzte URL ersetzt den Anbieter. |
| `AAOS_INSTALL_SELF_ENV` | `yes` für „Umgebung selbst eintragen“. |
| `AAOS_INSTALL_CCACHE` | `yes`, nur zusammen mit `AAOS_INSTALL_SELF_ENV=yes`. Dazu `AAOS_INSTALL_CCACHE_DIR`, `AAOS_INSTALL_CCACHE_SIZE` und `AAOS_INSTALL_CCACHE_EXEC`. Fehlt das Programm, installiert `AAOS_INSTALL_CCACHE_INSTALL=yes` es mit `sudo apt-get install -y ccache`. |
| `AAOS_INSTALL_ACTION` | `uninstall` für das Entfernen, siehe Abschnitt 3.4. |

### 3.1 Was der Installer in den Baum schreibt

Der Installer schreibt ausschließlich in den angegebenen Quellbaum. Ihre `~/.bashrc` lässt er unangetastet.

- `build/soong/bin/ai-patch-gate.sh`, das Gate-Skript, und `build/soong/bin/aaos-ai-gate-dialog.ps1`, das Hinweisfenster für Windows.
- Einen kurzen Block in `build/soong/bin/m`, direkt vor dem bestehenden Build-Aufruf. Der Block ruft den Gate über `_wrap_build` auf, damit die gewohnte Zeile „#### build completed successfully …“ samt Bauzeit erhalten bleibt. Lehnt der Gate einen Build ab, erscheint stattdessen „failed to build some targets“.
- Die Konfiguration `.aaos-ai-gate.conf` in der Wurzel des Baums, nur für Ihren Benutzer lesbar, sofern Sie die Umgebung nicht selbst eintragen. Sie enthält nur `AAOS_AI_GATE` und Namen, die mit `AAOS_AI_GATE_` beginnen. Andere Zeilen, etwa `PATH`, `LD_PRELOAD` oder ccache-Variablen, bleiben wirkungslos. Variablen aus Ihrer Shell gewinnen gegenüber der Datei.

Fehlt in `m` die erwartete Zeile `_wrap_build "$TOP/build/soong/soong_ui.bash"`, kopiert der Installer das Skript trotzdem und druckt den Block, den Sie von Hand einsetzen; er endet dann mit Exit 2. Findet er einen älteren Block aus einer früheren Version, bringt er ihn auf die aktuelle Form.

Damit `repo status` den Hook nicht als lokale Änderung meldet, trägt der Installer die beiden Skripte in die Git-Ausschlussliste von `build/soong` ein und markiert `bin/m` mit `skip-worktree`. Hat `build/soong` kein eigenes Git, entfällt beides. In einem Git-Checkout an der Baumwurzel kommt zusätzlich der Name der Konfiguration in `.git/info/exclude`, damit das Token nicht versehentlich committet wird. Ein `repo`-Baum versioniert die Wurzel ohnehin nicht. Rückgängig:

```bash
git -C build/soong update-index --no-skip-worktree bin/m
```

`m` ruft den Gate nur auf, wenn die Konfiguration existiert oder `AAOS_AI_GATE` beziehungsweise `AAOS_AI_GATE_MODE` in der Umgebung gesetzt ist. Ohne beides baut `m` wie vorher.

### 3.2 Umgebung selbst eintragen

Wer keine Datei mit Token im Quellbaum möchte, bejaht „Umgebung selbst eintragen“. Der Installer kopiert dann nur die Skripte und den Hook, entfernt eine vorhandene Konfiguration und druckt am Ende die `export`-Zeilen für `~/.bashrc`, zum Beispiel:

```bash
export AAOS_AI_GATE=on
export AAOS_AI_GATE_MODE=blocking
export AAOS_AI_GATE_PROVIDER=claude
export AAOS_AI_GATE_AUTH=subscription
```

Diese Zeilen tragen Sie selbst ein und laden die Shell neu. Ohne die Variablen baut `m` wie vorher.

### 3.3 ccache

ccache beschleunigt wiederholte C- und C++-Übersetzungen. AOSP liefert kein ccache mehr mit und erwartet drei Variablen in der Umgebung: `USE_CCACHE=1`, `CCACHE_EXEC` mit dem Pfad des Programms und `CCACHE_DIR` mit dem Cache-Verzeichnis. Alles Weitere, `compilercheck` und Sloppiness, setzt `build/make/core/ccache.mk` selbst.

Der Installer bietet ccache nur zusammen mit „Umgebung selbst eintragen“ an, und die Zeilen gehören ausdrücklich in `~/.bashrc`, nicht in die Gate-Datei. Der Grund: Die Gate-Datei liest nur der Hook in `build/soong/bin/m`. `mm`, `mmm`, `mma` und `mmma` sind eigene Skripte, und `make` aus `envsetup.sh` ruft `soong_ui.bash` direkt. Stünde `USE_CCACHE` nur in der Gate-Datei, sähen diese Wege ein anderes `CC_WRAPPER`, und bei jedem Wechsel erzeugten Soong und Kati den Build neu. Nach dem Entfernen des Gates wäre ccache zudem still verschwunden, und der nächste Build liefe kalt. Eine ccache-Zeile, die noch aus einer früheren Version in der Konfiguration steht, ignoriert der Gate mit einem Hinweis, und der Installer nimmt sie beim nächsten Schreiben heraus.

Bei ja zeigt der Installer:

```bash
export USE_CCACHE=1
export CCACHE_EXEC=$(command -v ccache)
export CCACHE_DIR=$HOME/.cache/ccache
```

und führt `ccache -M 100G` aus; ccache merkt sich die Größe selbst, `CCACHE_MAXSIZE` schreibt der Installer nicht. Verzeichnis und Größe können Sie ändern. `~`, `~/`, `$HOME` und `${HOME}` werden zum Home-Verzeichnis, bevor das Verzeichnis angelegt wird. Fehlt das Programm, fragt der Installer, ob er `sudo apt-get install -y ccache` ausführen soll. Ohne diese Zustimmung und ohne das Paket setzt er `USE_CCACHE` nicht. ccache wirkt nur auf C und C++.

### 3.4 Entfernen

```bash
bash install-linux.sh uninstall
```

Dasselbe erreicht `AAOS_INSTALL_ACTION=uninstall`. Entfernt werden der Hook in `m`, die beiden Skripte, die Konfiguration, die Datei `.aaos-ai-gate.dialog-off` und die Einträge in den Ausschlusslisten; `skip-worktree` an `m` wird aufgehoben. Der Diff-Cache in `~/.cache/aaos-ai-gate` und das Verzeichnis `out/` bleiben unangetastet.

Lässt sich der Hook in `m` nicht sauber entfernen, etwa weil er von Hand verändert wurde, bleiben Skripte und Konfiguration stehen, und der Installer endet mit Exit 3. So entsteht nie ein `m`, das ein gelöschtes Skript aufruft. Enthielt die Konfiguration noch ccache-Zeilen aus einer früheren Version, weist der Installer darauf hin, dass der nächste Build den Wrapper verliert, solange `~/.bashrc` ihn nicht setzt.

## 4. Installation von Hand

Wer den Installer nicht verwenden möchte, spielt den Patch `aaos-ai-patch-gate.diff` ein. Er enthält das Gate-Skript, das Dialogskript und den Hook in `m`, nicht aber die Installer. Von der Wurzel des Checkouts:

```bash
patch -p1 < /pfad/zu/aaos-ai-patch-gate.diff
chmod +x build/soong/bin/ai-patch-gate.sh
```

`git apply` setzt das Executable-Bit selbst. Danach setzen Sie die Variablen, sonst passiert nichts, hier für Claude mit Abonnement:

```bash
export AAOS_AI_GATE=on
export AAOS_AI_GATE_MODE=blocking
export AAOS_AI_GATE_PROVIDER=claude
export AAOS_AI_GATE_AUTH=subscription
```

Mit `AAOS_AI_GATE_AUTH=token` kommt `AAOS_AI_GATE_TOKEN` dazu. Copilot heißt `copilot`, Antigravity `antigravity` oder gleichbedeutend `agy`. Ein Modellname ist nur nötig, wenn Sie von der Voreinstellung des Anbieters abweichen möchten. Der Hook in `m` wird aktiv, sobald `AAOS_AI_GATE` oder `AAOS_AI_GATE_MODE` gesetzt ist.

## 5. Referenz

### Variablen

| Variable | Bedeutung |
|---|---|
| `AAOS_AI_GATE` | `on` schaltet den Gate ein. `stop` ist die einzige harte Weigerung, nur bei `likely_fail` und nur in der blockierenden Betriebsart. Die Datei des Installers setzt `on`. |
| `AAOS_AI_GATE_MODE` | `blocking` für den Vorabtest. `parallel`, `suggest` und `suggest-only` für nur Hinweis. Jeder andere Wert gilt als `blocking`. Ohne Setzen gilt `blocking`. |
| `AAOS_AI_GATE_PROVIDER` | `claude`, `copilot`, `antigravity` oder `agy` (gleichbedeutend mit `antigravity`). |
| `AAOS_AI_GATE_AUTH` | `subscription` für die vorhandene Anmeldung der Kommandozeile, `token` für ein API-Token. |
| `AAOS_AI_GATE_TOKEN` | Nur bei `token` oder zusammen mit einer eigenen URL. |
| `AAOS_AI_GATE_URL` | Nur auf ausdrücklichen Wunsch. Ersetzt den Anbieter, die Anmeldung der Kommandozeile gilt dort nicht, das Token ist Pflicht. |
| `AAOS_AI_GATE_MODEL` | Nur setzen, wenn Sie ein bestimmtes Modell wünschen. Sonst gilt die Voreinstellung des Anbieters, bei einer eigenen URL ohne Modellname `default`. |
| `AAOS_AI_GATE_BASE` | Git-Revision, gegen die der Diff gebildet wird. Voreinstellung `HEAD`, für einen Branch zum Beispiel `origin/main`. |
| `AAOS_AI_GATE_MAX_BYTES` | Obergrenze in Bytes für den neu geschickten Diff. Voreinstellung 80000. |
| `AAOS_AI_GATE_CACHE` | Anderes Verzeichnis statt `~/.cache/aaos-ai-gate`. `m clean` löscht es nicht. |
| `USE_CCACHE`, `CCACHE_EXEC`, `CCACHE_DIR` | Nur in der Shell, zum Beispiel `~/.bashrc`. Die Gate-Datei liest sie nicht. |

### Meldungen im Terminal

Alle Zeilen des Gates beginnen mit `ai-patch-gate:`.

| Meldung | Bedeutung |
|---|---|
| `keeping N already compiled file(s), sending M new file(s)` | Nur die M neuen Dateien gehen an das Modell. |
| `this tree already compiled` | Dieser Stand hat schon einmal kompiliert, es geht keine Anfrage hinaus. |
| `dieser Stand ist schon einmal fehlgeschlagen` | Der Build startet trotzdem, das Modell wird nicht erneut gefragt. |
| `schon bestätigt` | Ein früheres Ja gilt noch, der Build startet. |
| `Modell-Anfrage abgebrochen, der nächste m prüft erneut` | Der Build war schneller als das Modell. |
| `recorded build rc=…` | Das Ergebnis des durchgelaufenen Builds wurde gemerkt. |
| `build aborted` | Der Abbruch wurde nicht als Ergebnis gemerkt. |
| `jq fehlt` | Es wird nichts geprüft, der Build läuft normal. |
| `Zeitlimit (55 s) beim Aufruf von …` | Die Kommandozeile des Anbieters hat nicht rechtzeitig geantwortet. Der Build läuft normal. |
| `repo forall ist fehlgeschlagen` | Der Stand konnte nicht vollständig erfasst werden, dieser `m` läuft ohne Prüfung. |

### IDE

In VS Code ist der Gate die Shell-Aufgabe, die `m` aufruft. Der Stop-Knopf bricht den Build ab. Eine Erweiterung ist nicht nötig. Android Studio baut die App; das Systemimage und damit der Gate laufen nur, wenn `m` in seinem Terminal aufgerufen wird.

```json
{
  "label": "AAOS m",
  "type": "shell",
  "command": "source build/envsetup.sh && lunch sdk_car_x86_64-userdebug && m",
  "options": { "cwd": "${workspaceFolder}" },
  "problemMatcher": []
}
```

## 6. Wenn etwas nicht klappt

| Beobachtung | Ursache und Abhilfe |
|---|---|
| Der Installer meldet, dass `jq` fehlt. | `sudo apt install jq` ausführen und den Installer erneut starten. Der Baum wurde nicht verändert. |
| Der Installer druckt den Hook-Block zum Einsetzen und endet mit Exit 2. | Ihr `m` enthält die erwartete Zeile `_wrap_build "$TOP/build/soong/soong_ui.bash"` nicht. Setzen Sie den gezeigten Block von Hand davor. |
| `m` baut ohne jede Gate-Meldung. | Weder existiert `.aaos-ai-gate.conf` im Baum, noch ist `AAOS_AI_GATE` oder `AAOS_AI_GATE_MODE` gesetzt. Prüfen Sie nach dem Selbsteintragen, ob die Shell neu geladen wurde. |
| Der Gate meldet, dass die Anmeldung oder der Aufruf der Kommandozeile fehlgeschlagen ist. | Melden Sie die Kommandozeile an, oder wechseln Sie auf ein API-Token. Der Build läuft in beiden Fällen weiter. |
| `repo status` zeigt `build/soong/bin/m` als geändert. | `skip-worktree` wurde aufgehoben oder konnte nicht gesetzt werden. Setzen Sie es mit `git -C build/soong update-index --skip-worktree bin/m`. |
| Das Entfernen endet mit Exit 3. | Der Hook in `m` ließ sich nicht sauber erkennen. Entfernen Sie den Block in `build/soong/bin/m` von Hand und starten Sie das Entfernen erneut. |
