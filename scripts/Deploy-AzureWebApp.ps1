#Requires -Version 7.0
<#
.SYNOPSIS
  Legt eine Azure Web App im Free Tier (F1) an, falls sie fehlt, und deployt Policy Studio dorthin.

.DESCRIPTION
  Liest die Infrastruktur aus einer JSON-Datei (Vorlage: infrastructure.json.example), erzeugt
  Resource Group, App Service Plan und Web App nur bei Bedarf, setzt Konfiguration und App Settings
  und lädt ein Zip-Paket (Frontend-Build + Server) hoch. Läuft unter Windows, macOS und Linux mit
  PowerShell 7 und Azure CLI. Das Skript ist idempotent und kann beliebig oft wiederholt werden.

.PARAMETER ConfigPath
  Pfad zur JSON-Konfiguration. Standard: infrastructure.json neben diesem Skript.

.PARAMETER SkipBuild
  Vorhandenes dist/ verwenden, nicht neu bauen.

.PARAMETER InfrastructureOnly
  Nur Azure-Ressourcen anlegen/aktualisieren, nichts deployen.

.PARAMETER DryRun
  Konfiguration prüfen, Paket lokal bauen, aber keine Azure-Aufrufe ausführen.

.PARAMETER AllowPaidSku
  Erlaubt andere SKUs als F1. Ohne diesen Schalter bricht das Skript bei einem kostenpflichtigen Plan ab.

.EXAMPLE
  ./scripts/Deploy-AzureWebApp.ps1 -ConfigPath ./scripts/infrastructure.json
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'infrastructure.json'),
  [switch]$SkipBuild,
  [switch]$InfrastructureOnly,
  [switch]$DryRun,
  [switch]$AllowPaidSku
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" -ForegroundColor DarkGray }

# Führt az aus, wirft bei Fehlern und liefert die Ausgabe zeilenweise zurück.
function Invoke-Az {
  param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
  $output = & az @Arguments --only-show-errors 2>&1
  if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..1] -join ' ') ist fehlgeschlagen: $($output -join [Environment]::NewLine)" }
  return $output
}

# Wie Invoke-Az, liefert aber $false bei Exit-Code != 0 statt zu werfen (für Existenzprüfungen).
function Test-Az {
  param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
  $null = & az @Arguments --only-show-errors 2>&1
  return $LASTEXITCODE -eq 0
}

function Get-Setting($Object, [string]$Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) { return $Object.$Name }
  return $Default
}

# --- Konfiguration lesen und prüfen -------------------------------------------------------------
Write-Step "Konfiguration lesen: $ConfigPath"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Konfiguration nicht gefunden. Kopiere scripts/infrastructure.json.example nach scripts/infrastructure.json und passe sie an."
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$resourceGroup = Get-Setting $config 'resourceGroup'
$location      = Get-Setting $config 'location'
$planName      = Get-Setting (Get-Setting $config 'appServicePlan') 'name'
$sku           = Get-Setting (Get-Setting $config 'appServicePlan') 'sku' 'F1'
$web           = Get-Setting $config 'webApp'
$appName       = Get-Setting $web 'name'
$runtime       = Get-Setting $web 'runtime' 'NODE:22-lts'
$startup       = Get-Setting $web 'startupCommand' 'npm start'
$httpsOnly     = [bool](Get-Setting $web 'httpsOnly' $true)
$minTls        = Get-Setting $web 'minTlsVersion' '1.2'
$subscription  = Get-Setting $config 'subscriptionId' ''
$tags          = Get-Setting $config 'tags'
$settings      = Get-Setting $config 'appSettings'
$fromEnvironment = @(Get-Setting $config 'appSettingsFromEnvironment' @())
$allowedIps    = @(Get-Setting $config 'allowedIpRanges' @())
$deployment    = Get-Setting $config 'deployment'
$buildFrontend = [bool](Get-Setting $deployment 'buildFrontend' $true)
$healthPath    = Get-Setting $deployment 'healthCheckPath' '/api/health'
$healthTimeout = [int](Get-Setting $deployment 'healthCheckTimeoutSeconds' 300)

$missing = @(@{n='resourceGroup';v=$resourceGroup},@{n='location';v=$location},@{n='appServicePlan.name';v=$planName},@{n='webApp.name';v=$appName}) | Where-Object { [string]::IsNullOrWhiteSpace($_.v) } | ForEach-Object { $_.n }
if ($missing) { throw "Pflichtfelder fehlen in der Konfiguration: $($missing -join ', ')" }
if ($appName -match 'CHANGE-ME') { throw "webApp.name enthält noch den Platzhalter CHANGE-ME. Der Name muss weltweit eindeutig sein." }
if ($appName -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,58}[a-zA-Z0-9])?$') { throw "webApp.name '$appName' ist ungültig (2-60 Zeichen, Buchstaben, Ziffern, Bindestrich)." }
if ($sku -ne 'F1' -and -not $AllowPaidSku) { throw "SKU '$sku' ist nicht kostenfrei. Verwende F1 oder starte mit -AllowPaidSku, wenn Kosten gewollt sind." }

# App Settings: feste Werte plus Werte aus lokalen Umgebungsvariablen (Geheimnisse bleiben aus der JSON-Datei).
$appSettings = [ordered]@{ SCM_DO_BUILD_DURING_DEPLOYMENT = 'true' }
if ($settings) { foreach ($property in $settings.PSObject.Properties) { $appSettings[$property.Name] = [string]$property.Value } }
$secretNames = @()
foreach ($name in $fromEnvironment) {
  $value = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrEmpty($value)) { Write-Warning "Umgebungsvariable '$name' ist lokal nicht gesetzt und wird übersprungen."; continue }
  $appSettings[$name] = $value
  $secretNames += $name
}
if ($secretNames.Count -gt 0 -and $allowedIps.Count -eq 0) {
  Write-Warning "Die Web App erhält Server-Zugangsdaten ($($secretNames -join ', ')) und hat keine IP-Beschränkung. Jeder mit der URL könnte die KI-Endpunkte auf Ihre Kosten nutzen. Setze allowedIpRanges oder lasse die Schlüssel weg und trage sie im Browser ein."
}

# --- Werkzeuge prüfen ---------------------------------------------------------------------------
Write-Step 'Werkzeuge prüfen'
if (-not $DryRun -and -not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) fehlt. Installation: https://learn.microsoft.com/cli/azure/install-azure-cli' }
if (-not $InfrastructureOnly -and $buildFrontend -and -not $SkipBuild -and -not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm fehlt. Installiere Node.js oder verwende -SkipBuild mit vorhandenem dist/.' }

# --- Azure-Anmeldung ----------------------------------------------------------------------------
if (-not $DryRun) {
  Write-Step 'Azure-Anmeldung prüfen'
  if (-not (Test-Az account show)) { Write-Note 'Nicht angemeldet, starte az login.'; & az login --only-show-errors | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'az login ist fehlgeschlagen.' } }
  if ($subscription) { Invoke-Az account set --subscription $subscription | Out-Null }
  $account = (Invoke-Az account show --output json) -join '' | ConvertFrom-Json
  Write-Note "Subscription: $($account.name) ($($account.id))"
}

# --- Infrastruktur ------------------------------------------------------------------------------
Write-Step "Resource Group '$resourceGroup'"
if ($DryRun) { Write-Note '[DryRun] würde Resource Group prüfen/anlegen' }
elseif ((Invoke-Az group exists --name $resourceGroup) -join '' -eq 'true') { Write-Note 'vorhanden' }
else {
  $groupArgs = @('group','create','--name',$resourceGroup,'--location',$location,'--output','none')
  if ($tags) { $groupArgs += '--tags'; $groupArgs += @($tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) }
  Invoke-Az @groupArgs | Out-Null; Write-Note 'angelegt'
}

Write-Step "App Service Plan '$planName' ($sku, Linux)"
if ($DryRun) { Write-Note '[DryRun] würde Plan prüfen/anlegen' }
elseif (Test-Az appservice plan show --name $planName --resource-group $resourceGroup) { Write-Note 'vorhanden' }
else { Invoke-Az appservice plan create --name $planName --resource-group $resourceGroup --location $location --sku $sku --is-linux --output none | Out-Null; Write-Note 'angelegt' }

Write-Step "Web App '$appName' ($runtime)"
if ($DryRun) { Write-Note '[DryRun] würde Web App prüfen/anlegen und konfigurieren' }
else {
  if (Test-Az webapp show --name $appName --resource-group $resourceGroup) { Write-Note 'vorhanden' }
  else { Invoke-Az webapp create --name $appName --resource-group $resourceGroup --plan $planName --runtime $runtime --output none | Out-Null; Write-Note 'angelegt' }

  Invoke-Az webapp update --name $appName --resource-group $resourceGroup --https-only $httpsOnly.ToString().ToLower() --output none | Out-Null
  Invoke-Az webapp config set --name $appName --resource-group $resourceGroup --startup-file $startup --min-tls-version $minTls --http20-enabled true --output none | Out-Null

  # App Settings über eine temporäre Datei setzen, damit Werte nicht in der Prozessliste auftauchen.
  $settingsFile = Join-Path ([IO.Path]::GetTempPath()) "appsettings-$([guid]::NewGuid()).json"
  try {
    $appSettings | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8
    Invoke-Az webapp config appsettings set --name $appName --resource-group $resourceGroup --settings "@$settingsFile" --output none | Out-Null
  } finally { Remove-Item -LiteralPath $settingsFile -Force -ErrorAction SilentlyContinue }
  Write-Note "App Settings gesetzt: $($appSettings.Keys -join ', ')"

  for ($i = 0; $i -lt $allowedIps.Count; $i++) {
    $rule = "allow-$($i + 1)"
    $null = Test-Az webapp config access-restriction remove --name $appName --resource-group $resourceGroup --rule-name $rule
    Invoke-Az webapp config access-restriction add --name $appName --resource-group $resourceGroup --rule-name $rule --action Allow --ip-address $allowedIps[$i] --priority (100 + $i) --output none | Out-Null
  }
  if ($allowedIps.Count -gt 0) { Write-Note "Zugriff beschränkt auf: $($allowedIps -join ', ')" }
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
    dependencies = [ordered]@{
      express = $rootPackage.dependencies.express
      dotenv  = $rootPackage.dependencies.dotenv
      tsx     = $rootPackage.devDependencies.tsx
    }
  }
  $runtimePackage | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'package.json') -Encoding utf8

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
  Write-Note ("{0} ({1:N1} MB)" -f $zipPath, ((Get-Item -LiteralPath $zipPath).Length / 1MB))

  if ($DryRun) { Write-Step '[DryRun] Paket erstellt, Deployment übersprungen.'; return }

  # --- Deployment -------------------------------------------------------------------------------
  Write-Step 'Deployment hochladen (Azure baut die Abhängigkeiten, das kann einige Minuten dauern)'
  Invoke-Az webapp deploy --name $appName --resource-group $resourceGroup --src-path $zipPath --type zip --clean true --output none | Out-Null

  $hostName = ((Invoke-Az webapp show --name $appName --resource-group $resourceGroup --query defaultHostName --output tsv) -join '').Trim()
  $url = "https://$hostName"
  Write-Step "Health-Check $url$healthPath"
  $deadline = (Get-Date).AddSeconds($healthTimeout)
  $healthy = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri "$url$healthPath" -TimeoutSec 20 -SkipHttpErrorCheck
      if ($response.StatusCode -eq 200) { $healthy = $true; break }
      Write-Note "HTTP $($response.StatusCode), warte…"
    } catch { Write-Note "noch nicht erreichbar, warte…" }
    Start-Sleep -Seconds 10
  }
  if (-not $healthy) { throw "Die Web App antwortet nach $healthTimeout s nicht mit HTTP 200. Logs: az webapp log tail --name $appName --resource-group $resourceGroup" }
  Write-Host "Fertig: $url" -ForegroundColor Green
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
}
