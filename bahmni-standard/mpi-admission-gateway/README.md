# Gateway de admisión MPI

Sirve `/openmrs/mpi-admission-gateway/fhir/Patient?identifier=<RUN>`, `GET /_identity` y, en modo `integrated`, `POST /_match` y `POST /_sync/<UUID>` bajo el mismo prefijo. Valida la cookie `JSESSIONID` contra la sesión OpenMRS y exige el privilegio `Add Patients` antes de usar la credencial OpenHIM del archivo secreto. Reenvía las cabeceras `X-MPI-*` que el formulario necesita. Los documentos/demografía viajan en el cuerpo de matching y la decisión firmada viaja en sync; no se registran en logs.

Desde el 19-10-2026, Registro usa matching de OpenCR antes de guardar, incluso sin RUN. El gateway limita los cuerpos JSON a 32 KiB, exige mismo origen y genera `X-MPI-Actor` desde la sesión validada. OpenHIM conserva esa cabecera hasta el mediador. La revisión humana y la firma se resuelven en Registro/mediador; el gateway no inventa coincidencias ni puntajes. En `.225` las imágenes Next y gateway están fijadas en `2026.10.19-mpi-identity.1`.

## Visor de demostración

`/openmrs/mpi-admission-gateway/demo.html` es un HTML autónomo, protegido por la misma sesión y privilegio. Al ingresar un RUN llama a `GET /demo/data?run=<RUN>` y presenta ocho operaciones reales: búsqueda de identidad por el canal de admisión de OpenHIM, lectura PDQm por CRID, búsqueda demográfica PDQm local por apellido/fecha, tres traducciones PIXm (CRID, identificador clínico y UUID de ficha del dominio `.225`), búsqueda de `Patient` persistidos en HAPI FHIR y búsqueda de ficha en OpenMRS FHIR2. Muestra la ruta, estado, duración, identificadores y JSON FHIR de cada respuesta. El gateway también permite GET demográfico validado y lectura por CRID desde el mismo origen. Si una fuente solo conoce el año de nacimiento, el visor usa la fecha completa de la lectura por CRID cuando existe; de otro modo busca por nombre sin inventar mes ni día.

El PDQm actual es un subconjunto JSON de ITI-78: `family`, `given`, `birthdate`, `gender`, GET/POST `_search` en el mediador y lectura por CRID. No declara conformidad completa con IHE; no consulta MINSAL.

Desde el 16-10-2026 el adaptador nacional de `.227` usa el MPI oficial productivo mediante OpenHIM
`.206`; API Persona oficial queda como contingencia. El gateway y el navegador conservan el mismo
contrato FHIR. La búsqueda demográfica PDQm y las traducciones PIXm de esta página son operaciones
del MPI **local**, no llamadas al MPI nacional. Una consulta local vigente puede no salir a MINSAL
por la ventana de refresco; el encabezado `X-MPI-Decision` permite comprobarlo.

El navegador nunca recibe credenciales OpenHIM ni acceso directo a HAPI por API. El gateway consulta destinos configurados, sin URL arbitraria, con rutas y métodos permitidos explícitamente. Las respuestas usan `Cache-Control: no-store`. HAPI se configura en el contenedor con `MPI_HAPI_FHIR_BASE_URL`; OpenMRS se consulta por HTTPS con la misma cookie de sesión. El botón superior a HAPI abre su interfaz de desarrollo existente para mostrarla aparte.

En `preview`, el POST está prohibido. En `integrated`, el gateway exige HTTPS hacia OpenHIM y valida su certificado con una CA montada. El navegador solo conoce la ruta del mismo origen.

Para el desarrollo integrado, configurar en `bahmni-standard/.env`:

```text
MPI_ADMISSION_MODE=integrated
MPI_OPENHIM_BASE_URL=https://10.68.174.206:5000
MPI_OPENHIM_CLIENT_ID=bahmni-registro-lab
MPI_OPENHIM_PASSWORD_FILE=<ruta absoluta ignorada por Git al archivo de clave del cliente>
```

El certificado público de OpenHIM va en `private/openhim-dev-ca.pem`; `MPI_OPENHIM_TLS_SERVERNAME=localhost` corresponde al certificado actual de `.206`. Después ejecutar `dev-environment.ps1 up` y `dev-environment.ps1 verify`. Si cambia `server.mjs`, reconstruir la imagen con `docker compose ... up -d --build --no-deps mpi-admission-gateway`; `up` puede reutilizar una imagen anterior. El script agrega `docker-compose.mpi-admission.yml` únicamente cuando el modo es `preview` o `integrated`. La credencial no va en `.env`, en el frontend ni en Git. El gateway usa la CA local para validar Apache y una CA separada para OpenHIM.

Prueba manual: entrar en `https://10.68.174.225/bahmni/registration/patient/new` con una cuenta que tenga `Add Patients`, consultar un RUN autorizado por su titular y comparar la tarjeta MPI con el visor de demostración. No usar los RUN sintéticos del mock para verificar el MPI productivo. En caso de 401, comprobar primero sesión y privilegio OpenMRS; el gateway no acepta credenciales del navegador para OpenHIM.

Pruebas del gateway: `node --test server.test.mjs`.

## Revisión diferida de identidad

La entrega `2026.10.19-mpi-queue.4` permite `/_reviews`, `/_reviews/{id}`, `/_reviews/{id}/prepare` y `/_reviews/{id}/resolve` sólo en modo integrado. El listado general (también paginado con `offset`) y las acciones de preparación/resolución requieren el privilegio activo **Manage MPI Identity Reviews** de la sesión OpenMRS. La consulta acotada por `patientUuid` y el envío de una propuesta permanecen disponibles para admisión.

El gateway sobrescribe `X-MPI-Actor` y `X-MPI-Identity-Manager` con la identidad y el permiso comprobados en servidor. Las cabeceras del navegador no elevan permisos. Un `review.caseId` en `/_sync/{uuid}` activa una propuesta durable después de verificar la ficha; no adjudica desde admisión.

La cola y la auditoría se conservan en el volumen persistente del mediador. No borrar el volumen para revertir una imagen. Contrato: `mediadores-mpi/docs/MPI-REVISION-DIFERIDA-2026-10-19.md`. Perfiles: `bahmni-nextjs-hcsba/docs/migration/registration-demo-role.md`.
