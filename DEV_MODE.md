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
| `openmrs-module-oauth2login-hcsba` | `hcsba/1.5.0-keycloak` | Fork reproducible del OMOD OAuth2. Se construye y despliega de forma controlada. |

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

El primer inicio ejecuta `npm ci` dentro del volumen Docker de Next.js. Luego la aplicacion queda disponible directamente en `https://localhost`: el proxy envia la raiz a `/bahmni/home/` y Next.js inicia Keycloak si no existe una sesion OpenMRS valida.

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

- `proxy`: termina HTTPS, enruta las aplicaciones y eleva `/bahmni/_next/webpack-hmr` como WebSocket. Los defines `NEXT_DOCUMENT_UPLOAD`, `NEXT_ORDERS` y `NEXT_ADMIN_AUDIT_LOG` dirigen esos módulos a sus rutas Next.js; `/bahmni/admin-legacy` conserva el rollback de Administración.
- `bahmni-next-web`: Node 24 Alpine, codigo montado desde el host y dependencias en volumen nombrado.
- `bahmni-config`: sirve `standard-config-HCSBA` desde el checkout local.
- `bahmni-web`: conserva AngularJS para referencia y rutas que aun no han sido cortadas.
- `ipd`: conserva el microfrontend legacy como referencia/rollback.
- OpenMRS: se consume remotamente desde `https://10.68.174.205/openmrs`; no se duplica su base de datos en el equipo de frontend.

El OMOD construido desde `openmrs-module-ipd` requiere build y despliegue controlado en OpenMRS. Reiniciar el compose frontend no despliega OMODs.

## Variables de entorno

Las variables del navegador estan documentadas en `bahmni-nextjs-hcsba/.example-env`. Solo contienen rutas same-origin y flags publicos. Credenciales de base de datos, correo u otros servicios pertenecen a `bahmni-standard/.env` y nunca deben agregarse como `NEXT_PUBLIC_*`.

La entrada canonica es `https://localhost`. El proxy la dirige a `/bahmni/home/`; si no hay sesion, Next.js pasa por `/bahmni/login` e inicia el flujo configurado (`openmrs` o `keycloak`). El proxy conserva las cookies de OpenMRS para todas las rutas Next y legacy.

## Perfil SSO opcional

Keycloak está desactivado por defecto y `AUTH_MODE=openmrs` conserva el login/OTP actual. Para levantar únicamente la infraestructura SSO de prueba use `..\sso.ps1 up` y `..\sso.ps1 verify-internal` desde `bahmni-docker-HCSBA`. La guía completa, compuertas de corte y reversa están en [KEYCLOAK_SSO.md](KEYCLOAK_SSO.md).

La consola web de administración debe abrirse mediante el mismo hostname TLS del SSO en `https://sso-dev.hcsba.local/admin/master/console/`; el puerto loopback `18080` queda reservado para automatizaciones porque no coincide con el hostname canónico generado por Keycloak.

### Selección explícita del modo de autenticación

Los modos se seleccionan por el archivo de entorno y los overlays Compose que se levantan; no se deben mezclar:

| Modo | Backend OpenMRS | Autenticación | Entrada y uso |
| --- | --- | --- | --- |
| Desarrollo liviano diario | Compartido `.205` | Login/OTP OpenMRS | `bahmni-standard/.env` mantiene `AUTH_MODE=openmrs`; usar `.\dev-environment.ps1 up`. Keycloak, PostgreSQL y el clon OpenMRS local permanecen apagados. |
| Laboratorio SSO aislado | Clon y base local | Keycloak | `bahmni-standard/.env.openmrs-local` mantiene `AUTH_MODE=keycloak`; usar `.\local-openmrs.ps1 up` y `.\local-openmrs.ps1 verify`. |
| Despliegue SSO controlado | OpenMRS del ambiente destino | Keycloak | Configurar `AUTH_MODE=keycloak` y hostnames en `.env.keycloak`, desplegar el OMOD OAuth2 y sus propiedades en ese OpenMRS y ejecutar `.\sso.ps1 integrate` siguiendo `KEYCLOAK_SSO.md`. |

Para salir del laboratorio local y recuperar el modo liviano sin perder bases, usuarios, realm ni snapshots:

```powershell
.\local-openmrs.ps1 remote
.\local-openmrs.ps1 down
.\sso.ps1 down
.\dev-environment.ps1 verify
```

`remote` restaura el proxy y Next.js con el archivo base (`AUTH_MODE=openmrs`) apuntando a `.205`. Los dos comandos `down` eliminan solamente los contenedores opcionales; no usan `-v` y conservan todos sus volúmenes. Para reactivar el laboratorio SSO basta con:

```powershell
.\local-openmrs.ps1 up
.\local-openmrs.ps1 verify
```

Cambiar sólo `AUTH_MODE` modifica el flujo visible de Next.js, pero no instala ni retira el OMOD OAuth2 de OpenMRS. Por eso una promoción o reversa productiva debe seguir siempre las compuertas de `KEYCLOAK_SSO.md`; el script del laboratorio local no se utiliza como mecanismo de despliegue productivo.

## Comprobacion manual minima

1. Abrir `https://localhost` y aceptar el certificado local si el navegador lo solicita. Sin una sesion activa debe comenzar el login configurado.
2. Iniciar sesion y entrar a Clinico y Camas.
3. Editar un texto o estilo en `bahmni-nextjs-hcsba/src`; la pagina debe actualizarse sin reconstruir imagen ni pulsar F5.
4. Confirmar que `https://localhost/openmrs/ws/rest/v1/session` responde y que las configuraciones se leen desde `/bahmni_config`.
5. Comparar cualquier escritura clinica contra legacy antes de modificar payloads o endpoints.

## Recuperacion

El comando `down` no usa `-v`, por lo que conserva cache de Next y volumenes. Para volver temporalmente a la imagen versionada de Next use `bahmni-standard/next-dev.ps1 restore`. Para eliminar cache de dependencias debe hacerse de forma explicita y nunca junto con datos clinicos.
