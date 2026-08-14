param(
    [ValidateSet("init", "dev-cert", "snapshot", "import", "up", "verify", "status", "logs", "remote", "down")]
    [string]$Action = "status",
    [string]$Snapshot = "",
    [switch]$ConfirmReplace
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $MyInvocation.MyCommand.Path
$standard = Join-Path $repository "bahmni-standard"
$baseCompose = Join-Path $standard "docker-compose.yml"
$nextCompose = Join-Path $standard "docker-compose.next-dev.yml"
$ssoCompose = Join-Path $standard "docker-compose.keycloak.yml"
$localCompose = Join-Path $standard "docker-compose.openmrs-local.yml"
$baseEnv = Join-Path $standard ".env"
$ssoEnv = Join-Path $standard ".env.keycloak"
$localEnv = Join-Path $standard ".env.openmrs-local"
$localEnvExample = Join-Path $standard ".env.openmrs-local.example"
$localDirectory = Join-Path $standard "openmrs-local"
$secretsDirectory = Join-Path $localDirectory "secrets"
$snapshotsDirectory = Join-Path $localDirectory "snapshots"
$stateDirectory = Join-Path $localDirectory "state"
$stateFile = Join-Path $stateDirectory "imported.json"
$tlsDirectory = Join-Path $standard "keycloak\tls"
$projectName = "bahmni-hcsba-dev"

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "No se encontro '$Name' en PATH."
    }
}

function New-RandomSecret {
    $bytes = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-EnvMap([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Falta $Path." }
    $result = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $value = $matches[2].Trim()
            if (($value.StartsWith("'") -and $value.EndsWith("'")) -or
                ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $result[$matches[1]] = $value
        }
    }
    return $result
}

function Initialize-LocalOpenmrs {
    New-Item -ItemType Directory -Force -Path $secretsDirectory, $snapshotsDirectory, $stateDirectory, $tlsDirectory | Out-Null
    if (-not (Test-Path -LiteralPath $localEnv)) {
        Copy-Item -LiteralPath $localEnvExample -Destination $localEnv
    }
    foreach ($name in @("openmrs-local-db-password", "openmrs-local-db-root-password")) {
        $path = Join-Path $secretsDirectory $name
        if (-not (Test-Path -LiteralPath $path)) {
            [System.IO.File]::WriteAllText($path, (New-RandomSecret), [System.Text.UTF8Encoding]::new($false))
        }
    }
    & (Join-Path $repository "sso.ps1") init

    $envMap = Get-EnvMap $localEnv
    foreach ($name in @("HCSBA_OAUTH2_OMOD_PATH", "HCSBA_IPD_OMOD_PATH")) {
        if (-not $envMap.ContainsKey($name)) { throw "Falta $name en $localEnv." }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $standard $envMap[$name]))
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw "No existe el artefacto requerido: $candidate. Compile los OMOD antes de levantar OpenMRS."
        }
    }
    Write-Host "Entorno OpenMRS local inicializado. Los secretos y snapshots estan ignorados por Git." -ForegroundColor Green
}

function Get-ComposePrefix([switch]$WithoutLocal) {
    $arguments = @("compose", "--project-name", $projectName, "--env-file", $baseEnv)
    if ($WithoutLocal) {
        return $arguments + @("-f", $baseCompose, "-f", $nextCompose)
    }
    foreach ($path in @($ssoEnv, $localEnv)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Falta $path. Ejecute .\local-openmrs.ps1 init." }
        $arguments += @("--env-file", $path)
    }
    return $arguments + @(
        "-f", $baseCompose,
        "-f", $nextCompose,
        "-f", $ssoCompose,
        "-f", $localCompose,
        "--profile", "sso",
        "--profile", "local-openmrs"
    )
}

function Invoke-Compose([string[]]$Arguments, [switch]$WithoutLocal) {
    $prefix = Get-ComposePrefix -WithoutLocal:$WithoutLocal
    Push-Location $standard
    try {
        & docker @prefix @Arguments
        if ($LASTEXITCODE -ne 0) { throw "docker compose termino con codigo $LASTEXITCODE." }
    } finally { Pop-Location }
}

function Get-LocalDatabaseContainer {
    $prefix = Get-ComposePrefix
    Push-Location $standard
    try {
        $id = (& docker @prefix ps -q openmrs-local-db).Trim()
    } finally { Pop-Location }
    if ([string]::IsNullOrWhiteSpace($id)) { throw "El contenedor openmrs-local-db no esta creado." }
    $labelsJson = (& docker inspect --format '{{json .Config.Labels}}' $id).Trim()
    if ([string]::IsNullOrWhiteSpace($labelsJson)) { throw "El contenedor local no tiene etiquetas de Compose." }
    $labels = $labelsJson | ConvertFrom-Json
    $service = $labels.'com.docker.compose.service'
    $project = $labels.'com.docker.compose.project'
    $isolation = $labels.'hcsba.environment'
    if ($service -ne "openmrs-local-db" -or $project -ne $projectName -or $isolation -ne "local-isolated") {
        throw "Proteccion activada: el contenedor no es la base local aislada esperada."
    }
    return $id
}

function Wait-LocalDatabase {
    $id = Get-LocalDatabaseContainer
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $health = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $id).Trim()
        if ($health -eq "healthy") { return }
        if ($health -eq "unhealthy" -or $health -eq "exited") {
            throw "La base local termino en estado $health. Revise .\local-openmrs.ps1 logs."
        }
        Start-Sleep -Seconds 2
    }
    throw "La base local no quedo saludable dentro del tiempo esperado."
}

function New-DevelopmentCertificate {
    Initialize-LocalOpenmrs
    $key = Join-Path $tlsDirectory "sso-dev-key.pem"
    $cert = Join-Path $tlsDirectory "sso-dev-cert.pem"
    $caKey = Join-Path $tlsDirectory "local-dev-ca-key.pem"
    $caCert = Join-Path $tlsDirectory "local-dev-ca-cert.pem"
    $csr = Join-Path $tlsDirectory "sso-dev.csr"
    $extension = Join-Path $tlsDirectory "dev-server-ext.cnf"
    if ((Test-Path -LiteralPath $key) -and (Test-Path -LiteralPath $cert) -and
        (Test-Path -LiteralPath $caKey) -and (Test-Path -LiteralPath $caCert)) {
        Write-Host "El certificado SSO ya existe; no se sobrescribio." -ForegroundColor Yellow
        return
    }
    if ((Test-Path -LiteralPath $key) -xor (Test-Path -LiteralPath $cert)) {
        throw "El par servidor TLS esta incompleto en $tlsDirectory."
    }
    if ((Test-Path -LiteralPath $caKey) -xor (Test-Path -LiteralPath $caCert)) {
        throw "El par de la CA local esta incompleto en $tlsDirectory."
    }
    if (-not (Test-Path -LiteralPath $extension)) { throw "Falta $extension." }

    $base = Get-EnvMap $baseEnv
    $proxyTag = $base["PROXY_IMAGE_TAG"]
    if ([string]::IsNullOrWhiteSpace($proxyTag)) { throw "Falta PROXY_IMAGE_TAG para ejecutar OpenSSL en Docker." }
    $opensslImage = "bahmni/proxy:$proxyTag"
    $mount = "type=bind,src=$tlsDirectory,dst=/tls"

    & docker run --rm --entrypoint sh --mount $mount $opensslImage /tls/generate-dev-certificate.sh
    if ($LASTEXITCODE -ne 0) { throw "OpenSSL no pudo generar el material TLS local." }
    Write-Host "Certificado servidor creado por 30 dias. Importe $caCert como raiz confiable solo en DEV." -ForegroundColor Green
    Write-Host "Agregue tambien '127.0.0.1 sso-dev.hcsba.local' al archivo hosts si el nombre no resuelve localmente." -ForegroundColor Yellow
}

function New-RemoteSnapshot {
    Initialize-LocalOpenmrs
    $source = Get-EnvMap $baseEnv
    foreach ($name in @("OPENMRS_DB_HOST", "OPENMRS_DB_NAME", "OPENMRS_DB_USERNAME", "OPENMRS_DB_PASSWORD")) {
        if (-not $source.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($source[$name])) {
            throw "Falta $name en $baseEnv."
        }
    }
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $fileName = "openmrs-$timestamp.sql.gz"
    $partialName = "$fileName.partial"
    $env:SOURCE_DB_HOST = $source["OPENMRS_DB_HOST"]
    $env:SOURCE_DB_NAME = $source["OPENMRS_DB_NAME"]
    $env:SOURCE_DB_USER = $source["OPENMRS_DB_USERNAME"]
    $env:SOURCE_DB_PASSWORD = $source["OPENMRS_DB_PASSWORD"]
    try {
        $dumpCommand = 'set -euo pipefail; MYSQL_PWD="$SOURCE_DB_PASSWORD" mysqldump --protocol=tcp -h "$SOURCE_DB_HOST" -u "$SOURCE_DB_USER" --single-transaction --quick --routines --triggers --events --hex-blob --set-gtid-purged=OFF --no-tablespaces --column-statistics=0 "$SOURCE_DB_NAME" | gzip -1 > "/backup/' + $partialName + '"; mv "/backup/' + $partialName + '" "/backup/' + $fileName + '"'
        & docker run --rm --entrypoint bash `
            --mount "type=bind,src=$snapshotsDirectory,dst=/backup" `
            -e SOURCE_DB_HOST -e SOURCE_DB_NAME -e SOURCE_DB_USER -e SOURCE_DB_PASSWORD `
            mysql:8.0.46 -lc $dumpCommand
        if ($LASTEXITCODE -ne 0) { throw "mysqldump no pudo crear la instantanea." }
    } finally {
        Remove-Item Env:\SOURCE_DB_HOST, Env:\SOURCE_DB_NAME, Env:\SOURCE_DB_USER, Env:\SOURCE_DB_PASSWORD -ErrorAction SilentlyContinue
    }
    $target = Join-Path $snapshotsDirectory $fileName
    if (-not (Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -lt 1024) {
        throw "La instantanea resultante es invalida o esta vacia."
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$target.sha256", "$hash  $fileName`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "Instantanea transaccional creada: $target" -ForegroundColor Green
    Write-Host "Contiene datos clinicos/PII y permanece fuera de Git." -ForegroundColor Yellow
}

function Resolve-Snapshot([string]$Requested) {
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        $candidate = Get-ChildItem -LiteralPath $snapshotsDirectory -Filter "openmrs-*.sql.gz" -File |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $candidate) { throw "No hay snapshots. Ejecute .\local-openmrs.ps1 snapshot." }
        return $candidate
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $snapshotsDirectory $Requested))
    $root = [System.IO.Path]::GetFullPath($snapshotsDirectory) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "El snapshot debe estar dentro de $snapshotsDirectory."
    }
    $item = Get-Item -LiteralPath $full
    if (-not $item.Name.EndsWith(".sql.gz")) { throw "El snapshot debe terminar en .sql.gz." }
    return $item
}

function Import-LocalSnapshot([string]$Requested, [switch]$AllowReplace) {
    Initialize-LocalOpenmrs
    $dump = Resolve-Snapshot $Requested
    if ((Test-Path -LiteralPath $stateFile) -and -not $AllowReplace) {
        throw "Ya existe una copia local. Repita con -ConfirmReplace para reemplazar solo esa copia."
    }
    Invoke-Compose @("up", "-d", "openmrs-local-db")
    Wait-LocalDatabase
    $null = Get-LocalDatabaseContainer
    Invoke-Compose @("stop", "openmrs-local")

    if (Test-Path -LiteralPath $stateFile) {
        $backupName = "local-before-replace-$(Get-Date -Format 'yyyyMMdd-HHmmss').sql.gz"
        Invoke-Compose @("exec", "-T", "openmrs-local-db", "bash", "/opt/hcsba/local-db.sh", "backup", $backupName)
        Write-Host "Respaldo previo de la copia local: $backupName" -ForegroundColor Cyan
    }

    Invoke-Compose @("exec", "-T", "openmrs-local-db", "bash", "/opt/hcsba/local-db.sh", "import", $dump.Name)

    $state = [ordered]@{
        importedAt = (Get-Date).ToUniversalTime().ToString("o")
        sourceFile = $dump.Name
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $dump.FullName).Hash.ToLowerInvariant()
        target = "docker:$projectName/openmrs-local-db/openmrs"
        isolationPatch = "openmrs-local/isolate-clone.sql"
    }
    [System.IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Snapshot importado exclusivamente en la base local aislada." -ForegroundColor Green
}

function Start-LocalStack {
    Initialize-LocalOpenmrs
    if (-not (Test-Path -LiteralPath $stateFile)) {
        throw "Falta importar un snapshot antes de iniciar OpenMRS."
    }
    foreach ($file in @("sso-dev-cert.pem", "sso-dev-key.pem")) {
        if (-not (Test-Path -LiteralPath (Join-Path $tlsDirectory $file))) {
            throw "Falta keycloak/tls/$file. Ejecute .\local-openmrs.ps1 dev-cert para DEV local."
        }
    }
    Invoke-Compose @("config", "--quiet")
    Invoke-Compose @("up", "-d", "keycloak-db", "keycloak", "keycloak-configurator")
    Invoke-Compose @("up", "-d", "openmrs-local-db", "openmrs-local")
    Invoke-Compose @("up", "-d", "patient-documents", "bahmni-web", "bahmni-next-web", "proxy")
    Write-Host "Stack local activo. /openmrs apunta al clon local; .205 no recibe escrituras." -ForegroundColor Green
}

function Test-LocalStack {
    Invoke-Compose @("ps", "openmrs-local-db", "openmrs-local", "keycloak", "proxy", "bahmni-next-web")
    $sessionStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" "https://localhost/openmrs/ws/rest/v1/session").Trim()
    if ($sessionStatus -ne "200") { throw "La sesion OpenMRS local respondio HTTP $sessionStatus." }
    $oidcStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" --resolve "sso-dev.hcsba.local:443:127.0.0.1" "https://sso-dev.hcsba.local/realms/hcsba/.well-known/openid-configuration").Trim()
    if ($oidcStatus -ne "200") { throw "OIDC discovery respondio HTTP $oidcStatus." }
    & (Join-Path $repository "sso.ps1") verify-internal
    if ($LASTEXITCODE -ne 0) { throw "El contrato interno de Keycloak no coincide con OpenMRS local." }
    $oauthHeaders = (& curl.exe -k -sS -o NUL -D - --max-time 20 "https://localhost/openmrs/oauth2login") -join "`n"
    if ($oauthHeaders -notmatch 'Location: https://sso-dev\.hcsba\.local/.+redirect_uri=https://localhost/openmrs/oauth2login') {
        throw "OpenMRS no emitio el callback OIDC HTTPS exacto para localhost."
    }
    $prefix = Get-ComposePrefix
    Push-Location $standard
    try { $checks = & docker @prefix exec -T openmrs-local-db bash /opt/hcsba/local-db.sh check-isolation }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or @($checks | Where-Object { $_.Trim() -ne "0" }).Count -ne 0) {
        throw "La comprobacion de aislamiento detecto tareas o publicaciones activas."
    }
    Write-Host "OK  OpenMRS local, callback OIDC HTTPS, proxy y aislamiento de efectos externos." -ForegroundColor Green
}

function Switch-ToRemote {
    if (Test-Path -LiteralPath $localEnv) {
        Invoke-Compose @("stop", "openmrs-local")
    }
    # Reconcile the same client back to the shared DEV backend. A Keycloak client has
    # one back-channel URL, so leaving the local target after stopping the clone would
    # silently break administrative session termination in remote mode.
    Push-Location $standard
    try {
        & docker compose --project-name $projectName --env-file $baseEnv --env-file $ssoEnv `
            -f $baseCompose -f $nextCompose -f $ssoCompose --profile sso `
            up -d keycloak-configurator
        if ($LASTEXITCODE -ne 0) { throw "No fue posible restaurar el back-channel de OpenMRS compartido." }
    } finally { Pop-Location }
    Invoke-Compose -WithoutLocal @("up", "-d", "proxy", "bahmni-next-web")
    Write-Host "Proxy restaurado al backend compartido .205. Los volumenes locales se conservaron." -ForegroundColor Green
}

Assert-Command "docker"
switch ($Action) {
    "init" { Initialize-LocalOpenmrs }
    "dev-cert" { New-DevelopmentCertificate }
    "snapshot" { New-RemoteSnapshot }
    "import" { Import-LocalSnapshot -Requested $Snapshot -AllowReplace:$ConfirmReplace }
    "up" { Start-LocalStack }
    "verify" { Test-LocalStack }
    "status" {
        Initialize-LocalOpenmrs
        Invoke-Compose @("ps")
        if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile }
        else { Write-Host "Todavia no hay snapshot importado." -ForegroundColor Yellow }
    }
    "logs" { Invoke-Compose @("logs", "-f", "--tail", "180", "openmrs-local", "openmrs-local-db", "keycloak") }
    "remote" { Switch-ToRemote }
    "down" {
        Invoke-Compose @("stop", "openmrs-local", "openmrs-local-db")
        Invoke-Compose @("rm", "-f", "openmrs-local", "openmrs-local-db")
        Write-Host "OpenMRS local detenido; bases, archivos y snapshots se conservaron." -ForegroundColor Green
    }
}
