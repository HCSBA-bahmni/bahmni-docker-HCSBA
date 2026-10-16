import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, test } from 'node:test';
import { allowedRequest, createHandler } from './server.mjs';

const calls = [];
const config = {
  mode: 'preview', publicOrigin: 'https://localhost', upstream: new URL('http://127.0.0.1:5001'),
  username: 'lab-client', password: 'synthetic-secret', privilege: 'Add Patients',
};
const server = http.createServer(createHandler(config, {
  authenticate: async (request) => request.headers.cookie === 'JSESSIONID=valid',
  fetch: async (url, options) => {
    calls.push({ url: String(url), options });
    return new Response(JSON.stringify({ resourceType: 'Bundle', entry: [] }), { headers: { 'X-MPI-Outcome': 'no-match', 'X-MPI-Stale': 'true', 'Content-Type': 'application/fhir+json' } });
  },
}));
let base;
before(async () => { await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve)); base = `http://127.0.0.1:${server.address().port}`; });
after(async () => { await new Promise((resolve) => server.close(resolve)); });

test('preview only accepts authenticated exact identifier lookup and returns MPI headers', async () => {
  const result = await fetch(`${base}/openmrs/mpi-admission-gateway/fhir/Patient?identifier=12345678-5`, { headers: { Cookie: 'JSESSIONID=valid' } });
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('X-MPI-Outcome'), 'no-match');
  assert.equal(result.headers.get('X-MPI-Stale'), 'true');
  assert.equal(calls.at(-1).url, 'http://127.0.0.1:5001/mpi-admision/fhir/Patient?identifier=12345678-5');
  assert.equal(calls.at(-1).options.headers.Authorization, `Basic ${Buffer.from('lab-client:synthetic-secret').toString('base64')}`);
  assert.equal(calls.at(-1).options.headers.Cookie, undefined);
});

test('preview forbids clinical writes and unauthenticated queries', async () => {
  const write = await fetch(`${base}/openmrs/mpi-admission-gateway/_sync/11111111-1111-4111-8111-111111111111`, { method: 'POST', headers: { Origin: 'https://localhost', Cookie: 'JSESSIONID=valid' } });
  assert.equal(write.status, 404);
  const read = await fetch(`${base}/openmrs/mpi-admission-gateway/fhir/Patient?identifier=12345678-5`);
  assert.equal(read.status, 401);
});

test('the gateway rejects repeated identifiers and cross-site requests', async () => {
  const repeated = await fetch(`${base}/openmrs/mpi-admission-gateway/fhir/Patient?identifier=12345678-5&identifier=20347573-K`, { headers: { Cookie: 'JSESSIONID=valid' } });
  assert.equal(repeated.status, 404);
  const crossSite = await fetch(`${base}/openmrs/mpi-admission-gateway/fhir/Patient?identifier=12345678-5`, { headers: { Cookie: 'JSESSIONID=valid', 'Sec-Fetch-Site': 'cross-site' } });
  assert.equal(crossSite.status, 403);
});

test('admission may force a fresh national check after a cached negative result', async () => {
  const result = await fetch(`${base}/openmrs/mpi-admission-gateway/fhir/Patient?identifier=12345678-5&_refresh=true`, { headers: { Cookie: 'JSESSIONID=valid' } });
  assert.equal(result.status, 200);
  assert.equal(calls.at(-1).url, 'http://127.0.0.1:5001/mpi-admision/fhir/Patient?identifier=12345678-5&_refresh=true');
});

test('a remote Bahmni instance uses its dedicated OpenHIM admission route for reads and sync', () => {
  const dedicated = { mode: 'integrated', admissionPath: '/mpi225-admision' };
  assert.equal(allowedRequest({ method: 'GET', url: '/openmrs/mpi-admission-gateway/fhir/Patient?identifier=20347573-K' }, dedicated),
    '/mpi225-admision/fhir/Patient?identifier=20347573-K');
  assert.equal(allowedRequest({ method: 'POST', url: '/openmrs/mpi-admission-gateway/_sync/11111111-1111-4111-8111-111111111111' }, dedicated),
    '/mpi225-admision/_sync/11111111-1111-4111-8111-111111111111');
});

test('demo page requires the registration session and does not expose credentials', async () => {
  const denied = await fetch(`${base}/openmrs/mpi-admission-gateway/demo.html`);
  assert.equal(denied.status, 401);
  const page = await fetch(`${base}/openmrs/mpi-admission-gateway/demo.html`, { headers: { Cookie: 'JSESSIONID=valid' } });
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);
  const html = await page.text();
  assert.match(html, /Del RUN al recurso FHIR/);
  assert.doesNotMatch(html, /synthetic-secret/);
});

test('demo executes fixed read-only MPI, PIXm, HAPI and OpenMRS operations', async () => {
  const observed = [];
  const demoServer = http.createServer(createHandler({ ...config, admissionPath: '/mpi225-admision',
    hapiURL: new URL('http://fhir.test/fhir/'), openmrsFhirURL: new URL('https://openmrs.test/openmrs/ws/fhir2/R4/'), tlsServername: 'localhost',
  }, {
    authenticate: async () => true,
    demoFetch: async (target, options, kind) => {
      observed.push({ target: String(target), kind, method: options.method, headers: options.headers });
      const body = kind === 'pix' ? { resourceType: 'Parameters', parameter: [] }
        : kind === 'openhim' ? { resourceType: 'Bundle', type: 'searchset', total: 1,
          entry: [{ resource: { resourceType: 'Patient', id: '11111111-1111-4111-8111-111111111111',
            name: [{ family: 'González', given: ['Ana'] }], birthDate: '1988' } }] }
          : kind === 'pdqm' && String(target).endsWith('/Patient/11111111-1111-4111-8111-111111111111')
            ? { resourceType: 'Patient', id: '11111111-1111-4111-8111-111111111111',
              name: [{ family: 'González', given: ['Ana'] }], birthDate: '1988-04-20' }
            : { resourceType: 'Bundle', type: 'searchset', total: 0, entry: [] };
      return new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/fhir+json' } });
    },
  }));
  await new Promise((resolve) => demoServer.listen(0, '127.0.0.1', resolve));
  try {
    const url = `http://127.0.0.1:${demoServer.address().port}/openmrs/mpi-admission-gateway/demo/data?run=12345678-5`;
    assert.equal((await fetch(url.replace('12345678-5', 'invalid'), { headers: { Cookie: 'JSESSIONID=valid' } })).status, 404);
    const result = await fetch(url, { headers: { Cookie: 'JSESSIONID=valid' } });
    assert.equal(result.status, 200);
    const json = await result.json();
    assert.equal(json.operations.length, 8);
    assert.deepEqual(observed.map((call) => call.method), Array(8).fill('GET'));
    assert.equal(observed.filter((call) => call.kind === 'pix').length, 3);
    assert.match(observed.find((call) => call.kind === 'pdqm' && call.target.includes('/Patient/')).target, /11111111-1111-4111-8111-111111111111/);
    assert.match(observed.find((call) => call.kind === 'pdqm' && call.target.includes('family=')).target, /family=Gonz/);
    assert.match(observed.find((call) => call.kind === 'pdqm' && call.target.includes('family=')).target, /birthdate=1988-04-20/);
    assert.match(observed.find((call) => call.kind === 'hapi').target, /identifier=http%3A%2F%2Fclientregistry.org%2Fnationalid%7C12345678-5/);
    assert.equal(observed.find((call) => call.kind === 'hapi').headers.Cookie, undefined);
    assert.equal(observed.find((call) => call.kind === 'openmrs').headers.Cookie, 'JSESSIONID=valid');
    assert.equal(result.headers.get('cache-control'), 'no-store');
  } finally { await new Promise((resolve) => demoServer.close(resolve)); }
});

test('the gateway only forwards bounded demographic searches and CRID reads', () => {
  const integrated = { mode: 'integrated', admissionPath: '/mpi225-admision' };
  assert.equal(allowedRequest({ method: 'GET', url: '/openmrs/mpi-admission-gateway/fhir/Patient?family=Gonz%C3%A1lez&birthdate=1988-04-20' }, integrated),
    '/mpi225-admision/fhir/Patient?family=Gonz%C3%A1lez&birthdate=1988-04-20');
  assert.equal(allowedRequest({ method: 'GET', url: '/openmrs/mpi-admission-gateway/fhir/Patient?gender=female' }, integrated), null);
  assert.equal(allowedRequest({ method: 'GET', url: '/openmrs/mpi-admission-gateway/fhir/Patient?family=Gonzalez&telecom=123' }, integrated), null);
  assert.equal(allowedRequest({ method: 'GET', url: '/openmrs/mpi-admission-gateway/fhir/Patient/11111111-1111-4111-8111-111111111111' }, integrated),
    '/mpi225-admision/fhir/Patient/11111111-1111-4111-8111-111111111111');
});
