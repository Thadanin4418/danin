(function () {
  if (window.__soraPageUrlFinderInstalled) return;
  window.__soraPageUrlFinderInstalled = true;

  const currentScript = document.currentScript;
  const SOURCE = currentScript?.dataset?.bridgeSource || '__sora_page_url_finder__';
  const TYPE = currentScript?.dataset?.bridgeType || 'PAGE_URL_FOUND';

  function normalizeUrl(raw) {
    if (!raw || typeof raw !== 'string') return null;

    const cleaned = raw.trim().replace(/^['"]|['"]$/g, '');
    if (!cleaned || cleaned.startsWith('javascript:') || cleaned.startsWith('data:') || cleaned.startsWith('blob:')) {
      return null;
    }

    try {
      return new URL(cleaned, location.href).href;
    } catch {
      return null;
    }
  }

  function isSoraProjectUrl(raw) {
    const url = normalizeUrl(raw);
    if (!url) return false;

    try {
      const parsed = new URL(url);
      return parsed.origin === 'https://sora.chatgpt.com' &&
        (/^\/p\/s_[a-z0-9]+\/?$/i.test(parsed.pathname) || /^\/d\/gen_[a-z0-9]+\/?$/i.test(parsed.pathname));
    } catch {
      return false;
    }
  }

  function report(raw, via) {
    const url = normalizeUrl(raw);
    if (!url || !isSoraProjectUrl(url)) return;
    window.postMessage({ source: SOURCE, type: TYPE, url, via }, '*');
  }

  function scanDom(root) {
    const scope = root && root.querySelectorAll ? root : document;

    report(location.href, 'location');

    scope.querySelectorAll('a[href], [data-href], [data-url], [data-link], [data-path]').forEach(node => {
      ['href', 'data-href', 'data-url', 'data-link', 'data-path'].forEach(attr => {
        report(node.getAttribute && node.getAttribute(attr), 'dom:' + attr);
      });
    });

    scope.querySelectorAll('script:not([src])').forEach(script => {
      const text = script.textContent || '';
      const absoluteMatches = text.match(/https:\/\/sora\.chatgpt\.com\/(?:p\/s_[a-z0-9]+|d\/gen_[a-z0-9]+)/gi) || [];
      absoluteMatches.forEach(match => report(match, 'script'));

      const relativeMatches = text.match(/\/(?:p\/s_[a-z0-9]+|d\/gen_[a-z0-9]+)/gi) || [];
      relativeMatches.forEach(match => report(match, 'script-relative'));
    });
  }

  const originalPushState = history.pushState;
  history.pushState = function () {
    const result = originalPushState.apply(this, arguments);
    report(location.href, 'pushState');
    return result;
  };

  const originalReplaceState = history.replaceState;
  history.replaceState = function () {
    const result = originalReplaceState.apply(this, arguments);
    report(location.href, 'replaceState');
    return result;
  };

  window.addEventListener('popstate', () => report(location.href, 'popstate'), true);
  window.addEventListener('hashchange', () => report(location.href, 'hashchange'), true);

  const observer = new MutationObserver(mutations => {
    mutations.forEach(mutation => {
      if (mutation.type === 'attributes') {
        const target = mutation.target;
        report(target && target.getAttribute && target.getAttribute(mutation.attributeName), 'mutation:' + mutation.attributeName);
      }

      mutation.addedNodes.forEach(node => {
        if (!node || node.nodeType !== Node.ELEMENT_NODE) return;
        scanDom(node);
      });
    });
  });

  observer.observe(document.documentElement || document, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['href', 'data-href', 'data-url', 'data-link', 'data-path']
  });

  scanDom(document);
  setTimeout(() => scanDom(document), 800);
  setTimeout(() => scanDom(document), 2000);
})();
