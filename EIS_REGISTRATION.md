# Registro EIS Chile HCSBA

Esta integración porta el registro de pacientes de HealthMesh Chile sin convertir
el RUN en número de ficha. En HCSBA el identificador preferido sigue siendo
`Patient Identifier`, generado con prefijo `HCSBA`; RUN, pasaporte y los demás
documentos EIS son identificadores adicionales gobernados.

## Componentes

| Repositorio | Responsabilidad |
| --- | --- |
| `standard-config-HCSBA` | conceptos EIS 820, atributos, tipos de identificador, jerarquía territorial, configuración legacy/v2, traducciones y preflight |
| `openmrs-module-eis-identity-hcsba` | validador RUN autoritativo, unicidad por namespace, API y esquema `eis_identity` |
| `bahmni-nextjs-hcsba` | formulario, segundo apellido, metadatos documentales, búsqueda, impresión y consumidores clínicos |
| `bahmni-docker-HCSBA` | montaje reproducible del OMOD, migración del esquema satélite, respaldo conjunto y verificación local |

Las fuentes externas están fijadas en `standard-config-HCSBA/docs/eis-registration-migration.md`.
La variante HCSBA validada corresponde al commit `c092b6d`; el artefacto local
`eisidentity-0.1.1-hcsba.1-SNAPSHOT.omod` produjo SHA-256
`7804A46486AD02A58F3CC37685BCC99A38B83F40A668577565840607A148E9A5`.

## Laboratorio local aislado

1. Construir el OMOD desde `openmrs-module-eis-identity-hcsba` con Java 8:

   ```powershell
   docker run --rm -v "${PWD}:/module" -w /module maven:3.9-eclipse-temurin-8 mvn -B -ntp clean verify
   ```

2. Inicializar o actualizar el clon local:

   ```powershell
   .\local-openmrs.ps1 init
   .\local-openmrs.ps1 up
   .\local-openmrs.ps1 verify
   ```

`up` aplica las migraciones idempotentes antes de iniciar OpenMRS y monta el OMOD
como sólo lectura. `verify` comprueba tabla, índice y la collation contra la columna
histórica `openmrs.patient_identifier.uuid`. Los snapshots y
respaldos locales incluyen `openmrs` y, cuando existe, `eis_identity`.

## Promoción controlada

El entorno de desarrollo no despliega automáticamente a `.205`. Antes de una
promoción autorizada deben cumplirse estas compuertas:

1. Ejecutar el preflight de sólo lectura
   `standard-config-HCSBA/db/preflight/eis-registration.sql` desde un host con ACL
   MySQL válida y guardar su resultado sin datos personales.
2. Resolver colisiones de UUID/nombre y confirmar que la fuente IDGen `HCSBA` no
   modifica la fuente histórica `RUT*`.
3. Tomar respaldos consistentes del esquema `openmrs` y de `eis_identity` en el
   mismo punto temporal.
4. Construir y verificar el OMOD; registrar el hash SHA-256 del artefacto.
5. Ejecutar `openmrs-module-eis-identity-hcsba/db/apply.sh` con credenciales de
   administración por archivo y `EIS_IDENTITY_GRANTEE=openmrs-user`.
6. Instalar/iniciar el OMOD y verificar el endpoint autenticado
   `/ws/rest/v1/eisidentity/identifier-metadata`.
7. Importar la configuración maestra. Revisar expresamente el `wipe=true` de la
   jerarquía territorial antes de permitir su ejecución.
8. Validar en una cohorte sintética: paciente sin RUN, RUN válido/inválido,
   pasaporte con país y expiración, documento extranjero, segundo apellido,
   ISAPRE y búsqueda por identificadores adicionales.
9. Habilitar `NEXT_REGISTRATION` sólo después de comparar los payloads y las
   lecturas con legacy.

## Reversa sin pérdida

1. Retirar el corte `NEXT_REGISTRATION` y volver a legacy.
2. Desactivar la referencia al validador RUN antes de detener el OMOD.
3. Restaurar el prefijo anterior sólo para nuevas fichas; no renumerar pacientes.
4. No borrar tipos, fuentes IDGen, conceptos ni metadatos como parte de una
   reversa funcional.
5. Si se restaura base de datos, restaurar `openmrs` y `eis_identity` como una
   sola unidad y ejecutar la verificación de huérfanos.
