import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DB_PATH = path.join(__dirname, 'data', 'licenses.json');
const PRODUCT_CODE = 'sora-all-in-one';
const LICENSE_VERSION = 1;
const PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAER3xb23hrkgsyVcEuBObxLTGHcsuF
CiLXiDYaQDr5SiRg2OxxxvMIP2ZZxSL9TL5qga7aISMKog+x4wfcmtVG/g==
-----END PUBLIC KEY-----`;

function usage() {
  console.log(`Usage:
  node admin.mjs list
  node admin.mjs status --key LICENSE_KEY
  node admin.mjs revoke --key LICENSE_KEY
  node admin.mjs unrevoke --key LICENSE_KEY
  node admin.mjs reset --key LICENSE_KEY
`);
}

function parseArg(name) {
  const index = process.argv.indexOf(name);
  if (index === -1) return '';
  return String(process.argv[index + 1] || '').trim();
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

function base64UrlToBuffer(value) {
  const normalized = String(value || '')
    .replace(/-/g, '+')
    .replace(/_/g, '/')
    .padEnd(Math.ceil(String(value || '').length / 4) * 4, '=');
  return Buffer.from(normalized, 'base64');
}

function parseToken(token) {
  const text = String(token || '').trim();
  const [payloadPart, signaturePart] = text.split('.');
  if (!payloadPart || !signaturePart) {
    throw new Error('License key format is invalid.');
  }
  return {
    token: text,
    payloadPart,
    signature: base64UrlToBuffer(signaturePart),
    payload: JSON.parse(base64UrlToBuffer(payloadPart).toString('utf8'))
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
  return parsed;
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

async function readDb() {
  const raw = await fs.readFile(DB_PATH, 'utf8');
  try {
    return JSON.parse(raw || '{}');
  } catch {
    const repaired = sliceFirstJsonObject(raw);
    const parsed = JSON.parse(repaired || '{}');
    await fs.writeFile(DB_PATH, JSON.stringify(parsed, null, 2));
    return parsed;
  }
}

async function writeDb(db) {
  const tempPath = `${DB_PATH}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(db, null, 2));
  await fs.rename(tempPath, DB_PATH);
}

function sanitizeRecord(record) {
  if (!record) return null;
  return {
    keyHash: record.keyHash,
    deviceId: record.deviceId || '',
    expiresAt: record.expiresAt || '',
    activatedAt: record.activatedAt || '',
    lastValidatedAt: record.lastValidatedAt || '',
    revoked: Boolean(record.revoked),
    revokedAt: record.revokedAt || '',
    historyCount: Array.isArray(record.history) ? record.history.length : 0
  };
}

function createRecordFromLicenseKey(key) {
  const verified = verifyLicenseToken(key);
  return {
    keyHash: sha256Hex(key),
    product: verified.payload.product,
    version: verified.payload.version,
    expiresAt: verified.payload.expiresAt || '',
    deviceId: '',
    activatedAt: '',
    lastValidatedAt: '',
    revoked: false,
    revokedAt: '',
    history: []
  };
}

async function main() {
  const command = String(process.argv[2] || '').trim();
  if (!command) {
    usage();
    process.exit(1);
  }

  const db = await readDb();
  db.licenses = db.licenses || {};

  if (command === 'list') {
    const rows = Object.values(db.licenses).map(sanitizeRecord);
    console.log(JSON.stringify(rows, null, 2));
    return;
  }

  const key = parseArg('--key');
  if (!key) {
    console.error('Missing --key LICENSE_KEY');
    process.exit(1);
  }

  const keyHash = sha256Hex(key);
  const record = db.licenses[keyHash] || createRecordFromLicenseKey(key);
  if (!db.licenses[keyHash]) {
    db.licenses[keyHash] = record;
    await writeDb(db);
  }

  if (command === 'status') {
    console.log(JSON.stringify(sanitizeRecord(record), null, 2));
    return;
  }

  if (command === 'revoke') {
    record.revoked = true;
    record.revokedAt = new Date().toISOString();
  } else if (command === 'unrevoke') {
    record.revoked = false;
    record.revokedAt = '';
  } else if (command === 'reset') {
    record.deviceId = '';
    record.activatedAt = '';
    record.lastValidatedAt = '';
  } else {
    usage();
    process.exit(1);
  }

  db.licenses[keyHash] = record;
  await writeDb(db);
  console.log(JSON.stringify(sanitizeRecord(record), null, 2));
}

main().catch(error => {
  console.error(error?.message || error);
  process.exit(1);
});
