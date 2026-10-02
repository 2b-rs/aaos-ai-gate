# Grafischer Installer. Nur Windows PowerShell, Apartment STA.
# Schreibt ausschliesslich in den angegebenen AAOS-Quellbaum.
# Die Windows-Benutzerumgebung wird nicht veraendert.
$ErrorActionPreference = 'Stop'

$script:WantUninstall = $false
foreach ($a in $args) {
  if ($a -eq '-Uninstall') { $script:WantUninstall = $true }
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if ($script:WantUninstall) {
    $childArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + @($args)
    & $hostExe @childArgs
    exit $LASTEXITCODE
  }
  $quotedFile = '"' + ($PSCommandPath -replace '"', '""') + '"'
  $arg = "-NoProfile -STA -File $quotedFile"
  foreach ($a in $args) {
    $arg += ' "' + (([string]$a) -replace '"', '""') + '"'
  }
  $proc = Start-Process -FilePath $hostExe -ArgumentList $arg -Wait -PassThru
  exit $proc.ExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:Payload = Join-Path $PSScriptRoot 'ai-patch-gate.sh'

function Quote-Bash([string]$Value) {
  return "'" + ($Value -replace "'", "'\''") + "'"
}

function Quote-PowerShell([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Get-TreeKind([string]$Tree) {
  $full = [System.IO.Path]::GetFullPath($Tree)
  if ($full -match '^(?<root>\\\\wsl\$|\\\\wsl\.localhost)\\(?<distro>[^\\]+)\\(?<rest>.*)$') {
    $linux = '/' + ($Matches.rest -replace '\\', '/')
    return @{ Kind = 'wsl'; Distro = $Matches.distro; Linux = $linux.TrimEnd('/'); Windows = $full }
  }
  if ($full -match '^[A-Za-z]:\\') {
    $drive = $full.Substring(0, 1).ToLower()
    $rest = $full.Substring(2) -replace '\\', '/'
    return @{ Kind = 'windows'; Distro = ''; Linux = "/mnt/$drive$rest".TrimEnd('/'); Windows = $full }
  }
  return @{ Kind = 'other'; Distro = ''; Linux = ''; Windows = $full }
}

function Test-AaosTree([string]$Tree) {
  foreach ($rel in @(
    'build\soong\bin\m',
    'build\soong\soong_ui.bash',
    'build\envsetup.sh'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $Tree $rel))) {
      return $false
    }
  }
  return $true
}

function Get-HookSpan([string]$Text) {
  $marker = 'if [[ -f "$TOP/.aaos-ai-gate.conf"'
  $start = $Text.IndexOf($marker)
  if ($start -lt 0) { return $null }
  $lineStart = $Text.LastIndexOf("`n", $start)
  if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart += 1 }
  $m = [regex]::Match($Text.Substring($start), '\n[ \t]*fi\r?\n')
  if (-not $m.Success) { return $null }
  $end = $start + $m.Index + $m.Length
  $chunk = $Text.Substring($lineStart, $end - $lineStart)
  if (-not $chunk.Contains('ai-patch-gate.sh')) { return $null }
  if ($end -lt $Text.Length -and $Text[$end] -eq "`n") { $end += 1 }
  return @{ Start = $lineStart; End = $end }
}

function Update-BuildEntry([string]$Text) {
  $block = @'
if [[ -f "$TOP/.aaos-ai-gate.conf" || -n "${AAOS_AI_GATE:-}" || -n "${AAOS_AI_GATE_MODE:-}" ]]; then
  export TOP
  _wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \
    "$TOP/build/soong/soong_ui.bash" --build-mode --all-modules --dir="$(pwd)" "$@"
  exit $?
fi

'@
  $wrapGate = '_wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run --'
  if ($Text.Contains($wrapGate) -and $Text.Contains('export TOP')) {
    return @{ Text = $Text; Status = 'vorhanden' }
  }
  $span = Get-HookSpan $Text
  if ($null -ne $span) {
    $newText = $Text.Remove($span.Start, $span.End - $span.Start).Insert($span.Start, $block)
    if ($newText -ceq $Text) {
      return @{ Text = $newText; Status = 'vorhanden' }
    }
    return @{ Text = $newText; Status = 'aktualisiert' }
  }
  if ($Text.Contains('ai-patch-gate.sh" run') -or $Text.Contains('ai-patch-gate.sh" drive')) {
    if (-not $Text.Contains('export TOP')) {
      return @{ Text = $Text; Status = 'vorhanden, ohne export TOP' }
    }
    return @{ Text = $Text; Status = 'vorhanden, Hook unvollstaendig' }
  }
  $needle = '_wrap_build "$TOP/build/soong/soong_ui.bash"'
  $idx = $Text.IndexOf($needle)
  if ($idx -lt 0) {
    return @{ Text = $Text; Status = 'fehlt' }
  }
  $lineStart = $Text.LastIndexOf("`n", $idx)
  if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart += 1 }
  return @{ Text = $Text.Insert($lineStart, $block); Status = 'eingefuegt' }
}

function Invoke-WslCommand([string]$Distro, [string]$Bash) {
  $prevEnc = [Console]::OutputEncoding
  $prevWsl = [Environment]::GetEnvironmentVariable('WSL_UTF8', 'Process')
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Environment]::SetEnvironmentVariable('WSL_UTF8', '1', 'Process')
    if ($Distro) {
      $null = & wsl.exe -d $Distro -e bash -lc $Bash
    } else {
      $null = & wsl.exe -e bash -lc $Bash
    }
    return [int]$LASTEXITCODE
  } finally {
    [Console]::OutputEncoding = $prevEnc
    [Environment]::SetEnvironmentVariable('WSL_UTF8', $prevWsl, 'Process')
  }
}

function Invoke-WslCapture([string]$Distro, [string]$Bash) {
  $prevEnc = [Console]::OutputEncoding
  $prevWsl = [Environment]::GetEnvironmentVariable('WSL_UTF8', 'Process')
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Environment]::SetEnvironmentVariable('WSL_UTF8', '1', 'Process')
    if ($Distro) {
      $out = & wsl.exe -d $Distro -e bash -lc $Bash
    } else {
      $out = & wsl.exe -e bash -lc $Bash
    }
    $script:LastWslExit = $LASTEXITCODE
    return $out
  } finally {
    [Console]::OutputEncoding = $prevEnc
    [Environment]::SetEnvironmentVariable('WSL_UTF8', $prevWsl, 'Process')
  }
}

function Set-LinuxMode([hashtable]$Loc, [string]$LinuxPath, [string]$Mode) {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    return "wsl.exe fehlt. In der Distribution ausfuehren: chmod $Mode $LinuxPath"
  }
  $q = Quote-Bash $LinuxPath
  $code = Invoke-WslCommand $Loc.Distro "chmod $Mode $q"
  if ($code -ne 0) {
    return "chmod $Mode fehlgeschlagen. In WSL ausfuehren: chmod $Mode $LinuxPath"
  }
  return ''
}

function Test-DistroCommand([hashtable]$Loc, [string]$Bash) {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
  $code = Invoke-WslCommand $Loc.Distro $Bash
  return ([int]$code -eq 0)
}

function Hide-GateFromGit([hashtable]$Loc) {
  if (-not $Loc.Linux) { return '' }
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return '' }
  $bash = @'
tree=__TREE__
soong="$tree/build/soong"
if [ -e "$soong/.git" ]; then
  gitdir=$(git -C "$soong" rev-parse --git-dir 2>/dev/null || true)
  if [ -n "$gitdir" ]; then
    case "$gitdir" in
      /*) ;;
      *) gitdir="$soong/$gitdir" ;;
    esac
    mkdir -p "$gitdir/info"
    touch "$gitdir/info/exclude"
    for name in bin/ai-patch-gate.sh bin/aaos-ai-gate-dialog.ps1; do
      grep -qxF "$name" "$gitdir/info/exclude" || printf '%s\n' "$name" >> "$gitdir/info/exclude"
    done
    if git -C "$soong" ls-files --error-unmatch -- bin/m >/dev/null 2>&1; then
      git -C "$soong" update-index --skip-worktree -- bin/m
      echo SKIP
    fi
  fi
fi
if [ -d "$tree/.git" ]; then
  mkdir -p "$tree/.git/info"
  touch "$tree/.git/info/exclude"
  for name in .aaos-ai-gate.conf .aaos-ai-gate.dialog-off; do
    grep -qxF "$name" "$tree/.git/info/exclude" || printf '%s\n' "$name" >> "$tree/.git/info/exclude"
  done
fi
'@
  $bash = $bash.Replace('__TREE__', (Quote-Bash $Loc.Linux))
  $out = Invoke-WslCapture $Loc.Distro $bash
  if (($out -join "`n") -match 'SKIP') {
    return "build/soong/bin/m ist mit skip-worktree markiert. Rueckgaengig: git -C build/soong update-index --no-skip-worktree bin/m"
  }
  return ''
}

function Uninstall-GatePath([string]$Tree) {
  if (-not (Test-AaosTree $Tree)) {
    throw 'Das ist kein AAOS/AOSP-Quellbaum. Erwartet werden build/soong/bin/m, build/soong/soong_ui.bash und build/envsetup.sh.'
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $mPath = Join-Path $Tree 'build\soong\bin\m'
  $text = [System.IO.File]::ReadAllText($mPath)
  $start = $text.IndexOf('if [[ -f "$TOP/.aaos-ai-gate.conf"')
  if ($start -ge 0) {
    $span = Get-HookSpan $text
    if ($null -eq $span) {
      throw 'Hook unvollstaendig, m bleibt unveraendert. Skripte und Konfiguration bleiben.'
    }
    $text = $text.Remove($span.Start, $span.End - $span.Start)
    [System.IO.File]::WriteAllText($mPath, $text, $utf8)
  }
  $ccacheWarn = ''
  $confBefore = Join-Path $Tree '.aaos-ai-gate.conf'
  if (Test-Path -LiteralPath $confBefore) {
    $confText = [System.IO.File]::ReadAllText($confBefore)
    if ($confText -match '(?m)^(USE_CCACHE|CCACHE_EXEC|CCACHE_DIR|CCACHE_MAXSIZE)=') {
      $ccacheWarn = ' Die Konfiguration stammte aus einer frueheren Version und enthielt ccache. Der naechste Build sieht den Wrapper nicht mehr, wenn ~/.bashrc ihn nicht setzt. Dann aendert sich CC_WRAPPER, Soong und Kati erzeugen neu, und der Compile laeuft kalt.'
    }
  }
  foreach ($rel in @(
    'build\soong\bin\ai-patch-gate.sh',
    'build\soong\bin\aaos-ai-gate-dialog.ps1',
    '.aaos-ai-gate.conf',
    '.aaos-ai-gate.dialog-off'
  )) {
    $p = Join-Path $Tree $rel
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
  }
  $loc = Get-TreeKind $Tree
  if ($loc.Linux -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    $bash = @'
tree=__TREE__
soong="$tree/build/soong"
strip() {
  file=$1
  name=$2
  [ -f "$file" ] || return 0
  grep -vxF "$name" "$file" > "$file.tmp"
  rc=$?
  if [ "$rc" -gt 1 ]; then
    rm -f "$file.tmp"
    return "$rc"
  fi
  cp "$file.tmp" "$file"
  rm -f "$file.tmp"
}
if [ -e "$soong/.git" ]; then
  gitdir=$(git -C "$soong" rev-parse --git-dir 2>/dev/null || true)
  if [ -n "$gitdir" ]; then
    case "$gitdir" in
      /*) ;;
      *) gitdir="$soong/$gitdir" ;;
    esac
    strip "$gitdir/info/exclude" "bin/ai-patch-gate.sh"
    strip "$gitdir/info/exclude" "bin/aaos-ai-gate-dialog.ps1"
    if git -C "$soong" ls-files -v -- bin/m 2>/dev/null | grep -q "^S"; then
      git -C "$soong" update-index --no-skip-worktree -- bin/m || true
    fi
  fi
fi
if [ -d "$tree/.git" ]; then
  strip "$tree/.git/info/exclude" ".aaos-ai-gate.conf"
  strip "$tree/.git/info/exclude" ".aaos-ai-gate.dialog-off"
fi
'@
    $bash = $bash.Replace('__TREE__', (Quote-Bash $loc.Linux))
    $null = Invoke-WslCommand $loc.Distro $bash
  }
  return "Gate aus $Tree entfernt. Skripte, Hook und Konfiguration sind weg. Der Diff-Cache und out/ bleiben.$ccacheWarn"
}

function Get-ManualHook {
  return @'
m enthaelt nicht die erwartete Zeile _wrap_build "$TOP/build/soong/soong_ui.bash".
Das Skript liegt in build/soong/bin/ai-patch-gate.sh. Diese Zeilen von Hand davor setzen:

if [[ -f "$TOP/.aaos-ai-gate.conf" || -n "${AAOS_AI_GATE:-}" || -n "${AAOS_AI_GATE_MODE:-}" ]]; then
  export TOP
  _wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \
    "$TOP/build/soong/soong_ui.bash" --build-mode --all-modules --dir="$(pwd)" "$@"
  exit $?
fi
'@
}

function Get-ProviderLabel([string]$Provider) {
  switch ($Provider) {
    'claude' { return 'Claude' }
    'copilot' { return 'Microsoft Copilot' }
    'antigravity' { return 'Antigravity' }
    default { return $Provider }
  }
}

function Get-AuthLabel([string]$Auth) {
  if ($Auth -eq 'token') { return 'API-Token' }
  return 'Abonnement'
}

function Get-CliProbe([string]$Distro) {
  $label = 'der Standard-Distribution'
  $key = ''
  if ($Distro) {
    $label = $Distro
    $key = $Distro
  }
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    return @{ Known = $false; DistroLabel = $label; DistroKey = $key; Found = @(); Reason = 'nowsl' }
  }
  $bash = "command -v claude >/dev/null 2>&1 && printf '%s\n' claude; command -v copilot >/dev/null 2>&1 && printf '%s\n' copilot; command -v agy >/dev/null 2>&1 && printf '%s\n' antigravity"
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = Invoke-WslCapture $Distro $bash
    $code = $script:LastWslExit
  } finally {
    $ErrorActionPreference = $prev
  }
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($out)) {
    $name = ([string]$line).Trim()
    if ($name -eq 'claude' -or $name -eq 'copilot' -or $name -eq 'antigravity') {
      if (-not $found.Contains($name)) { [void]$found.Add($name) }
    }
  }
  if ($code -ne 0 -and $found.Count -eq 0) {
    return @{ Known = $false; DistroLabel = $label; DistroKey = $key; Found = @(); Reason = 'fail' }
  }
  return @{ Known = $true; DistroLabel = $label; DistroKey = $key; Found = @($found); Reason = '' }
}

function Get-DetectSentence($Probe) {
  if ($Probe.Reason -eq 'nowsl') {
    return 'wsl.exe fehlt. Kommandozeilen konnten nicht gesucht werden.'
  }
  if (-not $Probe.Known) {
    return "Kommandozeilen in $($Probe.DistroLabel) konnten nicht gesucht werden."
  }
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($id in @($Probe.Found)) {
    if ($id -eq 'claude' -or $id -eq 'copilot' -or $id -eq 'antigravity') {
      [void]$names.Add((Get-ProviderLabel $id))
    }
  }
  if ($names.Count -eq 0) {
    return "In $($Probe.DistroLabel) keine Kommandozeile gefunden. Ein Abonnement braucht claude, copilot oder agy. Ein API-Token fuer Claude oder Antigravity kommt ohne sie aus. Microsoft Copilot braucht copilot auch mit Token."
  }
  return "In $($Probe.DistroLabel) gefunden: $(($names -join ', '))."
}

function Update-CliProbeFromTree {
  $tree = ''
  if ($script:TxtTree) { $tree = $script:TxtTree.Text.Trim() }
  $distro = ''
  if ($tree) {
    $loc = Get-TreeKind $tree
    if ($loc.Kind -eq 'wsl') { $distro = $loc.Distro }
  }
  $probe = Get-CliProbe $distro
  $script:LastProbe = $probe
  $known = [bool]$probe.Known
  $found = @($probe.Found)
  $ids = @('claude', 'copilot', 'antigravity')
  $index = 0
  if ($script:CmbProvider.SelectedIndex -ge 0) { $index = $script:CmbProvider.SelectedIndex }
  if (-not $script:ProviderTouched -and $known) {
    $prefer = -1
    foreach ($id in $ids) {
      if ($found -contains $id) { $prefer = [array]::IndexOf($ids, $id); break }
    }
    if ($prefer -ge 0) { $index = $prefer }
  }
  $script:ProviderUpdating = $true
  $script:CmbProvider.Items.Clear()
  foreach ($id in $ids) {
    $caption = Get-ProviderLabel $id
    if ($known) {
      if ($found -contains $id) { $caption += ' (installiert)' }
      else { $caption += ' (nicht gefunden)' }
    }
    [void]$script:CmbProvider.Items.Add($caption)
  }
  if ($index -lt 0 -or $index -ge $script:CmbProvider.Items.Count) { $index = 0 }
  $script:CmbProvider.SelectedIndex = $index
  $script:ProviderUpdating = $false
  $script:LblDetect.Text = Get-DetectSentence $probe
  Sync-InstallerLayout
}

function Get-GatePairs([string]$Mode, [string]$Provider, [string]$Auth, [string]$Url, [string]$Token, [string]$Model) {
  $pairs = @()
  $pairs += @{ Key = 'AAOS_AI_GATE'; Value = 'on' }
  $pairs += @{ Key = 'AAOS_AI_GATE_MODE'; Value = $Mode }
  if ($Url) {
    $pairs += @{ Key = 'AAOS_AI_GATE_URL'; Value = $Url }
    $pairs += @{ Key = 'AAOS_AI_GATE_TOKEN'; Value = $Token }
    if (-not $Model) { $Model = 'default' }
    $pairs += @{ Key = 'AAOS_AI_GATE_MODEL'; Value = $Model }
  } else {
    $pairs += @{ Key = 'AAOS_AI_GATE_PROVIDER'; Value = $Provider }
    $pairs += @{ Key = 'AAOS_AI_GATE_AUTH'; Value = $Auth }
    if ($Auth -eq 'token') {
      $pairs += @{ Key = 'AAOS_AI_GATE_TOKEN'; Value = $Token }
    }
    if ($Model -and $Model -ne 'default') {
      $pairs += @{ Key = 'AAOS_AI_GATE_MODEL'; Value = $Model }
    }
  }
  return ,$pairs
}

function Get-WhoLine([string]$Provider, [string]$Auth, [string]$Url, [string]$Model) {
  if ($Url) {
    $line = 'Eigene Verbindung. Anmeldung: API-Token.'
  } else {
    $line = "Anbieter: $(Get-ProviderLabel $Provider), Anmeldung: $(Get-AuthLabel $Auth)."
  }
  if ($Model -and $Model -ne 'default') {
    $line += " Modell: $Model."
  }
  return $line
}

function Get-SelfGuide([string]$Mode, [string]$Provider, [string]$Auth, [string]$Url, [string]$Token, [string]$Model, [bool]$Ccache, [string]$CcacheExec, [string]$CcacheDir, [string]$CcacheSize, [string]$CcacheNote) {
  $pairs = Get-GatePairs $Mode $Provider $Auth $Url $Token $Model
  $bash = New-Object System.Collections.Generic.List[string]
  $ps = New-Object System.Collections.Generic.List[string]
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($pair in $pairs) {
    $bash.Add("export $($pair.Key)=$(Quote-Bash $pair.Value)")
    $ps.Add("[Environment]::SetEnvironmentVariable('$( $pair.Key )', $(Quote-PowerShell $pair.Value), 'User')")
    $names.Add($pair.Key)
  }
  $names.Add('AAOS_AI_GATE_BASE')
  $names.Add('AAOS_AI_GATE_MAX_BYTES')
  $wslenv = (($names | ForEach-Object { "$_/u" }) -join ':')
  $who = Get-WhoLine $Provider $Auth $Url $Model
  $bashText = $bash -join "`r`n"
  $psText = $ps -join "`r`n"
  $text = @"
Umgebung selbst eintragen. Es wurde keine Konfigurationsdatei geschrieben und die Windows-Benutzerumgebung nicht veraendert.
Ohne diese Variablen baut m wie vorher.
$who

Variante A, in der WSL-Distribution in ~/.bashrc, danach source ~/.bashrc:

$bashText

Variante B, in Windows PowerShell. Das schreibt die Benutzerumgebung. Einen vorhandenen WSLENV-Wert anhaengen, nicht ersetzen. /u reicht die Variable nach WSL durch und uebersetzt sie nicht als Pfad:

$psText
`$existing = [Environment]::GetEnvironmentVariable('WSLENV', 'User')
`$gate = '$wslenv'
if (`$existing) { `$gate = "`${existing}:`$gate" }
[Environment]::SetEnvironmentVariable('WSLENV', `$gate, 'User')

blocking fragt vor dem Build. j, ja, y oder yes startet ihn, auch bei likely_fail. Eingabe oder n stoppt nur diesen Lauf und wird nicht gemerkt. Ein frueher fehlgeschlagener Stand sperrt den naechsten Build nicht. Der Compiler bleibt die Pruefung. AAOS_AI_GATE=stop ist die einzige harte Weigerung, und nur bei likely_fail.
parallel startet den Build sofort. Strg-C und der Stop-Button der IDE beenden ihn. Wird der Build fertig, waehrend die Anfrage noch laeuft, wird sie abgebrochen. Der naechste m prueft erneut. Keine 24-Stunden-Pause.
Diff, Stash und Commit-Betreffs gehen an den Anbieter. Claude mit Token an api.anthropic.com, Antigravity mit Token an Google, Copilot und jedes Abonnement an die jeweilige Kommandozeile, eine eigene URL an diese URL.
Optional: AAOS_AI_GATE_BASE=HEAD und AAOS_AI_GATE_MAX_BYTES=80000.
Ein Ja liegt unter out/.aaos-ai-gate. m clean loescht nur das. Der Diff-Cache unter ~/.cache/aaos-ai-gate in WSL bleibt.
"@
  if ($Ccache) {
    $qExec = Quote-Bash $CcacheExec
    $qDir = Quote-Bash $CcacheDir
    $qSize = Quote-Bash $CcacheSize
    $text += @"

ccache gehoert in ~/.bashrc der Distribution, nicht in die Gate-Datei. Die liest nur der Hook in build/soong/bin/m. mm, mmm, mma und mmma sind eigene Skripte. make aus envsetup.sh ruft soong_ui.bash direkt. Staende USE_CCACHE nur in der Konfiguration, saehen mm und make sie nicht. Ein Wechsel aenderte CC_WRAPPER in soong.variables, und Soong und Kati erzeugten neu. Nach dem Entfernen des Gates waere ccache still weg und der naechste Build kalt. AOSP setzt compilercheck und sloppiness selbst. Die Groesse merkt sich ccache ueber -M. CCACHE_MAXSIZE schreibt dieser Installer nicht.

export USE_CCACHE=1
export CCACHE_EXEC=$qExec
export CCACHE_DIR=$qDir
CCACHE_DIR=$qDir $qExec -M $qSize
"@
    if ($CcacheNote) {
      $text += "`r`n$CcacheNote"
    }
  }
  $text += "`r`n`r`nDanach in WSL: source build/envsetup.sh && lunch <ziel> && m"
  return $text
}

function Resolve-Ccache([hashtable]$Loc, [string]$Dir, [string]$Size) {
  $result = @{ Ok = $false; Exec = ''; Dir = $Dir; Note = '' }
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    $result.Note = 'wsl.exe fehlt. ccache wird nicht eingetragen. In der Distribution: sudo apt-get install -y ccache, danach die export-Zeilen in ~/.bashrc.'
    return $result
  }
  $cmd = @'
dir=__DIR__
case "$dir" in
  "~") dir=$HOME ;;
  "~/"*) dir=$HOME/${dir:2} ;;
  '$HOME') dir=$HOME ;;
  '$HOME/'*) dir=$HOME${dir:5} ;;
  '${HOME}') dir=$HOME ;;
  '${HOME}/'*) dir=$HOME${dir:7} ;;
esac
printf '%s\n' "DIR:$dir"
exec=$(command -v ccache || true)
if [ -z "$exec" ] || [ ! -x "$exec" ]; then echo MISSING; exit 0; fi
mkdir -p "$dir"
if ! CCACHE_DIR="$dir" "$exec" -M __SIZE__; then echo M_FAIL; fi
echo "EXEC:$exec"
'@
  $cmd = $cmd.Replace('__DIR__', (Quote-Bash $Dir)).Replace('__SIZE__', (Quote-Bash $Size))
  $out = Invoke-WslCapture $Loc.Distro $cmd
  $text = $out -join "`n"
  $dirLine = $out | Where-Object { $_ -like 'DIR:*' } | Select-Object -Last 1
  if ($dirLine) { $result.Dir = $dirLine.Substring(4).Trim() }
  if ($text -match 'MISSING') {
    $result.Note = 'ccache fehlt in der Distribution und wird nicht nachgeladen. In WSL: sudo apt-get install -y ccache. Danach diese Installation erneut, mit Umgebung selbst eintragen. USE_CCACHE wird nicht gesetzt.'
    return $result
  }
  $execLine = $out | Where-Object { $_ -like 'EXEC:*' } | Select-Object -Last 1
  if (-not $execLine) {
    $result.Note = 'ccache wurde nicht gefunden. USE_CCACHE wird nicht gesetzt.'
    return $result
  }
  $result.Exec = $execLine.Substring(5).Trim()
  if (-not $result.Exec) { return $result }
  $result.Ok = $true
  if ($text -match 'M_FAIL') {
    $result.Note = "ccache liegt unter $($result.Exec). ccache -M ist fehlgeschlagen. Die Groesse in WSL setzen: CCACHE_DIR=$(Quote-Bash $result.Dir) $(Quote-Bash $result.Exec) -M $(Quote-Bash $Size)"
  }
  return $result
}

function Install-Gate {
  Update-CliProbeFromTree
  if (-not (Test-Path -LiteralPath $script:Payload)) {
    throw "Nutzlast fehlt: $($script:Payload)"
  }
  $tree = $script:TxtTree.Text.Trim()
  if (-not $tree -or -not (Test-AaosTree $tree)) {
    throw 'Das ist kein AAOS/AOSP-Quellbaum. Erwartet werden build/soong/bin/m, build/soong/soong_ui.bash und build/envsetup.sh.'
  }
  $providers = @('claude', 'copilot', 'antigravity')
  $provider = $providers[[Math]::Max(0, $script:CmbProvider.SelectedIndex)]
  $auth = 'subscription'
  if ($script:CmbAuth.SelectedIndex -eq 1) { $auth = 'token' }
  $url = ''
  $model = ''
  if ($script:ChkAdvanced.Checked) {
    $url = $script:TxtUrl.Text.Trim()
    $model = $script:TxtModel.Text.Trim()
  }
  $token = $script:TxtToken.Text.Trim()
  if ($token -and ($token.Contains("`n") -or $token.Contains("`r"))) {
    throw 'API-Token enthaelt einen Zeilenumbruch.'
  }
  if ($url -and $url -notmatch '^https?://') {
    throw 'Die URL muss mit http:// oder https:// beginnen.'
  }
  if ($url) {
    if ([string]::IsNullOrWhiteSpace($token)) {
      throw 'Eine eigene URL braucht ein API-Token. Die Anmeldung der Kommandozeile gilt dort nicht.'
    }
    if (-not $model) { $model = 'default' }
  } elseif ($auth -eq 'token') {
    if ([string]::IsNullOrWhiteSpace($token)) {
      throw 'API-Token fehlt oder enthaelt einen Zeilenumbruch.'
    }
  } else {
    $token = ''
  }
  $mode = 'blocking'
  if ($script:CmbMode.SelectedIndex -eq 1) { $mode = 'parallel' }
  $self = $script:ChkSelf.Checked
  $ccache = $script:ChkCcache.Checked -and $self
  $cdir = $script:TxtCcacheDir.Text.Trim()
  $csize = $script:TxtCcacheSize.Text.Trim()
  $cexec = ''
  if ($ccache -and (-not $cdir -or -not $csize)) {
    throw 'Fuer ccache Verzeichnis und Groesse angeben.'
  }
  $loc = Get-TreeKind $tree
  if (-not (Test-DistroCommand $loc 'command -v jq >/dev/null')) {
    throw 'jq fehlt in der Distribution oder WSL ist nicht erreichbar. Zum Beispiel: sudo apt install jq. Der Baum wurde nicht veraendert.'
  }
  if (($url -or ($auth -eq 'token')) -and -not (Test-DistroCommand $loc 'command -v curl >/dev/null')) {
    throw 'curl fehlt in der Distribution oder WSL ist nicht erreichbar. Zum Beispiel: sudo apt install curl. Der Baum wurde nicht veraendert.'
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false

  $dialogPayload = Join-Path $PSScriptRoot 'aaos-ai-gate-dialog.ps1'
  if (-not (Test-Path -LiteralPath $dialogPayload)) {
    throw "Dialog fehlt: $dialogPayload"
  }
  $destSh = Join-Path $tree 'build\soong\bin\ai-patch-gate.sh'
  $shText = [System.IO.File]::ReadAllText($script:Payload)
  $shText = $shText -replace "`r", ''
  [System.IO.File]::WriteAllText($destSh, $shText, $utf8)
  [System.IO.File]::Copy($dialogPayload, (Join-Path $tree 'build\soong\bin\aaos-ai-gate-dialog.ps1'), $true)
  $notes = New-Object System.Collections.Generic.List[string]
  if (-not $url) {
    $probeKey = ''
    if ($loc.Kind -eq 'wsl') { $probeKey = $loc.Distro }
    $fresh = $script:LastProbe
    if (-not $fresh -or [string]$fresh.DistroKey -ne $probeKey) {
      $fresh = Get-CliProbe $probeKey
    }
    $needsCli = ($provider -eq 'copilot') -or ($auth -eq 'subscription')
    if ($needsCli -and $fresh.Known -and (@($fresh.Found) -notcontains $provider)) {
      $bin = $provider
      if ($provider -eq 'antigravity') { $bin = 'agy' }
      if ($provider -eq 'copilot') {
        $notes.Add("$bin ist in $($fresh.DistroLabel) nicht aufrufbar. Microsoft Copilot laeuft nur ueber diese Kommandozeile, auch mit API-Token.")
      } else {
        $notes.Add("$bin ist in $($fresh.DistroLabel) nicht aufrufbar. Das Abonnement braucht diese Kommandozeile. Ein API-Token fuer Claude oder Antigravity kommt ohne sie aus.")
      }
    }
  }
  if ($loc.Kind -eq 'wsl') {
    $warn = Set-LinuxMode $loc "$($loc.Linux)/build/soong/bin/ai-patch-gate.sh" '755'
    if ($warn) { $notes.Add($warn) }
  } else {
    $notes.Add('Der Baum liegt nicht auf einem ext4-Laufwerk von \\wsl$\. chmod 755 gilt dort nicht. In WSL pruefen, ob build/soong/bin/ai-patch-gate.sh ausfuehrbar ist.')
  }
  $hideNote = Hide-GateFromGit $loc
  if ($hideNote) { $notes.Add($hideNote) }

  $mPath = Join-Path $tree 'build\soong\bin\m'
  $mText = [System.IO.File]::ReadAllText($mPath)
  $patched = Update-BuildEntry $mText
  if ($patched.Status -eq 'fehlt') {
    $notes.Add((Get-ManualHook))
  } elseif ($patched.Text -ne $mText) {
    [System.IO.File]::WriteAllText($mPath, $patched.Text, $utf8)
  }

  $ccacheNote = ''
  $writeCcache = $false
  if ($script:ChkCcache.Checked -and -not $self) {
    $notes.Add('ccache bleibt aus der Konfiguration. Die liest nur m. mm, mmm, mma, mmma und make gehen sonst ohne Wrapper, und jeder Wechsel laesst Soong und Kati neu erzeugen. Dafuer Umgebung selbst eintragen.')
  } elseif ($ccache) {
    $resolved = Resolve-Ccache $loc $cdir $csize
    $cdir = $resolved.Dir
    if ($resolved.Note) { $ccacheNote = $resolved.Note }
    if ($resolved.Ok -and $resolved.Exec) {
      $cexec = $resolved.Exec
      $writeCcache = $true
    }
    if ($ccacheNote) { $notes.Add($ccacheNote) }
  }

  $confPath = Join-Path $tree '.aaos-ai-gate.conf'
  $oldCcache = $false
  if (Test-Path -LiteralPath $confPath) {
    $prev = [System.IO.File]::ReadAllText($confPath)
    if ($prev -match '(?m)^(USE_CCACHE|CCACHE_EXEC|CCACHE_DIR|CCACHE_MAXSIZE)=') { $oldCcache = $true }
  }
  if ($self) {
    if (Test-Path -LiteralPath $confPath) {
      Remove-Item -LiteralPath $confPath -Force
      $notes.Add('Vorhandene .aaos-ai-gate.conf wurde entfernt.')
    }
    if ($oldCcache) {
      $notes.Add('Die bisherige Konfiguration stammte aus einer frueheren Version und enthielt ccache. Diese Zeilen entfallen. Stehen sie nicht in der Shell, aendert der naechste Build CC_WRAPPER und Soong und Kati erzeugen neu.')
    }
    $guide = Get-SelfGuide $mode $provider $auth $url $token $model $writeCcache $cexec $cdir $csize $ccacheNote
    $head = "Installiert in $tree. Modus: $mode. Keine Konfigurationsdatei geschrieben."
    return ($head + "`r`n" + ($notes -join "`r`n") + "`r`n`r`n" + $guide)
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# aaos ai-patch-gate. Nur dieser Baum. Nicht committen.')
  foreach ($pair in (Get-GatePairs $mode $provider $auth $url $token $model)) {
    $lines.Add("$($pair.Key)=$(Quote-Bash $pair.Value)")
  }
  [System.IO.File]::WriteAllText($confPath, ($lines -join "`n") + "`n", $utf8)
  if ($loc.Kind -eq 'wsl') {
    $warn = Set-LinuxMode $loc "$($loc.Linux)/.aaos-ai-gate.conf" '600'
    if ($warn) { $notes.Add($warn) }
  } else {
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $confPath /inheritance:r /grant:r "${me}:(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      $notes.Add("Warnung: icacls ist fehlgeschlagen (rc=$LASTEXITCODE). Die Konfiguration konnte nicht auf den aktuellen Benutzer beschraenkt werden. Unix-Modus 600 gilt auf diesem Laufwerk nicht.")
    } else {
      $notes.Add('Die Konfiguration ist auf den aktuellen Windows-Benutzer beschraenkt. Unix-Modus 600 gilt auf diesem Laufwerk nicht.')
    }
  }

  $label = 'blockierend, Vorabtest'
  if ($mode -eq 'parallel') { $label = 'parallel, nur Hinweis' }
  $head = @(
    "Installiert in $tree.",
    "Modus: $label.",
    (Get-WhoLine $provider $auth $url $model),
    "Konfiguration: $confPath",
    'm ruft den Gate nur auf, wenn diese Datei oder AAOS_AI_GATE gesetzt ist.',
    'ccache steht nicht in dieser Datei. mm, mmm, mma, mmma und make aus envsetup.sh rufen soong_ui.bash direkt. Ein Wechsel aendert CC_WRAPPER, Soong und Kati erzeugen neu. Nach dem Entfernen waere ccache still weg. Die Variablen gehoeren in ~/.bashrc. Dafuer Umgebung selbst eintragen.',
    'Diff, Stash und Commit-Betreffs gehen an den Anbieter. Claude mit Token an api.anthropic.com, Antigravity mit Token an Google, sonst an die Kommandozeile oder an die eigene URL.'
  ) -join "`r`n"
  if ($oldCcache) {
    $notes.Add('Die bisherige Konfiguration stammte aus einer frueheren Version und enthielt ccache. Diese Zeilen entfallen. Stehen sie nicht in der Shell, aendert der naechste Build den Wrapper und kompiliert kalt.')
  }
  if ($notes.Count -gt 0) {
    return $head + "`r`n" + ($notes -join "`r`n")
  }
  return $head
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AAOS AI-Patch-Gate'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(680, 820)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Add-Label([string]$Text, [int]$Y) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text
  $l.Location = New-Object System.Drawing.Point(16, $Y)
  $l.AutoSize = $true
  $form.Controls.Add($l)
  return $l
}

Add-Label 'Quellbaum (Verzeichnis mit build/envsetup.sh)' 16 | Out-Null
$script:TxtTree = New-Object System.Windows.Forms.TextBox
$script:TxtTree.Location = New-Object System.Drawing.Point(16, 38)
$script:TxtTree.Size = New-Object System.Drawing.Size(540, 24)
$form.Controls.Add($script:TxtTree)
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = 'Durchsuchen'
$btnBrowse.Location = New-Object System.Drawing.Point(564, 36)
$btnBrowse.Size = New-Object System.Drawing.Size(100, 28)
$btnBrowse.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'AAOS-Quellbaum waehlen'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $script:TxtTree.Text = $dlg.SelectedPath
    Update-CliProbeFromTree
  }
})
$form.Controls.Add($btnBrowse)
$script:TxtTree.Add_Leave({ Update-CliProbeFromTree })

Add-Label 'Betriebsmodus' 72 | Out-Null
$script:CmbMode = New-Object System.Windows.Forms.ComboBox
$script:CmbMode.DropDownStyle = 'DropDownList'
$script:CmbMode.Location = New-Object System.Drawing.Point(16, 94)
$script:CmbMode.Size = New-Object System.Drawing.Size(648, 24)
[void]$script:CmbMode.Items.Add('blockierend, Vorabtest')
[void]$script:CmbMode.Items.Add('parallel, nur Hinweis')
$script:CmbMode.SelectedIndex = 0
$form.Controls.Add($script:CmbMode)

$script:LblProvider = Add-Label 'Anbieter' 128
$script:CmbProvider = New-Object System.Windows.Forms.ComboBox
$script:CmbProvider.DropDownStyle = 'DropDownList'
$script:CmbProvider.Size = New-Object System.Drawing.Size(648, 24)
[void]$script:CmbProvider.Items.Add('Claude')
[void]$script:CmbProvider.Items.Add('Microsoft Copilot')
[void]$script:CmbProvider.Items.Add('Antigravity')
$script:CmbProvider.SelectedIndex = 0
$script:ProviderTouched = $false
$script:ProviderUpdating = $false
$script:LastProbe = $null
$script:CmbProvider.Add_SelectedIndexChanged({
  if (-not $script:ProviderUpdating) { $script:ProviderTouched = $true }
})
$form.Controls.Add($script:CmbProvider)
$script:LblDetect = Add-Label 'Kommandozeilen werden in der Distribution gesucht.' 0
$script:LblDetect.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
$script:LblDetect.MaximumSize = New-Object System.Drawing.Size(648, 0)

$script:LblAuth = Add-Label 'Anmeldung' 184
$script:CmbAuth = New-Object System.Windows.Forms.ComboBox
$script:CmbAuth.DropDownStyle = 'DropDownList'
$script:CmbAuth.Size = New-Object System.Drawing.Size(648, 24)
[void]$script:CmbAuth.Items.Add('Abonnement, vorhandene Anmeldung')
[void]$script:CmbAuth.Items.Add('API-Token')
$script:CmbAuth.SelectedIndex = 0
$form.Controls.Add($script:CmbAuth)

$script:LblToken = Add-Label 'API-Token' 240
$script:TxtToken = New-Object System.Windows.Forms.TextBox
$script:TxtToken.Size = New-Object System.Drawing.Size(648, 24)
$script:TxtToken.UseSystemPasswordChar = $true
$script:TxtToken.Enabled = $false
$form.Controls.Add($script:TxtToken)

$script:ChkAdvanced = New-Object System.Windows.Forms.CheckBox
$script:ChkAdvanced.Text = 'Abweichende Verbindung angeben'
$script:ChkAdvanced.AutoSize = $true
$form.Controls.Add($script:ChkAdvanced)

$script:LblModel = Add-Label 'Modellname' 0
$script:TxtModel = New-Object System.Windows.Forms.TextBox
$script:TxtModel.Size = New-Object System.Drawing.Size(648, 24)
$script:LblModel.Visible = $false
$script:TxtModel.Visible = $false
$form.Controls.Add($script:TxtModel)

$script:LblUrl = Add-Label 'Chat-Completions-URL' 0
$script:TxtUrl = New-Object System.Windows.Forms.TextBox
$script:TxtUrl.Size = New-Object System.Drawing.Size(648, 24)
$script:LblUrl.Visible = $false
$script:TxtUrl.Visible = $false
$form.Controls.Add($script:TxtUrl)

$script:ChkCcache = New-Object System.Windows.Forms.CheckBox
$script:ChkCcache.Text = 'ccache in ~/.bashrc (nur zusammen mit Umgebung selbst eintragen)'
$script:ChkCcache.AutoSize = $true
$script:ChkCcache.Enabled = $false
$form.Controls.Add($script:ChkCcache)

$script:LblCcacheDir = Add-Label 'CCACHE_DIR (Linux-Pfad)' 0
$script:TxtCcacheDir = New-Object System.Windows.Forms.TextBox
$script:TxtCcacheDir.Size = New-Object System.Drawing.Size(420, 24)
$script:TxtCcacheDir.Text = '~/.cache/ccache'
$script:TxtCcacheDir.Enabled = $false
$form.Controls.Add($script:TxtCcacheDir)
$script:LblSize = Add-Label 'Groesse' 0
$script:TxtCcacheSize = New-Object System.Windows.Forms.TextBox
$script:TxtCcacheSize.Size = New-Object System.Drawing.Size(214, 24)
$script:TxtCcacheSize.Text = '100G'
$script:TxtCcacheSize.Enabled = $false
$form.Controls.Add($script:TxtCcacheSize)
function Sync-CcacheChoice {
  $selfOn = $script:ChkSelf.Checked
  $script:ChkCcache.Enabled = $selfOn
  if (-not $selfOn) { $script:ChkCcache.Checked = $false }
  $on = $selfOn -and $script:ChkCcache.Checked
  $script:TxtCcacheDir.Enabled = $on
  $script:TxtCcacheSize.Enabled = $on
}
$script:ChkCcache.Add_Click({ Sync-CcacheChoice })

$script:ChkSelf = New-Object System.Windows.Forms.CheckBox
$script:ChkSelf.Text = 'Umgebung selbst eintragen, statt einer Konfiguration im Baum'
$script:ChkSelf.AutoSize = $true
$form.Controls.Add($script:ChkSelf)
$script:ChkSelf.Add_Click({ Sync-CcacheChoice })

$script:LblHint = Add-Label 'Es wird nur der Quellbaum beschrieben. ~/.bashrc bleibt unangetastet. ccache nur dort, nicht in der Gate-Datei.' 0
$script:LblHint.MaximumSize = New-Object System.Drawing.Size(648, 0)

$script:BtnInstall = New-Object System.Windows.Forms.Button
$script:BtnInstall.Text = 'Installieren'
$script:BtnInstall.Size = New-Object System.Drawing.Size(160, 32)
$script:BtnInstall.Add_Click({
  $script:TxtResult.Text = ''
  try {
    $script:TxtResult.Text = Install-Gate
  } catch {
    $script:TxtResult.Text = $_.Exception.Message
  }
})
$form.Controls.Add($script:BtnInstall)

$script:BtnRemove = New-Object System.Windows.Forms.Button
$script:BtnRemove.Text = 'Entfernen'
$script:BtnRemove.Size = New-Object System.Drawing.Size(160, 32)
$script:BtnRemove.Add_Click({
  $tree = $script:TxtTree.Text.Trim()
  if (-not $tree) {
    $script:TxtResult.Text = 'Zuerst den Quellbaum angeben.'
    return
  }
  $answer = [System.Windows.Forms.MessageBox]::Show(
    "Gate aus diesem Baum entfernen?`r`n$tree`r`n`r`nHook, Skripte und Konfiguration werden geloescht. Der Diff-Cache und out/ bleiben.",
    'Entfernen',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
  )
  if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  $script:TxtResult.Text = ''
  try {
    $script:TxtResult.Text = Uninstall-GatePath $tree
  } catch {
    $script:TxtResult.Text = $_.Exception.Message
  }
})
$form.Controls.Add($script:BtnRemove)

$script:TxtResult = New-Object System.Windows.Forms.TextBox
$script:TxtResult.Size = New-Object System.Drawing.Size(648, 220)
$script:TxtResult.Multiline = $true
$script:TxtResult.ScrollBars = 'Vertical'
$script:TxtResult.ReadOnly = $true
$script:TxtResult.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($script:TxtResult)

function Move-Ctrl($Ctrl, [int]$X, [int]$Y) {
  $Ctrl.Location = New-Object System.Drawing.Point($X, $Y)
}

function Sync-InstallerLayout {
  $y = 128
  Move-Ctrl $script:LblProvider 16 $y
  $y += 22
  Move-Ctrl $script:CmbProvider 16 $y
  $y += 28
  Move-Ctrl $script:LblDetect 16 $y
  $y += [Math]::Max(22, $script:LblDetect.Height + 8)
  Move-Ctrl $script:LblAuth 16 $y
  $y += 22
  Move-Ctrl $script:CmbAuth 16 $y
  $y += 36
  Move-Ctrl $script:LblToken 16 $y
  $y += 22
  Move-Ctrl $script:TxtToken 16 $y
  $script:TxtToken.Enabled = ($script:CmbAuth.SelectedIndex -eq 1)
  $y += 40
  Move-Ctrl $script:ChkAdvanced 16 $y
  $advanced = $script:ChkAdvanced.Checked
  $script:LblModel.Visible = $advanced
  $script:TxtModel.Visible = $advanced
  $script:LblUrl.Visible = $advanced
  $script:TxtUrl.Visible = $advanced
  if ($advanced) {
    $y += 32
    Move-Ctrl $script:LblModel 16 $y
    $y += 22
    Move-Ctrl $script:TxtModel 16 $y
    $y += 36
    Move-Ctrl $script:LblUrl 16 $y
    $y += 22
    Move-Ctrl $script:TxtUrl 16 $y
    $y += 40
  } else {
    $y += 36
  }
  Move-Ctrl $script:ChkCcache 16 $y
  $y += 28
  Move-Ctrl $script:LblCcacheDir 16 $y
  Move-Ctrl $script:LblSize 450 $y
  $y += 22
  Move-Ctrl $script:TxtCcacheDir 16 $y
  Move-Ctrl $script:TxtCcacheSize 450 $y
  $y += 40
  Move-Ctrl $script:ChkSelf 16 $y
  $y += 28
  Move-Ctrl $script:LblHint 16 $y
  $y += 44
  Move-Ctrl $script:BtnInstall 16 $y
  Move-Ctrl $script:BtnRemove 190 $y
  $y += 48
  $height = $y + 220
  if ($height -lt 820) { $height = 820 }
  $form.ClientSize = New-Object System.Drawing.Size(680, $height)
  Move-Ctrl $script:TxtResult 16 $y
  $script:TxtResult.Size = New-Object System.Drawing.Size(648, ($height - $y - 16))
}

$script:CmbAuth.Add_SelectedIndexChanged({ Sync-InstallerLayout })
$script:ChkAdvanced.Add_CheckedChanged({ Sync-InstallerLayout })
Sync-InstallerLayout
$form.Add_Shown({ Update-CliProbeFromTree })

if ($script:WantUninstall -and $env:AAOS_INSTALL_TREE) {
  try {
    Write-Output (Uninstall-GatePath $env:AAOS_INSTALL_TREE)
    exit 0
  } catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
  }
}

[void]$form.ShowDialog()
