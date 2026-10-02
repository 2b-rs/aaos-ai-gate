# AI-Patch-Gate auf Linux

Der Gate hängt an `m` (`build/soong/bin/m`) und schaut sich die aktuellen Änderungen einmal pro Build an. Der Compiler bleibt die Prüfung. Das Modell kann einen klaren Compile-Bruch, einen konkreten Laufzeitfehler im Diff und eine verfehlte Absicht benennen. Es kennt keine absolute Wahrheit. Ein Urteil, eine abgelehnte Frage und ein früher fehlgeschlagener Stand sperren den nächsten `m` nicht.

Zwei Betriebsarten:

- **blockierend, Vorabtest** ist die Voreinstellung. Frage und Urteil stehen, bevor Ninja startet. `So beabsichtigt? [j/N]` wartet auf eine Antwort. `j`, `ja`, `y` oder `yes` lässt den Build zu, auch wenn das Modell `likely_fail` sagt, und dieses Ja wird gemerkt. Die Eingabetaste, `n` oder alles andere stoppt nur diesen Lauf und wird nicht gemerkt. Der nächste `m` fragt wieder. Sieht das Modell einen Compile-Bruch und fragt nicht selbst, lautet die Frage `Sieht nicht kompilierbar aus. Trotzdem bauen?`. Ein Stand, der schon einmal fehlgeschlagen ist, startet trotzdem. Die Zeile sagt das. Das Modell wird für genau diesen Stand nicht noch einmal gefragt.
- **parallel, nur Hinweis** startet den Build zusammen mit der Anfrage und bricht ihn von selbst nicht ab. Hinweise können im Ninja-Log nach oben rutschen. Nach dem Build stehen sie noch einmal im Terminal zwischen `----- ai-patch-gate -----`. Wird der Build fertig, während die Anfrage noch läuft, bricht der Gate die Anfrage ab. Der nächste `m` prüft erneut. Es gibt keine 24-Stunden-Pause. Strg-C und der Stop-Button der IDE beenden den Build. Unter Windows öffnet derselbe Modus bei einem konkreten Verdacht zusätzlich ein Fenster mit Rückfrage an das Modell. Auf Linux bleibt es beim Terminal.

Ohne Terminal wird die Frage gedruckt und der Build startet. `AAOS_AI_GATE=stop` ist die einzige harte Weigerung, und nur bei `likely_fail`: dann startet der Build nicht, und es wird nicht gefragt. Die vom Installer geschriebene Datei setzt `AAOS_AI_GATE=on`.

Die Absicht kommt aus den letzten Commits desselben Autors, dem Stash und dem aktuellen Diff. Der Diff geht mit 20 Zeilen Kontext. Ein Ja liegt in `out/.aaos-ai-gate/answers`. `m clean` löscht nur dieses Verzeichnis im Build-Baum. Der Diff-Cache unter `~/.cache/aaos-ai-gate` bleibt, einschließlich der gemerkten Compile-Ergebnisse. Ein Abbruch, Strg-C oder ein Rückgabewert ab 128 wird nicht als Compile-Fehler gemerkt.

Diff, der oberste Stash (`git stash show -p`, gekürzt) und die Betreffzeilen der letzten Commits gehen an den Anbieter. Claude mit Token an api.anthropic.com, Antigravity mit Token an Google, Copilot und jedes Abonnement an die jeweilige Kommandozeile, eine eigene URL an diese URL. Die eigenen Gate-Dateien schickt er nicht mit: das Skript, der Dialog, die Konfiguration und ein `m`, das nur den Hook enthält. Eine echte Änderung in `m` geht mit.

Fehlt `jq`, prüft der Gate nichts und sagt das. Der Build startet trotzdem. Ein Baum ohne Diff, den er schon kennt, läuft nicht erneut über alle Repo-Projekte.

## Installer

Im Verzeichnis `aaos-ai-gate` neben diesem Text:

```bash
bash install-linux.sh
```

Er fragt nach dem Quellbaum, dem Modus (Voreinstellung blockierend), dem Anbieter und der Anmeldung. Anbieter sind Claude, Microsoft Copilot und Antigravity. Vor der Frage sucht er `claude`, `copilot` und `agy`. Die Liste sagt, was installiert ist. Die Eingabetaste übernimmt die erste gefundene Kommandozeile, in der Reihenfolge Claude, Microsoft Copilot, Antigravity. Ist keine da, bleibt Claude vorausgewählt. Die Anmeldung ist entweder das Abonnement, also die schon vorhandene Anmeldung der jeweiligen Kommandozeile, oder ein API-Token. Eine Endpoint-URL fragt er nicht. Wer ausdrücklich eine abweichende Verbindung angibt, kann danach ein Modell und eine URL eintragen. Beides darf leer bleiben. Eine eingetragene URL braucht ein API-Token, weil dort die Anmeldung der Kommandozeile nicht gilt. Fehlt die Kommandozeile zum gewählten Abonnement, sagt er das und installiert trotzdem. Microsoft Copilot braucht `copilot` auch mit API-Token. Claude und Antigravity kommen mit einem Token ohne ihre Kommandozeile aus.

Vor dem Schreiben prüft er `jq`. Fehlt es, ändert er den Baum nicht. Zum Beispiel `sudo apt install jq`. `curl` braucht der Token-Weg, `git` liegt im Checkout.

Ohne Terminal: `AAOS_INSTALL_TREE`, `AAOS_INSTALL_MODE` (`blocking` oder `parallel`), `AAOS_INSTALL_AUTH` (`subscription` oder `token`), `AAOS_INSTALL_TOKEN` nur bei `token`, `AAOS_INSTALL_SELF_ENV` (`yes`/`no`), `AAOS_INSTALL_ADVANCED` (`yes`/`nein`). `AAOS_INSTALL_CCACHE` gilt nur bei `AAOS_INSTALL_SELF_ENV=yes`. Dazu `AAOS_INSTALL_CCACHE_DIR`, `AAOS_INSTALL_CCACHE_SIZE`, `AAOS_INSTALL_CCACHE_EXEC`. Fehlt das Binary, installiert `AAOS_INSTALL_CCACHE_INSTALL=yes` es mit `sudo apt-get install -y ccache`. `AAOS_INSTALL_PROVIDER` (`claude`, `copilot` oder `antigravity`) kann wegbleiben, dann gilt die erste gefundene Kommandozeile. Fehlt jede, bricht er ab und schreibt nichts. `AAOS_INSTALL_URL` und `AAOS_INSTALL_MODEL` nur setzen, wenn man sie wirklich will. Eine gesetzte URL ersetzt den Anbieter.

Der Installer schreibt nur in diesen Baum: `build/soong/bin/ai-patch-gate.sh`, `aaos-ai-gate-dialog.ps1` und die wenigen Zeilen in `build/soong/bin/m`. Er ändert `~/.bashrc` nicht. Fehlt in `m` die Zeile `_wrap_build "$TOP/build/soong/soong_ui.bash"`, kopiert er das Skript trotzdem und druckt den Block zum Einsetzen. Der Aufruf läuft über `_wrap_build`, damit die Zeile „#### build completed successfully …“ erhalten bleibt. Ein abgelehnter Gate (Exit 2) erscheint als „failed to build some targets“. Ohne eigenes Git in `build/soong` setzt der Installer keine Ausschlussliste und kein skip-worktree.

Solange die Umgebung nicht selbst eingetragen wird, entsteht `$TOP/.aaos-ai-gate.conf`, nur für den eigenen Benutzer lesbar. `m` ruft den Gate auf, wenn diese Datei existiert oder `AAOS_AI_GATE` gesetzt ist. Variablen aus der Shell gewinnen gegenüber der Datei. Die Datei setzt nur `AAOS_AI_GATE` und Namen mit `AAOS_AI_GATE_`. `PATH`, `LD_PRELOAD` und ccache-Zeilen darin bleiben wirkungslos. In einem Git-Checkout am Baumwurzelverzeichnis kommt der Dateiname in `.git/info/exclude`, damit der Token nicht mit committed wird. Ein AOSP-`repo`-Baum versioniert die Wurzel ohnehin nicht.

Die Gate-Skripte trägt er in die Ausschlussliste von `build/soong` ein und markiert `build/soong/bin/m` mit `skip-worktree`, damit `repo status` den Hook nicht als lokale Änderung zeigt. Rückgängig: `git -C build/soong update-index --no-skip-worktree bin/m`.

Wer die Umgebung selbst einträgt, bekommt am Ende die `export`-Zeilen. Es wird keine Konfigurationsdatei geschrieben. Eine schon vorhandene wird entfernt. Ohne die Variablen baut `m` wie vorher.

Entfernen, ohne den Diff-Cache und ohne `out/` anzufassen:

```bash
bash install-linux.sh uninstall
```

Dasselbe mit `AAOS_INSTALL_ACTION=uninstall`. Weg sind der Hook in `m`, die beiden Skripte, die Konfiguration, `.aaos-ai-gate.dialog-off` und die Ausschlusslisten. `skip-worktree` an `m` wird aufgehoben. Ist der Hook in `m` unvollständig, bleiben die Skripte und die Konfiguration, und der Installer endet mit Exit 3. Enthielt die Konfiguration ccache, sagt er das: der nächste Build sieht den Wrapper nicht mehr, solange `~/.bashrc` ihn nicht setzt. Dann ändern sich `CC_WRAPPER`, Soong und Kati erzeugen neu, und der Compile läuft kalt.

## ccache

Optional, und nur zusammen mit „Umgebung selbst eintragen“. Die Zeilen gehören in `~/.bashrc`, nicht in `.aaos-ai-gate.conf`. Die Konfiguration liest nur der Hook in `build/soong/bin/m`. `mm`, `mmm`, `mma` und `mmma` sind eigene Skripte, `make` aus `envsetup.sh` ruft `soong_ui.bash` direkt. Diese Wege sähen `USE_CCACHE` aus der Gate-Datei nicht. Ein Wechsel ändert `CC_WRAPPER` in `soong.variables`, und Soong und Kati erzeugen neu. Nach dem Entfernen des Gates wäre ein nur dort gesetztes ccache still weg, der nächste Build erzeugt neu und kompiliert kalt.

Bei Ja, und nur wenn `ccache` vorhanden ist, zeigt der Installer:

```bash
export USE_CCACHE=1
export CCACHE_EXEC=$(command -v ccache)
export CCACHE_DIR=$HOME/.cache/ccache
```

und führt `ccache -M 100G` aus. Die Größe merkt sich ccache dabei selbst. `CCACHE_MAXSIZE` schreibt der Installer nicht. Verzeichnis und Größe kann man ändern. `~`, `~/`, `$HOME` und `${HOME}` werden zum Home-Verzeichnis, bevor das Verzeichnis angelegt wird. Fehlt das Binary, fragt er, ob er `sudo apt-get install -y ccache` ausführen soll. Ohne diese Zustimmung und ohne das Paket setzt er `USE_CCACHE` nicht. AOSP liefert kein ccache mehr mit. `build/make/core/ccache.mk` setzt `compilercheck=content` und die Sloppiness selbst. ccache trifft nur C und C++. Eine schon in der Konfiguration stehende ccache-Zeile ignoriert der Gate und sagt das. Der Installer nimmt sie beim nächsten Schreiben heraus.

## Von Hand

`aaos-ai-patch-gate.diff` liegt neben diesem Text. Die Installer sind nicht darin. Von der Wurzel des Checkouts:

```bash
patch -p1 < /pfad/zu/aaos-ai-patch-gate.diff
chmod +x build/soong/bin/ai-patch-gate.sh
```

`git apply` setzt das Executable-Bit selbst. Danach die Variablen setzen, sonst passiert nichts:

```bash
export AAOS_AI_GATE=on
export AAOS_AI_GATE_MODE=blocking
export AAOS_AI_GATE_PROVIDER=claude
export AAOS_AI_GATE_AUTH=subscription
```

`AAOS_AI_GATE_AUTH=token` braucht zusätzlich `AAOS_AI_GATE_TOKEN`. Copilot heißt `copilot`, Antigravity `antigravity`. Ein Modellname ist nur nötig, wenn man von der Voreinstellung des Anbieters weg will.

| Variable | Bedeutung |
|---|---|
| `AAOS_AI_GATE` | `on` schaltet den Gate ein. `stop` ist die einzige harte Weigerung, und nur bei `likely_fail`. Die Datei des Installers setzt `on`. |
| `AAOS_AI_GATE_MODE` | `blocking` für den Vorabtest, `parallel` für nur Hinweis. Ohne Setzen gilt `blocking`. |
| `AAOS_AI_GATE_PROVIDER` | `claude`, `copilot` oder `antigravity`. |
| `AAOS_AI_GATE_AUTH` | `subscription` für die vorhandene Anmeldung, `token` für ein API-Token. |
| `AAOS_AI_GATE_TOKEN` | Nur bei `token`, oder wenn eine eigene URL gesetzt ist. |
| `AAOS_AI_GATE_URL` | Nur auf ausdrücklichen Wunsch. Ersetzt dann den Anbieter. Die Anmeldung der Kommandozeile gilt dort nicht, das Token ist Pflicht. |
| `AAOS_AI_GATE_MODEL` | Nur setzen, wenn ein bestimmtes Modell gewünscht ist. Sonst nimmt der Anbieter seine Voreinstellung. Bei einer eigenen URL ohne Modellname gilt `default`. |
| `AAOS_AI_GATE_BASE` | Git-Revision für den Diff. Voreinstellung `HEAD`. Für einen Branch z. B. `origin/main`. |
| `AAOS_AI_GATE_MAX_BYTES` | Obergrenze des neu geschickten Diffs. Voreinstellung 80000. |
| `AAOS_AI_GATE_CACHE` | Anderes Verzeichnis statt `~/.cache/aaos-ai-gate`. `m clean` löscht es nicht. |
| `USE_CCACHE`, `CCACHE_EXEC`, `CCACHE_DIR` | Nur in der Shell, zum Beispiel `~/.bashrc`. Die Gate-Datei liest sie nicht. Sonst gilt ccache nur für `m`. |

Aufruf wie gewohnt:

```bash
source build/envsetup.sh
lunch sdk_car_x86_64-userdebug
m
```

Zeilen beginnen mit `ai-patch-gate:`. `keeping N already compiled file(s), sending M new file(s)` heißt, dass nur neue Dateien ans Modell gehen. `this tree already compiled` heißt, dass kein Request mehr rausgeht. `dieser Stand ist schon einmal fehlgeschlagen` heißt, der Build startet trotzdem. `recorded build rc=` steht nach einem durchgelaufenen Build. `build aborted` heißt, der Abbruch wurde nicht gemerkt. `jq fehlt` heißt, es wird nichts geprüft. `Modell-Anfrage abgebrochen` heißt, der nächste `m` prüft erneut. `schon bestätigt` heißt, ein früheres Ja gilt noch und der Build startet.

In VS Code ist der Gate die Shell-Task, die `m` aufruft. Der Stop-Button bricht den Build ab. Eine Erweiterung braucht es dafür nicht. Android Studio baut die App, das Systemimage nur, wenn `m` in seinem Terminal läuft.

```json
{
  "label": "AAOS m",
  "type": "shell",
  "command": "source build/envsetup.sh && lunch sdk_car_x86_64-userdebug && m",
  "options": { "cwd": "${workspaceFolder}" },
  "problemMatcher": []
}
```
