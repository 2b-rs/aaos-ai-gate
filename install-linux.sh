#!/usr/bin/env bash
# Installiert den AI-Patch-Gate nur in einen AAOS/AOSP-Quellbaum.
# Nichts ausserhalb des Baums. ccache -M und apt-get nur, wenn die
# Umgebung selbst eingetragen wird und ccache ausdruecklich gewaehlt ist.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
payload=$here/ai-patch-gate.sh

die() {
  printf 'Installer: %s\n' "$1" >&2
  exit 1
}

need_tty() {
  ( : <>/dev/tty ) >/dev/null 2>&1
}

ask() {
  local __var=$1 __text=$2 __default=${3-}
  local __cur __ans
  __cur=${!__var:-}
  if [[ -n "$__cur" ]]; then
    return 0
  fi
  if ! need_tty; then
    if [[ -n "$__default" ]]; then
      printf -v "$__var" '%s' "$__default"
      return 0
    fi
    die "$__text fehlt. Zum Beispiel $__var setzen."
  fi
  if [[ -n "$__default" ]]; then
    printf '%s [%s]: ' "$__text" "$__default" >/dev/tty
  else
    printf '%s: ' "$__text" >/dev/tty
  fi
  IFS= read -r __ans </dev/tty || __ans=
  if [[ -z "$__ans" ]]; then
    __ans=$__default
  fi
  printf -v "$__var" '%s' "$__ans"
}

ask_secret() {
  local __var=$1 __text=$2
  local __cur __ans
  __cur=${!__var:-}
  if [[ -n "$__cur" ]]; then
    return 0
  fi
  if ! need_tty; then
    die "$__text fehlt. Zum Beispiel $__var setzen."
  fi
  printf '%s: ' "$__text" >/dev/tty
  IFS= read -r -s __ans </dev/tty || __ans=
  printf '\n' >/dev/tty
  printf -v "$__var" '%s' "$__ans"
}

is_yes() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    j|ja|y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

provider_label() {
  case "$1" in
    claude) printf 'Claude' ;;
    copilot) printf 'Microsoft Copilot' ;;
    antigravity) printf 'Antigravity' ;;
    *) printf '%s' "$1" ;;
  esac
}

auth_label() {
  case "$1" in
    token) printf 'API-Token' ;;
    *) printf 'Abonnement' ;;
  esac
}

cli_bin() {
  case "$1" in
    claude) printf 'claude' ;;
    copilot) printf 'copilot' ;;
    antigravity) printf 'agy' ;;
    *) printf '%s' "$1" ;;
  esac
}

cli_on_path() {
  command -v "$1" >/dev/null 2>&1
}

preferred_provider() {
  if cli_on_path claude; then printf 'claude'; return; fi
  if cli_on_path copilot; then printf 'copilot'; return; fi
  if cli_on_path agy; then printf 'antigravity'; return; fi
  printf ''
}

cli_state() {
  if cli_on_path "$1"; then
    printf 'installiert'
  else
    printf 'nicht gefunden'
  fi
}

cli_gap_note() {
  local bin
  [[ -n "${AAOS_INSTALL_URL:-}" ]] && return 0
  [[ -n "${provider:-}" ]] || return 0
  bin=$(cli_bin "$provider")
  cli_on_path "$bin" && return 0
  if [[ "$provider" == copilot ]]; then
    printf '%s\n' "copilot ist nicht aufrufbar. Microsoft Copilot laeuft nur ueber diese Kommandozeile, auch mit API-Token."
  elif [[ "$auth" == subscription ]]; then
    printf '%s\n' "$bin ist nicht aufrufbar. Das Abonnement braucht diese Kommandozeile. Ein API-Token fuer Claude oder Antigravity kommt ohne sie aus."
  fi
}

sq() {
  python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$1"
}

expand_tilde() {
  local d=$1
  case "$d" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${d:2}" ;;
    '$HOME') printf '%s' "$HOME" ;;
    '$HOME/'*) printf '%s' "$HOME${d:5}" ;;
    '${HOME}') printf '%s' "$HOME" ;;
    '${HOME}/'*) printf '%s' "$HOME${d:7}" ;;
    *) printf '%s' "$d" ;;
  esac
}

try_install_ccache() {
  local ans
  if [[ -x "${AAOS_INSTALL_CCACHE_EXEC:-}" ]]; then
    return 0
  fi
  if command -v ccache >/dev/null 2>&1; then
    AAOS_INSTALL_CCACHE_EXEC=$(command -v ccache)
    return 0
  fi
  if [[ -z "${AAOS_INSTALL_CCACHE_INSTALL:-}" ]] && need_tty; then
    printf '%s' "ccache fehlt. Mit sudo apt-get install -y ccache nachinstallieren? [j/N] " >/dev/tty
    IFS= read -r ans </dev/tty || ans=
    if is_yes "$ans"; then
      AAOS_INSTALL_CCACHE_INSTALL=yes
    else
      AAOS_INSTALL_CCACHE_INSTALL=nein
    fi
  fi
  if ! is_yes "${AAOS_INSTALL_CCACHE_INSTALL:-}"; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "apt-get fehlt. ccache mit dem Paket der Distribution installieren."
    return 0
  fi
  if ! sudo apt-get install -y ccache; then
    printf '%s\n' "apt-get install ccache ist fehlgeschlagen."
    return 0
  fi
  if command -v ccache >/dev/null 2>&1; then
    AAOS_INSTALL_CCACHE_EXEC=$(command -v ccache)
  fi
}

hide_gate_from_git() {
  local tree=$1 soong gitdir name
  soong=$tree/build/soong
  if [[ -e "$soong/.git" ]]; then
    gitdir=$(git -C "$soong" rev-parse --git-dir 2>/dev/null || true)
    if [[ -n "$gitdir" ]]; then
      case "$gitdir" in
        /*) ;;
        *) gitdir=$soong/$gitdir ;;
      esac
      mkdir -p "$gitdir/info"
      touch "$gitdir/info/exclude"
      for name in bin/ai-patch-gate.sh bin/aaos-ai-gate-dialog.ps1; do
        grep -qxF "$name" "$gitdir/info/exclude" || printf '%s\n' "$name" >> "$gitdir/info/exclude"
      done
      if git -C "$soong" ls-files --error-unmatch -- bin/m >/dev/null 2>&1; then
        git -C "$soong" update-index --skip-worktree -- bin/m
        printf '%s\n' "build/soong/bin/m ist mit skip-worktree markiert. repo status zeigt den Hook nicht."
        printf '%s\n' "Rueckgaengig: git -C build/soong update-index --no-skip-worktree bin/m"
      fi
    fi
  fi
  if [[ -d "$tree/.git" ]]; then
    mkdir -p "$tree/.git/info"
    touch "$tree/.git/info/exclude"
    for name in .aaos-ai-gate.conf .aaos-ai-gate.dialog-off; do
      grep -qxF "$name" "$tree/.git/info/exclude" || printf '%s\n' "$name" >> "$tree/.git/info/exclude"
    done
  fi
}

strip_exclude_line() {
  local file=$1 name=$2 tmp
  [[ -f "$file" ]] || return 0
  tmp=$(mktemp)
  grep -vxF "$name" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

do_uninstall() {
  local tree soong gitdir ccache_note
  ask AAOS_INSTALL_TREE "Quellbaum (Verzeichnis mit build/envsetup.sh)"
  tree=$(cd "$AAOS_INSTALL_TREE" 2>/dev/null && pwd) || die "Quellbaum nicht gefunden: $AAOS_INSTALL_TREE"
  ccache_note=no
  if [[ -f "$tree/.aaos-ai-gate.conf" ]] && grep -Eq '^(USE_CCACHE|CCACHE_EXEC|CCACHE_DIR|CCACHE_MAXSIZE)=' "$tree/.aaos-ai-gate.conf"; then
    ccache_note=yes
  fi
  [[ -f "$tree/build/soong/bin/m" ]] || die "Das ist kein AAOS/AOSP-Baum: build/soong/bin/m fehlt."
  soong=$tree/build/soong
  python3 - "$soong/bin/m" << 'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
start = text.find('if [[ -f "$TOP/.aaos-ai-gate.conf"')
if start < 0:
    print("Kein Gate-Hook in m.")
    raise SystemExit(0)
line_start = text.rfind("\n", 0, start)
line_start = 0 if line_start < 0 else line_start + 1
fi = text.find("\nfi\n", start)
if fi < 0 or "ai-patch-gate.sh" not in text[line_start:fi]:
    print("Hook unvollstaendig, m bleibt unveraendert.")
    raise SystemExit(0)
end = fi + len("\nfi\n")
if text[end:end + 1] == "\n":
    end += 1
path.write_text(text[:line_start] + text[end:])
print("Hook aus m entfernt.")
PY
  rm -f "$soong/bin/ai-patch-gate.sh" "$soong/bin/aaos-ai-gate-dialog.ps1"
  rm -f "$tree/.aaos-ai-gate.conf" "$tree/.aaos-ai-gate.dialog-off"
  if [[ -e "$soong/.git" ]]; then
    gitdir=$(git -C "$soong" rev-parse --git-dir 2>/dev/null || true)
    if [[ -n "$gitdir" ]]; then
      case "$gitdir" in
        /*) ;;
        *) gitdir=$soong/$gitdir ;;
      esac
      strip_exclude_line "$gitdir/info/exclude" "bin/ai-patch-gate.sh"
      strip_exclude_line "$gitdir/info/exclude" "bin/aaos-ai-gate-dialog.ps1"
      if git -C "$soong" ls-files -v -- bin/m 2>/dev/null | grep -q '^S'; then
        git -C "$soong" update-index --no-skip-worktree -- bin/m || true
        printf '%s\n' "skip-worktree an build/soong/bin/m aufgehoben."
      fi
    fi
  fi
  if [[ -d "$tree/.git" ]]; then
    strip_exclude_line "$tree/.git/info/exclude" ".aaos-ai-gate.conf"
    strip_exclude_line "$tree/.git/info/exclude" ".aaos-ai-gate.dialog-off"
  fi
  printf '%s\n' "Gate aus $tree entfernt. Skripte, Hook und Konfiguration sind weg."
  printf '%s\n' "Der Diff-Cache unter ~/.cache/aaos-ai-gate und out/ bleiben."
  if [[ "$ccache_note" == yes ]]; then
    printf '%s\n' "Die Konfiguration enthielt ccache. Der naechste Build sieht den Wrapper nicht mehr, wenn ~/.bashrc ihn nicht setzt. Dann aendert sich CC_WRAPPER, Soong und Kati erzeugen neu, und der Compile laeuft kalt."
  fi
  exit 0
}

[[ -f "$payload" ]] || die "Nutzlast fehlt: $payload"
command -v python3 >/dev/null 2>&1 || die "python3 fehlt. Damit wird nur die eine Zeile in m eingefuegt."

AAOS_INSTALL_TREE=${AAOS_INSTALL_TREE:-}
AAOS_INSTALL_MODE=${AAOS_INSTALL_MODE:-}
AAOS_INSTALL_PROVIDER=${AAOS_INSTALL_PROVIDER:-}
AAOS_INSTALL_AUTH=${AAOS_INSTALL_AUTH:-}
AAOS_INSTALL_URL=${AAOS_INSTALL_URL:-}
AAOS_INSTALL_TOKEN=${AAOS_INSTALL_TOKEN:-}
AAOS_INSTALL_MODEL=${AAOS_INSTALL_MODEL:-}
AAOS_INSTALL_ADVANCED=${AAOS_INSTALL_ADVANCED:-}
AAOS_INSTALL_CCACHE=${AAOS_INSTALL_CCACHE:-}
AAOS_INSTALL_CCACHE_DIR=${AAOS_INSTALL_CCACHE_DIR:-}
AAOS_INSTALL_CCACHE_SIZE=${AAOS_INSTALL_CCACHE_SIZE:-}
AAOS_INSTALL_CCACHE_EXEC=${AAOS_INSTALL_CCACHE_EXEC:-}
AAOS_INSTALL_SELF_ENV=${AAOS_INSTALL_SELF_ENV:-}

action=${1:-${AAOS_INSTALL_ACTION:-}}
if [[ "$action" == "uninstall" ]]; then
  do_uninstall
fi
command -v jq >/dev/null 2>&1 || die "jq fehlt. Zum Beispiel: sudo apt install jq. Der Baum wurde nicht veraendert."

ask AAOS_INSTALL_TREE "Quellbaum (Verzeichnis mit build/envsetup.sh)"
tree=$(cd "$AAOS_INSTALL_TREE" 2>/dev/null && pwd) || die "Quellbaum nicht gefunden: $AAOS_INSTALL_TREE"

[[ -f "$tree/build/soong/bin/m" ]] || die "Das ist kein AAOS/AOSP-Baum: build/soong/bin/m fehlt."
[[ -f "$tree/build/soong/soong_ui.bash" ]] || die "Das ist kein AAOS/AOSP-Baum: build/soong/soong_ui.bash fehlt."
[[ -f "$tree/build/envsetup.sh" ]] || die "Das ist kein AAOS/AOSP-Baum: build/envsetup.sh fehlt."

if [[ -z "$AAOS_INSTALL_MODE" ]]; then
  if need_tty; then
    printf '%s\n' "Betriebsmodus:" >/dev/tty
    printf '%s\n' "  1) blockierend, Vorabtest [Voreinstellung]" >/dev/tty
    printf '%s\n' "  2) parallel, nur Hinweis" >/dev/tty
    printf '%s' "Wahl [1]: " >/dev/tty
    IFS= read -r AAOS_INSTALL_MODE </dev/tty || AAOS_INSTALL_MODE=
  fi
fi
case "$(printf '%s' "$AAOS_INSTALL_MODE" | tr '[:upper:]' '[:lower:]')" in
  ''|1|blocking|blockierend|vorabtest) mode=blocking ;;
  2|parallel|suggest|suggest-only|hinweis) mode=parallel ;;
  *) die "Unbekannter Modus: $AAOS_INSTALL_MODE" ;;
esac

provider=
auth=subscription
provider_detected=no
if [[ -z "$AAOS_INSTALL_URL" ]]; then
  if [[ -z "$AAOS_INSTALL_PROVIDER" ]]; then
    detected=$(preferred_provider)
    default_choice=1
    default_provider=claude
    case "$detected" in
      copilot) default_choice=2; default_provider=copilot ;;
      antigravity) default_choice=3; default_provider=antigravity ;;
    esac
    if need_tty; then
      if [[ -z "$detected" ]]; then
        printf '%s\n' "Keine Kommandozeile gefunden: claude, copilot, agy." >/dev/tty
        printf '%s\n' "Ein Abonnement braucht die passende Kommandozeile. Ein API-Token fuer Claude oder Antigravity kommt ohne sie aus. Microsoft Copilot braucht copilot auch mit Token." >/dev/tty
      fi
      printf '%s\n' "Anbieter:" >/dev/tty
      printf '  1) Claude, %s' "$(cli_state claude)" >/dev/tty
      [[ "$default_choice" == 1 ]] && printf ' [Voreinstellung]' >/dev/tty
      printf '\n' >/dev/tty
      printf '  2) Microsoft Copilot, %s' "$(cli_state copilot)" >/dev/tty
      [[ "$default_choice" == 2 ]] && printf ' [Voreinstellung]' >/dev/tty
      printf '\n' >/dev/tty
      printf '  3) Antigravity, %s' "$(cli_state agy)" >/dev/tty
      [[ "$default_choice" == 3 ]] && printf ' [Voreinstellung]' >/dev/tty
      printf '\n' >/dev/tty
      printf 'Wahl [%s]: ' "$default_choice" >/dev/tty
      IFS= read -r AAOS_INSTALL_PROVIDER </dev/tty || AAOS_INSTALL_PROVIDER=
      if [[ -z "$AAOS_INSTALL_PROVIDER" ]]; then
        AAOS_INSTALL_PROVIDER=$default_provider
      fi
    elif [[ -n "$detected" ]]; then
      AAOS_INSTALL_PROVIDER=$detected
      provider_detected=yes
    else
      die "Anbieter fehlt und keine Kommandozeile gefunden. AAOS_INSTALL_PROVIDER=claude, copilot oder antigravity setzen."
    fi
  fi
  case "$(printf '%s' "$AAOS_INSTALL_PROVIDER" | tr '[:upper:]' '[:lower:]')" in
    1|claude) provider=claude ;;
    2|copilot|ms|microsoft|"microsoft copilot") provider=copilot ;;
    3|antigravity|agy) provider=antigravity ;;
    *) die "Unbekannter Anbieter: $AAOS_INSTALL_PROVIDER" ;;
  esac
  if [[ -z "$AAOS_INSTALL_AUTH" ]]; then
    if [[ -n "$AAOS_INSTALL_TOKEN" ]]; then
      AAOS_INSTALL_AUTH=token
    elif need_tty; then
      printf '%s\n' "Anmeldung:" >/dev/tty
      printf '%s\n' "  1) Abonnement, vorhandene Anmeldung [Voreinstellung]" >/dev/tty
      printf '%s\n' "  2) API-Token" >/dev/tty
      printf '%s' "Wahl [1]: " >/dev/tty
      IFS= read -r AAOS_INSTALL_AUTH </dev/tty || AAOS_INSTALL_AUTH=
    else
      AAOS_INSTALL_AUTH=subscription
    fi
  fi
  case "$(printf '%s' "$AAOS_INSTALL_AUTH" | tr '[:upper:]' '[:lower:]')" in
    ''|1|subscription|abonnement|abo) auth=subscription ;;
    2|token|api|api-token|apitoken) auth=token ;;
    *) die "Unbekannte Anmeldung: $AAOS_INSTALL_AUTH" ;;
  esac
  if [[ "$auth" == token ]]; then
    ask_secret AAOS_INSTALL_TOKEN "API-Token"
    [[ -n "$AAOS_INSTALL_TOKEN" ]] || die "API-Token ist leer."
  fi
  if [[ -z "$AAOS_INSTALL_ADVANCED" ]]; then
    if need_tty; then
      ask AAOS_INSTALL_ADVANCED "Abweichende Verbindung angeben" "nein"
    else
      AAOS_INSTALL_ADVANCED=nein
    fi
  fi
  if is_yes "$AAOS_INSTALL_ADVANCED"; then
    if [[ -z "$AAOS_INSTALL_MODEL" ]] && need_tty; then
      ask AAOS_INSTALL_MODEL "Modellname, leer fuer die Voreinstellung des Anbieters" ""
    fi
    if [[ -z "$AAOS_INSTALL_URL" ]] && need_tty; then
      ask AAOS_INSTALL_URL "Chat-Completions-URL, leer lassen" ""
    fi
  fi
fi
if [[ -n "$AAOS_INSTALL_URL" ]]; then
  case "$AAOS_INSTALL_URL" in
    http://*|https://*) ;;
    *) die "Die URL muss mit http:// oder https:// beginnen." ;;
  esac
  if [[ -z "$AAOS_INSTALL_TOKEN" ]]; then
    if need_tty; then
      printf '%s\n' "Eine eigene URL braucht ein API-Token. Die Anmeldung der Kommandozeile gilt dort nicht." >/dev/tty
      ask_secret AAOS_INSTALL_TOKEN "API-Token"
    fi
  fi
  [[ -n "$AAOS_INSTALL_TOKEN" ]] || die "Eine eigene URL braucht ein API-Token. Die Anmeldung der Kommandozeile gilt dort nicht."
  if [[ -z "$AAOS_INSTALL_MODEL" ]]; then
    AAOS_INSTALL_MODEL=default
  fi
fi
case "$AAOS_INSTALL_TOKEN" in
  *$'\n'*|*$'\r'*) die "API-Token darf keinen Zeilenumbruch enthalten." ;;
esac

ask AAOS_INSTALL_SELF_ENV "Umgebung selbst eintragen, statt einer Konfiguration im Baum" "nein"
if is_yes "$AAOS_INSTALL_SELF_ENV"; then
  self_env=yes
else
  self_env=no
fi

do_ccache=no
if [[ "$self_env" == yes ]]; then
  ask AAOS_INSTALL_CCACHE "ccache in ~/.bashrc (USE_CCACHE, Cache-Groesse)" "nein"
  if is_yes "$AAOS_INSTALL_CCACHE"; then
    if [[ -z "${AAOS_INSTALL_CCACHE_EXEC:-}" ]] && command -v ccache >/dev/null 2>&1; then
      AAOS_INSTALL_CCACHE_EXEC=$(command -v ccache)
    fi
    try_install_ccache
    if [[ -x "${AAOS_INSTALL_CCACHE_EXEC:-}" ]]; then
      do_ccache=yes
      ask AAOS_INSTALL_CCACHE_DIR "CCACHE_DIR" "${HOME}/.cache/ccache"
      ask AAOS_INSTALL_CCACHE_SIZE "Cache-Groesse fuer ccache -M" "100G"
      AAOS_INSTALL_CCACHE_DIR=$(expand_tilde "$AAOS_INSTALL_CCACHE_DIR")
    else
      printf '%s\n' "ccache fehlt und wurde nicht installiert. In der Distribution: sudo apt-get install -y ccache. Danach diese Installation erneut, mit Umgebung selbst eintragen. USE_CCACHE wird nicht gesetzt."
    fi
  fi
elif is_yes "${AAOS_INSTALL_CCACHE:-}"; then
  printf '%s\n' "AAOS_INSTALL_CCACHE wird ignoriert. ccache kommt nicht in die Gate-Datei, weil die nur m liest. Dafuer die Umgebung selbst eintragen."
fi

install -m 755 "$payload" "$tree/build/soong/bin/ai-patch-gate.sh"
if [[ -f "$here/aaos-ai-gate-dialog.ps1" ]]; then
  install -m 644 "$here/aaos-ai-gate-dialog.ps1" "$tree/build/soong/bin/aaos-ai-gate-dialog.ps1"
fi
hide_gate_from_git "$tree"

hook_status=$(python3 - "$tree/build/soong/bin/m" << 'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
block = "\n".join([
    'if [[ -f "$TOP/.aaos-ai-gate.conf" || -n "${AAOS_AI_GATE:-}" || -n "${AAOS_AI_GATE_MODE:-}" ]]; then',
    '  export TOP',
    '  "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \\',
    '    "$TOP/build/soong/soong_ui.bash" --build-mode --all-modules --dir="$(pwd)" "$@"',
    '  exit $?',
    'fi',
    '',
]) + "\n"
if 'ai-patch-gate.sh" run' in text and "export TOP" in text:
    print("vorhanden")
    raise SystemExit(0)
text2 = text.replace('ai-patch-gate.sh" drive', 'ai-patch-gate.sh" run', 1)
if 'ai-patch-gate.sh" run' in text2:
    old = '  "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \\\n'
    if "export TOP" not in text2 and old in text2:
        text2 = text2.replace(old, "  export TOP\n" + old, 1)
    if text2 != text:
        path.write_text(text2)
    print("aktualisiert")
    raise SystemExit(0)
needle = '_wrap_build "$TOP/build/soong/soong_ui.bash"'
idx = text.find(needle)
if idx < 0:
    print("fehlt")
    raise SystemExit(0)
line_start = text.rfind("\n", 0, idx) + 1
path.write_text(text[:line_start] + block + text[line_start:])
print("eingefuegt")
PY
)

if [[ "$hook_status" == "fehlt" ]]; then
  printf '%s\n' "m enthaelt nicht die erwartete Zeile _wrap_build \"\$TOP/build/soong/soong_ui.bash\"."
  printf '%s\n' "Das Skript liegt in build/soong/bin/ai-patch-gate.sh. Diese Zeilen von Hand vor dem Build-Aufruf in build/soong/bin/m setzen:"
  printf '%s\n' 'if [[ -f "$TOP/.aaos-ai-gate.conf" || -n "${AAOS_AI_GATE:-}" || -n "${AAOS_AI_GATE_MODE:-}" ]]; then'
  printf '%s\n' '  export TOP'
  printf '%s\n' '  "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \'
  printf '%s\n' '    "$TOP/build/soong/soong_ui.bash" --build-mode --all-modules --dir="$(pwd)" "$@"'
  printf '%s\n' '  exit $?'
  printf '%s\n' 'fi'
fi

if [[ "$do_ccache" == yes ]]; then
  if [[ -x "$AAOS_INSTALL_CCACHE_EXEC" ]]; then
    mkdir -p "$AAOS_INSTALL_CCACHE_DIR"
    if ! CCACHE_DIR="$AAOS_INSTALL_CCACHE_DIR" "$AAOS_INSTALL_CCACHE_EXEC" -M "$AAOS_INSTALL_CCACHE_SIZE"; then
      printf '%s\n' "Warnung: ccache -M ist fehlgeschlagen. Die export-Zeilen nennen den Pfad trotzdem."
    fi
  else
    printf '%s\n' "Warnung: $AAOS_INSTALL_CCACHE_EXEC fehlt, ccache -M wird uebersprungen."
  fi
fi

old_ccache=no
if [[ -f "$tree/.aaos-ai-gate.conf" ]] && grep -Eq '^(USE_CCACHE|CCACHE_EXEC|CCACHE_DIR|CCACHE_MAXSIZE)=' "$tree/.aaos-ai-gate.conf"; then
  old_ccache=yes
fi

if [[ "$self_env" == yes ]]; then
  if [[ -f "$tree/.aaos-ai-gate.conf" ]]; then
    rm -f "$tree/.aaos-ai-gate.conf"
    printf '%s\n' "Vorhandene $tree/.aaos-ai-gate.conf wurde entfernt."
  fi
  if [[ "$old_ccache" == yes ]]; then
    printf '%s\n' "Die bisherige Konfiguration enthielt ccache. Diese Zeilen entfallen. Stehen sie nicht in der Shell, aendert der naechste Build CC_WRAPPER und Soong und Kati erzeugen neu."
  fi
  printf '%s\n' "Installiert in $tree. Modus gewaehlt: $mode. Keine Konfigurationsdatei geschrieben."
  printf '%s\n' "Ohne gesetzte Variablen baut m wie vorher."
  if [[ "$provider_detected" == yes ]]; then
    printf '%s\n' "Anbieter erkannt: $(provider_label "$provider")."
  fi
  python3 - "$mode" "$provider" "$auth" "$AAOS_INSTALL_URL" "$AAOS_INSTALL_TOKEN" "$AAOS_INSTALL_MODEL" \
    "$do_ccache" "$AAOS_INSTALL_CCACHE_EXEC" "$AAOS_INSTALL_CCACHE_DIR" "$AAOS_INSTALL_CCACHE_SIZE" << 'PY'
import shlex, sys
mode, provider, auth, url, token, model, do, exe, cdir, size = sys.argv[1:11]
names = {
    "claude": "Claude",
    "copilot": "Microsoft Copilot",
    "antigravity": "Antigravity",
}
print()
print("Umgebung selbst eintragen. Nichts davon wurde in eine Datei im Baum geschrieben.")
print("In ~/.bashrc, danach source ~/.bashrc:")
print()
print("export AAOS_AI_GATE=on")
print("export AAOS_AI_GATE_MODE=" + shlex.quote(mode))
if url:
    print("export AAOS_AI_GATE_URL=" + shlex.quote(url))
    print("export AAOS_AI_GATE_TOKEN=" + shlex.quote(token))
    print("export AAOS_AI_GATE_MODEL=" + shlex.quote(model or "default"))
else:
    print("export AAOS_AI_GATE_PROVIDER=" + shlex.quote(provider))
    print("export AAOS_AI_GATE_AUTH=" + shlex.quote(auth))
    if auth == "token":
        print("export AAOS_AI_GATE_TOKEN=" + shlex.quote(token))
    if model and model != "default":
        print("export AAOS_AI_GATE_MODEL=" + shlex.quote(model))
print()
if url:
    print("Eigene Verbindung. Anmeldung: API-Token. Die Anmeldung der Kommandozeile gilt dort nicht.")
else:
    who = names.get(provider, provider)
    how = "API-Token" if auth == "token" else "Abonnement"
    print("Anbieter: " + who + ", Anmeldung: " + how + ".")
if model and model != "default":
    print("Modell: " + model + ".")
print("AAOS_AI_GATE_MODE=blocking fragt vor dem Build. j, ja, y oder yes startet ihn, auch bei likely_fail.")
print("Eingabe oder n stoppt nur diesen Lauf und wird nicht gemerkt. Ein frueher fehlgeschlagener Stand sperrt den naechsten Build nicht.")
print("Der Compiler bleibt die Pruefung. AAOS_AI_GATE=stop ist die einzige harte Weigerung, und nur bei likely_fail.")
print("AAOS_AI_GATE_MODE=parallel startet den Build sofort. Strg-C und der Stop-Button der IDE beenden ihn.")
print("Wird der Build fertig, waehrend die Anfrage noch laeuft, wird sie abgebrochen. Der naechste m prueft erneut. Keine 24-Stunden-Pause.")
print("Diff, Stash und Commit-Betreffs gehen an den Anbieter. Claude mit Token an api.anthropic.com, Antigravity mit Token an Google, Copilot und jedes Abonnement an die jeweilige Kommandozeile, eine eigene URL an diese URL.")
print("Optional: AAOS_AI_GATE_BASE=HEAD und AAOS_AI_GATE_MAX_BYTES=80000.")
print("Ein Ja liegt unter out/.aaos-ai-gate. m clean loescht nur das. Der Diff-Cache unter ~/.cache/aaos-ai-gate bleibt.")
if do == "yes":
    print()
    print("ccache gehoert in ~/.bashrc, nicht in die Gate-Datei. Die liest nur der Hook in build/soong/bin/m.")
    print("mm, mmm, mma und mmma sind eigene Skripte. make aus envsetup.sh ruft soong_ui.bash direkt.")
    print("Staende USE_CCACHE nur in der Gate-Datei, saehen mm und make sie nicht. Ein Wechsel aenderte CC_WRAPPER in soong.variables, und Soong und Kati erzeugten neu.")
    print("Nach dem Entfernen des Gates waere ccache still weg und der naechste Build kalt.")
    print("AOSP setzt compilercheck und sloppiness selbst. Die Groesse merkt sich ccache ueber -M. CCACHE_MAXSIZE schreibt dieser Installer nicht.")
    print("export USE_CCACHE=1")
    print("export CCACHE_EXEC=" + shlex.quote(exe))
    print("export CCACHE_DIR=" + shlex.quote(cdir))
    print("Einmalig die Groesse, falls ccache -M oben nicht schon lief:")
    print("CCACHE_DIR=" + shlex.quote(cdir) + " " + shlex.quote(exe) + " -M " + shlex.quote(size))
print()
print("Danach wie gewohnt: source build/envsetup.sh && lunch <ziel> && m")
PY
  cli_gap_note
  if [[ "$hook_status" == "fehlt" ]]; then
    exit 2
  fi
  exit 0
fi

conf=$(mktemp)
{
  printf '%s\n' '# aaos ai-patch-gate. Nur dieser Baum. Nicht committen.'
  printf 'AAOS_AI_GATE=%s\n' "$(sq on)"
  printf 'AAOS_AI_GATE_MODE=%s\n' "$(sq "$mode")"
  if [[ -n "$AAOS_INSTALL_URL" ]]; then
    printf 'AAOS_AI_GATE_URL=%s\n' "$(sq "$AAOS_INSTALL_URL")"
    printf 'AAOS_AI_GATE_TOKEN=%s\n' "$(sq "$AAOS_INSTALL_TOKEN")"
    printf 'AAOS_AI_GATE_MODEL=%s\n' "$(sq "${AAOS_INSTALL_MODEL:-default}")"
  else
    printf 'AAOS_AI_GATE_PROVIDER=%s\n' "$(sq "$provider")"
    printf 'AAOS_AI_GATE_AUTH=%s\n' "$(sq "$auth")"
    if [[ "$auth" == token ]]; then
      printf 'AAOS_AI_GATE_TOKEN=%s\n' "$(sq "$AAOS_INSTALL_TOKEN")"
    fi
    if [[ -n "$AAOS_INSTALL_MODEL" && "$AAOS_INSTALL_MODEL" != default ]]; then
      printf 'AAOS_AI_GATE_MODEL=%s\n' "$(sq "$AAOS_INSTALL_MODEL")"
    fi
  fi
} > "$conf"
install -m 600 "$conf" "$tree/.aaos-ai-gate.conf"
rm -f "$conf"

mode_label=blockierend
if [[ "$mode" == parallel ]]; then
  mode_label="parallel, nur Hinweis"
fi
printf '%s\n' "Installiert in $tree."
printf '%s\n' "Modus: $mode_label."
if [[ "$provider_detected" == yes ]]; then
  printf '%s\n' "Anbieter erkannt: $(provider_label "$provider")."
fi
if [[ -n "$AAOS_INSTALL_URL" ]]; then
  printf '%s\n' "Eigene Verbindung. Anmeldung: API-Token."
else
  printf '%s\n' "Anbieter: $(provider_label "$provider"), Anmeldung: $(auth_label "$auth")."
fi
if [[ -n "$AAOS_INSTALL_MODEL" && "$AAOS_INSTALL_MODEL" != default ]]; then
  printf '%s\n' "Modell: $AAOS_INSTALL_MODEL."
fi
printf '%s\n' "Konfiguration: $tree/.aaos-ai-gate.conf (nur fuer diesen Benutzer lesbar)."
printf '%s\n' "m ruft den Gate nur auf, wenn diese Datei oder AAOS_AI_GATE gesetzt ist."
printf '%s\n' "ccache steht nicht in dieser Datei. mm, mmm, mma, mmma und make aus envsetup.sh rufen soong_ui.bash direkt. Ein Wechsel aendert CC_WRAPPER, Soong und Kati erzeugen neu. Nach dem Entfernen waere ccache still weg. Die Variablen gehoeren in ~/.bashrc. Dafuer die Umgebung selbst eintragen."
if [[ "$old_ccache" == yes ]]; then
  printf '%s\n' "Die bisherige Konfiguration enthielt ccache. Diese Zeilen entfallen. Stehen sie nicht in der Shell, aendert der naechste Build den Wrapper und kompiliert kalt."
fi
printf '%s\n' "Diff, Stash und Commit-Betreffs gehen an den Anbieter. Claude mit Token an api.anthropic.com, Antigravity mit Token an Google, sonst an die Kommandozeile oder an die eigene URL."
cli_gap_note
if [[ "$hook_status" == "fehlt" ]]; then
  exit 2
fi
