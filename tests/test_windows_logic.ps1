# Prueft die fensterlose Logik der Windows-Skripte. Laeuft mit PowerShell 7 auf macOS/Linux
# und mit Windows PowerShell 5.1. Aufruf: pwsh -NoProfile -File tests/test_windows_logic.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:ok = 0
$script:bad = 0

function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
  if ($Cond) { $script:ok++; Write-Host "ok $Name" }
  else { $script:bad++; Write-Host "not ok $Name $Detail" }
}

function Import-Functions([string]$Path, [string[]]$Names) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Check "parse $(Split-Path -Leaf $Path)" ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')
  $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
  $texts = @()
  foreach ($name in $Names) {
    $def = $defs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -eq $def) { Check "function $name vorhanden" $false; continue }
    $texts += $def.Extent.Text
  }
  return $texts
}

# 1. Syntax aller drei Skripte
# Dot-Sourcing im Skriptbereich, damit die Funktionen hier sichtbar sind.
foreach ($t in (Import-Functions (Join-Path $root 'install-windows.ps1') @('Quote-Bash', 'Get-HookSpan', 'Update-BuildEntry', 'Get-ManualHook', 'Get-GatePairs', 'Test-AaosTree'))) { . ([scriptblock]::Create($t)) }
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'aaos-ai-gate-dialog.ps1'), [ref]$tokens, [ref]$errors)
Check 'parse aaos-ai-gate-dialog.ps1' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')

# 2. Quote-Bash: Roundtrip durch bash, wenn vorhanden
$bash = Get-Command bash -ErrorAction SilentlyContinue
foreach ($v in @("it's a token", 'back\slash', '$HOME/x', 'a"b', 'plain')) {
  $q = Quote-Bash $v
  if ($bash) {
    $out = & $bash.Source -c ("printf '%s' " + $q)
    Check "Quote-Bash roundtrip [$v]" ($out -ceq $v) "got [$out]"
  } else {
    Check "Quote-Bash single-quoted [$v]" ($q.StartsWith("'") -and $q.EndsWith("'"))
  }
}

# 3. Hook in m: einfuegen, erkennen, migrieren, entfernen
$fixture = [System.IO.File]::ReadAllText((Join-Path $root 'tests/fixtures/m')).Replace("`r`n", "`n")
$r1 = Update-BuildEntry $fixture
Check 'Hook eingefuegt' ($r1.Status -eq 'eingefuegt') $r1.Status
$wrap = '_wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run --'
Check 'Hook genau einmal' (([regex]::Matches($r1.Text, [regex]::Escape($wrap))).Count -eq 1)
Check 'Hook vor dem Build-Aufruf' ($r1.Text.IndexOf($wrap) -lt $r1.Text.IndexOf('_wrap_build "$TOP/build/soong/soong_ui.bash"'))
$linuxBlock = "if [[ -f `"`$TOP/.aaos-ai-gate.conf`" || -n `"`${AAOS_AI_GATE:-}`" || -n `"`${AAOS_AI_GATE_MODE:-}`" ]]; then`n  export TOP`n  _wrap_build `"`$TOP/build/soong/bin/ai-patch-gate.sh`" run -- \`n    `"`$TOP/build/soong/soong_ui.bash`" --build-mode --all-modules --dir=`"`$(pwd)`" `"`$@`"`n  exit `$?`nfi`n`n"
Check 'Block zeichengleich mit Linux-Installer' ($r1.Text.Contains($linuxBlock))
$r2 = Update-BuildEntry $r1.Text
Check 'zweiter Lauf vorhanden' ($r2.Status -eq 'vorhanden') $r2.Status
Check 'zweiter Lauf unveraendert' ($r2.Text -ceq $r1.Text)
$old = $r1.Text.Replace('  _wrap_build "$TOP/build/soong/bin/ai-patch-gate.sh" run -- \', '  "$TOP/build/soong/bin/ai-patch-gate.sh" drive -- \').Replace("  export TOP`n", '')
$r3 = Update-BuildEntry $old
Check 'alter Block migriert' ($r3.Status -eq 'aktualisiert') $r3.Status
Check 'migrierter Text wie frisch eingefuegt' ($r3.Text -ceq $r1.Text)
$span = Get-HookSpan $r1.Text
$removed = $r1.Text.Remove($span.Start, $span.End - $span.Start)
Check 'Entfernen stellt Fixture byteidentisch her' ($removed -ceq $fixture)
$indented = $r1.Text -replace '(?m)^(if \[\[ -f "\$TOP/\.aaos-ai-gate\.conf".*|  export TOP|  _wrap_build "\$TOP/build/soong/bin/ai-patch-gate\.sh".*|    "\$TOP/build/soong/soong_ui\.bash" --build-mode.*|  exit \$\?|fi)$', "`t`$1"
$spanI = Get-HookSpan $indented
Check 'eingerueckter Block wird erkannt' ($null -ne $spanI)
$broken = $r1.Text.Replace("  exit `$?`nfi`n", "  exit `$?`nfi;`n")
Check 'Block mit fi; gilt als unvollstaendig' ($null -eq (Get-HookSpan $broken))
$manual = Get-ManualHook
Check 'Handblock enthaelt _wrap_build' ($manual.Contains($wrap))

# 4. Konfigurationspaare und Baumpruefung
$pairs = Get-GatePairs 'blocking' 'claude' 'token' '' "tok'en" ''
$keys = @($pairs | ForEach-Object { $_.Key })
Check 'Konfiguration setzt AAOS_AI_GATE=on' (($pairs | Where-Object { $_.Key -eq 'AAOS_AI_GATE' }).Value -eq 'on')
Check 'Konfiguration enthaelt Token bei token' ($keys -contains 'AAOS_AI_GATE_TOKEN')
Check 'Konfiguration ohne URL-Schluessel' (-not ($keys -contains 'AAOS_AI_GATE_URL'))
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aaos-gate-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'build/soong/bin') -Force | Out-Null
Check 'Test-AaosTree lehnt unvollstaendigen Baum ab' (-not (Test-AaosTree $tmp))
Set-Content -Path (Join-Path $tmp 'build/soong/bin/m') -Value 'x'
Set-Content -Path (Join-Path $tmp 'build/soong/soong_ui.bash') -Value 'x'
Set-Content -Path (Join-Path $tmp 'build/envsetup.sh') -Value 'x'
Check 'Test-AaosTree erkennt vollstaendigen Baum' (Test-AaosTree $tmp)

# 5. Set-ConfLine aus dem Dialog
$tokens = $null; $errors = $null
$dast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'aaos-ai-gate-dialog.ps1'), [ref]$tokens, [ref]$errors)
$sdef = $dast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-ConfLine' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($sdef.Extent.Text))
$conf = Join-Path $tmp '.aaos-ai-gate.conf'
[System.IO.File]::WriteAllText($conf, "# kommentar`nAAOS_AI_GATE='on'`n# AAOS_AI_GATE_MODE='parallel'`nAAOS_AI_GATE_MODE='parallel'`r`nAAOS_AI_GATE_TOKEN='a`$b'`n")
Set-ConfLine $conf 'AAOS_AI_GATE_MODE' 'blocking'
$text = [System.IO.File]::ReadAllText($conf)
Check 'Set-ConfLine ersetzt genau die Schluesselzeile' (([regex]::Matches($text, "(?m)^AAOS_AI_GATE_MODE='blocking'`$")).Count -eq 1) $text
Check 'Set-ConfLine laesst Kommentarzeile stehen' ($text.Contains("# AAOS_AI_GATE_MODE='parallel'"))
Check 'Set-ConfLine laesst Token mit $ unveraendert' ($text.Contains("AAOS_AI_GATE_TOKEN='a`$b'"))
Set-ConfLine $conf 'AAOS_AI_GATE_DIALOG' 'off'
$text = [System.IO.File]::ReadAllText($conf)
Check 'Set-ConfLine haengt neuen Schluessel an' ($text.EndsWith("AAOS_AI_GATE_DIALOG='off'`n"))
Check 'Datei ohne BOM' (([System.IO.File]::ReadAllBytes($conf))[0] -ne 0xEF)
Remove-Item -Recurse -Force $tmp

Write-Host "$($script:ok + $script:bad) Tests, $($script:bad) fehlgeschlagen"
if ($script:bad -gt 0) { exit 1 }
exit 0
