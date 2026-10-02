#!/bin/bash
# One screen per m, plus a local cache.
#
# run  — blocking pretest (default) or parallel suggest-only.
#        On Windows, parallel opens a dialog when the model has a suspicion.
# pre  — call the model only for changes it has not already seen.
# ask  — one follow-up on the same provider. Prints plain text.
# post — remember whether this exact tree compiled.
#
# A tree that already compiled is not sent again. A previous failure, a
# declined question, or compile=likely_fail does not lock the next m.
# Yes is remembered. No only stops this run. j starts the build anyway.
# parallel never aborts by itself. Ctrl-C and the IDE stop button do.
# A faster build cancels the in-flight request; the next m checks again.
# AAOS_AI_GATE=stop is the only hard refuse, and only for likely_fail.
# ccache is not loaded from the conf. That file is read only by m.
# mm, mmm, mma, mmma and make would otherwise see a different CC_WRAPPER.
set -u

byte_len() {
  local s=$1 n had=0 saved=
  if [[ -n "${LC_ALL+x}" ]]; then
    had=1
    saved=$LC_ALL
  fi
  LC_ALL=C
  n=${#s}
  if [[ "$had" -eq 1 ]]; then
    LC_ALL=$saved
  else
    unset LC_ALL
  fi
  printf '%s' "$n"
}

hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

cache_root() {
  printf '%s\n' "${AAOS_AI_GATE_CACHE:-${HOME}/.cache/aaos-ai-gate}"
}

memory_dir() {
  local root out
  root=${TOP:-$PWD}
  if [[ -n "${OUT_DIR:-}" ]]; then
    case "$OUT_DIR" in
      /*) out=$OUT_DIR ;;
      *) out=$root/$OUT_DIR ;;
    esac
  else
    out=$root/out
  fi
  printf '%s\n' "$out/.aaos-ai-gate"
}

publish_verdict() {
  local dest dir tmp
  [[ -n "${AAOS_AI_GATE_VERDICT_FILE:-}" ]] || return 0
  dest=$AAOS_AI_GATE_VERDICT_FILE
  dir=$(dirname "$dest")
  [[ -d "$dir" ]] || return 0
  tmp=$(mktemp "$dir/.verdict.XXXXXX") || return 0
  if ! printf '%s\n' "$1" > "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$dest"
}

append_note() {
  [[ -n "${AAOS_AI_GATE_NOTES:-}" ]] || return 0
  printf '%s\n' "$*" >> "$AAOS_AI_GATE_NOTES"
}

open_tty() {
  exec 9<>/dev/tty
}

close_tty() {
  exec 9>&-
}

windows_ui_available() {
  case "${AAOS_AI_GATE_WINDOWS_UI:-}" in
    off) return 1 ;;
    force) return 0 ;;
  esac
  [[ -r /proc/version ]] || return 1
  grep -qi microsoft /proc/version || return 1
  command -v powershell.exe >/dev/null 2>&1 || return 1
  command -v wslpath >/dev/null 2>&1 || return 1
}

dialog_suppressed() {
  [[ "${AAOS_AI_GATE_DIALOG:-}" == "off" ]] && return 0
  [[ -f "${TOP:-$PWD}/.aaos-ai-gate.dialog-off" ]] && return 0
  return 1
}

to_windows_path() {
  if [[ "${AAOS_AI_GATE_WINDOWS_UI:-}" == "force" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  wslpath -w "$1"
}

save_dialog_context() {
  local src=$1
  [[ -n "${AAOS_AI_GATE_CONTEXT:-}" && -f "$src" ]] || return 0
  head -c 24000 "$src" > "$AAOS_AI_GATE_CONTEXT" || true
}

offer_windows_dialog() {
  local verdict_file=$1
  local dest script ps win_script win_data root conf top ask compile runtime effect interesting
  [[ "${AAOS_AI_GATE_DIALOG_LAUNCHED:-}" == 1 ]] && return 0
  windows_ui_available || return 0
  dialog_suppressed && return 0
  command -v jq >/dev/null 2>&1 || return 0
  interesting=no
  if [[ -s "$verdict_file" ]]; then
    ask=$(jq -r '.ask // false' "$verdict_file" 2>/dev/null || printf 'false')
    compile=$(jq -r '.compile // "unknown"' "$verdict_file" 2>/dev/null || printf 'unknown')
    runtime=$(jq -r '.runtime // "unknown"' "$verdict_file" 2>/dev/null || printf 'unknown')
    effect=$(jq -r '.effect // "unknown"' "$verdict_file" 2>/dev/null || printf 'unknown')
    if [[ "$ask" == "true" || "$compile" == "likely_fail" || "$runtime" == "concern" || "$effect" == "unlikely" ]]; then
      interesting=yes
    fi
  fi
  if [[ "$interesting" == no && -s "${AAOS_AI_GATE_NOTES:-}" ]] && grep -q 'Hinweis:' "${AAOS_AI_GATE_NOTES}"; then
    interesting=yes
  fi
  [[ "$interesting" == yes ]] || return 0
  root=$(cd "$(dirname "$0")" && pwd)
  script=$root/aaos-ai-gate-dialog.ps1
  linux_gate=$root/ai-patch-gate.sh
  if [[ ! -f "$script" ]]; then
    echo "ai-patch-gate: Dialogskript fehlt, der Hinweis bleibt im Log"
    export AAOS_AI_GATE_DIALOG_LAUNCHED=1
    return 0
  fi
  dest=$(mktemp -d)
  chmod 700 "$dest" || true
  if [[ -s "$verdict_file" ]]; then
    cp "$verdict_file" "$dest/verdict.json"
    jq -r '
      "Verdacht zum aktuellen Diff. Der Build läuft weiter.\n",
      (if (.ask == true) and ((.question // "") | length) > 0 then "Rückfrage: " + .question else empty end),
      (if (.reason // "") != "" then "Begründung: " + .reason else empty end),
      "Compile: " + (.compile // "unknown"),
      "Laufzeit: " + (.runtime // "unknown"),
      "Effekt: " + (.effect // "unknown"),
      "",
      "Das Modell hat dafür keinen Beweis. Der Compiler prüft weiter."
    ' "$verdict_file" > "$dest/problem.txt"
  elif [[ -s "${AAOS_AI_GATE_NOTES:-}" ]]; then
    {
      printf '%s\n' "Hinweis aus dem laufenden Check. Der Build läuft weiter."
      cat "${AAOS_AI_GATE_NOTES}"
    } > "$dest/problem.txt"
  fi
  if [[ -s "${AAOS_AI_GATE_CONTEXT:-}" ]]; then
    cp "${AAOS_AI_GATE_CONTEXT}" "$dest/context.txt"
  else
    : > "$dest/context.txt"
  fi
  top=${TOP:-$PWD}
  conf=$top/.aaos-ai-gate.conf
  jq -n \
    --arg url "${AAOS_AI_GATE_URL:-}" \
    --arg token "${AAOS_AI_GATE_TOKEN:-}" \
    --arg model "${AAOS_AI_GATE_MODEL:-}" \
    --arg provider "${AAOS_AI_GATE_PROVIDER:-}" \
    --arg auth "${AAOS_AI_GATE_AUTH:-}" \
    --arg distro "${WSL_DISTRO_NAME:-}" \
    --arg linuxScript "$linux_gate" \
    --arg linuxConf "$conf" \
    --arg linuxData "$dest" \
    --arg conf "$(to_windows_path "$conf")" \
    --arg top "$(to_windows_path "$top")" \
    --arg marker "$(to_windows_path "$top/.aaos-ai-gate.dialog-off")" \
    --arg modeFromEnv "${AAOS_AI_GATE_MODE_FROM_ENV:-no}" \
    '{
       url:$url,
       model:$model,
       provider:$provider,
       auth:$auth,
       distro:$distro,
       linuxScript:$linuxScript,
       linuxConf:$linuxConf,
       linuxData:$linuxData,
       conf:$conf,
       top:$top,
       marker:$marker,
       modeFromEnv:$modeFromEnv
     }
     + (if $token == "" then {} else {token:$token} end)' \
    > "$dest/meta.json" || {
    rm -rf "$dest"
    return 0
  }
  export AAOS_AI_GATE_DIALOG_LAUNCHED=1
  echo "ai-patch-gate: Hinweisdialog wird geöffnet, der Build läuft weiter"
  if [[ "${AAOS_AI_GATE_WINDOWS_UI:-}" == "force" ]]; then
    ps=${AAOS_AI_GATE_POWERSHELL:-powershell.exe}
    "$ps" -File "$script" -DataDir "$dest" >/dev/null 2>&1 &
    disown "$!" 2>/dev/null || true
    return 0
  fi
  ps=$(command -v powershell.exe) || return 0
  win_script=$(to_windows_path "$script")
  win_data=$(to_windows_path "$dest")
  setsid "$ps" -NoProfile -STA -ExecutionPolicy Bypass -File "$win_script" -DataDir "$win_data" \
    </dev/null >/dev/null 2>&1 &
  disown "$!" 2>/dev/null || true
}

replay_notes() {
  [[ -s "${AAOS_AI_GATE_NOTES:-}" ]] || return 0
  if open_tty 2>/dev/null; then
    {
      printf '%s\n' "----- ai-patch-gate -----"
      cat "$AAOS_AI_GATE_NOTES"
      printf '%s\n' "-------------------------"
    } >&9
    close_tty
  else
    printf '%s\n' "----- ai-patch-gate -----"
    cat "$AAOS_AI_GATE_NOTES"
    printf '%s\n' "-------------------------"
  fi
}

conf_comment_ahead() {
  local tail=$1
  [[ "$tail" =~ ^[[:space:]]*# ]]
}

unquote_conf() {
  local s=$1 i=0 n ch out= state=0 tail
  s=${s#"${s%%[![:space:]]*}"}
  if [[ -z "$s" ]]; then
    printf ''
    return 0
  fi
  if [[ "$s" != \'* && "$s" != \"* ]]; then
    if [[ "$s" == *" #"* ]]; then
      s=${s%% #*}
      s=${s%"${s##*[![:space:]]}"}
    fi
    printf '%s' "$s"
    return 0
  fi
  n=${#s}
  local sq=\' dq=\" embed
  embed="${dq}${sq}${dq}"
  if [[ "$s" == \"* ]]; then
    i=1
    state=1
  fi
  while (( i < n )); do
    ch=${s:i:1}
    if [[ "$s" == \"* ]]; then
      if (( state == 1 )); then
        if [[ "$ch" == '\' ]]; then
          i=$((i + 1))
          if (( i < n )); then
            ch=${s:i:1}
            out+=$ch
          fi
        elif [[ "$ch" == '"' ]]; then
          state=0
        else
          out+=$ch
        fi
      else
        tail=${s:i}
        if conf_comment_ahead "$tail"; then
          break
        fi
        out+=$ch
      fi
      i=$((i + 1))
      continue
    fi
    if (( state == 0 )); then
      tail=${s:i}
      if conf_comment_ahead "$tail"; then
        break
      fi
      if [[ "$ch" == "'" ]]; then
        state=1
      elif [[ "${s:i:3}" == "$embed" ]]; then
        out+=\'
        i=$((i + 3))
        continue
      elif [[ "$ch" == '\' ]]; then
        i=$((i + 1))
        if (( i < n )); then
          ch=${s:i:1}
          out+=$ch
        fi
      else
        out+=$ch
      fi
    elif [[ "$ch" == "'" ]]; then
      state=0
    else
      out+=$ch
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

load_tree_conf() {
  local conf line key val ccache_warn lineno
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    conf=$1
  else
    conf=${TOP:-$PWD}/.aaos-ai-gate.conf
  fi
  [[ -f "$conf" ]] || return 0
  ccache_warn=0
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [[ "$line" == export[[:space:]]* ]]; then
      line=${line#export}
      line=${line#"${line%%[![:space:]]*}"}
    fi
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [[ "$line" != *=* ]]; then
      echo "ai-patch-gate: Konfiguration Zeile $lineno wird ignoriert" >&2
      continue
    fi
    key=${line%%=*}
    key=${key%"${key##*[![:space:]]}"}
    val=${line#*=}
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      echo "ai-patch-gate: Konfiguration Zeile $lineno wird ignoriert" >&2
      continue
    fi
    val=$(unquote_conf "$val")
    case "$key" in
      AAOS_AI_GATE|AAOS_AI_GATE_*) ;;
      USE_CCACHE|CCACHE_EXEC|CCACHE_DIR|CCACHE_MAXSIZE)
        ccache_warn=1
        continue
        ;;
      *) continue ;;
    esac
    if [[ -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done < "$conf"
  if [[ "$ccache_warn" -eq 1 ]]; then
    echo "ai-patch-gate: ccache in der Konfiguration wird ignoriert. USE_CCACHE muss in der Shell stehen, sonst sehen mm, mmm, mma, mmma und make einen anderen Wrapper. Soong und Kati erzeugen dann neu."
  fi
}

write_state() {
  local state_file=$1 state_id=$2 list=$3
  [[ -n "$state_file" && -n "$state_id" ]] || return 0
  {
    printf 'STATE %s\n' "$state_id"
    if [[ -s "$list" ]]; then
      awk -F '\t' '{printf "FILE %s\n", $1}' "$list"
    fi
  } > "$state_file"
}

finish_pre() {
  write_state "${AAOS_AI_GATE_STATE_FILE:-}" "$1" "$2"
  exit "$3"
}

find_workspace() {
  local dir=${TOP:-$PWD}
  if [[ -d "$dir/.repo" || -d "$dir/.git" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  dir=$PWD
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.repo" || -e "$dir/.git" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  printf '%s\n' "$PWD"
}

cmd_post() {
  local state_file=${AAOS_AI_GATE_STATE_FILE:-}
  local rc=${AAOS_AI_GATE_BUILD_RC:-}
  local cache state_id
  [[ -n "$state_file" && -f "$state_file" && -n "$rc" ]] || exit 0
  cache=$(cache_root)
  state_id=$(awk '/^STATE / {print $2; exit}' "$state_file")
  [[ -n "$state_id" ]] || exit 0
  if [[ "$rc" =~ ^[0-9]+$ ]] && [[ "$rc" -ge 128 ]]; then
    echo "ai-patch-gate: build aborted (rc=$rc), not recorded"
    exit 0
  fi
  mkdir -p "$cache/ledger" "$cache/files"
  printf '%s\n' "$rc" > "$cache/ledger/$state_id"
  if [[ "$rc" == 0 ]]; then
    awk '/^FILE / {print $2}' "$state_file" | while IFS= read -r fid; do
      [[ -n "$fid" ]] || continue
      printf 'build\n' > "$cache/files/$fid"
    done
  fi
  echo "ai-patch-gate: recorded build rc=$rc"
  exit 0
}

fail_line() {
  local kind=$1 text=$2
  if [[ "$kind" == "ask" ]]; then
    echo "ai-patch-gate: $text" >&2
  else
    echo "ai-patch-gate: $text, der Build startet trotzdem" >&2
  fi
}

say_jq_missing() {
  local msg="ai-patch-gate: jq fehlt, es wird nichts geprüft. Der Build startet trotzdem."
  echo "$msg" >&2
  if open_tty 2>/dev/null; then
    printf '%s\n' "$msg" >&9
    close_tty
  fi
}

verdict_system_prompt() {
  cat << 'EOF'
You screen one Android change before a full build. You do not know absolute truth. Reply with JSON only: {"compile":"ok|likely_fail|unknown","runtime":"ok|concern|unknown","effect":"likely|unlikely|unknown","ask":false,"question":"","reason":"..."}. compile likely_fail only for a definite compile break in the new diff. runtime concern only for a concrete foreseeable fault in the new diff, such as a null deref, use after free, missing unlock, wrong unit, or a condition that skips the change. effect compares the new diff with the intent inferred from this author recent commits, the stash, and the current change. effect unlikely only when the diff clearly misses that intent. Thin intent means effect unknown. ask true only when a person should confirm they meant it: a concrete runtime fault or a clear intent mismatch. question is one German sentence. Do not ask about style, naming, or mere uncertainty. Unknown generated code, includes, Soong, or hidden API stays unknown. If truncated is 1, the new diff was cut off.
EOF
}

ask_system_prompt() {
  cat << 'EOF'
Du hast einen Android-Diff vor einem Build nur als Hinweis gelesen. Du kennst keine absolute Wahrheit. Antworte auf Deutsch, kurz, und bleib bei dem Befund und dem Diff-Auszug. Erfinde keinen Compile-Lauf. Der Build des Nutzers läuft bereits weiter.
EOF
}

effective_auth() {
  local raw
  raw=$(printf '%s' "${AAOS_AI_GATE_AUTH:-}" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    token|api|api-token|apitoken) printf 'token' ;;
    subscription|abonnement|abo) printf 'subscription' ;;
    '')
      if [[ -z "${AAOS_AI_GATE_URL:-}" && -n "${AAOS_AI_GATE_TOKEN:-}" && -n "${AAOS_AI_GATE_PROVIDER:-}" ]]; then
        printf 'token'
      else
        printf 'subscription'
      fi
      ;;
    *) printf 'subscription' ;;
  esac
}

provider_name() {
  local raw
  raw=$(printf '%s' "${AAOS_AI_GATE_PROVIDER:-}" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    agy) printf 'antigravity' ;;
    *) printf '%s' "$raw" ;;
  esac
}

chosen_model() {
  local user auth provider
  user=${AAOS_AI_GATE_MODEL:-}
  if [[ -n "${AAOS_AI_GATE_URL:-}" ]]; then
    if [[ -z "$user" ]]; then
      user=default
    fi
    printf '%s' "$user"
    return 0
  fi
  if [[ -n "$user" && "$user" != "default" ]]; then
    printf '%s' "$user"
    return 0
  fi
  auth=$(effective_auth)
  provider=$(provider_name)
  case "$provider" in
    claude)
      if [[ "$auth" == "token" ]]; then
        printf '%s' 'claude-haiku-4-5'
      else
        printf '%s' 'haiku'
      fi
      ;;
    antigravity)
      if [[ "$auth" == "token" ]]; then
        printf '%s' 'gemini-3.8-flash'
      else
        printf '%s' 'gemini-3.8-flash-low'
      fi
      ;;
    *)
      printf ''
      ;;
  esac
}

run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 55 "$@"
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import subprocess, sys
p = subprocess.Popen(sys.argv[1:])
try:
    rc = p.wait(timeout=55)
except subprocess.TimeoutExpired:
    p.kill()
    p.wait()
    sys.exit(124)
sys.exit(rc if isinstance(rc, int) and rc >= 0 else 1)' "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( i >= 55 )); then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    i=$((i + 1))
  done
  wait "$pid"
}

http_post() {
  local url=$1 body=$2
  shift 2
  local cfg h rc
  cfg=$(mktemp)
  chmod 600 "$cfg" || true
  {
    printf '%s\n' 'silent'
    printf '%s\n' 'show-error'
    printf '%s\n' 'fail'
    printf '%s\n' 'max-time = 60'
    printf 'url = "%s"\n' "$url"
    for h in "$@"; do
      h=${h//\\/\\\\}
      h=${h//\"/\\\"}
      printf 'header = "%s"\n' "$h"
    done
  } > "$cfg"
  curl --config "$cfg" --data-binary @"$body"
  rc=$?
  rm -f "$cfg"
  return "$rc"
}

assistant_text() {
  local file=$1 picked
  if jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    picked=$(jq -r '
      if ((.choices[0].message.content? | type) == "string") and (.choices[0].message.content != "") then
        .choices[0].message.content
      elif ((.content[0].text? | type) == "string") and (.content[0].text != "") then
        .content[0].text
      elif (.candidates[0].content.parts? | type) == "array" then
        ([.candidates[0].content.parts[].text // empty] | join(""))
      else
        empty
      end
    ' "$file")
    if [[ -n "$picked" ]]; then
      printf '%s' "$picked"
      return 0
    fi
    jq -c . "$file"
    return 0
  fi
  cat "$file"
}

parse_verdict_text() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys, re
s = sys.stdin.read().strip()
s = re.sub(r"^```(?:json)?\s*", "", s)
s = re.sub(r"\s*```\s*$", "", s)
def emit(obj):
    if isinstance(obj, dict) and "compile" in obj:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
        raise SystemExit(0)
try:
    emit(json.loads(s))
except Exception:
    pass
start = s.find("{")
end = s.rfind("}")
if start >= 0 and end > start:
    try:
        emit(json.loads(s[start:end + 1]))
    except Exception:
        pass
raise SystemExit(1)
'
    return $?
  fi
  jq -Rsc '
    def unfence:
      sub("^[[:space:]]*```(json)?[[:space:]]*"; "") | sub("[[:space:]]*```[[:space:]]*$"; "");
    (unfence | fromjson? // empty) | select(type == "object" and has("compile"))
  '
}

anthropic_post() {
  local kind=$1 model=$2 system=$3 prompt_file=$4 out_file=$5
  local body rc max
  if ! command -v curl >/dev/null 2>&1; then
    fail_line "$kind" "curl fehlt"
    return 1
  fi
  max=1024
  if [[ "$kind" == "ask" ]]; then
    max=2048
  fi
  body=$(mktemp)
  jq -n --rawfile user "$prompt_file" --arg model "$model" --arg system "$system" --argjson max "$max" \
    '{model:$model, max_tokens:$max, system:$system, messages:[{role:"user", content:$user}]}' > "$body" || {
    rm -f "$body"
    fail_line "$kind" "die Anfrage liess sich nicht bauen"
    return 1
  }
  http_post "https://api.anthropic.com/v1/messages" "$body" \
    "x-api-key: ${AAOS_AI_GATE_TOKEN}" \
    "anthropic-version: 2023-06-01" \
    "content-type: application/json" > "$out_file"
  rc=$?
  rm -f "$body"
  if [[ "$rc" -ne 0 ]]; then
    fail_line "$kind" "Anfrage fehlgeschlagen"
    return 1
  fi
}

gemini_post() {
  local kind=$1 model=$2 system=$3 prompt_file=$4 out_file=$5
  local body rc mime url
  case "$model" in
    ''|*[!A-Za-z0-9._:-]*)
      fail_line "$kind" "der Modellname ist fuer diese Verbindung unbrauchbar"
      return 1
      ;;
  esac
  if ! command -v curl >/dev/null 2>&1; then
    fail_line "$kind" "curl fehlt"
    return 1
  fi
  mime=application/json
  if [[ "$kind" == "ask" ]]; then
    mime=text/plain
  fi
  body=$(mktemp)
  jq -n --rawfile user "$prompt_file" --arg system "$system" --arg mime "$mime" \
    '{systemInstruction:{parts:[{text:$system}]}, contents:[{role:"user", parts:[{text:$user}]}], generationConfig:{responseMimeType:$mime}}' > "$body" || {
    rm -f "$body"
    fail_line "$kind" "die Anfrage liess sich nicht bauen"
    return 1
  }
  url="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent"
  http_post "$url" "$body" \
    "x-goog-api-key: ${AAOS_AI_GATE_TOKEN}" \
    "Content-Type: application/json" > "$out_file"
  rc=$?
  rm -f "$body"
  if [[ "$rc" -ne 0 ]]; then
    fail_line "$kind" "Anfrage fehlgeschlagen"
    return 1
  fi
}

openai_post() {
  local kind=$1 model=$2 system=$3 prompt_file=$4 out_file=$5
  local body rc
  case "${AAOS_AI_GATE_URL}" in
    *\"*|*\\*)
      fail_line "$kind" "die URL enthaelt ein Zeichen, das hier nicht getragen wird"
      return 1
      ;;
  esac
  if [[ -z "${AAOS_AI_GATE_TOKEN:-}" ]]; then
    fail_line "$kind" "fuer die eigene URL fehlt das API-Token"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    fail_line "$kind" "curl fehlt"
    return 1
  fi
  body=$(mktemp)
  if [[ "$kind" == "ask" ]]; then
    jq -n --rawfile user "$prompt_file" --arg model "$model" --arg system "$system" \
      '{model:$model, messages:[{role:"system", content:$system},{role:"user", content:$user}]}' > "$body" || {
      rm -f "$body"
      fail_line "$kind" "die Anfrage liess sich nicht bauen"
      return 1
    }
  else
    jq -n --rawfile user "$prompt_file" --arg model "$model" --arg system "$system" \
      '{model:$model, response_format:{type:"json_object"}, messages:[{role:"system", content:$system},{role:"user", content:$user}]}' > "$body" || {
      rm -f "$body"
      fail_line "$kind" "die Anfrage liess sich nicht bauen"
      return 1
    }
  fi
  http_post "${AAOS_AI_GATE_URL}" "$body" \
    "Authorization: Bearer ${AAOS_AI_GATE_TOKEN}" \
    "Content-Type: application/json" > "$out_file"
  rc=$?
  rm -f "$body"
  if [[ "$rc" -ne 0 ]]; then
    fail_line "$kind" "Anfrage fehlgeschlagen"
    return 1
  fi
}

cli_claude() {
  local kind=$1 model=$2 system=$3 prompt_file=$4 out_file=$5 rc
  if ! command -v claude >/dev/null 2>&1; then
    fail_line "$kind" "claude ist nicht aufrufbar"
    return 1
  fi
  (
    cd /tmp || exit 97
    unset CLAUDECODE
    unset CLAUDE_CODE_ENTRYPOINT
    run_bounded claude -p \
      --tools "" \
      --permission-mode dontAsk \
      --permission-prompts none \
      --output-format text \
      --no-session-persistence \
      --system-prompt "$system" \
      --model "$model"
  ) < "$prompt_file" > "$out_file"
  rc=$?
  if [[ "$rc" -eq 124 ]]; then
    fail_line "$kind" "Zeitlimit (55 s) beim Aufruf von claude"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail_line "$kind" "Anmeldung oder Aufruf von claude ist fehlgeschlagen"
    return 1
  fi
}

cli_agy() {
  local kind=$1 model=$2 system=$3 prompt_file=$4 out_file=$5 wrapped rc
  if ! command -v agy >/dev/null 2>&1; then
    fail_line "$kind" "agy ist nicht aufrufbar"
    return 1
  fi
  wrapped=$(mktemp)
  {
    printf '%s\n\n' "$system"
    cat "$prompt_file"
  } > "$wrapped"
  (
    cd /tmp || exit 97
    run_bounded agy --print \
      --output-format text \
      --disable-slash-commands \
      --model "$model"
  ) < "$wrapped" > "$out_file"
  rc=$?
  rm -f "$wrapped"
  if [[ "$rc" -eq 124 ]]; then
    fail_line "$kind" "Zeitlimit (55 s) beim Aufruf von agy"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail_line "$kind" "Anmeldung oder Aufruf von agy ist fehlgeschlagen"
    return 1
  fi
}

cli_copilot() {
  local kind=$1 model=$2 system=$3 prompt_file=$4 out_file=$5 auth=$6 wrapped rc
  if ! command -v copilot >/dev/null 2>&1; then
    fail_line "$kind" "copilot ist nicht aufrufbar"
    return 1
  fi
  wrapped=$(mktemp)
  {
    printf '%s\n\n' "$system"
    cat "$prompt_file"
  } > "$wrapped"
  (
    cd /tmp || exit 97
    if [[ "$auth" == "token" ]]; then
      export COPILOT_GITHUB_TOKEN="${AAOS_AI_GATE_TOKEN}"
      unset GH_TOKEN
      unset GITHUB_TOKEN
    fi
    if [[ -n "$model" ]]; then
      run_bounded copilot -s --no-ask-user --model "$model"
    else
      run_bounded copilot -s --no-ask-user
    fi
  ) < "$wrapped" > "$out_file"
  rc=$?
  rm -f "$wrapped"
  if [[ "$rc" -eq 124 ]]; then
    fail_line "$kind" "Zeitlimit (55 s) beim Aufruf von copilot"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail_line "$kind" "Anmeldung oder Aufruf von copilot ist fehlgeschlagen"
    return 1
  fi
}

invoke_model() {
  local kind=$1 prompt_file=$2 out_file=$3
  local auth provider model system
  auth=$(effective_auth)
  provider=$(provider_name)
  model=$(chosen_model)
  if [[ "$kind" == "ask" ]]; then
    system=$(ask_system_prompt)
  else
    system=$(verdict_system_prompt)
  fi
  if [[ -n "${AAOS_AI_GATE_URL:-}" ]]; then
    openai_post "$kind" "$model" "$system" "$prompt_file" "$out_file"
    return $?
  fi
  case "$provider" in
    claude|copilot|antigravity) ;;
    *)
      fail_line "$kind" "kein Anbieter gesetzt"
      return 1
      ;;
  esac
  if [[ "$auth" == "token" && -z "${AAOS_AI_GATE_TOKEN:-}" ]]; then
    fail_line "$kind" "fuer die Anmeldung per API-Token fehlt das Token"
    return 1
  fi
  case "$provider" in
    claude)
      if [[ "$auth" == "token" ]]; then
        anthropic_post "$kind" "$model" "$system" "$prompt_file" "$out_file"
      else
        cli_claude "$kind" "$model" "$system" "$prompt_file" "$out_file"
      fi
      ;;
    antigravity)
      if [[ "$auth" == "token" ]]; then
        gemini_post "$kind" "$model" "$system" "$prompt_file" "$out_file"
      else
        cli_agy "$kind" "$model" "$system" "$prompt_file" "$out_file"
      fi
      ;;
    copilot)
      cli_copilot "$kind" "$model" "$system" "$prompt_file" "$out_file" "$auth"
      ;;
  esac
}

screen_with_model() {
  local prompt_file=$1 cache=$2 prompt_id=$3 state_id=$4 list=$5
  local truncated=$6 cached_n=$7 new_n=$8
  local out text verdict compile runtime effect reason
  if ! command -v jq >/dev/null 2>&1; then
    say_jq_missing
    finish_pre "$state_id" "$list" 0
  fi
  echo "ai-patch-gate: keeping ${cached_n} already compiled file(s), sending ${new_n} new file(s)"
  write_state "${AAOS_AI_GATE_STATE_FILE:-}" "$state_id" "$list"
  if [[ -n "${AAOS_AI_GATE_AWAITING:-}" ]]; then
    : > "$AAOS_AI_GATE_AWAITING"
  fi
  out=$(mktemp)
  if ! invoke_model verdict "$prompt_file" "$out"; then
    rm -f "${AAOS_AI_GATE_AWAITING:-}" "$out"
    finish_pre "$state_id" "$list" 0
  fi
  rm -f "${AAOS_AI_GATE_AWAITING:-}"
  text=$(assistant_text "$out" || true)
  rm -f "$out"
  verdict=$(printf '%s' "$text" | parse_verdict_text 2>/dev/null || true)
  if [[ -z "$verdict" ]]; then
    echo "ai-patch-gate: die Antwort war kein Urteil, der Build startet trotzdem" >&2
    finish_pre "$state_id" "$list" 0
  fi
  compile=$(printf '%s' "$verdict" | jq -r '.compile // "unknown"' 2>/dev/null || printf 'unknown')
  runtime=$(printf '%s' "$verdict" | jq -r '.runtime // "unknown"' 2>/dev/null || printf 'unknown')
  effect=$(printf '%s' "$verdict" | jq -r '.effect // "unknown"' 2>/dev/null || printf 'unknown')
  reason=$(printf '%s' "$verdict" | jq -r '.reason // ""' 2>/dev/null || true)
  if [[ "$compile" == "ok" || "$compile" == "likely_fail" || "$compile" == "unknown" ]]; then
    mkdir -p "$cache/prompts"
    printf '%s\n' "$verdict" > "$cache/prompts/$prompt_id"
  fi
  echo "ai-patch-gate: compile=$compile runtime=$runtime effect=$effect truncated=$truncated $reason"
  append_note "ai-patch-gate: compile=$compile runtime=$runtime effect=$effect truncated=$truncated $reason"
  publish_verdict "$verdict"
  if [[ "$compile" == "likely_fail" && "${AAOS_AI_GATE:-}" == "stop" ]]; then
    finish_pre "$state_id" "$list" 2
  fi
  finish_pre "$state_id" "$list" 0
}

cmd_ask() {
  local conf= context= question= history= prompt out text
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --conf)
        conf=${2:-}
        shift 2
        ;;
      --context)
        context=${2:-}
        shift 2
        ;;
      --question)
        question=${2:-}
        shift 2
        ;;
      --history)
        history=${2:-}
        shift 2
        ;;
      *)
        echo "ai-patch-gate: unbekannte Option: $1" >&2
        exit 1
        ;;
    esac
  done
  if [[ -n "$conf" ]]; then
    if [[ ! -f "$conf" ]]; then
      echo "ai-patch-gate: Konfiguration fehlt." >&2
      exit 1
    fi
    TOP=$(cd "$(dirname "$conf")" && pwd)
    export TOP
    load_tree_conf
  fi
  if [[ -z "$question" || ! -f "$question" ]]; then
    echo "ai-patch-gate: Frage fehlt." >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ai-patch-gate: jq fehlt." >&2
    exit 1
  fi
  prompt=$(mktemp)
  out=$(mktemp)
  {
    printf '%s\n' 'Befund und Diff, nur als Kontext:'
    if [[ -n "$context" && -f "$context" ]]; then
      head -c 24000 "$context"
      printf '\n'
    fi
    if [[ -n "$history" && -s "$history" ]]; then
      printf '\n%s\n' 'Bisheriger Verlauf:'
      cat "$history"
      printf '\n'
    fi
    printf '\n%s\n' 'Neue Frage:'
    cat "$question"
  } > "$prompt"
  if ! invoke_model ask "$prompt" "$out"; then
    rm -f "$prompt" "$out"
    exit 1
  fi
  text=$(assistant_text "$out" || true)
  rm -f "$prompt" "$out"
  if [[ -z "$text" ]]; then
    echo "ai-patch-gate: keine Antwort." >&2
    exit 1
  fi
  printf '%s\n' "$text"
}

gate_path_noise() {
  case "$1" in
    bin/ai-patch-gate.sh|*/bin/ai-patch-gate.sh|ai-patch-gate.sh) return 0 ;;
    bin/aaos-ai-gate-dialog.ps1|*/bin/aaos-ai-gate-dialog.ps1|aaos-ai-gate-dialog.ps1) return 0 ;;
    .aaos-ai-gate.conf|*/.aaos-ai-gate.conf|.aaos-ai-gate.dialog-off|*/.aaos-ai-gate.dialog-off) return 0 ;;
    *) return 1 ;;
  esac
}

hook_only_m() {
  local gitpath=$1 rel=$2 base=$3 leftover
  git -C "$gitpath" cat-file -e "$base:$rel" 2>/dev/null || return 1
  leftover=$(git -C "$gitpath" diff --no-ext-diff -U0 "$base" -- "$rel" 2>/dev/null | awk '
    /^(\+\+\+|---)/ { next }
    /^[+-]/ {
      line = substr($0, 2)
      if (line ~ /ai-patch-gate|AAOS_AI_GATE|_wrap_build|export TOP|soong_ui\.bash/) next
      if (line ~ /^[[:space:]]*(fi|exit \$\?)[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*$/) next
      print
    }
  ')
  [[ -z "$leftover" ]]
}

repo_is_clean() {
  local gitpath=$1 base=$2 line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path=${line:3}
    case "$path" in
      *" -> "*) path=${path##* -> } ;;
    esac
    if gate_path_noise "$path"; then
      continue
    fi
    case "$path" in
      bin/m|build/soong/bin/m)
        if hook_only_m "$gitpath" "$path" "$base"; then
          continue
        fi
        return 1
        ;;
    esac
    return 1
  done < <(git -C "$gitpath" status --porcelain --untracked-files=all 2>/dev/null)
  return 0
}

projects_fingerprint() {
  local workspace=$1 out
  if [[ -d "$workspace/.repo" ]] && command -v repo >/dev/null 2>&1; then
    out=$(cd "$workspace" && repo list -p 2>/dev/null || true)
    printf '%s\n' "$out" | hash_stdin
    return 0
  fi
  printf 'nogit\n'
}

stamp_path() {
  local cache=$1 workspace=$2 base=$3 target=$4 key
  key=$(printf '%s\n%s\n%s\n' "$workspace" "$base" "$target" | hash_stdin)
  printf '%s\n' "$cache/seen/$key"
}

save_clean_stamp() {
  local stamp=$1 projects=$2 state_id=$3 rev_file=$4
  mkdir -p "$(dirname "$stamp")"
  {
    printf 'PROJECTS %s\n' "$projects"
    printf 'STATE %s\n' "$state_id"
    awk '{ printf "REV %s\n", $0 }' "$rev_file"
  } > "$stamp"
}

try_fast_clean() {
  local cache=$1 workspace=$2 base=$3 target=$4
  local stamp projects_now projects_saved state_id tag rest path rev gitpath now saw
  stamp=$(stamp_path "$cache" "$workspace" "$base" "$target")
  [[ -f "$stamp" ]] || return 1
  projects_now=$(projects_fingerprint "$workspace")
  projects_saved=$(awk '/^PROJECTS / { print $2; exit }' "$stamp")
  [[ -n "$projects_saved" && "$projects_now" == "$projects_saved" ]] || return 1
  state_id=$(awk '/^STATE / { print $2; exit }' "$stamp")
  [[ -n "$state_id" ]] || return 1
  saw=0
  while read -r tag rest; do
    [[ "$tag" == "REV" ]] || continue
    saw=1
    path=${rest% *}
    rev=${rest##* }
    if [[ "$path" == "." ]]; then
      gitpath=$workspace
    elif [[ -d "$workspace/$path" ]]; then
      gitpath=$workspace/$path
    else
      return 1
    fi
    now=$(git -C "$gitpath" rev-parse HEAD 2>/dev/null || true)
    [[ "$now" == "$rev" ]] || return 1
    repo_is_clean "$gitpath" "$base" || return 1
  done < "$stamp"
  [[ "$saw" -eq 1 ]] || return 1
  printf '%s\n' "$state_id"
}

cmd_pre() {
  local cache base target workspace diff_file list summary send_file
  local rev_file collector state_id cached_n new_n max_bytes send_bytes
  local truncated prompt_file prompt_id verdict compile reason payload response
  local recorded extra fid display gitdir relpath file_diff piece piece_len
  local fast_state projects_now stamp

  if ! command -v git >/dev/null 2>&1; then
    echo "ai-patch-gate: git is required, building anyway" >&2
    exit 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    say_jq_missing
    exit 0
  fi

  cache=$(cache_root)
  base=${AAOS_AI_GATE_BASE:-HEAD}
  target="${TARGET_PRODUCT:-unset}-${TARGET_BUILD_VARIANT:-unset}"
  workspace=$(find_workspace)
  diff_file=$(mktemp)
  list=$(mktemp)
  summary=$(mktemp)
  send_file=$(mktemp)
  rev_file=$(mktemp)
  collector=$(mktemp)
  intent_file=$(mktemp)
  prompt_file=
  trap 'set +u; rm -f "$diff_file" "$list" "$summary" "$send_file" "$send_file.names" "$rev_file" "$collector" "$prompt_file" "$intent_file"' EXIT

  cat > "$collector" << 'COLLECT'
set -u
prefix=${REPO_PATH:-}
if [[ -n "$prefix" ]]; then
  prefix="${prefix%/}/"
fi
use_base=$AAOS_GATE_BASE
if ! git rev-parse --verify --quiet "$use_base^{commit}" >/dev/null; then
  use_base=HEAD
fi
printf '%s %s\n' "${REPO_PATH:-.}" "$(git rev-parse HEAD)" >> "$AAOS_GATE_REVS"
collect_one() {
  local rel=$1 display old new fid skip leftover
  [[ -n "$rel" ]] || return 0
  skip=${AAOS_GATE_SKIP:-out}
  case "$rel" in
    "$skip"|"$skip"/*|.aaos-ai-gate|.aaos-ai-gate/*|*/.aaos-ai-gate|*/.aaos-ai-gate/*)
      return 0
      ;;
  esac
  display="${prefix}${rel}"
  case "$display" in
    bin/ai-patch-gate.sh|*/bin/ai-patch-gate.sh|ai-patch-gate.sh) return 0 ;;
    bin/aaos-ai-gate-dialog.ps1|*/bin/aaos-ai-gate-dialog.ps1|aaos-ai-gate-dialog.ps1) return 0 ;;
    .aaos-ai-gate.conf|*/.aaos-ai-gate.conf|.aaos-ai-gate.dialog-off|*/.aaos-ai-gate.dialog-off) return 0 ;;
  esac
  case "$rel" in
    bin/m|build/soong/bin/m)
      if git cat-file -e "$use_base:$rel" 2>/dev/null; then
        leftover=$(git diff --no-ext-diff -U0 "$use_base" -- "$rel" | awk '
          /^(\+\+\+|---)/ { next }
          /^[+-]/ {
            line = substr($0, 2)
            if (line ~ /ai-patch-gate|AAOS_AI_GATE|_wrap_build|export TOP|soong_ui\.bash/) next
            if (line ~ /^[[:space:]]*(fi|exit \$\?)[[:space:]]*$/) next
            if (line ~ /^[[:space:]]*$/) next
            print
          }
        ')
        if [[ -z "$leftover" ]]; then
          return 0
        fi
      fi
      ;;
  esac
  old=$(git rev-parse "$use_base:$rel" 2>/dev/null || printf 'none')
  if [[ -e "$rel" ]]; then
    new=$(git hash-object "$rel" 2>/dev/null || printf 'none')
  else
    new=deleted
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    fid=$(printf '%s\0%s\0%s' "$display" "$old" "$new" | sha256sum | awk '{print $1}')
  else
    fid=$(printf '%s\0%s\0%s' "$display" "$old" "$new" | shasum -a 256 | awk '{print $1}')
  fi
  printf '%s\t%s\t%s\t%s\n' "$fid" "$display" "$PWD" "$rel" >> "$AAOS_GATE_LIST"
}
while IFS= read -r -d '' rel; do
  collect_one "$rel"
done < <(git diff --name-only --no-ext-diff -z "$use_base")
while IFS= read -r -d '' rel; do
  collect_one "$rel"
done < <(git ls-files --others --exclude-standard -z)
COLLECT

  export AAOS_GATE_BASE="$base"
  export AAOS_GATE_LIST="$list"
  export AAOS_GATE_REVS="$rev_file"
  export AAOS_GATE_SKIP=${OUT_DIR:-out}
  : > "$list"
  : > "$rev_file"
  fast_state=$(try_fast_clean "$cache" "$workspace" "$base" "$target" || true)
  if [[ -n "$fast_state" ]]; then
    if [[ -f "$cache/ledger/$fast_state" ]]; then
      recorded=$(tr -d '[:space:]' < "$cache/ledger/$fast_state")
      if [[ "$recorded" == 0 ]]; then
        echo "ai-patch-gate: this tree already compiled, not asking the model"
        finish_pre "$fast_state" "$list" 0
      fi
    fi
    echo "ai-patch-gate: no diff against $base, building"
    finish_pre "$fast_state" "$list" 0
  fi
  if [[ -d "$workspace/.repo" ]] && command -v repo >/dev/null 2>&1; then
    (
      cd "$workspace"
      repo forall -c "bash \"$collector\""
    ) || echo "ai-patch-gate: repo forall failed, looking at this git checkout only" >&2
  fi
  if [[ ! -s "$rev_file" ]]; then
    git_top=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
    (
      cd "$git_top"
      unset REPO_PATH
      bash "$collector"
    ) || {
      echo "ai-patch-gate: could not read the git diff, building anyway" >&2
      finish_pre "" "$list" 0
    }
  fi

  state_id=$(
    {
      printf '%s\n%s\n' "$base" "$target"
      sort "$rev_file"
      printf 'FILES\n'
      awk -F '\t' '{print $1}' "$list" | sort
    } | hash_stdin
  )

  projects_now=$(projects_fingerprint "$workspace")
  stamp=$(stamp_path "$cache" "$workspace" "$base" "$target")
  if [[ ! -s "$list" ]]; then
    save_clean_stamp "$stamp" "$projects_now" "$state_id" "$rev_file"
  else
    rm -f "$stamp"
  fi

  if [[ -f "$cache/ledger/$state_id" ]]; then
    recorded=$(tr -d '[:space:]' < "$cache/ledger/$state_id")
    if [[ "$recorded" == 0 ]]; then
      echo "ai-patch-gate: this tree already compiled, not asking the model"
      finish_pre "$state_id" "$list" 0
    fi
    echo "ai-patch-gate: dieser Stand ist schon einmal fehlgeschlagen (rc=$recorded). Der Build startet trotzdem."
    case "${AAOS_AI_GATE_MODE:-}" in
      parallel|suggest|suggest-only)
        append_note "ai-patch-gate: Hinweis: dieser Stand ist schon einmal fehlgeschlagen (rc=$recorded). Der Build startet trotzdem."
        ;;
    esac
    finish_pre "$state_id" "$list" 0
  fi

  if [[ ! -s "$list" ]]; then
    echo "ai-patch-gate: no diff against $base, building"
    finish_pre "$state_id" "$list" 0
  fi

  cached_n=0
  new_n=0
  : > "$summary"
  : > "$send_file.names"
  while IFS=$'\t' read -r fid display gitdir relpath; do
    [[ -n "$fid" ]] || continue
    if [[ -f "$cache/files/$fid" ]]; then
      cached_n=$((cached_n + 1))
      if [[ "$cached_n" -le 30 ]]; then
        printf '%s\n' "$display" >> "$summary"
      fi
    else
      new_n=$((new_n + 1))
      printf '%s\t%s\t%s\t%s\n' "$fid" "$display" "$gitdir" "$relpath" >> "$send_file.names"
    fi
  done < "$list"

  if [[ "$new_n" -eq 0 ]]; then
    echo "ai-patch-gate: ${cached_n} changed file(s) already compiled earlier, not asking the model"
    finish_pre "$state_id" "$list" 0
  fi

  max_bytes=${AAOS_AI_GATE_MAX_BYTES:-80000}
  send_bytes=0
  truncated=0
  : > "$send_file"
  while IFS=$'\t' read -r fid display gitdir relpath; do
    file_diff=$(
      cd "$gitdir" || exit 0
      if git cat-file -e "$base:$relpath" 2>/dev/null; then
        git diff --no-ext-diff -U20 "$base" -- "$relpath" || true
      elif [[ -e "$relpath" ]]; then
        git diff --no-index -- /dev/null "$relpath" || true
      else
        printf 'deleted file %s\n' "$display"
      fi
    )
    piece=$(printf '%s\n' "$file_diff")
    piece_len=$(byte_len "$piece")
    if [[ $((send_bytes + piece_len)) -gt $max_bytes && $send_bytes -gt 0 ]]; then
      truncated=1
      break
    fi
    if [[ $piece_len -gt $max_bytes ]]; then
      printf 'file %s\n' "$display" >> "$send_file"
      printf '%s' "$piece" | head -c "$max_bytes" >> "$send_file"
      printf '\n' >> "$send_file"
      truncated=1
      break
    fi
    printf 'file %s\n%s\n' "$display" "$piece" >> "$send_file"
    send_bytes=$((send_bytes + piece_len))
  done < "$send_file.names"

  extra=0
  if [[ "$cached_n" -gt 30 ]]; then
    extra=$((cached_n - 30))
  fi
  : > "$intent_file"
  author_email=$(git config --get user.email 2>/dev/null || true)
  author_name=$(git config --get user.name 2>/dev/null || true)
  {
    printf 'author: %s <%s>\n' "$author_name" "$author_email"
    printf 'recent commits by this author, stash, and the current diff are the only intent evidence.\n'
  } > "$intent_file"
  awk -F '\t' '{print $3}' "$list" | sort -u | head -8 | while IFS= read -r gitdir; do
    [[ -d "$gitdir" ]] || continue
    (
      cd "$gitdir" || exit 0
      printf '\nproject %s\n' "$gitdir"
      if [[ -n "$author_email" ]]; then
        git log -5 --author="$author_email" --format='%h %s' 2>/dev/null || true
      elif [[ -n "$author_name" ]]; then
        git log -5 --author="$author_name" --format='%h %s' 2>/dev/null || true
      fi
      printf 'stash:\n'
      git stash list --format='%gd %s' 2>/dev/null | head -3 || true
      if git rev-parse --verify --quiet 'stash@{0}' >/dev/null; then
        git stash show -p 'stash@{0}' 2>/dev/null | head -c 4000 || true
        printf '\n'
      fi
    ) >> "$intent_file"
  done
  head -c 12000 "$intent_file" > "$intent_file.cut"
  mv "$intent_file.cut" "$intent_file"
  prompt_file=$(mktemp)
  {
    printf 'intent sources:\n'
    cat "$intent_file"
    printf '\npreviously compiled at the same blobs, bodies omitted:\n'
    if [[ -s "$summary" ]]; then
      cat "$summary"
    else
      printf '(none)\n'
    fi
    if [[ "$extra" -gt 0 ]]; then
      printf 'and %s more already compiled files\n' "$extra"
    fi
    printf 'truncated: %s\n' "$truncated"
    printf 'new diff:\n'
    cat "$send_file"
  } > "$prompt_file"
  save_dialog_context "$prompt_file"
  prompt_id=$(hash_stdin < "$prompt_file")

  if [[ -f "$cache/prompts/$prompt_id" ]]; then
    verdict=$(cat "$cache/prompts/$prompt_id")
    compile=$(printf '%s' "$verdict" | jq -r '.compile // "unknown"' 2>/dev/null || printf 'unknown')
    reason=$(printf '%s' "$verdict" | jq -r '.reason // ""' 2>/dev/null || true)
    echo "ai-patch-gate: same new changes already reviewed, compile=$compile $reason"
    write_state "${AAOS_AI_GATE_STATE_FILE:-}" "$state_id" "$list"
    publish_verdict "$verdict"
    if [[ "$compile" == "likely_fail" && "${AAOS_AI_GATE:-}" == "stop" ]]; then
      finish_pre "$state_id" "$list" 2
    fi
    finish_pre "$state_id" "$list" 0
  fi

  screen_with_model "$prompt_file" "$cache" "$prompt_id" "$state_id" "$list" \
    "$truncated" "$cached_n" "$new_n"
}

kill_tree() {
  local pid=$1 sig=${2:-TERM} child
  [[ -n "$pid" ]] || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      kill_tree "$child" "$sig"
    done
  fi
  kill -"$sig" "$pid" 2>/dev/null || true
}

kill_group() {
  local pid=$1
  [[ -n "$pid" ]] || return 0
  kill_tree "$pid" TERM
  kill_tree "$pid" KILL
}

consider_verdict() {
  local verdict_file=$1 mem=$2 state_id=$3
  local ask question reason compile runtime effect key prior reply ans
  [[ -s "$verdict_file" ]] || return 0
  ask=$(jq -r '.ask // false' "$verdict_file" 2>/dev/null || printf 'false')
  question=$(jq -r '.question // ""' "$verdict_file" 2>/dev/null || true)
  reason=$(jq -r '.reason // ""' "$verdict_file" 2>/dev/null || true)
  compile=$(jq -r '.compile // "unknown"' "$verdict_file" 2>/dev/null || printf 'unknown')
  runtime=$(jq -r '.runtime // "unknown"' "$verdict_file" 2>/dev/null || printf 'unknown')
  effect=$(jq -r '.effect // "unknown"' "$verdict_file" 2>/dev/null || printf 'unknown')
  case "${AAOS_AI_GATE_MODE:-blocking}" in
    parallel|suggest|suggest-only)
      if [[ "$ask" == "true" && -n "$question" ]]; then
        echo "ai-patch-gate: Hinweis: $question"
        append_note "ai-patch-gate: Hinweis: $question"
        if [[ -n "$reason" ]]; then
          echo "ai-patch-gate: Hinweis: $reason"
          append_note "ai-patch-gate: Hinweis: $reason"
        fi
      fi
      if [[ "$compile" == "likely_fail" ]]; then
        echo "ai-patch-gate: Hinweis: sieht nicht kompilierbar aus. $reason"
        append_note "ai-patch-gate: Hinweis: sieht nicht kompilierbar aus. $reason"
      fi
      if [[ "$runtime" == "concern" ]]; then
        echo "ai-patch-gate: Hinweis: mögliche Laufzeitfolge. $reason"
        append_note "ai-patch-gate: Hinweis: mögliche Laufzeitfolge. $reason"
      fi
      if [[ "$effect" == "unlikely" ]]; then
        echo "ai-patch-gate: Hinweis: der Effekt passt voraussichtlich nicht zur Absicht. $reason"
        append_note "ai-patch-gate: Hinweis: der Effekt passt voraussichtlich nicht zur Absicht. $reason"
      fi
      return 0
      ;;
  esac
  if [[ "$compile" == "likely_fail" && "${AAOS_AI_GATE:-}" == "stop" ]]; then
    echo "ai-patch-gate: AAOS_AI_GATE=stop, sieht nicht kompilierbar aus. $reason"
    return 2
  fi
  if [[ "$compile" == "likely_fail" && ( "$ask" != "true" || -z "$question" ) ]]; then
    ask=true
    question="Sieht nicht kompilierbar aus. Trotzdem bauen?"
  fi
  if [[ "$ask" == "true" && -n "$question" ]]; then
    key=$(printf '%s\n%s\n%s' "$state_id" "$question" "$reason" | hash_stdin)
    prior=
    if [[ -f "$mem/answers" ]]; then
      prior=$(awk -F '\t' -v k="$key" '$1==k { print $2; exit }' "$mem/answers")
    fi
    if [[ "$prior" == "yes" ]]; then
      echo "ai-patch-gate: schon bestätigt, der Build startet"
      return 0
    fi
    if open_tty 2>/dev/null; then
      printf 'ai-patch-gate: %s\n' "$question" >&9
      if [[ -n "$reason" ]]; then
        printf 'ai-patch-gate: %s\n' "$reason" >&9
      fi
      if [[ "$compile" == "likely_fail" ]]; then
        printf '%s\n' "ai-patch-gate: j startet den Build, auch wenn das Modell einen Compile-Bruch erwartet. Der Compiler bleibt die Prüfung." >&9
      fi
      printf 'So beabsichtigt? [j/N] ' >&9
      read -r reply <&9 || reply=
      close_tty
      ans=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
      case "$ans" in
        j|ja|y|yes)
          mkdir -p "$mem"
          printf '%s\tyes\t%s\t%s\n' "$key" "$(date +%s)" "$question" >> "$mem/answers"
          echo "ai-patch-gate: bestätigt, der Build startet"
          return 0
          ;;
      esac
      echo "ai-patch-gate: abgelehnt, der Build startet nicht"
      return 2
    fi
    echo "ai-patch-gate: $question"
    echo "ai-patch-gate: kein Terminal, der Build startet"
    return 0
  fi
  return 0
}

cmd_block() {
  local rundir pre_rc build_rc state_id mem block_stopping
  export AAOS_AI_GATE_MODE=blocking
  mem=$(memory_dir)
  rundir=$(mktemp -d)
  block_stopping=0
  export AAOS_AI_GATE_STATE_FILE=$rundir/state
  export AAOS_AI_GATE_VERDICT_FILE=$rundir/verdict
  export AAOS_AI_GATE_NOTES=$rundir/notes
  block_stop() {
    [[ "$block_stopping" -eq 1 ]] && exit 130
    block_stopping=1
    trap - INT TERM
    rm -rf "$rundir"
    exit 130
  }
  trap block_stop INT TERM
  bash "$0" pre
  pre_rc=$?
  state_id=$(awk '/^STATE / {print $2; exit}' "$AAOS_AI_GATE_STATE_FILE" 2>/dev/null || true)
  if [[ -s "$AAOS_AI_GATE_VERDICT_FILE" ]]; then
    if ! consider_verdict "$AAOS_AI_GATE_VERDICT_FILE" "$mem" "$state_id"; then
      trap - INT TERM
      rm -rf "$rundir"
      exit 2
    fi
  fi
  if [[ "$pre_rc" -ne 0 ]]; then
    trap - INT TERM
    rm -rf "$rundir"
    exit "$pre_rc"
  fi
  "$@"
  build_rc=$?
  trap - INT TERM
  if [[ "$build_rc" -ge 128 ]]; then
    rm -rf "$rundir"
    exit "$build_rc"
  fi
  if [[ -s "$AAOS_AI_GATE_STATE_FILE" ]]; then
    AAOS_AI_GATE_BUILD_RC=$build_rc "$0" post || true
  fi
  rm -rf "$rundir"
  exit "$build_rc"
}

cmd_drive() {
  local mem rundir gate_pid build_pid build_rc asked aborted state_id drive_stopping
  if [[ $# -lt 1 ]]; then
    echo "ai-patch-gate: drive needs a build command" >&2
    exit 1
  fi
  export AAOS_AI_GATE_MODE=parallel
  mem=$(memory_dir)
  rundir=$(mktemp -d)
  gate_pid=
  build_pid=
  drive_stopping=0
  export AAOS_AI_GATE_STATE_FILE=$rundir/state
  export AAOS_AI_GATE_VERDICT_FILE=$rundir/verdict
  export AAOS_AI_GATE_AWAITING=$rundir/awaiting-model
  export AAOS_AI_GATE_NOTES=$rundir/notes
  export AAOS_AI_GATE_CONTEXT=$rundir/context
  drive_stop() {
    [[ "$drive_stopping" -eq 1 ]] && exit 130
    drive_stopping=1
    trap - INT TERM
    kill_tree "$build_pid" INT
    kill_tree "$gate_pid" TERM
    sleep 0.2
    kill_tree "$build_pid" KILL
    kill_tree "$gate_pid" KILL
    [[ -n "$build_pid" ]] && wait "$build_pid" 2>/dev/null || true
    [[ -n "$gate_pid" ]] && wait "$gate_pid" 2>/dev/null || true
    rm -rf "$rundir"
    exit 130
  }
  trap drive_stop INT TERM
  bash "$0" pre &
  gate_pid=$!
  "$@" &
  build_pid=$!
  asked=0
  aborted=0
  while kill -0 "$build_pid" 2>/dev/null; do
    if [[ "$asked" -eq 0 && -s "$AAOS_AI_GATE_VERDICT_FILE" ]]; then
      state_id=$(awk '/^STATE / {print $2; exit}' "$AAOS_AI_GATE_STATE_FILE" 2>/dev/null || true)
      if ! consider_verdict "$AAOS_AI_GATE_VERDICT_FILE" "$mem" "$state_id"; then
        aborted=1
        kill_tree "$build_pid" TERM
        break
      fi
      offer_windows_dialog "$AAOS_AI_GATE_VERDICT_FILE"
      asked=1
    fi
    sleep 0.2
  done
  wait "$build_pid" 2>/dev/null
  build_rc=$?

  if [[ "$aborted" -eq 1 ]]; then
    kill_tree "$gate_pid" TERM
    wait "$gate_pid" 2>/dev/null || true
    trap - INT TERM
    rm -rf "$rundir"
    exit 2
  fi

  if kill -0 "$gate_pid" 2>/dev/null; then
    if [[ -s "$AAOS_AI_GATE_VERDICT_FILE" ]]; then
      wait "$gate_pid" 2>/dev/null || true
    else
      kill_tree "$gate_pid" TERM
      sleep 0.2
      kill_tree "$gate_pid" KILL
      wait "$gate_pid" 2>/dev/null || true
      echo "ai-patch-gate: Modell-Anfrage abgebrochen, der nächste m prüft erneut"
      append_note "ai-patch-gate: Modell-Anfrage abgebrochen, der nächste m prüft erneut"
    fi
  else
    wait "$gate_pid" 2>/dev/null || true
  fi

  if [[ "$asked" -eq 0 && -s "${AAOS_AI_GATE_VERDICT_FILE:-}" ]]; then
    state_id=$(awk '/^STATE / {print $2; exit}' "$AAOS_AI_GATE_STATE_FILE" 2>/dev/null || true)
    consider_verdict "$AAOS_AI_GATE_VERDICT_FILE" "$mem" "$state_id" || true
  fi

  offer_windows_dialog "${AAOS_AI_GATE_VERDICT_FILE:-}"
  if [[ "$build_rc" -ge 128 ]]; then
    trap - INT TERM
    rm -rf "$rundir"
    exit "$build_rc"
  fi
  if [[ -s "$AAOS_AI_GATE_STATE_FILE" ]]; then
    AAOS_AI_GATE_BUILD_RC=$build_rc "$0" post || true
  fi
  replay_notes
  trap - INT TERM
  rm -rf "$rundir"
  exit "$build_rc"
}

cmd_run() {
  if [[ -n "${AAOS_AI_GATE_MODE+x}" ]]; then
    export AAOS_AI_GATE_MODE_FROM_ENV=yes
  else
    export AAOS_AI_GATE_MODE_FROM_ENV=no
  fi
  load_tree_conf
  case "${AAOS_AI_GATE_MODE:-blocking}" in
    parallel|suggest|suggest-only)
      cmd_drive "$@"
      ;;
    *)
      cmd_block "$@"
      ;;
  esac
}

case "${1:-pre}" in
  pre) cmd_pre ;;
  post) cmd_post ;;
  ask)
    shift
    cmd_ask "$@"
    ;;
  drive)
    shift
    if [[ "${1:-}" == "--" ]]; then
      shift
    fi
    cmd_drive "$@"
    ;;
  run)
    shift
    if [[ "${1:-}" == "--" ]]; then
      shift
    fi
    cmd_run "$@"
    ;;
  *)
    echo "ai-patch-gate: unknown command ${1}, building anyway" >&2
    exit 0
    ;;
esac
