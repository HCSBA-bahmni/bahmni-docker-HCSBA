param(
    [ValidateSet("init", "credentials", "csr", "config", "up", "verify-internal", "render-openmrs", "plan-users", "sync-users", "validate-users", "plan-local-users", "sync-local-users", "validate-local-users", "integrate", "verify", "status", "logs", "backup", "down")]
    [string]$Action = "status"
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $MyInvocation.MyCommand.Path
$standard = Join-Path $repository "bahmni-standard"
$baseCompose = Join-Path $standard "docker-compose.yml"
$nextCompose = Join-Path $standard "docker-compose.next-dev.yml"
$ssoCompose = Join-Path $standard "docker-compose.keycloak.yml"
$baseEnv = Join-Path $standard ".env"
$ssoEnv = Join-Path $standard ".env.keycloak"
$ssoEnvExample = Join-Path $standard ".env.keycloak.example"
$secretsDirectory = Join-Path $standard "keycloak\secrets"
$tlsDirectory = Join-Path $standard "keycloak\tls"
$backupDirectory = Join-Path $standard "keycloak\backups"
$generatedDirectory = Join-Path $standard "keycloak\generated"
$projectName = "bahmni-hcsba-dev"
$ssoServices = @("openmrs-token-bridge-openelis", "openmrs-token-bridge-odoo", "openmrs-token-bridge-odoo10", "openmrs-token-bridge-reports", "openmrs-token-bridge-sms", "keycloak-configurator", "keycloak", "keycloak-db")

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

function Initialize-Sso {
    New-Item -ItemType Directory -Force -Path $secretsDirectory, $tlsDirectory, $backupDirectory, $generatedDirectory | Out-Null
    if (-not (Test-Path $ssoEnv)) {
        Copy-Item -LiteralPath $ssoEnvExample -Destination $ssoEnv
    } else {
        $existingNames = @{}
        Get-Content -LiteralPath $ssoEnv | ForEach-Object {
            if ($_ -match '^([A-Za-z_][A-Za-z0-9_]*)=') { $existingNames[$matches[1]] = $true }
        }
        $missingDefaults = Get-Content -LiteralPath $ssoEnvExample | Where-Object {
            $_ -match '^([A-Za-z_][A-Za-z0-9_]*)=' -and -not $existingNames.ContainsKey($matches[1])
        }
        if ($missingDefaults) {
            Add-Content -LiteralPath $ssoEnv -Value @('', '# Added from .env.keycloak.example')
            Add-Content -LiteralPath $ssoEnv -Value $missingDefaults
        }
    }
    foreach ($name in @("keycloak-db-password", "keycloak-admin-password", "openmrs-client-secret", "openelis-client-secret", "odoo-connect-client-secret", "odoo10-connect-client-secret", "reports-client-secret", "sms-service-client-secret")) {
        $path = Join-Path $secretsDirectory $name
        if (-not (Test-Path $path)) {
            [System.IO.File]::WriteAllText($path, (New-RandomSecret), [System.Text.UTF8Encoding]::new($false))
        }
    }
    Write-Host "SSO inicializado. Secretos locales creados sin mostrarlos." -ForegroundColor Green
    if (-not (Test-Path (Join-Path $tlsDirectory "sso-dev-cert.pem"))) {
        Write-Host "Falta el certificado de la CA interna. Ejecute '.\sso.ps1 csr' y haga firmar el CSR antes de 'integrate'." -ForegroundColor Yellow
    }
}

function Get-DotEnvValue([string]$Path, [string]$Name) {
    $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -First 1
    if (-not $line) { throw "Falta $Name en $Path." }
    return ($line -split '=', 2)[1].Trim()
}

function Write-OpenmrsOAuthConfiguration {
    Initialize-Sso
    $templatePath = Join-Path $standard "keycloak\openmrs\oauth2.properties.template"
    $targetPath = Join-Path $generatedDirectory "oauth2.properties"
    $clientSecretPath = Join-Path $secretsDirectory "openmrs-client-secret"
    $keycloakUrl = Get-DotEnvValue $ssoEnv "KEYCLOAK_PUBLIC_URL"
    $bahmniUrl = Get-DotEnvValue $ssoEnv "BAHMNI_PUBLIC_URL"
    $clientSecret = [System.IO.File]::ReadAllText($clientSecretPath).Trim()
    if ([string]::IsNullOrWhiteSpace($clientSecret)) { throw "El secreto OIDC de OpenMRS esta vacio." }
    $loginUrl = [System.Uri]::EscapeDataString("$bahmniUrl/bahmni/login?loggedOut=1")
    $rendered = [System.IO.File]::ReadAllText($templatePath)
    $rendered = $rendered.Replace("__OPENMRS_CLIENT_SECRET__", $clientSecret)
    $rendered = $rendered.Replace("__KEYCLOAK_PUBLIC_URL__", $keycloakUrl.TrimEnd('/'))
    $rendered = $rendered.Replace("__BAHMNI_PUBLIC_URL__", $bahmniUrl.TrimEnd('/'))
    $rendered = $rendered.Replace("__BAHMNI_LOGIN_URL_ENCODED__", $loginUrl)
    [System.IO.File]::WriteAllText($targetPath, $rendered, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Configuracion OpenMRS generada en $targetPath sin mostrar secretos." -ForegroundColor Green
}

function Set-OpenmrsBootstrapCredentials {
    Initialize-Sso
    $username = Read-Host "Usuario OpenMRS temporal para la sincronizacion previa al corte"
    $passwordSecure = Read-Host "Contrasena OpenMRS (no se mostrara)" -AsSecureString
    if ([string]::IsNullOrWhiteSpace($username)) { throw "El usuario OpenMRS no puede estar vacio." }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordSecure)
    try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ([string]::IsNullOrWhiteSpace($password)) { throw "La contrasena OpenMRS no puede estar vacia." }
    [System.IO.File]::WriteAllText((Join-Path $secretsDirectory "openmrs-bootstrap-username"), $username.Trim(), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $secretsDirectory "openmrs-bootstrap-password"), $password, [System.Text.UTF8Encoding]::new($false))
    $password = $null
    Write-Host "Credenciales de sincronizacion guardadas en archivos ignorados por Git." -ForegroundColor Green
}

function Invoke-UserSynchronization([ValidateSet("plan", "apply", "validate")][string]$Mode) {
    Initialize-Sso
    Assert-Command "python"
    $usernameFile = Join-Path $secretsDirectory "openmrs-bootstrap-username"
    $passwordFile = Join-Path $secretsDirectory "openmrs-bootstrap-password"
    foreach ($path in @($usernameFile, $passwordFile)) {
        if (-not (Test-Path $path) -or [string]::IsNullOrWhiteSpace([System.IO.File]::ReadAllText($path))) {
            throw "Faltan credenciales OpenMRS. Ejecute '.\sso.ps1 credentials'."
        }
    }
    $openmrsUrl = Get-DotEnvValue $ssoEnv "BAHMNI_PUBLIC_URL"
    $loopbackPort = Get-DotEnvValue $ssoEnv "KEYCLOAK_LOOPBACK_PORT"
    $adminUsername = Get-DotEnvValue $ssoEnv "KEYCLOAK_BOOTSTRAP_ADMIN"
    $scriptPath = Join-Path $standard "keycloak\tools\sync_openmrs_users.py"
    $outputPath = Join-Path $generatedDirectory "user-sync"
    & python $scriptPath $Mode --openmrs-url $openmrsUrl --keycloak-url "http://127.0.0.1:$loopbackPort" `
        --openmrs-username-file $usernameFile --openmrs-password-file $passwordFile `
        --keycloak-admin $adminUsername --keycloak-password-file (Join-Path $secretsDirectory "keycloak-admin-password") `
        --output $outputPath
    if ($LASTEXITCODE -ne 0) { throw "La sincronizacion de identidades fallo con codigo $LASTEXITCODE." }
}

function Invoke-LocalUserSynchronization([ValidateSet("plan", "apply", "validate")][string]$Mode) {
    Initialize-Sso
    Assert-Command "python"
    $databaseContainer = "bahmni-hcsba-dev-openmrs-local-db-1"
    $running = (& docker inspect --format '{{.State.Running}}' $databaseContainer 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $running -ne "true") {
        throw "La base OpenMRS local aislada no esta activa. Ejecute '.\local-openmrs.ps1 up'."
    }
    $loopbackPort = Get-DotEnvValue $ssoEnv "KEYCLOAK_LOOPBACK_PORT"
    $adminUsername = Get-DotEnvValue $ssoEnv "KEYCLOAK_BOOTSTRAP_ADMIN"
    $outputPath = Join-Path $generatedDirectory "user-sync"
    $identitySource = Join-Path $outputPath "local-identities.json"
    New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

    & python (Join-Path $standard "keycloak\tools\export_local_openmrs_identities.py") `
        --container $databaseContainer --output $identitySource
    if ($LASTEXITCODE -ne 0) { throw "La exportacion local de identidades fallo con codigo $LASTEXITCODE." }

    & python (Join-Path $standard "keycloak\tools\sync_openmrs_users.py") $Mode `
        --identity-source $identitySource --keycloak-url "http://127.0.0.1:$loopbackPort" `
        --keycloak-admin $adminUsername --keycloak-password-file (Join-Path $secretsDirectory "keycloak-admin-password") `
        --output $outputPath
    $syncExitCode = $LASTEXITCODE
    Remove-Item -LiteralPath $identitySource -Force -ErrorAction SilentlyContinue
    if ($syncExitCode -ne 0) { throw "La sincronizacion local de identidades fallo con codigo $syncExitCode." }
    if ($Mode -eq "apply") {
        & python (Join-Path $standard "keycloak\tools\recover_initial_passwords.py") `
            --keycloak-url "http://127.0.0.1:$loopbackPort" --keycloak-admin $adminUsername `
            --keycloak-password-file (Join-Path $secretsDirectory "keycloak-admin-password") `
            --password-csv (Join-Path $outputPath "initial-passwords.csv")
        if ($LASTEXITCODE -ne 0) { throw "La recuperacion de credenciales iniciales fallo con codigo $LASTEXITCODE." }
    }
}

function Invoke-Compose([string[]]$Arguments) {
    if (-not (Test-Path $baseEnv)) { throw "Falta $baseEnv. Ejecute dev-environment.ps1 bootstrap." }
    if (-not (Test-Path $ssoEnv)) { throw "Falta $ssoEnv. Ejecute sso.ps1 init." }
    Push-Location $standard
    try {
        & docker compose --project-name $projectName --env-file $baseEnv --env-file $ssoEnv `
            -f $baseCompose -f $nextCompose -f $ssoCompose --profile sso @Arguments
        if ($LASTEXITCODE -ne 0) { throw "docker compose termino con codigo $LASTEXITCODE." }
    } finally { Pop-Location }
}

function New-CertificateRequest {
    Assert-Command "openssl"
    Initialize-Sso
    $key = Join-Path $tlsDirectory "sso-dev-key.pem"
    $csr = Join-Path $tlsDirectory "sso-dev.csr"
    if (Test-Path $key) { throw "Ya existe $key; no se sobrescribira una clave privada." }
    & openssl req -new -newkey rsa:3072 -nodes -sha256 -keyout $key -out $csr `
        -subj "/CN=sso-dev.hcsba.local" -addext "subjectAltName=DNS:sso-dev.hcsba.local"
    if ($LASTEXITCODE -ne 0) { throw "OpenSSL no pudo generar el CSR." }
    Write-Host "CSR generado en $csr. Envie solamente el .csr a la CA interna." -ForegroundColor Green
}

function Test-Sso {
    Invoke-Compose -Arguments @("ps", "keycloak-db", "keycloak", "keycloak-configurator")
    $hostName = "sso-dev.hcsba.local"
    $line = Get-Content -LiteralPath $ssoEnv | Where-Object { $_ -match '^KEYCLOAK_PUBLIC_HOST=' } | Select-Object -First 1
    if ($line) { $hostName = ($line -split '=', 2)[1].Trim() }
    $status = (& curl.exe -k -s -o NUL -w "%{http_code}" --resolve "${hostName}:443:127.0.0.1" "https://${hostName}/realms/hcsba/.well-known/openid-configuration").Trim()
    if ($status -ne "200") { throw "OIDC discovery respondio HTTP $status." }
    $adminStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" --resolve "${hostName}:443:127.0.0.1" "https://${hostName}/admin/master/console/").Trim()
    if ($adminStatus -ne "200") { throw "La consola administrativa de Keycloak respondio HTTP $adminStatus." }

    $redirectUri = [uri]::EscapeDataString("https://localhost/openmrs/oauth2login")
    $authUrl = "https://${hostName}/realms/hcsba/protocol/openid-connect/auth?client_id=openmrs&redirect_uri=${redirectUri}&response_type=code&scope=openid&state=hcsba-theme-verification"
    $loginHtml = (& curl.exe -k -sS --resolve "${hostName}:443:127.0.0.1" $authUrl) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "No fue posible solicitar el login OIDC para verificar el tema HCSBA." }
    if ($loginHtml -notmatch 'href="([^"]*/login/hcsba/css/login\.css(?:\?[^\"]*)?)"') {
        throw "El login OIDC no esta publicando el tema HCSBA esperado."
    }
    $themePath = $matches[1] -replace '&amp;', '&'
    $themeStatus = (& curl.exe -k -s -o NUL -w "%{http_code}" --resolve "${hostName}:443:127.0.0.1" "https://${hostName}${themePath}").Trim()
    if ($themeStatus -ne "200") { throw "El CSS del tema HCSBA respondio HTTP $themeStatus." }

    Write-Host "OK  Keycloak discovery, tema HCSBA, consola administrativa restringida y proxy TLS" -ForegroundColor Green
}

function Test-SsoInternal {
    Initialize-Sso
    Assert-Command "python"
    $loopbackPort = Get-DotEnvValue $ssoEnv "KEYCLOAK_LOOPBACK_PORT"
    $adminUsername = Get-DotEnvValue $ssoEnv "KEYCLOAK_BOOTSTRAP_ADMIN"
    $expectedIssuer = (Get-DotEnvValue $ssoEnv "KEYCLOAK_PUBLIC_URL").TrimEnd('/') + "/realms/hcsba"
    $expectedBackchannelLogoutUrl = Get-DotEnvValue $ssoEnv "OPENMRS_BACKCHANNEL_LOGOUT_URL"
    if (Test-LocalOpenmrsRunning) {
        $expectedBackchannelLogoutUrl = "http://openmrs-local:8080/openmrs/oauth2backchannellogout"
    }
    & python (Join-Path $standard "keycloak\tools\verify_keycloak.py") `
        --keycloak-url "http://127.0.0.1:$loopbackPort" --expected-issuer $expectedIssuer `
        --expected-backchannel-logout-url $expectedBackchannelLogoutUrl `
        --keycloak-admin $adminUsername --keycloak-password-file (Join-Path $secretsDirectory "keycloak-admin-password") `
        --secrets-directory $secretsDirectory
    if ($LASTEXITCODE -ne 0) { throw "La verificacion interna de Keycloak fallo." }
}

function Test-LocalOpenmrsRunning {
    $container = (& docker ps --filter "label=com.docker.compose.project=$projectName" `
        --filter "label=com.docker.compose.service=openmrs-local" --format "{{.Names}}" | Select-Object -First 1)
    return -not [string]::IsNullOrWhiteSpace($container)
}

Assert-Command "docker"
switch ($Action) {
    "init" { Initialize-Sso }
    "credentials" { Set-OpenmrsBootstrapCredentials }
    "csr" { New-CertificateRequest }
    "config" { Initialize-Sso; Invoke-Compose -Arguments @("config", "--quiet") }
    "up" {
        Initialize-Sso
        Invoke-Compose -Arguments @("config", "--quiet")
        Invoke-Compose -Arguments @("up", "-d", "--build", "keycloak-db", "keycloak", "keycloak-configurator")
        Write-Host "Keycloak esta levantado, pero AUTH_MODE sigue en openmrs hasta el corte." -ForegroundColor Cyan
    }
    "verify-internal" { Test-SsoInternal }
    "render-openmrs" { Write-OpenmrsOAuthConfiguration }
    "plan-users" { Invoke-UserSynchronization "plan" }
    "sync-users" { Invoke-UserSynchronization "apply" }
    "validate-users" { Invoke-UserSynchronization "validate" }
    "plan-local-users" { Invoke-LocalUserSynchronization "plan" }
    "sync-local-users" { Invoke-LocalUserSynchronization "apply" }
    "validate-local-users" { Invoke-LocalUserSynchronization "validate" }
    "integrate" {
        Initialize-Sso
        foreach ($file in @("sso-dev-cert.pem", "sso-dev-key.pem")) {
            if (-not (Test-Path (Join-Path $tlsDirectory $file))) { throw "Falta keycloak/tls/$file firmado por la CA interna." }
        }
        if (Test-LocalOpenmrsRunning) {
            & (Join-Path $repository "local-openmrs.ps1") up
            if ($LASTEXITCODE -ne 0) { throw "No fue posible reconciliar el proxy con OpenMRS local." }
        } else {
            Invoke-Compose -Arguments @("up", "-d", "--build", "keycloak-db", "keycloak", "keycloak-configurator", "proxy", "bahmni-next-web")
        }
        Test-Sso
    }
    "verify" { Test-Sso }
    "status" { Invoke-Compose -Arguments @("ps") }
    "logs" { Invoke-Compose -Arguments @("logs", "-f", "--tail", "160", "keycloak", "keycloak-configurator", "keycloak-db") }
    "backup" {
        Initialize-Sso
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $target = Join-Path $backupDirectory "keycloak-$timestamp.sql"
        Push-Location $standard
        try {
            & docker compose --project-name $projectName --env-file $baseEnv --env-file $ssoEnv `
                -f $baseCompose -f $nextCompose -f $ssoCompose --profile sso exec -T keycloak-db `
                sh -c 'PGPASSWORD="$$(cat /run/secrets/keycloak_db_password)" pg_dump -U "$${POSTGRES_USER}" "$${POSTGRES_DB}"' | Set-Content -Encoding utf8 $target
            if ($LASTEXITCODE -ne 0) { throw "No fue posible respaldar PostgreSQL de Keycloak." }
        } finally { Pop-Location }
        Write-Host "Respaldo creado en $target" -ForegroundColor Green
    }
    "down" {
        Invoke-Compose -Arguments (@("stop") + $ssoServices)
        Invoke-Compose -Arguments (@("rm", "-f") + $ssoServices)
        Write-Host "Servicios SSO detenidos; el volumen keycloak-db-data fue preservado." -ForegroundColor Green
    }
}
