param(
    [switch]$Clean,
    [switch]$Audit
)

$ErrorActionPreference = "Stop"
$repository = Split-Path -Parent $MyInvocation.MyCommand.Path
$moduleRepository = Join-Path (Split-Path -Parent $repository) "openmrs-module-oauth2login-hcsba"
$mavenImage = "maven:3.9.11-eclipse-temurin-8@sha256:e3c149f44c95b0e9dd131862b3df67b3f061f7f6f3898a87b170564b3a943611"
$cacheVolume = "hcsba-oauth2-maven-cache"

if (-not (Test-Path (Join-Path $moduleRepository "pom.xml"))) {
    throw "No se encontro el repositorio hermano openmrs-module-oauth2login-hcsba."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker no esta disponible." }

$goals = @("-B")
if ($Clean) { $goals += "clean" }
$goals += @("verify", "org.cyclonedx:cyclonedx-maven-plugin:2.9.1:makeAggregateBom")

Push-Location $moduleRepository
try {
    & docker run --rm --name hcsba-oauth2-build `
        -v "${PWD}:/workspace" -v "${cacheVolume}:/root/.m2" -w /workspace `
        $mavenImage mvn @goals
    if ($LASTEXITCODE -ne 0) { throw "El build del OMOD fallo con codigo $LASTEXITCODE." }

    if ($Audit) {
        if ([string]::IsNullOrWhiteSpace($env:NVD_API_KEY)) {
            throw "Para -Audit defina NVD_API_KEY; la clave no se guarda ni se muestra."
        }
        & docker run --rm --name hcsba-oauth2-audit -e NVD_API_KEY `
            -v "${PWD}:/workspace" -v "${cacheVolume}:/root/.m2" -w /workspace `
            $mavenImage mvn -B org.owasp:dependency-check-maven:12.1.9:aggregate `
                -DnvdApiKeyEnvironmentVariable=NVD_API_KEY -DfailBuildOnCVSS=9.0
        if ($LASTEXITCODE -ne 0) { throw "La compuerta CVE del OMOD fallo." }
    }
} finally {
    Pop-Location
}

$omod = Get-ChildItem -Path (Join-Path $moduleRepository "omod\target") -Filter "*.omod" | Select-Object -First 1
if (-not $omod) { throw "El build termino pero no produjo un archivo .omod." }
Write-Host "OMOD verificado: $($omod.FullName)" -ForegroundColor Green
