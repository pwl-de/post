param(
    [int]$Delay = 10,
    [switch]$Quick,
    [switch]$ShowAll
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'POST - Power-On Self-Test'

$startTime = Get-Date
$results   = [System.Collections.Generic.List[object]]::new()
$sections  = [System.Collections.Generic.List[string]]::new()
$isAdmin   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)

$updateJob = $null
if (-not $Quick) {
    $updateJob = Start-Job -ScriptBlock {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $searcher.Search("IsInstalled=0 and IsHidden=0").Updates | ForEach-Object { $_.Title }
    }
}

function Set-Section {
    param([string]$Name)
    $script:section = $Name
    $sections.Add($Name)
}

function Add-Result {
    param(
        [string]$Name,
        [ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = '',
        [string[]]$Lines = @()
    )
    $results.Add([pscustomobject]@{
        Section = $script:section; Name = $Name; Status = $Status; Detail = $Detail; Lines = $Lines
    })
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Test, [switch]$AdminOnly)

    Write-Host ("`r   Prüfe: {0}" -f $Name).PadRight(70) -NoNewline -ForegroundColor DarkGray
    if ($AdminOnly -and -not $isAdmin) {
        Add-Result $Name 'SKIP' 'Benötigt Administratorrechte'
        return
    }
    try {
        & $Test
    } catch {
        Add-Result $Name 'SKIP' "Prüfung nicht möglich: $($_.Exception.Message.Split("`n")[0].Trim())"
    }
}

function Get-Events {
    param([hashtable]$Filter)
    @(Get-WinEvent -FilterHashtable $Filter -ErrorAction SilentlyContinue)
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

function Format-Top {

    param($Events, [scriptblock]$Key, [int]$Count = 3)
    @($Events | Group-Object $Key | Sort-Object Count -Descending | Select-Object -First $Count |
        ForEach-Object { "- {0}x {1}" -f $_.Count, $_.Name })
}

$os         = Get-CimInstance Win32_OperatingSystem
$cpus       = @(Get-CimInstance Win32_Processor)
$gpus       = @(Get-CimInstance Win32_VideoController)
$fixedDisks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
$upAdapters = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -notin 'Loopback', 'Tunnel' })
$mainAdapter = $upAdapters | Where-Object {
                   $_.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and "$($_.Address)" -ne '0.0.0.0' }
               } | Select-Object -First 1
$mainIp = if ($mainAdapter) {
    ($mainAdapter.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).Address
}
$version = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
$uptime  = (Get-Date) - $os.LastBootUpTime
$sysDisk = $fixedDisks | Where-Object DeviceID -eq $env:SystemDrive

Clear-Host
Write-Host ''
Write-Host '  ====================================================================' -ForegroundColor DarkCyan
Write-Host '   POST  -  Power-On Self-Test' -ForegroundColor Cyan
Write-Host '   by p4ckets  |  https://github.com/pwl-de' -ForegroundColor DarkGray
Write-Host ("   {0:dddd, dd. MMMM yyyy  HH:mm}" -f $startTime) -ForegroundColor DarkGray
Write-Host '  ====================================================================' -ForegroundColor DarkCyan

function Write-Info {
    param([string]$Label, [string]$Text)
    Write-Host ('   {0,-10}' -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Gray
}
$mode = if ($isAdmin) { 'Administrator' } else { 'Standardbenutzer' }
Write-Info 'System'   ("{0} {1} (Build {2})" -f $os.Caption, $version, $os.BuildNumber)
Write-Info 'Rechner'  ("{0} | {1} | {2}" -f $env:COMPUTERNAME, $env:USERNAME, $mode)
Write-Info 'CPU'      $cpus[0].Name.Trim()
Write-Info 'RAM'      (Format-Size ($os.TotalVisibleMemorySize * 1KB))
Write-Info 'Grafik'   (($gpus.Name) -join ', ')
if ($sysDisk) {
    Write-Info 'Laufwerk' ("{0} {1} frei von {2}" -f $sysDisk.DeviceID, (Format-Size $sysDisk.FreeSpace), (Format-Size $sysDisk.Size))
}
Write-Info 'Netzwerk' $(if ($mainAdapter) { "$mainIp ($($mainAdapter.Name))" } else { 'keine Verbindung' })
Write-Info 'Laufzeit' ("{0} T {1} Std {2} Min (seit {3:dd.MM. HH:mm})" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $os.LastBootUpTime)
Write-Host ''

Set-Section 'Hardware'

Invoke-Test 'CPU-Auslastung' {
    $load = ($cpus | Measure-Object LoadPercentage -Average).Average
    if ($load -ge 95) { Add-Result 'CPU-Auslastung' 'WARN' "Prozessor zu $([int]$load)% ausgelastet" }
    else              { Add-Result 'CPU-Auslastung' 'OK' "$([int]$load)%" }
}

$thermal = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue)
Invoke-Test 'Temperatur' {
    if ($thermal.Count -eq 0) { Add-Result 'Temperatur' 'SKIP' 'Kein Sensor verfügbar (meist nur als Admin)'; return }
    $maxC = ($thermal | ForEach-Object { $_.CurrentTemperature / 10 - 273.15 } | Measure-Object -Maximum).Maximum
    $status = if ($maxC -ge 90) { 'FAIL' } elseif ($maxC -ge 75) { 'WARN' } else { 'OK' }
    Add-Result 'Temperatur' $status ('{0:N0} °C' -f $maxC) @('Tipp: Lüfter und Staubfilter prüfen')
}

Invoke-Test 'CPU-Drosselung' {
    $ev = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = (Get-Date).AddDays(-7) }
    if ($ev.Count -gt 0) {
        Add-Result 'CPU-Drosselung' 'WARN' "Prozessor wurde $($ev.Count)x von der Firmware gedrosselt (7 Tage)" `
            @('Mögliche Ursache: Überhitzung oder Stromversorgung')
    } else { Add-Result 'CPU-Drosselung' 'OK' }
}

Invoke-Test 'Arbeitsspeicher' {
    $usedPct = 100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100)
    if ($usedPct -lt 90) { Add-Result 'Arbeitsspeicher' 'OK' ('{0:N0}% belegt' -f $usedPct); return }
    $top = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum }
    } | Sort-Object Bytes -Descending | Select-Object -First 3
    Add-Result 'Arbeitsspeicher' 'WARN' ('{0:N0}% belegt' -f $usedPct) `
        @('Größte Verbraucher: ' + (($top | ForEach-Object { "{0} ({1})" -f $_.Name, (Format-Size $_.Bytes) }) -join ', '))
}

Invoke-Test 'Auslagerung' {
    $commitPct = 100 - ($os.FreeVirtualMemory / $os.TotalVirtualMemorySize * 100)
    $pf = @(Get-CimInstance Win32_PageFileUsage)
    $pfPct = if ($pf.Count -and ($pf | Measure-Object AllocatedBaseSize -Sum).Sum) {
        ($pf | Measure-Object CurrentUsage -Sum).Sum / ($pf | Measure-Object AllocatedBaseSize -Sum).Sum * 100
    } else { 0 }
    if ($pf.Count -eq 0) {
        Add-Result 'Auslagerung' 'WARN' 'Keine Auslagerungsdatei konfiguriert' @('Kann zu Abstürzen bei Speichermangel führen')
    } elseif ($commitPct -ge 90 -or $pfPct -ge 80) {
        Add-Result 'Auslagerung' 'WARN' ('Zugesicherter Speicher {0:N0}% | Auslagerungsdatei {1:N0}% belegt' -f $commitPct, $pfPct)
    } else { Add-Result 'Auslagerung' 'OK' }
}

Invoke-Test 'Hardwarefehler (WHEA)' {
    $ev = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-30) }
    $fatal = @($ev | Where-Object Level -le 2)
    if ($fatal.Count -gt 0) {
        Add-Result 'Hardwarefehler (WHEA)' 'FAIL' "$($fatal.Count) schwere(r) Hardwarefehler (30 Tage)" `
            (@("Zuletzt: {0:dd.MM.yyyy HH:mm}" -f $fatal[0].TimeCreated) + @('Hinweis auf defekte CPU, RAM, Mainboard oder Übertaktung'))
    } elseif ($ev.Count -gt 0) {
        Add-Result 'Hardwarefehler (WHEA)' 'WARN' "$($ev.Count) korrigierte(r) Hardwarefehler (30 Tage)" `
            @('Häufig PCIe-Fehler - Treiber/BIOS aktualisieren, Steckplätze prüfen')
    } else { Add-Result 'Hardwarefehler (WHEA)' 'OK' }
}

Invoke-Test 'Grafik' {
    $bad = @($gpus | Where-Object Status -ne 'OK')
    $tdr = Get-Events @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = (Get-Date).AddDays(-30) }
    foreach ($g in $bad) { Add-Result 'Grafik' 'FAIL' "$($g.Name): Status $($g.Status)" }
    if ($tdr.Count -gt 0) {
        Add-Result 'Grafik' 'WARN' "Grafiktreiber wurde $($tdr.Count)x zurückgesetzt (30 Tage)" `
            @(("Zuletzt: {0:dd.MM.yyyy HH:mm}" -f $tdr[0].TimeCreated), 'Tipp: Grafiktreiber aktualisieren, Übertaktung entfernen')
    }
    if ($bad.Count -eq 0 -and $tdr.Count -eq 0) { Add-Result 'Grafik' 'OK' }
}

Invoke-Test 'Datenträger-Gesundheit' {
    foreach ($pd in Get-PhysicalDisk) {
        $name   = "$($pd.FriendlyName) ($($pd.MediaType), $(Format-Size $pd.Size))"
        $health = "$($pd.HealthStatus)"
        if ($health -ne 'Healthy') {
            $status = if ($health -eq 'Warning') { 'WARN' } else { 'FAIL' }
            Add-Result 'Datenträger-Gesundheit' $status "$name meldet: $health" @('Daten sichern und Datenträger ersetzen!')
            continue
        }
        if ($isAdmin) {
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            if ($rc -and $rc.Wear -ge 80) {
                Add-Result 'Datenträger-Gesundheit' 'WARN' "$name zu $($rc.Wear)% verschlissen"; continue
            }
            if ($rc -and $rc.Temperature -ge 70) {
                Add-Result 'Datenträger-Gesundheit' 'WARN' "$name ist $($rc.Temperature) °C heiß"; continue
            }
        }
        Add-Result 'Datenträger-Gesundheit' 'OK' $name
    }
}

Invoke-Test 'Datenträgerfehler' {
    $since = (Get-Date).AddDays(-30)
    $storage = Get-Events @{ LogName = 'System'; ProviderName = 'disk', 'stornvme', 'storahci'; Level = 1, 2, 3; StartTime = $since }
    $ntfs    = Get-Events @{ LogName = 'System'; ProviderName = 'Ntfs', 'Microsoft-Windows-Ntfs'; Level = 1, 2; StartTime = $since }
    $all = @($storage) + @($ntfs)
    if ($all.Count -gt 0) {
        Add-Result 'Datenträgerfehler' 'FAIL' "$($all.Count) Datenträger-/Dateisystemfehler im Ereignisprotokoll (30 Tage)" `
            ((Format-Top $all { "$($_.ProviderName) (ID $($_.Id))" }) + @('Daten sichern, Kabel/Anschluss prüfen, chkdsk ausführen'))
    } else { Add-Result 'Datenträgerfehler' 'OK' }
}

Invoke-Test 'Dateisystem' {
    $dirty = @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' | Where-Object { $_.DriveLetter -and $_.DirtyBitSet })
    if ($dirty.Count -gt 0) {
        Add-Result 'Dateisystem' 'FAIL' ("Dateisystem als beschädigt markiert: {0}" -f (($dirty.DriveLetter) -join ', ')) `
            @('Tipp: chkdsk /f beim nächsten Neustart ausführen')
    } else { Add-Result 'Dateisystem' 'OK' }
}

$battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($battery) {
    Invoke-Test 'Akku' {
        if ($battery.EstimatedChargeRemaining -lt 15 -and $battery.BatteryStatus -ne 2) {
            Add-Result 'Akku' 'WARN' "Nur noch $($battery.EstimatedChargeRemaining)% - Netzteil anschließen"
        }
        $full   = (Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        $design = (Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1).DesignedCapacity
        if ($full -and $design) {
            $healthPct = $full / $design * 100
            if ($healthPct -lt 60) { Add-Result 'Akku' 'WARN' ('Akkukapazität nur noch {0:N0}% des Neuzustands' -f $healthPct) }
        }
        if (-not ($results | Where-Object { $_.Name -eq 'Akku' })) { Add-Result 'Akku' 'OK' }
    }
}

Invoke-Test 'Geräte-Manager' {

    $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0 AND ConfigManagerErrorCode<>22')
    if ($bad.Count -gt 0) {
        Add-Result 'Geräte-Manager' 'WARN' "$($bad.Count) Gerät(e) mit Problemen" `
            @($bad | Select-Object -First 5 | ForEach-Object {
                $n = if ($_.Name) { $_.Name } else { $_.DeviceID }
                "- {0} (Code {1})" -f $n, $_.ConfigManagerErrorCode
            })
    } else { Add-Result 'Geräte-Manager' 'OK' }
}

Set-Section 'Speicherplatz'

foreach ($disk in $fixedDisks) {
    Invoke-Test "Laufwerk $($disk.DeviceID)" {
        $freePct = if ($disk.Size) { $disk.FreeSpace / $disk.Size * 100 } else { 0 }
        $status  = if ($freePct -lt 5) { 'FAIL' } elseif ($freePct -lt 15) { 'WARN' } else { 'OK' }
        Add-Result "Laufwerk $($disk.DeviceID)" $status ("Nur noch {0} frei ({1:N0}%)" -f (Format-Size $disk.FreeSpace), $freePct) `
            @('Tipp: Datenträgerbereinigung (cleanmgr) ausführen')
    }
}

if (-not $Quick) {
    Invoke-Test 'Temp-Ordner' {
        $size = (Get-ChildItem $env:TEMP -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $status = if ($size -ge 5GB) { 'WARN' } else { 'OK' }
        Add-Result 'Temp-Ordner' $status ("{0} temporäre Dateien" -f (Format-Size $size)) @("Ordner: $env:TEMP")
    }

    Invoke-Test 'Papierkorb' {
        $items = @((New-Object -ComObject Shell.Application).NameSpace(10).Items())
        $size  = ($items | ForEach-Object { $_.ExtendedProperty('Size') } | Measure-Object -Sum).Sum
        $status = if ($size -ge 5GB) { 'WARN' } else { 'OK' }
        Add-Result 'Papierkorb' $status ("{0} im Papierkorb" -f (Format-Size $size))
    }
}

Set-Section 'Netzwerk'

Invoke-Test 'Netzwerkverbindung' {
    if ($upAdapters.Count -eq 0) { Add-Result 'Netzwerkverbindung' 'FAIL' 'Kein aktiver Netzwerkadapter'; return }
    if (-not $mainAdapter)       { Add-Result 'Netzwerkverbindung' 'FAIL' 'Kein Standardgateway - keine Verbindung ins Netz'; return }
    if ("$mainIp" -like '169.254.*') {
        Add-Result 'Netzwerkverbindung' 'FAIL' "Keine IP vom Router erhalten ($mainIp)" @('Tipp: Router neu starten oder ipconfig /renew')
        return
    }
    Add-Result 'Netzwerkverbindung' 'OK'
}

Invoke-Test 'Gateway' {
    if (-not $mainAdapter) { Add-Result 'Gateway' 'SKIP' 'Kein Gateway'; return }
    $gw = $mainAdapter.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
    $reply = [System.Net.NetworkInformation.Ping]::new().Send($gw.Address, 1000)
    if ($reply.Status -ne 'Success') { Add-Result 'Gateway' 'WARN' "Router $($gw.Address) antwortet nicht" }
    elseif ($reply.RoundtripTime -ge 50) { Add-Result 'Gateway' 'WARN' "Router antwortet langsam ($($reply.RoundtripTime) ms)" @('Hinweis auf schwaches WLAN oder überlastetes Netz') }
    else { Add-Result 'Gateway' 'OK' }
}

Invoke-Test 'DNS' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { [void][System.Net.Dns]::GetHostAddresses('www.microsoft.com') }
    catch { Add-Result 'DNS' 'FAIL' 'Namensauflösung funktioniert nicht' @('Tipp: ipconfig /flushdns, DNS-Server prüfen'); return }
    $sw.Stop()
    if ($sw.ElapsedMilliseconds -ge 1000) { Add-Result 'DNS' 'WARN' "Namensauflösung langsam ($($sw.ElapsedMilliseconds) ms)" }
    else { Add-Result 'DNS' 'OK' }
}

Invoke-Test 'Internet' {
    $ping  = [System.Net.NetworkInformation.Ping]::new()
    $sent  = 0
    $times = foreach ($t in '1.1.1.1', '8.8.8.8', '1.1.1.1', '8.8.8.8') {
        $sent++
        $r = $ping.Send($t, 1500)
        if ($r.Status -eq 'Success') { $r.RoundtripTime }
    }
    $times = @($times)
    if ($times.Count -eq 0) { Add-Result 'Internet' 'FAIL' 'Internet nicht erreichbar'; return }
    $loss = ($sent - $times.Count) / $sent * 100
    $avg  = ($times | Measure-Object -Average).Average
    if ($loss -gt 0)    { Add-Result 'Internet' 'WARN' ('{0:N0}% Paketverlust' -f $loss) }
    elseif ($avg -ge 150) { Add-Result 'Internet' 'WARN' ('Hohe Latenz (Ø {0:N0} ms)' -f $avg) }
    else { Add-Result 'Internet' 'OK' }
}

Invoke-Test 'Web-Zugriff' {
    $resp = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5
    if ($resp.Content -ne 'Microsoft Connect Test') {
        Add-Result 'Web-Zugriff' 'WARN' 'Webseiten werden umgeleitet (Anmeldeseite/Captive Portal oder Proxy?)'
    } else { Add-Result 'Web-Zugriff' 'OK' }

    $server = [DateTime]::ParseExact(@($resp.Headers['Date'])[0], 'r', [Globalization.CultureInfo]::InvariantCulture)
    $diff = ((Get-Date).ToUniversalTime() - $server).TotalSeconds
    $status = if ([math]::Abs($diff) -ge 120) { 'FAIL' } elseif ([math]::Abs($diff) -ge 10) { 'WARN' } else { 'OK' }
    Add-Result 'Uhrzeit' $status ("Systemuhr weicht {0:+0;-0;0} s von der Internetzeit ab" -f $diff) `
        @('Tipp: als Admin "w32tm /resync" ausführen')
}

Invoke-Test 'Proxy' {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ((Get-RegValue $key 'ProxyEnable') -eq 1) {
        Add-Result 'Proxy' 'WARN' "Proxy aktiv: $(Get-RegValue $key 'ProxyServer')" @('Falls nicht gewollt: Einstellungen > Netzwerk > Proxy')
    } else { Add-Result 'Proxy' 'OK' }
}

Invoke-Test 'Hosts-Datei' {
    $entries = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" |
                 ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -and -not $_.StartsWith('#') -and $_ -notmatch '\slocalhost$' })
    if ($entries.Count -gt 0) {
        Add-Result 'Hosts-Datei' 'WARN' "$($entries.Count) Eintrag/Einträge leiten Adressen um" `
            (@($entries | Select-Object -First 3 | ForEach-Object { "- $_" }) + @('Prüfen, ob gewollt (Malware nutzt das gern)'))
    } else { Add-Result 'Hosts-Datei' 'OK' }
}

Set-Section 'Sicherheit'

Invoke-Test 'Virenschutz' {
    $avs = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct)
    $active = @($avs | Where-Object { ([int]$_.productState -band 0x1000) -ne 0 })
    if ($active.Count -eq 0) { Add-Result 'Virenschutz' 'FAIL' 'Kein Virenschutz aktiv!'; return }
    $outdated = @($active | Where-Object { ([int]$_.productState -band 0x10) -ne 0 })
    if ($outdated.Count -gt 0) { Add-Result 'Virenschutz' 'WARN' "$($outdated[0].displayName): Signaturen veraltet" }
    else { Add-Result 'Virenschutz' 'OK' (($active.displayName) -join ', ') }
}

Invoke-Test 'Defender' {
    $mp = Get-MpComputerStatus
    if (-not $mp.AntivirusEnabled) { Add-Result 'Defender' 'OK' 'Anderer Virenschutz aktiv'; return }
    if (-not $mp.RealTimeProtectionEnabled) { Add-Result 'Defender' 'FAIL' 'Echtzeitschutz ist AUS' }
    elseif ($mp.AntivirusSignatureAge -gt 3) { Add-Result 'Defender' 'WARN' "Virensignaturen $($mp.AntivirusSignatureAge) Tage alt" }
    else { Add-Result 'Defender' 'OK' }
}

Invoke-Test 'Bedrohungen' -AdminOnly {
    $threats = @(Get-MpThreat | Where-Object IsActive)
    if ($threats.Count -gt 0) {
        Add-Result 'Bedrohungen' 'FAIL' "$($threats.Count) aktive Bedrohung(en) gefunden!" `
            (@($threats | Select-Object -First 3 | ForEach-Object { "- $($_.ThreatName)" }) + @('Windows-Sicherheit öffnen und Bedrohungen entfernen'))
    } else { Add-Result 'Bedrohungen' 'OK' }
}

Invoke-Test 'Firewall' {
    $off = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled } | ForEach-Object Name)
    if ($off.Count -gt 0) { Add-Result 'Firewall' 'FAIL' ("Firewall deaktiviert für: {0}" -f ($off -join ', ')) }
    else { Add-Result 'Firewall' 'OK' }
}

Invoke-Test 'Benutzerkontensteuerung' {
    if ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA') -ne 1) {
        Add-Result 'Benutzerkontensteuerung' 'FAIL' 'UAC ist deaktiviert'
    } else { Add-Result 'Benutzerkontensteuerung' 'OK' }
}

Invoke-Test 'Secure Boot' {
    $sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    if ($sb -eq 0) { Add-Result 'Secure Boot' 'WARN' 'Secure Boot ist im BIOS deaktiviert' }
    else { Add-Result 'Secure Boot' 'OK' }
}

Invoke-Test 'BitLocker' {
    $shell = New-Object -ComObject Shell.Application
    $suspended = foreach ($disk in $fixedDisks) {
        $v = $shell.NameSpace("$($disk.DeviceID)\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
        if ($v -eq 5) { $disk.DeviceID }
    }
    if ($suspended) { Add-Result 'BitLocker' 'WARN' ("Verschlüsselung angehalten: {0}" -f (@($suspended) -join ', ')) }
    else { Add-Result 'BitLocker' 'OK' }
}

Invoke-Test 'Windows-Aktivierung' {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter `
        "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    $map = @{ 0 = 'Nicht lizenziert'; 2 = 'Kulanzzeit'; 3 = 'Kulanzzeit'; 4 = 'Nicht echt'; 5 = 'Benachrichtigungsmodus'; 6 = 'Erweiterte Kulanzzeit' }
    if (-not $lic) { Add-Result 'Windows-Aktivierung' 'WARN' 'Kein Produktschlüssel gefunden' }
    elseif ($lic.LicenseStatus -ne 1) { Add-Result 'Windows-Aktivierung' 'WARN' "Windows nicht aktiviert ($($map[[int]$lic.LicenseStatus]))" }
    else { Add-Result 'Windows-Aktivierung' 'OK' }
}

Set-Section 'Wartung'

Invoke-Test 'Update-Dienst' {
    $wu = Get-CimInstance Win32_Service -Filter "Name='wuauserv'"
    if ($wu.StartMode -eq 'Disabled') { Add-Result 'Update-Dienst' 'FAIL' 'Windows Update ist deaktiviert' }
    else { Add-Result 'Update-Dienst' 'OK' }
}

if ($updateJob) {
    Invoke-Test 'Windows-Updates' {
        $remaining = [math]::Max(1, 90 - ((Get-Date) - $startTime).TotalSeconds)
        if (-not (Wait-Job $updateJob -Timeout $remaining)) {
            Add-Result 'Windows-Updates' 'SKIP' 'Update-Suche dauert zu lange'; return
        }
        if ($updateJob.State -eq 'Failed') {
            Add-Result 'Windows-Updates' 'SKIP' "Update-Suche fehlgeschlagen: $($updateJob.ChildJobs[0].JobStateInfo.Reason.Message)"; return
        }
        $titles = @(Receive-Job $updateJob -ErrorAction SilentlyContinue)
        if ($titles.Count -eq 0) { Add-Result 'Windows-Updates' 'OK'; return }
        $lines = @($titles | Select-Object -First 4 | ForEach-Object {
            if ($_.Length -gt 70) { '- ' + $_.Substring(0, 67) + '...' } else { "- $_" }
        })
        if ($titles.Count -gt 4) { $lines += "  ... und $($titles.Count - 4) weitere" }
        Add-Result 'Windows-Updates' 'WARN' "$($titles.Count) Update(s) verfügbar" $lines
    }
}

Invoke-Test 'Letzte Update-Installation' {
    $installed = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
    if (-not $installed -or $installed.Year -lt 2000) {
        Add-Result 'Letzte Update-Installation' 'WARN' 'Keine erfolgreiche Update-Installation bekannt'; return
    }
    $days = [int]((Get-Date) - $installed.ToLocalTime()).TotalDays
    if ($days -ge 45) { Add-Result 'Letzte Update-Installation' 'WARN' "Letzte Update-Installation vor $days Tagen" }
    else { Add-Result 'Letzte Update-Installation' 'OK' }
}

Invoke-Test 'Neustart ausstehend' {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows-Komponenten' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    if (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations') { $reasons += 'Ausstehende Dateioperationen' }
    $active  = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' 'ComputerName'
    $pending = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' 'ComputerName'
    if ($active -ne $pending) { $reasons += 'Computername geändert' }

    if ($reasons.Count -gt 0) { Add-Result 'Neustart ausstehend' 'WARN' ("Neustart erforderlich: {0}" -f ($reasons -join ', ')) }
    else { Add-Result 'Neustart ausstehend' 'OK' }
}

Invoke-Test 'Laufzeit' {
    if ($uptime.TotalDays -ge 14) {
        Add-Result 'Laufzeit' 'WARN' "Seit $($uptime.Days) Tagen nicht neu gestartet" `
            @('Hinweis: "Herunterfahren" zählt bei aktiviertem Schnellstart nicht als Neustart')
    } else { Add-Result 'Laufzeit' 'OK' }
}

Invoke-Test 'Windows-Abbild' -AdminOnly {
    $state = "$((Repair-WindowsImage -Online -CheckHealth).ImageHealthState)"
    switch ($state) {
        'Healthy'    { Add-Result 'Windows-Abbild' 'OK' }
        'Repairable' { Add-Result 'Windows-Abbild' 'WARN' 'Windows-Systemdateien beschädigt, aber reparierbar' @('Tipp: DISM /Online /Cleanup-Image /RestoreHealth, danach sfc /scannow') }
        default      { Add-Result 'Windows-Abbild' 'FAIL' "Windows-Systemdateien beschädigt ($state)" @('Reparaturinstallation von Windows nötig') }
    }
}

Invoke-Test 'Zuverlässigkeit' {
    $metric = Get-CimInstance Win32_ReliabilityStabilityMetrics | Sort-Object TimeGenerated -Descending | Select-Object -First 1
    if (-not $metric) { Add-Result 'Zuverlässigkeit' 'SKIP' 'Keine Daten'; return }
    $idx = [math]::Round($metric.SystemStabilityIndex, 1)
    $status = if ($idx -lt 3) { 'FAIL' } elseif ($idx -lt 5) { 'WARN' } else { 'OK' }
    Add-Result 'Zuverlässigkeit' $status "Stabilitätsindex nur $idx von 10" @('Details: Startmenü > "Zuverlässigkeitsverlauf anzeigen"')
}

Set-Section 'Systemzustand'

Invoke-Test 'Systemabstürze' {
    $since = (Get-Date).AddDays(-30)
    $bsod  = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $power = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
    if ($bsod.Count -gt 0) {
        Add-Result 'Systemabstürze' 'FAIL' "$($bsod.Count) Bluescreen(s) in 30 Tagen" `
            @(("Zuletzt: {0:dd.MM.yyyy HH:mm}" -f $bsod[0].TimeCreated), 'Speicherabbilder: C:\Windows\Minidump')
    }
    if ($power.Count -gt 0) {
        Add-Result 'Systemabstürze' 'WARN' "$($power.Count)x unerwartet ausgeschaltet/neu gestartet (30 Tage)" `
            @(("Zuletzt: {0:dd.MM.yyyy HH:mm}" -f $power[0].TimeCreated), 'Mögliche Ursachen: Stromausfall, Netzteil, Überhitzung, Einfrieren')
    }
    if ($bsod.Count -eq 0 -and $power.Count -eq 0) { Add-Result 'Systemabstürze' 'OK' }
}

Invoke-Test 'Kritische Ereignisse' {
    $ev = Get-Events @{ LogName = 'System'; Level = 1; StartTime = (Get-Date).AddDays(-1) } |
          Where-Object { -not ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) }
    $ev = @($ev)
    if ($ev.Count -gt 0) {
        Add-Result 'Kritische Ereignisse' 'WARN' "$($ev.Count) kritische(s) Ereignis(se) in 24 Stunden" `
            (Format-Top $ev { "$($_.ProviderName) (ID $($_.Id))" })
    } else { Add-Result 'Kritische Ereignisse' 'OK' }
}

Invoke-Test 'Wiederkehrende Fehler' {

    $ev = Get-Events @{ LogName = 'System'; Level = 2; StartTime = (Get-Date).AddDays(-1) } |
          Where-Object ProviderName -ne 'Microsoft-Windows-DistributedCOM'
    $noisy = @($ev | Group-Object ProviderName | Where-Object Count -ge 10 | Sort-Object Count -Descending)
    if ($noisy.Count -gt 0) {
        Add-Result 'Wiederkehrende Fehler' 'WARN' "$($noisy.Count) Quelle(n) melden ständig Fehler (24 Stunden)" `
            @($noisy | Select-Object -First 3 | ForEach-Object { "- {0}x {1}" -f $_.Count, $_.Name })
    } else { Add-Result 'Wiederkehrende Fehler' 'OK' }
}

Invoke-Test 'App-Abstürze' {
    $crashes = Get-Events @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = (Get-Date).AddDays(-7) }
    $hangs   = Get-Events @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = (Get-Date).AddDays(-7) }
    $all = @($crashes) + @($hangs)
    $repeat = @($all | Group-Object { $_.Properties[0].Value } | Where-Object Count -ge 3)
    if ($all.Count -ge 10 -or $repeat.Count -gt 0) {
        Add-Result 'App-Abstürze' 'WARN' "$($all.Count) Programmabstürze/-hänger in 7 Tagen" (Format-Top $all { $_.Properties[0].Value })
    } else { Add-Result 'App-Abstürze' 'OK' }
}

Invoke-Test 'Wichtige Dienste' {
    $core = 'RpcSs', 'EventLog', 'Winmgmt', 'PlugPlay', 'Power', 'ProfSvc', 'Schedule', 'CryptSvc', 'BFE', 'mpssvc',
            'Dhcp', 'Dnscache', 'nsi', 'LanmanWorkstation', 'AudioSrv', 'AudioEndpointBuilder', 'Themes', 'BrokerInfrastructure'
    $down = @(Get-Service -Name $core -ErrorAction SilentlyContinue | Where-Object Status -ne 'Running')
    if ($down.Count -gt 0) {
        Add-Result 'Wichtige Dienste' 'FAIL' "$($down.Count) wichtige(r) Systemdienst(e) läuft/laufen nicht" `
            @($down | ForEach-Object { "- $($_.DisplayName) ($($_.Status))" })
    } else { Add-Result 'Wichtige Dienste' 'OK' }
}

Invoke-Test 'Dienste' {

    $bad = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
             Where-Object { $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 })
    if ($bad.Count -gt 0) {
        Add-Result 'Dienste' 'WARN' "$($bad.Count) automatische(r) Dienst(e) mit Fehler beendet" `
            @($bad | Select-Object -First 4 | ForEach-Object { "- {0} (Code {1})" -f $_.DisplayName, $_.ExitCode })
    } else { Add-Result 'Dienste' 'OK' }
}

Invoke-Test 'Autostart' {
    $count = @(Get-CimInstance Win32_StartupCommand).Count
    if ($count -ge 20) {
        Add-Result 'Autostart' 'WARN' "$count Programme im Autostart - verlangsamt den Start" @('Tipp: Task-Manager > Autostart-Apps')
    } else { Add-Result 'Autostart' 'OK' }
}

if ($updateJob) { Remove-Job $updateJob -Force -ErrorAction SilentlyContinue }
Write-Host ("`r" + (' ' * 72) + "`r") -NoNewline

$fails    = @($results | Where-Object Status -eq 'FAIL')
$warns    = @($results | Where-Object Status -eq 'WARN')
$skipped  = @($results | Where-Object Status -eq 'SKIP')
$passed   = @($results | Where-Object Status -eq 'OK')
$duration = ((Get-Date) - $startTime).TotalSeconds

$colors = @{ FAIL = 'Red'; WARN = 'Yellow'; OK = 'Green'; SKIP = 'DarkGray' }
$shown  = if ($ShowAll) { 'FAIL', 'WARN', 'OK', 'SKIP' } else { 'FAIL', 'WARN' }

foreach ($sec in $sections) {
    $items = @($results | Where-Object { $_.Section -eq $sec -and $_.Status -in $shown } |
               Sort-Object { [array]::IndexOf($shown, $_.Status) })
    if ($items.Count -eq 0) { continue }
    Write-Host "   $sec" -ForegroundColor Cyan
    foreach ($r in $items) {
        Write-Host ('   [{0,-4}] ' -f $r.Status) -NoNewline -ForegroundColor $colors[$r.Status]
        Write-Host $r.Name -NoNewline -ForegroundColor White
        if ($r.Detail) { Write-Host ": $($r.Detail)" -ForegroundColor Gray } else { Write-Host '' }
        if ($r.Status -in 'FAIL', 'WARN') {
            foreach ($line in $r.Lines) { Write-Host "            $line" -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
}

Write-Host '  ====================================================================' -ForegroundColor DarkCyan
if ($fails.Count -gt 0) {
    Write-Host ("   {0} FEHLER, {1} Warnung(en) gefunden" -f $fails.Count, $warns.Count) -ForegroundColor Red
} elseif ($warns.Count -gt 0) {
    Write-Host ("   {0} Warnung(en) gefunden - sonst alles in Ordnung" -f $warns.Count) -ForegroundColor Yellow
} else {
    Write-Host '   ALLES IN ORDNUNG - keine Probleme gefunden' -ForegroundColor Green
}
$skipNote = if ($skipped.Count -gt 0 -and -not $isAdmin) { ', mehr Prüfungen als Admin' } else { '' }
Write-Host ("   {0} Prüfungen in {1:N0} s | {2} bestanden | {3} übersprungen{4}" -f `
    $results.Count, $duration, $passed.Count, $skipped.Count, $skipNote) -ForegroundColor DarkGray
Write-Host '  ====================================================================' -ForegroundColor DarkCyan

$greeting = switch ((Get-Date).Hour) {
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

$outro = if ($fails.Count -gt 0) { 'Da läuft was krumm - schau dir die Fehler oben an.' }
         elseif ($warns.Count -gt 0) { 'Dein System läuft - ein paar Kleinigkeiten könnten Aufmerksamkeit vertragen.' }
         else { 'Dein System ist in Topform. Viel Erfolg heute!' }

Write-Host ''
Write-Host "   $greeting, $name!" -ForegroundColor Cyan
Write-Host "   $outro" -ForegroundColor White
Write-Host ''

if (-not $PSBoundParameters.ContainsKey('Delay') -and ($fails.Count + $warns.Count) -gt 0) { $Delay = 30 }

$hold = $false
for ($i = $Delay; $i -gt 0 -and -not $hold; $i--) {
    Write-Host ("`r   Schließt in {0,2} s - beliebige Taste hält das Fenster offen " -f $i) -NoNewline -ForegroundColor DarkGray
    for ($t = 0; $t -lt 10; $t++) {
        Start-Sleep -Milliseconds 100
        try { if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); $hold = $true; break } } catch { }
    }
}
if ($hold) {
    Write-Host ("`r   Fenster bleibt offen - Taste drücken zum Schließen ...").PadRight(70) -NoNewline -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}
Write-Host ''
exit $fails.Count
