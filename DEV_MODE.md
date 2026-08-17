# Entorno de desarrollo HCSBA Bahmni

Este entorno ejecuta `bahmni-nextjs-hcsba` con Fast Refresh dentro de Docker y conserva el mismo origen de la instalacion integrada: `https://localhost`. Apache dirige OpenMRS al ambiente HCSBA `.205`, sirve la configuracion local y mantiene las aplicaciones legacy disponibles para comparar paridad.

El script usa el nombre de proyecto Compose fijo `bahmni-hcsba-dev`. Esto evita mezclar o eliminar contenedores de otros workspaces que tambien tengan un directorio llamado `bahmni-standard`.

## Repositorios

Todos deben quedar como directorios hermanos dentro del mismo workspace.

| Repositorio | Rama de trabajo | Uso en desarrollo |
| --- | --- | --- |
| `bahmni-docker-HCSBA` | `master` | Compose, proxy, certificados y scripts del entorno. |
| `bahmni-nextjs-hcsba` | `main` | Frontend Next.js con Fast Refresh. |
| `standard-config-HCSBA` | `master` | Configuracion, formularios, traducciones y overrides HCSBA. |
| `openmrs-module-bahmniapps-hcsba-2024` | `master` | Referencia AngularJS y fallback legacy montado por Apache. |
| `openmrs-module-ipd-frontend-hcsba-2024` | `main` | Referencia ejecutable de IPD/Care View legacy. |
| `openmrs-module-ipd` | `hcsba/1.1.1-fix-ward-patients` | Codigo del OMOD IPD cuando se modifican contratos backend. No se monta en caliente. |

El script usa las URLs publicas de la organizacion `HCSBA-bahmni` y clona automaticamente cualquier repositorio ausente.

## Requisitos

- Windows 10/11 con PowerShell 5.1 o superior.
- Git y Docker Desktop con Docker Compose v2.
- Acceso a la red interna `10.68.174.0/24` y al OpenMRS `.205`.
- Puertos locales 80 y 443 libres.
- Acceso de lectura a los repositorios HCSBA.

## Primera instalacion en una maquina limpia

```powershell
git clone https://github.com/HCSBA-bahmni/bahmni-docker-HCSBA.git
cd bahmni-docker-HCSBA
.\dev-environment.ps1 bootstrap
.\dev-environment.ps1 up
```

`bootstrap` realiza lo siguiente sin sobrescribir archivos locales existentes:

1. Clona los otros cinco repositorios como hermanos.
2. Crea `bahmni-standard/.env` desde `.env.dev` y aplica los valores de integracion HCSBA.
3. Crea `bahmni-nextjs-hcsba/.env.local` desde `.example-env`.
4. Instala las dependencias de la aplicacion legacy con Node 10 si faltan.

El primer inicio ejecuta `npm ci` dentro del volumen Docker de Next.js. Luego la aplicacion queda disponible en `https://localhost/bahmni`.

## Trabajo diario

```powershell
# Levantar o reconciliar toda la pila de desarrollo
.\dev-environment.ps1 up

# Ver estado
.\dev-environment.ps1 status

# Seguir proxy, configuracion y Next.js
.\dev-environment.ps1 logs

# Verificar rutas, OpenMRS y WebSocket de Fast Refresh
.\dev-environment.ps1 verify

# Bajar la pila sin borrar volumenes
.\dev-environment.ps1 down

# Bajar, recrear y volver a verificar todo
.\dev-environment.ps1 recreate
```

Los cambios guardados en `bahmni-nextjs-hcsba/src` se reflejan mediante Fast Refresh. El contenedor usa `next dev --webpack` y Watchpack con polling porque Turbopack no observa de forma confiable los bind mounts de Docker Desktop sobre Windows. No ejecute `yarn dev` adicionalmente mientras el contenedor `bahmni-next-web` este activo.

Para ejecutar Next.js directamente en el host, detenga solo ese servicio, copie `.example-env` como `.env.local` y use `npm run dev -- --hostname 0.0.0.0`. Para mantener sesion, configuracion y rutas same-origin se recomienda el compose; un servidor en otro puerto requiere proxy adicional y cookies compatibles.

## Topologia

- `proxy`: termina HTTPS, enruta las aplicaciones y eleva `/bahmni/_next/webpack-hmr` como WebSocket.
- `bahmni-next-web`: Node 24 Alpine, codigo montado desde el host y dependencias en volumen nombrado.
- `bahmni-config`: sirve `standard-config-HCSBA` desde el checkout local.
- `bahmni-web`: conserva AngularJS para referencia y rutas que aun no han sido cortadas.
- `ipd`: conserva el microfrontend legacy como referencia/rollback.
- OpenMRS: se consume remotamente desde `https://10.68.174.205/openmrs`; no se duplica su base de datos en el equipo de frontend.

El OMOD construido desde `openmrs-module-ipd` requiere build y despliegue controlado en OpenMRS. Reiniciar el compose frontend no despliega OMODs.

## Variables de entorno

Las variables del navegador estan documentadas en `bahmni-nextjs-hcsba/.example-env`. Solo contienen rutas same-origin y flags publicos. Credenciales de base de datos, correo u otros servicios pertenecen a `bahmni-standard/.env` y nunca deben agregarse como `NEXT_PUBLIC_*`.

La sesion se inicia normalmente desde `https://localhost/bahmni/login`; el proxy conserva las cookies de OpenMRS para todas las rutas Next y legacy.

## Comprobacion manual minima

1. Abrir `https://localhost/bahmni` y aceptar el certificado local si el navegador lo solicita.
2. Iniciar sesion y entrar a Clinico y Camas.
3. Editar un texto o estilo en `bahmni-nextjs-hcsba/src`; la pagina debe actualizarse sin reconstruir imagen ni pulsar F5.
4. Confirmar que `https://localhost/openmrs/ws/rest/v1/session` responde y que las configuraciones se leen desde `/bahmni_config`.
5. Comparar cualquier escritura clinica contra legacy antes de modificar payloads o endpoints.

## Recuperacion

El comando `down` no usa `-v`, por lo que conserva cache de Next y volumenes. Para volver temporalmente a la imagen versionada de Next use `bahmni-standard/next-dev.ps1 restore`. Para eliminar cache de dependencias debe hacerse de forma explicita y nunca junto con datos clinicos.
