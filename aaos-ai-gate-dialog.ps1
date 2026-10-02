# Dialog fuer den parallelen Modus. Der Build laeuft weiter.
param(
  [Parameter(Mandatory = $true)][string]$DataDir
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process -FilePath $hostExe -ArgumentList @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', $PSCommandPath, '-DataDir', $DataDir
  ) | Out-Null
  exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

function Read-Utf8([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return [System.IO.File]::ReadAllText($Path)
}

function Quote-Bash([string]$Value) {
  return "'" + ($Value -replace "'", "'\''") + "'"
}

function Set-ConfLine([string]$Path, [string]$Key, [string]$Value) {
  $line = $Key + '=' + (Quote-Bash $Value)
  $utf8 = New-Object System.Text.UTF8Encoding $false
  if (-not (Test-Path -LiteralPath $Path)) {
    [System.IO.File]::WriteAllText($Path, "# aaos ai-patch-gate. Nur dieser Baum.`n$line`n", $utf8)
    return
  }
  $text = [System.IO.File]::ReadAllText($Path)
  $pattern = '(?m)^' + [regex]::Escape($Key) + '=.*$'
  $replacement = $line.Replace('$', '$$')
  if ([regex]::IsMatch($text, $pattern)) {
    $text = [regex]::Replace($text, $pattern, $replacement)
  } else {
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $text += $line + "`n"
  }
  [System.IO.File]::WriteAllText($Path, $text, $utf8)
}

function Add-GitExclude([string]$Top, [string]$Name) {
  $git = Join-Path $Top '.git'
  if (-not (Test-Path -LiteralPath $git -PathType Container)) { return }
  $info = Join-Path $git 'info'
  if (-not (Test-Path -LiteralPath $info)) {
    New-Item -ItemType Directory -Path $info | Out-Null
  }
  $exclude = Join-Path $info 'exclude'
  $text = ''
  if (Test-Path -LiteralPath $exclude) { $text = [System.IO.File]::ReadAllText($exclude) }
  if ($text -match ('(?m)^' + [regex]::Escape($Name) + '$')) { return }
  if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
  $text += $Name + "`n"
  [System.IO.File]::WriteAllText($exclude, $text, (New-Object System.Text.UTF8Encoding $false))
}

$metaPath = Join-Path $DataDir 'meta.json'
$meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$problem = Read-Utf8 (Join-Path $DataDir 'problem.txt')
if (-not $problem) { $problem = 'Das Modell hat einen Hinweis zum aktuellen Diff. Der Build läuft weiter.' }
$context = Read-Utf8 (Join-Path $DataDir 'context.txt')
if ($context.Length -gt 12000) { $context = $context.Substring(0, 12000) }

$script:messages = New-Object System.Collections.Generic.List[object]
$script:messages.Add(@{
  role = 'system'
  content = 'Du hast einen Android-Diff vor einem Build nur als Hinweis gelesen. Du kennst keine absolute Wahrheit. Antworte auf Deutsch, kurz, und bleib bei dem Befund und dem Diff-Auszug. Erfinde keinen Compile-Lauf. Der Build des Nutzers läuft bereits weiter.'
}) | Out-Null
$script:messages.Add(@{
  role = 'user'
  content = "Befund:`r`n$problem`r`n`r`nAuszug aus dem geprüften Diff:`r`n$context"
}) | Out-Null
$script:follow = New-Object System.Collections.Generic.List[string]
$script:chatJob = $null
$hasUrl = -not [string]::IsNullOrWhiteSpace([string]$meta.url) -and -not [string]::IsNullOrWhiteSpace([string]$meta.token)
$hasProvider = -not [string]::IsNullOrWhiteSpace([string]$meta.provider) -and -not [string]::IsNullOrWhiteSpace([string]$meta.linuxScript)
if ($hasUrl) {
  $script:askVia = 'url'
} elseif ($hasProvider) {
  $script:askVia = 'wsl'
} else {
  $script:askVia = 'off'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AAOS AI-Patch-Gate'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ClientSize = New-Object System.Drawing.Size(560, 590)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 20000
$tip.InitialDelay = 400
$tip.ReshowDelay = 200
$tip.ShowAlways = $true

function Add-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 22) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text
  $l.Location = New-Object System.Drawing.Point($X, $Y)
  $l.Size = New-Object System.Drawing.Size($W, $H)
  $form.Controls.Add($l)
  return $l
}

$intro = Add-Label 'Der Build läuft weiter. Das Modell meldet einen Verdacht, es bricht den Build nicht ab.' 16 12 528 40
$tip.SetToolTip($intro, 'Paralleler Modus: kompilieren und prüfen gleichzeitig. Dieses Fenster wartet nicht auf den Compiler und hält ihn nicht an.')

$lblProblem = Add-Label 'Was das Modell erwartet' 16 56 528
$tip.SetToolTip($lblProblem, 'Kurzfassung des Befunds: Rückfrage, Begründung, Compile, Laufzeit und Effekt.')

$txtProblem = New-Object System.Windows.Forms.TextBox
$txtProblem.Location = New-Object System.Drawing.Point(16, 80)
$txtProblem.Size = New-Object System.Drawing.Size(528, 110)
$txtProblem.Multiline = $true
$txtProblem.ReadOnly = $true
$txtProblem.ScrollBars = 'Vertical'
$txtProblem.BackColor = [System.Drawing.SystemColors]::Control
$txtProblem.Text = $problem
$form.Controls.Add($txtProblem)
$tip.SetToolTip($txtProblem, 'Das hat das Modell am aktuellen Diff ausgesetzt. Es kann sich irren. Der Compiler prüft den Code trotzdem.')

$lblChat = Add-Label 'Rückfrage an die KI' 16 196 528
$tip.SetToolTip($lblChat, 'Dieselbe Schnittstelle und dasselbe Modell wie der Check. Der Verlauf bleibt in diesem Fenster.')

$txtChat = New-Object System.Windows.Forms.TextBox
$txtChat.Location = New-Object System.Drawing.Point(16, 228)
$txtChat.Size = New-Object System.Drawing.Size(528, 150)
$txtChat.Multiline = $true
$txtChat.ReadOnly = $true
$txtChat.ScrollBars = 'Vertical'
$txtChat.BackColor = [System.Drawing.SystemColors]::Window
$txtChat.Text = "KI: $problem`r`n`r`n"
$script:TxtChat = $txtChat
$form.Controls.Add($txtChat)
$tip.SetToolTip($txtChat, 'Verlauf. Oben steht der Befund, darunter die Antworten auf deine Fragen.')

$txtIn = New-Object System.Windows.Forms.TextBox
$txtIn.Location = New-Object System.Drawing.Point(16, 390)
$txtIn.Size = New-Object System.Drawing.Size(400, 24)
$form.Controls.Add($txtIn)
$tip.SetToolTip($txtIn, 'Frage an das Modell, zum Beispiel warum es den Diff für riskant hält. Eingabetaste schickt die Frage ab.')

$btnAsk = New-Object System.Windows.Forms.Button
$btnAsk.Text = 'Fragen'
$btnAsk.Location = New-Object System.Drawing.Point(424, 388)
$btnAsk.Size = New-Object System.Drawing.Size(120, 28)
$script:BtnAsk = $btnAsk
$form.Controls.Add($btnAsk)
if ($script:askVia -eq 'off') {
  $btnAsk.Enabled = $false
  $askTip = 'Kein Anbieter hinterlegt. Der Befund bleibt lesbar, eine Rückfrage geht so nicht hinaus.'
} elseif ($script:askVia -eq 'url') {
  $askTip = 'Schickt die Frage an die hinterlegte Verbindung. Der Build wartet nicht darauf.'
} else {
  $askTip = 'Schickt die Frage über denselben Anbieter. Der Build wartet nicht darauf.'
}
$tip.SetToolTip($btnAsk, $askTip)

$chk = New-Object System.Windows.Forms.CheckBox
$chk.Text = 'Nicht mehr anzeigen'
$chk.Location = New-Object System.Drawing.Point(16, 428)
$chk.AutoSize = $true
$form.Controls.Add($chk)
$tip.SetToolTip($chk, 'Gilt beim Schließen. Legt .aaos-ai-gate.dialog-off in die Wurzel des Quellbaums und setzt AAOS_AI_GATE_DIALOG=off in der Konfiguration. Beides entfernen, dann erscheint der Dialog beim nächsten Verdacht wieder.')

$btnMode = New-Object System.Windows.Forms.Button
$btnMode.Text = 'Auf blockierend umstellen'
$btnMode.Location = New-Object System.Drawing.Point(16, 464)
$btnMode.Size = New-Object System.Drawing.Size(220, 32)
$form.Controls.Add($btnMode)
$modeTip = 'Der nächste m fragt vor dem Build. Ein klarer Compile-Bruch startet den Build dann nicht. Dieser Build läuft zu Ende.'
if ($meta.modeFromEnv -eq 'yes') {
  $modeTip = 'Schreibt blockierend in die Konfiguration im Baum. AAOS_AI_GATE_MODE steht zusätzlich in der Shell und gewinnt, bis es dort geändert wird. Dieser Build läuft zu Ende.'
}
$tip.SetToolTip($btnMode, $modeTip)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Schließen'
$btnClose.Location = New-Object System.Drawing.Point(424, 464)
$btnClose.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnClose)
$tip.SetToolTip($btnClose, 'Schließt das Fenster. Der Build läuft weiter. Der nächste Verdacht öffnet es wieder, solange Nicht mehr anzeigen aus ist.')
$form.CancelButton = $btnClose

$lblStatus = Add-Label '' 16 508 528 48
$script:LblStatus = $lblStatus
$tip.SetToolTip($lblStatus, 'Status der letzten Aktion: Rückfrage, Moduswechsel oder ein Fehler der Schnittstelle.')

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({
  if (-not $script:chatJob) { return }
  $state = [string]$script:chatJob.State
  if ($state -eq 'Running' -or $state -eq 'NotStarted') { return }
  $out = Receive-Job $script:chatJob -ErrorAction SilentlyContinue -ErrorVariable jobErr
  Remove-Job $script:chatJob -Force -ErrorAction SilentlyContinue
  $script:chatJob = $null
  $script:BtnAsk.Enabled = ($script:askVia -ne 'off')
  if ($jobErr -and $jobErr.Count -gt 0) {
    $script:LblStatus.Text = 'Die Anfrage ist fehlgeschlagen. Der Build läuft weiter.'
    return
  }
  $reply = ''
  if ($script:askVia -eq 'url') {
    try { $reply = [string]$out.choices[0].message.content } catch { $reply = '' }
  } elseif ($out -is [System.Array]) {
    $reply = (($out | ForEach-Object { [string]$_ }) -join "`n").Trim()
  } else {
    $reply = ([string]$out).Trim()
  }
  if (-not $reply) { $reply = 'Keine Antwort.' }
  if ($script:pendingQuestion) {
    $script:follow.Add("Sie: $($script:pendingQuestion)") | Out-Null
    $script:follow.Add("KI: $reply") | Out-Null
    $script:pendingQuestion = ''
  }
  $script:messages.Add(@{ role = 'assistant'; content = $reply }) | Out-Null
  $script:TxtChat.AppendText("KI: $reply`r`n`r`n")
  $script:LblStatus.Text = ''
})
$timer.Start()

$btnAsk.Add_Click({
  $text = $txtIn.Text.Trim()
  if (-not $text) { return }
  if ($script:chatJob) { return }
  $txtIn.Text = ''
  $script:TxtChat.AppendText("Sie: $text`r`n`r`n")
  $script:messages.Add(@{ role = 'user'; content = $text }) | Out-Null
  $script:BtnAsk.Enabled = $false
  $script:LblStatus.Text = 'Frage ist unterwegs. Der Build läuft weiter.'
  $script:pendingQuestion = $text
  $utf8 = New-Object System.Text.UTF8Encoding $false
  if ($script:askVia -eq 'wsl') {
    $hist = "Befund:`r`n$problem"
    if ($script:follow.Count -gt 0) {
      $hist += "`r`n" + ($script:follow -join "`r`n")
    }
    [System.IO.File]::WriteAllText((Join-Path $DataDir 'question.txt'), $text, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $DataDir 'history.txt'), $hist, $utf8)
    $script:chatJob = Start-Job -ScriptBlock {
      param($dir)
      $metaFile = Get-Content -LiteralPath (Join-Path $dir 'meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $bash = [string]$metaFile.linuxScript
      $data = [string]$metaFile.linuxData
      $argList = @(
        'ask',
        '--conf', [string]$metaFile.linuxConf,
        '--context', ($data + '/context.txt'),
        '--question', ($data + '/question.txt'),
        '--history', ($data + '/history.txt')
      )
      if ([string]$metaFile.distro) {
        & wsl.exe -d ([string]$metaFile.distro) -e bash $bash @argList
      } else {
        & wsl.exe -e bash $bash @argList
      }
      if ($LASTEXITCODE -ne 0) { throw 'Die Rueckfrage ist fehlgeschlagen.' }
    } -ArgumentList $DataDir
  } else {
    $modelName = [string]$meta.model
    if (-not $modelName) { $modelName = 'default' }
    $bodyObj = @{ model = $modelName; messages = @($script:messages.ToArray()) }
    $json = $bodyObj | ConvertTo-Json -Depth 6 -Compress
    $req = Join-Path $DataDir 'request.json'
    [System.IO.File]::WriteAllText($req, $json, $utf8)
    $script:chatJob = Start-Job -ScriptBlock {
      param($dir)
      $metaFile = Get-Content -LiteralPath (Join-Path $dir 'meta.json') -Raw -Encoding UTF8 | ConvertFrom-Json
      $payload = [System.IO.File]::ReadAllText((Join-Path $dir 'request.json'))
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
      Invoke-RestMethod -Uri $metaFile.url -Method Post -Headers @{ Authorization = "Bearer $($metaFile.token)" } -ContentType 'application/json' -Body $bytes -TimeoutSec 60
    } -ArgumentList $DataDir
  }
})

$txtIn.Add_KeyDown({
  param($sender, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
    $e.SuppressKeyPress = $true
    $script:BtnAsk.PerformClick()
  }
})

$btnMode.Add_Click({
  try {
    Set-ConfLine ([string]$meta.conf) 'AAOS_AI_GATE_MODE' 'blocking'
    Add-GitExclude ([string]$meta.top) '.aaos-ai-gate.conf'
    if ($meta.modeFromEnv -eq 'yes') {
      $script:LblStatus.Text = 'Konfiguration steht auf blockierend. Die Shell-Variable gewinnt, solange sie gesetzt ist.'
    } else {
      $script:LblStatus.Text = 'Ab dem nächsten m blockierend. Dieser Build läuft weiter.'
    }
  } catch {
    $script:LblStatus.Text = 'Modus konnte nicht geschrieben werden.'
  }
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_FormClosed({
  $timer.Stop()
  if ($script:chatJob) {
    Stop-Job $script:chatJob -ErrorAction SilentlyContinue
    Remove-Job $script:chatJob -Force -ErrorAction SilentlyContinue
  }
  if ($chk.Checked) {
    try {
      $utf8 = New-Object System.Text.UTF8Encoding $false
      [System.IO.File]::WriteAllText([string]$meta.marker, "off`n", $utf8)
      if ($meta.conf -and (Test-Path -LiteralPath ([string]$meta.conf))) {
        Set-ConfLine ([string]$meta.conf) 'AAOS_AI_GATE_DIALOG' 'off'
      }
      Add-GitExclude ([string]$meta.top) '.aaos-ai-gate.dialog-off'
    } catch {
    }
  }
  Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
})

[void]$form.ShowDialog()
$timer.Dispose()
