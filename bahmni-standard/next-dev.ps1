param(
    [ValidateSet("up", "restore", "logs", "status")]
    [string]$Action = "up"
)

$ErrorActionPreference = "Stop"
$composeDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseCompose = Join-Path $composeDirectory "docker-compose.yml"
$devCompose = Join-Path $composeDirectory "docker-compose.next-dev.yml"
$environmentFile = Join-Path $composeDirectory ".env"

function Invoke-Compose {
    param([string[]]$Arguments)

    & docker compose --env-file $environmentFile -f $baseCompose -f $devCompose @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose termino con codigo $LASTEXITCODE."
    }
}

function Invoke-BaseCompose {
    param([string[]]$Arguments)

    & docker compose --env-file $environmentFile -f $baseCompose @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose termino con codigo $LASTEXITCODE."
    }
}

function Wait-NextHealth {
    $containerId = (& docker compose --env-file $environmentFile -f $baseCompose -f $devCompose ps -q bahmni-next-web).Trim()
    if (-not $containerId) {
        throw "No se encontro el contenedor bahmni-next-web."
    }

    $deadline = (Get-Date).AddMinutes(5)
    do {
        $status = (& docker inspect --format "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" $containerId).Trim()
        if ($status -eq "healthy") {
            Write-Host "Next.js dev esta disponible en https://localhost/bahmni" -ForegroundColor Green
            return
        }
        if ($status -eq "unhealthy" -or $status -eq "exited") {
            Invoke-Compose -Arguments @("logs", "--tail", "120", "bahmni-next-web")
            throw "bahmni-next-web termino en estado $status."
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    Invoke-Compose -Arguments @("logs", "--tail", "120", "bahmni-next-web")
    throw "Next.js dev no estuvo saludable dentro de cinco minutos."
}

Push-Location $composeDirectory
try {
    switch ($Action) {
        "up" {
            Invoke-Compose -Arguments @("config", "--quiet")
            Invoke-Compose -Arguments @("up", "-d", "--force-recreate", "--no-deps", "bahmni-next-web")
            Wait-NextHealth
            Write-Host "Edite bahmni-nextjs-hcsba; Fast Refresh se enviara por https://localhost." -ForegroundColor Cyan
        }
        "restore" {
            Invoke-BaseCompose -Arguments @("up", "-d", "--force-recreate", "--no-deps", "bahmni-next-web")
            Write-Host "Se restauro la imagen versionada de bahmni-next-web." -ForegroundColor Green
        }
        "logs" {
            Invoke-Compose -Arguments @("logs", "-f", "--tail", "120", "bahmni-next-web")
        }
        "status" {
            Invoke-Compose -Arguments @("ps", "bahmni-next-web")
        }
    }
}
finally {
    Pop-Location
}
