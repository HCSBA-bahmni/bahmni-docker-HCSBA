# OpenMRS local aislado para SSO

Este perfil ejecuta OpenMRS y MySQL en localhost usando una copia transaccional de la base
compartida. Nunca conecta la instancia local al esquema activo de `.205` y no modifica los
volumenes remotos.

## Garantias de aislamiento

- MySQL 8.0.46 y OpenMRS 1.1.2 estan fijados por digest.
- La importacion valida las etiquetas `project`, `service` y `hcsba.environment=local-isolated`
  antes de eliminar o reemplazar un esquema.
- Scheduler, publicacion de atom feeds, correo y SMS se desactivan en la copia.
- OpenELIS no se enruta al servidor compartido en modo `LOCAL_OPENMRS`.
- Los metadatos ya presentes en el snapshot no se vuelven a importar mediante Initializer/OCL.
- Snapshots, estado y secretos quedan ignorados por Git.
- `remote` restaura el proxy a `.205` sin eliminar volumenes locales.

## Primer arranque

Desde `bahmni-docker-HCSBA`:

```powershell
.\local-openmrs.ps1 init
.\local-openmrs.ps1 dev-cert
.\local-openmrs.ps1 snapshot
.\local-openmrs.ps1 import
.\local-openmrs.ps1 up
.\local-openmrs.ps1 verify
.\sso.ps1 plan-local-users
.\sso.ps1 sync-local-users
.\sso.ps1 validate-local-users
```

La sincronizacion local lee exclusivamente identidad, roles, Provider y ubicaciones desde el
clon aislado; no necesita ni cambia contrasenas OpenMRS. Las claves temporales quedan en el
directorio ignorado `bahmni-standard/keycloak/generated/user-sync/initial-passwords.csv`.
Cuando no hay atributos `Login Locations` por Provider, conserva el fallback legacy que ofrece
todas las ubicaciones activas con el tag `Login Location`.

El dump contiene informacion clinica/PII y se guarda en
`bahmni-standard/openmrs-local/snapshots/`. No debe copiarse ni publicarse fuera del entorno
autorizado.

Para reemplazar una copia existente se exige confirmacion explicita y se crea primero un
respaldo local:

```powershell
.\local-openmrs.ps1 import -ConfirmReplace
```

## Preparacion del navegador

El hostname del realm se mantiene igual al contrato DEV: `sso-dev.hcsba.local`. Una vez por
equipo:

1. Agregar como administrador al archivo de hosts de Windows:

   ```text
   127.0.0.1 sso-dev.hcsba.local
   ```

2. Confiar solo para desarrollo en
   `bahmni-standard/keycloak/tls/local-dev-ca-cert.pem`, o aceptar manualmente la advertencia del
   navegador. El certificado de servidor cubre `localhost`, `127.0.0.1` y
   `sso-dev.hcsba.local`; dura 30 dias y no se usa en ambientes compartidos.

3. Abrir `https://localhost/bahmni/login`.

Sin el alias de hosts, las comprobaciones automatizadas siguen funcionando con `curl --resolve`,
pero el navegador no puede completar la redireccion a Keycloak.

## Operacion

```powershell
.\local-openmrs.ps1 status
.\local-openmrs.ps1 logs
.\local-openmrs.ps1 verify
.\local-openmrs.ps1 remote  # proxy nuevamente hacia .205
.\local-openmrs.ps1 down    # detiene el backend local; preserva datos
```

No se usa `docker compose down -v`: los volumenes se conservan intencionalmente.
