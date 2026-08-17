param(
    [ValidateSet("bootstrap", "up", "down", "recreate", "verify", "logs", "status")]
    [string]$Action = "up",
    [switch]$SkipLegacyDependencies
)

$ErrorActionPreference = "Stop"
$dockerRepository = Split-Path -Parent $MyInvocation.MyCommand.Path
$workspace = Split-Path -Parent $dockerRepository
$standardDirectory = Join-Path $dockerRepository "bahmni-standard"
$baseCompose = Join-Path $standardDirectory "docker-compose.yml"
$devCompose = Join-Path $standardDirectory "docker-compose.next-dev.yml"
$environmentFile = Join-Path $standardDirectory ".env"
$composeProjectName = "bahmni-hcsba-dev"

$repositories = @(
    @{ Name = "bahmni-nextjs-hcsba"; Url = "https://github.com/HCSBA-bahmni/bahmni-nextjs-hcsba.git"; Branch = "main" },
    @{ Name = "standard-config-HCSBA"; Url = "https://github.com/HCSBA-bahmni/standard-config-HCSBA.git"; Branch = "master" },
    @{ Name = "openmrs-module-bahmniapps-hcsba-2024"; Url = "https://github.com/HCSBA-bahmni/openmrs-module-bahmniapps-hcsba-2024.git"; Branch = "master" },
    @{ Name = "openmrs-module-ipd-frontend-hcsba-2024"; Url = "https://github.com/HCSBA-bahmni/openmrs-module-ipd-frontend-hcsba-2024.git"; Branch = "main" },
    @{ Name = "openmrs-module-ipd"; Url = "https://github.com/HCSBA-bahmni/openmrs-module-ipd.git"; Branch = "hcsba/1.1.1-fix-ward-patients" }
)

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontro '$Name' en PATH."
    }
}

function Set-DotEnvValue {
    param([string]$Path, [string]$Name, [string]$Value)

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $Path) {
        [System.IO.File]::ReadAllLines($Path) | ForEach-Object { $lines.Add($_) }
    }
    $prefix = "$Name="
    $index = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $index = $i
            break
        }
    }
    if ($index -ge 0) {
        $lines[$index] = "$prefix$Value"
    } else {
        $lines.Add("$prefix$Value")
    }
    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Convert-ToComposePath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).Replace("\", "/")
}

function Initialize-Workspace {
    Assert-Command "git"
    Assert-Command "docker"

    foreach ($repository in $repositories) {
        $destination = Join-Path $workspace $repository.Name
        if (Test-Path (Join-Path $destination ".git")) {
            Write-Host "Repositorio presente: $($repository.Name)" -ForegroundColor DarkGray
            continue
        }
        if (Test-Path $destination) {
            throw "La ruta $destination existe pero no es un repositorio Git."
        }
        & git clone --branch $repository.Branch $repository.Url $destination
        if ($LASTEXITCODE -ne 0) {
            throw "No se pudo clonar $($repository.Name)."
        }
    }

    if (-not (Test-Path $environmentFile)) {
        Copy-Item (Join-Path $standardDirectory ".env.dev") $environmentFile
    }

    $environmentValues = [ordered]@{
        COMPOSE_PROFILES = "emr"
        TZ = "America/Santiago"
        OPENMRS_HOST = "10.68.174.205"
        OPENMRS_PORT = "443"
        CONFIG_VOLUME = Convert-ToComposePath (Join-Path $workspace "standard-config-HCSBA")
        BAHMNI_APPS_PATH = Convert-ToComposePath (Join-Path $workspace "openmrs-module-bahmniapps-hcsba-2024")
        IPD_PATH = Convert-ToComposePath (Join-Path $workspace "openmrs-module-ipd-frontend-hcsba-2024")
        PROXY_IMAGE_TAG = "1.1.0"
        APPOINTMENTS_IMAGE_TAG = "1.1.1"
        IMPLEMENTER_INTERFACE_IMAGE_TAG = "1.1.1"
        PATIENT_DOCUMENTS_TAG = "1.1.1"
        BAHMNI_NEXT_WEB_IMAGE_TAG = "0.1.0-rc.0-ipd-tasks.5"
        CLINICAL_CONSULTATION_ENABLED = "true"
        NEXT_PROXY_DEFINES = "-D NEXT_SHELL -D NEXT_REGISTRATION -D NEXT_CLINICAL -D NEXT_BEDMANAGEMENT -D NEXT_ADT -D NEXT_APPOINTMENTS -D NEXT_DOCUMENT_UPLOAD -D NEXT_ORDERS"
        REPORTS_DB_HOST = "reportsdb"
        RESTART_POLICY = "unless-stopped"
    }
    foreach ($entry in $environmentValues.GetEnumerator()) {
        Set-DotEnvValue -Path $environmentFile -Name $entry.Key -Value $entry.Value
    }

    $nextRepository = Join-Path $workspace "bahmni-nextjs-hcsba"
    $nextLocalEnv = Join-Path $nextRepository ".env.local"
    if (-not (Test-Path $nextLocalEnv)) {
        Copy-Item (Join-Path $nextRepository ".example-env") $nextLocalEnv
    }

    $legacyUi = Join-Path $workspace "openmrs-module-bahmniapps-hcsba-2024\ui"
    $legacyComponents = Join-Path $legacyUi "node_modules\@bower_components"
    if (-not $SkipLegacyDependencies -and -not (Test-Path $legacyComponents)) {
        Write-Host "Instalando dependencias legacy con Node 10..." -ForegroundColor Cyan
        $mount = "type=bind,source=$legacyUi,target=/workspace"
        & docker run --rm --mount $mount --workdir /workspace node:10.24.1 /bin/sh -lc "yarn install --frozen-lockfile"
        if ($LASTEXITCODE -ne 0) {
            throw "Fallo la instalacion de dependencias legacy."
        }
    }

    Write-Host "Workspace preparado en $workspace" -ForegroundColor Green
    Write-Host "Backend de integracion: https://10.68.174.205/openmrs" -ForegroundColor Cyan
}

function Invoke-Compose {
    param([string[]]$Arguments)
    if (-not (Test-Path $environmentFile)) {
        throw "Falta $environmentFile. Ejecute primero: .\dev-environment.ps1 bootstrap"
    }
    Push-Location $standardDirectory
    try {
        & docker compose --project-name $composeProjectName --env-file $environmentFile -f $baseCompose -f $devCompose @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose termino con codigo $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

function Wait-NextHealth {
    $deadline = (Get-Date).AddMinutes(8)
    do {
        $containerId = (& docker compose --project-name $composeProjectName --env-file $environmentFile -f $baseCompose -f $devCompose ps -q bahmni-next-web).Trim()
        if ($containerId) {
            $status = (& docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $containerId).Trim()
            if ($status -eq "healthy") {
                return
            }
            if ($status -in @("unhealthy", "exited", "dead")) {
                Invoke-Compose -Arguments @("logs", "--tail", "160", "bahmni-next-web")
                throw "bahmni-next-web termino en estado $status."
            }
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw "Next.js no estuvo saludable dentro de ocho minutos."
}

function Assert-Http200 {
    param([string]$Url)
    $status = (& curl.exe -k -s -o NUL -w "%{http_code}" $Url).Trim()
    if ($status -ne "200") {
        throw "$Url respondio HTTP $status."
    }
    Write-Host "OK  $Url" -ForegroundColor Green
}

function Assert-RootEntryRedirect {
    $response = (& curl.exe -k -s -D - -o NUL "https://localhost/") -join "`n"
    if ($response -notmatch '(?m)^HTTP/\S+ 302\b' -or
        $response -notmatch '(?mi)^Location:\s*(?:https://localhost)?/bahmni/home/\s*$') {
        throw "https://localhost/ no redirigio a /bahmni/home/."
    }
    Write-Host "OK  https://localhost/ -> /bahmni/home/" -ForegroundColor Green
}

function Test-Integration {
    Assert-Command "curl.exe"
    Wait-NextHealth
    Assert-RootEntryRedirect
    Assert-Http200 "https://localhost/bahmni/api/health"
    Assert-Http200 "https://localhost/bahmni/bedmanagement"
    Assert-Http200 "https://localhost/bahmni/document-upload?encounterType=RADIOLOGY&topLevelConcept=All%20Radiology%20orders"
    Assert-Http200 "https://localhost/bahmni/orders"
    Assert-Http200 "https://localhost/bahmni_config/openmrs/apps/home/app.json"
    Assert-Http200 "https://localhost/openmrs/ws/rest/v1/session"

    $hmr = & curl.exe -k --http1.1 -s -i --max-time 3 `
        -H "Connection: Upgrade" `
        -H "Upgrade: websocket" `
        -H "Sec-WebSocket-Version: 13" `
        -H "Sec-WebSocket-Key: SGVsbG9Xb3JsZDEyMzQ1Ng==" `
        "https://localhost/bahmni/_next/webpack-hmr" 2>$null
    if (($hmr -join "`n") -notmatch "101 Switching Protocols") {
        throw "El proxy no confirmo el WebSocket de Fast Refresh."
    }
    Write-Host "OK  WebSocket Fast Refresh" -ForegroundColor Green
    # curl conserva el codigo 28 del timeout intencional aunque el handshake 101
    # ya haya confirmado el WebSocket. No propagar ese falso fallo al caller.
    $global:LASTEXITCODE = 0
}

Assert-Command "docker"
switch ($Action) {
    "bootstrap" { Initialize-Workspace }
    "up" {
        Invoke-Compose -Arguments @("config", "--quiet")
        Invoke-Compose -Arguments @("up", "-d", "--remove-orphans")
        Test-Integration
    }
    "down" { Invoke-Compose -Arguments @("down", "--remove-orphans") }
    "recreate" {
        Invoke-Compose -Arguments @("down", "--remove-orphans")
        Invoke-Compose -Arguments @("config", "--quiet")
        Invoke-Compose -Arguments @("up", "-d", "--remove-orphans")
        Test-Integration
    }
    "verify" { Test-Integration }
    "logs" { Invoke-Compose -Arguments @("logs", "-f", "--tail", "160", "proxy", "bahmni-next-web", "bahmni-config") }
    "status" { Invoke-Compose -Arguments @("ps") }
}
