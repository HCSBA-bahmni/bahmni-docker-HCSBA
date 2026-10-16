# Despliegue de integración `.225`

Esta capa conserva el OpenMRS, OpenELIS, Odoo, PACS, formularios, OMODs y
volúmenes existentes del host `10.68.174.225`. Agrega la imagen standalone de
Next.js y el servicio biométrico sin publicar sus puertos, y corta las rutas
migradas mediante el proxy HTTPS existente.

Se utiliza junto con el Compose base personalizado del host:

```sh
docker compose --project-name bahmni-standard --env-file .env \
  -f docker-compose.yml -f docker-compose.production-225.yml config --quiet
```

Variables locales obligatorias (no versionar sus valores):

- `BAHMNI_NEXT_WEB_IMAGE_TAG`
- `BIOMETRIC_API_IMAGE_TAG`
- `BIOMETRIC_POSTGRES_PASSWORD`
- `BIOMETRIC_API_KEY`
- `NEXT_PROXY_DEFINES`

El directorio `tls/` no se versiona. Debe contener `cert.pem` y `key.pem`; el
certificado debe cubrir el nombre o IP real que usan los clientes. Antes de un
corte se respaldan de forma consistente `openmrs` y `eis_identity`, se valida
el OMOD EIS, y se construyen todas las imágenes con etiquetas inmutables.

Las imágenes HCSBA se publican en GitHub Container Registry:

- `ghcr.io/hcsba-bahmni/bahmni-next-web`
- `ghcr.io/hcsba-bahmni/standard-config`
- `ghcr.io/hcsba-bahmni/mpi-biometric-api`
- `ghcr.io/hcsba-bahmni/mpi-biometric-db`
- `ghcr.io/hcsba-bahmni/openmrs-eis`
- `ghcr.io/hcsba-bahmni/bahmni-proxy`

El proxy empaqueta su configuración, pero nunca los certificados ni secretos.
La imagen de base biométrica incluye únicamente el inicializador de esquema;
los embeddings permanecen en un volumen PostgreSQL externo.

La reversa de frontend consiste en retirar del proxy los defines `NEXT_*` y
recrear únicamente `proxy`; el fallback `/bahmni` permanece en AngularJS. La
reversa EIS sigue el orden documentado en `EIS_REGISTRATION.md`: quitar primero
la referencia al validador y sólo después retirar el OMOD.

## Admisión MPI integrada (06-10-2026)

El despliegue activo suma `production-225/docker-compose.mpi-admission.yml` al
Compose anterior. La entrega inicial usó `hcsba/bahmni-next-web:2026.10.06-mpi.1`,
agrega `hcsba/mpi-admission-gateway:2026.10.06.5` y publica el gateway bajo
`/openmrs/mpi-admission-gateway`. El gateway consulta el canal aislado
`/mpi225-admision` de OpenHIM `.206`, dirigido al mediador `.227:8533`; ese
mediador sincroniza con el OpenMRS **de `.225`**, no con el de `.205`.

El visor HTML de la presentación está en
`https://10.68.174.225/openmrs/mpi-admission-gateway/demo.html`. Usa la sesión
de la cuenta de Registro, lee PDQm local y PIXm por OpenHIM y recursos FHIR de
HAPI/OpenMRS, sin exponer credenciales al navegador. El PDQm implementado es
un subconjunto JSON de ITI-78; `mpi-local-mediator/README.md` enumera sus límites.
La imagen Next activa `hcsba/bahmni-next-web:2026.10.06-mpi-link.1` añade
**Comprobar flujo MPI** en búsqueda, alta y edición de Registro. Abre el visor
en otra pestaña sin poner el RUN en la URL.

El 16-10-2026 se conectó el mediador nacional `.227` al MPI oficial productivo
mediante los canales separados de OpenHIM `.206`. API Persona quedó como
contingencia. El gateway `hcsba/mpi-admission-gateway:2026.10.16-mpi-prod.1`
actualiza el texto del visor para reflejar este origen; el contrato del gateway
y la imagen Next no cambiaron. La verificación de admisión con refresco obtuvo
una identidad desde MINSAL y la segunda consulta leyó la copia local vigente.

```sh
docker compose --project-name bahmni-standard --env-file .env \
  -f docker-compose.yml -f docker-compose.production-225.yml \
  -f production-225/docker-compose.mpi-admission.yml \
  ps proxy bahmni-next-web mpi-admission-gateway
```

`production-225/mpi/private/` contiene la clave de cliente y CA montadas en el
gateway; no se versionan. El archivo `production-225/bahmni-proxy.conf.bak-20261006`
conserva la versión anterior para reversa. La configuración EIS remota y el OMOD
se mantuvieron. El recorrido, las pruebas y el resto de la reversa están en
`mediadores-mpi/docs/DESPLIEGUE-BAHMNI-225-MPI-2026-10-06.md`.

## Entrega de permisos de Registro (06-10-2026)

El frontend activo es `hcsba/bahmni-next-web:2026.10.06-registro.1` y conserva
MPI en modo `integrated`. Este host y todos los ambientes actuales son de
desarrollo, según confirmación del usuario. El Compose remoto está en
`/home/arki/bahmni/bahmni-docker-HCSBA/bahmni-standard`.

La imagen se transfirió como archivo Docker con SHA-256
`120976b51e0e45465768d62a269b70166c7872e003a901407d316e1ae7dea02a`.
Se cambió el tag de Next en `.env` y en el overlay MPI, y se ejecutó `up -d
--no-deps --no-build --pull never bahmni-next-web` con los tres archivos Compose
indicados arriba. Solo se recreó Next; los demás contenedores conservaron sus
IDs. El servicio quedó `healthy`, y los endpoints públicos de salud de Next y
biometría respondieron HTTP 200. Las 15 pruebas de perfiles y acceso directo
pasaron contra la imagen remota en Chromium, Firefox y Edge.

La cuenta `demo.registro` autentica y muestra únicamente Registro, tanto en
Inicio como en la navegación. Su ubicación disponible es `Registration Desk`.
Las credenciales se guardan en `.local/development-access.json` del workspace
local, excluido de Git; la guía del rol está en
`bahmni-nextjs-hcsba/docs/migration/registration-demo-role.md`.

Para reversa, se conservaron la imagen `2026.10.06-mpi.1` y las copias de los
dos archivos modificados en
`production-225/releases/2026.10.06-registro.1/` del host. Restaurar
`docker-compose.mpi-admission.yml.before` al overlay MPI y `environment.before`
a `.env`, validar `config --quiet` y recrear solamente `bahmni-next-web` con
la misma composición. La carpeta de respaldos tiene acceso restringido y no
se debe versionar su archivo de entorno.

## Interfaz visual y Registro MPI (16-10-2026)

La imagen activa de Next.js es `hcsba/bahmni-next-web:2026.10.16-visual-mpi.2`
(commit `7905574`, imagen `sha256:edb3ff6dea23279781d0933c025abfe4139ce87e9f6c12569f78771f35932399`).
Integra el sistema visual nuevo con el flujo de admisión MPI y corrige el desborde
horizontal del pie de Registro en ancho de tableta. El gateway sigue en
`hcsba/mpi-admission-gateway:2026.10.16-mpi-prod.1`.

El checkout Next.js de `.225` está en `7905574` y la configuración fuente en
`0c4c621`. Se recreó solo `bahmni-next-web` con los tres archivos Compose; el
proxy, gateway, OpenMRS y los volúmenes clínicos no se recrearon. Posteriormente
se actualizó también `bahmni-config`, según la entrega documentada abajo.

La validación incluyó build standalone, 596 pruebas unitarias, 33 pruebas E2E
en Chromium contra `.225`, healthcheck `healthy`, y HTTP 200 en salud y rutas de
Registro. Para volver al tag anterior, en `.225` se guardó el overlay previo en
`production-225/docker-compose.mpi-admission.yml.bak-20261016-v1`. Restaurarlo,
validar `config --quiet` y recrear solo `bahmni-next-web` con `--no-deps
--no-build --pull never`.

## Configuración compartida actualizada (16-10-2026)

La imagen activa es `hcsba/standard-config:2026.10.16-config.1`, construida en
`.225` desde `standard-config-HCSBA` commit `0c4c621` con
`package/docker/Dockerfile`. Su identificador es
`sha256:cff45831c7e363a497d72a3dd9568177a8230010141b3787aaa546a640af80b1`.
El archivo `.env` remoto selecciona `CONFIG_IMAGE_TAG=2026.10.16-config.1`.

Antes del cambio se comprobó que el volumen compartido coincidía exactamente
con la imagen anterior, sin ajustes exclusivos del host. Se validaron los 60
archivos modificados: 30 JSON, 26 CSV, 2 XML, un ZIP y el JavaScript de
validación (con `node --check`). Después de recrear solo
`bahmni-config`, los 310 archivos del volumen coincidieron por SHA-256 con las
fuentes, y cinco rutas públicas de configuración y traducciones respondieron
HTTP 200 con los mismos bytes del repositorio.

Las cinco pruebas E2E de permisos de Registro pasaron contra `.225`. La sesión
real de OpenMRS, el visor MPI autenticado, la salud de Next y la ruta de alta
respondieron HTTP 200. Los demás contenedores conservaron sus identificadores.
Los archivos de masterdata quedan disponibles en el volumen; esta entrega no
reejecuta el importador de masterdata sobre la base de OpenMRS.

El respaldo privado está en
`/home/arki/bahmni/backups/standard-config-20261016/`: incluye `environment.before`,
`config-before.tgz`, inventarios y las verificaciones. El SHA-256 del archivo de
configuración respaldado es
`bfe2fc464608bc4a35363784f1d1b9311ee0650d99cf01d2326bf1ccd60243e9`.
Para reversa, seleccionar `CONFIG_IMAGE_TAG=2026.09.23-eis.1`, validar el Compose
con los mismos tres archivos y recrear solo `bahmni-config` usando
`up -d --no-deps --no-build --pull never bahmni-config`.
