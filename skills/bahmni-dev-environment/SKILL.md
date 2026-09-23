---
name: bahmni-dev-environment
description: Preparar, levantar, verificar y diagnosticar el entorno de desarrollo integrado HCSBA Bahmni con Docker Compose, Next.js Fast Refresh, configuracion local, aplicaciones legacy y OpenMRS remoto. Usar al instalar el workspace en una maquina limpia, iniciar o detener el stack, comprobar hot reload y rutas same-origin, investigar fallos del proxy o contenedores, o explicar que repositorios y servicios requiere el modo dev.
---

# Bahmni Dev Environment

## Objetivo

Operar el entorno reproducible descrito en `../../DEV_MODE.md`. Mantener Next.js en modo desarrollo con Fast Refresh bajo `https://localhost`, la configuracion HCSBA y los frontends legacy locales, y OpenMRS integrado desde `10.68.174.205` a traves de Apache.

## Antes de actuar

1. Leer `../../DEV_MODE.md` completo.
2. Ejecutar `git status --short` en cada repositorio que se vaya a modificar.
3. Tratar `.env`, `bahmni-standard/docker-compose.yml` y cualquier cambio sin commit como propiedad del usuario.
4. No copiar credenciales a archivos `NEXT_PUBLIC_*`, documentación, salidas ni commits.
5. No ejecutar `docker compose down -v`, podas globales ni borrar volúmenes. El modo dev reutiliza datos y recursos existentes.

## Flujo principal

Ejecutar los comandos desde la raiz de `bahmni-docker-HCSBA`:

```powershell
.\dev-environment.ps1 bootstrap
.\dev-environment.ps1 up
```

`bootstrap` debe ser idempotente: clona solamente repositorios ausentes, conserva repositorios existentes, crea archivos locales sólo cuando faltan y actualiza las claves de integración requeridas en `bahmni-standard/.env`.

Usar después:

```powershell
.\dev-environment.ps1 status
.\dev-environment.ps1 logs
.\dev-environment.ps1 verify
.\dev-environment.ps1 down
```

Usar `recreate` únicamente cuando sea necesario bajar y volver a crear el proyecto Compose. Nunca agregar `-v`.

## Topología que se debe preservar

- Apache expone el origen integrado `https://localhost`.
- `/bahmni` y `/_next` resuelven al contenedor Next.js según los defines activos.
- `/openmrs` se proxifica al backend `10.68.174.205:443`.
- `/bahmni_config` y `/implementation_config` se sirven desde `standard-config-HCSBA`.
- Las aplicaciones AngularJS se montan desde `openmrs-module-bahmniapps-hcsba-2024` para paridad y rollback.
- `docker-compose.next-dev.yml` reemplaza sólo `bahmni-next-web` por Node en modo `next dev --webpack`, monta el código fuente y activa Watchpack polling para Docker Desktop sobre Windows.
- El WebSocket `/bahmni/_next/webpack-hmr` debe conservar HTTP 101 para Fast Refresh.
- El proyecto Compose debe llamarse `bahmni-hcsba-dev` para no colisionar con otros workspaces que usen el directorio `bahmni-standard`.

No reemplazar esta topología por URLs absolutas públicas en el frontend: rompería cookies, CORS y la equivalencia con producción.

## Verificación obligatoria

Antes de afirmar que el entorno funciona, ejecutar:

```powershell
.\dev-environment.ps1 verify
```

La verificación debe confirmar:

- Contenedor `bahmni-next-web` saludable.
- HTTP 200 en `/bahmni/api/health`.
- HTTP 200 en `/bahmni/bedmanagement`.
- HTTP 200 para configuración HCSBA.
- Acceso same-origin a la sesión OpenMRS.
- Upgrade HTTP 101 del WebSocket de Fast Refresh.

Si se modificó código Next.js, comprobar además que el navegador recibe el cambio sin reconstruir una imagen ni reiniciar el stack.

## Diagnóstico

1. Ejecutar `status` y luego `logs`.
2. Validar la composición antes de recrear servicios:

```powershell
docker compose --project-name bahmni-hcsba-dev --env-file .\bahmni-standard\.env `
  -f .\bahmni-standard\docker-compose.yml `
  -f .\bahmni-standard\docker-compose.next-dev.yml config --quiet
```

3. Si Next falla después de cambiar `package-lock.json`, dejar que el entrypoint del overlay ejecute `npm ci`; no instalar dependencias manualmente dentro del volumen salvo diagnóstico justificado.
4. Si la UI carga pero no autentica, revisar primero cookies y proxy `/openmrs`, no introducir credenciales en el frontend.
5. Si Fast Refresh no conecta, revisar la regla WebSocket explícita en `bahmni-standard/bahmni-proxy.conf` antes de tocar Next.js.
6. Si sólo falla configuración o traducciones, revisar `standard-config-HCSBA` y sus overrides montados.

## Límites del hot reload

El modo dev recarga el frontend Next.js. No despliega automáticamente el OMOD de `openmrs-module-ipd` ni otros módulos backend. Para cambios Java, compilar y desplegar el OMOD mediante el flujo backend correspondiente y declarar explícitamente qué servidor OpenMRS se modificará.

## Ediciones seguras

- Editar archivos con `apply_patch`.
- Mantener el compose base intacto siempre que el cambio pueda vivir en el overlay.
- Agregar nuevas variables públicas también a `bahmni-nextjs-hcsba/.example-env` con comentarios y valores de desarrollo no secretos.
- Actualizar `../../DEV_MODE.md` cuando cambien repositorios, ramas, puertos, endpoints, comandos o responsabilidades de servicios.
- Informar qué contenedores se bajaron y si los datos siguen recuperables después de cualquier acción material.
