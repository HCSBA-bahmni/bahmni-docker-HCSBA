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
