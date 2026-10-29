# Get-HawkAuditLogs

PowerShell-Skript zum Sammeln von Hawk-Forensikdaten und Entra-Anmeldeprotokollen.

## Einrichtung

1. Lade `Get-HawkAuditLogs.ps1` und `Get-HawkAuditLogs.settings.json` aus dem neuesten [GitHub-Release](https://github.com/heppo1990/Get-HawkAuditLogs/releases) herunter.
2. Trage die `TenantID` in der Settings-Datei ein. Ergänze bei Bedarf die Mail-Einstellungen.
3. Für die Standortanreicherung mit Stadt und Region trägst du unter `GeoLocation.ApiToken` einen IPinfo-Legacy-API-Token ein. IPinfo Lite liefert keine Stadt- oder Regionsangaben. Fehlt der Token oder schlägt eine Abfrage fehl, läuft das Skript mit unbekanntem Standort weiter.
4. Starte das Skript in PowerShell 7 als Administrator.

Die Settings-Datei im Repository enthält ausschließlich neutrale Standardwerte. Sie wird absichtlich nicht von `.gitignore` ausgeschlossen, damit genau diese eine Datei als Standard versioniert werden kann. Eine bereitgestellte und konfigurierte Kopie kann Mandantenkennungen, Mailadressen, Servernamen und API-Tokens enthalten. Eine konfigurierte Datei darf nicht in dieses öffentliche Repository hochgeladen werden.

Die `.gitignore` schließt Backups, Laufzeitdateien und zusätzliche lokale Settings-Varianten aus. Sie kann Änderungen an der versionierten Standarddatei nicht ignorieren; führe das Skript deshalb für den Produktivbetrieb mit einer bereitgestellten Kopie außerhalb des Repository-Arbeitsverzeichnisses aus.

## Skript- und Settings-Updates

Beim Start prüft das Skript das neueste GitHub-Release und kontrolliert die SHA-256-Prüfsummen. Ist eine neuere Skriptversion verfügbar, wird sie heruntergeladen und automatisch neu gestartet. Die Settings-Datei wird ebenfalls aktualisiert: Neue Schlüssel werden ergänzt, vorhandene Werte und zusätzliche eigene Schlüssel bleiben erhalten. `SettingsVersion` wird auf die veröffentlichte Version gesetzt. Mit `ScriptUpdates.Enabled: false` kannst du Online-Updates abschalten.

Ein Push auf `main` erstellt ein GitHub-Release anhand von `$ScriptVersion`. Erhöhe diese Version in `Get-HawkAuditLogs.ps1`, bevor du eine weitere Version veröffentlichst.

## Modulversionen

Die festgelegten Modulversionen stehen unter `ModuleVersions` in der Settings-Datei. Nach einem Modulupdate und der Sammlung fragt das Skript, ob der Lauf erfolgreich war. Mit `J` werden die neuen Modulversionen in der Settings-Datei gespeichert.

## Geolokalisierung

Öffentliche IP-Adressen werden zur Abfrage an IPinfo übermittelt. Die gelieferten Stadt- und Regionsangaben sind Näherungswerte und keine exakten physischen Standorte. Aktuelle Tarife und Kontingente findest du im [IPinfo-Tarifvergleich](https://support.ipinfo.io/hc/en-us/articles/34121895556242-Legacy-Free-API-vs-IPinfo-Lite).

