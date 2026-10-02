#!/usr/bin/env bash
# Tests fuer install-linux.sh. Bash 3.2, ohne Netz.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER=${INSTALLER:-"$ROOT/install-linux.sh"}
FIXTURE_M=$ROOT/tests/fixtures/m
FIXTURE_UTILS=$ROOT/tests/fixtures/shell_utils.sh
WRAP_GATE='_wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run --'
TOKEN="s3cr3tTok'en \$XY"

n=0
bad=0

pass() {
  n=$((n + 1))
  printf 'ok %s %s\n' "$n" "$1"
}

fail() {
  n=$((n + 1))
  bad=$((bad + 1))
  printf 'not ok %s %s\n' "$n" "$1"
}

cleanup_list=
cleanup() {
  local d
  for d in $cleanup_list; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

note_cleanup() {
  cleanup_list="$cleanup_list $1"
}

make_tree() {
  local t
  t=$(mktemp -d "${TMPDIR:-/tmp}/aaos-gate-tree.XXXXXX")
  note_cleanup "$t"
  mkdir -p "$t/build/soong/bin" "$t/build/make"
  cp "$FIXTURE_M" "$t/build/soong/bin/m"
  chmod +x "$t/build/soong/bin/m"
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$t/build/soong/soong_ui.bash"
  chmod +x "$t/build/soong/soong_ui.bash"
  : > "$t/build/envsetup.sh"
  cp "$FIXTURE_UTILS" "$t/build/make/shell_utils.sh"
  printf '%s\n' "$t"
}

stage_installer() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/aaos-gate-inst.XXXXXX")
  note_cleanup "$d"
  cp "$INSTALLER" "$d/install-linux.sh"
  cp "$ROOT/ai-patch-gate.sh" "$d/"
  if [[ -f "$ROOT/aaos-ai-gate-dialog.ps1" ]]; then
    cp "$ROOT/aaos-ai-gate-dialog.ps1" "$d/"
  fi
  printf '%s\n' "$d"
}

run_install() {
  local stage=$1 tree=$2
  AAOS_INSTALL_TREE="$tree" \
    AAOS_INSTALL_MODE=blocking \
    AAOS_INSTALL_PROVIDER=claude \
    AAOS_INSTALL_AUTH=token \
    AAOS_INSTALL_TOKEN="$TOKEN" \
    AAOS_INSTALL_ADVANCED=nein \
    AAOS_INSTALL_SELF_ENV=nein \
    AAOS_INSTALL_CCACHE=nein \
    AAOS_INSTALL_CCACHE_INSTALL=nein \
    bash "$stage/install-linux.sh"
}

run_uninstall() {
  local stage=$1 tree=$2
  AAOS_INSTALL_TREE="$tree" \
    bash "$stage/install-linux.sh" uninstall
}

count_wrap() {
  grep -F -c "$WRAP_GATE" "$1/build/soong/bin/m" || true
}

insert_old_hook() {
  local m=$1
  python3 - "$m" << 'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = "\n".join([
    'if [[ -f "$TOP/.aaos-ai-gate.conf" || -n "${AAOS_AI_GATE:-}" || -n "${AAOS_AI_GATE_MODE:-}" ]]; then',
    '  export TOP',
    '  "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \\',
    '    "$TOP/build/soong/soong_ui.bash" --build-mode --all-modules --dir="$(pwd)" "$@"',
    '  exit $?',
    'fi',
    '',
]) + "\n"
needle = '_wrap_build "$TOP/build/soong/soong_ui.bash"'
idx = text.find(needle)
if idx < 0:
    raise SystemExit("needle fehlt")
line_start = text.rfind("\n", 0, idx) + 1
path.write_text(text[:line_start] + old + text[line_start:])
PY
}

insert_indented_hook() {
  local m=$1
  python3 - "$m" << 'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
block = "\n".join([
    '  if [[ -f "$TOP/.aaos-ai-gate.conf" || -n "${AAOS_AI_GATE:-}" || -n "${AAOS_AI_GATE_MODE:-}" ]]; then',
    '    export TOP',
    '    _wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \\',
    '      "$TOP/build/soong/soong_ui.bash" --build-mode --all-modules --dir="$(pwd)" "$@"',
    '    exit $?',
    '  fi',
    '',
]) + "\n"
needle = '_wrap_build "$TOP/build/soong/soong_ui.bash"'
idx = text.find(needle)
if idx < 0:
    raise SystemExit("needle fehlt")
line_start = text.rfind("\n", 0, idx) + 1
path.write_text(text[:line_start] + block + text[line_start:])
PY
}

stub_gate() {
  printf '%s\n' '#!/bin/bash' 'exit 0' > "$1/build/soong/bin/ai-patch-gate.sh"
  chmod +x "$1/build/soong/bin/ai-patch-gate.sh"
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# --- (a) Installation in Fake-Baum ---
stage=$(stage_installer)
tree=$(make_tree)
out=$(run_install "$stage" "$tree" 2>&1) || true
wraps=$(count_wrap "$tree")
stub_gate "$tree"
m_out=$(cd "$tree" && TOP="$tree" bash "$tree/build/soong/bin/m" 2>&1) || true
if [[ "$wraps" -eq 1 ]] && printf '%s\n' "$m_out" | grep -q 'WRAPPED rc=0'; then
  pass "a install wrap_build einmal, Fake-m WRAPPED rc=0"
else
  fail "a wrap_count=$wraps m_out=$(printf '%s' "$m_out" | tr '\n' '|')"
fi

# --- (b) zweite Installation, byteidentisch, Meldung vorhanden ---
cp "$tree/build/soong/bin/m" "$tree/m.after-a"
out_b=$(run_install "$stage" "$tree" 2>&1) || true
if cmp -s "$tree/m.after-a" "$tree/build/soong/bin/m" && printf '%s\n' "$out_b" | grep -q 'vorhanden'; then
  pass "b zweite Installation vorhanden, m byteidentisch"
else
  fail "b vorhanden-Meldung oder m geaendert"
fi

# --- (c) alter Block ohne _wrap_build ---
tree_c=$(make_tree)
insert_old_hook "$tree_c/build/soong/bin/m"
stage_c=$(stage_installer)
run_install "$stage_c" "$tree_c" >/dev/null 2>&1 || true
wraps_c=$(count_wrap "$tree_c")
if [[ "$wraps_c" -eq 1 ]]; then
  pass "c alter Block auf neue Form, genau einmal"
else
  fail "c wrap_count=$wraps_c"
fi

# --- (d) Uninstall stellt Fixture wieder her ---
tree_d=$(make_tree)
stage_d=$(stage_installer)
run_install "$stage_d" "$tree_d" >/dev/null 2>&1 || true
run_uninstall "$stage_d" "$tree_d" >/dev/null 2>&1 || true
scripts_d=0
[[ -f "$tree_d/build/soong/bin/ai-patch-gate.sh" ]] && scripts_d=1
[[ -f "$tree_d/.aaos-ai-gate.conf" ]] && scripts_d=1
if cmp -s "$FIXTURE_M" "$tree_d/build/soong/bin/m" && [[ "$scripts_d" -eq 0 ]]; then
  pass "d Uninstall: m wie Fixture, Skripte und Konfiguration weg"
else
  fail "d m weicht ab oder Reste bleiben"
fi

# --- (e) handeingerueckter Block ---
tree_e=$(make_tree)
stage_e=$(stage_installer)
insert_indented_hook "$tree_e/build/soong/bin/m"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$tree_e/build/soong/bin/ai-patch-gate.sh"
: > "$tree_e/build/soong/bin/aaos-ai-gate-dialog.ps1"
: > "$tree_e/.aaos-ai-gate.conf"
set +e
run_uninstall "$stage_e" "$tree_e" >/dev/null 2>&1
rc_e=$?
set -u
hook_e=0
grep -q 'ai-patch-gate.sh' "$tree_e/build/soong/bin/m" && hook_e=1
script_e=0
[[ -f "$tree_e/build/soong/bin/ai-patch-gate.sh" ]] && script_e=1
if [[ "$script_e" -eq 0 && "$hook_e" -eq 1 ]]; then
  fail "e Skripte weg, Hook da"
elif [[ "$hook_e" -eq 0 ]]; then
  pass "e eingerueckter Hook entfernt"
elif [[ "$script_e" -eq 1 && "$rc_e" -eq 3 ]]; then
  pass "e Skripte bleiben, rc 3"
else
  fail "e hook=$hook_e scripts=$script_e rc=$rc_e"
fi

# --- (f) Konfiguration Modus 600 und Token-Quoting ---
tree_f=$(make_tree)
stage_f=$(stage_installer)
run_install "$stage_f" "$tree_f" >/dev/null 2>&1 || true
conf=$tree_f/.aaos-ai-gate.conf
mode_f=$(file_mode "$conf")
want_line=$(TOKEN_VAL="$TOKEN" python3 -c 'import os,shlex; print("AAOS_AI_GATE_TOKEN="+shlex.quote(os.environ["TOKEN_VAL"]))')
if [[ "$mode_f" == 600 ]] && grep -qxF "$want_line" "$conf"; then
  pass "f Konfiguration Modus 600, Token korrekt gequotet"
else
  fail "f mode=$mode_f line_ok=$(grep -qxF "$want_line" "$conf" && echo yes || echo no)"
fi

# --- (g) Token nicht in python3-argv ---
tree_g=$(make_tree)
stage_g=$(stage_installer)
wrapdir=$(mktemp -d "${TMPDIR:-/tmp}/aaos-gate-py.XXXXXX")
note_cleanup "$wrapdir"
argvlog=$wrapdir/argv.log
: > "$argvlog"
real_py=$(command -v python3)
cat > "$wrapdir/python3" << EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$argvlog"
exec "$real_py" "\$@"
EOF
chmod +x "$wrapdir/python3"
PATH="$wrapdir:$PATH" \
  AAOS_INSTALL_TREE="$tree_g" \
  AAOS_INSTALL_MODE=blocking \
  AAOS_INSTALL_PROVIDER=claude \
  AAOS_INSTALL_AUTH=token \
  AAOS_INSTALL_TOKEN="$TOKEN" \
  AAOS_INSTALL_ADVANCED=nein \
  AAOS_INSTALL_SELF_ENV=nein \
  AAOS_INSTALL_CCACHE=nein \
  AAOS_INSTALL_CCACHE_INSTALL=nein \
  bash "$stage_g/install-linux.sh" >/dev/null 2>&1 || true
hits=$(grep -F -c "$TOKEN" "$argvlog" || true)
if [[ -s "$argvlog" && "$hits" -eq 0 ]]; then
  pass "g Token nicht in python3-argv"
else
  fail "g hits=$hits argvlog_empty=$([[ -s $argvlog ]] && echo no || echo yes)"
fi

# --- (h) Self-Env Token als nicht exportierte Shell-Variable ---
# Die Briefing-Form `AAOS_INSTALL_TOKEN=geheim exec bash install-linux.sh` legt
# den Wert in die Umgebung des exec. BASH_ENV setzt ihn nur in der Shell.
tree_h=$(make_tree)
stage_h=$(stage_installer)
settok=$(mktemp "${TMPDIR:-/tmp}/aaos-gate-tok.XXXXXX")
note_cleanup "$settok"
printf '%s\n' 'AAOS_INSTALL_TOKEN=geheim' > "$settok"
tok_env=$(env -u AAOS_INSTALL_TOKEN BASH_ENV="$settok" bash -c 'python3 -c "import os; print(os.environ.get(\"AAOS_INSTALL_TOKEN\") or \"\")"')
tok_sh=$(env -u AAOS_INSTALL_TOKEN BASH_ENV="$settok" bash -c 'printf %s "$AAOS_INSTALL_TOKEN"')
if [[ -n "$tok_env" || "$tok_sh" != "geheim" ]]; then
  fail "h Vorbereitung: Token exportiert oder nicht gesetzt (env='$tok_env' sh='$tok_sh')"
else
  out_h=$(
    env -u AAOS_INSTALL_TOKEN \
      BASH_ENV="$settok" \
      AAOS_INSTALL_TREE="$tree_h" \
      AAOS_INSTALL_MODE=blocking \
      AAOS_INSTALL_PROVIDER=claude \
      AAOS_INSTALL_AUTH=token \
      AAOS_INSTALL_ADVANCED=nein \
      AAOS_INSTALL_SELF_ENV=ja \
      AAOS_INSTALL_CCACHE=nein \
      AAOS_INSTALL_CCACHE_INSTALL=nein \
      bash "$stage_h/install-linux.sh" 2>&1
  ) || true
  if printf '%s\n' "$out_h" | grep -Eq "export AAOS_AI_GATE_TOKEN=('geheim'|geheim)$"; then
    pass "h Self-Env Token nicht exportiert, Ausgabe enthaelt export"
  else
    fail "h Token-Zeile fehlt: $(printf '%s' "$out_h" | grep AAOS_AI_GATE_TOKEN | tr '\n' '|')"
  fi
fi

printf '%s\n' "$n Tests, $bad fehlgeschlagen"
if [[ "$bad" -ne 0 ]]; then
  exit 1
fi
exit 0
