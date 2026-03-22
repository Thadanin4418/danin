(function initSoraLicense(global) {
  const PRODUCT_CODE = 'sora-all-in-one';
  const LICENSE_STORAGE_KEY = 'soraLicenseToken';
  const LICENSE_DEVICE_ID_STORAGE_KEY = 'soraLicenseDeviceId';
  const LICENSE_SERVER_URL_STORAGE_KEY = 'soraLicenseServerUrl';
  const LICENSE_SERVER_CACHE_KEY = 'soraLicenseServerCache';
  const LICENSE_VERSION = 1;
  const SEALED_LICENSE_PREFIX = 's1.';
  const SEAL_KDF_ITERATIONS = 120000;
  const SEAL_PEPPER_PARTS = ['sora', 'all', 'one', 'local', 'lock', 'v1'];
  const DEFAULT_LICENSE_SERVER_URL = 'https://sora-license-server-op4k.onrender.com';
  const LEGACY_LOCAL_LICENSE_SERVER_URLS = new Set([
    'http://127.0.0.1:8787',
    'http://localhost:8787',
    'https://127.0.0.1:8787',
    'https://localhost:8787'
  ]);
  const SERVER_VALIDATION_CACHE_MAX_AGE_MS = 10 * 60 * 1000;
  const SERVER_VALIDATION_OFFLINE_GRACE_MS = 12 * 60 * 60 * 1000;
  const PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAER3xb23hrkgsyVcEuBObxLTGHcsuF
CiLXiDYaQDr5SiRg2OxxxvMIP2ZZxSL9TL5qga7aISMKog+x4wfcmtVG/g==
-----END PUBLIC KEY-----`;

  let publicKeyPromise = null;
  let deviceIdPromise = null;

  function getSubtleCrypto() {
    const cryptoObject = global.crypto || (global.self && global.self.crypto);
    if (!cryptoObject?.subtle) {
      throw new Error('Web Crypto is unavailable in this browser context.');
    }
    return cryptoObject.subtle;
  }

  function utf8Encode(value) {
    return new TextEncoder().encode(String(value || ''));
  }

  function utf8Decode(bytes) {
    return new TextDecoder().decode(bytes);
  }

  function bytesToHex(bytes) {
    return Array.from(bytes || [], byte => byte.toString(16).padStart(2, '0')).join('');
  }

  function getCryptoObject() {
    return global.crypto || (global.self && global.self.crypto) || null;
  }

  function bytesToBase64(bytes) {
    let binary = '';
    (bytes || []).forEach(byte => {
      binary += String.fromCharCode(byte);
    });
    return btoa(binary);
  }

  function base64ToBytes(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  }

  function bytesToBase64Url(bytes) {
    return bytesToBase64(bytes)
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/g, '');
  }

  function base64UrlToBytes(value) {
    const normalized = String(value || '')
      .replace(/-/g, '+')
      .replace(/_/g, '/')
      .padEnd(Math.ceil(String(value || '').length / 4) * 4, '=');
    return base64ToBytes(normalized);
  }

  function pemToArrayBuffer(pem) {
    const base64 = String(pem || '').replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
    return base64ToBytes(base64).buffer;
  }

  function getRandomBytes(length) {
    const cryptoObject = getCryptoObject();
    if (!cryptoObject?.getRandomValues) {
      throw new Error('Secure random generator is unavailable.');
    }
    const bytes = new Uint8Array(length);
    cryptoObject.getRandomValues(bytes);
    return bytes;
  }

  function trimLeadingZeros(bytes) {
    let index = 0;
    while (index < bytes.length - 1 && bytes[index] === 0) {
      index += 1;
    }
    return bytes.slice(index);
  }

  function padToLength(bytes, targetLength) {
    if (bytes.length === targetLength) return bytes;
    if (bytes.length > targetLength) {
      return bytes.slice(bytes.length - targetLength);
    }
    const output = new Uint8Array(targetLength);
    output.set(bytes, targetLength - bytes.length);
    return output;
  }

  function derEcdsaToP1363(signatureBytes, fieldLength = 32) {
    const bytes = signatureBytes instanceof Uint8Array ? signatureBytes : new Uint8Array(signatureBytes || []);
    if (bytes.length < 8 || bytes[0] !== 0x30) {
      return bytes;
    }

    let index = 1;
    let sequenceLength = bytes[index];
    index += 1;

    if (sequenceLength & 0x80) {
      const lengthBytes = sequenceLength & 0x7f;
      sequenceLength = 0;
      for (let i = 0; i < lengthBytes; i += 1) {
        sequenceLength = (sequenceLength << 8) | bytes[index];
        index += 1;
      }
    }

    if (bytes[index] !== 0x02) {
      return bytes;
    }
    index += 1;
    const rLength = bytes[index];
    index += 1;
    const r = bytes.slice(index, index + rLength);
    index += rLength;

    if (bytes[index] !== 0x02) {
      return bytes;
    }
    index += 1;
    const sLength = bytes[index];
    index += 1;
    const s = bytes.slice(index, index + sLength);

    const normalizedR = padToLength(trimLeadingZeros(r), fieldLength);
    const normalizedS = padToLength(trimLeadingZeros(s), fieldLength);
    const raw = new Uint8Array(fieldLength * 2);
    raw.set(normalizedR, 0);
    raw.set(normalizedS, fieldLength);
    return raw;
  }

  async function importPublicKey() {
    if (!publicKeyPromise) {
      publicKeyPromise = getSubtleCrypto().importKey(
        'spki',
        pemToArrayBuffer(PUBLIC_KEY_PEM),
        {
          name: 'ECDSA',
          namedCurve: 'P-256'
        },
        false,
        ['verify']
      );
    }
    return publicKeyPromise;
  }

  async function sha256Hex(value) {
    const digest = await getSubtleCrypto().digest('SHA-256', utf8Encode(value));
    return bytesToHex(new Uint8Array(digest));
  }

  function normalizeDeviceId(value) {
    const text = String(value || '').trim().toUpperCase();
    return /^[A-F0-9]{32}$/.test(text) ? text : '';
  }

  function getLicenseStorageArea() {
    return global.chrome?.storage?.local || null;
  }

  function normalizeUserAgentFamily(userAgent) {
    return String(userAgent || '')
      .replace(/\b\d+(?:[._]\d+)*\b/g, '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();
  }

  async function deriveStableDeviceId() {
    const bits = [
      global.navigator?.language || '',
      Array.isArray(global.navigator?.languages) ? global.navigator.languages.join(',') : '',
      global.navigator?.platform || '',
      global.navigator?.vendor || '',
      String(global.navigator?.hardwareConcurrency || ''),
      String(global.navigator?.deviceMemory || ''),
      String(global.navigator?.maxTouchPoints || ''),
      Intl.DateTimeFormat().resolvedOptions().timeZone || '',
      normalizeUserAgentFamily(global.navigator?.userAgent || '')
    ];
    const digest = await sha256Hex(bits.join('|'));
    return digest.slice(0, 32).toUpperCase();
  }

  async function deriveLegacyDeviceId() {
    const bits = [
      global.navigator?.userAgent || '',
      global.navigator?.language || '',
      Array.isArray(global.navigator?.languages) ? global.navigator.languages.join(',') : '',
      global.navigator?.platform || '',
      String(global.navigator?.hardwareConcurrency || ''),
      Intl.DateTimeFormat().resolvedOptions().timeZone || ''
    ];
    const digest = await sha256Hex(bits.join('|').toLowerCase());
    return digest.slice(0, 32).toUpperCase();
  }

  function buildDeviceAliasList(values, primary) {
    const primaryNormalized = normalizeDeviceId(primary);
    const aliases = [];
    const seen = new Set(primaryNormalized ? [primaryNormalized] : []);
    values.forEach((value) => {
      const normalized = normalizeDeviceId(value);
      if (!normalized || seen.has(normalized)) return;
      seen.add(normalized);
      aliases.push(normalized);
    });
    return aliases;
  }

  async function readPersistedDeviceId(storage) {
    if (!storage?.get) return '';
    try {
      const data = await storage.get(LICENSE_DEVICE_ID_STORAGE_KEY);
      return normalizeDeviceId(data?.[LICENSE_DEVICE_ID_STORAGE_KEY] || '');
    } catch {
      return '';
    }
  }

  async function persistDeviceId(deviceId, storage) {
    const normalized = normalizeDeviceId(deviceId);
    if (!normalized) return '';
    if (storage?.set) {
      try {
        await storage.set({ [LICENSE_DEVICE_ID_STORAGE_KEY]: normalized });
      } catch {}
    }
    return normalized;
  }

  async function readCachedDeviceIdFromServerCache(storage) {
    try {
      const cache = await readServerValidationCache(storage);
      return normalizeDeviceId(cache?.deviceId || '');
    } catch {
      return '';
    }
  }

  async function getDeviceId() {
    const identity = await getDeviceIdentity();
    return identity.deviceId;
  }

  async function getDeviceIdentity() {
    if (deviceIdPromise) {
      return await deviceIdPromise;
    }

    deviceIdPromise = (async () => {
      const storage = getLicenseStorageArea();
      const persisted = await readPersistedDeviceId(storage);
      const cached = await readCachedDeviceIdFromServerCache(storage);
      const stableDerived = await deriveStableDeviceId();
      const legacyDerived = await deriveLegacyDeviceId();

      const deviceId = persisted || cached || stableDerived || legacyDerived;
      await persistDeviceId(deviceId, storage);

      return {
        deviceId: normalizeDeviceId(deviceId),
        aliases: buildDeviceAliasList([
          persisted,
          cached,
          stableDerived,
          legacyDerived
        ], deviceId)
      };
    })();

    try {
      return await deviceIdPromise;
    } catch (error) {
      deviceIdPromise = null;
      throw error;
    }
  }

  async function deriveStorageSealKey(deviceId, saltBytes) {
    const subtle = getSubtleCrypto();
    const seed = [
      PRODUCT_CODE,
      `v${LICENSE_VERSION}`,
      String(deviceId || ''),
      String(global.chrome?.runtime?.id || ''),
      SEALED_LICENSE_PREFIX,
      SEAL_PEPPER_PARTS.join(':')
    ].join('|');

    const keyMaterial = await subtle.importKey(
      'raw',
      utf8Encode(seed),
      'PBKDF2',
      false,
      ['deriveKey']
    );

    return await subtle.deriveKey(
      {
        name: 'PBKDF2',
        hash: 'SHA-256',
        salt: saltBytes instanceof Uint8Array ? saltBytes : new Uint8Array(saltBytes),
        iterations: SEAL_KDF_ITERATIONS
      },
      keyMaterial,
      {
        name: 'AES-GCM',
        length: 256
      },
      false,
      ['encrypt', 'decrypt']
    );
  }

  async function sealTokenForStorage(token, deviceId) {
    const subtle = getSubtleCrypto();
    const salt = getRandomBytes(16);
    const iv = getRandomBytes(12);
    const key = await deriveStorageSealKey(deviceId, salt);
    const cipherBytes = new Uint8Array(await subtle.encrypt(
      {
        name: 'AES-GCM',
        iv
      },
      key,
      utf8Encode(String(token || '').trim())
    ));

    const envelope = JSON.stringify({
      v: 1,
      s: bytesToBase64Url(salt),
      i: bytesToBase64Url(iv),
      c: bytesToBase64Url(cipherBytes)
    });

    return `${SEALED_LICENSE_PREFIX}${bytesToBase64Url(utf8Encode(envelope))}`;
  }

  async function unsealStoredToken(value, deviceId) {
    const text = String(value || '').trim();
    if (!text.startsWith(SEALED_LICENSE_PREFIX)) {
      return String(value || '').trim();
    }

    try {
      const subtle = getSubtleCrypto();
      const envelopeText = utf8Decode(base64UrlToBytes(text.slice(SEALED_LICENSE_PREFIX.length)));
      const envelope = JSON.parse(envelopeText);
      const salt = base64UrlToBytes(envelope?.s || '');
      const iv = base64UrlToBytes(envelope?.i || '');
      const cipher = base64UrlToBytes(envelope?.c || '');
      if (!salt.length || !iv.length || !cipher.length) {
        throw new Error('Stored license payload is incomplete.');
      }

      const key = await deriveStorageSealKey(deviceId, salt);
      const plainBuffer = await subtle.decrypt(
        {
          name: 'AES-GCM',
          iv
        },
        key,
        cipher
      );
      return utf8Decode(new Uint8Array(plainBuffer)).trim();
    } catch (error) {
      throw new Error(error?.message || 'Stored license could not be unlocked on this computer.');
    }
  }

  function parseToken(token) {
    const text = String(token || '').trim();
    if (!text) {
      throw new Error('License key is empty.');
    }

    const [payloadPart, signaturePart] = text.split('.');
    if (!payloadPart || !signaturePart) {
      throw new Error('License key format is invalid.');
    }

    const payloadJson = utf8Decode(base64UrlToBytes(payloadPart));
    const payload = JSON.parse(payloadJson);

    return {
      token: text,
      payloadPart,
      signature: base64UrlToBytes(signaturePart),
      payload
    };
  }

  async function verifySignature(token) {
    const parsed = parseToken(token);
    const publicKey = await importPublicKey();
    const normalizedSignature = parsed.signature.length === 64
      ? parsed.signature
      : derEcdsaToP1363(parsed.signature);
    const valid = await getSubtleCrypto().verify(
      {
        name: 'ECDSA',
        hash: 'SHA-256'
      },
      publicKey,
      normalizedSignature,
      utf8Encode(parsed.payloadPart)
    );

    return {
      ...parsed,
      signature: normalizedSignature,
      signatureValid: valid
    };
  }

  function asTimestamp(value) {
    const timestamp = Date.parse(String(value || ''));
    return Number.isFinite(timestamp) ? timestamp : NaN;
  }

  function formatExpiry(value) {
    const timestamp = asTimestamp(value);
    if (!Number.isFinite(timestamp)) return 'Unknown';
    return new Date(timestamp).toLocaleString();
  }

  function normalizeServerUrl(value) {
    const text = String(value || '').trim();
    const fallback = DEFAULT_LICENSE_SERVER_URL;
    const target = text || fallback;
    try {
      const url = new URL(target);
      url.pathname = '/';
      url.hash = '';
      return url.toString().replace(/\/$/, '');
    } catch {
      return fallback;
    }
  }

  function buildInvalidStatus(deviceId, reason, extra = {}) {
    return {
      ok: false,
      valid: false,
      licensed: false,
      deviceId,
      reason,
      ...extra
    };
  }

  function buildTrialStatus(deviceId, trial) {
    const endsAt = String(trial?.endsAt || '').trim();
    return {
      ok: true,
      valid: true,
      licensed: false,
      trialActive: true,
      deviceId,
      expiresAt: endsAt,
      expiresAtLabel: trial?.expiresAtLabel || (trial?.forever ? 'No expiry' : formatExpiry(endsAt)),
      trialForever: Boolean(trial?.forever),
      trialPolicyLabel: String(trial?.policyLabel || '').trim(),
      trial: trial || null
    };
  }

  async function getStoredServerUrl(storage) {
    if (storage?.set) {
      await storage.set({ [LICENSE_SERVER_URL_STORAGE_KEY]: DEFAULT_LICENSE_SERVER_URL });
    }
    return DEFAULT_LICENSE_SERVER_URL;
  }

  async function setStoredServerUrl(value, storage) {
    if (storage?.set) {
      await storage.set({ [LICENSE_SERVER_URL_STORAGE_KEY]: DEFAULT_LICENSE_SERVER_URL });
    }
    return DEFAULT_LICENSE_SERVER_URL;
  }

  async function readServerValidationCache(storage) {
    if (!storage?.get) return null;
    const data = await storage.get(LICENSE_SERVER_CACHE_KEY);
    const cache = data?.[LICENSE_SERVER_CACHE_KEY];
    return cache && typeof cache === 'object' ? cache : null;
  }

  async function writeServerValidationCache(storage, cache) {
    if (!storage?.set) return;
    await storage.set({ [LICENSE_SERVER_CACHE_KEY]: cache });
  }

  async function clearServerValidationCache(storage) {
    if (!storage?.remove) return;
    await storage.remove(LICENSE_SERVER_CACHE_KEY);
  }

  function shouldProxyLicenseServerRequest() {
    const runtime = global.chrome?.runtime;
    const hasMessaging = typeof runtime?.sendMessage === 'function';
    const hasDocument = typeof global.document !== 'undefined';
    return hasMessaging && hasDocument;
  }

  async function callLicenseServerDirect(storage, path, body) {
    const serverUrl = await getStoredServerUrl(storage);
    const targetUrl = new URL(path, `${serverUrl}/`).toString();
    let response;

    try {
      response = await fetch(targetUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(body || {})
      });
    } catch (error) {
      throw new Error(`Could not reach license server at ${serverUrl}.`);
    }

    let payload = null;
    try {
      payload = await response.json();
    } catch {
      payload = null;
    }

    if (!response.ok || payload?.ok === false) {
      throw new Error(payload?.message || `License server request failed at ${serverUrl}.`);
    }

    return {
      serverUrl,
      payload: payload || {}
    };
  }

  async function callLicenseServer(storage, path, body) {
    if (shouldProxyLicenseServerRequest()) {
      const runtime = global.chrome?.runtime;
      return await new Promise((resolve, reject) => {
        try {
          runtime.sendMessage(
            {
              action: 'license_server_request',
              path,
              body: body || {}
            },
            (response) => {
              const runtimeError = global.chrome?.runtime?.lastError;
              if (runtimeError) {
                reject(new Error(runtimeError.message || 'Could not reach background license proxy.'));
                return;
              }
              if (!response?.ok) {
                reject(new Error(response?.message || 'Could not reach license server.'));
                return;
              }
              resolve({
                serverUrl: response.serverUrl || DEFAULT_LICENSE_SERVER_URL,
                payload: response.payload || {}
              });
            }
          );
        } catch (error) {
          reject(error);
        }
      });
    }

    return await callLicenseServerDirect(storage, path, body);
  }

  function buildDeviceRequestPayload(deviceIdentity, extra = {}) {
    return {
      ...extra,
      deviceId: deviceIdentity?.deviceId || '',
      deviceIdAliases: Array.isArray(deviceIdentity?.aliases) ? deviceIdentity.aliases : []
    };
  }

  async function getLicenseStatusFromToken(token) {
    const deviceId = await getDeviceId();
    let verified;

    try {
      verified = await verifySignature(token);
    } catch (error) {
      return buildInvalidStatus(deviceId, error?.message || 'License key is invalid.');
    }

    if (!verified.signatureValid) {
      return buildInvalidStatus(deviceId, 'License signature is invalid.');
    }

    const payload = verified.payload || {};
    if (payload.product !== PRODUCT_CODE) {
      return buildInvalidStatus(deviceId, 'License key is for a different product.');
    }
    if (payload.version !== LICENSE_VERSION) {
      return buildInvalidStatus(deviceId, 'License key version is not supported.');
    }
    if (!payload.deviceId || payload.deviceId !== deviceId) {
      return buildInvalidStatus(deviceId, 'License key is for a different computer.', { payload });
    }

    const expiresAtMs = asTimestamp(payload.expiresAt);
    if (!Number.isFinite(expiresAtMs)) {
      return buildInvalidStatus(deviceId, 'License expiry date is invalid.', { payload });
    }
    if (Date.now() > expiresAtMs) {
      return buildInvalidStatus(deviceId, 'License key has expired.', {
        payload,
        expiresAt: payload.expiresAt
      });
    }

    return {
      ok: true,
      valid: true,
      licensed: true,
      deviceId,
      payload,
      expiresAt: payload.expiresAt,
      expiresAtLabel: formatExpiry(payload.expiresAt)
    };
  }

  async function getServerValidatedLicenseStatus(token, storage, options = {}) {
    const localStatus = await getLicenseStatusFromToken(token);
    if (!localStatus.valid) return localStatus;

    const tokenHash = await sha256Hex(token);
    const serverUrl = await getStoredServerUrl(storage);
    const cache = await readServerValidationCache(storage);
    const now = Date.now();
    const matchesCache = Boolean(
      cache &&
      cache.tokenHash === tokenHash &&
      cache.deviceId === localStatus.deviceId &&
      cache.serverUrl === serverUrl &&
      cache.expiresAt === localStatus.expiresAt
    );
    const cacheAgeMs = matchesCache ? Math.max(0, now - Number(cache.checkedAtMs || 0)) : Number.POSITIVE_INFINITY;

    if (!options.force && matchesCache && cacheAgeMs <= SERVER_VALIDATION_CACHE_MAX_AGE_MS) {
      return {
        ...localStatus,
        serverValidated: true,
        serverUrl,
        serverCheckedAt: cache.checkedAt || '',
        serverCacheAgeMs: cacheAgeMs,
        fromServerCache: true
      };
    }

    try {
      const result = await callLicenseServer(storage, options.activate ? '/api/activate' : '/api/validate', {
        licenseKey: token,
        deviceId: localStatus.deviceId
      });
      const checkedAt = new Date().toISOString();
      await writeServerValidationCache(storage, {
        tokenHash,
        deviceId: localStatus.deviceId,
        expiresAt: localStatus.expiresAt,
        checkedAt,
        checkedAtMs: Date.now(),
        serverUrl
      });

      return {
        ...localStatus,
        serverValidated: true,
        serverUrl,
        serverCheckedAt: checkedAt,
        serverLicense: result.payload?.license || null
      };
    } catch (error) {
      if (matchesCache && cacheAgeMs <= SERVER_VALIDATION_OFFLINE_GRACE_MS) {
        return {
          ...localStatus,
          serverValidated: true,
          serverUrl,
          serverCheckedAt: cache.checkedAt || '',
          serverCacheAgeMs: cacheAgeMs,
          usingOfflineGrace: true,
          offlineGraceReason: error?.message || 'License server is unavailable.'
        };
      }

      return buildInvalidStatus(localStatus.deviceId, error?.message || 'Could not validate the license with the server.', {
        expiresAt: localStatus.expiresAt,
        expiresAtLabel: localStatus.expiresAtLabel,
        serverUrl
      });
    }
  }

  async function buildFastAutoActivatedStatus(restoredToken, storage, restoredPayload = {}) {
    const localStatus = await getLicenseStatusFromToken(restoredToken);
    if (!localStatus.valid) return localStatus;

    const serverUrl = await getStoredServerUrl(storage);
    const tokenHash = await sha256Hex(restoredToken);
    const checkedAt = new Date().toISOString();

    await writeServerValidationCache(storage, {
      tokenHash,
      deviceId: localStatus.deviceId,
      expiresAt: localStatus.expiresAt,
      checkedAt,
      checkedAtMs: Date.now(),
      serverUrl
    });

    return {
      ...localStatus,
      token: restoredToken,
      autoActivated: true,
      serverValidated: true,
      serverUrl,
      serverCheckedAt: checkedAt,
      serverLicense: restoredPayload?.license || null,
      autoActivatedFastPath: true
    };
  }

  async function tryAutoRestoreOrTrial(storage, deviceIdentity) {
    const requestBody = buildDeviceRequestPayload(deviceIdentity);

    try {
      const restored = await callLicenseServer(storage, '/api/auto-activate', requestBody);
      const restoredToken = String(restored?.payload?.licenseKey || '').trim();
      if (restoredToken) {
        const result = await buildFastAutoActivatedStatus(
          restoredToken,
          storage,
          restored?.payload || {}
        );
        if (result.valid && storage?.set) {
          const sealedToken = await sealTokenForStorage(restoredToken, result.deviceId);
          await storage.set({ [LICENSE_STORAGE_KEY]: sealedToken });
        }
        return result;
      }
    } catch (error) {
      const message = String(error?.message || '').trim();
      if (message && !/No active license was found for this computer/i.test(message)) {
        return buildInvalidStatus(deviceIdentity?.deviceId || '', message);
      }
    }

    try {
      const trialResult = await callLicenseServer(storage, '/api/trial-status', requestBody);
      const trial = trialResult?.payload?.trial || null;
      if (trial?.active) {
        return buildTrialStatus(deviceIdentity?.deviceId || '', trial);
      }
      if (trial?.disabled) {
        return buildInvalidStatus(deviceIdentity?.deviceId || '', 'Free access is disabled. Activate a license key to continue.', {
          trialDisabled: true,
          trial
        });
      }
      if (trial?.expired) {
        return buildInvalidStatus(deviceIdentity?.deviceId || '', 'Free access period ended. Activate a license key to continue.', {
          trialExpired: true,
          expiresAt: trial?.endsAt || '',
          expiresAtLabel: trial?.expiresAtLabel || formatExpiry(trial?.endsAt || ''),
          trial
        });
      }
    } catch (error) {
      const message = String(error?.message || '').trim();
      if (message) {
        return buildInvalidStatus(deviceIdentity?.deviceId || '', message);
      }
    }

    return null;
  }

  async function readStoredTokenRecord(storage) {
    if (!storage?.get) {
      return {
        raw: '',
        token: '',
        sealed: false,
        legacy: false,
        error: ''
      };
    }

    const data = await storage.get(LICENSE_STORAGE_KEY);
    const raw = String(data?.[LICENSE_STORAGE_KEY] || '').trim();
    if (!raw) {
      return {
        raw: '',
        token: '',
        sealed: false,
        legacy: false,
        error: ''
      };
    }

    const sealed = raw.startsWith(SEALED_LICENSE_PREFIX);
    if (!sealed) {
      return {
        raw,
        token: raw,
        sealed: false,
        legacy: true,
        error: ''
      };
    }

    try {
      const deviceId = await getDeviceId();
      const token = await unsealStoredToken(raw, deviceId);
      return {
        raw,
        token,
        sealed: true,
        legacy: false,
        error: ''
      };
    } catch (error) {
      return {
        raw,
        token: '',
        sealed: true,
        legacy: false,
        error: error?.message || 'Stored license could not be unlocked on this computer.'
      };
    }
  }

  async function getStoredLicenseStatus(storage) {
    const stored = await readStoredTokenRecord(storage);
    const token = stored.token;
    const deviceIdentity = await getDeviceIdentity();
    if (!token) {
      const restoredOrTrial = await tryAutoRestoreOrTrial(storage, deviceIdentity);
      if (restoredOrTrial) {
        return restoredOrTrial;
      }

      return buildInvalidStatus(deviceIdentity.deviceId, stored.error || 'License key is not activated.');
    }

    const result = await getServerValidatedLicenseStatus(token, storage, { force: false });
    if (!result.valid && /different computer/i.test(String(result.reason || ''))) {
      const restoredOrTrial = await tryAutoRestoreOrTrial(storage, deviceIdentity);
      if (restoredOrTrial) {
        return restoredOrTrial;
      }
    }
    if (result.valid && stored.legacy && storage?.set) {
      try {
        const sealedToken = await sealTokenForStorage(token, result.deviceId);
        await storage.set({ [LICENSE_STORAGE_KEY]: sealedToken });
      } catch {}
    }
    return {
      ...result,
      token
    };
  }

  async function activateLicenseToken(token, storage) {
    const result = await getServerValidatedLicenseStatus(String(token || '').trim(), storage, {
      force: true,
      activate: true
    });
    if (!result.valid) return result;
    const sealedToken = await sealTokenForStorage(String(token || '').trim(), result.deviceId);
    await storage.set({ [LICENSE_STORAGE_KEY]: sealedToken });
    return {
      ...result,
      saved: true
    };
  }

  async function clearStoredLicense(storage) {
    if (storage?.remove) {
      await storage.remove(LICENSE_STORAGE_KEY);
    }
    await clearServerValidationCache(storage);
    const deviceId = await getDeviceId();
    return buildInvalidStatus(deviceId, 'License key is not activated.');
  }

  global.SoraLicense = {
    PRODUCT_CODE,
    LICENSE_STORAGE_KEY,
    LICENSE_SERVER_URL_STORAGE_KEY,
    LICENSE_SERVER_CACHE_KEY,
    LICENSE_VERSION,
    SEALED_LICENSE_PREFIX,
    DEFAULT_LICENSE_SERVER_URL,
    getDeviceId,
    getDeviceIdentity,
    parseToken,
    verifySignature,
    getLicenseStatusFromToken,
    getStoredServerUrl,
    setStoredServerUrl,
    callLicenseServerDirect,
    getStoredLicenseStatus,
    activateLicenseToken,
    clearStoredLicense,
    formatExpiry
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
