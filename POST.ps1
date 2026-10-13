<#
.SYNOPSIS
    POST - Power-On Self-Test

.DESCRIPTION
    Führt einen kleinen Selbsttest des Systems durch (CPU, Arbeitsspeicher,
    Laufwerke, Grafik, Netzwerk, Akku, Laufzeit), begrüßt anschließend den
    Benutzer und schließt sich nach einer einstellbaren Wartezeit automatisch.

.PARAMETER Delay
    Sekunden bis zum automatischen Schließen (Standard: 10).

.PARAMETER NoBeep
    Unterdrückt den POST-Piepton.

.EXAMPLE
    .\POST.ps1
    .\POST.ps1 -Delay 5 -NoBeep
#>
param(
    [int]$Delay = 10,
    [switch]$NoBeep
)

$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'POST - Power-On Self-Test'

$results = [System.Collections.Generic.List[object]]::new()

function Write-Status {
    param([string]$Name, [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Detail)

    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Cyan' }[$Status]
    Write-Host ('  {0,-22}' -f $Name) -NoNewline -ForegroundColor Gray
    Write-Host ('[{0,-4}] ' -f $Status) -NoNewline -ForegroundColor $color
    Write-Host $Detail -ForegroundColor White
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status })
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)

    Write-Host ('  {0,-22}' -f $Name) -NoNewline -ForegroundColor Gray
    Write-Host 'prüfe ...' -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 250
    Write-Host "`r" -NoNewline
    try {
        & $Test
    } catch {
        Write-Status $Name 'FAIL' $_.Exception.Message
    }
}

# --- Kopfzeile ----------------------------------------------------------------
Clear-Host
Write-Host ''
Write-Host '  ==========================================================' -ForegroundColor DarkCyan
Write-Host '   POST  -  Power-On Self-Test' -ForegroundColor Cyan
Write-Host ("   {0:dddd, dd. MMMM yyyy  HH:mm:ss}" -f (Get-Date)) -ForegroundColor DarkGray
Write-Host '  ==========================================================' -ForegroundColor DarkCyan
Write-Host ''

$os = Get-CimInstance Win32_OperatingSystem

# --- Tests --------------------------------------------------------------------
Invoke-Test 'Betriebssystem' {
    Write-Status 'Betriebssystem' 'INFO' ("{0} (Build {1})" -f $os.Caption, $os.BuildNumber)
}

Invoke-Test 'Prozessor' {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $load = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    $status = if ($load -ge 90) { 'WARN' } else { 'OK' }
    Write-Status 'Prozessor' $status ("{0} | {1} Kerne / {2} Threads | Last {3}%" -f `
        $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, [int]$load)
}

Invoke-Test 'Arbeitsspeicher' {
    $totalGB = $os.TotalVisibleMemorySize / 1MB
    $freeGB  = $os.FreePhysicalMemory / 1MB
    $usedPct = 100 - ($freeGB / $totalGB * 100)
    $status  = if ($usedPct -ge 90) { 'WARN' } else { 'OK' }
    Write-Status 'Arbeitsspeicher' $status ("{0:N1} GB gesamt | {1:N1} GB frei | {2:N0}% belegt" -f $totalGB, $freeGB, $usedPct)
}

Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $disk = $_
    Invoke-Test "Laufwerk $($disk.DeviceID)" {
        $freePct = if ($disk.Size) { $disk.FreeSpace / $disk.Size * 100 } else { 0 }
        $status  = if ($freePct -lt 5) { 'FAIL' } elseif ($freePct -lt 15) { 'WARN' } else { 'OK' }
        Write-Status "Laufwerk $($disk.DeviceID)" $status ("{0:N0} GB frei von {1:N0} GB ({2:N0}%)" -f `
            ($disk.FreeSpace / 1GB), ($disk.Size / 1GB), $freePct)
    }
}

Invoke-Test 'Grafik' {
    $gpus = Get-CimInstance Win32_VideoController
    foreach ($gpu in $gpus) {
        $status = if ($gpu.Status -eq 'OK') { 'OK' } else { 'WARN' }
        Write-Status 'Grafik' $status $gpu.Name
    }
}

Invoke-Test 'Netzwerk' {
    $adapters = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
    if (-not $adapters) {
        Write-Status 'Netzwerk' 'FAIL' 'Kein aktiver Netzwerkadapter'
        return
    }
    Write-Status 'Netzwerk' 'OK' (($adapters | Select-Object -First 2 -ExpandProperty Name) -join ', ')
}

Invoke-Test 'Internet' {
    $reply = [System.Net.NetworkInformation.Ping]::new().Send('1.1.1.1', 1500)
    if ($reply.Status -eq 'Success') {
        Write-Status 'Internet' 'OK' ("Erreichbar ({0} ms)" -f $reply.RoundtripTime)
    } else {
        Write-Status 'Internet' 'WARN' "Nicht erreichbar ($($reply.Status))"
    }
}

$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($battery) {
    Invoke-Test 'Akku' {
        $charge  = $battery.EstimatedChargeRemaining
        $plugged = if ($battery.BatteryStatus -eq 2) { 'am Netz' } else { 'Akkubetrieb' }
        $status  = if ($charge -lt 15) { 'WARN' } else { 'OK' }
        Write-Status 'Akku' $status ("{0}% | {1}" -f $charge, $plugged)
    }
}

Invoke-Test 'Laufzeit' {
    $uptime = (Get-Date) - $os.LastBootUpTime
    $status = if ($uptime.TotalDays -ge 14) { 'WARN' } else { 'OK' }
    Write-Status 'Laufzeit' $status ("{0} Tage, {1} Std., {2} Min. seit Neustart" -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
}

# --- Ergebnis -----------------------------------------------------------------
$fails = @($results | Where-Object Status -eq 'FAIL').Count
$warns = @($results | Where-Object Status -eq 'WARN').Count

Write-Host ''
Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkCyan
if ($fails -gt 0) {
    Write-Host "   POST abgeschlossen: $fails Fehler, $warns Warnung(en)" -ForegroundColor Red
    $beeps = @(@(800, 400), @(500, 400))
} elseif ($warns -gt 0) {
    Write-Host "   POST abgeschlossen: $warns Warnung(en)" -ForegroundColor Yellow
    $beeps = @(@(1000, 150), @(1000, 150))
} else {
    Write-Host '   POST abgeschlossen: Alle Tests bestanden' -ForegroundColor Green
    $beeps = @(, @(1000, 150))
}
Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkCyan

if (-not $NoBeep) {
    try { foreach ($b in $beeps) { [Console]::Beep($b[0], $b[1]) } } catch { }
}

# --- Begrüßung ----------------------------------------------------------------
$hour = (Get-Date).Hour
$greeting = switch ($hour) {
    { $_ -lt 5 }  { 'Gute Nacht'; break }
    { $_ -lt 11 } { 'Guten Morgen'; break }
    { $_ -lt 18 } { 'Guten Tag'; break }
    default       { 'Guten Abend' }
}

$name = $env:USERNAME
try {
    $fullName = ([adsi]"WinNT://$env:COMPUTERNAME/$env:USERNAME,user").FullName
    if ($fullName) { $name = "$fullName" }
} catch { }

Write-Host ''
Write-Host "   $greeting, $name!" -ForegroundColor Cyan
Write-Host '   Dein System ist bereit. Viel Erfolg heute!' -ForegroundColor White
Write-Host ''

# --- Automatisch schließen ----------------------------------------------------
for ($i = $Delay; $i -gt 0; $i--) {
    Write-Host ("`r   Fenster schließt in {0,2} Sekunden ...  " -f $i) -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
Write-Host ''
exit $fails
