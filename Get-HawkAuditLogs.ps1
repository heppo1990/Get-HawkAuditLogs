# ============================================================================
# Hawk Audit Log Collection Script - Hawk 4.0 Produktionsversion
# ============================================================================
# Verwendung:
#   Normale Ausführung:   .\Get-HawkAuditLogs.ps1
#   Mit Debug-Ausgaben:   .\Get-HawkAuditLogs.ps1 -VerboseOutput
# ============================================================================

#Requires -RunAsAdministrator

Param(
    [switch]$VerboseOutput
)

$ScriptVersion = '1.0.0'
$GitHubRepository = 'heppo1990/Get-HawkAuditLogs'

[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::CreateSpecificCulture('en-US')
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::CreateSpecificCulture('en-US')
$WarningPreference = 'SilentlyContinue'

# ============================================================================
# HILFSFUNKTION: Ausgabe-Steuerung
# ============================================================================

Function Write-Log {
    param(
        [string]$Message,
        [string]$Color = 'White',
        [switch]$Always
    )
    if ($Always -or $VerboseOutput) {
        Write-Host $Message -ForegroundColor $Color
    }
}

# ============================================================================
# Konfiguration
# ============================================================================

$ScriptName            = (Split-Path -Path ($MyInvocation.MyCommand.Name) -Leaf).Replace('.ps1','')
$TenantID              = ''
$ZielPfadAuditLogsBase = "C:\Skripte\AuditLogs"
$DaysToLookBack        = 13
$RetentionDays         = 730
$SettingsFilePath      = Join-Path $PSScriptRoot "$ScriptName.settings.json"
$ModuleUpdatesMade     = @()

$Global:HawkOutputPath = $null
$Global:HawkFolderName = $null

# Gepinnte Modulversionen werden aus der Settings-Datei geladen.
$PinnedVersions = @{}

# Installationsreihenfolge ist kritisch für Hawk 4.0!
# PSFramework/PSAppInsights müssen VOR Microsoft.Graph geladen werden
$ModuleInstallOrder = @(
    "PSFramework"
    "PSAppInsights"
    "ExchangeOnlineManagement"
    "Microsoft.Graph.Authentication"
    "Microsoft.Graph.Users"
    "Microsoft.Graph.Identity.SignIns"
    "Microsoft.Graph.Identity.DirectoryManagement"
    "Microsoft.Graph.Applications"
    "Microsoft.Graph.Reports"
    "Microsoft.Graph.Beta.Reports"                 # Benötigt für Get-MgBetaAuditLogSignIn
    "Hawk"                                         # Hawk immer zuletzt!
)

# ============================================================================
# FUNKTION: Mail-Einstellungen laden
# Mail-Einstellungen aus der Settings-Datei laden.
# ============================================================================

Function Initialize-MailSettings {
    $DefaultSettings = '{"MailSettings":{"CompanyName":"","Host":"","Port":25,"UseSSL":false,"Auth":false,"AuthUser":"","AuthPass":"","Sender":"","MailTo":"","MailCC":"","MailBCC":"","SendMail":false,"Subject":"Hawk Audit Log Zusammenfassung"}}'
    $Settings = ($DefaultSettings | ConvertFrom-Json)
    $SettingsFromFile = $ScriptSettings

    if ($null -ne $SettingsFromFile -and $null -ne $SettingsFromFile.MailSettings) {
        $InpObj = $SettingsFromFile.MailSettings
        $OutObj = $Settings.MailSettings
        if ($InpObj -is [System.Collections.IDictionary]) {
            foreach ($Key in $InpObj.Keys) {
                Add-Member -InputObject $OutObj -NotePropertyName $Key -NotePropertyValue $InpObj[$Key] -Force
            }
        }
        else {
            ForEach ($Setting in Get-Member -InputObject $InpObj -MemberType NoteProperty) {
                Add-Member -InputObject $OutObj -NotePropertyName $Setting.Name -NotePropertyValue $InpObj.$($Setting.Name) -Force
            }
        }
        $Settings.MailSettings = $OutObj
    }

    # Sender aus Firmenname generieren falls leer
    $MailSettings = $Settings.MailSettings
    if ([string]::IsNullOrWhiteSpace($MailSettings.Sender) -and -not [string]::IsNullOrWhiteSpace($MailSettings.CompanyName)) {
        $safeName = $MailSettings.CompanyName -replace '[äÄ]','ae' -replace '[öÖ]','oe' -replace '[üÜ]','ue' -replace 'ß','ss'
        $safeName = $safeName -replace '\s+','-' -replace '[^a-zA-Z0-9\-]','' -replace '-{2,}','-'
        $safeName = $safeName.ToLower().Trim('-')
        foreach ($form in @('gmbh-co-kg','gmbh-co','gmbh','mbh','ug','ag','kg')) {
            $safeName = $safeName -replace "-$form$",'' -replace "^$form-",''
        }
        Add-Member -InputObject $MailSettings -NotePropertyName 'Sender' -NotePropertyValue "hawk-audit@$safeName.de" -Force
    }

    # Subject mit Firmenname und Datum kombinieren
    $subject = [string]$MailSettings.Subject
    if ([string]::IsNullOrWhiteSpace($subject)) { $subject = "Hawk Audit Log Zusammenfassung" }
    $dateStamp = Get-Date -Format 'dd.MM.yyyy'
    if (-not [string]::IsNullOrWhiteSpace($MailSettings.CompanyName)) {
        $subject = "$($MailSettings.CompanyName) - $subject - $dateStamp"
    } else {
        $subject = "$subject - $dateStamp"
    }
    Add-Member -InputObject $MailSettings -NotePropertyName 'SubjectFull' -NotePropertyValue $subject -Force

    return $MailSettings
}

Function Initialize-DeploymentSettings {
    $FallbackDefaults = @{
        SettingsVersion = 1
        TenantID = ''
        ModuleVersions = @{}
        GeoLocation = @{ Provider = 'IPinfo'; ApiToken = '' }
        ScriptUpdates = @{ Enabled = $true }
        MailSettings = @{ CompanyName = ''; Host = ''; Port = 25; UseSSL = $false; Auth = $false; AuthUser = ''; AuthPass = ''; Sender = ''; MailTo = ''; MailCC = ''; MailBCC = ''; SendMail = $false; Subject = 'Hawk Audit Log Zusammenfassung' }
    }

    try {
        $Settings = $FallbackDefaults
        if (Test-Path -LiteralPath $SettingsFilePath) {
            $Settings = Get-Content -LiteralPath $SettingsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        return (Merge-SettingsDefaults -Defaults $FallbackDefaults -Current $Settings)
    }
    catch {
        throw "Einstellungsdatei '$SettingsFilePath' konnte nicht geladen werden: $($_.Exception.Message)"
    }
}

Function Save-ModuleVersionsToSettings {
    param([hashtable]$Versions)

    $Current = @{}
    if (Test-Path -LiteralPath $SettingsFilePath) {
        $Current = Get-Content -LiteralPath $SettingsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    }
    if (-not $Current) { $Current = @{} }
    $Current.TenantID = $TenantID
    if (-not $Current.ModuleVersions) { $Current.ModuleVersions = @{} }
    foreach ($Name in $Versions.Keys) { $Current.ModuleVersions[$Name] = [string]$Versions[$Name] }
    $Current | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SettingsFilePath -Encoding UTF8
}

Function Merge-SettingsDefaults {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Defaults,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Current
    )

    foreach ($Key in $Defaults.Keys) {
        if (-not $Current.Contains($Key)) {
            $Current[$Key] = $Defaults[$Key]
        }
        elseif ($Defaults[$Key] -is [System.Collections.IDictionary] -and $Current[$Key] -is [System.Collections.IDictionary]) {
            $Current[$Key] = Merge-SettingsDefaults -Defaults $Defaults[$Key] -Current $Current[$Key]
        }
    }
    return $Current
}

# ============================================================================
# FUNKTION: HTML-Mail versenden
# ============================================================================

Function Send-HawkMailReport {
    param(
        [object]$MailSettings,
        [string]$HtmlBody
    )
    try {
        $smtp = New-Object System.Net.Mail.SmtpClient($MailSettings.Host, $MailSettings.Port)
        $smtp.EnableSsl = $MailSettings.UseSSL

        if ($MailSettings.Auth -eq $true) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential($MailSettings.AuthUser, $MailSettings.AuthPass)
        }

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $MailSettings.Sender
        $mail.To.Add($MailSettings.MailTo)

        if (-not [string]::IsNullOrEmpty($MailSettings.MailCC) -and $MailSettings.MailCC -ne $MailSettings.MailTo) {
            $mail.CC.Add($MailSettings.MailCC)
        }
        if (-not [string]::IsNullOrEmpty($MailSettings.MailBCC) -and $MailSettings.MailBCC -ne $MailSettings.MailTo) {
            $mail.Bcc.Add($MailSettings.MailBCC)
        }

        $mail.Subject         = $MailSettings.SubjectFull
        $mail.Body            = $HtmlBody
        $mail.IsBodyHtml      = $true
        $mail.BodyEncoding    = [System.Text.Encoding]::UTF8
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8

        $smtp.Send($mail)
        $mail.Dispose()
        Write-Host "  [ERFOLG] E-Mail versendet an $($MailSettings.MailTo)" -ForegroundColor Green
    }
    catch {
        Write-Host "  [FEHLER] E-Mail Versand fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    }
}



Function Test-PowerShell7 {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "VORAUSSETZUNGSPRÜFUNG" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Write-Log "  [OK] PowerShell $($PSVersionTable.PSVersion) wird verwendet" -Color Green
        return $true
    }

    Write-Log "  [WARNUNG] PowerShell 7+ erforderlich" -Color Yellow
    $PS7Paths = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe"
    )
    $PS7Found = $PS7Paths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($PS7Found) {
        Start-Process -FilePath $PS7Found -ArgumentList "-NoExit", "-File", "`"$PSCommandPath`"" -Verb RunAs
        exit 0
    }

    $WingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if ($WingetPath) {
        $p = Start-Process -FilePath "winget" -ArgumentList "install","--id","Microsoft.PowerShell","--source","winget","--accept-package-agreements","--accept-source-agreements" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) {
            $ps7 = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
            if (Test-Path $ps7) { Start-Process -FilePath $ps7 -ArgumentList "-NoExit","-File","`"$PSCommandPath`"" -Verb RunAs; exit 0 }
        }
    }
    Write-Host "  [FEHLER] PowerShell 7 konnte nicht bereitgestellt werden. Bitte manuell installieren: https://aka.ms/powershell" -ForegroundColor Red
    return $false
}

# ============================================================================
# FUNKTION: Einzelnes Modul auf gepinnte Version installieren (Rollback)
# ============================================================================

Function Install-PinnedVersion {
    param(
        [string]$ModuleName,
        [string]$PinnedVersion
    )
    Write-Host "    [ROLLBACK] Installiere $ModuleName $PinnedVersion..." -ForegroundColor Yellow
    try {
        Remove-Module -Name $ModuleName -Force -ErrorAction SilentlyContinue
        # Alle anderen Versionen entfernen
        Get-Module -ListAvailable -Name $ModuleName | ForEach-Object {
            if ($_.Version -ne [version]$PinnedVersion) {
                Uninstall-Module -Name $ModuleName -RequiredVersion $_.Version -Force -ErrorAction SilentlyContinue
            }
        }
        Install-Module -Name $ModuleName -RequiredVersion $PinnedVersion -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
        Write-Host "    [OK] $ModuleName $PinnedVersion installiert" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "    [FEHLER] Rollback fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ============================================================================
# FUNKTION: Module prüfen, optional updaten, bei Fehler zurückrollen
# ============================================================================

Function Test-AndInstallModules {
    Write-Host "`n[PRÜFUNG] PowerShell Module..." -ForegroundColor Cyan
    $AllReady = $true

    foreach ($ModuleName in $ModuleInstallOrder) {
        $PinnedVersion = $PinnedVersions[$ModuleName]
        Write-Host "`n  Modul: $ModuleName (gepinnt auf $PinnedVersion)" -ForegroundColor White

        $Installed = Get-Module -ListAvailable -Name $ModuleName |
                     Sort-Object Version -Descending |
                     Select-Object -First 1

        # Nicht installiert -> gepinnte Version installieren
        if (-not $Installed) {
            Write-Host "    [NICHT GEFUNDEN] Installiere Version $PinnedVersion..." -ForegroundColor Yellow
            if (-not (Install-PinnedVersion -ModuleName $ModuleName -PinnedVersion $PinnedVersion)) {
                $AllReady = $false
            }
            continue
        }

        # Falsche Version installiert -> auf gepinnte Version bringen
        if ($Installed.Version -ne [version]$PinnedVersion) {
            Write-Host "    [GEFUNDEN] Version $($Installed.Version) - erwartet $PinnedVersion" -ForegroundColor Yellow
            Write-Host "    [AKTION] Bringe Modul auf gepinnte Version $PinnedVersion..." -ForegroundColor Yellow
            if (-not (Install-PinnedVersion -ModuleName $ModuleName -PinnedVersion $PinnedVersion)) {
                $AllReady = $false
            }
            continue
        }

        Write-Host "    [OK] Version $($Installed.Version) (gepinnte Version)" -ForegroundColor Green

        # Update-Check: Neuere Version verfügbar?
        try {
            $Online = Find-Module -Name $ModuleName -ErrorAction Stop
            if ($Online.Version -gt [version]$PinnedVersion) {
                Write-Host "" 
                Write-Host "    [UPDATE] Version $($Online.Version) verfügbar (aktuell: $PinnedVersion)" -ForegroundColor Cyan
                Write-Host "    Möchtest du auf $($Online.Version) updaten? [J/N] (Standard: N): " -ForegroundColor Cyan -NoNewline
                $Answer = (Read-Host).Trim()

                if ($Answer -eq 'J' -or $Answer -eq 'j') {
                    Write-Host "    [UPDATE] Installiere $ModuleName $($Online.Version)..." -ForegroundColor Yellow
                    try {
                        Remove-Module -Name $ModuleName -Force -ErrorAction SilentlyContinue
                        Install-Module -Name $ModuleName -RequiredVersion $Online.Version -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
                        
                        # Sofort testen ob das Modul nach Update noch ladbar ist
                        Import-Module -Name $ModuleName -RequiredVersion $Online.Version -Force -ErrorAction Stop
                        Write-Host "    [ERFOLG] $ModuleName $($Online.Version) installiert und geladen" -ForegroundColor Green
                        # Gepinnte Version in dieser Session aktualisieren
                        $PinnedVersions[$ModuleName] = $Online.Version.ToString()
                        $script:ModuleUpdatesMade += $ModuleName
                    }
                    catch {
                        Write-Host "    [FEHLER] Update fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
                        Write-Host "    [ROLLBACK] Falle zurück auf Version $PinnedVersion..." -ForegroundColor Yellow
                        if (-not (Install-PinnedVersion -ModuleName $ModuleName -PinnedVersion $PinnedVersion)) {
                            $AllReady = $false
                        }
                    }
                }
                else {
                    Write-Host "    [INFO] Update übersprungen - bleibe bei $PinnedVersion" -ForegroundColor Gray
                }
            }
        }
        catch {
            Write-Log "    [INFO] Kein Update-Check möglich (offline?)" -Color Gray
        }
    }

    return $AllReady
}

# ============================================================================
# FUNKTION: Module in korrekter Reihenfolge importieren
# Kritisch für Hawk 4.0 - verhindert Assembly-Konflikt
# ============================================================================

Function Import-ModulesInOrder {
    Write-Host "`n  Lade Module in korrekter Reihenfolge..." -ForegroundColor White
    foreach ($ModuleName in $ModuleInstallOrder) {
        try {
            Remove-Module -Name $ModuleName -Force -ErrorAction SilentlyContinue
            Import-Module -Name $ModuleName -Force -ErrorAction Stop
            Write-Log "    [OK] $ModuleName geladen" -Color Green
        }
        catch {
            Write-Host "    [FEHLER] $ModuleName konnte nicht geladen werden: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    return $true
}

Function Set-HawkIPGeolocationProvider {
    param([string]$ApiToken)

    $HawkModule = Get-Module -Name Hawk
    if (-not $HawkModule) { throw 'Hawk-Modul ist nicht geladen; IP-Geolokalisierung kann nicht konfiguriert werden.' }

    # Ersetzt Hawks IPStack-Aufruf im Modul-Scope. IPinfo Legacy Free liefert Stadt/Region;
    # bei fehlendem Token, Limit oder API-Fehler bleibt der Hawk-Lauf mit unbekanntem Ort am Leben.
    $GeoFunction = {
        param([Parameter(Mandatory = $true)]$IPAddress)

        $IpText = [string]$IPAddress
        if ($Global:IPLocationCache -and ($Global:IPLocationCache.ip -contains $IpText)) {
            return ($Global:IPLocationCache | Where-Object { $_.ip -eq $IpText } | Select-Object -First 1)
        }

        $Result = [PSCustomObject]@{
            IP               = $IpText
            CountryName      = 'Unknown'
            RegionName       = 'Unknown'
            RegionCode       = 'Unknown'
            ContinentName    = 'Unknown'
            City             = 'Unknown'
            KnownMicrosoftIP = 'Unknown'
        }

        $ParsedIP = $null
        $IsPublicIP = [System.Net.IPAddress]::TryParse($IpText, [ref]$ParsedIP)
        if ($IsPublicIP) {
            $Bytes = $ParsedIP.GetAddressBytes()
            if ($ParsedIP.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $IsPublicIP = -not (
                    $Bytes[0] -eq 0 -or $Bytes[0] -eq 10 -or $Bytes[0] -eq 127 -or
                    ($Bytes[0] -eq 169 -and $Bytes[1] -eq 254) -or
                    ($Bytes[0] -eq 172 -and $Bytes[1] -ge 16 -and $Bytes[1] -le 31) -or
                    ($Bytes[0] -eq 192 -and $Bytes[1] -eq 168) -or
                    ($Bytes[0] -eq 100 -and $Bytes[1] -ge 64 -and $Bytes[1] -le 127) -or
                    $Bytes[0] -ge 224
                )
            }
            else {
                $IsPublicIP = -not ($ParsedIP.IsIPv6LinkLocal -or $ParsedIP.IsIPv6SiteLocal -or $ParsedIP.IsIPv6Multicast -or $ParsedIP.IsIPv6Loopback -or [System.Net.IPAddress]::IPv6Any.Equals($ParsedIP) -or (($Bytes[0] -band 0xFE) -eq 0xFC))
            }
        }

        if ($IsPublicIP -and -not [string]::IsNullOrWhiteSpace($Global:HawkIPinfoToken)) {
            try {
                $EncodedIP = [uri]::EscapeDataString($IpText)
                $EncodedToken = [uri]::EscapeDataString($Global:HawkIPinfoToken)
                $Response = Invoke-RestMethod -Method Get -Uri "https://ipinfo.io/$EncodedIP/json?token=$EncodedToken" -TimeoutSec 15 -ErrorAction Stop
                if ($Response.city) { $Result.City = [string]$Response.city }
                if ($Response.region) { $Result.RegionName = [string]$Response.region }
                if ($Response.country) { $Result.CountryName = [string]$Response.country }
                if ($Response.org -match '(?i)\bMicrosoft\b') { $Result.KnownMicrosoftIP = 'True' }
            }
            catch {
                Out-LogFile "IPinfo lookup failed; continuing without geolocation for an IP address." -isError
            }
        }

        [array]$Global:IPLocationCache += $Result
        return $Result
    }

    & $HawkModule {
        param($FunctionBody, $Token)
        $Global:HawkIPinfoToken = $Token
        Set-Item -Path Function:\Get-IPGeolocation -Value $FunctionBody -Force
    } $GeoFunction $ApiToken
}

Function Update-ScriptFromGitHub {
    if ($ScriptSettings.ScriptUpdates.Enabled -ne $true -or -not $PSCommandPath) { return }

    try {
        $Headers = @{ 'User-Agent' = 'Get-HawkAuditLogs-Updater'; 'Accept' = 'application/vnd.github+json' }
        $Release = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$GitHubRepository/releases/latest" -Headers $Headers -TimeoutSec 15 -ErrorAction Stop
        $LatestVersionText = ([string]$Release.tag_name).TrimStart('v')
        $ScriptAsset = $Release.assets | Where-Object { $_.name -eq 'Get-HawkAuditLogs.ps1' } | Select-Object -First 1
        $HashAsset = $Release.assets | Where-Object { $_.name -eq 'Get-HawkAuditLogs.ps1.sha256' } | Select-Object -First 1
        $SettingsAsset = $Release.assets | Where-Object { $_.name -eq 'Get-HawkAuditLogs.settings.json' } | Select-Object -First 1
        $SettingsHashAsset = $Release.assets | Where-Object { $_.name -eq 'Get-HawkAuditLogs.settings.json.sha256' } | Select-Object -First 1

        if (-not $SettingsAsset -or -not $SettingsHashAsset) {
            Write-Host '  [WARNUNG] GitHub-Release enthält keine Settings-Datei; lokale Einstellungen bleiben unverändert.' -ForegroundColor Yellow
        }
        else {
            $TempSettings = Join-Path $PSScriptRoot '.Get-HawkAuditLogs.settings.update.json'
            $TempSettingsHash = Join-Path $PSScriptRoot '.Get-HawkAuditLogs.settings.update.sha256'
            Invoke-WebRequest -Uri $SettingsAsset.browser_download_url -OutFile $TempSettings -Headers @{ 'User-Agent' = 'Get-HawkAuditLogs-Updater' } -TimeoutSec 15 -ErrorAction Stop
            Invoke-WebRequest -Uri $SettingsHashAsset.browser_download_url -OutFile $TempSettingsHash -Headers @{ 'User-Agent' = 'Get-HawkAuditLogs-Updater' } -TimeoutSec 15 -ErrorAction Stop
            $ExpectedSettingsHash = ([string](Get-Content -LiteralPath $TempSettingsHash -Raw)).Trim().Split(' ')[0].ToUpperInvariant()
            $ActualSettingsHash = (Get-FileHash -LiteralPath $TempSettings -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($ExpectedSettingsHash -notmatch '^[A-F0-9]{64}$' -or $ActualSettingsHash -ne $ExpectedSettingsHash) {
                throw 'SHA-256-Prüfung der Settings-Datei fehlgeschlagen.'
            }

            $NewSettings = Get-Content -LiteralPath $TempSettings -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $CurrentSettings = @{}
            if (Test-Path -LiteralPath $SettingsFilePath) {
                $CurrentSettings = Get-Content -LiteralPath $SettingsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            }
            if (-not $CurrentSettings) { $CurrentSettings = @{} }
            $MergedSettings = Merge-SettingsDefaults -Defaults $NewSettings -Current $CurrentSettings
            if ($NewSettings.ContainsKey('SettingsVersion')) { $MergedSettings.SettingsVersion = $NewSettings.SettingsVersion }
            $TempMergedSettings = "$SettingsFilePath.update"
            $MergedSettings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $TempMergedSettings -Encoding UTF8
            Move-Item -LiteralPath $TempMergedSettings -Destination $SettingsFilePath -Force -ErrorAction Stop
            Remove-Item -LiteralPath $TempSettings -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $TempSettings,$TempSettingsHash -Force -ErrorAction SilentlyContinue
            Write-Host '  [UPDATE] Settings-Datei aktualisiert; vorhandene Werte bleiben erhalten.' -ForegroundColor Cyan
        }

        if ([version]$LatestVersionText -le [version]$ScriptVersion) { return }
        if (-not $ScriptAsset -or -not $HashAsset) {
            Write-Host '  [WARNUNG] GitHub-Release hat nicht alle Update-Dateien; verwende die lokale Version.' -ForegroundColor Yellow
            return
        }

        $TempScript = Join-Path $PSScriptRoot '.Get-HawkAuditLogs.update.ps1'
        $TempHash = Join-Path $PSScriptRoot '.Get-HawkAuditLogs.update.sha256'
        Invoke-WebRequest -Uri $ScriptAsset.browser_download_url -OutFile $TempScript -Headers @{ 'User-Agent' = 'Get-HawkAuditLogs-Updater' } -TimeoutSec 30 -ErrorAction Stop
        Invoke-WebRequest -Uri $HashAsset.browser_download_url -OutFile $TempHash -Headers @{ 'User-Agent' = 'Get-HawkAuditLogs-Updater' } -TimeoutSec 15 -ErrorAction Stop

        $ExpectedHash = ([string](Get-Content -LiteralPath $TempHash -Raw)).Trim().Split(' ')[0].ToUpperInvariant()
        $ActualHash = (Get-FileHash -LiteralPath $TempScript -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($ExpectedHash -notmatch '^[A-F0-9]{64}$' -or $ActualHash -ne $ExpectedHash) {
            Remove-Item -LiteralPath $TempScript,$TempHash -Force -ErrorAction SilentlyContinue
            throw 'SHA-256-Prüfung der neuen Skriptversion fehlgeschlagen.'
        }

        Move-Item -LiteralPath $TempScript -Destination $PSCommandPath -Force -ErrorAction Stop
        Remove-Item -LiteralPath $TempHash -Force -ErrorAction SilentlyContinue
        Write-Host "  [UPDATE] Skriptversion $LatestVersionText wird gestartet..." -ForegroundColor Cyan
        $PowerShellExe = Join-Path $PSHOME 'pwsh.exe'
        $Arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
        if ($VerboseOutput) { $Arguments += '-VerboseOutput' }
        Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments
        exit 0
    }
    catch {
        Remove-Item -LiteralPath (Join-Path $PSScriptRoot '.Get-HawkAuditLogs.update.ps1'),(Join-Path $PSScriptRoot '.Get-HawkAuditLogs.update.sha256'),(Join-Path $PSScriptRoot '.Get-HawkAuditLogs.settings.update.json'),(Join-Path $PSScriptRoot '.Get-HawkAuditLogs.settings.update.sha256'),("$SettingsFilePath.update") -Force -ErrorAction SilentlyContinue
        Write-Host "  [INFO] GitHub-Update nicht verfügbar; starte mit der lokalen Version. $($_.Exception.Message)" -ForegroundColor Gray
    }
}

# ============================================================================
# FUNKTION: Anmelde-Logs über Microsoft Graph Beta abrufen
# ============================================================================

Function Get-UserSignInLogs {
    param (
        [Parameter(Mandatory = $true)][string]$UserPrincipalName,
        [Parameter(Mandatory = $true)][int]$DaysBack,
        [Parameter(Mandatory = $true)][string]$UserFolderPath
    )
    try {
        $StartDateTime = (Get-Date).AddDays(-$DaysBack)
        if ($null -eq $Global:AllSignInLogs -or $Global:AllSignInLogs.Count -eq 0) { return $false }

        $SignInLogs = $Global:AllSignInLogs | Where-Object {
            $_.UserPrincipalName -eq $UserPrincipalName -and $_.CreatedDateTime -ge $StartDateTime
        }

        if ($SignInLogs -and $SignInLogs.Count -gt 0) {
            if (-not (Test-Path $UserFolderPath)) { return $false }

            $SignInLogFile = Join-Path -Path $UserFolderPath -ChildPath "SignIn_Logs_Graph.csv"
            $SignInLogs | ForEach-Object {
                $ErrorCode = $_.Status.ErrorCode
                $Status    = if ($ErrorCode -eq 0) { 'Success' } else { 'Failed' }
                $Failure   = $_.Status.FailureReason
                if ($Failure -eq 'Other.') { $Failure = 'None' }

                $AppliedPolicies = @()
                $_.AppliedConditionalAccessPolicies | ForEach-Object {
                    if ($_.Result -eq 'Success' -or $_.Result -eq 'Failed') { $AppliedPolicies += $_.DisplayName }
                }

                [PSCustomObject]@{
                    'Signin Date'                         = $_.CreatedDateTime
                    'User Name'                           = $_.UserDisplayName
                    'SigninId'                            = $_.Id
                    'UPN'                                 = $_.UserPrincipalName
                    'Status'                              = $Status
                    'Failure Reason'                      = $Failure
                    'Ip Address'                          = $_.IpAddress
                    'Location'                            = "$($_.Location.City),$($_.Location.State),$($_.Location.CountryOrRegion)"
                    'Device Name'                         = $_.DeviceDetail.DisplayName
                    'Browser'                             = $_.DeviceDetail.Browser
                    'Operating System'                    = $_.DeviceDetail.OperatingSystem
                    'User Type'                           = $_.UserType
                    'Authentication Requirement'          = $_.AuthenticationRequirement
                    'Risk Detail'                         = $_.RiskDetail
                    'Risk State'                          = $_.RiskState
                    'Conditional Access Status'           = $_.ConditionalAccessStatus
                    'Applied Conditional Access Policies' = if ($AppliedPolicies.Count -eq 0) { 'None' } else { $AppliedPolicies -join ', ' }
                    'IsInteractive'                       = $_.IsInteractive
                    'App'                                 = $_.AppDisplayName
                    'Resource'                            = $_.ResourceDisplayName
                }
            } | Export-Csv -Path $SignInLogFile -NoTypeInformation -Encoding UTF8

            Write-Log "        ✓ Anmelde-Logs: $($SignInLogs.Count) Events gespeichert" -Color Green
            return $true
        }
        return $false
    }
    catch {
        Write-Log "        [FEHLER] Anmelde-Funktion: $($_.Exception.Message)" -Color Red
        return $false
    }
}

# ============================================================================
# HAUPTSKRIPT START
# ============================================================================

if (-not (Test-PowerShell7)) {
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

try {
    $ScriptSettings = Initialize-DeploymentSettings
    $TenantID = [string]$ScriptSettings.TenantID
    $TenantGuid = [guid]::Empty
    if (-not [guid]::TryParse($TenantID, [ref]$TenantGuid) -or $TenantGuid -eq [guid]::Empty) {
        throw "TenantID fehlt oder ist ungültig. Bitte einen Wert in '$SettingsFilePath' eintragen."
    }
    foreach ($ModuleName in $ModuleInstallOrder) {
        if (-not $ScriptSettings.ModuleVersions.ContainsKey($ModuleName) -or [string]::IsNullOrWhiteSpace([string]$ScriptSettings.ModuleVersions[$ModuleName])) {
            throw "Modulversion für '$ModuleName' fehlt im Abschnitt ModuleVersions der Einstellungsdatei."
        }
        $PinnedVersions[$ModuleName] = [string]$ScriptSettings.ModuleVersions[$ModuleName]
    }
    Update-ScriptFromGitHub
}
catch {
    Write-Host "`n[FEHLER] Einstellungen: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

if (-not (Test-AndInstallModules)) {
    Write-Host "`n[ABBRUCH] Nicht alle Module konnten bereitgestellt werden." -ForegroundColor Red
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

if (-not (Import-ModulesInOrder)) {
    Write-Host "`n[ABBRUCH] Module konnten nicht korrekt geladen werden." -ForegroundColor Red
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

try {
    Set-HawkIPGeolocationProvider -ApiToken ([string]$ScriptSettings.GeoLocation.ApiToken)
    if ([string]::IsNullOrWhiteSpace([string]$ScriptSettings.GeoLocation.ApiToken)) {
        Write-Host "  [INFO] Kein IPinfo-Token konfiguriert; Stadt/Region werden als Unknown gespeichert, Hawk läuft weiter." -ForegroundColor Gray
    }
}
catch {
    Write-Host "`n[ABBRUCH] IP-Geolokalisierung konnte nicht konfiguriert werden: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "HAWK AUDIT LOG COLLECTION" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ============================================================================
# SCHRITT 1: Verzeichnis vorbereiten
# ============================================================================

Write-Host "`n[SCHRITT 1] Verzeichnis vorbereiten..." -ForegroundColor Cyan
if (-not (Test-Path -Path $ZielPfadAuditLogsBase)) {
    try {
        New-Item -Path $ZielPfadAuditLogsBase -ItemType Directory -ErrorAction Stop | Out-Null
        Write-Log "  [ERFOLG] Verzeichnis erstellt" -Color Green
    }
    catch {
        Write-Host "  [FEHLER] $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "`nDrücke Enter zum Beenden"; exit 1
    }
}

# ============================================================================
# SCHRITT 2: Verbindungen herstellen
# ============================================================================

Write-Host "`n[SCHRITT 2] Verbindungen herstellen..." -ForegroundColor Cyan

Write-Log "  Verbinde mit Microsoft Graph..." -Color White
try {
    Connect-MgGraph -Scopes 'User.Read.All','Directory.Read.All','AuditLog.Read.All', `
                            'Policy.Read.ConditionalAccess','IdentityRiskEvent.Read.All', `
                            'IdentityRiskyUser.Read.All' `
                    -TenantId $TenantID -ErrorAction Stop -NoWelcome
    Write-Log "  [ERFOLG] Microsoft Graph verbunden" -Color Green
}
catch {
    Write-Host "  [FEHLER] Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

Write-Log "  Verbinde mit Exchange Online..." -Color White
try {
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    Write-Log "  [ERFOLG] Exchange Online verbunden" -Color Green
}
catch {
    Write-Host "  [FEHLER] Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-MgGraph | Out-Null
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

# ============================================================================
# SCHRITT 3: Benutzer abrufen und verarbeiten
# ============================================================================

Write-Host "`n[SCHRITT 3] Postfach-Logs erfassen..." -ForegroundColor Cyan

$StartDate = (Get-Date).AddDays(-$DaysToLookBack)
$EndDate   = Get-Date
Write-Log "  Erfassungszeitraum: $($StartDate.ToString('dd.MM.yyyy')) - $($EndDate.ToString('dd.MM.yyyy')) ($DaysToLookBack Tage)" -Color Gray

$Global:HawkBasePath   = $ZielPfadAuditLogsBase
$Global:HawkOutputPath = $null

# Hawk Global-Variable zuruecksetzen damit ein frischer Ordner angelegt wird.
# Noetig wenn der Ausgabeordner manuell geloescht wurde - sonst findet Hawk
# den alten (nicht mehr existenten) Pfad und schlaegt bei jedem User fehl.
Remove-Variable -Name Hawk -Scope Global -ErrorAction SilentlyContinue


# Alle Anmelde-Logs einmalig laden
Write-Log "`n  Lade alle Anmelde-Logs aus Graph Beta API (einmalig)..." -Color White
$Global:AllSignInLogs = @()
try {
    $Global:AllSignInLogs = Get-MgBetaAuditLogSignIn -All -ErrorAction Stop
    Write-Log "  [ERFOLG] $($Global:AllSignInLogs.Count) Anmelde-Einträge geladen" -Color Green
}
catch {
    Write-Log "  [WARNUNG] Anmelde-Logs nicht verfügbar: $($_.Exception.Message)" -Color Yellow
}

# Benutzer abrufen
Write-Log "`n  Rufe alle Benutzer ab..." -Color White
try {
    $AllUsers = Get-MgUser -All -ErrorAction Stop
    Write-Log "  [ERFOLG] $($AllUsers.Count) Benutzer gefunden" -Color Green
}
catch {
    Write-Host "  [FEHLER] $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Disconnect-MgGraph | Out-Null
    Read-Host "`nDrücke Enter zum Beenden"; exit 1
}

$SuccessCount          = 0
$SuccessWithSignInOnly = 0
$NoMailboxCount        = 0
$ErrorCount            = 0
$SkippedCount          = 0
$ErrorLogFile          = $null
$UserCounter           = 0
$StartTime             = Get-Date

Write-Host "`n  Verarbeite Benutzer..." -ForegroundColor White

foreach ($User in $AllUsers) {
    $UserCounter++
    Write-Progress -Activity "Hawk Protokoll-Erfassung" `
                   -Status "[$UserCounter/$($AllUsers.Count)] $($User.UserPrincipalName)" `
                   -PercentComplete ([math]::Round(($UserCounter / $AllUsers.Count) * 100, 2))

    if ([string]::IsNullOrWhiteSpace($User.UserPrincipalName)) { $SkippedCount++; continue }

    $HawkSuccess  = $false
    $SignInSuccess = $false

    try {
        Write-Log "    [$UserCounter/$($AllUsers.Count)] -> Hawk: $($User.UserPrincipalName)" -Color DarkGray

        # Hawk 4.0: Start-HawkUserInvestigation mit direkten Parametern
        # NonInteractive-Modus wird automatisch aktiviert wenn Parameter übergeben werden
        if ($VerboseOutput) {
            Start-HawkUserInvestigation -UserPrincipalName $User.UserPrincipalName `
                                        -DaysToLookBack $DaysToLookBack `
                                        -FilePath $Global:HawkBasePath `
                                        -SkipUpdate `
                                        -ErrorAction Stop
        }
        else {
            Start-HawkUserInvestigation -UserPrincipalName $User.UserPrincipalName `
                                        -DaysToLookBack $DaysToLookBack `
                                        -FilePath $Global:HawkBasePath `
                                        -SkipUpdate `
                                        -ErrorAction Stop *>&1 | Out-Null
        }

        # Hawk-Ordner nach erstem Aufruf ermitteln
        if ($null -eq $Global:HawkOutputPath) {
            $HawkFolder = Get-ChildItem -Path $Global:HawkBasePath -Directory -Filter "Hawk_*" -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($HawkFolder) {
                $Global:HawkOutputPath = $HawkFolder.FullName
                $Global:HawkFolderName = $HawkFolder.Name
                Write-Log "      -> Hawk-Ordner: $($HawkFolder.Name)" -Color Gray
            }
        }

        $HawkSuccess = $true
    }
    catch {
        $ErrorMessage = $_.Exception.Message
		    # Temporäre Diagnose für den vollständigen Fehler
    Add-Content -Path (Join-Path $Global:HawkBasePath "ErrorDetails.txt") -Value @"
Zeit: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Benutzer: $($User.UserPrincipalName)
Fehlertyp: $($_.Exception.GetType().FullName)
Fehlerdetails: $($_.Exception.ToString())
Aufrufstapel: $($_.ScriptStackTrace)
================================================
"@
        if ($ErrorMessage -match "couldn't be found|NotFound|no mailbox|Mailbox not found") {
            Write-Log "  [$UserCounter/$($AllUsers.Count)] --  $($User.UserPrincipalName) (kein Postfach)" -Color DarkCyan
            $NoMailboxCount++
        }
        else {
            Write-Host "  [$UserCounter/$($AllUsers.Count)] ERR $($User.UserPrincipalName)" -ForegroundColor Red
            Write-Log "      $($ErrorMessage.Substring(0, [Math]::Min(120, $ErrorMessage.Length)))" -Color DarkRed
            $ErrorCount++

            if ($null -eq $Global:HawkOutputPath) {
                # Kein Fallback-Ordner anlegen - ErrorLog direkt ins Basisverzeichnis schreiben
                $ErrorLogFile = Join-Path $Global:HawkBasePath "ErrorLog.txt"
            }
            else {
                $ErrorLogFile = Join-Path $Global:HawkOutputPath "ErrorLog.txt"
            }
            Add-Content -Path $ErrorLogFile -Value "================================================`nZeit: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`nBenutzer: $($User.UserPrincipalName)`nFehler: $ErrorMessage`n================================================`n`n" -ErrorAction SilentlyContinue
        }
    }

    # Benutzerordner für SignIn-Logs
    if ($null -ne $Global:HawkOutputPath) {
        $UserFolderPath = Join-Path $Global:HawkOutputPath ($User.UserPrincipalName -replace '[\\/:*?"<>|]', '_')
        if (-not (Test-Path $UserFolderPath)) {
            try { New-Item -Path $UserFolderPath -ItemType Directory -Force -ErrorAction Stop | Out-Null }
            catch { Write-Host "  [$UserCounter/$($AllUsers.Count)] ERR Benutzerordner nicht erstellbar" -ForegroundColor Red; continue }
        }
    }
    else {
        Write-Host "  [$UserCounter/$($AllUsers.Count)] ERR Hawk-Hauptordner nicht gefunden" -ForegroundColor Red
        continue
    }

    $SignInSuccess = Get-UserSignInLogs -UserPrincipalName $User.UserPrincipalName `
                                        -DaysBack $DaysToLookBack `
                                        -UserFolderPath $UserFolderPath

    if ($HawkSuccess -and $SignInSuccess) {
        Write-Host "  [$UserCounter/$($AllUsers.Count)] OK  $($User.UserPrincipalName)" -ForegroundColor Green
        $SuccessCount++
    }
    elseif ($HawkSuccess) {
        Write-Host "  [$UserCounter/$($AllUsers.Count)] OK  $($User.UserPrincipalName) (keine Anmelde-Logs)" -ForegroundColor Green
        $SuccessCount++
    }
    elseif (-not $HawkSuccess -and $SignInSuccess) {
        # Kein Postfach aber SignIn-Logs vorhanden - aus NoMailboxCount rausnehmen, in SuccessWithSignInOnly
        $NoMailboxCount--
        Write-Host "  [$UserCounter/$($AllUsers.Count)] OK  $($User.UserPrincipalName) (nur Anmelde-Logs, kein Postfach)" -ForegroundColor Cyan
        $SuccessWithSignInOnly++
    }

    Start-Sleep -Milliseconds 100
}

Write-Progress -Activity "Hawk Protokoll-Erfassung" -Completed
$CollectionDuration = (Get-Date) - $StartTime

# ============================================================================
# SCHRITT 4: Bereinigung
# ============================================================================

Write-Host "`n[SCHRITT 4] Bereinigung..." -ForegroundColor Cyan
$DirectoriesDeleted = 0
try {
    $CutoffDate = (Get-Date).AddDays(-$RetentionDays)

    $AllHawkFolders = Get-ChildItem -Path $ZielPfadAuditLogsBase -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "Hawk_*" -and $_.FullName -ne $Global:HawkOutputPath }

    foreach ($Folder in $AllHawkFolders) {
        # Zuerst Telemetrie-Dateien in diesem Ordner löschen
        $TelFiles = Get-ChildItem -Path $Folder.FullName -Recurse -Filter "*_logs.csv" -ErrorAction SilentlyContinue
        foreach ($TelFile in $TelFiles) {
            Remove-Item -Path $TelFile.FullName -Force -ErrorAction SilentlyContinue
        }

        # Jetzt prüfen ob Ordner leer oder abgelaufen
        $RemainingFiles = Get-ChildItem -Path $Folder.FullName -Recurse -File -ErrorAction SilentlyContinue
        $IsEmpty   = ($RemainingFiles.Count -eq 0)
        $IsExpired = ($Folder.LastWriteTime -lt $CutoffDate)

        if ($IsEmpty -or $IsExpired) {
            try {
                Remove-Item -Path $Folder.FullName -Force -Recurse -ErrorAction Stop
                $DirectoriesDeleted++
                Write-Log "  [OK] Gelöscht: $($Folder.Name) $(if ($IsEmpty) { '(leer)' } else { '(abgelaufen)' })" -Color Gray
            }
            catch { Write-Log "  [FEHLER] Konnte nicht löschen: $($Folder.Name)" -Color Red }
        }
    }

    # Auch im aktuellen Lauf-Ordner Telemetrie aufräumen
    if ($Global:HawkOutputPath -and (Test-Path $Global:HawkOutputPath)) {
        $TelFiles = Get-ChildItem -Path $Global:HawkOutputPath -Recurse -Filter "*_logs.csv" -ErrorAction SilentlyContinue
        $TelemetryCount = 0
        foreach ($TelFile in $TelFiles) {
            try { Remove-Item -Path $TelFile.FullName -Force -ErrorAction Stop; $TelemetryCount++ }
            catch {}
        }
        if ($TelemetryCount -gt 0) {
            Write-Log "  [OK] $TelemetryCount PSAppInsights Telemetrie-Datei(en) gelöscht" -Color Green
        }
    }

    if ($DirectoriesDeleted -gt 0) {
        Write-Log "  [ERFOLG] $DirectoriesDeleted alter Ordner gelöscht" -Color Green
    }
    else {
        Write-Log "  [INFO] Keine alten Hawk-Ordner zum Löschen gefunden" -Color Green
    }
}
catch { Write-Log "  [FEHLER] Bereinigung: $($_.Exception.Message)" -Color Red }

# ============================================================================
# SCHRITT 5: Zusammenfassung
# ============================================================================

$NoDataCount = $AllUsers.Count - $SuccessCount - $SuccessWithSignInOnly - $NoMailboxCount - $ErrorCount - $SkippedCount
if ($NoDataCount -lt 0) { $NoDataCount = 0 }  # Kann durch Überschneidungen (kein Postfach + SignIn) negativ werden

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "ZUSAMMENFASSUNG" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`n  Zeitraum : $($StartDate.ToString('dd.MM.yyyy')) - $($EndDate.ToString('dd.MM.yyyy')) ($DaysToLookBack Tage)" -ForegroundColor Gray
Write-Host "  Laufzeit : $($CollectionDuration.Hours)h $($CollectionDuration.Minutes)m $($CollectionDuration.Seconds)s" -ForegroundColor Gray
Write-Host "`n  Benutzer gesamt              : $($AllUsers.Count)" -ForegroundColor White
Write-Host "  Postfach-Logs + Anmelde-Logs : $SuccessCount" -ForegroundColor $(if ($SuccessCount -gt 0) { "Green" } else { "White" })
Write-Host "  Nur Anmelde-Logs (kein Postfach vorhanden) : $SuccessWithSignInOnly" -ForegroundColor $(if ($SuccessWithSignInOnly -gt 0) { "Cyan" } else { "White" })
Write-Host "  Kein Postfach, keine Anmelde-Logs : $NoMailboxCount" -ForegroundColor DarkGray
Write-Host "  Keine Daten                  : $NoDataCount" -ForegroundColor DarkGray
Write-Host "  Fehler                       : $ErrorCount" -ForegroundColor $(if ($ErrorCount -gt 0) { "Red" } else { "White" })
Write-Host "`n  Ausgabe-Ordner :" -ForegroundColor Gray
Write-Host "    Server : $($env:COMPUTERNAME)" -ForegroundColor Gray
Write-Host "    Pfad   : $Global:HawkOutputPath" -ForegroundColor Gray
if ($DirectoriesDeleted -gt 0) { Write-Host "  Bereinigt: $DirectoriesDeleted alte Ordner gelöscht" -ForegroundColor Green }
if ($ErrorCount -gt 0 -and $ErrorLogFile -and (Test-Path $ErrorLogFile)) { Write-Host "  Fehler-Log: $ErrorLogFile" -ForegroundColor Yellow }
Write-Host "`n  Abgeschlossen: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Disconnect-MgGraph | Out-Null

# ============================================================================
# MAIL-VERSAND
# ============================================================================

$MailSettings = Initialize-MailSettings

if ($MailSettings.SendMail -eq $true) {
    Write-Host "`n[MAIL] Versende Zusammenfassung..." -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($MailSettings.MailTo)) {
        Write-Host "  [WARNUNG] Kein Empfänger konfiguriert - kein Mailversand" -ForegroundColor Yellow
    }
    elseif ([string]::IsNullOrWhiteSpace($MailSettings.Host)) {
        Write-Host "  [WARNUNG] Kein SMTP-Host konfiguriert - kein Mailversand" -ForegroundColor Yellow
    }
    else {
        $StatusColor   = if ($ErrorCount -gt 0) { '#c0392b' } else { '#27ae60' }
        $StatusText    = if ($ErrorCount -gt 0) { "Mit Fehlern abgeschlossen" } else { "Erfolgreich abgeschlossen" }

        $HtmlBody = @"
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f0f2f5;font-family:Arial,sans-serif;font-size:14px;color:#333;">
<table width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f0f2f5;padding:20px 0;">
  <tr><td align="center">
  <table width="680" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.12);">

    <!-- HEADER -->
    <tr><td style="background:#2c3e50;padding:24px 30px;">
      <p style="margin:0;color:#ffffff;font-size:22px;font-weight:bold;">🦅 Hawk Audit Log Zusammenfassung</p>
      <p style="margin:6px 0 0;color:#a0b0c0;font-size:13px;">$($MailSettings.CompanyName) &nbsp;|&nbsp; $(Get-Date -Format 'dd.MM.yyyy HH:mm') Uhr</p>
    </td></tr>

    <!-- STATUS -->
    <tr><td style="background:$StatusColor;padding:11px 30px;">
      <p style="margin:0;color:#ffffff;font-weight:bold;font-size:14px;">$StatusText</p>
    </td></tr>

    <!-- STATS -->
    <tr><td style="padding:24px 30px 10px;">
      <table width="100%" cellpadding="0" cellspacing="0" border="0">
        <tr>
          <td width="25%" align="center" style="padding:0 6px 0 0;">
            <table width="100%" cellpadding="14" cellspacing="0" border="0" style="background:#f8f9fa;border-radius:6px;border-top:3px solid #2c3e50;">
              <tr><td align="center">
                <p style="margin:0;font-size:30px;font-weight:bold;color:#2c3e50;">$($AllUsers.Count)</p>
                <p style="margin:4px 0 0;font-size:11px;color:#666;">Benutzer gesamt</p>
              </td></tr>
            </table>
          </td>
          <td width="25%" align="center" style="padding:0 6px;">
            <table width="100%" cellpadding="14" cellspacing="0" border="0" style="background:#f8f9fa;border-radius:6px;border-top:3px solid #27ae60;">
              <tr><td align="center">
                <p style="margin:0;font-size:30px;font-weight:bold;color:#27ae60;">$SuccessCount</p>
                <p style="margin:4px 0 0;font-size:11px;color:#666;">Postfach + Anmelde-Logs</p>
              </td></tr>
            </table>
          </td>
          <td width="25%" align="center" style="padding:0 6px;">
            <table width="100%" cellpadding="14" cellspacing="0" border="0" style="background:#f8f9fa;border-radius:6px;border-top:3px solid #2980b9;">
              <tr><td align="center">
                <p style="margin:0;font-size:30px;font-weight:bold;color:#2980b9;">$SuccessWithSignInOnly</p>
                <p style="margin:4px 0 0;font-size:11px;color:#666;">Nur Anmelde-Logs</p>
              </td></tr>
            </table>
          </td>
          <td width="25%" align="center" style="padding:0 0 0 6px;">
            <table width="100%" cellpadding="14" cellspacing="0" border="0" style="background:#f8f9fa;border-radius:6px;border-top:3px solid $(if ($ErrorCount -gt 0) { '#c0392b' } else { '#95a5a6' });">
              <tr><td align="center">
                <p style="margin:0;font-size:30px;font-weight:bold;color:$(if ($ErrorCount -gt 0) { '#c0392b' } else { '#95a5a6' });">$ErrorCount</p>
                <p style="margin:4px 0 0;font-size:11px;color:#666;">Fehler</p>
              </td></tr>
            </table>
          </td>
        </tr>
      </table>
    </td></tr>

    <!-- DETAILS -->
    <tr><td style="padding:16px 30px 24px;">
      <table width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">
        <tr>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;color:#888;width:180px;font-size:13px;">Erfassungszeitraum</td>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;font-weight:500;font-size:13px;">$($StartDate.ToString('dd.MM.yyyy')) – $($EndDate.ToString('dd.MM.yyyy')) ($DaysToLookBack Tage)</td>
        </tr>
        <tr>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;color:#888;font-size:13px;">Kein Postfach vorhanden</td>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;font-weight:500;font-size:13px;">$NoMailboxCount Benutzer (kein Exchange-Postfach, keine Postfach-Logs gesichert)</td>
        </tr>
        <tr>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;color:#888;font-size:13px;">Laufzeit</td>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;font-weight:500;font-size:13px;">$($CollectionDuration.Hours)h $($CollectionDuration.Minutes)m $($CollectionDuration.Seconds)s</td>
        </tr>
        <tr>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;color:#888;font-size:13px;">Ausgabe-Ordner</td>
          <td style="padding:9px 12px;border-bottom:1px solid #eee;font-size:13px;">
            <table cellpadding="0" cellspacing="0" border="0">
              <tr><td style="color:#888;width:50px;font-size:13px;">Server</td><td style="font-weight:500;font-size:13px;padding-left:8px;">$($env:COMPUTERNAME)</td></tr>
              <tr><td style="color:#888;font-size:13px;padding-top:4px;">Pfad</td><td style="font-weight:500;font-size:13px;padding-left:8px;padding-top:4px;">$Global:HawkOutputPath</td></tr>
            </table>
          </td>
        </tr>
        $(if ($ErrorCount -gt 0 -and $ErrorLogFile) {
        "<tr><td style='padding:9px 12px;border-bottom:1px solid #eee;color:#c0392b;font-size:13px;'>Fehler-Log</td><td style='padding:9px 12px;border-bottom:1px solid #eee;font-weight:500;font-size:13px;color:#c0392b;'>$ErrorLogFile</td></tr>"
        })
      </table>
    </td></tr>

    <!-- FOOTER -->
    <tr><td style="background:#f8f9fa;padding:12px 30px;border-top:1px solid #eee;">
      <p style="margin:0;font-size:12px;color:#aaa;">Hawk Forensics 4.0 &nbsp;|&nbsp; hawkforensics.io &nbsp;|&nbsp; Erstellt am $(Get-Date -Format 'dd.MM.yyyy') um $(Get-Date -Format 'HH:mm') Uhr</p>
    </td></tr>

  </table>
  </td></tr>
</table>
</body>
</html>
"@
        Send-HawkMailReport -MailSettings $MailSettings -HtmlBody $HtmlBody
    }
}
else {
    Write-Log "  [INFO] Kein Mailversand (SendMail=false in settings.json)" -Color Gray
}


# PSFramework Logging deaktivieren damit keine neuen *_logs.csv Dateien
# mehr in alte Ordner geschrieben werden
try {
    Set-PSFLoggingProvider -Name 'logfile' -InstanceName 'Hawk' -Enabled $false -ErrorAction SilentlyContinue
    Wait-PSFMessage -ErrorAction SilentlyContinue
} catch {}

# Abschliessende Telemetrie-Bereinigung nach Logging-Stop
Start-Sleep -Milliseconds 500
Get-ChildItem -Path $ZielPfadAuditLogsBase -Recurse -Filter "*_logs.csv" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue }

# Finale Bereinigung: alle leeren Hawk-Ordner löschen (außer aktuellem Lauf)
Get-ChildItem -Path $ZielPfadAuditLogsBase -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "Hawk_*" -and $_.FullName -ne $Global:HawkOutputPath } |
    ForEach-Object {
        $Files = Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue
        if ($Files.Count -eq 0) {
            Remove-Item -Path $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

if ($ModuleUpdatesMade.Count -gt 0) {
    $UniqueModuleUpdates = @($ModuleUpdatesMade | Sort-Object -Unique)
    Write-Host "`n[MODULE] Aktualisiert in diesem Lauf: $($UniqueModuleUpdates -join ', ')" -ForegroundColor Cyan
    $UpdateConfirmation = (Read-Host 'Waren die Modulupdates und der Lauf erfolgreich? Neue Versionen in den Einstellungen speichern? [J/N]').Trim()
    if ($UpdateConfirmation -match '^(J|j)$') {
        try {
            Save-ModuleVersionsToSettings -Versions $PinnedVersions
            Write-Host "  [OK] Modulversionen in $SettingsFilePath gespeichert." -ForegroundColor Green
        }
        catch {
            Write-Host "  [FEHLER] Modulversionen konnten nicht gespeichert werden: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host '  [INFO] Gespeicherte Modulversionen bleiben unverändert.' -ForegroundColor Gray
    }
}

Write-Host "[INFO] Alle Verbindungen getrennt" -ForegroundColor Green
Write-Host "`nQuelle: https://hawkforensics.io/" -ForegroundColor Gray
Read-Host "`nDrücke Enter zum Beenden"

