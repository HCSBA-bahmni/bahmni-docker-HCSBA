import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const prefix = '/openmrs/mpi-admission-gateway';
const forwardedHeaders = ['content-type', 'x-mpi-outcome', 'x-mpi-source', 'x-mpi-purpose', 'x-mpi-decision', 'x-mpi-stale', 'x-mpi-synced-at', 'x-mpi-crid', 'x-correlation-id'];
const runSystem = 'http://clientregistry.org/nationalid';
const pixTargets = [
  { key: 'crid', label: 'Identidad MPI (CRID)', system: 'urn:hcsba:mpi:crid' },
  { key: 'clinical', label: 'Identificador clínico Bahmni .225', system: 'urn:hcsba:mpi:identificador-clinico:225' },
  { key: 'record', label: 'UUID de ficha OpenMRS .225', system: 'urn:hcsba:mpi:ficha-emr:225' },
];
const demoHtml = fs.readFileSync(new URL('./demo.html', import.meta.url), 'utf8');

function readConfig(env = process.env) {
  const mode = env.MPI_ADMISSION_MODE;
  if (!['preview', 'integrated'].includes(mode)) throw new Error('MPI_ADMISSION_MODE must be preview or integrated');
  const upstream = new URL(env.MPI_OPENHIM_BASE_URL || '');
  if (!['http:', 'https:'].includes(upstream.protocol) || upstream.pathname !== '/') throw new Error('MPI_OPENHIM_BASE_URL must be an HTTP(S) origin');
  if (mode === 'integrated' && upstream.protocol !== 'https:') throw new Error('Integrated MPI requires HTTPS to OpenHIM');
  const sessionURL = new URL(env.OPENMRS_SESSION_URL || '');
  if (sessionURL.protocol !== 'https:' || !sessionURL.pathname.endsWith('/ws/rest/v1/session')) throw new Error('OPENMRS_SESSION_URL must be the HTTPS OpenMRS session endpoint');
  const publicOrigin = new URL(env.PUBLIC_ORIGIN || '');
  if (publicOrigin.protocol !== 'https:' || publicOrigin.pathname !== '/') throw new Error('PUBLIC_ORIGIN must be an HTTPS origin');
  const admissionPath = env.MPI_OPENHIM_ADMISSION_PATH || '/mpi-admision';
  if (!/^\/[a-z0-9-]+$/.test(admissionPath)) throw new Error('MPI_OPENHIM_ADMISSION_PATH must be a single absolute path segment');
  const username = env.MPI_OPENHIM_CLIENT_ID;
  const password = fs.readFileSync(env.MPI_OPENHIM_PASSWORD_FILE, 'utf8').trim();
  const ca = fs.readFileSync(env.OPENMRS_SESSION_CA_FILE);
  const openhimCa = mode === 'integrated' ? fs.readFileSync(env.MPI_OPENHIM_CA_FILE) : undefined;
  const hapiURL = new URL(env.MPI_HAPI_FHIR_BASE_URL || 'http://10.68.174.227:8082/fhir/');
  if (hapiURL.protocol !== 'http:' || hapiURL.pathname !== '/fhir/' || hapiURL.username || hapiURL.password) throw new Error('MPI_HAPI_FHIR_BASE_URL must be an HTTP FHIR base URL');
  const openmrsFhirURL = new URL('/openmrs/ws/fhir2/R4/', sessionURL);
  if (!username || !password || !ca.length) throw new Error('MPI credential and OpenMRS CA are required');
  if (mode === 'integrated' && !openhimCa?.length) throw new Error('Integrated MPI requires an OpenHIM CA');
  return { mode, upstream, sessionURL, openmrsFhirURL, hapiURL, publicOrigin: publicOrigin.origin, admissionPath, username, password, ca,
    tlsServername: env.OPENMRS_SESSION_TLS_SERVERNAME || sessionURL.hostname,
    openhimCa, openhimServername: env.MPI_OPENHIM_TLS_SERVERNAME || upstream.hostname,
    privilege: env.OPENMRS_REQUIRED_PRIVILEGE || 'Add Patients',
    listen: Number(env.PORT || 8080) };
}

function verifiedResourceFetch(target, options, config, kind) {
  const secure = kind === 'openmrs';
  const transport = secure ? https : http;
  return new Promise((resolve, reject) => {
    const req = transport.request(target, {
      method: 'GET', headers: options.headers, signal: options.signal, timeout: 12000,
      ...(secure ? { ca: config.ca, servername: config.tlsServername } : {}),
    }, (upstream) => {
      const chunks = [];
      let size = 0;
      upstream.on('data', (chunk) => {
        size += chunk.length;
        if (size > 2_000_000) upstream.destroy(new Error('FHIR response too large'));
        else chunks.push(chunk);
      });
      upstream.on('end', () => resolve(new Response(Buffer.concat(chunks), {
        status: upstream.statusCode, headers: upstream.headers,
      })));
      upstream.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('FHIR timeout')));
    req.on('error', reject);
    req.end();
  });
}

function demoRun(request) {
  const url = new URL(request.url, 'http://gateway');
  if (url.pathname !== `${prefix}/demo/data` || request.method !== 'GET') return null;
  if ([...url.searchParams.keys()].some((key) => key !== 'run') || url.searchParams.getAll('run').length !== 1) return null;
  const run = url.searchParams.get('run')?.trim().toUpperCase();
  return /^\d{1,8}-[\dK]$/.test(run || '') ? run : null;
}

function demographicPath(url, admissionPath) {
  const keys = [...url.searchParams.keys()];
  if (!keys.length || keys.some((key) => !['family', 'given', 'birthdate', 'gender'].includes(key))) return null;
  if (keys.some((key) => url.searchParams.getAll(key).length !== 1)) return null;
  const family = url.searchParams.get('family')?.trim();
  const given = url.searchParams.get('given')?.trim();
  if (!family && !given) return null;
  const name = /^[\p{L}\p{M} .'-]{2,80}$/u;
  if ((family && !name.test(family)) || (given && !name.test(given))) return null;
  const birthdate = url.searchParams.get('birthdate');
  if (birthdate && (!/^\d{4}-\d{2}-\d{2}$/.test(birthdate)
    || Number.isNaN(Date.parse(`${birthdate}T00:00:00Z`))
    || new Date(`${birthdate}T00:00:00Z`).toISOString().slice(0, 10) !== birthdate)) return null;
  const gender = url.searchParams.get('gender');
  if (gender && !['male', 'female', 'other', 'unknown'].includes(gender)) return null;
  if (keys.some((key) => !url.searchParams.get(key)?.trim())) return null;
  const params = new URLSearchParams();
  for (const key of ['family', 'given', 'birthdate', 'gender']) {
    if (url.searchParams.has(key)) params.set(key, url.searchParams.get(key).trim());
  }
  return `${admissionPath}/fhir/Patient?${params}`;
}

async function runDemo(request, config, transport, run) {
  const token = `${runSystem}|${run}`;
  const auth = `Basic ${Buffer.from(`${config.username}:${config.password}`).toString('base64')}`;
  const cookie = /(?:^|;\s*)JSESSIONID=([^;]+)/.exec(request.headers.cookie || '')?.[1];
  const correlationId = randomUUID();
  const operation = async (key, label, kind, target, visiblePath, headers) => {
    const started = Date.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 18000);
    try {
      const upstream = await transport(target, { method: 'GET', signal: controller.signal, headers }, kind);
      const bodyText = await upstream.text();
      if (bodyText.length > 2_000_000) throw new Error('FHIR response too large');
      const body = JSON.parse(bodyText);
      return { key, label, kind, method: 'GET', path: visiblePath, status: upstream.status,
        durationMs: Date.now() - started, body,
        mpi: Object.fromEntries(['x-mpi-outcome', 'x-mpi-source', 'x-mpi-decision', 'x-mpi-crid', 'x-mpi-synced-at', 'x-correlation-id']
          .map((header) => [header, upstream.headers.get(header)]).filter(([, value]) => value)) };
    } catch {
      return { key, label, kind, method: 'GET', path: visiblePath, status: 0,
        durationMs: Date.now() - started, error: 'Servicio no disponible o respuesta FHIR inválida' };
    } finally { clearTimeout(timer); }
  };
  const mpiHeaders = { Authorization: auth, Accept: 'application/fhir+json', 'X-Correlation-Id': correlationId };
  const searchPath = `${config.admissionPath || '/mpi-admision'}/fhir/Patient?identifier=${encodeURIComponent(run)}`;
  // Primero se consulta admisión: este paso puede incorporar al índice la fuente nacional.
  const lookup = await operation('lookup', 'Consulta de identidad por RUN', 'openhim',
    new URL(searchPath, config.upstream), searchPath, mpiHeaders);
  const patient = lookup.body?.entry?.[0]?.resource;
  const crid = patient?.id;
  const readPath = /^[0-9a-f-]{36}$/i.test(crid || '')
    ? `${config.admissionPath || '/mpi-admision'}/fhir/Patient/${crid}`
    : null;
  const pdqmRead = readPath
    ? await operation('pdqm-read', 'PDQm · leer identidad por CRID', 'pdqm',
      new URL(readPath, config.upstream), readPath, mpiHeaders)
    : { key: 'pdqm-read', label: 'PDQm · leer identidad por CRID', kind: 'pdqm',
      method: 'GET', path: `${config.admissionPath || '/mpi-admision'}/fhir/Patient/{CRID}`,
      status: 0, durationMs: 0, skipped: true,
      error: 'No se ejecutó: la consulta por RUN no entregó un CRID.' };
  const demographicPatient = pdqmRead.body?.resourceType === 'Patient' ? pdqmRead.body : patient;
  const name = (demographicPatient?.name || []).find((item) => item?.family || item?.given?.length);
  const demographic = new URLSearchParams();
  if (name?.family) demographic.set('family', name.family);
  else if (name?.given?.[0]) demographic.set('given', name.given[0]);
  // FHIR admite fechas parciales como "1997"; este subconjunto PDQm acepta fechas completas.
  // Si la ficha solo conoce el año, se busca por nombre sin fabricar día ni mes.
  if (/^\d{4}-\d{2}-\d{2}$/.test(demographicPatient?.birthDate || '')) {
    demographic.set('birthdate', demographicPatient.birthDate);
  }
  const pdqmPath = demographic.size
    ? demographicPath(new URL(`${prefix}/fhir/Patient?${demographic}`, 'http://gateway'), config.admissionPath || '/mpi-admision')
    : null;
  const pdqm = pdqmPath
    ? await operation('pdqm', 'PDQm · búsqueda demográfica', 'pdqm', new URL(pdqmPath, config.upstream), pdqmPath, mpiHeaders)
    : { key: 'pdqm', label: 'PDQm · búsqueda demográfica', kind: 'pdqm', method: 'GET',
      path: `${config.admissionPath || '/mpi-admision'}/fhir/Patient?family=…`,
      status: 0, durationMs: 0, skipped: true,
      error: 'No se ejecutó: la consulta por RUN no entregó un apellido o nombre válido.' };
  const pix = await Promise.all(pixTargets.map((target) => {
    const path = `${config.admissionPath || '/mpi-admision'}/fhir/Patient/$ihe-pix?sourceIdentifier=${encodeURIComponent(token)}&targetSystem=${encodeURIComponent(target.system)}`;
    return operation(target.key, target.label, 'pix', new URL(path, config.upstream), path, mpiHeaders);
  }));
  const hapiPath = `Patient?identifier=${encodeURIComponent(token)}&_count=20`;
  const openmrsPath = `Patient?identifier=${encodeURIComponent(run)}&_count=20`;
  const [hapi, openmrs] = await Promise.all([
    operation('hapi', 'Pacientes persistidos en HAPI FHIR', 'hapi', new URL(hapiPath, config.hapiURL),
      `/fhir/${hapiPath}`, { Accept: 'application/fhir+json' }),
    operation('openmrs', 'Ficha en OpenMRS FHIR2', 'openmrs', new URL(openmrsPath, config.openmrsFhirURL),
      `/openmrs/ws/fhir2/R4/${openmrsPath}`, { Accept: 'application/fhir+json', Cookie: `JSESSIONID=${cookie}`, Host: config.tlsServername }),
  ]);
  return { run, checkedAt: new Date().toISOString(), correlationId,
    operations: [lookup, pdqmRead, pdqm, ...pix, hapi, openmrs] };
}

function verifiedOpenhimFetch(target, options, config) {
  return new Promise((resolve, reject) => {
    const request = https.request(target, {
      method: options.method, headers: options.headers, signal: options.signal,
      ca: config.openhimCa, servername: config.openhimServername,
      timeout: 20000,
    }, (upstream) => {
      const chunks = [];
      let size = 0;
      upstream.on('data', (chunk) => {
        size += chunk.length;
        if (size > 2_000_000) upstream.destroy(new Error('MPI response too large'));
        else chunks.push(chunk);
      });
      upstream.on('end', () => resolve(new Response(Buffer.concat(chunks), {
        status: upstream.statusCode,
        headers: upstream.headers,
      })));
      upstream.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('MPI timeout')));
    request.on('error', reject);
    request.end(options.body);
  });
}

export function sessionIdentity(data, privilege) {
  const active = (name) => data.user?.privileges?.some(p => p.name === name && p.retired !== true && p.retired !== 'true');
  return data.authenticated === true && Array.isArray(data.user?.privileges) && active(privilege)
    ? { actor: data.user.username || data.user.uuid, identityManager: active('Manage MPI Identity Reviews') } : false;
}
function authenticateSession(request, config) {
  const session = /(?:^|;\s*)JSESSIONID=([^;]+)/.exec(request.headers.cookie || '')?.[1];
  if (!session) return Promise.resolve(false);
  return new Promise((resolve, reject) => {
    const check = https.request(config.sessionURL, {
      method: 'GET', servername: config.tlsServername, ca: config.ca, timeout: 10000,
      headers: { Accept: 'application/json', Cookie: `JSESSIONID=${session}`, Host: config.tlsServername },
    }, (response) => {
      let body = '';
      response.on('data', (chunk) => { body += chunk; if (body.length > 1_000_000) response.destroy(new Error('session response too large')); });
      response.on('end', () => {
        if (response.statusCode !== 200) return resolve(false);
        try {
          const data = JSON.parse(body);
          resolve(sessionIdentity(data, config.privilege));
        } catch (error) { reject(error); }
      });
      response.on('error', reject);
    });
    check.on('timeout', () => check.destroy(new Error('session timeout')));
    check.on('error', reject);
    check.end();
  });
}

function allowedRequest(request, config) {
  const url = new URL(request.url, 'http://gateway');
  const admissionPath = config.admissionPath || '/mpi-admision';
  if (request.method === 'GET' && url.pathname === `${prefix}/_identity` && !url.search) return `${admissionPath}/_identity`;
  if (config.mode === 'integrated' && url.pathname === `${prefix}/_reviews`) {
    if (request.method === 'POST' && !url.search) return `${admissionPath}/_reviews`;
    if (request.method === 'GET' && [...url.searchParams.keys()].every(k => ['patientUuid','offset'].includes(k) && url.searchParams.getAll(k).length === 1)
      && (!url.searchParams.has('patientUuid') || /^[0-9a-f-]{36}$/i.test(url.searchParams.get('patientUuid')))
      && (!url.searchParams.has('offset') || /^\d{1,6}$/.test(url.searchParams.get('offset')))) return `${admissionPath}/_reviews${url.search}`;
  }
  if (config.mode === 'integrated' && /^\/openmrs\/mpi-admission-gateway\/_reviews\/[0-9a-f-]{36}$/i.test(url.pathname) && request.method === 'GET' && !url.search) return url.pathname.replace(prefix, admissionPath);
  if (config.mode === 'integrated' && /^\/openmrs\/mpi-admission-gateway\/_reviews\/[0-9a-f-]{36}\/(prepare|resolve|clinical-prepare|consolidate|separation-prepare|separate)$/i.test(url.pathname) && request.method === 'POST' && !url.search) return url.pathname.replace(prefix, admissionPath);
  if (config.mode === 'integrated' && request.method === 'POST' && url.pathname === `${prefix}/_match` && !url.search) return `${admissionPath}/_match`;
  if (url.pathname === `${prefix}/fhir/Patient` && request.method === 'GET') {
    const identifiers = url.searchParams.getAll('identifier');
    if (!identifiers.length) return demographicPath(url, admissionPath);
    const refresh = url.searchParams.getAll('_refresh');
    if (identifiers.length !== 1 || !/^\d{1,8}-[\dK]$/.test(identifiers[0]) || refresh.length > 1 || (refresh.length === 1 && refresh[0] !== 'true') || [...url.searchParams.keys()].some((key) => !['identifier', '_refresh'].includes(key))) return null;
    return `${admissionPath}/fhir/Patient?identifier=${encodeURIComponent(identifiers[0])}${refresh.length ? '&_refresh=true' : ''}`;
  }
  if (request.method === 'GET' && /^\/openmrs\/mpi-admission-gateway\/fhir\/Patient\/[0-9a-f-]{36}$/i.test(url.pathname) && !url.search) {
    return url.pathname.replace(prefix, admissionPath);
  }
  if (config.mode === 'integrated' && request.method === 'POST' && /^\/openmrs\/mpi-admission-gateway\/_sync\/[0-9a-f-]{36}$/i.test(url.pathname) && !url.search) {
    return url.pathname.replace(prefix, admissionPath);
  }
  return null;
}

export function createHandler(config, deps = {}) {
  const authenticate = deps.authenticate ?? authenticateSession;
  const upstreamFetch = deps.fetch ?? (config.mode === 'integrated'
    ? (target, options) => verifiedOpenhimFetch(target, options, config)
    : fetch);
  const demoFetch = deps.demoFetch ?? ((target, options, kind) =>
    kind === 'openhim' || kind === 'pdqm' || kind === 'pix'
      ? upstreamFetch(target, options)
      : verifiedResourceFetch(target, options, config, kind));
  return async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    if (request.url === '/health' && request.method === 'GET') {
      response.writeHead(200, { 'Content-Type': 'application/json' }); response.end('{"status":"UP"}'); return;
    }
    const isDemoPage = request.method === 'GET' && request.url === `${prefix}/demo.html`;
    const run = demoRun(request);
    const path = allowedRequest(request, config);
    if (!path && !isDemoPage && !run) { response.writeHead(404); response.end(); return; }
    if (request.headers['sec-fetch-site'] === 'cross-site' || (request.headers.origin && request.headers.origin !== config.publicOrigin)) {
      response.writeHead(403); response.end(); return;
    }
    if (request.method === 'POST' && request.headers.origin !== config.publicOrigin) { response.writeHead(403); response.end(); return; }
    let authorized;
    try { authorized = await authenticate(request, config); }
    catch { response.writeHead(502); response.end('OpenMRS session unavailable'); return; }
    if (!authorized) { response.writeHead(401); response.end('Unauthorized'); return; }
    const reviewRoute = new URL(request.url, 'http://gateway');
    if (reviewRoute.pathname.startsWith(`${prefix}/_reviews`) && !authorized.identityManager
      && ((request.method === 'GET' && reviewRoute.pathname === `${prefix}/_reviews` && !reviewRoute.searchParams.has('patientUuid'))
        || /\/(prepare|resolve|clinical-prepare|consolidate|separation-prepare|separate)$/.test(reviewRoute.pathname))) { response.writeHead(403); response.end('Identity manager privilege required'); return; }
    if (isDemoPage) {
      response.setHeader('Referrer-Policy', 'no-referrer');
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      response.end(demoHtml); return;
    }
    if (run) {
      try {
        const result = await runDemo(request, config, demoFetch, run);
        response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Referrer-Policy': 'no-referrer' });
        response.end(JSON.stringify(result));
      } catch {
        response.writeHead(502); response.end('Demo unavailable');
      }
      return;
    }
    try {
      const target = new URL(path, config.upstream);
      let requestBody;
      if (request.method === 'POST') {
        const chunks = []; let size = 0;
        for await (const chunk of request) {
          size += chunk.length;
          if (size > 32768) { response.writeHead(413); response.end(); return; }
          chunks.push(chunk);
        }
        requestBody = Buffer.concat(chunks);
        if (requestBody.length) {
          try { JSON.parse(requestBody.toString('utf8')); }
          catch { response.writeHead(400); response.end(); return; }
        }
      }
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 20000);
      let upstream;
      try {
        upstream = await upstreamFetch(target, {
          method: request.method, signal: controller.signal,
          body: requestBody?.length ? requestBody : undefined,
          headers: {
            Authorization: `Basic ${Buffer.from(`${config.username}:${config.password}`).toString('base64')}`,
            Accept: request.method === 'GET' ? 'application/fhir+json' : 'application/json',
            'X-Correlation-Id': randomUUID(),
            ...(requestBody?.length ? { 'Content-Type': 'application/json' } : {}),
            ...(authorized.actor ? { 'X-MPI-Actor': String(authorized.actor).replace(/[\r\n]/g, '').slice(0, 128) } : {}),
            'X-MPI-Identity-Manager': authorized.identityManager === true ? 'true' : 'false',
          },
        });
      } finally { clearTimeout(timeout); }
      const body = Buffer.from(await upstream.arrayBuffer());
      if (body.length > 2_000_000) { response.writeHead(502); response.end('MPI response too large'); return; }
      for (const header of forwardedHeaders) {
        const value = upstream.headers.get(header);
        if (value) response.setHeader(header, value);
      }
      response.writeHead(upstream.status);
      response.end(body);
    } catch {
      response.writeHead(502); response.end('MPI unavailable');
    }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = readConfig();
  http.createServer(createHandler(config)).listen(config.listen, '0.0.0.0');
}

export { allowedRequest, readConfig };
