<#
.SYNOPSIS
    POST - Power-On Self-Test

.DESCRIPTION
    Führt einen umfangreichen Selbsttest des Systems durch, begrüßt anschließend
    den Benutzer und schließt sich nach einer einstellbaren Wartezeit automatisch.

    Bereiche:
      Hardware        CPU, Temperatur, RAM, Grafik, Datenträger-Gesundheit, Akku
      Speicherplatz   Laufwerke, Temp-Ordner, Papierkorb
      Netzwerk        Adapter, Gateway, DNS, Internet, Uhrzeit-Abgleich
      Sicherheit      Virenschutz, Defender, Firewall, UAC, Secure Boot, BitLocker, Aktivierung
      Wartung         Ausstehende Updates, letzte Installation, Neustart ausstehend, Laufzeit
      Systemzustand   Ereignisprotokoll, Abstürze, App-Abstürze, Dienste, Geräte, Prozesse, Autostart

    Einige Tests (z. B. Temperatur, SSD-Verschleiß) liefern nur mit Administratorrechten Daten.

.PARAMETER Delay
    Sekunden bis zum automatischen Schließen (Standard: 10).

.PARAMETER NoBeep
    Unterdrückt den POST-Piepton.

.PARAMETER Quick
    Überspringt langsame Tests (Update-Suche, Temp-Ordner, Papierkorb).

.EXAMPLE
    .\POST.ps1
    .\POST.ps1 -Delay 5 -NoBeep -Quick
#>
param(
    [int]$Delay = 10,
    [switch]$NoBeep,
    [switch]$Quick
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'POST - Power-On Self-Test'

$startTime = Get-Date
$results   = [System.Collections.Generic.List[object]]::new()
$isAdmin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)

# Update-Suche dauert oft lange -> sofort im Hintergrund starten
$updateJob = $null
if (-not $Quick) {
    $updateJob = Start-Job -ScriptBlock {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $searcher.Search("IsInstalled=0 and IsHidden=0").Updates | ForEach-Object { $_.Title }
    }
}

# --- Hilfsfunktionen ----------------------------------------------------------
function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Title.Length)) -ForegroundColor DarkCyan
}

function Write-Status {
    param(
        [string]$Name,
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO', 'SKIP')][string]$Status,
        [string]$Detail
    )
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Cyan'; SKIP = 'DarkGray' }[$Status]
    Write-Host ('  {0,-24}' -f $Name) -NoNewline -ForegroundColor Gray
    Write-Host ('[{0,-4}] ' -f $Status) -NoNewline -ForegroundColor $color
    Write-Host $Detail -ForegroundColor White
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

function Write-Detail {
    param([string]$Text)
    Write-Host ((' ' * 33) + $Text) -ForegroundColor DarkGray
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)

    Write-Host ('  {0,-24}' -f $Name) -NoNewline -ForegroundColor Gray
    Write-Host 'prüfe ...' -NoNewline -ForegroundColor DarkGray
    Write-Host "`r" -NoNewline
    try {
        & $Test
    } catch {
        Write-Status $Name 'SKIP' "Test nicht möglich: $($_.Exception.Message.Split("`n")[0].Trim())"
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($item) { return $item.$Name }
}

# --- Kopfzeile ----------------------------------------------------------------
Clear-Host
Write-Host ''
Write-Host '  ================================================================' -ForegroundColor DarkCyan
Write-Host '   POST  -  Power-On Self-Test' -ForegroundColor Cyan
Write-Host ("   {0:dddd, dd. MMMM yyyy  HH:mm:ss}" -f $startTime) -ForegroundColor DarkGray
$mode = if ($isAdmin) { 'Administrator' } else { 'Standardbenutzer (einige Tests eingeschränkt)' }
Write-Host "   Rechner: $env:COMPUTERNAME  |  Modus: $mode" -ForegroundColor DarkGray
Write-Host '  ================================================================' -ForegroundColor DarkCyan

$os         = Get-CimInstance Win32_OperatingSystem
$fixedDisks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
$upAdapters = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and
                               $_.NetworkInterfaceType -ne 'Tunnel' })

# ==============================================================================
Write-Section 'Hardware'
# ==============================================================================
Invoke-Test 'Betriebssystem' {
    $version = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
    Write-Status 'Betriebssystem' 'INFO' ("{0} {1} (Build {2})" -f $os.Caption, $version, $os.BuildNumber)
}

Invoke-Test 'Prozessor' {
    $cpus = @(Get-CimInstance Win32_Processor)
    $load = ($cpus | Measure-Object LoadPercentage -Average).Average
    $status = if ($load -ge 90) { 'WARN' } else { 'OK' }
    Write-Status 'Prozessor' $status ("{0} | {1} Kerne / {2} Threads | Last {3}%" -f `
        $cpus[0].Name.Trim(), $cpus[0].NumberOfCores, $cpus[0].NumberOfLogicalProcessors, [int]$load)
}

# Temperatur nur anzeigen, wenn das System sie liefert (meist nur als Admin)
$thermal = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue)
if ($thermal.Count -gt 0) {
    Invoke-Test 'Temperatur' {
        $maxC = ($thermal | ForEach-Object { $_.CurrentTemperature / 10 - 273.15 } | Measure-Object -Maximum).Maximum
        $status = if ($maxC -ge 90) { 'FAIL' } elseif ($maxC -ge 75) { 'WARN' } else { 'OK' }
        Write-Status 'Temperatur' $status ('{0:N0} °C (wärmste Thermalzone)' -f $maxC)
    }
}

Invoke-Test 'Arbeitsspeicher' {
    $totalB  = $os.TotalVisibleMemorySize * 1KB
    $freeB   = $os.FreePhysicalMemory * 1KB
    $usedPct = 100 - ($freeB / $totalB * 100)
    $status  = if ($usedPct -ge 90) { 'WARN' } else { 'OK' }
    $modules = @(Get-CimInstance Win32_PhysicalMemory)
    $speed   = ($modules | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
    Write-Status 'Arbeitsspeicher' $status ("{0} gesamt | {1} frei | {2:N0}% belegt | {3} Modul(e) @ {4} MHz" -f `
        (Format-Size $totalB), (Format-Size $freeB), $usedPct, $modules.Count, $speed)
}

Invoke-Test 'Grafik' {
    foreach ($gpu in Get-CimInstance Win32_VideoController) {
        $status = if ($gpu.Status -eq 'OK') { 'OK' } else { 'WARN' }
        $res = if ($gpu.CurrentHorizontalResolution) {
            " | {0}x{1} @ {2} Hz" -f $gpu.CurrentHorizontalResolution, $gpu.CurrentVerticalResolution, $gpu.CurrentRefreshRate
        }
        Write-Status 'Grafik' $status ("{0} | Treiber {1}{2}" -f $gpu.Name, $gpu.DriverVersion, $res)
    }
}

Invoke-Test 'Datenträger-Gesundheit' {
    foreach ($pd in Get-PhysicalDisk) {
        $health = "$($pd.HealthStatus)"
        $status = switch ($health) { 'Healthy' { 'OK' } 'Warning' { 'WARN' } default { 'FAIL' } }
        $extra  = ''
        if ($isAdmin) {
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($rc -and $null -ne $rc.Wear)        { $extra += " | Verschleiß $($rc.Wear)%" ; if ($rc.Wear -ge 80) { $status = 'WARN' } }
            if ($rc -and $rc.Temperature -gt 0)     { $extra += " | $($rc.Temperature) °C" }
        }
        Write-Status 'Datenträger-Gesundheit' $status ("{0} ({1}, {2}, {3}) - {4}{5}" -f `
            $pd.FriendlyName, $pd.BusType, $pd.MediaType, (Format-Size $pd.Size), $health, $extra)
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

# ==============================================================================
Write-Section 'Speicherplatz'
# ==============================================================================
foreach ($disk in $fixedDisks) {
    Invoke-Test "Laufwerk $($disk.DeviceID)" {
        $freePct = if ($disk.Size) { $disk.FreeSpace / $disk.Size * 100 } else { 0 }
        $status  = if ($freePct -lt 5) { 'FAIL' } elseif ($freePct -lt 15) { 'WARN' } else { 'OK' }
        $label   = if ($disk.VolumeName) { " [$($disk.VolumeName)]" } else { '' }
        Write-Status "Laufwerk $($disk.DeviceID)" $status ("{0} frei von {1} ({2:N0}%){3}" -f `
            (Format-Size $disk.FreeSpace), (Format-Size $disk.Size), $freePct, $label)
    }
}

if (-not $Quick) {
    Invoke-Test 'Temp-Ordner' {
        $size = (Get-ChildItem $env:TEMP -Recurse -Force -File -ErrorAction SilentlyContinue |
                 Measure-Object Length -Sum).Sum
        $status = if ($size -ge 5GB) { 'WARN' } else { 'OK' }
        Write-Status 'Temp-Ordner' $status ("{0} in {1}" -f (Format-Size $size), $env:TEMP)
    }

    Invoke-Test 'Papierkorb' {
        $items = @((New-Object -ComObject Shell.Application).NameSpace(10).Items())
        $size  = ($items | ForEach-Object { $_.ExtendedProperty('Size') } | Measure-Object -Sum).Sum
        $status = if ($size -ge 5GB) { 'WARN' } else { 'OK' }
        Write-Status 'Papierkorb' $status ("{0} Element(e), {1}" -f $items.Count, (Format-Size $size))
    }
}

# ==============================================================================
Write-Section 'Netzwerk'
# ==============================================================================
Invoke-Test 'Netzwerkadapter' {
    if ($upAdapters.Count -eq 0) {
        Write-Status 'Netzwerkadapter' 'FAIL' 'Kein aktiver Netzwerkadapter'
        return
    }
    foreach ($a in $upAdapters) {
        $ip = $a.GetIPProperties().UnicastAddresses |
              Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        $speed = if ($a.Speed -gt 0) { '{0:N0} Mbit/s' -f ($a.Speed / 1e6) } else { '?' }
        Write-Status 'Netzwerkadapter' 'OK' ("{0} | {1} | {2}" -f $a.Name, $ip.Address, $speed)
    }
}

Invoke-Test 'Gateway' {
    $gw = $upAdapters | ForEach-Object { $_.GetIPProperties().GatewayAddresses } |
          Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and "$($_.Address)" -ne '0.0.0.0' } |
          Select-Object -First 1
    if (-not $gw) { Write-Status 'Gateway' 'FAIL' 'Kein Standardgateway konfiguriert'; return }
    $reply = [System.Net.NetworkInformation.Ping]::new().Send($gw.Address, 1000)
    if ($reply.Status -eq 'Success') {
        Write-Status 'Gateway' 'OK' ("{0} erreichbar ({1} ms)" -f $gw.Address, $reply.RoundtripTime)
    } else {
        Write-Status 'Gateway' 'WARN' ("{0} antwortet nicht auf Ping" -f $gw.Address)
    }
}

Invoke-Test 'DNS-Auflösung' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $addr = [System.Net.Dns]::GetHostAddresses('www.microsoft.com')
    $sw.Stop()
    $status = if ($sw.ElapsedMilliseconds -ge 1000) { 'WARN' } else { 'OK' }
    Write-Status 'DNS-Auflösung' $status ("www.microsoft.com -> {0} ({1} ms)" -f $addr[0], $sw.ElapsedMilliseconds)
}

Invoke-Test 'Internet' {
    $targets = '1.1.1.1', '8.8.8.8'
    $times = foreach ($t in $targets) {
        $r = [System.Net.NetworkInformation.Ping]::new().Send($t, 1500)
        if ($r.Status -eq 'Success') { $r.RoundtripTime }
    }
    if (-not $times) { Write-Status 'Internet' 'FAIL' 'Nicht erreichbar'; return }
    $avg = ($times | Measure-Object -Average).Average
    $status = if ($avg -ge 150) { 'WARN' } else { 'OK' }
    Write-Status 'Internet' $status ("Erreichbar | Ø {0:N0} ms Latenz" -f $avg)
}

Invoke-Test 'Uhrzeit' {
    $resp = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -Method Head -UseBasicParsing -TimeoutSec 5
    $date = @($resp.Headers['Date'])[0]
    $server = [DateTime]::ParseExact($date, 'r', [Globalization.CultureInfo]::InvariantCulture)
    $diff = ((Get-Date).ToUniversalTime() - $server).TotalSeconds
    $status = if ([math]::Abs($diff) -ge 120) { 'FAIL' } elseif ([math]::Abs($diff) -ge 10) { 'WARN' } else { 'OK' }
    Write-Status 'Uhrzeit' $status ("Abweichung zur Internetzeit: {0:+0;-0;0} s" -f $diff)
}

# ==============================================================================
Write-Section 'Sicherheit'
# ==============================================================================
Invoke-Test 'Virenschutz' {
    $avs = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct)
    if ($avs.Count -eq 0) { Write-Status 'Virenschutz' 'FAIL' 'Kein Virenschutz registriert'; return }
    $active = @($avs | Where-Object { ([int]$_.productState -band 0x1000) -ne 0 })
    if ($active.Count -eq 0) {
        Write-Status 'Virenschutz' 'FAIL' ("Kein Virenschutz aktiv ({0})" -f (($avs.displayName) -join ', '))
        return
    }
    foreach ($av in $active) {
        $outdated = ([int]$av.productState -band 0x10) -ne 0
        if ($outdated) { Write-Status 'Virenschutz' 'WARN' "$($av.displayName) aktiv, aber Signaturen veraltet" }
        else           { Write-Status 'Virenschutz' 'OK'   "$($av.displayName) aktiv und aktuell" }
    }
}

Invoke-Test 'Defender-Details' {
    $mp = Get-MpComputerStatus
    if (-not $mp.AntivirusEnabled) { Write-Status 'Defender-Details' 'INFO' 'Defender ist nicht der aktive Virenschutz'; return }
    $status = 'OK'
    if (-not $mp.RealTimeProtectionEnabled) { $status = 'FAIL' }
    elseif ($mp.AntivirusSignatureAge -gt 3) { $status = 'WARN' }
    $rt = if ($mp.RealTimeProtectionEnabled) { 'Echtzeitschutz an' } else { 'Echtzeitschutz AUS' }
    $scan = if ($mp.QuickScanAge -lt 0 -or $mp.QuickScanAge -gt 10000) { 'nie' } else { "vor $($mp.QuickScanAge) Tag(en)" }
    Write-Status 'Defender-Details' $status ("{0} | Signaturen {1} Tag(e) alt | Letzter Schnellscan {2}" -f `
        $rt, $mp.AntivirusSignatureAge, $scan)
}

Invoke-Test 'Firewall' {
    $profiles = @(Get-NetFirewallProfile)
    $off = @($profiles | Where-Object { -not $_.Enabled } | ForEach-Object Name)
    if ($off.Count -eq 0) { Write-Status 'Firewall' 'OK' ("Alle Profile aktiv ({0})" -f (($profiles.Name) -join ', ')) }
    else                  { Write-Status 'Firewall' 'WARN' ("Deaktiviert: {0}" -f ($off -join ', ')) }
}

Invoke-Test 'Benutzerkontensteuerung' {
    $lua = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
    if ($lua -eq 1) { Write-Status 'Benutzerkontensteuerung' 'OK' 'UAC aktiv' }
    else            { Write-Status 'Benutzerkontensteuerung' 'FAIL' 'UAC deaktiviert' }
}

Invoke-Test 'Secure Boot' {
    $sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    if ($null -eq $sb) { Write-Status 'Secure Boot' 'INFO' 'Nicht unterstützt (Legacy-BIOS?)' }
    elseif ($sb -eq 1) { Write-Status 'Secure Boot' 'OK' 'Aktiv' }
    else               { Write-Status 'Secure Boot' 'WARN' 'Unterstützt, aber deaktiviert' }
}

Invoke-Test 'BitLocker' {
    $shell = New-Object -ComObject Shell.Application
    $map = @{ 1 = 'Aktiv'; 2 = 'Aus'; 3 = 'Wird verschlüsselt'; 4 = 'Wird entschlüsselt'; 5 = 'Angehalten'; 6 = 'Aktiv (gesperrt)' }
    $parts = foreach ($disk in $fixedDisks) {
        $v = $shell.NameSpace("$($disk.DeviceID)\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
        $text = if ($null -ne $v -and $map.ContainsKey([int]$v)) { $map[[int]$v] } else { 'nicht verfügbar' }
        "$($disk.DeviceID) $text"
    }
    Write-Status 'BitLocker' 'INFO' ($parts -join ' | ')
}

Invoke-Test 'Windows-Aktivierung' {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter `
        "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    $map = @{ 0 = 'Nicht lizenziert'; 1 = 'Aktiviert'; 2 = 'Kulanzzeit'; 3 = 'Kulanzzeit'; 4 = 'Nicht echt'; 5 = 'Benachrichtigungsmodus'; 6 = 'Erweiterte Kulanzzeit' }
    $status = if ($lic.LicenseStatus -eq 1) { 'OK' } else { 'WARN' }
    Write-Status 'Windows-Aktivierung' $status $map[[int]$lic.LicenseStatus]
}

# ==============================================================================
Write-Section 'Wartung'
# ==============================================================================
if ($updateJob) {
    Invoke-Test 'Windows-Updates' {
        $remaining = [math]::Max(1, 90 - ((Get-Date) - $startTime).TotalSeconds)
        if (-not (Wait-Job $updateJob -Timeout $remaining)) {
            Write-Status 'Windows-Updates' 'SKIP' 'Update-Suche dauert zu lange - übersprungen'
            return
        }
        if ($updateJob.State -eq 'Failed') {
            Write-Status 'Windows-Updates' 'SKIP' "Update-Suche fehlgeschlagen: $($updateJob.ChildJobs[0].JobStateInfo.Reason.Message)"
            return
        }
        $titles = @(Receive-Job $updateJob -ErrorAction SilentlyContinue)
        if ($titles.Count -eq 0) {
            Write-Status 'Windows-Updates' 'OK' 'Keine ausstehenden Updates'
        } else {
            Write-Status 'Windows-Updates' 'WARN' "$($titles.Count) Update(s) verfügbar"
            $titles | Select-Object -First 4 | ForEach-Object {
                $t = if ($_.Length -gt 75) { $_.Substring(0, 72) + '...' } else { $_ }
                Write-Detail "- $t"
            }
            if ($titles.Count -gt 4) { Write-Detail "  ... und $($titles.Count - 4) weitere" }
        }
    }
}

Invoke-Test 'Letzte Installation' {
    $au = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results
    $installed = $au.LastInstallationSuccessDate
    $searched  = $au.LastSearchSuccessDate
    if (-not $installed -or $installed.Year -lt 2000) {
        Write-Status 'Letzte Installation' 'WARN' 'Keine erfolgreiche Update-Installation bekannt'
        return
    }
    $days = [int]((Get-Date) - $installed.ToLocalTime()).TotalDays
    $status = if ($days -ge 45) { 'WARN' } else { 'OK' }
    $searchText = if ($searched -and $searched.Year -ge 2000) { '{0:dd.MM.yyyy HH:mm}' -f $searched.ToLocalTime() } else { 'nie' }
    Write-Status 'Letzte Installation' $status ("{0:dd.MM.yyyy} (vor {1} Tag(en)) | Letzte Suche: {2}" -f `
        $installed.ToLocalTime(), $days, $searchText)
}

Invoke-Test 'Neustart ausstehend' {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'Windows-Komponenten (CBS)'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update'
    }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') {
        $reasons += 'Ausstehende Dateioperationen'
    }
    $active  = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName'
    $pending = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName'
    if ($active -ne $pending) { $reasons += "Computername-Änderung ($active -> $pending)" }

    if ($reasons.Count -eq 0) { Write-Status 'Neustart ausstehend' 'OK' 'Nein' }
    else                      { Write-Status 'Neustart ausstehend' 'WARN' ("Ja: {0}" -f ($reasons -join ', ')) }
}

Invoke-Test 'Laufzeit' {
    $uptime = (Get-Date) - $os.LastBootUpTime
    $status = if ($uptime.TotalDays -ge 14) { 'WARN' } else { 'OK' }
    Write-Status 'Laufzeit' $status ("{0} Tage, {1} Std., {2} Min. seit Neustart ({3:dd.MM. HH:mm})" -f `
        $uptime.Days, $uptime.Hours, $uptime.Minutes, $os.LastBootUpTime)
}

Invoke-Test 'Energieplan' {
    $line = powercfg /getactivescheme
    $name = if ("$line" -match '\((.+)\)') { $Matches[1] } else { "$line" }
    Write-Status 'Energieplan' 'INFO' $name
}

# ==============================================================================
Write-Section 'Systemzustand'
# ==============================================================================
Invoke-Test 'Ereignisprotokoll (24h)' {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } `
                -ErrorAction SilentlyContinue)
    $critical = @($events | Where-Object Level -eq 1).Count
    $errors   = $events.Count - $critical
    $status = if ($critical -gt 0) { 'WARN' } elseif ($errors -gt 20) { 'WARN' } else { 'OK' }
    Write-Status 'Ereignisprotokoll (24h)' $status ("{0} kritisch | {1} Fehler" -f $critical, $errors)
    $events | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        Write-Detail ("- {0}x {1}" -f $_.Count, $_.Name)
    }
}

Invoke-Test 'Systemabstürze (30T)' {
    $since = (Get-Date).AddDays(-30)
    $power = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
    $bsod  = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue)
    $status = if ($bsod.Count -gt 0) { 'FAIL' } elseif ($power.Count -gt 0) { 'WARN' } else { 'OK' }
    Write-Status 'Systemabstürze (30T)' $status ("{0} Bluescreen(s) | {1} unerwartete(s) Herunterfahren" -f $bsod.Count, $power.Count)
    $last = @($bsod + $power) | Sort-Object TimeCreated -Descending | Select-Object -First 1
    if ($last) { Write-Detail ("Zuletzt: {0:dd.MM.yyyy HH:mm}" -f $last.TimeCreated) }
}

Invoke-Test 'App-Abstürze (7T)' {
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue)
    $status = if ($crashes.Count -ge 10) { 'WARN' } else { 'OK' }
    Write-Status 'App-Abstürze (7T)' $status ("{0} Absturz/Abstürze" -f $crashes.Count)
    $crashes | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        Write-Detail ("- {0}x {1}" -f $_.Count, $_.Name)
    }
}

Invoke-Test 'Dienste' {
    # Automatische Dienste, die mit Fehlercode beendet wurden (1077 = seit Start nie gestartet -> normal)
    $bad = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
             Where-Object { $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 })
    if ($bad.Count -eq 0) {
        Write-Status 'Dienste' 'OK' 'Alle automatischen Dienste fehlerfrei'
    } else {
        Write-Status 'Dienste' 'WARN' "$($bad.Count) automatische(r) Dienst(e) mit Fehler beendet"
        $bad | Select-Object -First 4 | ForEach-Object { Write-Detail ("- {0} (Code {1})" -f $_.DisplayName, $_.ExitCode) }
    }
}

Invoke-Test 'Geräte-Manager' {
    # 22 = vom Benutzer deaktiviert -> kein Fehler
    $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0 AND ConfigManagerErrorCode<>22')
    if ($bad.Count -eq 0) {
        Write-Status 'Geräte-Manager' 'OK' 'Keine Gerätefehler'
    } else {
        Write-Status 'Geräte-Manager' 'WARN' "$($bad.Count) Gerät(e) mit Problemen"
        $bad | Select-Object -First 4 | ForEach-Object {
            $n = if ($_.Name) { $_.Name } else { $_.DeviceID }
            Write-Detail ("- {0} (Code {1})" -f $n, $_.ConfigManagerErrorCode)
        }
    }
}

Invoke-Test 'Speicherfresser' {
    $top = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
    } | Sort-Object Bytes -Descending | Select-Object -First 3
    Write-Status 'Speicherfresser' 'INFO' (($top | ForEach-Object { "{0} ({1})" -f $_.Name, (Format-Size $_.Bytes) }) -join ', ')
}

Invoke-Test 'Autostart' {
    $count = @(Get-CimInstance Win32_StartupCommand).Count
    $status = if ($count -ge 15) { 'WARN' } else { 'INFO' }
    Write-Status 'Autostart' $status "$count Programm(e) im Autostart"
}

if ($updateJob) { Remove-Job $updateJob -Force -ErrorAction SilentlyContinue }

# --- Ergebnis -----------------------------------------------------------------
$fails    = @($results | Where-Object Status -eq 'FAIL')
$warns    = @($results | Where-Object Status -eq 'WARN')
$passed   = @($results | Where-Object Status -eq 'OK').Count
$duration = ((Get-Date) - $startTime).TotalSeconds

Write-Host ''
Write-Host '  ================================================================' -ForegroundColor DarkCyan
$summary = "   POST abgeschlossen in {0:N1} s: {1} OK, {2} Warnung(en), {3} Fehler" -f $duration, $passed, $warns.Count, $fails.Count
if ($fails.Count -gt 0) {
    Write-Host $summary -ForegroundColor Red
    $beeps = @(@(800, 400), @(500, 400))
} elseif ($warns.Count -gt 0) {
    Write-Host $summary -ForegroundColor Yellow
    $beeps = @(@(1000, 150), @(1000, 150))
} else {
    Write-Host $summary -ForegroundColor Green
    $beeps = @(, @(1000, 150))
}
foreach ($r in @($fails) + @($warns)) {
    $color = if ($r.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
    Write-Host ("     ! {0}: {1}" -f $r.Name, $r.Detail) -ForegroundColor $color
}
Write-Host '  ================================================================' -ForegroundColor DarkCyan

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
    if ("$fullName") { $name = "$fullName" }
} catch { }

$outro = if ($fails.Count -gt 0) { 'Bitte wirf einen Blick auf die Fehler oben.' }
         elseif ($warns.Count -gt 0) { 'Dein System ist bereit - ein paar Kleinigkeiten könnten Aufmerksamkeit vertragen.' }
         else { 'Dein System ist in Topform. Viel Erfolg heute!' }

Write-Host ''
Write-Host "   $greeting, $name!" -ForegroundColor Cyan
Write-Host "   $outro" -ForegroundColor White
Write-Host ''

# --- Automatisch schließen ----------------------------------------------------
for ($i = $Delay; $i -gt 0; $i--) {
    Write-Host ("`r   Fenster schließt in {0,2} Sekunden ...  " -f $i) -NoNewline -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
Write-Host ''
exit $fails.Count
