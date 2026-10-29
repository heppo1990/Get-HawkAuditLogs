# Get-HawkAuditLogs

PowerShell wrapper for collecting Hawk forensic logs and Entra sign-in logs.

## Setup

1. Download `Get-HawkAuditLogs.ps1` and `Get-HawkAuditLogs.settings.json` from the latest [GitHub release](https://github.com/heppo1990/Get-HawkAuditLogs/releases).
2. Set `TenantID` in the settings file and configure mail fields if mail delivery is needed.
3. For city and region enrichment, set `GeoLocation.ApiToken` to an IPinfo Legacy API token. IPinfo Lite does not include city or region. The script continues with unknown location values if the token is missing or a lookup fails.
4. Run from PowerShell 7 as Administrator.

The settings file in this repository contains neutral values only. A deployed copy can contain tenant identifiers, mail addresses, hostnames and API tokens. Do not commit a configured settings file to this public repository.

## Script and settings updates

At startup, the script checks the latest GitHub release and verifies SHA-256 checksums. A newer script is downloaded and restarted automatically. The settings file is updated from the same release: new keys are added, while existing values and custom keys are retained. `SettingsVersion` is advanced to the published version. Set `ScriptUpdates.Enabled` to `false` to disable online updates.

A push to `main` creates a GitHub release using `$ScriptVersion`. Increase that version in `Get-HawkAuditLogs.ps1` before publishing another release.

## Module versions

Pinned module versions are read from `ModuleVersions` in the settings file. After a module update and collection, the script asks whether the run succeeded. Answering `J` saves the new module versions to the settings file.

## Geolocation

Public IP addresses are sent to IPinfo for lookup. The service can return approximate city and region data; this is a third-party disclosure and must not be treated as an exact physical location. See [IPinfo's plan comparison](https://support.ipinfo.io/hc/en-us/articles/34121895556242-Legacy-Free-API-vs-IPinfo-Lite) for current plan and quota details.

