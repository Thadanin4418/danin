import http from 'node:http';
import https from 'node:https';
import fsSync from 'node:fs';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ENV_PATH = path.join(__dirname, '.env');
const execFileAsync = promisify(execFile);
const FACEBOOK_RESOLVE_SCRIPT = path.join(__dirname, 'facebook_resolve.py');

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
const BUY_PANEL_PATH = path.join(__dirname, 'buy-panel.html');
const PREFILL_TOKEN_PATH = path.join(DB_DIR, 'manager-prefill-token.txt');
let writeQueue = Promise.resolve();

const PRODUCT_CODE = 'sora-all-in-one';
const LICENSE_VERSION = 1;
const DEFAULT_LICENSE_DAYS = Math.max(1, Number.parseInt(String(process.env.LICENSE_DURATION_DAYS || '30'), 10) || 30);
const LICENSE_PRICE_USD = parseMoney(process.env.LICENSE_PRICE_USD, 35);
const LICENSE_PRICE_KHR = parseMoney(process.env.LICENSE_PRICE_KHR, null);
const BUY_PRICE_3M_USD = parseMoney(process.env.BUY_PRICE_3M_USD, 105);
const BUY_PRICE_3M_KHR = parseMoney(process.env.BUY_PRICE_3M_KHR, null);
const BUY_PRICE_LIFETIME_USD = parseMoney(process.env.BUY_PRICE_LIFETIME_USD, 250);
const BUY_PRICE_LIFETIME_KHR = parseMoney(process.env.BUY_PRICE_LIFETIME_KHR, null);
const BUY_3M_DAYS = Math.max(1, Number.parseInt(String(process.env.BUY_3M_DAYS || '90'), 10) || 90);
const BUY_LIFETIME_DAYS = Math.max(3650, Number.parseInt(String(process.env.BUY_LIFETIME_DAYS || '36500'), 10) || 36500);
const BUY_ORDER_EXPIRE_MS = Math.max(15 * 1000, Number.parseInt(String(process.env.BUY_ORDER_EXPIRE_MS || '60000'), 10) || 60000);
const BUY_ORDER_HIDE_APPROVED_MS = Math.max(15 * 1000, Number.parseInt(String(process.env.BUY_ORDER_HIDE_APPROVED_MS || String(BUY_ORDER_EXPIRE_MS)), 10) || BUY_ORDER_EXPIRE_MS);
const BAKONG_API_TOKEN = String(process.env.BAKONG_API_TOKEN || '').trim();
const BAKONG_ACCOUNT_ID = String(process.env.BAKONG_ACCOUNT_ID || '').trim();
const BAKONG_MERCHANT_NAME = String(process.env.BAKONG_MERCHANT_NAME || '').trim();
const BAKONG_MERCHANT_CITY = String(process.env.BAKONG_MERCHANT_CITY || 'PHNOM PENH').trim() || 'PHNOM PENH';
const BAKONG_MERCHANT_ID = String(process.env.BAKONG_MERCHANT_ID || '').trim();
const BAKONG_ACQUIRING_BANK = String(process.env.BAKONG_ACQUIRING_BANK || '').trim();
const BAKONG_API_BASE_URL = String(process.env.BAKONG_API_BASE_URL || 'https://api-bakong.nbc.gov.kh').trim().replace(/\/+$/g, '');
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
const TRIAL_POLICY = parseTrialPolicy(process.env.TRIAL_POLICY || '1h');

const EMPTY_DB = {
  version: 1,
  createdAt: null,
  updatedAt: null,
  licenses: {},
  trials: {},
  orders: {},
  settings: {}
};

function parseMoney(value, fallback) {
  const text = String(value ?? '').trim().replace(/[$,\s]/g, '');
  if (!text) return fallback;
  const number = Number(text);
  if (!Number.isFinite(number) || number <= 0) {
    return fallback;
  }
  return number;
}

function formatCountLabel(value, singular) {
  const safeValue = Math.max(1, Number.parseInt(String(value || '1'), 10) || 1);
  return `${safeValue} ${singular}${safeValue === 1 ? '' : 's'}`;
}

function parseTrialPolicy(value) {
  const text = String(value || '1h').trim().toLowerCase();
  if (!text || text === '1h') {
    return {
      raw: '1h',
      mode: 'timed',
      durationMs: 60 * 60 * 1000,
      policyLabel: '1 hour'
    };
  }

  if (['off', 'disabled', 'disable', 'none', 'no'].includes(text)) {
    return {
      raw: text,
      mode: 'disabled',
      durationMs: 0,
      policyLabel: 'Disabled'
    };
  }

  if (['forever', 'always', 'unlimited', 'infinite'].includes(text)) {
    return {
      raw: text,
      mode: 'forever',
      durationMs: Number.POSITIVE_INFINITY,
      policyLabel: 'Unlimited'
    };
  }

  const match = text.match(/^(\d+)\s*(h|hr|hrs|hour|hours|d|day|days|m|mo|mon|month|months)$/i);
  if (!match) {
    return {
      raw: text,
      mode: 'timed',
      durationMs: 60 * 60 * 1000,
      policyLabel: '1 hour'
    };
  }

  const amount = Math.max(1, Number.parseInt(match[1], 10) || 1);
  const unit = match[2].toLowerCase();

  if (unit.startsWith('h')) {
    return {
      raw: text,
      mode: 'timed',
      durationMs: amount * 60 * 60 * 1000,
      policyLabel: formatCountLabel(amount, 'hour')
    };
  }

  if (unit.startsWith('d')) {
    return {
      raw: text,
      mode: 'timed',
      durationMs: amount * 24 * 60 * 60 * 1000,
      policyLabel: formatCountLabel(amount, 'day')
    };
  }

  return {
    raw: text,
    mode: 'timed',
    durationMs: amount * 30 * 24 * 60 * 60 * 1000,
    policyLabel: amount === 1 ? '1 month' : `${amount} months`
  };
}

function formatUsd(value) {
  if (!Number.isFinite(value)) return '';
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 2
  }).format(value);
}

function formatKhr(value) {
  if (!Number.isFinite(value)) return '';
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'KHR',
    maximumFractionDigits: 0
  }).format(value);
}

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
      : {},
    trials: db?.trials && typeof db.trials === 'object'
      ? db.trials
      : {},
    orders: db?.orders && typeof db.orders === 'object'
      ? db.orders
      : {},
    settings: db?.settings && typeof db.settings === 'object'
      ? db.settings
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
    hasLicenseKey: Boolean(record.licenseKey),
    revoked: Boolean(record.revoked),
    revokedAt: record.revokedAt || '',
    lastIp: record.lastIp || '',
    historyCount: Array.isArray(record.history) ? record.history.length : 0
  };
}

function sanitizeTrialRecord(record) {
  if (!record) return null;
  return {
    deviceId: String(record.deviceId || '').trim().toUpperCase(),
    startedAt: record.startedAt || '',
    endsAt: record.endsAt || '',
    active: Boolean(record.active),
    expired: Boolean(record.expired),
    lastIp: record.lastIp || '',
    historyCount: Array.isArray(record.history) ? record.history.length : 0
  };
}

function sanitizeOrderRecord(record, options = {}) {
  if (!record) return null;
  const expiresAtMs = Date.parse(String(record.licenseExpiresAt || ''));
  const createdAtMs = Date.parse(String(record.createdAt || ''));
  const orderExpiresAtMs = Number.isFinite(createdAtMs) ? createdAtMs + BUY_ORDER_EXPIRE_MS : NaN;
  return {
    orderId: String(record.orderId || '').trim().toUpperCase(),
    deviceId: String(record.deviceId || '').trim().toUpperCase(),
    status: String(record.status || 'pending').trim().toLowerCase(),
    planId: String(record.planId || '').trim(),
    planLabel: String(record.planLabel || '').trim(),
    requestedDays: Number.isFinite(record.requestedDays) ? record.requestedDays : null,
    amountUsd: Number.isFinite(record.amountUsd) ? record.amountUsd : null,
    amountUsdLabel: Number.isFinite(record.amountUsd) ? formatUsd(record.amountUsd) : '',
    amountKhr: Number.isFinite(record.amountKhr) ? record.amountKhr : null,
    amountKhrLabel: Number.isFinite(record.amountKhr) ? formatKhr(record.amountKhr) : '',
    bakongAccountId: String(record.bakongAccountId || '').trim(),
    merchantName: String(record.merchantName || '').trim(),
    merchantId: String(record.merchantId || '').trim(),
    acquiringBank: String(record.acquiringBank || '').trim(),
    createdAt: record.createdAt || '',
    orderExpiresAt: Number.isFinite(orderExpiresAtMs) ? new Date(orderExpiresAtMs).toISOString() : '',
    orderExpiresAtLabel: Number.isFinite(orderExpiresAtMs)
      ? new Date(orderExpiresAtMs).toLocaleString()
      : '',
    expiredAt: record.expiredAt || '',
    approvedAt: record.approvedAt || '',
    licenseExpiresAt: record.licenseExpiresAt || '',
    licenseExpiresAtLabel: Number.isFinite(expiresAtMs)
      ? new Date(expiresAtMs).toLocaleString()
      : '',
    paymentNote: options.includeNote ? String(record.paymentNote || '').trim() : '',
    khqrString: options.includeNote ? String(record.khqrString || '').trim() : '',
    khqrMd5: options.includeNote ? String(record.khqrMd5 || '').trim() : '',
    autoPaymentEnabled: Boolean(record.autoPaymentEnabled),
    paymentCheckedAt: record.paymentCheckedAt || '',
    paymentMode: String(record.paymentMode || 'manual-bakong').trim(),
    historyCount: Array.isArray(record.history) ? record.history.length : 0
  };
}

let bakongSdkPromise = null;

async function loadBakongSdk() {
  if (!bakongSdkPromise) {
    bakongSdkPromise = (async () => {
      const mod = await import('bakong-khqr');
      const source = mod?.default && !mod.BakongKHQR ? mod.default : mod;
      const sdk = {
        BakongKHQR: source.BakongKHQR || mod.BakongKHQR,
        khqrData: source.khqrData || mod.khqrData,
        IndividualInfo: source.IndividualInfo || mod.IndividualInfo
      };
      if (!sdk.BakongKHQR || !sdk.khqrData || !sdk.IndividualInfo) {
        throw new Error('Bakong KHQR SDK exports are unavailable.');
      }
      return sdk;
    })();
  }
  return bakongSdkPromise;
}

function getBakongMerchantName() {
  if (BAKONG_MERCHANT_NAME) return BAKONG_MERCHANT_NAME;
  const fallback = String(BAKONG_ACCOUNT_ID || '')
    .split('@')[0]
    .replace(/[_-]+/g, ' ')
    .trim();
  return fallback || 'DANIN THA';
}

function isBakongAutoPaymentReady() {
  return Boolean(BAKONG_API_TOKEN && BAKONG_ACCOUNT_ID);
}

function getBuyPlans() {
  const plans = [];

  if (Number.isFinite(LICENSE_PRICE_USD) || Number.isFinite(LICENSE_PRICE_KHR)) {
    plans.push({
      id: '1m',
      label: '1 Month',
      description: `${formatCountLabel(Math.round(DEFAULT_LICENSE_DAYS / 30) || 1, 'month')} access for one computer`,
      days: DEFAULT_LICENSE_DAYS,
      amountUsd: Number.isFinite(LICENSE_PRICE_USD) ? LICENSE_PRICE_USD : null,
      amountUsdLabel: Number.isFinite(LICENSE_PRICE_USD) ? formatUsd(LICENSE_PRICE_USD) : '',
      amountKhr: Number.isFinite(LICENSE_PRICE_KHR) ? LICENSE_PRICE_KHR : null,
      amountKhrLabel: Number.isFinite(LICENSE_PRICE_KHR) ? formatKhr(LICENSE_PRICE_KHR) : ''
    });
  }

  if (Number.isFinite(BUY_PRICE_3M_USD) || Number.isFinite(BUY_PRICE_3M_KHR)) {
    plans.push({
      id: '3m',
      label: '3 Months',
      description: `${formatCountLabel(Math.round(BUY_3M_DAYS / 30), 'month')} access for one computer`,
      days: BUY_3M_DAYS,
      amountUsd: Number.isFinite(BUY_PRICE_3M_USD) ? BUY_PRICE_3M_USD : null,
      amountUsdLabel: Number.isFinite(BUY_PRICE_3M_USD) ? formatUsd(BUY_PRICE_3M_USD) : '',
      amountKhr: Number.isFinite(BUY_PRICE_3M_KHR) ? BUY_PRICE_3M_KHR : null,
      amountKhrLabel: Number.isFinite(BUY_PRICE_3M_KHR) ? formatKhr(BUY_PRICE_3M_KHR) : ''
    });
  }

  if (Number.isFinite(BUY_PRICE_LIFETIME_USD) || Number.isFinite(BUY_PRICE_LIFETIME_KHR)) {
    plans.push({
      id: 'lifetime',
      label: 'Lifetime',
      description: 'One computer lifetime access',
      days: BUY_LIFETIME_DAYS,
      lifetime: true,
      amountUsd: Number.isFinite(BUY_PRICE_LIFETIME_USD) ? BUY_PRICE_LIFETIME_USD : null,
      amountUsdLabel: Number.isFinite(BUY_PRICE_LIFETIME_USD) ? formatUsd(BUY_PRICE_LIFETIME_USD) : '',
      amountKhr: Number.isFinite(BUY_PRICE_LIFETIME_KHR) ? BUY_PRICE_LIFETIME_KHR : null,
      amountKhrLabel: Number.isFinite(BUY_PRICE_LIFETIME_KHR) ? formatKhr(BUY_PRICE_LIFETIME_KHR) : ''
    });
  }

  return plans;
}

function getBuyPlanById(planId) {
  const normalized = String(planId || '').trim().toLowerCase();
  const plans = getBuyPlans();
  return plans.find(plan => plan.id === normalized) || plans[0] || null;
}

function getBuyConfig() {
  const plans = getBuyPlans();
  return {
    enabled: Boolean(BAKONG_ACCOUNT_ID && plans.length),
    paymentMode: isBakongAutoPaymentReady() ? 'bakong-auto' : 'manual-bakong',
    bakongAccountId: BAKONG_ACCOUNT_ID,
    merchantName: getBakongMerchantName(),
    merchantId: BAKONG_MERCHANT_ID,
    acquiringBank: BAKONG_ACQUIRING_BANK,
    merchantCity: BAKONG_MERCHANT_CITY,
    amountUsd: plans[0]?.amountUsd ?? null,
    amountUsdLabel: plans[0]?.amountUsdLabel || '',
    amountKhr: plans[0]?.amountKhr ?? null,
    amountKhrLabel: plans[0]?.amountKhrLabel || '',
    defaultLicenseDays: DEFAULT_LICENSE_DAYS,
    hasBakongApiToken: Boolean(BAKONG_API_TOKEN),
    autoPaymentEnabled: isBakongAutoPaymentReady(),
    plans
  };
}

function getEffectiveTrialPolicy(db) {
  const configured = String(db?.settings?.trialPolicy || '').trim();
  return parseTrialPolicy(configured || TRIAL_POLICY.raw);
}

function sanitizeSettings(db) {
  const policy = getEffectiveTrialPolicy(db);
  return {
    trialPolicy: policy.raw,
    trialPolicyMode: policy.mode,
    trialPolicyLabel: policy.policyLabel,
    source: String(db?.settings?.trialPolicy || '').trim() ? 'manager' : 'environment'
  };
}

function createOrderId() {
  const random = crypto.randomBytes(4).toString('hex').toUpperCase();
  const stamp = Date.now().toString(36).toUpperCase();
  return `ORD-${stamp}-${random}`;
}

function getOrderStatus(order) {
  return String(order?.status || 'pending').trim().toLowerCase();
}

function getOrderCreatedAtMs(order) {
  return Date.parse(String(order?.createdAt || ''));
}

function getOrderApprovedAtMs(order) {
  return Date.parse(String(order?.approvedAt || ''));
}

function createSystemHistoryEntry(type, extra = {}) {
  return {
    type,
    at: new Date().toISOString(),
    ip: '',
    ...extra
  };
}

function expireStaleBuyOrders(db) {
  const nowMs = Date.now();
  let changed = false;

  Object.values(db.orders || {}).forEach((order) => {
    if (getOrderStatus(order) !== 'pending') return;
    const createdAtMs = getOrderCreatedAtMs(order);
    if (!Number.isFinite(createdAtMs)) return;
    if ((nowMs - createdAtMs) < BUY_ORDER_EXPIRE_MS) return;

    order.status = 'expired';
    order.expiredAt = new Date(nowMs).toISOString();
    order.paymentCheckedAt = order.expiredAt;
    ensureHistory(order).push(createSystemHistoryEntry('order-expired', {
      orderId: order.orderId,
      reason: `Pending longer than ${Math.round(BUY_ORDER_EXPIRE_MS / 1000)} seconds.`
    }));
    changed = true;
  });

  return changed;
}

function shouldHideBuyOrderFromAdminList(order) {
  const status = getOrderStatus(order);
  if (status === 'expired') return true;
  if (status !== 'approved') return false;

  const approvedAtMs = getOrderApprovedAtMs(order);
  if (!Number.isFinite(approvedAtMs)) return false;
  return (Date.now() - approvedAtMs) >= BUY_ORDER_HIDE_APPROVED_MS;
}

function buildPaymentNote(order) {
  const lines = [
    'SORA LICENSE ORDER',
    '',
    `Order ID: ${order.orderId}`,
    `Device ID: ${order.deviceId}`
  ];

  if (order.planLabel) {
    lines.push(`Plan: ${order.planLabel}`);
  }

  if (Number.isFinite(order.amountUsd)) {
    lines.push(`Amount (USD): ${formatUsd(order.amountUsd)}`);
  }
  if (Number.isFinite(order.amountKhr)) {
    lines.push(`Amount (KHR): ${formatKhr(order.amountKhr)}`);
  }
  if (order.bakongAccountId) {
    lines.push(`Bakong ID: ${order.bakongAccountId}`);
  }

  lines.push('', order.autoPaymentEnabled
    ? 'After payment, the server will try to approve this order automatically. The extension can auto-restore the license for this computer.'
    : 'After payment, wait for admin approval. The extension can auto-restore the license for this computer.');
  return lines.join('\n');
}

async function generateBakongKhqrForOrder(order) {
  const { BakongKHQR, khqrData, IndividualInfo } = await loadBakongSdk();
  const config = getBuyConfig();
  const currencyCode = Number.isFinite(order.amountUsd) ? khqrData.currency.usd : khqrData.currency.khr;
  const optionalData = {
    currency: currencyCode,
    amount: Number.isFinite(order.amountUsd) ? order.amountUsd : order.amountKhr,
    billNumber: order.orderId,
    storeLabel: 'Sora License',
    terminalLabel: 'Chrome',
    purposeOfTransaction: order.planLabel || 'Sora License',
    // Dynamic KHQR with amount should expire to avoid reusing an old payment session.
    expirationTimestamp: Date.now() + (15 * 60 * 1000)
  };
  if (BAKONG_ACQUIRING_BANK) {
    optionalData.acquiringBank = BAKONG_ACQUIRING_BANK;
  }

  const individualInfo = new IndividualInfo(
    config.bakongAccountId,
    config.merchantName || getBakongMerchantName(),
    config.merchantCity || BAKONG_MERCHANT_CITY,
    optionalData
  );

  const khqr = new BakongKHQR();
  const result = khqr.generateIndividual(individualInfo);
  if (result?.status?.code !== 0 || !result?.data?.qr || !result?.data?.md5) {
    throw new Error(result?.status?.message || 'Could not generate KHQR.');
  }

  return {
    qr: String(result.data.qr || '').trim(),
    md5: String(result.data.md5 || '').trim()
  };
}

async function checkBakongTransactionByMd5(md5) {
  const response = await fetch(`${BAKONG_API_BASE_URL}/v1/check_transaction_by_md5`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${BAKONG_API_TOKEN}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ md5 })
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data?.responseMessage || data?.message || 'Bakong transaction check failed.');
  }
  return data;
}

function isMatchingPaidOrder(order, paymentData) {
  const expectedAccount = String(BAKONG_ACCOUNT_ID || '').trim().toLowerCase();
  const toAccount = String(paymentData?.toAccountId || '').trim().toLowerCase();
  if (expectedAccount && toAccount && expectedAccount !== toAccount) {
    return false;
  }

  const paidAmount = Number(paymentData?.amount);
  if (Number.isFinite(order.amountUsd)) {
    return Number.isFinite(paidAmount) && Math.abs(paidAmount - order.amountUsd) < 0.0001;
  }
  if (Number.isFinite(order.amountKhr)) {
    return Number.isFinite(paidAmount) && Math.abs(paidAmount - order.amountKhr) < 0.0001;
  }
  return false;
}

function normalizeDeviceId(value) {
  const text = String(value || '').trim().toUpperCase();
  return /^[A-F0-9]{32}$/.test(text) ? text : '';
}

function normalizeDeviceIdList(values, primary = '') {
  const output = [];
  const seen = new Set();

  [primary].concat(Array.isArray(values) ? values : [values]).forEach((value) => {
    const normalized = normalizeDeviceId(value);
    if (!normalized || seen.has(normalized)) return;
    seen.add(normalized);
    output.push(normalized);
  });

  return output;
}

function getRequestedDeviceIds(body) {
  return normalizeDeviceIdList(body?.deviceIdAliases || [], body?.deviceId || '');
}

function getRecordAliasDeviceIds(record) {
  return normalizeDeviceIdList(record?.aliasDeviceIds || [], '');
}

function deviceRecordMatches(record, deviceIds, fields = ['deviceId']) {
  const requested = normalizeDeviceIdList(deviceIds || [], '');
  if (!requested.length) return false;

  for (const field of fields) {
    if (requested.includes(normalizeDeviceId(record?.[field] || ''))) {
      return true;
    }
  }

  const aliases = getRecordAliasDeviceIds(record);
  return aliases.some(alias => requested.includes(alias));
}

function mergeRecordDeviceAliases(record, nextPrimary, extraValues = []) {
  const merged = normalizeDeviceIdList([
    ...(record?.aliasDeviceIds || []),
    record?.deviceId || '',
    record?.licensedDeviceId || '',
    ...extraValues
  ], '');

  record.aliasDeviceIds = merged.filter(value => value !== normalizeDeviceId(nextPrimary));
  return record.aliasDeviceIds;
}

function findExistingOrderByDeviceId(db, deviceIds) {
  const normalizedDeviceIds = normalizeDeviceIdList(deviceIds || [], '');
  if (!normalizedDeviceIds.length) return null;

  const orders = Object.values(db.orders || {})
    .filter(order => deviceRecordMatches(order, normalizedDeviceIds, ['deviceId']))
    .sort((a, b) => String(b?.createdAt || '').localeCompare(String(a?.createdAt || '')));

  return orders.find(order => getOrderStatus(order) === 'pending')
    || orders.find(order => getOrderStatus(order) === 'approved')
    || null;
}

function createEmptyRecordFromVerified(verified, keyHash, options = {}) {
  return {
    keyHash,
    product: verified.payload.product,
    version: verified.payload.version,
    expiresAt: verified.payload.expiresAt,
    licensedDeviceId: verified.payload.deviceId || '',
    licenseKey: options.licenseKey || '',
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
    if (!existing.licenseKey) {
      existing.licenseKey = String(licenseKey || '').trim();
    }
    return {
      record: existing,
      verified,
      keyHash,
      created: false
    };
  }

  const record = createEmptyRecordFromVerified(verified, keyHash, {
    licenseKey: String(licenseKey || '').trim(),
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

function findAutoActivatableRecord(db, deviceIds) {
  const normalizedDeviceIds = normalizeDeviceIdList(deviceIds || [], '');
  if (!normalizedDeviceIds.length) return null;

  const nowMs = Date.now();
  const records = Object.values(db.licenses || {})
    .filter(record => deviceRecordMatches(record, normalizedDeviceIds, ['licensedDeviceId', 'deviceId']))
    .filter(record => !record?.revoked)
    .filter(record => String(record?.licenseKey || '').trim())
    .filter(record => {
      const expiresAtMs = Date.parse(String(record?.expiresAt || ''));
      return Number.isFinite(expiresAtMs) && expiresAtMs > nowMs;
    })
    .sort((a, b) => Date.parse(String(b?.expiresAt || '')) - Date.parse(String(a?.expiresAt || '')));

  return records[0] || null;
}

function findTrialRecord(db, deviceIds) {
  const normalizedDeviceIds = normalizeDeviceIdList(deviceIds || [], '');
  if (!normalizedDeviceIds.length) return null;

  const directMatch = normalizedDeviceIds.find(deviceId => db.trials?.[deviceId]);
  if (directMatch) {
    return {
      key: directMatch,
      record: db.trials[directMatch]
    };
  }

  const record = Object.values(db.trials || {}).find(item => deviceRecordMatches(item, normalizedDeviceIds, ['deviceId']));
  if (!record) return null;

  return {
    key: normalizeDeviceId(record.deviceId || ''),
    record
  };
}

function migrateTrialRecordToDeviceId(db, trialEntry, nextDeviceId, req) {
  const record = trialEntry?.record;
  const previousKey = normalizeDeviceId(trialEntry?.key || '');
  const targetDeviceId = normalizeDeviceId(nextDeviceId);
  if (!record || !targetDeviceId) return record;

  mergeRecordDeviceAliases(record, targetDeviceId, [previousKey]);
  record.deviceId = targetDeviceId;
  record.lastIp = getClientIp(req);
  ensureHistory(record).push(createHistoryEntry('trial-device-migrate', req, {
    fromDeviceId: previousKey,
    toDeviceId: targetDeviceId
  }));

  if (previousKey && previousKey !== targetDeviceId) {
    delete db.trials[previousKey];
  }
  db.trials[targetDeviceId] = record;
  return record;
}

function rekeyLicenseRecord(db, oldKeyHash, record, newKeyHash) {
  if (oldKeyHash && oldKeyHash !== newKeyHash) {
    delete db.licenses[oldKeyHash];
  }
  db.licenses[newKeyHash] = record;

  Object.values(db.orders || {}).forEach((order) => {
    if (String(order?.approvedLicenseKeyHash || '').trim() === String(oldKeyHash || '').trim()) {
      order.approvedLicenseKeyHash = newKeyHash;
    }
  });
}

function migrateLicenseRecordToDeviceId(db, record, nextDeviceId, req) {
  const targetDeviceId = normalizeDeviceId(nextDeviceId);
  if (!record || !targetDeviceId) {
    throw new Error('deviceId is required.');
  }

  const oldKeyHash = String(record.keyHash || '').trim();
  const previousLicensedDeviceId = normalizeDeviceId(record.licensedDeviceId || '');
  const previousRuntimeDeviceId = normalizeDeviceId(record.deviceId || '');
  const nextLicenseKey = generateLicenseKey({
    deviceId: targetDeviceId,
    expiresAt: record.expiresAt
  });
  const verified = verifyLicenseToken(nextLicenseKey);
  const nextKeyHash = sha256Hex(nextLicenseKey);
  const now = new Date().toISOString();

  mergeRecordDeviceAliases(record, targetDeviceId, [previousLicensedDeviceId, previousRuntimeDeviceId]);
  record.keyHash = nextKeyHash;
  record.licensedDeviceId = targetDeviceId;
  record.licenseKey = nextLicenseKey;
  record.deviceId = targetDeviceId;
  record.activatedAt = record.activatedAt || now;
  record.lastValidatedAt = now;
  record.lastIp = getClientIp(req);
  ensureHistory(record).push(createHistoryEntry('device-migrate', req, {
    fromDeviceId: previousLicensedDeviceId || previousRuntimeDeviceId,
    toDeviceId: targetDeviceId
  }));

  rekeyLicenseRecord(db, oldKeyHash, record, nextKeyHash);

  return {
    record,
    licenseKey: nextLicenseKey,
    verified
  };
}

async function trialStatus(req, res, body) {
  const deviceId = normalizeDeviceId(body?.deviceId || '');
  const requestedDeviceIds = getRequestedDeviceIds(body);
  if (!deviceId) {
    return jsonResponse(res, 400, { ok: false, message: 'deviceId is required.' });
  }

  try {
    const db = await readDb();
    const nowMs = Date.now();
    const nowIso = new Date(nowMs).toISOString();
    const policy = getEffectiveTrialPolicy(db);
    let record = db.trials[deviceId];

    if (policy.mode === 'disabled') {
      return jsonResponse(res, 200, {
        ok: true,
        trial: {
          deviceId,
          active: false,
          expired: false,
          disabled: true,
          forever: false,
          mode: policy.mode,
          startedAt: '',
          endsAt: '',
          expiresAtLabel: 'Disabled',
          policyLabel: policy.policyLabel
        }
      });
    }

    if (!record) {
      const existing = findTrialRecord(db, requestedDeviceIds);
      if (existing?.record) {
        record = migrateTrialRecordToDeviceId(db, existing, deviceId, req);
      }
    }

    if (!record) {
      record = {
        deviceId,
        aliasDeviceIds: normalizeDeviceIdList(requestedDeviceIds, deviceId).filter(value => value !== deviceId),
        startedAt: nowIso,
        endsAt: new Date(nowMs + TRIAL_DURATION_MS).toISOString(),
        lastIp: getClientIp(req),
        history: [createHistoryEntry('trial-start', req, { deviceId })]
      };
      db.trials[deviceId] = record;
      await writeDb(db);
    }

    if (policy.mode === 'forever') {
      mergeRecordDeviceAliases(record, deviceId, requestedDeviceIds);
      record.lastIp = getClientIp(req);
      db.trials[deviceId] = record;
      await writeDb(db);

      return jsonResponse(res, 200, {
        ok: true,
        trial: {
          ...sanitizeTrialRecord({
            ...record,
            active: true,
            expired: false
          }),
          forever: true,
          disabled: false,
          mode: policy.mode,
          endsAt: '',
          expiresAtLabel: 'No expiry',
          policyLabel: policy.policyLabel
        }
      });
    }

    const startedAtMs = Date.parse(String(record.startedAt || nowIso));
    const endsAtMs = Number.isFinite(startedAtMs)
      ? startedAtMs + policy.durationMs
      : nowMs + policy.durationMs;
    const nextEndsAt = new Date(endsAtMs).toISOString();
    record.endsAt = nextEndsAt;
    mergeRecordDeviceAliases(record, deviceId, requestedDeviceIds);
    record.lastIp = getClientIp(req);
    db.trials[deviceId] = record;
    await writeDb(db);

    const active = Number.isFinite(endsAtMs) && nowMs < endsAtMs;
    const expired = !active;

    return jsonResponse(res, 200, {
      ok: true,
      trial: {
        ...sanitizeTrialRecord({
          ...record,
          active,
          expired
        }),
        forever: false,
        disabled: false,
        mode: policy.mode,
        endsAt: nextEndsAt,
        expiresAtLabel: Number.isFinite(endsAtMs)
          ? new Date(endsAtMs).toLocaleString()
          : 'Unknown',
        policyLabel: policy.policyLabel
      }
    });
  } catch (error) {
    return jsonResponse(res, 400, { ok: false, message: error?.message || 'Could not check trial status.' });
  }
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

function requestManualRedirect(rawUrl, method = 'HEAD') {
  return new Promise((resolve, reject) => {
    const parsed = new URL(rawUrl);
    const client = parsed.protocol === 'https:' ? https : http;
    const request = client.request(
      parsed,
      {
        method,
        headers: {
          'user-agent': 'Mozilla/5.0',
          accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        }
      },
      (response) => {
        const location = response.headers.location
          ? new URL(response.headers.location, parsed).toString()
          : '';
        response.resume();
        response.on('end', () => {
          resolve({
            statusCode: response.statusCode || 0,
            location
          });
        });
      }
    );

    request.setTimeout(10000, () => {
      request.destroy(new Error('Timeout while resolving Facebook URL.'));
    });
    request.on('error', reject);
    request.end();
  });
}

async function requestManualRedirectWithCurl(rawUrl) {
  const { stdout } = await execFileAsync(
    'curl',
    ['-sSI', '-A', 'Mozilla/5.0', rawUrl],
    {
      cwd: __dirname,
      timeout: 10000,
      maxBuffer: 512 * 1024
    }
  );
  const locationLine = String(stdout || '')
    .split(/\r?\n/)
    .find((line) => /^location:/i.test(String(line || '')));
  return {
    location: locationLine
      ? locationLine.replace(/^location:\s*/i, '').trim()
      : ''
  };
}

async function normalizeFacebookResolveUrl(rawUrl) {
  try {
    const parsed = new URL(String(rawUrl || '').trim());
    const host = (parsed.hostname || '').toLowerCase();
    if (!(host === 'fb.watch' || host.endsWith('.fb.watch'))) {
      return String(rawUrl || '').trim();
    }

    for (const method of ['HEAD', 'GET']) {
      try {
        const probe = await requestManualRedirect(parsed.toString(), method);
        if (!probe.location) {
          continue;
        }

        const nextUrl = new URL(probe.location, parsed);
        const videoId = nextUrl.searchParams.get('v');
        if ((nextUrl.hostname || '').toLowerCase().endsWith('.facebook.com') && videoId) {
          return `https://www.facebook.com/watch/?v=${videoId}`;
        }

        return nextUrl.toString();
      } catch {
        continue;
      }
    }

    try {
      const curlProbe = await requestManualRedirectWithCurl(parsed.toString());
      if (curlProbe.location) {
        const nextUrl = new URL(curlProbe.location, parsed);
        const videoId = nextUrl.searchParams.get('v');
        if ((nextUrl.hostname || '').toLowerCase().endsWith('.facebook.com') && videoId) {
          return `https://www.facebook.com/watch/?v=${videoId}`;
        }
        return nextUrl.toString();
      }
    } catch {}

    return String(rawUrl || '').trim();
  } catch {
    return String(rawUrl || '').trim();
  }
}

async function resolveFacebookVideo(req, res, body) {
  const rawUrl = String(body?.url || body?.raw_input || '').trim();
  if (!rawUrl) {
    return jsonResponse(res, 400, { ok: false, message: 'url is required.' });
  }

  const requestedQuality = String(body?.quality || 'auto').trim().toLowerCase();
  const quality = ['auto', 'high', 'low'].includes(requestedQuality) ? requestedQuality : 'auto';

  try {
    const normalizedInput = await normalizeFacebookResolveUrl(rawUrl);
    const { stdout } = await execFileAsync(
      'python3',
      [FACEBOOK_RESOLVE_SCRIPT, normalizedInput, quality],
      {
        cwd: __dirname,
        timeout: 120000,
        maxBuffer: 10 * 1024 * 1024
      }
    );

    const payload = JSON.parse(String(stdout || '').trim() || '{}');
    return jsonResponse(res, 200, {
      ok: true,
      ...payload
    });
  } catch (error) {
    const stderrText = String(error?.stderr || '').trim();
    const stdoutText = String(error?.stdout || '').trim();
    const message = stderrText || stdoutText || error?.message || 'Facebook resolve failed.';
    const statusCode = /required|supported|no direct|could not|failed/i.test(message) ? 400 : 500;
    return jsonResponse(res, statusCode, {
      ok: false,
      message
    });
  }
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

async function autoActivateLicense(req, res, body) {
  const deviceId = normalizeDeviceId(body?.deviceId || '');
  const requestedDeviceIds = getRequestedDeviceIds(body);
  if (!deviceId) {
    return jsonResponse(res, 400, { ok: false, message: 'deviceId is required.' });
  }

  try {
    const db = await readDb();
    let record = findAutoActivatableRecord(db, requestedDeviceIds);
    if (!record) {
      return jsonResponse(res, 404, { ok: false, message: 'No active license was found for this computer.' });
    }

    let licenseKey = String(record.licenseKey || '').trim();
    let expiresAt = record.expiresAt;
    let expiresAtLabel = new Date(Date.parse(String(record.expiresAt || ''))).toLocaleString();

    if (normalizeDeviceId(record.licensedDeviceId || '') !== deviceId) {
      const migrated = migrateLicenseRecordToDeviceId(db, record, deviceId, req);
      record = migrated.record;
      licenseKey = migrated.licenseKey;
      expiresAt = migrated.verified.payload.expiresAt;
      expiresAtLabel = migrated.verified.expiresAtLabel;
    } else {
      const now = new Date().toISOString();
      if (record.deviceId && normalizeDeviceId(record.deviceId) && normalizeDeviceId(record.deviceId) !== deviceId) {
        return jsonResponse(res, 403, { ok: false, message: 'License key is already activated on another computer.' });
      }

      record.deviceId = deviceId;
      record.activatedAt = record.activatedAt || now;
      record.lastValidatedAt = now;
      record.lastIp = getClientIp(req);
      mergeRecordDeviceAliases(record, deviceId, requestedDeviceIds);
      ensureHistory(record).push(createHistoryEntry('auto-activate', req, { deviceId }));
      db.licenses[record.keyHash] = record;
    }
    await writeDb(db);

    return jsonResponse(res, 200, {
      ok: true,
      message: 'License restored for this computer.',
      licenseKey,
      license: {
        deviceId,
        expiresAt,
        expiresAtLabel,
        keyHash: record.keyHash
      }
    });
  } catch (error) {
    return jsonResponse(res, 400, { ok: false, message: error?.message || 'Automatic license restore failed.' });
  }
}

async function buyConfig(req, res) {
  return jsonResponse(res, 200, {
    ok: true,
    config: getBuyConfig()
  });
}

async function createBuyRequest(req, res, body) {
  const deviceId = normalizeDeviceId(body?.deviceId || '');
  const requestedDeviceIds = getRequestedDeviceIds(body);
  const requestedPlanId = String(body?.planId || '').trim().toLowerCase();
  if (!deviceId) {
    return jsonResponse(res, 400, { ok: false, message: 'deviceId is required.' });
  }

  const config = getBuyConfig();
  if (!config.enabled) {
    return jsonResponse(res, 503, {
      ok: false,
      message: 'Buy License is not configured yet. Set BAKONG_ACCOUNT_ID and a license price first.'
    });
  }

  const selectedPlan = getBuyPlanById(requestedPlanId);
  if (!selectedPlan) {
    return jsonResponse(res, 400, { ok: false, message: 'Selected buy plan is invalid.' });
  }

  try {
    const db = await readDb();
    expireStaleBuyOrders(db);
    let order = findExistingOrderByDeviceId(db, requestedDeviceIds);

    if (order && String(order.status || '').trim().toLowerCase() === 'approved') {
      order = null;
    }
    if (order && String(order.planId || '').trim().toLowerCase() !== selectedPlan.id) {
      order = null;
    }

    if (order && normalizeDeviceId(order.deviceId || '') !== deviceId) {
      mergeRecordDeviceAliases(order, deviceId, requestedDeviceIds);
      order.deviceId = deviceId;
      order.lastIp = getClientIp(req);
      ensureHistory(order).push(createHistoryEntry('order-device-migrate', req, {
        orderId: order.orderId,
        toDeviceId: deviceId
      }));
      db.orders[order.orderId] = order;
    }

    if (!order) {
      const now = new Date().toISOString();
      order = {
        orderId: createOrderId(),
        deviceId,
        aliasDeviceIds: normalizeDeviceIdList(requestedDeviceIds, deviceId).filter(value => value !== deviceId),
        planId: selectedPlan.id,
        planLabel: selectedPlan.label,
        requestedDays: selectedPlan.days,
        status: 'pending',
        amountUsd: selectedPlan.amountUsd,
        amountKhr: selectedPlan.amountKhr,
        bakongAccountId: config.bakongAccountId,
        merchantName: config.merchantName,
        merchantId: config.merchantId,
        acquiringBank: config.acquiringBank,
        paymentMode: config.paymentMode,
        autoPaymentEnabled: Boolean(config.autoPaymentEnabled),
        createdAt: now,
        approvedAt: '',
        licenseExpiresAt: '',
        approvedLicenseKeyHash: '',
        paymentCheckedAt: '',
        khqrString: '',
        khqrMd5: '',
        lastIp: getClientIp(req),
        history: []
      };
      if (config.autoPaymentEnabled) {
        try {
          const khqr = await generateBakongKhqrForOrder(order);
          order.khqrString = khqr.qr;
          order.khqrMd5 = khqr.md5;
        } catch (error) {
          order.autoPaymentEnabled = false;
          order.paymentMode = 'manual-bakong';
          ensureHistory(order).push(createHistoryEntry('khqr-fallback-manual', req, {
            message: error?.message || 'KHQR auto generation failed.'
          }));
        }
      }
      order.paymentNote = buildPaymentNote(order);
      ensureHistory(order).push(createHistoryEntry('buy-request', req, {
        orderId: order.orderId,
        deviceId
      }));
      db.orders[order.orderId] = order;
      await writeDb(db);
    } else if (order) {
      order.planId = selectedPlan.id;
      order.planLabel = selectedPlan.label;
      order.requestedDays = selectedPlan.days;
      order.amountUsd = selectedPlan.amountUsd;
      order.amountKhr = selectedPlan.amountKhr;
      order.autoPaymentEnabled = Boolean(config.autoPaymentEnabled);
      if (config.autoPaymentEnabled && (!order.khqrString || !order.khqrMd5)) {
        try {
          const khqr = await generateBakongKhqrForOrder(order);
          order.khqrString = khqr.qr;
          order.khqrMd5 = khqr.md5;
        } catch (error) {
          order.autoPaymentEnabled = false;
          order.paymentMode = 'manual-bakong';
          ensureHistory(order).push(createHistoryEntry('khqr-fallback-manual', req, {
            message: error?.message || 'KHQR auto generation failed.'
          }));
        }
      }
      order.paymentNote = buildPaymentNote(order);
      db.orders[order.orderId] = order;
      await writeDb(db);
    }

    return jsonResponse(res, 200, {
      ok: true,
      message: 'Buy request prepared.',
      config,
      order: sanitizeOrderRecord(order, { includeNote: true })
    });
  } catch (error) {
    return jsonResponse(res, 400, {
      ok: false,
      message: error?.message || 'Could not prepare buy request.'
    });
  }
}

async function buyOrderStatus(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const orderId = String(url.searchParams.get('orderId') || '').trim().toUpperCase();
  if (!orderId) {
    return jsonResponse(res, 400, { ok: false, message: 'orderId query parameter is required.' });
  }

  try {
    const db = await readDb();
    const changed = expireStaleBuyOrders(db);
    if (changed) {
      await writeDb(db);
    }
    let order = db.orders[orderId];
    if (!order) {
      return jsonResponse(res, 404, { ok: false, message: 'Order was not found.' });
    }

    const autoApproved = await tryAutoApproveOrderPayment(db, order, req);
    if (autoApproved?.order) {
      order = autoApproved.order;
    } else {
      order = db.orders[orderId] || order;
    }

    return jsonResponse(res, 200, {
      ok: true,
      order: sanitizeOrderRecord(order, { includeNote: true })
    });
  } catch (error) {
    return jsonResponse(res, 400, {
      ok: false,
      message: error?.message || 'Could not load order status.'
    });
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

async function adminOrders(req, res) {
  try {
    ensureAdmin(req);
    const db = await readDb();
    const changed = expireStaleBuyOrders(db);
    if (changed) {
      await writeDb(db);
    }
    const records = Object.values(db.orders || {})
      .filter(order => !shouldHideBuyOrderFromAdminList(order))
      .map((order) => sanitizeOrderRecord(order, { includeNote: true }))
      .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    return jsonResponse(res, 200, {
      ok: true,
      orders: records
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Admin action failed.' });
  }
}

async function adminGetSettings(req, res) {
  try {
    ensureAdmin(req);
    const db = await readDb();
    return jsonResponse(res, 200, {
      ok: true,
      settings: sanitizeSettings(db)
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Admin action failed.' });
  }
}

async function adminSetSettings(req, res, body) {
  try {
    ensureAdmin(req);
    const db = await readDb();
    const nextTrialPolicy = String(body?.trialPolicy || '').trim();

    if (!nextTrialPolicy) {
      return jsonResponse(res, 400, { ok: false, message: 'trialPolicy is required.' });
    }

    const parsed = parseTrialPolicy(nextTrialPolicy);
    db.settings = {
      ...(db.settings || {}),
      trialPolicy: parsed.raw,
      updatedAt: new Date().toISOString()
    };
    await writeDb(db);

    return jsonResponse(res, 200, {
      ok: true,
      message: `Trial policy set to ${parsed.policyLabel}.`,
      settings: sanitizeSettings(db)
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Could not update settings.' });
  }
}

async function approveOrderWithLicense(db, order, req, options = {}) {
  const orderDays = Math.max(1, Number.parseInt(String(order.requestedDays || DEFAULT_LICENSE_DAYS), 10) || DEFAULT_LICENSE_DAYS);
  const licenseKey = generateLicenseKey({
    deviceId: order.deviceId,
    days: orderDays
  });
  const verified = verifyLicenseToken(licenseKey);
  const resolved = await getOrCreateRecordFromLicenseKey(db, licenseKey, {
    deviceId: '',
    activatedAt: '',
    lastValidatedAt: ''
  });

  ensureHistory(resolved.record).push(createHistoryEntry(
    options.auto ? 'auto-generate-from-order' : 'generate-from-order',
    req,
    {
      orderId: order.orderId,
      deviceId: order.deviceId,
      planId: order.planId || ''
    }
  ));
  db.licenses[resolved.keyHash] = resolved.record;

  order.status = 'approved';
  order.approvedAt = new Date().toISOString();
  order.licenseExpiresAt = verified.payload.expiresAt;
  order.approvedLicenseKeyHash = resolved.keyHash;
  order.lastIp = getClientIp(req);
  order.paymentCheckedAt = new Date().toISOString();
  ensureHistory(order).push(createHistoryEntry(
    options.auto ? 'auto-approve-order' : 'approve-order',
    req,
    {
      orderId: order.orderId,
      deviceId: order.deviceId,
      planId: order.planId || '',
      requestedDays: orderDays
    }
  ));
  db.orders[order.orderId] = order;
  await writeDb(db);

  return {
    order,
    license: {
      deviceId: order.deviceId,
      expiresAt: verified.payload.expiresAt,
      expiresAtLabel: verified.expiresAtLabel,
      keyHash: resolved.keyHash
    },
    licenseKey
  };
}

async function tryAutoApproveOrderPayment(db, order, req) {
  if (!isBakongAutoPaymentReady() || !order?.khqrMd5 || String(order.status || '').trim().toLowerCase() !== 'pending') {
    return null;
  }

  try {
    const result = await checkBakongTransactionByMd5(order.khqrMd5);
    order.paymentCheckedAt = new Date().toISOString();
    if (Number(result?.responseCode) !== 0 || !result?.data) {
      db.orders[order.orderId] = order;
      await writeDb(db);
      return null;
    }
    if (!isMatchingPaidOrder(order, result.data)) {
      ensureHistory(order).push(createHistoryEntry('auto-payment-mismatch', req, {
        orderId: order.orderId
      }));
      db.orders[order.orderId] = order;
      await writeDb(db);
      return null;
    }

    order.paymentHash = String(result?.data?.hash || '').trim();
    order.paymentFromAccountId = String(result?.data?.fromAccountId || '').trim();
    order.paymentToAccountId = String(result?.data?.toAccountId || '').trim();
    order.paymentDescription = String(result?.data?.description || '').trim();
    ensureHistory(order).push(createHistoryEntry('bakong-payment-detected', req, {
      orderId: order.orderId,
      hash: order.paymentHash
    }));
    return await approveOrderWithLicense(db, order, req, { auto: true });
  } catch {
    order.paymentCheckedAt = new Date().toISOString();
    db.orders[order.orderId] = order;
    await writeDb(db);
    return null;
  }
}

async function adminApproveOrder(req, res, body) {
  try {
    ensureAdmin(req);
    const orderId = String(body?.orderId || '').trim().toUpperCase();
    if (!orderId) {
      return jsonResponse(res, 400, { ok: false, message: 'orderId is required.' });
    }

    const db = await readDb();
    const changed = expireStaleBuyOrders(db);
    if (changed) {
      await writeDb(db);
    }
    const order = db.orders[orderId];
    if (!order) {
      return jsonResponse(res, 404, { ok: false, message: 'Order was not found.' });
    }
    if (getOrderStatus(order) === 'expired') {
      return jsonResponse(res, 410, {
        ok: false,
        message: 'Order expired. Generate a new QR and try again.'
      });
    }
    if (String(order.status || '').trim().toLowerCase() === 'approved') {
      return jsonResponse(res, 200, {
        ok: true,
        message: 'Order is already approved.',
        order: sanitizeOrderRecord(order, { includeNote: true })
      });
    }

    const approved = await approveOrderWithLicense(db, order, req, { auto: false });

    return jsonResponse(res, 200, {
      ok: true,
      message: 'Buy order approved and license generated.',
      order: sanitizeOrderRecord(approved.order, { includeNote: true }),
      license: approved.license,
      licenseKey: approved.licenseKey
    });
  } catch (error) {
    return jsonResponse(res, 403, { ok: false, message: error?.message || 'Could not approve buy order.' });
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

async function serveBuyPanel(res) {
  try {
    const html = await fs.readFile(BUY_PANEL_PATH, 'utf8');
    return textResponse(res, 200, html, 'text/html; charset=utf-8');
  } catch (error) {
    return textResponse(res, 500, error?.message || 'Could not load buy page.');
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
    const db = await readDb();
    return jsonResponse(res, 200, {
      ok: true,
      product: PRODUCT_CODE,
      now: new Date().toISOString(),
      buyConfigured: getBuyConfig().enabled,
      facebookResolveEnabled: true,
      trialPolicy: sanitizeSettings(db)
    });
  }

  if (req.method === 'GET' && (req.url === '/' || req.url === '/admin')) {
    return await serveAdminPanel(res);
  }
  if (req.method === 'GET' && req.url === '/manager') {
    return await serveManagerPanel(res);
  }
  if (req.method === 'GET' && req.url.startsWith('/buy')) {
    return await serveBuyPanel(res);
  }

  try {
    if (req.method === 'GET' && req.url === '/api/admin/prefill-token') {
      return await managerPrefillToken(res);
    }
    if (req.method === 'POST' && req.url === '/api/activate') {
      const body = await readJsonBody(req);
      return await activateLicense(req, res, body);
    }
    if (req.method === 'GET' && req.url === '/api/buy/config') {
      return await buyConfig(req, res);
    }
    if (req.method === 'POST' && req.url === '/api/buy/request') {
      const body = await readJsonBody(req);
      return await createBuyRequest(req, res, body);
    }
    if (req.method === 'GET' && req.url.startsWith('/api/buy/order-status')) {
      return await buyOrderStatus(req, res);
    }
    if (req.method === 'POST' && req.url === '/api/auto-activate') {
      const body = await readJsonBody(req);
      return await autoActivateLicense(req, res, body);
    }
    if (req.method === 'POST' && req.url === '/api/trial-status') {
      const body = await readJsonBody(req);
      return await trialStatus(req, res, body);
    }
    if (req.method === 'POST' && req.url === '/api/validate') {
      const body = await readJsonBody(req);
      return await validateLicense(req, res, body);
    }
    if (req.method === 'POST' && (req.url === '/facebook-resolve' || req.url === '/api/facebook/resolve')) {
      const body = await readJsonBody(req);
      return await resolveFacebookVideo(req, res, body);
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
    if (req.method === 'GET' && req.url === '/api/admin/orders') {
      return await adminOrders(req, res);
    }
    if (req.method === 'GET' && req.url === '/api/admin/settings') {
      return await adminGetSettings(req, res);
    }
    if (req.method === 'POST' && req.url === '/api/admin/settings') {
      const body = await readJsonBody(req);
      return await adminSetSettings(req, res, body);
    }
    if (req.method === 'POST' && req.url === '/api/admin/approve-order') {
      const body = await readJsonBody(req);
      return await adminApproveOrder(req, res, body);
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
    console.log(`Buy page: ${PUBLIC_BASE_URL.replace(/\/$/, '')}/buy`);
  }
  if (!ADMIN_TOKEN) {
    console.log('ADMIN_TOKEN is not set. Admin HTTP routes are disabled.');
  }
  if (BAKONG_ACCOUNT_ID) {
    console.log(`Bakong account for buy flow: ${BAKONG_ACCOUNT_ID}`);
  } else {
    console.log('Bakong buy flow is not configured. Set BAKONG_ACCOUNT_ID to enable /buy.');
  }
  if (Number.isFinite(LICENSE_PRICE_USD)) {
    console.log(`License price (USD): ${formatUsd(LICENSE_PRICE_USD)}`);
  }
  if (Number.isFinite(LICENSE_PRICE_KHR)) {
    console.log(`License price (KHR): ${formatKhr(LICENSE_PRICE_KHR)}`);
  }
  if (BAKONG_API_TOKEN) {
    console.log('Bakong API token is configured.');
  }
  if (!process.env.LICENSE_PRIVATE_KEY_PEM && !process.env.LICENSE_PRIVATE_KEY_PEM_BASE64) {
    console.log('Using built-in private key. For public deployment, set LICENSE_PRIVATE_KEY_PEM or LICENSE_PRIVATE_KEY_PEM_BASE64.');
  }
});
