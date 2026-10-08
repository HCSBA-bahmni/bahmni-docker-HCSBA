# Rutas modernas en los equipos de desarrollo

El proxy local monta `bahmni-standard/bahmni-proxy.conf`. Las rutas de Next.js
se resuelven antes del fallback `/bahmni` de AngularJS y conservan el mismo origen
`https://localhost` para OpenMRS, configuración y cookies de sesión.

| Define | Rutas hacia Next.js |
| --- | --- |
| `NEXT_SHELL` | `/bahmni/home`, `/bahmni/login`, `/bahmni/location`, `/bahmni/change-password` |
| `NEXT_REGISTRATION` | `/bahmni/registration` |
| `NEXT_CLINICAL` | `/bahmni/clinical` |
| `NEXT_BEDMANAGEMENT` | `/bahmni/bedmanagement` |
| `NEXT_ADT` | `/bahmni/adt` |
| `NEXT_APPOINTMENTS` | `/bahmni/appointments` |
| `NEXT_DOCUMENT_UPLOAD` | `/bahmni/document-upload` |
| `NEXT_ORDERS` | `/bahmni/orders` |
| `NEXT_ADMIN_AUDIT_LOG` | `/bahmni/admin` |

El overlay `docker-compose.next-dev.yml` activa estos nueve defines por defecto.
Si un equipo ya tiene `NEXT_PROXY_DEFINES` en `bahmni-standard/.env`, ese valor
prevalece y debe actualizarse explícitamente para habilitar todas las vistas:

```dotenv
NEXT_PROXY_DEFINES=-D NEXT_SHELL -D NEXT_REGISTRATION -D NEXT_CLINICAL -D NEXT_BEDMANAGEMENT -D NEXT_ADT -D NEXT_APPOINTMENTS -D NEXT_DOCUMENT_UPLOAD -D NEXT_ORDERS -D NEXT_ADMIN_AUDIT_LOG
```

Desde la raíz de `bahmni-docker-HCSBA`, con el entorno dev ya preparado y Next.js
en ejecución, actualizar Git y recrear únicamente el proxy:

```powershell
git pull --ff-only origin master
docker compose --project-name bahmni-hcsba-dev --env-file .\bahmni-standard\.env `
  -f .\bahmni-standard\docker-compose.yml `
  -f .\bahmni-standard\docker-compose.next-dev.yml config --quiet
docker compose --project-name bahmni-hcsba-dev --env-file .\bahmni-standard\.env `
  -f .\bahmni-standard\docker-compose.yml `
  -f .\bahmni-standard\docker-compose.next-dev.yml `
  up -d --no-deps --force-recreate proxy
.\dev-environment.ps1 verify
```

Si el equipo utiliza overlays opcionales, agregar sus mismos `-f` y perfiles
a los comandos Compose. Para una instalación nueva seguir `DEV_MODE.md`.
No hace falta reconstruir Next.js ni reiniciar servicios clínicos para aplicar
la configuración del proxy. Su CA y certificados locales deben estar preparados.

`/bahmni/_next/webpack-hmr` conserva el WebSocket de Fast Refresh; `/_next`, API
e i18n bajo `/bahmni` se sirven desde Next. `/bahmni/admin-legacy` conserva la
entrada alternativa de Administración. Quitar un define y recrear el proxy
devuelve las rutas de ese módulo al fallback legacy.

Los dos proxies también reservan `/openmrs/mpi-admission-gateway` antes de la
regla general `/openmrs`. Esta ruta requiere el servicio opcional
`mpi-admission-gateway` configurado en el ambiente; el proxy por sí solo no
instala el gateway ni habilita MPI. Las credenciales del gateway permanecen
en el servidor. El proxy de `.225` usa su OpenMRS local; el proxy dev normal
continúa apuntando a `.205`.
