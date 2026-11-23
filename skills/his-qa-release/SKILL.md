---
name: his-qa-release
description: Preparar, ejecutar y documentar QA por desarrollo de Bahmni/Next.js HCSBA y por entrega a 10.68.174.225, con aceptación ponderada, evidencia, esperado/obtenido y sugerencias de solución. Usar junto a bahmni-nextjs-migration en cambios funcionales y entregas; no para otros HIS ni para certificar módulos sin pruebas reales.
---

# QA HIS y entregas .225

## Fuentes y alcance

Localizar el checkout `bahmni-nextjs-hcsba` en el workspace, sin asumir una ruta ni un sistema operativo. Si se trabaja desde otro repositorio HCSBA, usar un checkout hermano o la ubicación indicada por el contribuyente. Leer su `docs/qa/pauta-qa.md` antes de preparar o evaluar una campaña. Allí viven la política, campos, comandos y límites. Usar `docs/qa/catalogo.json` y `scripts/qa-release.mjs`, sin duplicar el scoring en cálculos ad hoc. Si faltan esos recursos, localizar el checkout o informar la dependencia faltante; no inventar resultados.

Para instalar el paquete completo, usarlo desde cualquiera de los repositorios y mantener sus copias, leer [references/contributors.md](references/contributors.md). La política, el catálogo y el harness se ejecutan desde `bahmni-nextjs-hcsba`; las copias de la skill en los demás repositorios no contienen otro motor QA.

Aplicar también `bahmni-nextjs-migration` y las instrucciones del entorno antes de probar o desplegar. `.225` es desarrollo y, desde el cambio autorizado el 2026-11-04, el frontend integrado local también usa `.225` por proxy. Una campaña cubre su alcance y revisión; no acredita el HIS completo.

## Trabajo por cambio

1. Revisar cambios y caracterizar requisitos/contratos legacy. Crear pauta con `npm run qa:init -- <pauta.json>` antes de las pruebas; ampliar casos del catálogo por operación, perfil, estado, consumidor y navegador relevantes. Definir esperado antes de obtener resultados. Justificar NO_APLICA sólo para casos condicionales.
2. Ejecutar PRE usando las pruebas y compuertas existentes. Registrar obtenido, evidencia anonimizada, modo REAL/SIMULADO/ARTEFACTO, entorno, revisión, fecha y ejecutor. Una prueba omitida queda pendiente/bloqueada. Si falla o se bloquea, documentar sugerencia concreta y responsable; distinguir hipótesis de causa demostrada.
3. Generar informe PRE con `npm run qa:report -- <pauta.json> <carpeta-nueva> PRE`. La política inicial requiere 95% de aceptación ponderada, 100% de ejecución, compuertas/P0/P1 aprobados y ningún hallazgo P0/P1 abierto. No rebajar riesgo ni cambiar umbrales después de probar para conseguir aprobación.
4. Cuando el encargo incluya entrega, usar el flujo de despliegue del proyecto con revisión/manifest, imagen inmutable y reversión. Inspeccionar scripts reales antes de ejecutarlos: algunos crean datos o perfiles. Esta pauta no autoriza operaciones adicionales en OpenMRS/DB/roles ni escrituras clínicas ajenas al ensayo. No desplegar automáticamente por un exit code del harness.
5. Registrar imagen/revisión/hora observadas y ejecutar POST en `https://10.68.174.225`. Casos que exigen REAL no se aprueban con mocks, lecturas aisladas o evidencia local. Verificar lectura posterior y auditoría de escrituras, perfiles reales y estado final de datos sintéticos. Releer estado durable ante respuestas ambiguas antes de recuperar.
6. Generar informe POST en otra carpeta. Exige PRE aprobado, misma revisión/imagen y pruebas posteriores al despliegue. Conservar corridas previas y reusar IDs en repeticiones; una corrección de código inicia una campaña de nueva revisión, sin heredar aprobados antiguos.

## Entrega

Devolver dictamen PRE/POST, aceptación y ejecución separadas, lo realmente probado, pendientes y hallazgos con sugerencias, más enlaces al HTML y CSV. No confundir QA con aprobación clínica/regulatoria ni declarar probado lo que sólo se planificó. El harness valida registros y porcentajes; el ejecutor debe revisar las evidencias.

### HTML claro para lectores de ambas áreas

Diseño acordado con el usuario el 2026-11-02: el informe debe servir por igual a jefaturas/equipos clínicos y administrativos y a QA/desarrollo. Leer [references/report-design.md](references/report-design.md) al redactarlo. Usar [assets/report-template.html](assets/report-template.html) y [assets/report.css](assets/report.css) como base de presentación.

Entregar un HTML principal de lectura clara: resultado primero; tareas con lo esperado, lo observado y evidencia desplegables; correcciones; pendientes y límites visibles; estado de los datos de prueba; documentos y anexo técnico desplegable. Redactar en español cotidiano, con frases cortas y nombres de tareas que reconozca el lector. Los fallos, su efecto, la solución pendiente y su responsable deben verse sin abrir el anexo.

El harness sigue siendo la fuente de los dictámenes, porcentajes y resultados por caso. Conservar su HTML técnico, CSV y JSON como respaldo, enlazados desde el informe principal; no recalcular aceptación ni convertir simulaciones en pruebas reales. El CLI actual genera el informe técnico: completar después la presentación de lectura clara a partir de esos resultados. Mantener versiones anteriores y no sobrescribir evidencia cerrada al mejorar su redacción.

Reservar para el anexo códigos, nombres internos, versiones, identificadores, hashes, registros de ejecución e incidencias ya resueltas. Mantener en la lectura principal qué se probó, qué pasó, qué falta y qué quedó fuera del alcance. No describir una aprobación parcial como aprobación de todo el HIS.

### Nombre de los archivos entregados

El nombre del HTML debe identificar el módulo o flujo probado. Usar `qa-<modulo-o-flujo>-<aaaa-mm-dd>-rNN.html`, en minúsculas, sin espacios ni tildes. Ejemplos: `qa-mpi-2026-11-02-r03.html`, `qa-registro-pacientes-2026-11-02-r01.html`. La fecha es la del cierre de las pruebas en America/Santiago y `rNN` identifica la revisión de la campaña.

Para anexos compartidos, agregar `-tecnico`; si se entregan fases por separado, `-pre` o `-post`. Evitar nombres genéricos como `ENTREGA_QA.html`, `informe.html` o `index.html` para el archivo que recibe el usuario. El harness puede conservar sus nombres internos: crear copias con nombres descriptivos para la entrega y ajustar sus enlaces relativos, sin sobrescribir las evidencias cerradas. Una nueva presentación de la misma campaña puede agregar `-v02`, conservando la fecha y revisión originales; no presentarla como pruebas nuevas.

Mantener el informe y datos de prueba en carpeta privada fuera de Git; nunca credenciales, tokens ni PHI en artefactos. Usar pacientes sintéticos y documentar efectos; no enviarlos a MPI nacional, borrar historia para ocultarlos ni repetir escrituras ambiguas. Preservar las restricciones de integraciones OpenHIM/Pabellón del proyecto.

La fuente mantenida de esta skill vive en `bahmni-nextjs-hcsba/skills/his-qa-release`. Sincronizar el directorio completo (SKILL.md, agents, referencias y assets) con las copias distribuidas en los repositorios HCSBA y con la copia instalada en `<CODEX_HOME>/skills/his-qa-release` (por defecto `~/.codex/skills/his-qa-release`). No reemplazar reglas HCSBA al actualizar herramientas oficiales; esta skill local no tiene un upstream oficial externo declarado.
