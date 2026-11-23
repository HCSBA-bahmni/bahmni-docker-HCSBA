# Informe QA de lectura clara

Estructura elegida por el usuario el 2026-11-02 y redacción refinada después de su respuesta «Mantener esta estructura y pulir los textos». Audiencia: jefaturas, equipos clínicos/administrativos y QA/desarrollo por igual.

## Fuente y propósito

El lector debe entender en pocos segundos qué se revisó, cuál fue el resultado y si queda algo por resolver. Después debe poder consultar el detalle sin perder el contexto.

El HTML principal presenta los resultados del harness; no calcula otra nota ni sustituye la pauta. Usar el `resumen.json` y la `pauta.json` de la corrida correcta. Conservar PRE/POST, revisión, política, esperado/obtenido, evidencia y clasificación REAL/SIMULADO/ARTEFACTO. Mantener el HTML técnico y CSV originales como anexos. Una mejora editorial genera otro archivo o carpeta, conservando los entregables cerrados.

## Nombre del archivo

El módulo o flujo debe reconocerse en el nombre del archivo recibido por el usuario. Convención: `qa-<modulo-o-flujo>-<aaaa-mm-dd>-rNN.html`.

- Usar nombres de negocio breves y consistentes: `mpi`, `registro-pacientes`, `consulta-clinica`, `hospitalizacion`.
- Escribir en minúsculas, con guiones, sin espacios ni tildes.
- Tomar la fecha del cierre del ensayo en America/Santiago y la revisión de la campaña. Una mejora de redacción no cambia esas referencias.
- HTML principal: `qa-mpi-2026-11-02-r03.html`.
- Anexo técnico: `qa-mpi-2026-11-02-r03-tecnico.html`.
- Fases separadas, cuando corresponda: `qa-mpi-2026-11-02-r03-pre.html` y `qa-mpi-2026-11-02-r03-post.html`; un anexo técnico de esa fase puede terminar en `-pre-tecnico` o `-post-tecnico`.
- Si se conserva otra presentación del mismo ensayo, agregar `-v02` al nombre. Diferenciar esta versión editorial de una nueva revisión de QA.
- No incluir nombres de pacientes, identificadores personales, hashes largos ni un estado «aprobado» en el nombre.

`informe.html`, `index.html` y `ENTREGA_QA.html` pueden existir como archivos internos o históricos, pero no deben ser el nombre principal del entregable. El harness mantiene sus exportaciones originales: preparar copias descriptivas y actualizar los enlaces del HTML principal. Verificar que los enlaces funcionen desde la ubicación final y que no se hayan alterado los resultados de la campaña.

## Orden de lectura acordado

1. **Resultado.** Título de la tarea o flujo, fecha, ambiente y dictamen en palabras claras. Una o dos frases explican qué ocurrió. Si no aprueba, decir de inmediato qué falta. Identificar desarrollo como desarrollo; no inferir autorización para producción.
2. **Lo esencial.** Hasta tres ideas concretas sobre funcionamiento, acceso y estado final. Evitar repetir porcentajes o el título en cada bloque.
3. **Qué se probó.** Agrupar por tareas reconocibles, sin reemplazar ni alterar los casos de la pauta. Cada tarea muestra título, estado escrito y una frase con el resultado. El desplegable contiene «Se esperaba», «Se observó», «Cómo se comprobó» y enlaces de evidencia. Distinguir uso del sistema, consultas entre servicios y simulaciones. Un fallo y su efecto se muestran fuera del desplegable.
4. **Qué se corrigió.** Problema, cambio y resultado en frases cortas. Distinguir un defecto del sistema de un ajuste del guion o de sus datos de prueba. No convertir una tarea de preparación de entrega en un fallo clínico.
5. **Pendientes y alcance.** Hallazgos abiertos con su efecto, siguiente acción y responsable. Si no los hay, decir «Sin problemas abiertos en esta revisión». Mostrar siempre qué quedó fuera de las pruebas. Una aprobación con observaciones conserva esos pendientes visibles.
6. **Trabajo realizado.** Traducir PRE como «Antes de instalar la corrección» y POST como «Después de instalarla en desarrollo», según el encargo real. Mostrar realizadas/previstas y aprobadas desde el harness. Los totales pueden incluir variantes y comprobaciones agregadas: no llamarlos cantidad de pacientes ni sumar reintentos como casos nuevos. Si hay casos no ejecutados, titular «Estado de las pruebas», sin afirmar que todo se completó.
7. **Datos de prueba.** Explicar de forma breve qué recursos se crearon y cómo quedaron. Una captura opcional debe estar anonimizada o corresponder sólo a pacientes de prueba. Los identificadores y el manifest durable pueden quedar en el detalle.
8. **Documentos y respaldo.** Enlaces con nombres comprensibles a pauta CSV e informe técnico. Un anexo desplegable reúne criterios, porcentajes PRE/POST, versión, ambiente, revisión/imagen, incidencias resueltas, resultados de runners y vínculos a registros originales.

Los incidentes que aún afectan el dictamen deben aparecer en el resumen o los pendientes. Los ya resueltos pueden explicarse en el anexo, conservando intento inicial y repetición con los mismos IDs.

## Redacción

- Explicar el resultado con una acción observable: «La ficha conservó sus datos al abrirla de nuevo», «La cuenta de admisión no pudo abrir la función reservada al gestor».
- Preferir «problema», «resultado», «se guardó», «se volvió a abrir» y «quedó pendiente» a frases abstractas o centradas en la implementación.
- Nombrar el rol cuando ayude a entender la decisión. Explicar una sigla clínica necesaria la primera vez que aparezca.
- Reservar HTTP, UUID, CRID, nombres de contenedores, flags, hashes, nombres de tests y mensajes crudos para el respaldo técnico. No ocultar un resultado importante al trasladar esos detalles.
- Evitar lenguaje de certificación general. «El flujo revisado pasó las pruebas en desarrollo» acota la afirmación al trabajo ejecutado.
- Unificar el tiempo verbal. La fecha corresponde al cierre observado del ensayo, no al momento de generar otra presentación. Los resultados históricos no acreditan el estado vivo actual.
- No atribuir una causa a una incidencia si sólo hay una hipótesis. Describir el intento fallido, la recuperación y el resultado final.
- Mantener el mismo significado entre la frase cotidiana y la evidencia. Por ejemplo, «ofreció abrir la ficha existente» no equivale a «abrió automáticamente la ficha».
- Marcar los enlaces JSON/log como detalle técnico. Usar capturas y resultados redactados cuando permitan entender la evidencia sin conocimientos informáticos.

## Dictamen y estados

Usar el dictamen del harness para la fase solicitada. PRE aprobado no significa POST aprobado. Si el harness indica aprobación con observaciones, conservar esa condición y las observaciones. Si faltan comprobaciones, mostrarlo incluso cuando las ejecutadas hayan aprobado.

Usar texto además de color: «Correcto», «No cumplió lo esperado», «No se pudo completar», «Pendiente». La etiqueta de cada tarea debe respetar todas sus variantes necesarias; no aprobar el conjunto por una sola variante exitosa. Los hallazgos críticos o de alta prioridad nunca se esconden detrás de una nota o un desplegable.

Mantener aceptación ponderada y ejecución como conceptos separados en el anexo, con sus valores originales y la política aplicada. La lectura principal puede usar realizadas/previstas y aprobadas, sin presentar un porcentaje de pruebas como porcentaje de seguridad del sistema.

## Presentación

- HTML autónomo, con CSS integrado desde `assets/report.css`, fuentes del sistema y sin servicios externos.
- Una columna principal de lectura, ancho máximo cercano a 1056 px; párrafos de longitud contenida y tipografía base de 16–17 px.
- Fondo claro, contraste suficiente, bordes suaves y jerarquía consistente. El resultado aparece antes de los detalles de ejecución.
- Desplegables nativos `details/summary`, títulos en orden y etiquetas que identifiquen la tarea. Foco visible, acceso por teclado y enlaces descriptivos.
- Adaptar a pantalla estrecha sin desplazamiento horizontal de toda la página. Las tablas del anexo pueden tener su propio desplazamiento cuando sea necesario.
- Versión de impresión legible: conservar resultado, hallazgos, alcance y resumen de tareas. Aclarar que el respaldo completo está en los archivos enlazados.
- Usar la paleta de estado según el dictamen real: verde para aprobado, ámbar para observaciones/pendientes y rojo para no aprobado. No usar un indicador de éxito en un resultado bloqueado.

## Uso de la plantilla

`assets/report-template.html` es una estructura editorial, no un informe ejecutado. Reemplazar todos sus marcadores con contenido basado en la campaña; integrar `assets/report.css` en `{{REPORT_CSS}}`. La agrupación de tareas y su resumen requieren revisar la pauta, no cortar automáticamente el texto técnico ni inventar resultados. Escapar los textos y comprobar los enlaces de evidencia.

No incluir la barra de «propuesta» ni notas de diseño en el informe final de QA. Esas marcas son útiles sólo durante la revisión de la presentación.

Antes de entregar, verificar concordancia con JSON, dictamen y porcentajes sin recalcularlos; pendientes y exclusiones visibles; enlaces; lectura en escritorio y pantalla estrecha; teclado y estado de los desplegables. El informe debe poder leerse sin abrir registros técnicos, y el equipo QA debe poder llegar a éstos sin perder la evidencia.
