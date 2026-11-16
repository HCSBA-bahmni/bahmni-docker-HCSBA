# Uso de QA por contribuyentes HCSBA

## Paquete y fuente mantenida

La fuente mantenida es [bahmni-nextjs-hcsba/skills/his-qa-release](https://github.com/HCSBA-bahmni/bahmni-nextjs-hcsba/tree/main/skills/his-qa-release). Los seis repositorios de la migración distribuyen una copia completa en `skills/his-qa-release`, con instrucciones, metadatos del agente, referencias y plantillas. Copiar sólo `SKILL.md` deja recursos necesarios fuera de la instalación.

La pauta, el catálogo y el harness se mantienen únicamente en [bahmni-nextjs-hcsba](https://github.com/HCSBA-bahmni/bahmni-nextjs-hcsba). Si se trabaja sobre Docker, configuración, backend IPD o frontends legacy, clonar también ese repositorio, preferentemente como hermano del repositorio del cambio. Ejecutar los comandos QA desde su raíz; no asumir que están disponibles en el `package.json` de los otros repositorios.

Requisitos: Git y Node.js 24. El harness sólo usa módulos nativos de Node; sus autopruebas no requieren `npm ci`, navegador, Docker ni acceso clínico. Las pruebas de la aplicación sí requieren las dependencias y el entorno documentados por el proyecto. Aplicar también `bahmni-nextjs-migration` y las instrucciones locales para cambios funcionales y despliegues. Si esa skill no está disponible, obtenerla del equipo antes de realizar una migración; esta exportación distribuye `his-qa-release`.

## Instalar en Codex

Desde la raíz de cualquiera de los seis repositorios, copiar **todo** el directorio a la carpeta personal de skills. Si existe una instalación con modificaciones propias, conservarlas antes de actualizar. La copia usa `CODEX_HOME` cuando está definido.

PowerShell:

```powershell
$skillRoot = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'skills' } else { Join-Path $env:USERPROFILE '.codex/skills' }
New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
Copy-Item -LiteralPath './skills/his-qa-release' -Destination $skillRoot -Recurse -Force
```

Bash (Linux/macOS):

```bash
skill_root="${CODEX_HOME:-$HOME/.codex}/skills"
mkdir -p "$skill_root"
cp -R ./skills/his-qa-release "$skill_root/"
```

Abrir una nueva sesión del agente tras instalar. Invocar `$his-qa-release` e indicar el módulo, la revisión, el repositorio del cambio y la ubicación del checkout Next.js. También se puede proporcionar directamente el archivo `skills/his-qa-release/SKILL.md` al agente y pedirle que lea sus recursos relativos. Otros asistentes pueden seguir esas mismas instrucciones sin instalar una skill de Codex.

## Comprobar y preparar una campaña

Desde `bahmni-nextjs-hcsba`, comprobar primero el harness:

```bash
npm run qa:test
```

Para crear la pauta, usar una carpeta privada **fuera de todos los repositorios**. Ejemplo PowerShell:

```powershell
$qaPrivateRoot = Join-Path $env:USERPROFILE 'his-qa-private/mi-modulo-r01'
New-Item -ItemType Directory -Force -Path $qaPrivateRoot | Out-Null
npm run qa:init -- "$qaPrivateRoot/pauta.json"
# Definir esperado, alcance, revision, imagen y perfiles antes de ejecutar.
# Ejecutar las pruebas y registrar obtenido y evidencia anonimizados.
npm run qa:report -- "$qaPrivateRoot/pauta.json" "$qaPrivateRoot/pre-01" PRE
# Si el encargo incluye entrega, registrar despliegue y ejecutar POST real.
npm run qa:report -- "$qaPrivateRoot/pauta.json" "$qaPrivateRoot/post-01" POST
```

Equivalente Bash para preparar la pauta:

```bash
qa_private_root="$HOME/his-qa-private/mi-modulo-r01"
mkdir -p "$qa_private_root"
npm run qa:init -- "$qa_private_root/pauta.json"
# Tras ejecutar y registrar las pruebas:
npm run qa:report -- "$qa_private_root/pauta.json" "$qa_private_root/pre-01" PRE
```

Los ejemplos sólo preparan y evalúan registros. Una pauta recién creada está pendiente y no aprueba; no convertirla en evidencia. Las autopruebas del harness validan el software de QA con fixtures y no prueban el HIS ni certifican `.225`. El harness no ejecuta pruebas clínicas ni despliega.

En una campaña que abarque varios repositorios, registrar en `release.revision` los commits de todos los componentes y un manifest con hashes de los archivos sin commit entregados. Usar esa misma identificación en los resultados y en `deployment.observedRevision`; no identificar toda la entrega sólo con el HEAD del checkout del harness.

Conservar la política PRE/POST: aceptación ponderada >=95%, ejecución 100%, compuertas y P0/P1 aprobados, ningún hallazgo P0/P1 abierto. POST requiere la misma revisión e imagen y evidencia real posterior a la entrega en `https://10.68.174.225`. Credenciales y conectividad se obtienen por los mecanismos privados del equipo; no incorporarlas a Git. Los informes, datos sintéticos y capturas se conservan fuera de Git. Leer la pauta completa antes de una campaña.

## Mantener las copias

Actualizar primero `bahmni-nextjs-hcsba/skills/his-qa-release`; después copiar el directorio completo a `skills/his-qa-release` de:

- `openmrs-module-bahmniapps-hcsba-2024`
- `openmrs-module-ipd-frontend-hcsba-2024`
- `openmrs-module-ipd`
- `standard-config-HCSBA`
- `bahmni-docker-HCSBA`

Comparar lista de archivos y hashes entre las seis copias y sincronizar las instalaciones personales. Mantener referencias y assets en el mismo commit que `SKILL.md`. La pauta, el catálogo y el harness permanecen en Next.js para evitar divergencias de política y scoring. Una actualización de herramientas oficiales debe conservar las reglas HCSBA; no existe un upstream oficial externo declarado para esta skill.
