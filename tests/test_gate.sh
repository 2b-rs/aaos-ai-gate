#!/bin/bash
# Gate regression tests. Exit 0 when every selected case passes.
# GATE=/path/to/ai-patch-gate.sh bash tests/test_gate.sh [a b c ...]
# With no ids, every case runs. Needs bash 3.2, git, curl, jq, python3.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE=${GATE:-$ROOT/ai-patch-gate.sh}
FAKE_BUILD=$ROOT/tests/fake_build.sh
FAKE_MODEL=$ROOT/tests/fake_model.py

if [[ ! -f "$GATE" ]]; then
  echo "gate missing: $GATE" >&2
  echo "0 Tests, 1 fehlgeschlagen"
  exit 1
fi
# git show redirects a baseline script without the executable bit. post is
# invoked as "$0", so a non-executable copy never records the ledger.
chmod +x "$GATE" 2>/dev/null || true

SUITE=$(mktemp -d "${TMPDIR:-/tmp}/aaos-gate-tests.XXXXXX")
export TMPDIR=$SUITE/tmp
mkdir -p "$TMPDIR" "$SUITE/home" "$SUITE/server" "$SUITE/bin"
PIDS=

cleanup() {
  local p
  for p in $PIDS; do
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 0.2
  for p in $PIDS; do
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$SUITE"
}
trap cleanup EXIT

ok=0
bad=0
RUN_ALL=1
RUN_SET=
if [[ $# -gt 0 ]]; then
  RUN_ALL=0
  RUN_SET=" $* "
fi

should() {
  if [[ "$RUN_ALL" -eq 1 ]]; then
    return 0
  fi
  case "$RUN_SET" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

note() {
  printf '%s\n' "$*" >&2
}

count_now() {
  local n
  n=$(cat "$SUITE/server/count" 2>/dev/null || printf '0')
  printf '%s' "$n"
}

set_delay() {
  printf '%s\n' "$1" > "$SUITE/server/delay"
}

set_verdict() {
  printf '%s\n' "$1" > "$SUITE/server/verdict.txt"
}

make_repo() {
  local d
  d=$(mktemp -d "$TMPDIR/repo.XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.quotepath false
  printf 'base\n' > "$d/file.txt"
  git -C "$d" add file.txt
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

# Wait until the server has accepted at least one new request, then exit.
# Used as the fake build so the model call is in flight before the build ends.
poll_build='
b=$1
f=$2
extra=${3:-0}
i=0
while [ "$i" -lt 80 ]; do
  c=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$c" -gt "$b" ]; then
    if [ "$extra" -gt 0 ]; then
      sleep "$extra"
    fi
    exit 0
  fi
  i=$((i + 1))
  sleep 0.1
done
exit 0
'

start_server() {
  FAKE_MODEL_DIR=$SUITE/server python3 "$FAKE_MODEL" &
  PIDS="$PIDS $!"
  local i=0
  while [[ ! -s "$SUITE/server/port" ]]; do
    i=$((i + 1))
    if [[ "$i" -gt 50 ]]; then
      note "fake model did not bind"
      return 1
    fi
    sleep 0.1
  done
  PORT=$(cat "$SUITE/server/port")
  set_delay 0
  set_verdict '{"compile":"ok","runtime":"ok","effect":"likely","ask":false,"question":"","reason":"ok"}'
}

# Start the gate in the repo and wait until it exits, or kill it after ~25s.
# Stdout/stderr go to the given log. The pid is stored in GATE_PID.
run_gate_wait() {
  local repo=$1 log=$2
  shift 2
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="${GATE_TMPDIR:-$TMPDIR}" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      "$@" \
      bash "$GATE" run -- bash -c "$poll_build" _ "$COUNT_BEFORE" "$SUITE/server/count" "${BUILD_EXTRA:-0}"
  ) > "$log" 2>&1 &
  GATE_PID=$!
  PIDS="$PIDS $GATE_PID"
  local i=0
  while kill -0 "$GATE_PID" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt 250 ]]; then
      kill -TERM "$GATE_PID" 2>/dev/null || true
      sleep 0.3
      kill -KILL "$GATE_PID" 2>/dev/null || true
      note "gate timed out; log follows"
      cat "$log" >&2 || true
      wait "$GATE_PID" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
  done
  wait "$GATE_PID" 2>/dev/null || true
  return 0
}

gate_env() {
  REPO=$1
  CACHE=$2
  printf '%s\n' \
    AAOS_AI_GATE=on \
    AAOS_AI_GATE_MODE=parallel \
    AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
    AAOS_AI_GATE_TOKEN="${TOKEN:-token-default}" \
    AAOS_AI_GATE_CACHE="$CACHE" \
    TOP="$REPO"
}

case_a() {
  local repo cache log before after
  repo=$(make_repo)
  printf 'changed\n' >> "$repo/file.txt"
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  log=$SUITE/a.log
  set_delay 4
  before=$(count_now)
  COUNT_BEFORE=$before
  BUILD_EXTRA=0
  TOKEN=token-a
  GATE_TMPDIR=$TMPDIR
  # shellcheck disable=SC2046
  run_gate_wait "$repo" "$log" $(gate_env "$repo" "$cache") || return 1
  set_delay 0
  before=$(count_now)
  if [[ "$before" -lt 1 ]]; then
    note "a: first run never reached the model"
    cat "$log" >&2 || true
    return 1
  fi
  COUNT_BEFORE=$before
  log=$SUITE/a2.log
  run_gate_wait "$repo" "$log" $(gate_env "$repo" "$cache") || return 1
  after=$(count_now)
  if [[ "$after" -ne $((before + 1)) ]]; then
    note "a: expected a second model call, count $before -> $after"
    cat "$SUITE/a.log" "$log" >&2 || true
    return 1
  fi
  if grep -q "this tree already compiled" "$log"; then
    note "a: second run treated the tree as already compiled"
    cat "$log" >&2 || true
    return 1
  fi
  return 0
}

case_b() {
  local repo cache log before bdir token real_tmp snap hits extra
  repo=$(make_repo)
  printf 'changed\n' >> "$repo/file.txt"
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  bdir=$SUITE/b-tmp
  mkdir -p "$bdir"
  token=TOK$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  # Real curl dies on TERM and the old gate then reaches `rm`. A client that
  # ignores TERM keeps the request in flight until KILL, which is when the
  # token file survives unless the gate deletes its temp directory anyway.
  mkdir -p "$SUITE/b-bin"
  cat > "$SUITE/b-bin/curl" << 'EOF'
#!/usr/bin/env python3
import signal
import sys
import time
import urllib.error
import urllib.request

signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)

args = sys.argv[1:]
config = None
data_file = None
i = 0
while i < len(args):
    arg = args[i]
    if arg == "--config" and i + 1 < len(args):
        config = args[i + 1]
        i += 2
        continue
    if arg == "--data-binary" and i + 1 < len(args):
        spec = args[i + 1]
        if spec.startswith("@"):
            data_file = spec[1:]
        i += 2
        continue
    i += 1

url = ""
headers = {}
if config:
    for line in open(config, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.startswith("url"):
            url = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("header"):
            raw = line.split("=", 1)[1].strip().strip('"')
            if ":" in raw:
                key, value = raw.split(":", 1)
                headers[key.strip()] = value.strip()
body = b""
if data_file:
    with open(data_file, "rb") as handle:
        body = handle.read()
request = urllib.request.Request(url, data=body, headers=headers, method="POST")
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        sys.stdout.buffer.write(response.read())
except (OSError, urllib.error.URLError):
    pass
while True:
    time.sleep(30)
EOF
  chmod +x "$SUITE/b-bin/curl"
  log=$SUITE/b.log
  set_delay 20
  before=$(count_now)
  # macOS mktemp ignores TMPDIR and drops tmp.* directly in its temp
  # directory. Only that one level is compared; descending into it walks
  # every other program's cache. The suite is skipped: the fake server
  # stores the bearer token in last_meta.json.
  real_tmp=$(dirname "$(mktemp -u)")
  snap=$SUITE/b-before.txt
  : > "$snap"
  if [[ -d "$real_tmp" ]]; then
    find "$real_tmp" -maxdepth 1 \( -type f -o -type d \) ! -path "$real_tmp" ! -path "$SUITE" -print 2>/dev/null | sort > "$snap"
  fi
  COUNT_BEFORE=$before
  BUILD_EXTRA=0
  TOKEN=$token
  GATE_TMPDIR=$bdir
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$SUITE/b-bin:$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$bdir" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      AAOS_AI_GATE=on \
      AAOS_AI_GATE_MODE=parallel \
      AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
      AAOS_AI_GATE_TOKEN="$token" \
      AAOS_AI_GATE_CACHE="$cache" \
      TOP="$repo" \
      bash "$GATE" run -- bash -c 'sleep 30'
  ) > "$log" 2>&1 &
  GATE_PID=$!
  PIDS="$PIDS $GATE_PID"
  local i=0
  while [[ "$(count_now)" -le "$before" ]]; do
    i=$((i + 1))
    if [[ "$i" -gt 80 ]]; then
      note "b: request did not start"
      cat "$log" >&2 || true
      kill -TERM "$GATE_PID" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
  done
  kill -TERM "$GATE_PID" 2>/dev/null || true
  i=0
  while kill -0 "$GATE_PID" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt 150 ]]; then
      kill -KILL "$GATE_PID" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done
  wait "$GATE_PID" 2>/dev/null || true
  hits=$(grep -rl -- "$token" "$bdir" 2>/dev/null || true)
  extra=
  if [[ -d "$real_tmp" ]]; then
    extra=$(find "$real_tmp" -maxdepth 1 \( -type f -o -type d \) ! -path "$real_tmp" ! -path "$SUITE" -print 2>/dev/null | sort | comm -13 "$snap" - | while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [[ -d "$f" ]]; then
        grep -rl -- "$token" "$f" 2>/dev/null || true
      elif [[ -f "$f" ]]; then
        grep -l -- "$token" "$f" 2>/dev/null || true
      fi
    done)
  fi
  hits=$(printf '%s\n%s\n' "$hits" "$extra" | sed '/^$/d' | sort -u)
  if [[ -n "$hits" ]]; then
    note "b: token still on disk:"
    printf '%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

case_c() {
  local repo cache log
  repo=$(make_repo)
  printf 'changed\n' >> "$repo/file.txt"
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  log=$SUITE/c-build.log
  : > "$log"
  set_delay 15
  TOKEN=token-c
  GATE_TMPDIR=$TMPDIR
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$TMPDIR" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      AAOS_AI_GATE=on \
      AAOS_AI_GATE_MODE=parallel \
      AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
      AAOS_AI_GATE_TOKEN="$TOKEN" \
      AAOS_AI_GATE_CACHE="$cache" \
      TOP="$repo" \
      bash "$GATE" run -- bash "$FAKE_BUILD" "$log"
  ) > "$SUITE/c-gate.log" 2>&1 &
  GATE_PID=$!
  PIDS="$PIDS $GATE_PID"
  local i=0
  while ! grep -q '^start$' "$log" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt 80 ]]; then
      note "c: build did not start"
      cat "$SUITE/c-gate.log" >&2 || true
      kill -TERM "$GATE_PID" 2>/dev/null || true
      return 1
    fi
    sleep 0.1
  done
  local started=$SECONDS
  kill -TERM "$GATE_PID" 2>/dev/null || true
  i=0
  while kill -0 "$GATE_PID" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt 150 ]]; then
      kill -KILL "$GATE_PID" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done
  wait "$GATE_PID" 2>/dev/null || true
  local elapsed=$((SECONDS - started))
  if ! grep -q '^TERM$' "$log"; then
    note "c: build did not record TERM"
    cat "$log" >&2 || true
    return 1
  fi
  if ! grep -q '^cleanup-done$' "$log"; then
    note "c: build had no time to finish cleanup"
    cat "$log" >&2 || true
    return 1
  fi
  if [[ "$elapsed" -lt 2 ]]; then
    note "c: gate returned after ${elapsed}s, before the 2s cleanup"
    return 1
  fi
  return 0
}

case_d() {
  local repo cache log before meta
  repo=$(make_repo)
  printf 'changed line for the parser case\n' >> "$repo/file.txt"
  # Long enough that a parsed limit of 80 truncates.
  python3 -c 'open("'"$repo"'/file.txt","a").write("x"*400+"\n")'
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  cat > "$repo/.aaos-ai-gate.conf" << EOF
  AAOS_AI_GATE_TOKEN='from-space'
export AAOS_AI_GATE_MODEL='from-export'
AAOS_AI_GATE_URL
AAOS_AI_GATE_URL='http://127.0.0.1:${PORT}/'  # c
AAOS_AI_GATE_MAX_BYTES="80"
EOF
  log=$SUITE/d.log
  set_delay 0
  before=$(count_now)
  COUNT_BEFORE=$before
  BUILD_EXTRA=1
  GATE_TMPDIR=$TMPDIR
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$TMPDIR" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      AAOS_AI_GATE=on \
      AAOS_AI_GATE_MODE=parallel \
      AAOS_AI_GATE_CACHE="$cache" \
      TOP="$repo" \
      bash "$GATE" run -- bash -c "$poll_build" _ "$COUNT_BEFORE" "$SUITE/server/count" 1
  ) > "$log" 2>&1
  if ! grep -q 'Konfiguration Zeile 3 wird ignoriert' "$log"; then
    note "d: missing warning for the line without '='"
    cat "$log" >&2 || true
    return 1
  fi
  if [[ "$(count_now)" -le "$before" ]]; then
    note "d: model was not called; URL or token did not parse"
    cat "$log" >&2 || true
    return 1
  fi
  meta=$(python3 -c 'import json; print(json.load(open("'"$SUITE"'/server/last_meta.json"))["auth"]); print(json.load(open("'"$SUITE"'/server/last_meta.json"))["model"])')
  local auth model
  auth=$(printf '%s\n' "$meta" | awk 'NR==1 {print}')
  model=$(printf '%s\n' "$meta" | awk 'NR==2 {print}')
  if [[ "$auth" != "Bearer from-space" ]]; then
    note "d: token parsed as [$auth]"
    return 1
  fi
  if [[ "$model" != "from-export" ]]; then
    note "d: model parsed as [$model]"
    return 1
  fi
  if ! grep -q 'truncated=1' "$log"; then
    note "d: double-quoted MAX_BYTES was not applied"
    cat "$log" >&2 || true
    return 1
  fi
  return 0
}

case_e() {
  local repo cache log before piece_meta max_bytes sent
  repo=$(make_repo)
  python3 -c 'open("'"$repo"'/u.txt","w").write("ä"*40+"\n")'
  git -C "$repo" add u.txt
  git -C "$repo" commit -q -m umlaut
  python3 -c 'open("'"$repo"'/u.txt","w").write("ä"*80+"\n")'
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  piece_meta=$(
    cd "$repo" && python3 -c '
import subprocess, sys
diff = subprocess.check_output(["git","diff","--no-ext-diff","-U20","HEAD","--","u.txt"])
piece = diff + b"\n"
chars = len(piece.decode("utf-8"))
byt = len(piece)
cut = piece[:chars]
cut.decode("utf-8")
if byt <= chars:
    sys.stderr.write("piece has no multibyte gap\n")
    sys.exit(2)
sys.stdout.write("%s %s\n" % (chars, byt))
'
  ) || {
    note "e: could not measure the umlaut diff"
    return 1
  }
  max_bytes=${piece_meta%% *}
  log=$SUITE/e.log
  set_delay 0
  before=$(count_now)
  COUNT_BEFORE=$before
  BUILD_EXTRA=0
  TOKEN=token-e
  GATE_TMPDIR=$TMPDIR
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$TMPDIR" \
      LANG="${LANG:-}" \
      LC_CTYPE=UTF-8 \
      AAOS_AI_GATE=on \
      AAOS_AI_GATE_MODE=parallel \
      AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
      AAOS_AI_GATE_TOKEN="$TOKEN" \
      AAOS_AI_GATE_CACHE="$cache" \
      AAOS_AI_GATE_MAX_BYTES="$max_bytes" \
      TOP="$repo" \
      bash "$GATE" run -- bash -c "$poll_build" _ "$COUNT_BEFORE" "$SUITE/server/count" 0
  ) > "$log" 2>&1
  if [[ "$(count_now)" -le "$before" ]]; then
    note "e: model was not called"
    cat "$log" >&2 || true
    return 1
  fi
  sent=$(python3 -c '
import json, sys
body = open("'"$SUITE"'/server/last_body","rb").read()
req = json.loads(body.decode("utf-8"))
user = req["messages"][-1]["content"]
part = user.split("new diff:\n", 1)[1]
prefix = "file u.txt\n"
if not part.startswith(prefix):
    sys.stderr.write("diff prefix missing\n")
    sys.exit(2)
rest = part[len(prefix):].encode("utf-8")
sys.stdout.write(str(len(rest)))
') || {
    note "e: could not read the sent diff"
    cat "$log" >&2 || true
    return 1
  }
  # The gate adds one trailing newline after the limited piece.
  if [[ "$sent" -gt $((max_bytes + 1)) ]]; then
    note "e: sent $sent bytes, limit is $max_bytes (piece ${piece_meta##* } bytes)"
    return 1
  fi
  return 0
}

case_f() {
  local repo q ans log rc
  repo=$(make_repo)
  q=$SUITE/question.txt
  ans=$SUITE/answer.txt
  printf 'Was bedeutet das?\n' > "$q"
  rm -f "$ans"
  log=$SUITE/f.log
  set_delay 0
  set +e
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$TMPDIR" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
      AAOS_AI_GATE_TOKEN="tok-f" \
      AAOS_AI_GATE_TOP="$repo" \
      bash "$GATE" ask --conf "$SUITE/no-such-conf" --question "$q" --answer "$ans"
  ) > "$log" 2>"$SUITE/f.err"
  rc=$?
  set -u
  if [[ "$rc" -ne 0 ]]; then
    note "f: ask exited $rc"
    cat "$SUITE/f.err" "$log" >&2 || true
    return 1
  fi
  if [[ ! -s "$ans" ]]; then
    note "f: answer.txt is empty"
    return 1
  fi
  return 0
}

case_g() {
  local repo cache log before bin
  repo=$(make_repo)
  printf 'changed\n' >> "$repo/file.txt"
  mkdir -p "$repo/.repo"
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  bin=$SUITE/bin
  cat > "$bin/repo" << 'EOF'
#!/bin/bash
if [[ "${1:-}" == "list" ]]; then
  printf '%s\n' .
  exit 0
fi
exit 3
EOF
  chmod +x "$bin/repo"
  log=$SUITE/g.log
  set_delay 0
  before=$(count_now)
  TOKEN=token-g
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$bin:$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$TMPDIR" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      AAOS_AI_GATE=on \
      AAOS_AI_GATE_MODE=parallel \
      AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
      AAOS_AI_GATE_TOKEN="$TOKEN" \
      AAOS_AI_GATE_CACHE="$cache" \
      TOP="$repo" \
      bash "$GATE" run -- bash -c 'sleep 2'
  ) > "$log" 2>&1
  if ! grep -q 'repo forall ist fehlgeschlagen, dieser m läuft ohne Prüfung' "$log"; then
    note "g: missing forall failure message"
    cat "$log" >&2 || true
    return 1
  fi
  if [[ "$(count_now)" -ne "$before" ]]; then
    note "g: model was asked even though repo forall failed"
    return 1
  fi
  return 0
}

case_i() {
  local repo cache log ps meta conf mode
  repo=$(make_repo)
  printf 'changed\n' >> "$repo/file.txt"
  cache=$(mktemp -d "$TMPDIR/cache.XXXXXX")
  mkdir -p "$SUITE/dialog"
  ps=$SUITE/fake-ps.sh
  cat > "$ps" << EOF
#!/bin/bash
dest=
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-DataDir" ]]; then
    dest=\$2
    shift 2
  else
    shift
  fi
done
cp "\$dest/meta.json" "$SUITE/dialog/meta.json"
cp "\$dest/env.conf" "$SUITE/dialog/env.conf" 2>/dev/null || true
EOF
  chmod +x "$ps"
  set_verdict '{"compile":"likely_fail","runtime":"ok","effect":"unknown","ask":false,"question":"","reason":"bruch"}'
  set_delay 0
  log=$SUITE/i.log
  COUNT_BEFORE=$(count_now)
  BUILD_EXTRA=1
  TOKEN=token-i
  GATE_TMPDIR=$TMPDIR
  (
    cd "$repo" || exit 97
    exec env -i \
      PATH="$PATH" \
      HOME="$SUITE/home" \
      TMPDIR="$TMPDIR" \
      LANG="${LANG:-}" \
      LC_CTYPE="${LC_CTYPE:-UTF-8}" \
      AAOS_AI_GATE=on \
      AAOS_AI_GATE_MODE=parallel \
      AAOS_AI_GATE_URL="http://127.0.0.1:${PORT}/" \
      AAOS_AI_GATE_TOKEN="$TOKEN" \
      AAOS_AI_GATE_CACHE="$cache" \
      AAOS_AI_GATE_WINDOWS_UI=force \
      AAOS_AI_GATE_POWERSHELL="$ps" \
      TOP="$repo" \
      bash "$GATE" run -- bash -c "$poll_build" _ "$COUNT_BEFORE" "$SUITE/server/count" 1
  ) > "$log" 2>&1
  set_verdict '{"compile":"ok","runtime":"ok","effect":"likely","ask":false,"question":"","reason":"ok"}'
  # The dialog process is started in the background and may still be copying
  # when run returns.
  local n=0
  while [[ ! -f "$SUITE/dialog/meta.json" ]]; do
    n=$((n + 1))
    if [[ "$n" -gt 30 ]]; then
      note "i: dialog was not started"
      cat "$log" >&2 || true
      return 1
    fi
    sleep 0.1
  done
  meta=$(python3 -c 'import json; print(json.load(open("'"$SUITE"'/dialog/meta.json")).get("linuxConf",""))')
  case "$meta" in
    */env.conf) ;;
    *)
      note "i: linuxConf is [$meta]"
      return 1
      ;;
  esac
  conf=$SUITE/dialog/env.conf
  if [[ ! -f "$conf" ]]; then
    note "i: env.conf was not written"
    return 1
  fi
  mode=$(stat -f %Lp "$conf" 2>/dev/null || stat -c %a "$conf")
  if [[ "$mode" != "600" ]]; then
    note "i: env.conf mode is $mode"
    return 1
  fi
  if ! grep -q "^AAOS_AI_GATE_TOP=" "$conf"; then
    note "i: AAOS_AI_GATE_TOP missing"
    return 1
  fi
  if ! grep -q "^AAOS_AI_GATE_URL=" "$conf"; then
    note "i: AAOS_AI_GATE_URL missing"
    return 1
  fi
  if grep -q 'AAOS_AI_GATE_STATE_FILE\|AAOS_AI_GATE_VERDICT_FILE\|AAOS_AI_GATE_NOTES\|AAOS_AI_GATE_CONTEXT\|AAOS_AI_GATE_MODE_FROM_ENV' "$conf"; then
    note "i: internal run variable leaked into env.conf"
    cat "$conf" >&2
    return 1
  fi
  if grep -q '^AAOS_AI_GATE_CLI_DIR=' "$conf"; then
    note "i: CLI dir was written in URL mode"
    return 1
  fi
  return 0
}

run_case() {
  local id=$1
  shift
  if "$@"; then
    printf 'OK %s\n' "$id"
    ok=$((ok + 1))
  else
    printf 'FAIL %s\n' "$id" >&2
    bad=$((bad + 1))
  fi
}

start_server || {
  echo "0 Tests, 1 fehlgeschlagen"
  exit 1
}

should a && run_case a case_a
should b && run_case b case_b
should c && run_case c case_c
should d && run_case d case_d
should e && run_case e case_e
should f && run_case f case_f
should g && run_case g case_g
should i && run_case i case_i

printf '%s Tests, %s fehlgeschlagen\n' "$ok" "$bad"
if [[ "$bad" -eq 0 && "$ok" -gt 0 ]]; then
  exit 0
fi
exit 1
