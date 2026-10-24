# Ein Dry-Run auf der offenen Karte.
#
# Das Skript schickt eine Lua-Zeile an den Command-Listener von BeamNG.drive.
# Die Extension alpinert/dryrun spawnt das Fahrzeug am Player Start der Mission
# imst_tarrenz_one_bend_v1 und laesst die KI die Pathnodes abfahren.
#
# Bedingungen, bevor das Skript etwas schickt:
# - BeamNG.drive laeuft. Der Ladebildschirm ist zu, die Simulation ist nicht pausiert.
# - Geladen ist die Karte imst_tarrenz. Die letzte Zeile "Level loaded" im beamng.log
#   muss diese Karte nennen.
# - Der Start erfolgte ohne -nocmdlistener. Die Pipe \\.\pipe\BEAMNGCOMMANDLISTENER
#   nimmt genau eine Schreiboperation entgegen. Ein Zeilenumbruch in der Nutzlast
#   bricht den Lua-String im Spiel und wird nicht gesendet.
# - Der eingehaengte Mod autoroad_alpine_rt enthaelt lua/ge/extensions/alpinert/dryrun.lua
#   und dryrun_vehicles.json. Das Skript liegt in dem Checkout, den das Spiel mountet.
# - Im User-Ordner liegt die Mission
#   gameplay/missions/imst_tarrenz/timeTrial/imst_tarrenz_one_bend_v1/
#   mit race.race.json und alpine_rt.json.
# - model und config stehen in der Fahrzeugliste. -Remaining faehrt jede Zeile
#   ausser etkc / kc6_360_M, nacheinander.
# - Es laeuft kein anderer Dry-Run. Ein zweiter Start wird abgelehnt.
#
# Nebenwirkungen: Stand das eigene Fahrzeug naeher als 18 m am Start, wird es
# 22 m zur Seite gesetzt. Der Test-Verkehr dieser Karte wird geloescht. Das
# fertige KI-Fahrzeug wird vor dem naechsten Lauf entfernt.
#
# Ergebnis: settings/alpine_rt/dryrun/imst_tarrenz_one_bend_v1/<model>__<config>.json
# und eine Logzeile "dryrun <model> <config> <reason> ...".
#
# Aufruf, eine Zeile:
#   powershell -NoProfile -File C:\temp\alpine-roadtrip\tools\dryrun_stage.ps1 -Remaining
#   powershell -NoProfile -File C:\temp\alpine-roadtrip\tools\dryrun_stage.ps1 -Model scintilla -Config gts

param(
  [string]$Model,
  [string]$Config,
  [switch]$Remaining
)

$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$listPath = Join-Path $repo "mods\autoroad_alpine_rt\lua\ge\extensions\alpinert\dryrun_vehicles.json"
$user = Join-Path $env:LOCALAPPDATA "BeamNG\BeamNG.drive\current"
$logPath = Join-Path $user "beamng.log"
$racePath = Join-Path $user "gameplay\missions\imst_tarrenz\timeTrial\imst_tarrenz_one_bend_v1\race.race.json"
$outDir = Join-Path $user "settings\alpine_rt\dryrun\imst_tarrenz_one_bend_v1"

function Fail([string]$message) {
  Write-Output $message
  exit 1
}

if (-not (Get-Process -Name "BeamNG.drive" -ErrorAction SilentlyContinue)) {
  Fail "BeamNG.drive laeuft nicht."
}
if (-not (Test-Path -LiteralPath $listPath)) {
  Fail "Fahrzeugliste fehlt: $listPath"
}
if (-not (Test-Path -LiteralPath $racePath)) {
  Fail "Mission fehlt: $racePath"
}
if (-not (Test-Path -LiteralPath $logPath)) {
  Fail "beamng.log fehlt: $logPath"
}

$loaded = Select-String -Path $logPath -Pattern "Level loaded:" | Select-Object -Last 1
if (-not $loaded -or $loaded.Line -notmatch "imst_tarrenz") {
  Fail "Die letzte geladene Karte ist nicht imst_tarrenz."
}

$list = Get-Content -LiteralPath $listPath -Raw | ConvertFrom-Json
$rows = @($list.vehicles)
if ($Remaining) {
  $targets = @($rows | Where-Object { -not ($_.model -eq "etkc" -and $_.config -eq "kc6_360_M") })
  if ($targets.Count -lt 1) {
    Fail "Die Liste hat ausser dem ETK keine Fahrzeuge."
  }
  $lua = '); extensions.reload("alpinert/dryrun"); alpinert_dryrun.startRest(); --'
} elseif ($Model -and $Config) {
  $hit = @($rows | Where-Object { $_.model -eq $Model -and $_.config -eq $Config })
  if ($hit.Count -ne 1) {
    Fail "model/config steht nicht in der Fahrzeugliste: $Model / $Config"
  }
  if ($Model -notmatch '^[A-Za-z0-9_]+$' -or $Config -notmatch '^[A-Za-z0-9_]+$') {
    Fail "model und config duerfen nur Buchstaben, Ziffern und Unterstrich enthalten."
  }
  $targets = @($hit)
  $lua = '); extensions.reload("alpinert/dryrun"); alpinert_dryrun.startVehicle("' + $Model + '", "' + $Config + '"); --'
} else {
  Fail "Aufruf: -Remaining, oder -Model und -Config."
}

if ($lua -match "`n|`r") {
  Fail "Die Lua-Zeile enthaelt einen Zeilenumbruch."
}

$started = Get-Date
try {
  $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "BEAMNGCOMMANDLISTENER", [System.IO.Pipes.PipeDirection]::Out)
  $pipe.Connect(3000)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($lua)
  $pipe.Write($bytes, 0, $bytes.Length)
  $pipe.Flush()
  $pipe.Dispose()
} catch {
  Fail "Command-Listener nicht erreichbar. BeamNG ohne -nocmdlistener starten. $($_.Exception.Message)"
}

$pending = New-Object System.Collections.Generic.List[string]
foreach ($row in $targets) {
  $pending.Add($row.model + "__" + $row.config)
}

$deadline = (Get-Date).AddMinutes(4)
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $still = New-Object System.Collections.Generic.List[string]
  foreach ($name in $pending) {
    $file = Join-Path $outDir ($name + ".json")
    $fresh = (Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).LastWriteTime -gt $started)
    if (-not $fresh) {
      $still.Add($name)
    }
  }
  $pending = $still
}

if ($pending.Count -gt 0) {
  Fail ("Zeit abgelaufen, ohne Ergebnis: " + ($pending -join ", "))
}

foreach ($row in $targets) {
  $name = $row.model + "__" + $row.config
  $file = Join-Path $outDir ($name + ".json")
  $doc = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  Write-Output ("{0} {1}: {2}, {3} ms, Tore {4}/{5}, {6:N1} m" -f $doc.model, $doc.config, $doc.reason, $doc.time_ms, $doc.gates, $doc.gate_count, $doc.driven_length_m)
}
