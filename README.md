# AI-Patch-Gate für AAOS

Eine kurze KI-Vorprüfung vor jedem `m`-Build eines AAOS/AOSP-Baums. Der Gate hängt an `build/soong/bin/m`, zeigt dem Modell einmal pro Build den aktuellen Diff und meldet einen erwarteten Compile-Bruch, einen konkreten Laufzeitfehler oder eine verfehlte Absicht. Der Compiler bleibt die eigentliche Prüfung; der Gate sperrt nie dauerhaft.

## Handbücher

- [AI-Patch-Gate unter Linux](aaos-ai-patch-gate-linux.md)
- [AI-Patch-Gate unter Windows mit WSL](aaos-ai-patch-gate-windows.md), auch als [PDF mit Skizzen](aaos-ai-patch-gate-windows.pdf)

Beide beginnen mit einem Überblick und einem Schnellstart und gehen dann ins Detail.

## Inhalt

| Datei | Zweck |
|---|---|
| `ai-patch-gate.sh` | Der Gate selbst. Wird nach `build/soong/bin/` kopiert. |
| `aaos-ai-gate-dialog.ps1` | Hinweisfenster für Windows im parallelen Modus. |
| `install-linux.sh` | Installer für Linux, interaktiv oder über `AAOS_INSTALL_*`-Variablen. |
| `install-windows.ps1` | Grafischer Installer für Windows PowerShell 5.1. |
| `aaos-ai-patch-gate.diff` | Patch für die Installation von Hand. Wird aus den Skripten erzeugt. |
| `tests/` | Testsuiten für Gate, Linux-Installer und die fensterlose Logik der Windows-Skripte. |

## Tests

```bash
bash tests/test_install_linux.sh
TMPDIR=$(mktemp -d) bash tests/test_gate.sh
pwsh -NoProfile -File tests/test_windows_logic.ps1   # oder powershell unter Windows
```

Die Suiten laufen unter Linux und macOS (bash 3.2 reicht). Der Workflow in `.github/workflows/check.yml` führt sie auf Ubuntu- und Windows-Runnern aus, dort auch mit Windows PowerShell 5.1.

## Anbieter

Claude, Microsoft Copilot und Antigravity, jeweils über die angemeldete Kommandozeile oder ein API-Token. Eine eigene Chat-Completions-URL ist möglich. Was genau an den Anbieter geht, steht in den Handbüchern unter „Was an den Anbieter geht“.
