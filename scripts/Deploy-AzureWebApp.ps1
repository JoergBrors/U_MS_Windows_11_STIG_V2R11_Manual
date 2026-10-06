#Requires -Version 7.0
<#
.SYNOPSIS
  Deployt Policy Studio auf eine Azure Web App (Free Tier F1) mit Key Vault, Managed Identity und Entra-ID-Anmeldung.

.DESCRIPTION
  Liest die Infrastruktur aus einer JSON-Datei (Vorlage: infrastructure.json.example) und legt alles
  an, was fehlt:
    - Resource Group, App Service Plan (F1, Linux) und Web App mit system-assigned Managed Identity
    - Key Vault (RBAC-Modell); die Web App erhält die Rolle "Key Vault Secrets User"
    - Alle Werte aus der lokalen .env werden als Secrets in den Key Vault übertragen und der App
      als Key-Vault-Referenzen bereitgestellt (die Werte stehen nie in App Settings oder in der JSON)
    - Entra-App-Registrierung inkl. Service Principal, Client-Secret (nur im Key Vault) und
      optionaler Zuweisung von Benutzern/Gruppen; die Anmeldung läuft über App Service Authentication
    - Zip-Deployment (Frontend-Build + Server) und Health-Check
  Das Skript ist idempotent, läuft mit PowerShell 7 und Azure CLI unter Windows, macOS und Linux.

.PARAMETER ConfigPath
  Pfad zur JSON-Konfiguration. Standard: infrastructure.json neben diesem Skript.
.PARAMETER SkipBuild
  Vorhandenes dist/ verwenden, nicht neu bauen.
.PARAMETER InfrastructureOnly
  Ressourcen, Secrets und Anmeldung einrichten, aber nichts deployen.
.PARAMETER RotateClientSecret
  Erzeugt ein neues Entra-Client-Secret und legt es im Key Vault ab (sonst bleibt ein vorhandenes bestehen).
.PARAMETER DryRun
  Konfiguration und .env prüfen und das Paket lokal bauen, aber keine Azure-Aufrufe ausführen.
.PARAMETER AllowPaidSku
  Erlaubt das Neuanlegen eines Plans mit anderer SKU als F1.
.PARAMETER OverwriteExisting
  Standardmäßig überschreibt das Skript nichts, was in Azure schon gesetzt ist (vorhandene App Settings,
  Startbefehl, Redirect-URIs, Anmelde-Konfiguration usw.), sondern ergänzt nur Fehlendes und verschärft
  höchstens Sicherheitseinstellungen. Mit diesem Schalter werden die Werte aus der JSON erzwungen.
  Ausnahme: Secrets aus der .env werden immer mit der .env abgeglichen.
.PARAMETER NoPrune
  Löscht keine Key-Vault-Secrets (und App Settings), deren Schlüssel nicht mehr in der .env steht.
.PARAMETER SelectPlan
  Zeigt die vorhandenen Linux-App-Service-Pläne der Subscription zur Auswahl an. Statt eines neuen Plans
  kann so ein bestehender verwendet werden. Alternativ in der JSON appServicePlan.name (und optional
  appServicePlan.resourceGroup) auf einen vorhandenen Plan setzen und appServicePlan.useExisting auf true.

.EXAMPLE
  ./scripts/Deploy-AzureWebApp.ps1 -ConfigPath ./scripts/infrastructure.json
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'infrastructure.json'),
  [switch]$SkipBuild,
  [switch]$InfrastructureOnly,
  [switch]$RotateClientSecret,
  [switch]$DryRun,
  [switch]$AllowPaidSku,
  [switch]$SelectPlan,
  [switch]$OverwriteExisting,
  [switch]$NoPrune
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$errorRecordType = [System.Management.Automation.ErrorRecord]

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

# Führt az aus, wirft bei Fehlern und liefert nur stdout zurück (Warnungen auf stderr stören kein JSON).
# Vorübergehende Azure-Fehler (z. B. "Cannot acquire exclusive lock ... Retry the request later") werden wiederholt.
$transientPattern = 'Retry the request later|exclusive lock|TooManyRequests|ServiceUnavailable|InternalServerError|temporarily unavailable|GatewayTimeout|\b429\b|\b503\b|Connection (reset|aborted)'
function Invoke-Az {
  param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
  $maxAttempts = 6
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $all = & az @Arguments --only-show-errors 2>&1
    $stdout = @($all | Where-Object { $_ -isnot $errorRecordType })
    if ($LASTEXITCODE -eq 0) { return $stdout }
    $stderr = @($all | Where-Object { $_ -is $errorRecordType } | ForEach-Object { $_.ToString() })
    $text = ($stderr + $stdout) -join [Environment]::NewLine
    if ($attempt -lt $maxAttempts -and $text -match $transientPattern) {
      $delay = 15 * $attempt
      Write-Note "Azure meldet einen vorübergehenden Fehler, neuer Versuch $($attempt + 1)/$maxAttempts in $delay s…"
      Start-Sleep -Seconds $delay
      continue
    }
    throw "az $($Arguments[0..1] -join ' ') ist fehlgeschlagen: $text"
  }
}
function Invoke-AzJson { $text = (Invoke-Az @args --output json) -join ''; if ($text) { $text | ConvertFrom-Json } }
function Invoke-AzTsv { ((Invoke-Az @args --output tsv) -join '').Trim() }
function Test-Az {
  param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
  $null = & az @Arguments --only-show-errors 2>&1
  return $LASTEXITCODE -eq 0
}

# Schreibt Inhalte (JSON, Secrets) in eine temporäre Datei, damit sie nicht in der Prozessliste auftauchen.
function Use-TempFile([string]$Content, [scriptblock]$Action) {
  $path = Join-Path ([IO.Path]::GetTempPath()) "azdeploy-$([guid]::NewGuid())"
  try { [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false)); & $Action $path }
  finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-Setting($Object, [string]$Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) { return $Object.$Name }
  return $Default
}

# Rollenzuweisungen sind nach dem Anlegen eines Principals manchmal verzögert sichtbar, daher Wiederholungen.
function New-RoleAssignmentIfMissing([string]$PrincipalId, [string]$PrincipalType, [string]$Role, [string]$Scope) {
  for ($attempt = 1; $attempt -le 6; $attempt++) {
    try {
      Invoke-Az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType --role $Role --scope $Scope --output none | Out-Null
      return
    } catch {
      if ($_.Exception.Message -match 'already exists|RoleAssignmentExists') { return }
      if ($attempt -eq 6 -or $_.Exception.Message -notmatch 'PrincipalNotFound|does not exist in the directory') { throw }
      Start-Sleep -Seconds 10
    }
  }
}

# Liest ein Secret samt Tags (oder $null, wenn es fehlt). Wartet bei fehlenden Rechten auf die RBAC-Replikation.
function Get-KeyVaultSecret([string]$Vault, [string]$Name) {
  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try { return ((Invoke-Az keyvault secret show --vault-name $Vault --name $Name --query '{value:value,tags:tags}' --output json) -join '') | ConvertFrom-Json }
    catch {
      $message = $_.Exception.Message
      if ($message -match 'SecretNotFound|was not found|not found') { return $null }
      if ($attempt -eq 20 -or $message -notmatch 'Forbidden|AuthorizationFailed|not authorized|does not have') { throw }
      Write-Note 'Key-Vault-Berechtigung ist noch nicht wirksam, warte…'; Start-Sleep -Seconds 15
    }
  }
}
function Set-KeyVaultSecretValue([string]$Vault, [string]$Name, [string]$Value, [string[]]$Tags = @()) {
  Use-TempFile $Value {
    param($file)
    $setArgs = @('keyvault', 'secret', 'set', '--vault-name', $Vault, '--name', $Name, '--file', $file, '--encoding', 'utf-8', '--output', 'none')
    if ($Tags.Count -gt 0) { $setArgs += '--tags'; $setArgs += $Tags }
    for ($attempt = 1; $attempt -le 20; $attempt++) {
      try { Invoke-Az @setArgs | Out-Null; return }
      catch {
        $message = $_.Exception.Message
        # Ein zuvor gelöschtes Secret (Soft Delete) muss erst wiederhergestellt werden, bevor es neu geschrieben werden kann.
        if ($message -match 'deleted but recoverable|currently in a deleted state') { Invoke-Az keyvault secret recover --vault-name $Vault --name $Name --output none | Out-Null; Start-Sleep -Seconds 8; continue }
        if ($attempt -eq 20 -or $message -notmatch 'Forbidden|AuthorizationFailed|not authorized|does not have') { throw }
        Write-Note 'Key-Vault-Berechtigung ist noch nicht wirksam, warte…'; Start-Sleep -Seconds 15
      }
    }
  }
}

# Liest eine .env-Datei wie dotenv (KEY=VALUE, Kommentare, optionale Anführungszeichen). Später Treffer gewinnen.
function Read-EnvFile([string]$Path) {
  $values = [ordered]@{}
  foreach ($raw in Get-Content -LiteralPath $Path) {
    $line = $raw.Trim() -replace '^export\s+', ''
    if (-not $line -or $line.StartsWith('#')) { continue }
    $index = $line.IndexOf('=')
    if ($index -lt 1) { continue }
    $key = $line.Substring(0, $index).Trim()
    $value = $line.Substring($index + 1).Trim()
    if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1, $value.Length - 2) }
    $values[$key] = $value
  }
  return $values
}

# --- Konfiguration lesen und prüfen -------------------------------------------------------------
Write-Step "Konfiguration lesen: $ConfigPath"
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'Konfiguration nicht gefunden. Kopiere scripts/infrastructure.json.example nach scripts/infrastructure.json und passe sie an.' }
$configDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $ConfigPath)
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$resourceGroup = Get-Setting $config 'resourceGroup'
$location      = Get-Setting $config 'location'
$planName      = Get-Setting (Get-Setting $config 'appServicePlan') 'name'
$sku           = Get-Setting (Get-Setting $config 'appServicePlan') 'sku' 'F1'
$planResourceGroup = Get-Setting (Get-Setting $config 'appServicePlan') 'resourceGroup' ''
$useExistingPlan = [bool](Get-Setting (Get-Setting $config 'appServicePlan') 'useExisting' $false)
$web           = Get-Setting $config 'webApp'
$appName       = Get-Setting $web 'name'
$runtime       = Get-Setting $web 'runtime' 'NODE:22-lts'
$startup       = Get-Setting $web 'startupCommand' 'npm start'
$httpsOnly     = [bool](Get-Setting $web 'httpsOnly' $true)
$minTls        = Get-Setting $web 'minTlsVersion' '1.2'
$subscription  = Get-Setting $config 'subscriptionId' ''
$tags          = Get-Setting $config 'tags'
$plainSettings = Get-Setting $config 'appSettings'
$allowedIps    = @(Get-Setting $config 'allowedIpRanges' @())
$deployment    = Get-Setting $config 'deployment'
$buildFrontend = [bool](Get-Setting $deployment 'buildFrontend' $true)
$healthPath    = Get-Setting $deployment 'healthCheckPath' '/healthz'
$healthTimeout = [int](Get-Setting $deployment 'healthCheckTimeoutSeconds' 300)

$vaultConfig   = Get-Setting $config 'keyVault'
$vaultName     = Get-Setting $vaultConfig 'name'
$vaultSku      = Get-Setting $vaultConfig 'sku' 'standard'
$vaultRetention = [int](Get-Setting $vaultConfig 'retentionDays' 7)
$vaultPurge    = [bool](Get-Setting $vaultConfig 'purgeProtection' $false)
$envFileSetting = Get-Setting $vaultConfig 'envFile' '../.env'
$envExclude    = @(Get-Setting $vaultConfig 'envExclude' @('PORT'))

$entra         = Get-Setting $config 'entra'
$entraEnabled  = [bool](Get-Setting $entra 'enabled' $false)
$entraApp      = Get-Setting $entra 'application'
$entraName     = Get-Setting $entraApp 'displayName' 'Policy Studio'
$entraAudience = Get-Setting $entraApp 'signInAudience' 'AzureADMyOrg'
$entraRedirects = @(Get-Setting $entraApp 'additionalRedirectUris' @())
$entraSecretName = Get-Setting (Get-Setting $entra 'clientSecret') 'secretName' 'entra-client-secret'
$entraSecretYears = [int](Get-Setting (Get-Setting $entra 'clientSecret') 'validityYears' 1)
$entraAssignmentRequired = [bool](Get-Setting $entra 'assignmentRequired' $true)
$entraUsers    = @(Get-Setting $entra 'assignedUsers' @())
$entraGroups   = @(Get-Setting $entra 'assignedGroups' @())
$entraExcluded = @(@(Get-Setting $entra 'excludedPaths' @('/healthz')) + $healthPath | Select-Object -Unique)

$missing = @(@{n='resourceGroup';v=$resourceGroup},@{n='location';v=$location},@{n='appServicePlan.name';v=$planName},@{n='webApp.name';v=$appName},@{n='keyVault.name';v=$vaultName}) | Where-Object { [string]::IsNullOrWhiteSpace($_.v) } | ForEach-Object { $_.n }
if ($missing) { throw "Pflichtfelder fehlen in der Konfiguration: $($missing -join ', ')" }
if ($appName -match 'CHANGE-ME' -or $vaultName -match 'CHANGE-ME') { throw 'webApp.name oder keyVault.name enthält noch den Platzhalter CHANGE-ME. Beide Namen müssen weltweit eindeutig sein.' }
if ($appName -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,58}[a-zA-Z0-9])?$') { throw "webApp.name '$appName' ist ungültig (2-60 Zeichen, Buchstaben, Ziffern, Bindestrich)." }
if ($vaultName -notmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$') { throw "keyVault.name '$vaultName' ist ungültig (3-24 Zeichen, beginnt mit Buchstabe, nur Buchstaben, Ziffern, Bindestrich)." }
if ($vaultRetention -lt 7 -or $vaultRetention -gt 90) { throw 'keyVault.retentionDays muss zwischen 7 und 90 liegen.' }
if (-not $useExistingPlan -and -not $SelectPlan -and $sku -ne 'F1' -and -not $AllowPaidSku) { throw "SKU '$sku' ist nicht kostenfrei. Verwende F1 oder starte mit -AllowPaidSku, wenn Kosten gewollt sind." }
if ($entraEnabled -and $entraAudience -notin 'AzureADMyOrg', 'AzureADMultipleOrgs') { throw "entra.application.signInAudience '$entraAudience' wird nicht unterstützt (AzureADMyOrg oder AzureADMultipleOrgs)." }

# .env lesen: jeder Eintrag wird ein Key-Vault-Secret. Secret-Namen erlauben nur Buchstaben, Ziffern und Bindestrich.
$envFileFound = $false
$envSecrets = [ordered]@{}   # App-Setting-Name -> @{ SecretName; Value }
$envFile = if ([IO.Path]::IsPathRooted($envFileSetting)) { $envFileSetting } else { [IO.Path]::GetFullPath((Join-Path $configDirectory $envFileSetting)) }
if (Test-Path -LiteralPath $envFile) {
  $envFileFound = $true
  foreach ($entry in (Read-EnvFile $envFile).GetEnumerator()) {
    if ($entry.Key -in $envExclude -or [string]::IsNullOrEmpty($entry.Value)) { continue }
    $secretName = $entry.Key.ToLowerInvariant().Replace('_', '-')
    if ($secretName -notmatch '^[a-z0-9-]{1,127}$') { throw "Der .env-Schlüssel '$($entry.Key)' ergibt keinen gültigen Secret-Namen. Entferne ihn oder nimm ihn in keyVault.envExclude auf." }
    $envSecrets[$entry.Key] = @{ SecretName = $secretName; Value = $entry.Value }
  }
  Write-Note ".env: $($envSecrets.Count) Werte für den Key Vault ($($envSecrets.Keys -join ', '))"
} else { Write-Warning "Die .env-Datei '$envFile' wurde nicht gefunden. Es werden keine Werte in den Key Vault übertragen." }
$clientSecretSetting = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
if ($envSecrets.Contains($clientSecretSetting)) { throw "$clientSecretSetting ist für die Entra-Anmeldung reserviert und darf nicht in der .env stehen." }

# --- Werkzeuge prüfen ---------------------------------------------------------------------------
Write-Step 'Werkzeuge prüfen'
if (-not $DryRun -and -not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) fehlt. Installation: https://learn.microsoft.com/cli/azure/install-azure-cli' }
if (-not $InfrastructureOnly -and $buildFrontend -and -not $SkipBuild -and -not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm fehlt. Installiere Node.js oder verwende -SkipBuild mit vorhandenem dist/.' }

# --- Azure-Anmeldung ----------------------------------------------------------------------------
$account = $null
if (-not $DryRun) {
  Write-Step 'Azure-Anmeldung prüfen'
  if (-not (Test-Az account show)) { Write-Note 'Nicht angemeldet, starte az login.'; & az login --only-show-errors | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'az login ist fehlgeschlagen.' } }
  if ($subscription) { Invoke-Az account set --subscription $subscription | Out-Null }
  $account = Invoke-AzJson account show
  $subscription = $account.id
  Write-Note "Subscription: $($account.name) ($($account.id)), Tenant: $($account.tenantId)"
}

# --- Infrastruktur ------------------------------------------------------------------------------
$vaultId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$vaultName"
$appId = "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$appName"

Write-Step "Resource Group '$resourceGroup'"
if ($DryRun) { Write-Note '[DryRun] würde Resource Group prüfen/anlegen' }
elseif ((Invoke-AzTsv group exists --name $resourceGroup) -eq 'true') { Write-Note 'vorhanden' }
else {
  $groupArgs = @('group', 'create', '--name', $resourceGroup, '--location', $location, '--output', 'none')
  if ($tags) { $groupArgs += '--tags'; $groupArgs += @($tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) }
  Invoke-Az @groupArgs | Out-Null; Write-Note 'angelegt'
}

if ([string]::IsNullOrWhiteSpace($planResourceGroup)) { $planResourceGroup = $resourceGroup }
$planSelected = $false
if ($SelectPlan) {
  Write-Step 'Vorhandene App Service Pläne (Linux) auswählen'
  if ($DryRun) { Write-Note '[DryRun] würde die Pläne der Subscription auflisten' }
  else {
    $plans = @(Invoke-AzJson appservice plan list --query "[?reserved].{name:name,resourceGroup:resourceGroup,sku:sku.name,location:location,apps:numberOfSites}")
    if ($plans.Count -eq 0) { Write-Note 'Keine Linux-Pläne gefunden, ein neuer Plan wird angelegt.' }
    else {
      if ([Console]::IsInputRedirected) { throw 'Die Auswahl braucht eine interaktive Eingabe. Setze stattdessen appServicePlan.name, appServicePlan.resourceGroup und appServicePlan.useExisting in der JSON.' }
      $numbered = for ($i = 0; $i -lt $plans.Count; $i++) { [pscustomobject]@{ Nr = $i + 1; Name = $plans[$i].name; ResourceGroup = $plans[$i].resourceGroup; Sku = $plans[$i].sku; Region = $plans[$i].location; Apps = $plans[$i].apps } }
      Write-Host (($numbered | Format-Table -AutoSize | Out-String).TrimEnd())
      $choice = Read-Host "Nummer des Plans (Enter = neuen Plan '$planName' anlegen)"
      if ($choice) {
        if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $plans.Count) { throw "Ungültige Auswahl '$choice'." }
        $picked = $plans[[int]$choice - 1]
        $planName = $picked.name; $planResourceGroup = $picked.resourceGroup; $sku = $picked.sku; $planSelected = $true
      }
    }
  }
}

Write-Step "App Service Plan '$planName' (Linux)"
$planId = "/subscriptions/$subscription/resourceGroups/$planResourceGroup/providers/Microsoft.Web/serverfarms/$planName"
if ($DryRun) { Write-Note "[DryRun] würde Plan in '$planResourceGroup' prüfen und bei Bedarf anlegen ($sku)" }
elseif (Test-Az appservice plan show --name $planName --resource-group $planResourceGroup) {
  $plan = Invoke-AzJson appservice plan show --name $planName --resource-group $planResourceGroup --query "{sku:sku.name,reserved:reserved,location:location,apps:numberOfSites}"
  if (-not $plan.reserved) { throw "Der vorhandene Plan '$planName' ist kein Linux-Plan. Die Web App benötigt einen Linux-Plan (Runtime $runtime)." }
  Write-Note "vorhanden und wird verwendet: $($plan.sku), $($plan.location), $($plan.apps) Apps, Resource Group '$planResourceGroup'"
  if ($plan.sku -ne 'F1') { Write-Warning "Der Plan hat die SKU $($plan.sku) und ist nicht kostenfrei. Die Web App läuft auf diesem Plan und teilt dessen Kosten und Kapazität." }
}
elseif ($useExistingPlan -or $planSelected) { throw "Der Plan '$planName' wurde in Resource Group '$planResourceGroup' nicht gefunden." }
elseif ($planResourceGroup -ne $resourceGroup) { throw "Der Plan '$planName' wurde in Resource Group '$planResourceGroup' nicht gefunden. Neue Pläne werden nur in '$resourceGroup' angelegt." }
else {
  if ($sku -ne 'F1' -and -not $AllowPaidSku) { throw "SKU '$sku' ist nicht kostenfrei. Verwende F1 oder starte mit -AllowPaidSku, wenn Kosten gewollt sind." }
  Invoke-Az appservice plan create --name $planName --resource-group $resourceGroup --location $location --sku $sku --is-linux --output none | Out-Null; Write-Note "angelegt ($sku)"
}

Write-Step "Key Vault '$vaultName' (RBAC)"
if ($DryRun) { Write-Note '[DryRun] würde Key Vault prüfen/anlegen und dem Deployer die Rolle "Key Vault Secrets Officer" geben' }
else {
  if (Test-Az keyvault show --name $vaultName --resource-group $resourceGroup) { Write-Note 'vorhanden' }
  else {
    if (Test-Az keyvault show-deleted --name $vaultName) { Write-Note 'gelöschter Vault mit diesem Namen gefunden, stelle wieder her'; Invoke-Az keyvault recover --name $vaultName --output none | Out-Null }
    else {
      $vaultArgs = @('keyvault', 'create', '--name', $vaultName, '--resource-group', $resourceGroup, '--location', $location, '--sku', $vaultSku, '--enable-rbac-authorization', 'true', '--retention-days', $vaultRetention, '--output', 'none')
      if ($vaultPurge) { $vaultArgs += @('--enable-purge-protection', 'true') }
      Invoke-Az @vaultArgs | Out-Null; Write-Note 'angelegt'
    }
  }
  # Der Deployer braucht Datenebenen-Rechte, um Secrets zu schreiben (Owner/Contributor reichen dafür nicht).
  $deployerId = if ($account.user.type -eq 'servicePrincipal') { Invoke-AzTsv ad sp show --id $account.user.name --query id } else { Invoke-AzTsv ad signed-in-user show --query id }
  $deployerType = if ($account.user.type -eq 'servicePrincipal') { 'ServicePrincipal' } else { 'User' }
  New-RoleAssignmentIfMissing $deployerId $deployerType 'Key Vault Secrets Officer' $vaultId
}

Write-Step "Web App '$appName' ($runtime)"
$hostName = "$appName.azurewebsites.net"
$principalId = ''
if ($DryRun) { Write-Note '[DryRun] würde Web App prüfen/anlegen, Managed Identity aktivieren und konfigurieren' }
else {
  if (Test-Az webapp show --name $appName --resource-group $resourceGroup) { Write-Note 'vorhanden' }
  else { Invoke-Az webapp create --name $appName --resource-group $resourceGroup --plan $planId --runtime $runtime --output none | Out-Null; Write-Note 'angelegt' }
  $hostName = Invoke-AzTsv webapp show --name $appName --resource-group $resourceGroup --query defaultHostName

  Invoke-Az webapp identity assign --name $appName --resource-group $resourceGroup --identities '[system]' --output none | Out-Null
  $principalId = Invoke-AzTsv webapp identity show --name $appName --resource-group $resourceGroup --query principalId
  New-RoleAssignmentIfMissing $principalId 'ServicePrincipal' 'Key Vault Secrets User' $vaultId
  Write-Note "Managed Identity $principalId darf Secrets lesen (Key Vault Secrets User)"

  # Vorhandene Konfiguration bleibt unangetastet; gesetzt wird nur, was fehlt oder sicherer wird (-OverwriteExisting erzwingt die JSON-Werte).
  $current = Invoke-AzJson webapp config show --name $appName --resource-group $resourceGroup --query '{startup:appCommandLine,minTls:minTlsVersion,http2:http20Enabled}'
  $currentHttpsOnly = [bool](Invoke-AzTsv webapp show --name $appName --resource-group $resourceGroup --query httpsOnly | ForEach-Object { $_ -eq 'true' })
  if ($httpsOnly -and -not $currentHttpsOnly) { Invoke-Az webapp update --name $appName --resource-group $resourceGroup --https-only true --output none | Out-Null; Write-Note 'HTTPS-only aktiviert' }
  elseif ($httpsOnly -ne $currentHttpsOnly -and $OverwriteExisting) { Invoke-Az webapp update --name $appName --resource-group $resourceGroup --https-only $httpsOnly.ToString().ToLower() --output none | Out-Null }
  $configArgs = @()
  if ([string]::IsNullOrWhiteSpace($current.startup)) { $configArgs += @('--startup-file', $startup) }
  elseif ($current.startup -ne $startup) {
    if ($OverwriteExisting) { $configArgs += @('--startup-file', $startup) }
    else { Write-Warning "Startbefehl '$($current.startup)' ist bereits gesetzt und bleibt unverändert (JSON: '$startup'). Mit -OverwriteExisting wird er ersetzt. Die App erwartet 'npm start'." }
  }
  $tlsLower = [string]::IsNullOrWhiteSpace($current.minTls) -or ([version]$current.minTls -lt [version]$minTls)
  if ($tlsLower -or ($OverwriteExisting -and $current.minTls -ne $minTls)) { $configArgs += @('--min-tls-version', $minTls) }
  if (-not $current.http2) { $configArgs += @('--http20-enabled', 'true') }
  if ($configArgs.Count -gt 0) { Invoke-Az webapp config set --name $appName --resource-group $resourceGroup @configArgs --output none | Out-Null; Write-Note "Konfiguration ergänzt: $($configArgs | Where-Object { $_ -like '--*' } | ForEach-Object { $_.TrimStart('-') })" }
  else { Write-Note 'Konfiguration bereits vollständig, nichts geändert' }

  for ($i = 0; $i -lt $allowedIps.Count; $i++) {
    $rule = "allow-$($i + 1)"
    $existingIp = Invoke-AzTsv webapp config access-restriction show --name $appName --resource-group $resourceGroup --query "ipSecurityRestrictions[?name=='$rule'].ip_address | [0]"
    if ($existingIp -eq $allowedIps[$i] -or ($existingIp -and $allowedIps[$i] -notmatch '/' -and $existingIp -eq "$($allowedIps[$i])/32")) { continue }
    if ($existingIp) { $null = Test-Az webapp config access-restriction remove --name $appName --resource-group $resourceGroup --rule-name $rule }
    Invoke-Az webapp config access-restriction add --name $appName --resource-group $resourceGroup --rule-name $rule --action Allow --ip-address $allowedIps[$i] --priority (100 + $i) --output none | Out-Null
  }
  if ($allowedIps.Count -gt 0) { Write-Note "Zugriff beschränkt auf: $($allowedIps -join ', ')" }
}

# --- Secrets aus der .env in den Key Vault ------------------------------------------------------
Write-Step "Secrets in Key Vault '$vaultName' übertragen"
$keyVaultReference = { param($secretName) "@Microsoft.KeyVault(VaultName=$vaultName;SecretName=$secretName)" }
$appSettings = [ordered]@{ SCM_DO_BUILD_DURING_DEPLOYMENT = 'true' }
$managedSettingNames = @('SCM_DO_BUILD_DURING_DEPLOYMENT')   # werden immer gesetzt; alle anderen nur, wenn sie noch fehlen
if ($plainSettings) { $plainSettingNames = @($plainSettings.PSObject.Properties.Name) } else { $plainSettingNames = @() }
if ($plainSettings) { foreach ($property in $plainSettings.PSObject.Properties) { $appSettings[$property.Name] = [string]$property.Value } }
$envTagSource = 'managed-by=policy-studio-env'
foreach ($entry in $envSecrets.GetEnumerator()) {
  $secretName = $entry.Value.SecretName
  $secretTags = @($envTagSource, "env-name=$($entry.Key)")
  if ($DryRun) { Write-Note "[DryRun] $($entry.Key) -> Secret '$secretName'" }
  else {
    # Die .env ist die Quelle der Wahrheit: geänderte Werte werden aktualisiert, gleiche bleiben unberührt.
    $current = Get-KeyVaultSecret $vaultName $secretName
    if ($null -eq $current) { Set-KeyVaultSecretValue $vaultName $secretName $entry.Value.Value $secretTags; Write-Note "$($entry.Key) -> '$secretName' (neu geschrieben)" }
    elseif ($current.value -cne $entry.Value.Value) { Set-KeyVaultSecretValue $vaultName $secretName $entry.Value.Value $secretTags; Write-Note "$($entry.Key) -> '$secretName' (Wert geändert, aktualisiert)" }
    else {
      Write-Note "$($entry.Key) -> '$secretName' (unverändert)"
      $tagName = if ($current.tags) { $current.tags.PSObject.Properties['env-name'] } else { $null }
      if (-not $tagName) { Invoke-Az keyvault secret set-attributes --vault-name $vaultName --name $secretName --tags @secretTags --output none | Out-Null }
    }
  }
  $appSettings[$entry.Key] = & $keyVaultReference $secretName
  $managedSettingNames += $entry.Key
}

# Schlüssel, die aus der .env entfernt wurden, werden auch aus dem Key Vault und den App Settings entfernt.
# Nur Secrets mit dem Tag des Skripts sind betroffen. Gelöschte Secrets bleiben per Soft Delete wiederherstellbar.
if (-not $DryRun -and -not $NoPrune) {
  if (-not $envFileFound) { Write-Note 'Keine .env gefunden, es wird nichts gelöscht.' }
  elseif ($envSecrets.Count -eq 0) { Write-Warning 'Die .env enthält keine Werte. Aus Sicherheitsgründen wird nichts gelöscht (-NoPrune ist nicht nötig).' }
  else {
    $managed = @(Invoke-AzJson keyvault secret list --vault-name $vaultName --query '[?tags."managed-by"==''policy-studio-env''].{name:name,env:tags."env-name"}')
    $keep = @($envSecrets.Values | ForEach-Object { $_.SecretName })
    $stale = @($managed | Where-Object { $_.name -notin $keep })
    if ($stale.Count -gt 0) {
      $liveSettings = @{}
      foreach ($item in @(Invoke-AzJson webapp config appsettings list --name $appName --resource-group $resourceGroup)) { $liveSettings[$item.name] = $item.value }
      foreach ($item in $stale) {
        Invoke-Az keyvault secret delete --vault-name $vaultName --name $item.name --output none | Out-Null
        $settingName = if ($item.env) { $item.env } else { $item.name.ToUpperInvariant().Replace('-', '_') }
        $reference = $liveSettings[$settingName]
        if ($reference -and $reference -like "@Microsoft.KeyVault(VaultName=$vaultName;SecretName=$($item.name))") {
          Invoke-Az webapp config appsettings delete --name $appName --resource-group $resourceGroup --setting-names $settingName --output none | Out-Null
          Write-Note "$settingName entfernt (nicht mehr in der .env): Secret '$($item.name)' gelöscht, App Setting entfernt"
        } else { Write-Note "Secret '$($item.name)' gelöscht (nicht mehr in der .env)" }
      }
    } else { Write-Note 'Keine veralteten Secrets' }
  }
}

# --- Entra-ID-Anmeldung -------------------------------------------------------------------------
$entraClientId = ''
if ($entraEnabled) {
  Write-Step "Entra-App-Registrierung '$entraName'"
  if ($DryRun) { Write-Note '[DryRun] würde App-Registrierung, Service Principal, Client-Secret und Benutzerzuweisungen anlegen' }
  else {
    $redirectUris = @(@("https://$hostName/.auth/login/aad/callback") + $entraRedirects | Select-Object -Unique)
    $filter = $entraName.Replace("'", "''")
    $found = @(Invoke-AzJson ad app list --display-name $entraName --query "[?displayName=='$filter'].{id:id,appId:appId}")
    if ($found.Count -gt 1) { throw "Mehrere App-Registrierungen heißen '$entraName'. Benenne sie eindeutig oder lösche Duplikate." }
    $graphAppId = '00000003-0000-0000-c000-000000000000'; $userReadId = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'   # Microsoft Graph, delegiert User.Read
    $createdNow = $false
    if ($found.Count -eq 0) {
      $created = Invoke-AzJson ad app create --display-name $entraName --sign-in-audience $entraAudience --web-redirect-uris @redirectUris --enable-id-token-issuance true
      $entraClientId = $created.appId; $createdNow = $true; Write-Note "angelegt: $entraClientId"
    } else { $entraClientId = $found[0].appId; Write-Note "vorhanden: $entraClientId" }

    # Vorhandene Registrierungen werden nur ergänzt, nie überschrieben: eigene Redirect-URIs bleiben erhalten.
    $app = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
      try { $app = Invoke-AzJson ad app show --id $entraClientId --query '{redirects:web.redirectUris,idToken:web.implicitGrantSettings.enableIdTokenIssuance,audience:signInAudience,access:requiredResourceAccess}'; break }
      catch { if ($attempt -eq 6) { throw }; Start-Sleep -Seconds 5 }
    }
    $updateArgs = @()
    $currentRedirects = @($app.redirects | Where-Object { $_ })
    $missingRedirects = @($redirectUris | Where-Object { $_ -notin $currentRedirects })
    if ($missingRedirects.Count -gt 0) { $updateArgs += @('--web-redirect-uris') + @($currentRedirects + $missingRedirects); Write-Note "Redirect-URI ergänzt: $($missingRedirects -join ', ')" }
    if (-not $app.idToken) { $updateArgs += @('--enable-id-token-issuance', 'true') }
    if ($app.audience -ne $entraAudience) {
      if ($OverwriteExisting) { $updateArgs += @('--sign-in-audience', $entraAudience) }
      else { Write-Warning "signInAudience ist '$($app.audience)' (JSON: '$entraAudience') und bleibt unverändert. Mit -OverwriteExisting wird er ersetzt." }
    }
    # Graph-Berechtigung User.Read ergänzen (Profilbild); vorhandene Berechtigungen bleiben erhalten.
    $access = @($app.access | Where-Object { $_ })
    $graphEntry = $access | Where-Object { $_.resourceAppId -eq $graphAppId } | Select-Object -First 1
    $hasUserRead = $graphEntry -and @($graphEntry.resourceAccess | Where-Object { $_.id -eq $userReadId }).Count -gt 0
    $accessJson = $null
    if (-not $hasUserRead) {
      $merged = @($access | Where-Object { $_.resourceAppId -ne $graphAppId })
      $graphAccess = @(); if ($graphEntry) { $graphAccess = @($graphEntry.resourceAccess) }
      $graphAccess += [pscustomobject]@{ id = $userReadId; type = 'Scope' }
      $merged += [pscustomobject]@{ resourceAppId = $graphAppId; resourceAccess = $graphAccess }
      $accessJson = ConvertTo-Json -InputObject @($merged) -Depth 6
      Write-Note 'Berechtigung Microsoft Graph User.Read ergänzt'
    }
    $applyUpdate = { param($accessFile)
      $all = @($updateArgs); if ($accessFile) { $all += @('--required-resource-accesses', "@$accessFile") }
      if ($all.Count -gt 0) { Invoke-Az ad app update --id $entraClientId @all --output none | Out-Null }
    }
    if ($accessJson) { Use-TempFile $accessJson { param($file) & $applyUpdate $file } } else { & $applyUpdate $null }
    if ($updateArgs.Count -eq 0 -and -not $accessJson) { Write-Note 'Registrierung bereits vollständig, nichts geändert' }

    if (-not (Test-Az ad sp show --id $entraClientId)) { Invoke-Az ad sp create --id $entraClientId --output none | Out-Null; Write-Note 'Service Principal angelegt' }
    $servicePrincipalId = Invoke-AzTsv ad sp show --id $entraClientId --query id
    $assignmentCurrentlyRequired = (Invoke-AzTsv ad sp show --id $entraClientId --query appRoleAssignmentRequired) -eq 'true'
    if ($entraAssignmentRequired -and -not $assignmentCurrentlyRequired) { Invoke-Az ad sp update --id $servicePrincipalId --set 'appRoleAssignmentRequired=true' --output none | Out-Null; Write-Note 'Zuweisung erforderlich: aktiviert' }
    elseif (-not $entraAssignmentRequired -and $assignmentCurrentlyRequired) {
      if ($OverwriteExisting) { Invoke-Az ad sp update --id $servicePrincipalId --set 'appRoleAssignmentRequired=false' --output none | Out-Null; Write-Note 'Zuweisung erforderlich: deaktiviert' }
      else { Write-Warning 'Für die Anwendung ist "Zuweisung erforderlich" bereits aktiv und bleibt es (JSON: false). Mit -OverwriteExisting wird sie deaktiviert.' }
    } else { Write-Note "Zuweisung erforderlich: $assignmentCurrentlyRequired (unverändert)" }

    # Administrator-Zustimmung für User.Read versuchen; ohne passende Rolle stimmen Benutzer beim ersten Login selbst zu.
    if ($accessJson) {
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { if ($createdNow) { Start-Sleep -Seconds 10 }; Invoke-Az ad app permission admin-consent --id $entraClientId --output none | Out-Null; Write-Note 'Administrator-Zustimmung erteilt'; break }
        catch { if ($attempt -eq 3) { Write-Note 'Administrator-Zustimmung nicht möglich (fehlende Rolle). Benutzer stimmen beim ersten Login einmalig zu.' } else { Start-Sleep -Seconds 10 } }
      }
    }

    # Benutzer und Gruppen zuweisen (Standard-Rolle), nur wenn noch nicht vorhanden.
    $assignmentsUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$servicePrincipalId/appRoleAssignedTo"
    $existing = @((Invoke-AzJson rest --method get --url $assignmentsUrl).value | ForEach-Object { $_.principalId })
    $principals = @($entraUsers | ForEach-Object { @{ Kind = 'Benutzer'; Name = $_; Id = (Invoke-AzTsv ad user show --id $_ --query id) } }) +
                  @($entraGroups | ForEach-Object { @{ Kind = 'Gruppe'; Name = $_; Id = (Invoke-AzTsv ad group show --group $_ --query id) } })
    foreach ($principal in $principals) {
      if ($existing -contains $principal.Id) { Write-Note "$($principal.Kind) '$($principal.Name)' bereits zugewiesen"; continue }
      $body = @{ principalId = $principal.Id; resourceId = $servicePrincipalId; appRoleId = '00000000-0000-0000-0000-000000000000' } | ConvertTo-Json -Compress
      Use-TempFile $body { param($file) Invoke-Az rest --method post --url $assignmentsUrl --headers 'Content-Type=application/json' --body "@$file" --output none | Out-Null }
      Write-Note "$($principal.Kind) '$($principal.Name)' zugewiesen"
    }
    if ($entraAssignmentRequired -and $principals.Count -eq 0) { Write-Warning 'assignmentRequired ist aktiv, aber assignedUsers und assignedGroups sind leer. Niemand außer Administratoren kann sich anmelden.' }

    # Client-Secret: nur erzeugen, wenn es im Key Vault fehlt (oder -RotateClientSecret), und nie ausgeben.
    $haveSecret = $null -ne (Get-KeyVaultSecret $vaultName $entraSecretName)
    if ($haveSecret -and -not $RotateClientSecret) { Write-Note "Client-Secret '$entraSecretName' im Key Vault vorhanden" }
    else {
      $password = Invoke-AzTsv ad app credential reset --id $entraClientId --append --display-name "key-vault-$((Get-Date).ToString('yyyyMMdd'))" --years $entraSecretYears --query password
      Set-KeyVaultSecretValue $vaultName $entraSecretName $password @('managed-by=policy-studio-entra')
      $password = $null
      Write-Note "Neues Client-Secret im Key Vault als '$entraSecretName' abgelegt"
    }
    $appSettings[$clientSecretSetting] = & $keyVaultReference $entraSecretName
  }
}

# --- App Settings setzen ------------------------------------------------------------------------
if (-not $DryRun) {
  Write-Step 'App Settings setzen (Secrets nur als Key-Vault-Referenzen)'
  # Vorhandene Werte bleiben unverändert. Immer abgeglichen werden nur die vom Skript verwalteten Einträge
  # (Key-Vault-Referenzen aus der .env, Entra-Secret, Build-Schalter); eigene Einträge aus der JSON nur bei -OverwriteExisting.
  $liveSettings = @{}
  foreach ($item in @(Invoke-AzJson webapp config appsettings list --name $appName --resource-group $resourceGroup)) { $liveSettings[$item.name] = $item.value }
  $toSet = [ordered]@{}; $kept = @()
  foreach ($entry in $appSettings.GetEnumerator()) {
    $managed = $entry.Key -in $managedSettingNames -or $entry.Key -eq $clientSecretSetting
    if ($liveSettings.ContainsKey($entry.Key) -and $liveSettings[$entry.Key] -ceq $entry.Value) { continue }
    if ($liveSettings.ContainsKey($entry.Key) -and -not $managed -and -not $OverwriteExisting) { $kept += $entry.Key; continue }
    $toSet[$entry.Key] = $entry.Value
  }
  if ($toSet.Count -gt 0) {
    $settingsJson = @($toSet.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value; slotSetting = $false } }) | ConvertTo-Json -AsArray
    Use-TempFile $settingsJson { param($file) Invoke-Az webapp config appsettings set --name $appName --resource-group $resourceGroup --settings "@$file" --output none | Out-Null }
    Write-Note "gesetzt: $($toSet.Keys -join ', ')"
  } else { Write-Note 'App Settings sind bereits aktuell' }
  if ($kept.Count -gt 0) { Write-Note "bereits gesetzt, nicht überschrieben: $($kept -join ', ') (mit -OverwriteExisting ersetzen)" }

  if ($entraEnabled) {
    Write-Step 'App Service Authentication (Entra ID) konfigurieren'
    $tenantId = $account.tenantId
    $authUrl = "https://management.azure.com$appId/config/authsettingsV2?api-version=2022-03-01"
    $liveAuth = ((Invoke-Az rest --method get --url $authUrl --output json) -join '') | ConvertFrom-Json -AsHashtable
    $properties = if ($liveAuth -and $liveAuth.properties) { $liveAuth.properties } else { @{} }
    function Get-Node([hashtable]$Parent, [string]$Key) { if ($Parent[$Key] -isnot [hashtable]) { $Parent[$Key] = @{} }; return $Parent[$Key] }

    $providers = Get-Node (Get-Node $properties 'identityProviders') 'azureActiveDirectory'
    $registration = Get-Node $providers 'registration'
    $foreignClient = $registration['clientId'] -and $registration['clientId'] -ne $entraClientId
    if ($foreignClient -and -not $OverwriteExisting) {
      Write-Warning "An der Web App ist bereits eine andere Entra-Anmeldung konfiguriert (Client $($registration['clientId'])). Sie bleibt unverändert. Mit -OverwriteExisting wird sie durch '$entraName' ersetzt."
      $authChanged = $false
    } else {
      # Bestehende Auth-Konfiguration wird zusammengeführt, nicht ersetzt: nur die benötigten Felder werden gesetzt.
      $platform = Get-Node $properties 'platform'; $platform['enabled'] = $true; if (-not $platform['runtimeVersion']) { $platform['runtimeVersion'] = '~1' }
      $validation = Get-Node $properties 'globalValidation'
      $validation['requireAuthentication'] = $true
      if (-not $validation['unauthenticatedClientAction'] -or $OverwriteExisting) { $validation['unauthenticatedClientAction'] = 'RedirectToLoginPage' }
      if (-not $validation['redirectToProvider'] -or $OverwriteExisting) { $validation['redirectToProvider'] = 'azureactivedirectory' }
      $validation['excludedPaths'] = @(@($validation['excludedPaths']) + $entraExcluded | Where-Object { $_ } | Select-Object -Unique)
      $registration['openIdIssuer'] = "https://login.microsoftonline.com/$tenantId/v2.0"
      $registration['clientId'] = $entraClientId
      $registration['clientSecretSettingName'] = $clientSecretSetting
      $providers['enabled'] = $true
      # Token Store und Scope User.Read werden für Anzeige von Benutzer und Profilbild benötigt.
      (Get-Node (Get-Node $properties 'login') 'tokenStore')['enabled'] = $true
      $login = Get-Node $providers 'login'
      $loginParameters = @($login['loginParameters'] | Where-Object { $_ })
      if (-not ($loginParameters | Where-Object { $_ -like 'scope=*' })) { $loginParameters += 'scope=openid profile email offline_access User.Read' }
      $login['loginParameters'] = $loginParameters
      (Get-Node $properties 'httpSettings')['requireHttps'] = $true
      $authChanged = $true
      Use-TempFile (@{ properties = $properties } | ConvertTo-Json -Depth 12) { param($file) Invoke-Az rest --method put --url $authUrl --headers 'Content-Type=application/json' --body "@$file" --output none | Out-Null }
    }
    if ($authChanged) { Write-Note "Anmeldung aktiv, ausgenommen: $($entraExcluded -join ', ')" }
  }
}

if ($InfrastructureOnly) { Write-Step 'Fertig (nur Infrastruktur).'; return }

# --- Build und Paket ----------------------------------------------------------------------------
if ($buildFrontend -and -not $SkipBuild) {
  Write-Step 'Frontend bauen'
  Push-Location $repoRoot
  try {
    if (-not (Test-Path 'node_modules')) { & npm ci; if ($LASTEXITCODE -ne 0) { throw 'npm ci ist fehlgeschlagen.' } }
    & npm run build; if ($LASTEXITCODE -ne 0) { throw 'npm run build ist fehlgeschlagen.' }
  } finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $repoRoot 'dist/index.html'))) { throw 'dist/index.html fehlt. Baue das Frontend (npm run build) oder aktiviere deployment.buildFrontend.' }

Write-Step 'Deployment-Paket erstellen'
$stage = Join-Path ([IO.Path]::GetTempPath()) "policy-studio-$([guid]::NewGuid())"
$zipPath = "$stage.zip"
try {
  New-Item -ItemType Directory -Path $stage | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot 'dist') -Destination (Join-Path $stage 'dist') -Recurse
  Copy-Item -LiteralPath (Join-Path $repoRoot 'server') -Destination (Join-Path $stage 'server') -Recurse
  $stageSrc = New-Item -ItemType Directory -Path (Join-Path $stage 'src')
  foreach ($file in 'types.ts', 'analysisProfile.ts') { Copy-Item -LiteralPath (Join-Path $repoRoot "src/$file") -Destination $stageSrc }

  # Schlankes package.json mit den Laufzeit-Abhängigkeiten des Servers; .env wird bewusst nie mitgeliefert.
  $rootPackage = Get-Content -LiteralPath (Join-Path $repoRoot 'package.json') -Raw | ConvertFrom-Json
  $runtimePackage = [ordered]@{
    name = $rootPackage.name; version = $rootPackage.version; private = $true; type = 'module'
    scripts = [ordered]@{ start = 'tsx server/index.ts' }
    dependencies = [ordered]@{ express = $rootPackage.dependencies.express; dotenv = $rootPackage.dependencies.dotenv; tsx = $rootPackage.devDependencies.tsx }
  }
  $runtimePackage | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'package.json') -Encoding utf8

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
  Write-Note ("{0} ({1:N1} MB)" -f $zipPath, ((Get-Item -LiteralPath $zipPath).Length / 1MB))

  if ($DryRun) { Write-Step '[DryRun] Paket erstellt, Deployment übersprungen.'; return }

  # --- Deployment -------------------------------------------------------------------------------
  Write-Step 'Deployment hochladen (Azure baut die Abhängigkeiten, das kann einige Minuten dauern)'
  Invoke-Az webapp deploy --name $appName --resource-group $resourceGroup --src-path $zipPath --type zip --clean true --output none | Out-Null

  # Key-Vault-Referenzen prüfen (best effort): nicht aufgelöste Referenzen deuten auf fehlende Rechte hin.
  Write-Step 'Key-Vault-Referenzen prüfen'
  $referencesUrl = "https://management.azure.com$appId/config/configreferences/appsettings?api-version=2022-03-01"
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
      $references = @((Invoke-AzJson rest --method get --url $referencesUrl).value)
      $unresolved = @($references | Where-Object { $_.properties.status -and $_.properties.status -ne 'Resolved' })
      if ($unresolved.Count -eq 0) { Write-Note "$($references.Count) Referenzen aufgelöst"; break }
      Write-Note "Nicht aufgelöst: $(($unresolved | ForEach-Object { $_.name }) -join ', ')"
      if ($attempt -lt 4) { Invoke-Az webapp restart --name $appName --resource-group $resourceGroup | Out-Null; Start-Sleep -Seconds 30 }
      else { Write-Warning 'Einige Key-Vault-Referenzen sind nicht aufgelöst. Prüfe die Rolle "Key Vault Secrets User" der Managed Identity und die Secret-Namen.' }
    } catch { Write-Note "Referenzstatus nicht abrufbar ($($_.Exception.Message.Split([Environment]::NewLine)[0]))"; break }
  }

  $url = "https://$hostName"
  Write-Step "Health-Check $url$healthPath"
  $deadline = (Get-Date).AddSeconds($healthTimeout)
  $healthy = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri "$url$healthPath" -TimeoutSec 20 -SkipHttpErrorCheck
      if ($response.StatusCode -eq 200) { $healthy = $true; break }
      Write-Note "HTTP $($response.StatusCode), warte…"
    } catch { Write-Note 'noch nicht erreichbar, warte…' }
    Start-Sleep -Seconds 10
  }
  if (-not $healthy) { throw "Die Web App antwortet nach $healthTimeout s nicht mit HTTP 200. Logs: az webapp log tail --name $appName --resource-group $resourceGroup" }
  Write-Host "Fertig: $url" -ForegroundColor Green
  if ($entraEnabled) { Write-Host 'Der Aufruf leitet auf die Microsoft-Anmeldung um.' -ForegroundColor Green }
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
}
