require_top() {
  if [[ -z "${TOP:-}" ]]; then
    printf '%s\n' "require_top: TOP fehlt" >&2
    return 1
  fi
}

_wrap_build() {
  local _rc
  "$@"
  _rc=$?
  printf 'WRAPPED rc=%s\n' "$_rc"
  return "$_rc"
}
