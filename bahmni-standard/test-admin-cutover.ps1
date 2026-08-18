param(
    [string]$ComposeFile = "docker-compose.yml"
)

$ErrorActionPreference = "Stop"
$compose = Join-Path $PSScriptRoot $ComposeFile
$proxy = Join-Path $PSScriptRoot "bahmni-proxy.conf"

if (-not (Test-Path -LiteralPath $compose)) { throw "No existe $compose" }
if (-not (Test-Path -LiteralPath $proxy)) { throw "No existe $proxy" }

$config = Get-Content -LiteralPath $proxy -Raw
$legacyIndex = $config.IndexOf("ProxyPass /bahmni/admin-legacy")
$nextIndex = $config.IndexOf("ProxyPass /bahmni/admin http://bahmni-next-web")
if ($legacyIndex -lt 0 -or $nextIndex -lt 0 -or $legacyIndex -gt $nextIndex) {
    throw "El alias admin-legacy debe estar declarado antes del cutover general de admin."
}

docker compose --env-file (Join-Path $PSScriptRoot ".env") -f $compose config --quiet
if ($LASTEXITCODE -ne 0) { throw "docker compose config no es válido." }

Write-Host "Configuración válida. Activación:" -ForegroundColor Green
Write-Host '  NEXT_PROXY_DEFINES="-D NEXT_ADMIN_AUDIT_LOG" docker compose up -d --force-recreate proxy'
Write-Host "Rollback:"
Write-Host '  NEXT_PROXY_DEFINES="" docker compose up -d --force-recreate proxy'
