(function initSoraIntegrity(global) {
  const CORE_FILE_HASHES = {
    'manifest.json': '9974fbf0dabdcc68aee41eea2c34c7adf75040411aa90683860210e79c71266e',
    'background.js': 'f5fae55efb30b8dad0f8c1354d16244ea57779cba518ecf8cdacfb892dc85868',
    'content.js': 'add376e72165d9e2b10daaec8a232df6b40678b9cfaa8fc50190d1a6cecf4d0f',
    'popup.js': '5b1a5301b06966e53d048af9f6924bb940b159975cbb0b97992ee1e483b2fdaf',
    'popup.html': '09941240edce837ed4bde532807247fb1a8750a917de45a88f3b3e998c441676',
    'license.js': '6dc0fef9b64e54638c3c937f11aebc2cef2bdba2b40c73f93d65ef4c0bc29f46',
    'page-hook.js': 'ea28b107f7a65f7eee1b83e6c0afabeb8ec27674eb20dbcc1bca3201fdacd65d'
  };

  let integrityPromise = null;

  function getCryptoSubtle() {
    const cryptoObject = global.crypto || (global.self && global.self.crypto);
    if (!cryptoObject?.subtle) {
      throw new Error('Web Crypto is unavailable.');
    }
    return cryptoObject.subtle;
  }

  function toHex(buffer) {
    return Array.from(new Uint8Array(buffer), byte => byte.toString(16).padStart(2, '0')).join('');
  }

  async function sha256Text(text) {
    const digest = await getCryptoSubtle().digest('SHA-256', new TextEncoder().encode(String(text || '')));
    return toHex(digest);
  }

  async function fetchOwnFileText(path) {
    const url = global.chrome?.runtime?.getURL
      ? global.chrome.runtime.getURL(path)
      : path;
    const response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`Could not read ${path}`);
    }
    return await response.text();
  }

  async function getIntegrityStatus(options = {}) {
    const force = options.force === true;
    if (!force && integrityPromise) return integrityPromise;

    integrityPromise = (async () => {
      const results = [];
      for (const [file, expectedHash] of Object.entries(CORE_FILE_HASHES)) {
        try {
          const text = await fetchOwnFileText(file);
          const actualHash = await sha256Text(text);
          results.push({
            file,
            expectedHash,
            actualHash,
            ok: actualHash === expectedHash
          });
        } catch (error) {
          results.push({
            file,
            expectedHash,
            actualHash: '',
            ok: false,
            error: error?.message || 'Unknown error'
          });
        }
      }

      const mismatches = results.filter(item => !item.ok);
      return {
        ok: mismatches.length === 0,
        valid: mismatches.length === 0,
        message: mismatches.length
          ? 'Extension files were changed. Reinstall the original package.'
          : 'Original package verified.',
        mismatches,
        checkedAt: Date.now()
      };
    })();

    return integrityPromise;
  }

  global.SoraIntegrity = {
    CORE_FILE_HASHES,
    getIntegrityStatus
  };
})(typeof globalThis !== 'undefined' ? globalThis : self);
