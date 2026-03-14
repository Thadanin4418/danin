import http from 'node:http';
import fsSync from 'node:fs';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ENV_PATH = path.join(__dirname, '.env');

function loadEnvFile(filePath) {
  try {
    const text = fsSync.readFileSync(filePath, 'utf8');
    text.split(/\r?\n/).forEach((line) => {
      const trimmed = String(line || '').trim();
      if (!trimmed || trimmed.startsWith('#')) return;
      const index = trimmed.indexOf('=');
      if (index <= 0) return;
      const key = trimmed.slice(0, index).trim();
      let value = trimmed.slice(index + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      if (!(key in process.env)) {
        process.env[key] = value;
      }
    });
  } catch {}
}

loadEnvFile(ENV_PATH);

const HOST = process.env.HOST || '0.0.0.0';
const PORT = Number(process.env.PORT || 8787);
const ADMIN_TOKEN = String(process.env.ADMIN_TOKEN || '').trim();
const PUBLIC_BASE_URL = String(process.env.PUBLIC_BASE_URL || '').trim();
const DB_DIR = process.env.DATA_DIR
  ? path.resolve(process.env.DATA_DIR)
  : path.join(__dirname, 'data');
const DB_PATH = path.join(DB_DIR, 'licenses.json');
const ADMIN_PANEL_PATH = path.join(__dirname, 'admin-panel.html');
const MANAGER_PANEL_PATH = path.join(__dirname, 'manager-panel.html');
const PREFILL_TOKEN_PATH = path.join(DB_DIR, 'manager-prefill-token.txt');
let writeQueue = Promise.resolve();

const PRODUCT_CODE = 'sora-all-in-one';
const LICENSE_VERSION = 1;
const DEFAULT_PRIVATE_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvlr8EllTMXS3A+9x
Vu65elQ7R3sjpSA1oan+QUnKq4ehRANCAARHfFvbeGuSCzJVwS4E5vEtMYdyy4UK
IteINhpAOvlKJGDY7HHG8wg/ZlnFIv1MvmqBrtohIwqiD7HjB9ya1Ub+
-----END PRIVATE KEY-----`;
const PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAER3xb23hrkgsyVcEuBObxLTGHcsuF
CiLXiDYaQDr5SiRg2OxxxvMIP2ZZxSL9TL5qga7aISMKog+x4wfcmtVG/g==
-----END PUBLIC KEY-----`;

function readPrivateKeyPem() {
  const direct = String(process.env.LICENSE_PRIVATE_KEY_PEM || '').trim();
  if (direct) {
    return direct.replace(/\\n/g, '\n');
  }

  const base64 = String(process.env.LICENSE_PRIVATE_KEY_PEM_BASE64 || '').trim();
  if (base64) {
    return Buffer.from(base64, 'base64').toString('utf8');
  }

  return DEFAULT_PRIVATE_KEY_PEM;
}

const PRIVATE_KEY_PEM = readPrivateKeyPem();

const EMPTY_DB = {
  version: 1,
  createdAt: null,
  updatedAt: null,
  licenses: {}
};

function jsonResponse(res, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Admin-Token'
  });
  res.end(body);
}

function textResponse(res, statusCode, body, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(statusCode, {
    'Content-Type': contentType,
    'Access-Control-Allow-Origin': '*'
  });
  res.end(body);
}

function base64UrlToBuffer(value) {
  const normalized = String(value || '')
    .replace(/-/g, '+')
    .replace(/_/g, '/')
    .padEnd(Math.ceil(String(value || '').length / 4) * 4, '=');
  return Buffer.from(normalized, 'base64');
}

function toBase64Url(buffer) {
  return Buffer.from(buffer)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function parseToken(token) {
  const text = String(token || '').trim();
  const [payloadPart, signaturePart] = text.split('.');
  if (!payloadPart || !signaturePart) {
    throw new Error('License key format is invalid.');
  }

  const payload = JSON.parse(base64UrlToBuffer(payloadPart).toString('utf8'));
  return {
    token: text,
    payloadPart,
    signature: base64UrlToBuffer(signaturePart),
    payload
  };
}

function verifyLicenseToken(token) {
  const parsed = parseToken(token);
  const verifier = crypto.createVerify('SHA256');
  verifier.update(parsed.payloadPart);
  verifier.end();

  const signatureValid = verifier.verify(
    {
      key: PUBLIC_KEY_PEM,
      dsaEncoding: 'ieee-p1363'
    },
    parsed.signature
  );

  if (!signatureValid) {
    throw new Error('License signature is invalid.');
  }

  const payload = parsed.payload || {};
  if (payload.product !== PRODUCT_CODE) {
    throw new Error('License key is for a different product.');
  }
  if (payload.version !== LICENSE_VERSION) {
    throw new Error('License key version is not supported.');
  }
  if (!payload.deviceId) {
    throw new Error('License key does not include a device binding.');
  }

  const expiresAtMs = Date.parse(String(payload.expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) {
    throw new Error('License expiry date is invalid.');
  }
  if (Date.now() > expiresAtMs) {
    throw new Error('License key has expired.');
  }

  return {
    token: parsed.token,
    payload,
    expiresAtMs,
    expiresAtLabel: new Date(expiresAtMs).toLocaleString()
  };
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

async function ensureDbFile() {
  await fs.mkdir(DB_DIR, { recursive: true });
  try {
    await fs.access(DB_PATH);
  } catch {
    const now = new Date().toISOString();
    await fs.writeFile(DB_PATH, JSON.stringify({
      ...EMPTY_DB,
      createdAt: now,
      updatedAt: now
    }, null, 2));
  }
}

async function readAndClearPrefillToken() {
  await fs.mkdir(DB_DIR, { recursive: true });
  try {
    const token = String(await fs.readFile(PREFILL_TOKEN_PATH, 'utf8') || '').trim();
    try {
      await fs.unlink(PREFILL_TOKEN_PATH);
    } catch {}
    return token;
  } catch {
    return '';
  }
}

function sliceFirstJsonObject(text) {
  const source = String(text || '');
  let depth = 0;
  let inString = false;
  let escaped = false;
  let started = false;

  for (let index = 0; index < source.length; index += 1) {
    const ch = source[index];

    if (!started) {
      if (/\s/.test(ch)) continue;
      if (ch !== '{') {
        throw new Error('License database is not a JSON object.');
      }
      started = true;
      depth = 1;
      continue;
    }

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === '{') {
      depth += 1;
      continue;
    }
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        return source.slice(0, index + 1);
      }
    }
  }

  throw new Error('License database JSON is incomplete.');
}

function normalizeDb(db) {
  return {
    ...EMPTY_DB,
    ...db,
    licenses: db?.licenses && typeof db.licenses === 'object'
      ? db.licenses
      : {}
  };
}

async function readDb() {
  await ensureDbFile();
  const raw = await fs.readFile(DB_PATH, 'utf8');
  try {
    return normalizeDb(JSON.parse(raw || '{}'));
  } catch {
    const recoveredText = sliceFirstJsonObject(raw);
    const recoveredDb = normalizeDb(JSON.parse(recoveredText || '{}'));
    await fs.writeFile(DB_PATH, JSON.stringify({
      ...recoveredDb,
      updatedAt: new Date().toISOString()
    }, null, 2));
    return recoveredDb;
  }
}

async function writeDb(db) {
  writeQueue = writeQueue.then(async () => {
    await ensureDbFile();
    const nextDb = normalizeDb({
      ...db,
      updatedAt: new Date().toISOString()
    });
    const tempPath = `${DB_PATH}.tmp`;
    await fs.writeFile(tempPath, JSON.stringify(nextDb, null, 2));
    await fs.rename(tempPath, DB_PATH);
  });
  return writeQueue;
}

function getClientIp(req) {
  const forwarded = String(req.headers['x-forwarded-for'] || '').trim();
  if (forwarded) return forwarded.split(',')[0].trim();
  return req.socket.remoteAddress || '';
}

function createHistoryEntry(type, req, extra = {}) {
  return {
    type,
    at: new Date().toISOString(),
    ip: getClientIp(req),
    ...extra
  };
}

function ensureHistory(record) {
  if (!Array.isArray(record.history)) record.history = [];
  return record.history;
}

function sanitizeRecord(record) {
  if (!record) return null;
  return {
    keyHash: record.keyHash,
    product: record.product,
    version: record.version,
    expiresAt: record.expiresAt,
    licensedDeviceId: record.licensedDeviceId || '',
    deviceId: record.deviceId || '',
    activatedAt: record.activatedAt || '',
    lastValidatedAt: record.lastValidatedAt || '',
    revoked: Boolean(record.revoked),
    revokedAt: record.revokedAt || '',
    lastIp: record.lastIp || '',
    historyCount: Array.isArray(record.history) ? record.history.length : 0
  };
}

function createEmptyRecordFromVerified(verified, keyHash, options = {}) {
  return {
    keyHash,
    product: verified.payload.product,
    version: verified.payload.version,
    expiresAt: verified.payload.expiresAt,
    licensedDeviceId: verified.payload.deviceId || '',
    deviceId: options.deviceId ?? '',
    activatedAt: options.activatedAt || '',
    lastValidatedAt: options.lastValidatedAt || '',
    revoked: false,
    revokedAt: '',
    lastIp: '',
    history: []
  };
}

async function getOrCreateRecordFromLicenseKey(db, licenseKey, options = {}) {
  const verified = verifyLicenseToken(licenseKey);
  const keyHash = sha256Hex(licenseKey);
  const existing = db.licenses[keyHash];
  if (existing) {
    return {
      record: existing,
      verified,
      keyHash,
      created: false
    };
  }

  const record = createEmptyRecordFromVerified(verified, keyHash, {
    deviceId: options.deviceId ?? '',
    activatedAt: options.activatedAt || '',
    lastValidatedAt: options.lastValidatedAt || ''
  });
  db.licenses[keyHash] = record;
  return {
    record,
    verified,
    keyHash,
    created: true
  };
}

async function readJsonBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8').trim();
  if (!text) return {};
  return JSON.parse(text);
}

function generateLicenseKey({ deviceId, days, expiresAt }) {
  const normalizedDeviceId = String(deviceId || '').trim().toUpperCase();
  if (!normalizedDeviceId) {
    throw new Error('deviceId is required.');
  }

  let expiresAtIso = '';
  if (expiresAt) {
    const parsed = new Date(String(expiresAt));
    if (Number.isNaN(parsed.getTime())) {
      throw new Error('expiresAt is invalid.');
    }
    expiresAtIso = parsed.toISOString();
  } else {
    const safeDays = Math.max(1, Number.parseInt(String(days || '30'), 10) || 30);
    const date = new Date();
    date.setUTCDate(date.getUTCDate() + safeDays);
    expiresAtIso = date.toISOString();
  }

  const payload = {
    product: PRODUCT_CODE,
    version: LICENSE_VERSION,
    deviceId: normalizedDeviceId,
    issuedAt: new Date().toISOString(),
    expiresAt: expiresAtIso
  };

  const payloadPart = toBase64Url(Buffer.from(JSON.stringify(payload)));
  const signer = crypto.createSign('SHA256');
  signer.update(payloadPart);
  signer.end();
  const signature = signer.sign({
    key: PRIVATE_KEY_PEM,
    dsaEncoding: 'ieee-p1363'
  });

  return `${payloadPart}.${toBase64Url(signature)}`;
}

function ensureAdmin(req) {
  if (!ADMIN_TOKEN) {
    throw new Error('ADMIN_TOKEN is not configured on the server.');
  }
  const token = String(req.headers['x-admin-token'] || '').trim();
  if (!token || token !== ADMIN_TOKEN) {
    throw new Error('Admin token is invalid.');
  }
}

async function activateLicense(req, res, body) {
  const licenseKey = String(body?.licenseKey || '').trim();
  const deviceId = String(body?.deviceId || '').trim().toUpperCase();
  if (!licenseKey || !deviceId) {
    return jsonResponse(res, 400, { ok: false, message: 'licenseKey and deviceId are required.' });
  }

  try {
    const db = await readDb();
    const now = new Date().toISOString();
    const resolved = await getOrCreateRecordFromLicenseKey(db, licenseKey, {
      deviceId: '',
      activatedAt: '',
      lastValidatedAt: ''
    });
    const verified = resolved.verified;
    if (verified.payload.deviceId !== deviceId) {
      return jsonResponse(res, 400, { ok: false, message: 'License key is for a different computer.' });
    }

    const existing = resolved.record;

    if (existing.revoked) {
      return jsonResponse(res, 403, { ok: false, message: 'License key was revoked.' });
    }
    if (existing.deviceId && existing.deviceId !== deviceId) {
      return jsonResponse(res, 403, { ok: false, message: 'License key is already activated on another computer.' });
    }

    existing.deviceId = deviceId;
    existing.activatedAt = existing.activatedAt || now;
    existing.lastValidatedAt = now;
    existing.lastIp = getClientIp(req);
    ensureHistory(existing).push(createHistoryEntry('activate', req, { deviceId }));
    db.licenses[resolved.keyHash] = existing;
    await writeDb(db);

    return jsonResponse(res, 200, {
      ok: true,
      message: 'License activated.',
      license: {
        deviceId,
        expiresAt: verified.payload.expiresAt,
        expiresAtLabel: verified.expiresAtLabel,
        keyHash: resolved.keyHash
      }
    });
  } catch (error) {
    return jsonResponse(res, 400, { ok: false, message: error?.message || 'License activation failed.' });
  }
}

async function validateLicense(req, res, body) {
  const licenseKey = String(body?.licenseKey || '').trim();
  const deviceId = String(body?.deviceId || '').trim().toUpperCase();
  if (!licenseKey || !deviceId) {
    return jsonResponse(res, 400, { ok: false, message: 'licenseKey and deviceId are required.' });
  }

  try {
    const db = await readDb();
    const now = new Date().toISOString();
    const resolved = await getOrCreateRecordFromLicenseKey(db, licenseKey, {
      deviceId,
      activatedAt: now,
      lastValidatedAt: ''
    });
    const verified = resolved.verified;
    if (verified.payload.deviceId !== deviceId) {
      return jsonResponse(res, 403, { ok: false, message: 'License key is for a different computer.' });
    }

    const existing = resolved.record;

    if (existing.revoked) {
      return jsonResponse(res, 403, { ok: false, message: 'License key was revoked.' });
    }
    if (existing.deviceId && existing.deviceId !== deviceId) {
      return jsonResponse(res, 403, { ok: false, message: 'License key is already activated on another computer.' });
    }

    existing.deviceId = deviceId;
    existing.lastValidatedAt = now;
    existing.lastIp = getClientIp(req);
    ensureHistory(existing).push(createHistoryEntry('validate', req, { deviceId }));
    db.licenses[resolved.keyHash] = existing;
    await writeDb(db);

    return jsonResponse(res, 200, {
      ok: true,
      message: 'License is valid.',
      license: {
        deviceId,
        expiresAt: verified.payload.expiresAt,
        expiresAtLabel: verified.expiresAtLabel,
        keyHash: resolved.keyHash
      }
    });
  } catch (error) {
    return jsonResponse(res, 400, { ok: false, message: error?.message || 'License validation failed.' });
  }
}

async function adminChange(req, res, body, mode) {
  try {
    ensureAdmin(req);
    const licenseKey = String(body?.licenseKey || '').trim();
    if (!licenseKey) {
      return jsonResponse(res, 400, { ok: false, message: 'licenseKey is required.' });
    }

    const db = await readDb();
    const resolved = await getOrCreateRecordFromLicenseKey(db, licenseKey, {
      deviceId: '',
      activatedAt: '',
      lastValidatedAt: ''
    });
    const existing = resolved.record;

    if (mode === 'revoke') {
      existing.revoked = true;
      existing.revokedAt = new Date().toISOString();
      ensureHistory(existing).push(createHistoryEntry('revoke', req));
    } else if (mode === 'unrevoke') {
      existing.revoked = false;
      existing.revokedAt = '';
      ensureHistory(existing).push(createHistoryEntry('unrevoke', req));
    } else if (mode === 'reset') {
      existing.deviceId = '';
      existing.activatedAt = '';
      existing.lastValidatedAt = '';
      ensureHistory(existing).push(createHistoryEntry('reset', req));
    }

    db.licenses[resolved.keyHash] = existing;
    await writeDb(db);

    return jsonResponse(res, 200, {
      ok: true,
      message: `License ${mode} completed.`,
      record: sanitizeRecord(existing)
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Admin action failed.' });
  }
}

async function adminStatus(req, res) {
  try {
    ensureAdmin(req);
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const licenseKey = String(url.searchParams.get('licenseKey') || '').trim();
    if (!licenseKey) {
      return jsonResponse(res, 400, { ok: false, message: 'licenseKey query parameter is required.' });
    }

    const db = await readDb();
    const resolved = await getOrCreateRecordFromLicenseKey(db, licenseKey, {
      deviceId: '',
      activatedAt: '',
      lastValidatedAt: ''
    });
    if (resolved.created) {
      await writeDb(db);
    }
    return jsonResponse(res, 200, {
      ok: true,
      record: sanitizeRecord(resolved.record || null)
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Admin action failed.' });
  }
}

async function adminList(req, res) {
  try {
    ensureAdmin(req);
    const db = await readDb();
    const records = Object.values(db.licenses || {})
      .map(sanitizeRecord)
      .sort((a, b) => String(b.lastValidatedAt || '').localeCompare(String(a.lastValidatedAt || '')));
    return jsonResponse(res, 200, {
      ok: true,
      records
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Admin action failed.' });
  }
}

async function managerPrefillToken(res) {
  try {
    const token = await readAndClearPrefillToken();
    return jsonResponse(res, 200, {
      ok: true,
      token
    });
  } catch (error) {
    return jsonResponse(res, 500, {
      ok: false,
      message: error?.message || 'Could not read prefill token.'
    });
  }
}

async function serveAdminPanel(res) {
  try {
    const html = await fs.readFile(ADMIN_PANEL_PATH, 'utf8');
    return textResponse(res, 200, html, 'text/html; charset=utf-8');
  } catch (error) {
    return textResponse(res, 500, error?.message || 'Could not load admin panel.');
  }
}

async function serveManagerPanel(res) {
  try {
    const html = await fs.readFile(MANAGER_PANEL_PATH, 'utf8');
    return textResponse(res, 200, html, 'text/html; charset=utf-8');
  } catch (error) {
    return textResponse(res, 500, error?.message || 'Could not load manager panel.');
  }
}

async function adminGenerate(req, res, body) {
  try {
    ensureAdmin(req);
    const deviceId = String(body?.deviceId || '').trim().toUpperCase();
    const days = body?.days;
    const expiresAt = String(body?.expiresAt || '').trim();
    if (!deviceId) {
      return jsonResponse(res, 400, { ok: false, message: 'deviceId is required.' });
    }

    const licenseKey = generateLicenseKey({
      deviceId,
      days,
      expiresAt
    });
    const verified = verifyLicenseToken(licenseKey);
    const db = await readDb();
    const resolved = await getOrCreateRecordFromLicenseKey(db, licenseKey, {
      deviceId: '',
      activatedAt: '',
      lastValidatedAt: ''
    });
    ensureHistory(resolved.record).push(createHistoryEntry('generate', req, { deviceId }));
    db.licenses[resolved.keyHash] = resolved.record;
    await writeDb(db);

    return jsonResponse(res, 200, {
      ok: true,
      message: 'License key generated.',
      licenseKey,
      record: sanitizeRecord(resolved.record),
      issued: {
        deviceId,
        expiresAt: verified.payload.expiresAt,
        expiresAtLabel: verified.expiresAtLabel
      }
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Could not generate license key.' });
  }
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    return jsonResponse(res, 200, { ok: true });
  }

  if (req.method === 'GET' && req.url === '/health') {
    return jsonResponse(res, 200, {
      ok: true,
      product: PRODUCT_CODE,
      now: new Date().toISOString()
    });
  }

  if (req.method === 'GET' && (req.url === '/' || req.url === '/admin')) {
    return await serveAdminPanel(res);
  }
  if (req.method === 'GET' && req.url === '/manager') {
    return await serveManagerPanel(res);
  }

  try {
    if (req.method === 'GET' && req.url === '/api/admin/prefill-token') {
      return await managerPrefillToken(res);
    }
    if (req.method === 'POST' && req.url === '/api/activate') {
      const body = await readJsonBody(req);
      return await activateLicense(req, res, body);
    }
    if (req.method === 'POST' && req.url === '/api/validate') {
      const body = await readJsonBody(req);
      return await validateLicense(req, res, body);
    }
    if (req.method === 'POST' && req.url === '/api/admin/revoke') {
      const body = await readJsonBody(req);
      return await adminChange(req, res, body, 'revoke');
    }
    if (req.method === 'POST' && req.url === '/api/admin/unrevoke') {
      const body = await readJsonBody(req);
      return await adminChange(req, res, body, 'unrevoke');
    }
    if (req.method === 'POST' && req.url === '/api/admin/reset') {
      const body = await readJsonBody(req);
      return await adminChange(req, res, body, 'reset');
    }
    if (req.method === 'POST' && req.url === '/api/admin/generate') {
      const body = await readJsonBody(req);
      return await adminGenerate(req, res, body);
    }
    if (req.method === 'GET' && req.url.startsWith('/api/admin/status')) {
      return await adminStatus(req, res);
    }
    if (req.method === 'GET' && req.url === '/api/admin/list') {
      return await adminList(req, res);
    }
  } catch (error) {
    return jsonResponse(res, 500, {
      ok: false,
      message: error?.message || 'Unexpected server error.'
    });
  }

  return jsonResponse(res, 404, { ok: false, message: 'Not found.' });
});

await ensureDbFile();
server.listen(PORT, HOST, () => {
  const localBaseUrl = `http://${HOST}:${PORT}`;
  console.log(`Sora license server running at ${localBaseUrl}`);
  console.log(`Database: ${DB_PATH}`);
  if (PUBLIC_BASE_URL) {
    console.log(`Public base URL: ${PUBLIC_BASE_URL}`);
    console.log(`Manager page: ${PUBLIC_BASE_URL.replace(/\/$/, '')}/manager`);
    console.log(`Admin page: ${PUBLIC_BASE_URL.replace(/\/$/, '')}/admin`);
  }
  if (!ADMIN_TOKEN) {
    console.log('ADMIN_TOKEN is not set. Admin HTTP routes are disabled.');
  }
  if (!process.env.LICENSE_PRIVATE_KEY_PEM && !process.env.LICENSE_PRIVATE_KEY_PEM_BASE64) {
    console.log('Using built-in private key. For public deployment, set LICENSE_PRIVATE_KEY_PEM or LICENSE_PRIVATE_KEY_PEM_BASE64.');
  }
});
