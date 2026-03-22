const STORAGE_KEY = 'soraPageUrlResults';
const DELETE_STORAGE_KEY = 'soraDeleteScanResults';
const PUBLISHED_VIDEO_STORAGE_KEY = 'soraPublishedVideoUrlCache';
const DELETE_FAST_MODE_KEY = 'soraFastDeleteEnabled';
const BRIDGE_SOURCE = '__sora_page_url_finder__';
const BRIDGE_TYPE = 'PAGE_URL_FOUND';
const HOOK_ID = 'sora-page-url-finder-hook';
const HELPER_STYLE_ID = 'sora-draft-helper-style';
const HELPER_BUTTON_ID = 'sora-draft-helper-button';
const DELETE_HELPER_BUTTON_ID = 'sora-delete-all-helper-button';
const HELPER_STATUS_ID = 'sora-draft-helper-status';
const HELPER_MENU_ROOT_ID = 'sora-helper-menu-root';
const HELPER_MENU_TRIGGER_ID = 'sora-helper-menu-trigger';
const HELPER_MENU_PANEL_ID = 'sora-helper-menu-panel';
const HELPER_MENU_META_ID = 'sora-helper-menu-meta';
const DRAFTS_POST_ACTIONS_ID = 'sora-drafts-post-actions';
const DRAFTS_POST_TRIGGER_ID = 'sora-drafts-post-trigger';
const DRAFTS_POST_PANEL_ID = 'sora-drafts-post-panel';
const DRAFTS_POST_BUTTON_ID = 'sora-drafts-post-all-found-button';
const DRAFTS_POST_FIVE_BUTTON_ID = 'sora-drafts-post-five-button';
const DRAFTS_POST_TEN_BUTTON_ID = 'sora-drafts-post-ten-button';
const PROFILE_ACTIONS_ID = 'sora-profile-actions';
const PROFILE_ACTIONS_PANEL_ID = 'sora-profile-actions-panel';
const PROFILE_ACTIONS_STATUS_ID = 'sora-profile-actions-status';
const PROJECT_DOWNLOAD_ACTIONS_ID = 'sora-project-download-actions';
const PROJECT_PAGE_HOST_CLASS = 'sora-project-page-host';
const PROJECT_PAGE_DOWNLOAD_CLASS = 'sora-project-page-download';
const EXPLORE_ACTIONS_ID = 'sora-explore-actions';
const EXPLORE_ACTIONS_STATUS_ID = 'sora-explore-actions-status';
const EXPLORE_CARD_HOST_CLASS = 'sora-explore-card-host';
const EXPLORE_CARD_DOWNLOAD_CLASS = 'sora-explore-card-download';
const PROFILE_BUY_MODAL_ID = 'sora-profile-buy-modal';
const PROFILE_BUY_DIALOG_ID = 'sora-profile-buy-dialog';
const PROFILE_BUY_CONTENT_ID = 'sora-profile-buy-content';
const ENABLE_PAGE_HELPERS = false;
const ENABLE_PAGE_STATUS = false;
const INTEGRITY_REQUIRED_MESSAGE = 'Extension files were changed. Reinstall the original package.';
const POST_PROFILE_REDIRECT_DELAY_MS = 3000;
const ABSOLUTE_SORA_URL_PATTERN = /https:\/\/sora\.chatgpt\.com\/(?:p\/s_[a-z0-9]+|d\/[a-z0-9_-]+)\/?/gi;
const RELATIVE_SORA_URL_PATTERN = /\/(?:p\/s_[a-z0-9]+|d\/[a-z0-9_-]+)\/?/gi;
const CARD_SUBTREE_SCAN_LIMIT = 180;
const FAST_POST_ACTION_DELAY_MS = 90;
const NORMAL_POST_ACTION_DELAY_MS = 240;
const FAST_POST_MENU_DELAY_MS = 170;
const NORMAL_POST_MENU_DELAY_MS = 500;
const FAST_POST_RETRY_DELAY_MS = 220;
const NORMAL_POST_RETRY_DELAY_MS = 700;
const FAST_POST_COMPLETE_POLL_MS = 120;
const NORMAL_POST_COMPLETE_POLL_MS = 260;
const FAST_POST_COMPLETE_TIMEOUT_MS = 5200;
const NORMAL_POST_COMPLETE_TIMEOUT_MS = 9000;
const DRAFT_EDIT_OPEN_DELAY_MS = 500;
const DRAFT_EDIT_CLEAR_DELAY_MS = 180;
const DRAFT_EDIT_INPUT_DELAY_MS = 180;
const DRAFT_EDIT_DONE_DELAY_MS = 420;
const INLINE_POST_OPEN_SETTLE_MS = 4500;
const INLINE_POST_RETURN_SETTLE_MS = 900;
const INLINE_POST_REOPEN_RETRY_COUNT = 2;
const FAST_DELETE_ACTION_DELAY_MS = 90;
const NORMAL_DELETE_ACTION_DELAY_MS = 600;
const FAST_DELETE_MENU_DELAY_MS = 110;
const NORMAL_DELETE_MENU_DELAY_MS = 500;
const FAST_DELETE_CONFIRM_DELAY_MS = 220;
const NORMAL_DELETE_CONFIRM_DELAY_MS = 1000;
const FAST_DELETE_RETRY_DELAY_MS = 110;
const NORMAL_DELETE_RETRY_DELAY_MS = 700;
const FAST_DELETE_TIMEOUT_MS = 4200;
const NORMAL_DELETE_TIMEOUT_MS = 12000;
const PROFILE_ACTION_SCAN_PASSES = 8;
const PROFILE_ACTION_SCAN_SETTLE_MS = 260;
const PAGE_PROTECTION_CACHE_MAX_AGE_MS = 60 * 1000;

const discoveredUrls = new Map();
let rescanTimer = null;
let helperTimer = null;
let deleteStopRequested = false;
let inlineDraftPostRunning = false;
let inlineDraftPostStopRequested = false;
let helperKeepAliveTimer = null;
let historyHooked = false;
let lastKnownHref = location.href;
let lastFullHtmlScanAt = 0;
let helperMenuOpen = false;
let pageProtectionCache = null;
let pageProtectionCacheAt = 0;
let pageProtectionExpiryTimer = null;
let profileBuyModalEscapeHooked = false;
let profileBuyConfig = null;
let profileBuySelectedPlanId = '';
let profileBuyOrder = null;
let profileBuyPollTimer = null;
let profileBuyPreparing = false;
let profileBuyCountdownTimer = null;

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function clearPageProtectionCache() {
  pageProtectionCache = null;
  pageProtectionCacheAt = 0;
}

function schedulePageProtectionExpiryRefresh(expiresAt) {
  if (pageProtectionExpiryTimer) {
    window.clearTimeout(pageProtectionExpiryTimer);
    pageProtectionExpiryTimer = null;
  }

  const expiresAtMs = Date.parse(String(expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return;

  const delayMs = Math.max(250, expiresAtMs - Date.now() + 250);
  pageProtectionExpiryTimer = window.setTimeout(() => {
    clearPageProtectionCache();
    updateProfileLicenseLabel(document.getElementById(PROFILE_ACTIONS_ID)).catch(() => {});
  }, delayMs);
}

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

function isSoraPublishedUrl(raw) {
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    return parsed.origin === 'https://sora.chatgpt.com' && /^\/p\/s_[a-z0-9]+\/?$/i.test(parsed.pathname);
  } catch {
    return false;
  }
}

function isSoraDraftUrl(raw) {
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    return parsed.origin === 'https://sora.chatgpt.com' && /^\/d\/[^/]+\/?$/i.test(parsed.pathname);
  } catch {
    return false;
  }
}

function isSoraProjectUrl(raw) {
  return isSoraPublishedUrl(raw) || isSoraDraftUrl(raw);
}

function isSoraDomainPage() {
  return location.origin === 'https://sora.chatgpt.com';
}

function isSoraDraftsPage() {
  return isSoraDomainPage() && /^\/drafts\/?$/i.test(location.pathname);
}

function isSoraProfilePage() {
  return isSoraDomainPage() && /^\/profile\/?$/i.test(location.pathname);
}

function isSoraPublicProfilePage() {
  return isSoraDomainPage() && /^\/profile\/[^/]+\/?$/i.test(location.pathname);
}

function isSoraExplorePage() {
  return isSoraDomainPage() && /^\/explore\/?$/i.test(location.pathname);
}

function isSoraPublishedProjectPage() {
  return isSoraPublishedUrl(location.href);
}

async function goToSoraProfilePage() {
  const targetUrl = 'https://sora.chatgpt.com/profile';
  if (normalizeUrl(location.href) === targetUrl) return true;
  await sleep(POST_PROFILE_REDIRECT_DELAY_MS);
  location.href = targetUrl;
  return await waitForCurrentUrl(targetUrl, 15000);
}

function isLikelyMediaAssetUrl(raw, options = {}) {
  const { allowStreaming = true, allowUnknownVideo = false } = options;
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    if (!/^https?:$/i.test(parsed.protocol)) return false;

    const full = `${parsed.pathname}${parsed.search}`.toLowerCase();
    if (/\.(mp4|webm|mov|m4v)(?:$|[?#])/i.test(full)) return true;
    if (allowStreaming && /\.(m3u8|mpd)(?:$|[?#])/i.test(full)) return true;
    if (/\.(png|jpe?g|gif|webp|svg|ico|css|js|json|txt|woff2?|ttf|otf)(?:$|[?#])/i.test(full)) return false;
    if (allowUnknownVideo && parsed.origin !== location.origin) return true;
    return false;
  } catch {
    return false;
  }
}

function collectProjectMediaCandidates() {
  const seen = new Set();
  const candidates = [];
  const addCandidate = (raw, via, options = {}) => {
    const url = normalizeUrl(raw);
    if (!url || seen.has(url)) return;
    const accept = isLikelyMediaAssetUrl(url, options);
    if (!accept) return;
    seen.add(url);
    let score = 0;
    if (/\.(mp4|webm|mov|m4v)(?:$|[?#])/i.test(url)) score += 140;
    if (/\.(m3u8|mpd)(?:$|[?#])/i.test(url)) score += 70;
    if (via === 'video-current') score += 180;
    if (via === 'video-source') score += 160;
    if (via === 'anchor') score += 120;
    if (via === 'performance') score += 100;
    if (via === 'html') score += 80;
    candidates.push({ url, via, score });
  };

  document.querySelectorAll('video').forEach(video => {
    addCandidate(video.currentSrc || video.src || '', 'video-current', {
      allowStreaming: true,
      allowUnknownVideo: true
    });
    video.querySelectorAll?.('source[src]').forEach(source => {
      addCandidate(source.getAttribute('src') || '', 'video-source', {
        allowStreaming: true,
        allowUnknownVideo: true
      });
    });
  });

  document.querySelectorAll('a[href], [src], [data-url], [data-src], [data-video-url], [data-download-url]').forEach(node => {
    ['href', 'src', 'data-url', 'data-src', 'data-video-url', 'data-download-url'].forEach(attr => {
      addCandidate(node.getAttribute?.(attr) || '', node.tagName === 'A' ? 'anchor' : 'attr', {
        allowStreaming: true
      });
    });
  });

  try {
    const entries = performance.getEntriesByType('resource') || [];
    entries.forEach(entry => {
      addCandidate(entry?.name || '', 'performance', {
        allowStreaming: true,
        allowUnknownVideo: ['video', 'xmlhttprequest', 'fetch'].includes(String(entry?.initiatorType || '').toLowerCase())
      });
    });
  } catch {}

  const html = typeof document.documentElement?.outerHTML === 'string'
    ? document.documentElement.outerHTML.slice(0, 2_000_000)
    : '';
  if (html) {
    const matches = html.match(/https?:\/\/[^"'`\s<>]+/gi) || [];
    matches.forEach(match => addCandidate(match, 'html', { allowStreaming: true }));
  }

  return candidates.sort((left, right) => right.score - left.score);
}

async function resolveCurrentProjectMediaUrl(timeoutMs = 9000) {
  const start = Date.now();
  let lastCandidates = [];

  while (Date.now() - start < timeoutMs) {
    lastCandidates = collectProjectMediaCandidates();
    if (lastCandidates.length) {
      return {
        ok: true,
        pageUrl: normalizeUrl(location.href),
        mediaUrl: lastCandidates[0].url,
        candidates: lastCandidates.slice(0, 10)
      };
    }
    await sleep(450);
  }

  return {
    ok: false,
    pageUrl: normalizeUrl(location.href),
    mediaUrl: null,
    candidates: lastCandidates.slice(0, 10),
    message: 'Could not find a direct media URL on this Sora page.'
  };
}

function decodeUrlLikeText(value) {
  return String(value || '')
    .replace(/\\u002f/gi, '/')
    .replace(/\\\//g, '/')
    .replace(/&#x2f;|&#47;/gi, '/')
    .replace(/&quot;/gi, '"')
    .replace(/&amp;/gi, '&');
}

function extractProjectUrlsFromValue(value) {
  const text = decodeUrlLikeText(value);
  const seen = new Set();
  const urls = [];

  const addMatch = raw => {
    const url = normalizeUrl(raw);
    if (!url || !isSoraProjectUrl(url) || seen.has(url)) return;
    seen.add(url);
    urls.push(url);
  };

  for (const match of text.match(ABSOLUTE_SORA_URL_PATTERN) || []) addMatch(match);
  for (const match of text.match(RELATIVE_SORA_URL_PATTERN) || []) addMatch(match);

  return urls;
}

function extractProjectUrlsFromWeakValue(value) {
  const text = decodeUrlLikeText(value);
  const seen = new Set();
  const urls = [];
  const absolutePattern = /https:\/\/sora\.chatgpt\.com\/(?:p\/s_[a-z0-9]+|d\/(?:gen_[a-z0-9_-]+|[a-z0-9_-]{12,}))\/?/gi;
  const relativePattern = /\/(?:p\/s_[a-z0-9]+|d\/(?:gen_[a-z0-9_-]+|[a-z0-9_-]{12,}))\/?/gi;

  const addMatch = raw => {
    const url = normalizeUrl(raw);
    if (!url || !isSoraProjectUrl(url) || seen.has(url)) return;
    seen.add(url);
    urls.push(url);
  };

  for (const match of text.match(absolutePattern) || []) addMatch(match);
  for (const match of text.match(relativePattern) || []) addMatch(match);

  return urls;
}

function getProjectUrlsFromAttributes(node) {
  if (!node?.attributes) return [];

  const seen = new Set();
  const urls = [];
  for (const attr of Array.from(node.attributes)) {
    for (const url of extractProjectUrlsFromValue(attr.value)) {
      if (seen.has(url)) continue;
      seen.add(url);
      urls.push(url);
    }
  }

  return urls;
}

function pickPreferredProjectUrl(urls) {
  const unique = Array.from(new Set((urls || []).map(url => normalizeUrl(url)).filter(isSoraProjectUrl)));
  return unique.find(isSoraPublishedUrl) || unique[0] || null;
}

function addUrl(raw, source = 'scan') {
  const url = normalizeUrl(raw);
  if (!url || !isSoraProjectUrl(url) || discoveredUrls.has(url)) return false;

  discoveredUrls.set(url, { url, source });
  chrome.storage.local.set({ [STORAGE_KEY]: getResults() });
  return true;
}

function getResults() {
  return Array.from(discoveredUrls.values()).sort((left, right) => left.url.localeCompare(right.url));
}

function collectFromLocation() {
  addUrl(location.href, 'location');
}

function collectFromAttributes(root = document) {
  const selector = 'a[href], [data-href], [data-url], [data-link], [data-path]';
  root.querySelectorAll?.(selector).forEach(node => {
    ['href', 'data-href', 'data-url', 'data-link', 'data-path'].forEach(attr => {
      addUrl(node.getAttribute?.(attr) || '', `attr:${attr}`);
    });
  });
}

function collectFromText(root = document) {
  const text = root.body?.innerText || root.documentElement?.innerText || '';
  extractProjectUrlsFromWeakValue(text).forEach(url => addUrl(url, 'text'));
}

function collectFromInlineScripts(root = document) {
  root.querySelectorAll?.('script:not([src])').forEach(script => {
    const text = script.textContent || '';
    if (!text) return;
    extractProjectUrlsFromWeakValue(text).forEach(url => addUrl(url, 'inline-script'));
  });
}

function collectFromHtml(root = document) {
  const now = Date.now();
  if (now - lastFullHtmlScanAt < 4000) return;

  const html = typeof root?.documentElement?.outerHTML === 'string'
    ? root.documentElement.outerHTML
    : typeof root?.outerHTML === 'string'
      ? root.outerHTML
      : '';
  if (!html) return;

  lastFullHtmlScanAt = now;

  for (const url of extractProjectUrlsFromWeakValue(html.slice(0, 2_500_000))) {
    addUrl(url, 'html');
  }
}

function scanForProjectUrls() {
  collectFromLocation();
  collectFromAttributes();
  collectFromInlineScripts();
  collectFromText();
  collectFromHtml();
  return getResults();
}

function refreshHelpersOnly() {
  removeLegacyHelperButtons();
  document.getElementById(HELPER_MENU_ROOT_ID)?.remove();
  document.getElementById(HELPER_STATUS_ID)?.remove();
  ensurePageActionButtons();
}

function ensureHelperKeepAlive() {
  if (helperKeepAliveTimer) return;
  helperKeepAliveTimer = window.setInterval(() => {
    if (!isSoraDomainPage()) return;
    ensurePageActionButtons();
  }, 1200);
}

function scheduleRescan(delay = 150) {
  clearTimeout(rescanTimer);
  rescanTimer = setTimeout(() => {
    lastKnownHref = location.href;
    scanForProjectUrls();
    ensurePageActionButtons();
  }, delay);
}

function installHistoryWatchers() {
  if (historyHooked) return;
  historyHooked = true;

  const originalPushState = history.pushState.bind(history);
  history.pushState = function (...args) {
    const result = originalPushState(...args);
    scheduleRescan(0);
    return result;
  };

  const originalReplaceState = history.replaceState.bind(history);
  history.replaceState = function (...args) {
    const result = originalReplaceState(...args);
    scheduleRescan(0);
    return result;
  };

  window.addEventListener('popstate', () => scheduleRescan(0));
  window.addEventListener('hashchange', () => scheduleRescan(0));
  window.addEventListener('focus', () => scheduleRescan(0));
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) scheduleRescan(0);
  });
}

function handleBridgeMessage(event) {
  if (event.source !== window) return;
  if (event.data?.source !== BRIDGE_SOURCE) return;
  if (event.data?.type !== BRIDGE_TYPE) return;

  addUrl(event.data.url, event.data.via || 'page-hook');
}

function injectPageHook() {
  if (document.getElementById(HOOK_ID)) return;

  const script = document.createElement('script');
  script.id = HOOK_ID;
  script.src = chrome.runtime.getURL('page-hook.js');
  script.dataset.bridgeSource = BRIDGE_SOURCE;
  script.dataset.bridgeType = BRIDGE_TYPE;

  (document.documentElement || document.head || document.body).appendChild(script);
  script.addEventListener('load', () => script.remove(), { once: true });
}

function getProjectLinkUrl(node) {
  if (!node?.getAttribute) return null;

  const attrs = ['href', 'data-href', 'data-url', 'data-link', 'data-path'];
  for (const attr of attrs) {
    const url = normalizeUrl(node.getAttribute(attr) || '');
    if (isSoraProjectUrl(url)) return url;
  }

  return null;
}

function getProjectLinkElements(root = document) {
  const selector = 'a[href], [data-href], [data-url], [data-link], [data-path]';
  return Array.from(root.querySelectorAll?.(selector) || []).filter(node => {
    return Boolean(getProjectLinkUrl(node));
  });
}

function getProjectUrlFromNodeDeep(node) {
  if (!node) return null;

  const found = [];
  const seen = new Set();
  const addUrl = raw => {
    const url = normalizeUrl(raw);
    if (!url || !isSoraProjectUrl(url) || seen.has(url)) return;
    seen.add(url);
    found.push(url);
  };

  const inspectNode = candidate => {
    if (!candidate) return;

    const directUrl = getProjectLinkUrl(candidate);
    if (directUrl) addUrl(directUrl);

    for (const url of getProjectUrlsFromAttributes(candidate)) addUrl(url);
  };

  inspectNode(node);
  getProjectLinkElements(node).forEach(inspectNode);

  if (!found.length) {
    const descendants = Array.from(node.querySelectorAll?.('*') || []).slice(0, CARD_SUBTREE_SCAN_LIMIT);
    for (const candidate of descendants) {
      inspectNode(candidate);
      if (found.length >= 2) break;
    }
  }

  if (!found.length) {
    for (const url of extractProjectUrlsFromValue(textOf(node))) addUrl(url);
  }

  if (!found.length) {
    const html = typeof node.outerHTML === 'string'
      ? node.outerHTML.slice(0, 50000)
      : '';
    for (const url of extractProjectUrlsFromValue(html)) addUrl(url);
  }

  return pickPreferredProjectUrl(found);
}

function textOf(node) {
  return (node?.innerText || node?.textContent || '').replace(/\s+/g, ' ').trim();
}

function normalizeText(value) {
  return textOf({ textContent: value || '' }).toLowerCase();
}

function isVisible(node, minWidth = 20, minHeight = 20) {
  if (!node) return false;
  const style = window.getComputedStyle(node);
  const rect = node.getBoundingClientRect();
  return style.display !== 'none' &&
    style.visibility !== 'hidden' &&
    !node.disabled &&
    rect.width >= minWidth &&
    rect.height >= minHeight;
}

function getClickableNodes(root = document) {
  return Array.from(root.querySelectorAll('button, [role="button"], [role="menuitem"], a[href]'))
    .filter(node => isVisible(node) && !node.closest('[data-sora-helper="true"]'));
}

function getActionPanelFromPostButton(root = document) {
  const postButton = findPostAction(root);
  if (!postButton) return root;

  let current = postButton;
  let best = null;
  let bestScore = -Infinity;

  for (let depth = 0; current && depth < 8; depth += 1) {
    const rect = current.getBoundingClientRect?.() || { width: 0, height: 0 };
    if (rect.width < 220 || rect.height < 120) {
      current = current.parentElement;
      continue;
    }

    const tooLarge = rect.width > Math.max(window.innerWidth * 0.96, 980) && rect.height > Math.max(window.innerHeight * 0.92, 760);
    if (tooLarge) {
      current = current.parentElement;
      continue;
    }

    const buttons = getClickableNodes(current).length;
    const textLength = textOf(current).length;
    const score = buttons * 6 + Math.min(textLength, 180) - depth * 4;
    if (score > bestScore) {
      best = current;
      bestScore = score;
    }

    current = current.parentElement;
  }

  return best || root;
}

function getNodeLabel(node) {
  return normalizeText(
    node?.getAttribute?.('aria-label') ||
    node?.getAttribute?.('title') ||
    node?.value ||
    textOf(node)
  );
}

function getNodeHint(node) {
  return normalizeText([
    node?.id,
    typeof node?.className === 'string' ? node.className : '',
    node?.getAttribute?.('data-testid'),
    node?.getAttribute?.('data-test'),
    node?.getAttribute?.('name'),
    node?.getAttribute?.('aria-describedby')
  ].filter(Boolean).join(' '));
}

function getNodeMarkup(node) {
  return normalizeText(node?.innerHTML || '');
}

function matchesAny(label, patterns) {
  return patterns.some(pattern => label.includes(pattern));
}

function clickNode(node) {
  if (!node) return false;
  try {
    node.scrollIntoView?.({ block: 'center', inline: 'center' });
  } catch {}

  try {
    node.focus?.({ preventScroll: true });
  } catch {}

  const mouseOptions = { bubbles: true, cancelable: true, composed: true, view: window };
  try { node.dispatchEvent(new PointerEvent('pointerdown', mouseOptions)); } catch {}
  try { node.dispatchEvent(new MouseEvent('pointerdown', mouseOptions)); } catch {}
  try { node.dispatchEvent(new MouseEvent('mousedown', mouseOptions)); } catch {}
  try { node.dispatchEvent(new PointerEvent('pointerup', mouseOptions)); } catch {}
  try { node.dispatchEvent(new MouseEvent('mouseup', mouseOptions)); } catch {}

  try {
    if (typeof node.click === 'function') {
      node.click();
    } else {
      node.dispatchEvent(new MouseEvent('click', mouseOptions));
    }
  } catch {
    try { node.dispatchEvent(new MouseEvent('click', mouseOptions)); } catch {}
  }

  return true;
}

function getEditableTextNodes(root = document) {
  const selector = [
    'textarea',
    'input[type="text"]',
    'input:not([type])',
    '[contenteditable="true"]',
    '[contenteditable=""]',
    '[role="textbox"]',
    '.ProseMirror',
    '[data-lexical-editor="true"]'
  ].join(', ');

  return Array.from(root.querySelectorAll?.(selector) || [])
    .filter(node => {
      if (!isVisible(node, 40, 20)) return false;
      if (node.closest?.('[data-sora-helper="true"]')) return false;
      const label = getNodeLabel(node);
      const hint = getNodeHint(node);
      return !matchesAny(`${label} ${hint}`, ['search', 'delete', 'post', 'publish']);
    });
}

function isTextEditableNode(node) {
  return Boolean(
    node &&
    (
      'value' in node ||
      node.isContentEditable ||
      node.getAttribute?.('contenteditable') !== null ||
      node.matches?.('.ProseMirror, [data-lexical-editor="true"], [role="textbox"]')
    )
  );
}

function scoreEditableTextNode(node) {
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  const placeholder = normalizeText(node?.getAttribute?.('placeholder') || '');
  let score = 0;

  if (matchesAny(`${label} ${hint} ${placeholder}`, ['caption'])) score += 160;
  if (matchesAny(`${label} ${hint} ${placeholder}`, ['prompt', 'description', 'describe', 'details'])) score += 120;
  if (node.matches?.('textarea')) score += 35;
  if (node.isContentEditable || node.matches?.('.ProseMirror, [data-lexical-editor="true"]')) score += 25;
  if (matchesAny(`${label} ${hint} ${placeholder}`, ['search', 'title', 'name', 'email'])) score -= 140;

  return score;
}

function findPreferredEditableTextNode(root = document) {
  const ranked = getEditableTextNodes(root)
    .map(node => ({ node, score: scoreEditableTextNode(node) }))
    .sort((left, right) => right.score - left.score);

  return ranked[0]?.node || null;
}

function scoreViewboxAction(node) {
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  let score = 0;

  if (matchesAny(label, ['viewbox', 'view box'])) score += 150;
  if (matchesAny(hint, ['viewbox', 'view-box', 'view_box', 'view box'])) score += 100;
  if (matchesAny(label, ['post', 'publish', 'delete', 'remove', 'done', 'save', 'cancel', 'close'])) score -= 140;

  return score;
}

function findViewboxAction(root = document) {
  const ranked = getClickableNodes(root)
    .map(node => ({ node, score: scoreViewboxAction(node) }))
    .filter(item => item.score >= 80)
    .sort((left, right) => right.score - left.score);

  return ranked[0]?.node || null;
}

function scoreEditDescribeAction(node) {
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  const markup = getNodeMarkup(node);
  const rect = node.getBoundingClientRect?.() || { top: 0, left: 0, width: 0, height: 0 };
  const iconCount = node.querySelectorAll?.('svg, i, [data-icon]')?.length || 0;
  let score = 0;

  if (matchesAny(label, ['edit description', 'edit prompt', 'edit caption', 'edit details'])) score += 140;
  if (matchesAny(label, ['describe', 'description', 'prompt', 'caption', 'details'])) score += 80;
  if (matchesAny(label, ['edit', 'rewrite'])) score += 55;
  if (matchesAny(hint, ['description', 'prompt', 'caption', 'details', 'edit'])) score += 45;
  if (matchesAny(markup, ['pencil', 'edit', 'pen'])) score += 75;
  if (!label && !hint && iconCount) score += 28;
  if (rect.left > window.innerWidth * 0.72 && rect.top > window.innerHeight * 0.18 && rect.top < window.innerHeight * 0.72) score += 34;
  if (Math.abs(rect.width - rect.height) <= 24 && rect.width >= 34 && rect.width <= 110) score += 18;
  if (matchesAny(label, ['post', 'publish', 'delete', 'remove', 'done', 'save', 'cancel', 'close'])) score -= 120;
  if (matchesAny(label, ['extend'])) score -= 60;
  if (matchesAny(hint, ['share', 'menu', 'options'])) score -= 90;

  return score;
}

function findEditDescribeAction(root = document) {
  const ranked = getClickableNodes(root)
    .map(node => ({ node, score: scoreEditDescribeAction(node) }))
    .filter(item => item.score >= 55)
    .sort((left, right) => right.score - left.score);

  return ranked[0]?.node || null;
}

function scoreDoneAction(node) {
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  const markup = getNodeMarkup(node);
  const rect = node.getBoundingClientRect?.() || { top: 0, left: 0, width: 0, height: 0 };
  const iconCount = node.querySelectorAll?.('svg, i, [data-icon]')?.length || 0;
  const text = textOf(node);
  let score = 0;

  if (label === 'done') score += 150;
  if (matchesAny(label, ['done', 'save changes', 'apply', 'update', 'confirm', 'save'])) score += 90;
  if (matchesAny(hint, ['done', 'save', 'apply', 'update', 'confirm'])) score += 45;
  if (matchesAny(text, ['✓', '✔', 'check'])) score += 120;
  if (matchesAny(markup, ['check', 'checkmark', 'done'])) score += 85;
  if (!label && !hint && iconCount) score += 24;
  if (rect.left > window.innerWidth * 0.72 && rect.top > window.innerHeight * 0.18 && rect.top < window.innerHeight * 0.82) score += 30;
  if (Math.abs(rect.width - rect.height) <= 24 && rect.width >= 34 && rect.width <= 110) score += 18;
  if (matchesAny(label, ['post', 'publish', 'delete', 'remove', 'cancel', 'close'])) score -= 120;
  if (matchesAny(label, ['extend'])) score -= 60;
  if (matchesAny(hint, ['share', 'menu', 'options'])) score -= 90;

  return score;
}

function findDoneAction(root = document) {
  const ranked = getClickableNodes(root)
    .map(node => ({ node, score: scoreDoneAction(node) }))
    .filter(item => item.score >= 60)
    .sort((left, right) => right.score - left.score);

  return ranked[0]?.node || null;
}

function dispatchTextInputEvents(node) {
  node.dispatchEvent(new Event('input', { bubbles: true }));
  node.dispatchEvent(new Event('change', { bubbles: true }));
}

function setEditableNodeValue(node, value) {
  if (!node) return false;

  node.focus?.();

  if ('value' in node) {
    const prototype = Object.getPrototypeOf(node);
    const descriptor = prototype ? Object.getOwnPropertyDescriptor(prototype, 'value') : null;
    if (descriptor?.set) descriptor.set.call(node, value);
    else node.value = value;
    dispatchTextInputEvents(node);
    return true;
  }

  if (node.isContentEditable || node.getAttribute?.('contenteditable') !== null || node.matches?.('.ProseMirror, [data-lexical-editor="true"]')) {
    node.textContent = value;
    dispatchTextInputEvents(node);
    return true;
  }

  return false;
}

async function prepareDraftDescriptionBeforePost(silent = false) {
  const actionPanel = getActionPanelFromPostButton(document);
  const rootDialogs = () => getDialogRoots();
  const findAcrossRoots = finder => (
    finder(actionPanel) ||
    finder(document) ||
    rootDialogs().map(root => finder(root)).find(Boolean) ||
    null
  );

  const editAction = findAcrossRoots(findEditDescribeAction) || findAcrossRoots(findViewboxAction);
  if (editAction) {
    clickNode(editAction);
    await sleep(DRAFT_EDIT_OPEN_DELAY_MS);
  }

  let editor = (
    findPreferredEditableTextNode(actionPanel) ||
    findPreferredEditableTextNode(document) ||
    rootDialogs().map(root => findPreferredEditableTextNode(root)).find(Boolean) ||
    null
  );
  let openedEditor = false;

  if (!editor) {
    const opener = findAcrossRoots(findEditDescribeAction) || findAcrossRoots(findViewboxAction);
    if (opener) {
      clickNode(opener);
      openedEditor = true;
      await sleep(DRAFT_EDIT_OPEN_DELAY_MS);
      editor = (
        findPreferredEditableTextNode(actionPanel) ||
        findPreferredEditableTextNode(document) ||
        rootDialogs().map(root => findPreferredEditableTextNode(root)).find(Boolean) ||
        null
      );
    }
  }

  if (!editor && isTextEditableNode(document.activeElement) && isVisible(document.activeElement, 20, 20)) {
    editor = document.activeElement;
  }

  if (!editor) {
    reportPostStatus('Edit description control was not found. Continuing to Post.', silent);
    return { ok: false, edited: false, message: 'Edit description control was not found.' };
  }

  if (!setEditableNodeValue(editor, '')) {
    reportPostStatus('Could not clear the caption field. Continuing to Post.', silent);
    return { ok: false, edited: false, message: 'Could not clear the caption field.' };
  }

  await sleep(DRAFT_EDIT_CLEAR_DELAY_MS);

  const doneAction = findAcrossRoots(findDoneAction);
  if (doneAction) {
    clickNode(doneAction);
    await sleep(DRAFT_EDIT_DONE_DELAY_MS);
    reportPostStatus('Cleared caption, clicked the check button, and continued to Post.', silent);
    return { ok: true, edited: true, message: 'Cleared caption and confirmed the edit.' };
  }

  if (openedEditor) {
    reportPostStatus('Cleared caption. Done button was not found; continuing to Post.', silent);
  }
  return { ok: true, edited: true, message: 'Cleared caption.' };
}

function findDraftAction(root = document) {
  const draftPatterns = [
    'save draft',
    'save as draft',
    'post as draft',
    'publish as draft',
    'move to draft'
  ];

  const nodes = getClickableNodes(root);
  return nodes.find(node => matchesAny(getNodeLabel(node), draftPatterns)) || null;
}

function scorePostAction(node, options = {}) {
  const { inDialog = false } = options;
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  const rect = node.getBoundingClientRect?.() || { width: 0, height: 0, top: 0, left: 0 };
  let score = 0;

  if (!label && !hint) return -Infinity;
  if (label === 'post' || label === 'publish') score += 120;
  if (matchesAny(label, ['publish now', 'publish video', 'post video', 'create post', 'post now'])) score += 95;
  if (matchesAny(label, ['post', 'publish'])) score += 60;
  if (matchesAny(hint, ['post', 'publish', 'submit'])) score += 30;
  if (node.matches?.('button')) score += 10;
  if (inDialog) score += 12;
  if (rect.width >= 56 && rect.height >= 28) score += 8;
  if (rect.width >= 96 && rect.height >= 36) score += 12;
  if (rect.top < window.innerHeight * 0.45) score += 4;
  if (rect.top >= window.innerHeight * 0.45) score += 10;
  if (matchesAny(label, ['draft', 'delete', 'remove', 'trash', 'cancel', 'close', 'save'])) score -= 140;
  if (matchesAny(hint, ['draft', 'delete', 'remove', 'trash'])) score -= 80;

  return score;
}

function findPostAction(root = document, options = {}) {
  const candidates = getClickableNodes(root)
    .map(node => ({ node, score: scorePostAction(node, options) }))
    .filter(item => item.score >= 55)
    .sort((left, right) => right.score - left.score);

  return candidates[0]?.node || null;
}

function scoreMenuAction(node) {
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  const rect = node.getBoundingClientRect?.() || { top: 0, left: 0, width: 0, height: 0 };
  let score = 0;

  if (node.getAttribute('aria-haspopup') === 'menu') score += 90;
  if (matchesAny(label, ['more', 'actions', 'menu', 'options'])) score += 80;
  if (matchesAny(label, ['share'])) score += 45;
  if (matchesAny(hint, ['more', 'actions', 'menu', 'options', 'ellipsis', 'overflow', 'share'])) score += 55;
  if (rect.top < window.innerHeight * 0.45) score += 6;
  if (rect.left > window.innerWidth * 0.45) score += 6;
  if (matchesAny(label, ['delete', 'remove', 'trash'])) score -= 60;

  return score;
}

function findMenuAction(root = document) {
  const candidates = getClickableNodes(root)
    .map(node => ({ node, score: scoreMenuAction(node) }))
    .filter(item => item.score >= 45)
    .sort((left, right) => right.score - left.score);

  return candidates[0]?.node || null;
}

function findDeleteMenuAction(root = document) {
  const nodes = getClickableNodes(root);
  const explicit = nodes.find(node => {
    const label = getNodeLabel(node);
    const hint = getNodeHint(node);
    return matchesAny(label, ['more', 'actions', 'menu', 'options']) ||
      matchesAny(hint, ['more', 'actions', 'menu', 'options', 'ellipsis']) ||
      node.getAttribute('aria-haspopup') === 'menu';
  });
  if (explicit) return explicit;

  return nodes.find(node => {
    const label = getNodeLabel(node);
    const hint = getNodeHint(node);
    const hasIcon = Boolean(node.querySelector?.('svg'));
    return (hasIcon && !label) || matchesAny(hint, ['ellipsis', 'more-horizontal', 'dots']);
  }) || null;
}

function scoreThreeDotMenuButton(node) {
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  const rect = node.getBoundingClientRect?.() || { top: 0, left: 0, width: 0, height: 0 };
  const iconCount = node.querySelectorAll?.('svg, i, [data-icon]')?.length || 0;
  const markup = normalizeText(node.innerHTML || '');
  let score = 0;

  if (node.getAttribute('aria-haspopup') === 'menu') score += 90;
  if (matchesAny(label, ['more', 'more actions', 'actions', 'menu', 'options'])) score += 70;
  if (matchesAny(hint, ['more', 'actions', 'menu', 'options', 'ellipsis', 'overflow', 'dots'])) score += 60;
  if (/[⋯…]/.test(textOf(node))) score += 60;
  if (matchesAny(markup, ['ellipsis', 'three dots', 'more_horiz', 'more_vert', 'overflow'])) score += 25;
  if (!label && iconCount) score += 18;
  if (rect.top < window.innerHeight * 0.38) score += 14;
  if (rect.left > window.innerWidth * 0.55) score += 14;
  if (rect.width > 12 && rect.width <= 72 && rect.height > 12 && rect.height <= 72) score += 10;
  if (matchesAny(label, ['share'])) score -= 40;

  return score;
}

function findThreeDotMenuButton(root = document) {
  const nodes = getClickableNodes(root);
  const ranked = nodes
    .map(node => ({ node, score: scoreThreeDotMenuButton(node) }))
    .filter(item => item.score >= 60)
    .sort((left, right) => right.score - left.score);

  return ranked[0]?.node || null;
}

function getDialogRoots() {
  return Array.from(document.querySelectorAll('[role="dialog"], [role="menu"], dialog, [data-state="open"]'))
    .filter(node => isVisible(node, 40, 40));
}

function countVisibleVisuals(root) {
  return Array.from(root.querySelectorAll('img, video, canvas, picture'))
    .filter(node => isVisible(node, 24, 24)).length;
}

function getCardFromProjectNode(startNode) {
  let current = startNode;
  let best = null;
  let bestScore = -Infinity;

  for (let depth = 0; current && depth < 8; depth += 1) {
    if (current.matches?.('article, li, [role="listitem"], section, div, figure')) {
      const rect = current.getBoundingClientRect();
      const visuals = countVisibleVisuals(current);
      const buttons = Array.from(current.querySelectorAll('button, [role="button"]')).filter(node => isVisible(node)).length;
      if (rect.width < 140 || rect.height < 100) {
        current = current.parentElement;
        continue;
      }

      const tooLarge = rect.width > Math.max(window.innerWidth * 0.95, 900) && rect.height > Math.max(window.innerHeight * 0.9, 720);
      if (tooLarge) {
        current = current.parentElement;
        continue;
      }

      const score = (visuals * 4) + Math.min(buttons, 6) - depth;
      if (score > bestScore) {
        best = current;
        bestScore = score;
      }
    }
    current = current.parentElement;
  }

  return best;
}

function getCardFromProjectAnchor(anchor) {
  return getCardFromProjectNode(anchor);
}

function getProjectCardTitle(card, sourceNode, index) {
  const candidateSelectors = ['h1', 'h2', 'h3', 'figcaption', '[title]', '[aria-label]', 'img[alt]'];
  for (const selector of candidateSelectors) {
    const nodes = card.matches?.(selector) ? [card] : [];
    nodes.push(...card.querySelectorAll(selector));
    for (const node of nodes) {
      const value = selector === 'img[alt]'
        ? node.getAttribute('alt')
        : selector === '[title]'
          ? node.getAttribute('title')
          : selector === '[aria-label]'
            ? node.getAttribute('aria-label')
            : textOf(node);
      const label = textOf({ textContent: value || '' });
      if (label && label.length <= 120) return label;
    }
  }

  const href = getProjectUrlFromNodeDeep(sourceNode) || getProjectUrlFromNodeDeep(card);
  if (href) {
    try {
      return new URL(href).pathname.split('/').filter(Boolean).pop() || `Video ${index + 1}`;
    } catch {}
  }

  return `Video ${index + 1}`;
}

function sortProfileCards(cards) {
  return cards.sort((left, right) => {
    const a = left.getBoundingClientRect();
    const b = right.getBoundingClientRect();
    if (Math.abs(a.top - b.top) > 8) return a.top - b.top;
    return a.left - b.left;
  });
}

function getVisibleProfileCardNodes() {
  const seenCards = new Set();
  const cards = [];
  const addCard = card => {
    if (!card || seenCards.has(card) || !isVisible(card, 120, 90)) return;
    seenCards.add(card);
    cards.push(card);
  };

  getProjectLinkElements(document).forEach(node => addCard(getCardFromProjectAnchor(node)));

  const menuCandidates = getClickableNodes(document).filter(node => {
    const label = getNodeLabel(node);
    const hasIcon = Boolean(node.querySelector?.('svg'));
    return matchesAny(label, ['more', 'actions', 'menu', 'options']) ||
      node.getAttribute('aria-haspopup') === 'menu' ||
      (hasIcon && !label);
  });

  menuCandidates.forEach(node => addCard(getCardFromProjectNode(node)));

  const visualCandidates = Array.from(document.querySelectorAll('img, video, canvas, picture'))
    .filter(node => isVisible(node, 24, 24));
  visualCandidates.forEach(node => addCard(getCardFromProjectNode(node)));

  return sortProfileCards(cards);
}

function getGlobalProfileProjectUrls() {
  scanForProjectUrls();
  const discovered = getResults()
    .map(item => normalizeUrl(item?.url || ''))
    .filter(isSoraProjectUrl)
    .filter(url => normalizeUrl(location.href) !== url);
  const htmlUrls = extractProjectUrlsFromValue(
    typeof document.documentElement?.outerHTML === 'string'
      ? document.documentElement.outerHTML.slice(0, 2_500_000)
      : ''
  ).map(url => normalizeUrl(url)).filter(isSoraProjectUrl);
  const allUrls = Array.from(new Set([...discovered, ...htmlUrls]))
    .filter(url => normalizeUrl(location.href) !== url);
  const publishedUrls = allUrls.filter(isSoraPublishedUrl);
  return publishedUrls.length ? Array.from(new Set(publishedUrls)) : Array.from(new Set(allUrls));
}

function getGlobalDraftProjectUrls() {
  scanForProjectUrls();
  const discovered = getResults()
    .map(item => normalizeUrl(item?.url || ''))
    .filter(isSoraDraftUrl)
    .filter(url => normalizeUrl(location.href) !== url);
  const htmlUrls = extractProjectUrlsFromValue(
    typeof document.documentElement?.outerHTML === 'string'
      ? document.documentElement.outerHTML.slice(0, 2_500_000)
      : ''
  ).map(url => normalizeUrl(url)).filter(isSoraDraftUrl);

  return Array.from(new Set([...discovered, ...htmlUrls]))
    .filter(url => normalizeUrl(location.href) !== url);
}

function getBestVisibleProjectVisual(root) {
  if (!root) return null;

  const candidates = [];
  const addCandidate = node => {
    if (!node || !isVisible(node, 24, 24)) return;
    const rect = node.getBoundingClientRect();
    candidates.push({
      node,
      score: rect.width * rect.height
    });
  };

  if (matchesAny(root.tagName, ['IMG', 'VIDEO', 'CANVAS', 'PICTURE'])) {
    addCandidate(root);
  }

  root.querySelectorAll?.('img, video, canvas, picture').forEach(addCandidate);
  return candidates.sort((left, right) => right.score - left.score)[0]?.node || null;
}

function getProfileCardEntries() {
  const seenCards = new Set();
  const seenUrls = new Set();
  const entries = [];
  const cards = getVisibleProfileCardNodes();

  const addEntry = (card, url, sourceNode, index) => {
    if (!card || !url) return;
    if (seenCards.has(card) || seenUrls.has(url)) return;
    if (!isVisible(card, 120, 90)) return;
    if (normalizeUrl(location.href) === url) return;

    seenCards.add(card);
    seenUrls.add(url);
    entries.push({
      key: url,
      url,
      title: getProjectCardTitle(card, sourceNode || card, index),
      card,
      visual: getBestVisibleProjectVisual(card)
    });
  };

  cards.forEach((card, index) => {
    const url = getProjectUrlFromNodeDeep(card);
    if (url) addEntry(card, url, card, index);
  });

  const fallbackUrls = getGlobalProfileProjectUrls().filter(url => !seenUrls.has(url));
  cards.forEach((card, index) => {
    if (seenCards.has(card)) return;
    const fallbackUrl = fallbackUrls.shift();
    if (!fallbackUrl) return;
    addEntry(card, fallbackUrl, card, index);
  });

  return entries.sort((left, right) => {
    const a = left.card.getBoundingClientRect();
    const b = right.card.getBoundingClientRect();
    if (Math.abs(a.top - b.top) > 8) return a.top - b.top;
    return a.left - b.left;
  });
}

function getVisiblePublishedVisualEntries() {
  const seenUrls = new Set();
  const visuals = Array.from(document.querySelectorAll('img, video, canvas, picture'))
    .filter(node => isVisible(node, 90, 140))
    .map(node => ({ node, rect: node.getBoundingClientRect() }))
    .filter(entry => entry.rect.width * entry.rect.height >= 70_000)
    .sort((left, right) => {
      if (Math.abs(left.rect.top - right.rect.top) > 8) return left.rect.top - right.rect.top;
      return left.rect.left - right.rect.left;
    });

  const fallbackUrls = getGlobalProfileProjectUrls().filter(isSoraPublishedUrl);
  const entries = [];

  visuals.forEach((entry, index) => {
    const visual = entry.node;
    const card = getCardFromProjectNode(visual) || visual.parentElement || visual;
    let url = getProjectUrlFromNodeDeep(visual) || getProjectUrlFromNodeDeep(card) || null;

    while ((!url || seenUrls.has(url)) && fallbackUrls.length) {
      const nextUrl = fallbackUrls.shift();
      if (nextUrl && !seenUrls.has(nextUrl)) {
        url = nextUrl;
        break;
      }
    }

    if (!url || seenUrls.has(url)) return;
    seenUrls.add(url);
    entries.push({
      key: url,
      url,
      title: getProjectCardTitle(card, visual, index),
      card,
      visual
    });
  });

  return entries;
}

function getPublishedAnchorCardEntries() {
  const seenUrls = new Set();
  const entries = [];

  getProjectLinkElements(document).forEach((node, index) => {
    const url = getProjectLinkUrl(node);
    if (!isSoraPublishedUrl(url) || seenUrls.has(url)) return;

    const card =
      getCardFromProjectAnchor(node) ||
      getCardFromProjectNode(node) ||
      node.parentElement ||
      node;
    if (!card || !isVisible(card, 120, 90)) return;

    const visual =
      getBestVisibleProjectVisual(card) ||
      getBestVisibleProjectVisual(node.parentElement) ||
      getBestVisibleProjectVisual(node) ||
      null;
    if (!visual) return;

    seenUrls.add(url);
    entries.push({
      key: url,
      url,
      title: getProjectCardTitle(card, visual, index),
      card,
      visual
    });
  });

  return entries.sort((left, right) => {
    const a = left.visual.getBoundingClientRect();
    const b = right.visual.getBoundingClientRect();
    if (Math.abs(a.top - b.top) > 8) return a.top - b.top;
    return a.left - b.left;
  });
}

function getDraftCardEntries() {
  const seenCards = new Set();
  const seenUrls = new Set();
  const entries = [];
  const cards = getVisibleProfileCardNodes();

  const addEntry = (card, url, sourceNode, index) => {
    if (!card || !url || !isSoraDraftUrl(url)) return;
    if (seenCards.has(card) || seenUrls.has(url)) return;
    if (!isVisible(card, 120, 90)) return;

    seenCards.add(card);
    seenUrls.add(url);
    entries.push({
      key: url,
      url,
      title: getProjectCardTitle(card, sourceNode || card, index),
      card
    });
  };

  cards.forEach((card, index) => {
    const url = getProjectUrlFromNodeDeep(card);
    if (isSoraDraftUrl(url)) addEntry(card, url, card, index);
  });

  const fallbackUrls = getGlobalDraftProjectUrls().filter(url => !seenUrls.has(url));
  cards.forEach((card, index) => {
    if (seenCards.has(card)) return;
    const fallbackUrl = fallbackUrls.shift();
    if (!fallbackUrl) return;
    addEntry(card, fallbackUrl, card, index);
  });

  return entries.sort((left, right) => {
    const a = left.card.getBoundingClientRect();
    const b = right.card.getBoundingClientRect();
    if (Math.abs(a.top - b.top) > 8) return a.top - b.top;
    return a.left - b.left;
  });
}

function isProfileListPage() {
  return isSoraDomainPage() && !isSoraProjectUrl(location.href) && getVisibleProfileCardNodes().length > 0;
}

async function waitForProfileListPage(timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (isProfileListPage()) return true;
    await sleep(400);
  }
  return false;
}

function isDraftListPage() {
  return isSoraDraftsPage() && getVisibleProfileCardNodes().length > 0;
}

async function waitForDraftListPage(timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (isDraftListPage()) return true;
    await sleep(400);
  }
  return false;
}

function findCardMenuAction(root) {
  const nodes = getClickableNodes(root);
  const explicit = nodes.find(node => {
    const label = getNodeLabel(node);
    return matchesAny(label, ['more', 'actions', 'menu', 'options']) || node.getAttribute('aria-haspopup') === 'menu';
  });
  if (explicit) return explicit;

  return nodes.find(node => {
    const label = getNodeLabel(node);
    const hasIcon = Boolean(node.querySelector?.('svg'));
    return hasIcon && !label;
  }) || null;
}

function matchesDeleteAction(node) {
  const label = getNodeLabel(node);
  return matchesAny(label, [
    'delete',
    'delete video',
    'delete project',
    'delete post',
    'delete generation',
    'permanently delete',
    'remove',
    'remove forever',
    'trash'
  ]);
}

function scoreDeleteAction(node, options = {}) {
  const { inDialog = false } = options;
  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  let score = 0;

  if (matchesDeleteAction(node)) score += 80;
  if (label === 'delete') score += 35;
  if (matchesAny(label, ['delete project', 'delete video', 'delete post', 'delete generation'])) score += 45;
  if (matchesAny(label, ['permanently delete', 'remove forever'])) score += 55;
  if (matchesAny(hint, ['delete', 'danger', 'trash', 'remove'])) score += 20;
  if (node.matches?.('[role="menuitem"]')) score += 10;
  if (node.getAttribute('aria-haspopup') === 'dialog') score += 5;
  if (inDialog) score += 25;
  if (matchesAny(label, ['cancel', 'close', 'back'])) score -= 80;

  return score;
}

function findBestDeleteAction(root, options = {}) {
  const candidates = getClickableNodes(root)
    .filter(node => matchesDeleteAction(node) || matchesAny(getNodeHint(node), ['delete', 'danger', 'trash']));

  if (!candidates.length) return null;

  return candidates
    .map(node => ({ node, score: scoreDeleteAction(node, options) }))
    .sort((left, right) => right.score - left.score)[0]?.node || null;
}

function getDeleteTimings(fastMode = false) {
  return {
    actionDelay: fastMode ? FAST_DELETE_ACTION_DELAY_MS : NORMAL_DELETE_ACTION_DELAY_MS,
    menuDelay: fastMode ? FAST_DELETE_MENU_DELAY_MS : NORMAL_DELETE_MENU_DELAY_MS,
    confirmDelay: fastMode ? FAST_DELETE_CONFIRM_DELAY_MS : NORMAL_DELETE_CONFIRM_DELAY_MS,
    retryDelay: fastMode ? FAST_DELETE_RETRY_DELAY_MS : NORMAL_DELETE_RETRY_DELAY_MS,
    timeout: fastMode ? FAST_DELETE_TIMEOUT_MS : NORMAL_DELETE_TIMEOUT_MS
  };
}

async function clickDeleteAction(options = {}) {
  const timings = getDeleteTimings(Boolean(options.fastMode));
  const menuDelete = getDialogRoots()
    .filter(root => root.getAttribute('role') === 'menu')
    .map(root => findBestDeleteAction(root, { inDialog: true }))
    .find(Boolean);
  if (menuDelete) {
    clickNode(menuDelete);
    await sleep(Math.max(50, timings.actionDelay));
    return true;
  }

  const dialogDelete = getDialogRoots()
    .filter(root => root.getAttribute('role') !== 'menu')
    .map(root => findBestDeleteAction(root, { inDialog: true }))
    .find(Boolean);
  if (dialogDelete) {
    clickNode(dialogDelete);
    await sleep(Math.max(50, timings.actionDelay));
    return true;
  }

  const pageDelete = findBestDeleteAction(document);
  if (!pageDelete) return false;
  clickNode(pageDelete);
  await sleep(Math.max(50, timings.actionDelay));
  return true;
}

async function confirmDelete(card, options = {}) {
  const timings = getDeleteTimings(Boolean(options.fastMode));
  const dialogs = Array.from(document.querySelectorAll('[role="dialog"], dialog, [data-state="open"]'))
    .filter(node => isVisible(node, 40, 40) && node.getAttribute('role') !== 'menu');
  for (const root of dialogs) {
    const deleteButtons = getClickableNodes(root).filter(matchesDeleteAction);
    const confirmButton = deleteButtons[deleteButtons.length - 1];
    if (!confirmButton) continue;
    clickNode(confirmButton);
    await sleep(Math.max(80, timings.confirmDelay));
    return true;
  }

  await sleep(Math.max(80, timings.confirmDelay));
  return !card.isConnected || !isVisible(card, 20, 20);
}

async function waitForProjectDeletion(targetUrl, options = {}) {
  const timings = getDeleteTimings(Boolean(options.fastMode));
  const start = Date.now();
  const target = normalizeUrl(targetUrl);

  while (Date.now() - start < timings.timeout) {
    const current = normalizeUrl(location.href);
    if (target && current && current !== target) return true;

    const pageText = normalizeText(document.body?.innerText || '');
    if (matchesAny(pageText, ['not found', 'page not found', 'deleted', 'removed'])) return true;

    await sleep(Math.max(70, Math.floor(timings.retryDelay)));
  }

  return false;
}

async function confirmProjectDelete(targetUrl, options = {}) {
  const timings = getDeleteTimings(Boolean(options.fastMode));
  const dialogs = Array.from(document.querySelectorAll('[role="dialog"], dialog, [data-state="open"]'))
    .filter(node => isVisible(node, 40, 40) && node.getAttribute('role') !== 'menu');
  for (const root of dialogs) {
    const confirmButton = findBestDeleteAction(root, { inDialog: true });
    if (!confirmButton) continue;
    clickNode(confirmButton);
    await sleep(timings.confirmDelay);
    return waitForProjectDeletion(targetUrl, options);
  }

  return false;
}

async function openDeleteProjectMenu(options = {}) {
  const timings = getDeleteTimings(Boolean(options.fastMode));
  const existingMenus = getDialogRoots().filter(root => root.getAttribute('role') === 'menu').length;
  const opener = findThreeDotMenuButton(document) || findDeleteMenuAction(document) || findMenuAction(document) || findCardMenuAction(document);
  if (!opener) return false;

  clickNode(opener);
  await sleep(Math.max(60, Math.floor(timings.menuDelay / 2)));

  const currentMenus = getDialogRoots().filter(root => root.getAttribute('role') === 'menu').length;
  if (currentMenus > existingMenus) return true;
  if (findBestDeleteAction(document)) return true;

  await sleep(Math.max(50, Math.floor(timings.menuDelay / 2)));
  return Boolean(findBestDeleteAction(document));
}

async function deleteSingleProfileCard(entry, options = {}) {
  const { card, key, title, url } = entry;
  const timings = getDeleteTimings(Boolean(options.fastMode));
  if (!card?.isConnected) {
    return { ok: false, key, title, url, reason: 'Card no longer exists' };
  }

  card.scrollIntoView({ behavior: 'auto', block: 'center' });
  await sleep(Math.max(90, timings.actionDelay));

  const menu = findThreeDotMenuButton(card) || findCardMenuAction(card);
  if (!menu) {
    return { ok: false, key, title, url, reason: 'Card menu not found' };
  }

  clickNode(menu);
  await sleep(Math.max(90, timings.menuDelay));

  const deleted = await clickDeleteAction({ fastMode: options.fastMode !== false });
  if (!deleted) {
    return { ok: false, key, title, url, reason: 'Delete action not found' };
  }

  const confirmed = await confirmDelete(card, { fastMode: options.fastMode !== false });
  if (!confirmed) {
    return { ok: false, key, title, url, reason: 'Delete confirmation not found' };
  }

  await sleep(Math.max(90, timings.confirmDelay));
  return { ok: true, key, title, url };
}

async function scrollForMoreCards() {
  const before = Math.max(
    document.documentElement.scrollHeight || 0,
    document.body?.scrollHeight || 0
  );

  window.scrollTo({ top: before, behavior: 'auto' });
  await sleep(1400);

  const after = Math.max(
    document.documentElement.scrollHeight || 0,
    document.body?.scrollHeight || 0
  );

  return after > before + 20;
}

function injectHelperStyles() {
  if (document.getElementById(HELPER_STYLE_ID)) return;

  const style = document.createElement('style');
  style.id = HELPER_STYLE_ID;
  style.textContent = `
    #${HELPER_MENU_ROOT_ID} {
      position: fixed;
      top: 20px;
      right: 20px;
      z-index: 2147483647;
      display: flex;
      flex-direction: column;
      align-items: flex-end;
      gap: 8px;
      pointer-events: none;
    }
    #${HELPER_MENU_ROOT_ID} > * {
      pointer-events: auto;
    }
    #${HELPER_MENU_TRIGGER_ID} {
      border: 0;
      border-radius: 999px;
      background: linear-gradient(135deg, #111827, #2563eb);
      color: #fff;
      padding: 10px 16px;
      font: 600 14px/1 Arial, sans-serif;
      box-shadow: 0 12px 30px rgba(17, 24, 39, 0.28);
      cursor: pointer;
    }
    #${HELPER_MENU_TRIGGER_ID}:hover {
      filter: brightness(1.05);
    }
    #${HELPER_MENU_PANEL_ID} {
      width: min(320px, calc(100vw - 32px));
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.98);
      color: #111827;
      border: 1px solid rgba(209, 213, 219, 0.95);
      box-shadow: 0 18px 48px rgba(17, 24, 39, 0.24);
      padding: 12px;
      opacity: 0;
      transform: translateY(-8px) scale(0.98);
      pointer-events: none;
      transition: opacity 160ms ease, transform 160ms ease;
    }
    #${HELPER_MENU_ROOT_ID}[data-open="true"] #${HELPER_MENU_PANEL_ID} {
      opacity: 1;
      transform: translateY(0) scale(1);
      pointer-events: auto;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-title {
      font: 700 13px/1.2 Arial, sans-serif;
      margin: 0 0 4px 0;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-subtitle {
      font: 12px/1.4 Arial, sans-serif;
      color: #4b5563;
      margin: 0 0 10px 0;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-button {
      border: 0;
      border-radius: 10px;
      padding: 10px 12px;
      font: 600 12px/1.2 Arial, sans-serif;
      cursor: pointer;
      color: #fff;
      background: #111827;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-button[data-tone="post"] {
      background: #2563eb;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-button[data-tone="delete"] {
      background: #dc2626;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-button[data-tone="neutral"] {
      background: #374151;
    }
    #${HELPER_MENU_PANEL_ID} .sora-menu-button:disabled {
      opacity: 0.58;
      cursor: not-allowed;
    }
    #${HELPER_MENU_META_ID} {
      margin-top: 10px;
      font: 12px/1.4 Arial, sans-serif;
      color: #374151;
      min-height: 18px;
    }
    #${HELPER_STATUS_ID} {
      position: fixed;
      right: 20px;
      top: 84px;
      z-index: 2147483647;
      max-width: 280px;
      border-radius: 12px;
      background: rgba(17, 24, 39, 0.95);
      color: #fff;
      padding: 10px 12px;
      font: 12px/1.4 Arial, sans-serif;
      box-shadow: 0 10px 24px rgba(17, 24, 39, 0.24);
      opacity: 0;
      transform: translateY(8px);
      pointer-events: none;
      transition: opacity 160ms ease, transform 160ms ease;
    }
    #${HELPER_STATUS_ID}[data-show="true"] {
      opacity: 1;
      transform: translateY(0);
    }
    #${DRAFTS_POST_ACTIONS_ID} {
      position: fixed;
      top: 20px;
      right: 20px;
      z-index: 2147483647;
      display: flex;
      flex-direction: column;
      align-items: flex-end;
      gap: 8px;
      pointer-events: none;
    }
    #${DRAFTS_POST_ACTIONS_ID} > * {
      pointer-events: auto;
    }
    #${DRAFTS_POST_TRIGGER_ID} {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      border: 0;
      border-radius: 999px;
      padding: 12px 16px;
      background: linear-gradient(135deg, #111827 0%, #2563eb 100%);
      color: #fff;
      box-shadow: 0 16px 36px rgba(17, 24, 39, 0.28);
      font: 700 13px/1 Arial, sans-serif;
      cursor: pointer;
      min-width: 156px;
      text-align: center;
    }
    #${DRAFTS_POST_TRIGGER_ID}:hover {
      filter: brightness(1.04);
    }
    #${DRAFTS_POST_TRIGGER_ID}[data-open="true"] {
      box-shadow: 0 18px 40px rgba(17, 24, 39, 0.34);
    }
    #${DRAFTS_POST_PANEL_ID} {
      width: min(220px, calc(100vw - 40px));
      display: flex;
      flex-direction: column;
      gap: 10px;
      opacity: 0;
      transform: translateY(-8px) scale(0.98);
      pointer-events: none;
      transition: opacity 150ms ease, transform 150ms ease;
    }
    #${DRAFTS_POST_ACTIONS_ID}[data-open="true"] #${DRAFTS_POST_PANEL_ID} {
      opacity: 1;
      transform: translateY(0) scale(1);
      pointer-events: auto;
    }
    #${DRAFTS_POST_BUTTON_ID},
    #${DRAFTS_POST_FIVE_BUTTON_ID},
    #${DRAFTS_POST_TEN_BUTTON_ID} {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      border: 0;
      border-radius: 14px;
      padding: 12px 16px;
      background: linear-gradient(135deg, #111827 0%, #2563eb 100%);
      color: #fff;
      box-shadow: 0 16px 36px rgba(17, 24, 39, 0.28);
      font: 700 13px/1 Arial, sans-serif;
      cursor: pointer;
      width: 100%;
      text-align: center;
    }
    #${DRAFTS_POST_FIVE_BUTTON_ID},
    #${DRAFTS_POST_TEN_BUTTON_ID} {
      background: linear-gradient(135deg, #1f2937 0%, #1d4ed8 100%);
    }
    #${DRAFTS_POST_BUTTON_ID}[data-busy="true"],
    #${DRAFTS_POST_FIVE_BUTTON_ID}[data-busy="true"],
    #${DRAFTS_POST_TEN_BUTTON_ID}[data-busy="true"] {
      opacity: 0.75;
      cursor: progress;
    }
    #${DRAFTS_POST_TRIGGER_ID} .sora-badge,
    #${DRAFTS_POST_BUTTON_ID} .sora-badge,
    #${DRAFTS_POST_FIVE_BUTTON_ID} .sora-badge,
    #${DRAFTS_POST_TEN_BUTTON_ID} .sora-badge {
      width: 24px;
      height: 24px;
      border-radius: 999px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      background: rgba(255, 255, 255, 0.16);
      border: 1px solid rgba(255, 255, 255, 0.2);
      font: 700 12px/1 Arial, sans-serif;
    }
    #${PROFILE_ACTIONS_ID} {
      position: fixed;
      top: 20px;
      right: 20px;
      z-index: 2147483647;
      display: flex;
      flex-direction: column;
      align-items: flex-end;
      gap: 10px;
      pointer-events: none;
    }
    #${PROFILE_ACTIONS_ID} > * {
      pointer-events: auto;
    }
    #${PROFILE_ACTIONS_PANEL_ID} {
      width: min(220px, calc(100vw - 40px));
      display: flex;
      flex-direction: column;
      gap: 10px;
      max-height: 0;
      overflow: hidden;
      opacity: 0;
      transform: translateY(-8px) scale(0.98);
      pointer-events: none;
      margin-top: -10px;
      margin-bottom: -10px;
      transition: max-height 180ms ease, opacity 150ms ease, transform 150ms ease, margin 150ms ease;
    }
    #${PROFILE_ACTIONS_ID}[data-open="true"] #${PROFILE_ACTIONS_PANEL_ID} {
      max-height: 220px;
      opacity: 1;
      transform: translateY(0) scale(1);
      pointer-events: auto;
      margin-top: 0;
      margin-bottom: 0;
    }
    #${PROFILE_ACTIONS_ID} .sora-profile-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      border: 0;
      border-radius: 14px;
      padding: 12px 14px;
      color: #fff;
      box-shadow: 0 16px 36px rgba(17, 24, 39, 0.22);
      font: 700 13px/1 Arial, sans-serif;
      cursor: pointer;
      width: min(220px, calc(100vw - 40px));
      text-align: center;
    }
    #${PROFILE_ACTIONS_ID} .sora-profile-button[data-tone="copy"] {
      background: linear-gradient(135deg, #1f2937 0%, #2563eb 100%);
    }
    #${PROFILE_ACTIONS_ID} .sora-profile-button[data-tone="download"] {
      background: linear-gradient(135deg, #0f172a 0%, #059669 100%);
    }
    #${PROFILE_ACTIONS_ID} .sora-profile-button[data-tone="delete"] {
      background: linear-gradient(135deg, #450a0a 0%, #dc2626 100%);
    }
    #${PROFILE_ACTIONS_ID} .sora-profile-button[data-busy="true"] {
      opacity: 0.76;
      cursor: progress;
    }
    #${PROFILE_ACTIONS_STATUS_ID} {
      border-radius: 12px;
      background: rgba(17, 24, 39, 0.92);
      color: #fff;
      padding: 10px 12px;
      font: 12px/1.45 Arial, sans-serif;
      box-shadow: 0 12px 28px rgba(17, 24, 39, 0.18);
      min-height: 18px;
      word-break: break-word;
    }
    .${EXPLORE_CARD_HOST_CLASS} {
      position: relative !important;
    }
    .${EXPLORE_CARD_DOWNLOAD_CLASS} {
      position: absolute;
      top: 12px;
      left: 12px;
      z-index: 12;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 86px;
      border: 0;
      border-radius: 999px;
      padding: 10px 14px;
      background: linear-gradient(135deg, #0f172a 0%, #059669 100%);
      color: #fff;
      box-shadow: 0 12px 28px rgba(15, 23, 42, 0.3);
      font: 700 12px/1 Arial, sans-serif;
      cursor: pointer;
    }
    .${EXPLORE_CARD_DOWNLOAD_CLASS}[data-layout="compact"] {
      width: 38px;
      height: 38px;
      min-width: 38px;
      padding: 0;
      border-radius: 999px;
      font-size: 0;
    }
    .${EXPLORE_CARD_DOWNLOAD_CLASS}[data-layout="compact"]::before {
      content: '↓';
      display: block;
      font: 700 18px/1 Arial, sans-serif;
      color: #fff;
    }
    .${EXPLORE_CARD_DOWNLOAD_CLASS}[data-layout="compact"][data-busy="true"]::before {
      content: '...';
      font: 700 11px/1 Arial, sans-serif;
      letter-spacing: 1px;
    }
    .${EXPLORE_CARD_DOWNLOAD_CLASS}[data-busy="true"] {
      opacity: 0.8;
      cursor: progress;
    }
    .${PROJECT_PAGE_DOWNLOAD_CLASS} {
      position: fixed;
      z-index: 2147483000;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 120px;
      border: 0;
      border-radius: 999px;
      padding: 10px 14px;
      background: linear-gradient(135deg, #0f172a 0%, #059669 100%);
      color: #fff;
      box-shadow: 0 12px 28px rgba(15, 23, 42, 0.3);
      font: 700 12px/1 Arial, sans-serif;
      cursor: pointer;
      pointer-events: auto;
      user-select: none;
    }
    .${PROJECT_PAGE_DOWNLOAD_CLASS}[data-layout="rail"] {
      width: 42px;
      height: 42px;
      min-width: 42px;
      padding: 0;
      border-radius: 999px;
      font-size: 0;
      box-shadow: 0 10px 24px rgba(15, 23, 42, 0.32);
    }
    .${PROJECT_PAGE_DOWNLOAD_CLASS}[data-layout="rail"]::before {
      content: '↓';
      display: block;
      font: 700 20px/1 Arial, sans-serif;
      color: #fff;
    }
    .${PROJECT_PAGE_DOWNLOAD_CLASS}[data-layout="rail"][data-busy="true"]::before {
      content: '...';
      font: 700 12px/1 Arial, sans-serif;
      letter-spacing: 1px;
    }
    .${PROJECT_PAGE_DOWNLOAD_CLASS}[data-busy="true"] {
      opacity: 0.8;
      cursor: progress;
    }
    #${PROFILE_BUY_MODAL_ID} {
      position: fixed;
      inset: 0;
      z-index: 2147483647;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 18px;
      background: rgba(15, 23, 42, 0.68);
      backdrop-filter: blur(6px);
    }
    #${PROFILE_BUY_DIALOG_ID} {
      width: min(360px, calc(100vw - 28px));
      max-height: min(420px, calc(100vh - 28px));
      border-radius: 20px;
      overflow: hidden;
      background: linear-gradient(180deg, #fff7ed 0%, #ffffff 52%, #eff6ff 100%);
      border: 1px solid rgba(226, 232, 240, 0.95);
      box-shadow: 0 28px 64px rgba(15, 23, 42, 0.3);
      display: flex;
      flex-direction: column;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 14px 16px;
      border-bottom: 1px solid rgba(226, 232, 240, 0.95);
      background: rgba(255, 255, 255, 0.82);
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-title {
      font: 800 16px/1.2 Arial, sans-serif;
      color: #111827;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-close {
      border: 0;
      width: 38px;
      height: 38px;
      border-radius: 999px;
      background: #374151;
      color: #fff;
      font: 700 18px/1 Arial, sans-serif;
      cursor: pointer;
      flex: 0 0 auto;
    }
    #${PROFILE_BUY_CONTENT_ID} {
      flex: 1 1 auto;
      padding: 14px;
      overflow: auto;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-plan-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 8px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-plan {
      border: 1px solid #d1d5db;
      border-radius: 14px;
      background: #fff;
      color: #111827;
      padding: 12px 8px;
      cursor: pointer;
      text-align: center;
      box-shadow: 0 8px 18px rgba(15, 23, 42, 0.08);
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-plan:hover {
      border-color: #2563eb;
      transform: translateY(-1px);
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-plan-title {
      font: 700 11px/1.2 Arial, sans-serif;
      margin-bottom: 6px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-plan-price {
      font: 800 14px/1 Arial, sans-serif;
      color: #0f766e;
      margin-bottom: 6px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-plan-help {
      font: 11px/1.35 Arial, sans-serif;
      color: #6b7280;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-loading,
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-empty {
      text-align: center;
      color: #475569;
      font: 600 13px/1.5 Arial, sans-serif;
      padding: 26px 12px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-buy-qr-stage {
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 250px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-card {
      width: min(248px, 100%);
      border-radius: 18px;
      overflow: hidden;
      background: #fff;
      box-shadow: 0 18px 40px rgba(15, 23, 42, 0.16);
      border: 1px solid rgba(226, 232, 240, 0.9);
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-head {
      position: relative;
      background: #e11d21;
      color: #fff;
      text-align: center;
      font: 800 22px/1 Arial, sans-serif;
      letter-spacing: 0.04em;
      padding: 12px 12px 14px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-head::after {
      content: '';
      position: absolute;
      right: 0;
      bottom: -1px;
      width: 34px;
      height: 34px;
      background: linear-gradient(135deg, transparent 50%, #fff 50%);
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-body {
      padding: 12px 12px 14px;
      background: #fff;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-merchant {
      font: 500 11px/1.3 Arial, sans-serif;
      color: #111827;
      margin-bottom: 6px;
      word-break: break-word;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-amount-row {
      display: flex;
      align-items: flex-end;
      gap: 8px;
      margin-bottom: 10px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-amount {
      font: 800 20px/1 Arial, sans-serif;
      color: #000;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-currency {
      font: 700 11px/1 Arial, sans-serif;
      color: #374151;
      text-transform: uppercase;
      margin-bottom: 2px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-expiry {
      font: 700 10px/1.3 Arial, sans-serif;
      color: #b45309;
      margin-bottom: 10px;
      text-align: left;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-divider {
      border-top: 2px dashed #d1d5db;
      margin: 0 -12px 12px;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-qr-wrap {
      position: relative;
      width: 156px;
      aspect-ratio: 1 / 1;
      margin: 0 auto;
      border-radius: 10px;
      overflow: hidden;
      background: #fff;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-qr-wrap img {
      width: 100%;
      height: 100%;
      display: block;
      object-fit: contain;
      background: #fff;
    }
    #${PROFILE_BUY_DIALOG_ID} .sora-khqr-badge {
      position: absolute;
      left: 50%;
      top: 50%;
      transform: translate(-50%, -50%);
      width: 36px;
      height: 36px;
      border-radius: 999px;
      background: #111827;
      color: #fff;
      display: flex;
      align-items: center;
      justify-content: center;
      font: 800 18px/1 Arial, sans-serif;
      border: 3px solid #fff;
      box-shadow: 0 6px 14px rgba(15, 23, 42, 0.22);
    }
  `;

  document.documentElement.appendChild(style);
}

function showHelperStatus(message) {
  if (!ENABLE_PAGE_STATUS) {
    document.getElementById(HELPER_STATUS_ID)?.remove();
    return;
  }

  injectHelperStyles();
  const meta = document.getElementById(HELPER_MENU_META_ID);
  if (meta) meta.textContent = message;
  let status = document.getElementById(HELPER_STATUS_ID);
  if (!status) {
    status = document.createElement('div');
    status.id = HELPER_STATUS_ID;
    status.dataset.soraHelper = 'true';
    document.documentElement.appendChild(status);
  }

  status.textContent = message;
  status.setAttribute('data-show', 'true');
  clearTimeout(helperTimer);
  helperTimer = setTimeout(() => {
    status.setAttribute('data-show', 'false');
  }, 2600);
}

async function copyTextToClipboard(text) {
  const value = String(text || '').trim();
  if (!value) return false;

  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return true;
  }

  const textarea = document.createElement('textarea');
  textarea.value = value;
  textarea.setAttribute('readonly', 'readonly');
  textarea.style.position = 'fixed';
  textarea.style.opacity = '0';
  document.body.appendChild(textarea);
  textarea.select();
  const ok = document.execCommand('copy');
  textarea.remove();
  return ok;
}

function getMenuCopyUrls() {
  const deleteUrls = buildDeleteScanResult().items
    .map(item => normalizeUrl(item?.url || ''))
    .filter(isSoraProjectUrl);
  if (deleteUrls.length) return Array.from(new Set(deleteUrls));

  const projectUrls = scanForProjectUrls()
    .map(item => normalizeUrl(item?.url || ''))
    .filter(isSoraProjectUrl);
  const published = projectUrls.filter(isSoraPublishedUrl);
  return Array.from(new Set(published.length ? published : projectUrls));
}

function getDraftUrlsForMenu() {
  return Array.from(new Set(
    scanForProjectUrls()
      .map(item => normalizeUrl(item?.url || ''))
      .filter(isSoraDraftUrl)
  ));
}

function getProfileAnchorNode() {
  const nodes = getClickableNodes(document).filter(node => {
    const rect = node.getBoundingClientRect?.();
    if (!rect) return false;
    if (rect.top < 0 || rect.top > Math.min(160, window.innerHeight * 0.22)) return false;
    if (rect.right < window.innerWidth * 0.6) return false;
    if (rect.width < 20 || rect.height < 20 || rect.width > 90 || rect.height > 90) return false;
    return true;
  });

  const ranked = nodes
    .map(node => {
      const rect = node.getBoundingClientRect();
      const label = getNodeLabel(node);
      const hint = getNodeHint(node);
      let score = 0;
      if (matchesAny(label, ['profile', 'account', 'user', 'avatar', 'settings'])) score += 100;
      if (matchesAny(hint, ['profile', 'account', 'user', 'avatar', 'settings'])) score += 80;
      if (node.querySelector?.('img')) score += 40;
      if (Math.abs(rect.width - rect.height) <= 10) score += 20;
      if (rect.right > window.innerWidth * 0.84) score += 20;
      score -= rect.top;
      return { node, score };
    })
    .sort((left, right) => right.score - left.score);

  return ranked[0]?.node || null;
}

function positionPageMenu(root) {
  const anchor = getProfileAnchorNode();
  if (!anchor) {
    root.style.top = '20px';
    root.style.right = '20px';
    return;
  }

  const rect = anchor.getBoundingClientRect();
  const top = Math.max(12, Math.min(window.innerHeight - 80, rect.bottom + 8));
  const right = Math.max(12, window.innerWidth - rect.right);
  root.style.top = `${top}px`;
  root.style.right = `${right}px`;
}

function setPageMenuOpen(open) {
  helperMenuOpen = Boolean(open);
  const root = document.getElementById(HELPER_MENU_ROOT_ID);
  if (!root) return;
  root.setAttribute('data-open', helperMenuOpen ? 'true' : 'false');
}

function setMenuButtonsDisabled(disabled) {
  const root = document.getElementById(HELPER_MENU_ROOT_ID);
  if (!root) return;
  root.querySelectorAll('.sora-menu-button').forEach(button => {
    button.disabled = Boolean(disabled);
  });
}

async function runPageMenuAction(button, workingLabel, task) {
  const originalLabel = button.textContent;
  button.disabled = true;
  button.textContent = workingLabel;
  setMenuButtonsDisabled(true);
  try {
    await task();
  } finally {
    setMenuButtonsDisabled(false);
    button.disabled = false;
    button.textContent = originalLabel;
  }
}

function removeLegacyHelperButtons() {
  document.getElementById(HELPER_BUTTON_ID)?.remove();
  document.getElementById(DELETE_HELPER_BUTTON_ID)?.remove();
}

function removeInjectedHelperUi() {
  removeLegacyHelperButtons();
  document.getElementById(HELPER_MENU_ROOT_ID)?.remove();
  document.getElementById(HELPER_STATUS_ID)?.remove();
  document.getElementById(DRAFTS_POST_ACTIONS_ID)?.remove();
  document.getElementById(DRAFTS_POST_BUTTON_ID)?.remove();
  document.getElementById(PROFILE_ACTIONS_ID)?.remove();
  document.getElementById(PROJECT_DOWNLOAD_ACTIONS_ID)?.remove();
  document.querySelectorAll(`.${PROJECT_PAGE_DOWNLOAD_CLASS}`).forEach(node => node.remove());
  document.querySelectorAll(`.${PROJECT_PAGE_HOST_CLASS}`).forEach(node => node.classList.remove(PROJECT_PAGE_HOST_CLASS));
  document.getElementById(EXPLORE_ACTIONS_ID)?.remove();
  document.querySelectorAll(`.${EXPLORE_CARD_DOWNLOAD_CLASS}`).forEach(node => node.remove());
  document.querySelectorAll(`.${EXPLORE_CARD_HOST_CLASS}`).forEach(node => node.classList.remove(EXPLORE_CARD_HOST_CLASS));
  document.getElementById(HELPER_STYLE_ID)?.remove();
}

function setDraftsPageButtonBusy(button, busy, label = '') {
  if (!button) return;
  button.disabled = Boolean(busy);
  button.setAttribute('data-busy', busy ? 'true' : 'false');
  const labelNode = button.querySelector('.sora-label');
  if (labelNode && label) labelNode.textContent = label;
}

async function getPageLicenseStatus() {
  if (!globalThis.SoraLicense) {
    return {
      valid: false,
      reason: 'License module is unavailable.'
    };
  }
  return await SoraLicense.getStoredLicenseStatus(chrome.storage.local);
}

async function getPageIntegrityStatus() {
  try {
    const response = await chrome.runtime.sendMessage({ action: 'get_integrity_status' });
    const status = response?.status || null;
    if (status?.valid) return status;
    return {
      valid: false,
      message: status?.message || INTEGRITY_REQUIRED_MESSAGE
    };
  } catch (error) {
    return {
      valid: false,
      message: error?.message || 'Could not check extension package integrity.'
    };
  }
}

async function getPageProtectionStatus(options = {}) {
  const force = Boolean(options?.force);
  if (!force && pageProtectionCache && (Date.now() - pageProtectionCacheAt) < PAGE_PROTECTION_CACHE_MAX_AGE_MS) {
    return pageProtectionCache;
  }

  const integrity = await getPageIntegrityStatus();
  if (!integrity.valid) {
    if (pageProtectionExpiryTimer) {
      window.clearTimeout(pageProtectionExpiryTimer);
      pageProtectionExpiryTimer = null;
    }
    pageProtectionCache = {
      valid: false,
      type: 'integrity',
      reason: integrity.message || INTEGRITY_REQUIRED_MESSAGE,
      integrity
    };
    pageProtectionCacheAt = Date.now();
    return pageProtectionCache;
  }

  const license = await getPageLicenseStatus();
  if (!license.valid) {
    if (pageProtectionExpiryTimer) {
      window.clearTimeout(pageProtectionExpiryTimer);
      pageProtectionExpiryTimer = null;
    }
    pageProtectionCache = {
      valid: false,
      type: 'license',
      reason: license.reason || 'License required. Open the extension popup and activate a valid key first.',
      license
    };
    pageProtectionCacheAt = Date.now();
    return pageProtectionCache;
  }

  pageProtectionCache = {
    valid: true,
    type: 'ok',
    integrity,
    license
  };
  pageProtectionCacheAt = Date.now();
  schedulePageProtectionExpiryRefresh(license?.expiresAt || '');
  return pageProtectionCache;
}

async function ensureProtectedPageAction() {
  const cachedStatus = await getPageProtectionStatus();
  if (cachedStatus.valid) return cachedStatus;

  const refreshedStatus = await getPageProtectionStatus({ force: true });
  if (refreshedStatus.valid) return refreshedStatus;

  const message = refreshedStatus.reason || cachedStatus.reason || 'This action is locked.';
  showHelperStatus(message);
  throw new Error(message);
}

async function startDraftsPagePostQueue(limit, label, button) {
  setDraftsPageButtonBusy(button, true, 'Starting...');

  const originalLabel = label;
  const draftUrls = Array.from(new Set(
    scanForProjectUrls()
      .map(item => normalizeUrl(item?.url || ''))
      .filter(isSoraDraftUrl)
  ));

  if (!draftUrls.length) {
    showHelperStatus('No draft URLs found on this drafts page.');
    return;
  }

  try {
    await ensureProtectedPageAction();
    showHelperStatus(`Opening ${limit ? Math.min(limit, draftUrls.length) : draftUrls.length} draft URL(s) and posting them...`);
    const response = await chrome.runtime.sendMessage({
      action: 'start_run_queue',
      urls: draftUrls,
      limit: limit ?? null,
      limitLabel: label,
      skipFailed: true,
      forceParallelTabs: true
    });
    showHelperStatus(response?.message || 'Post queue started.');
  } catch (error) {
    showHelperStatus(error?.message || `${label} failed.`);
  } finally {
    setDraftsPageButtonBusy(button, false, originalLabel);
  }
}

function ensureDraftsPagePostButton() {
  const existing = document.getElementById(DRAFTS_POST_ACTIONS_ID);
  if (!isSoraDraftsPage()) {
    existing?.remove();
    document.getElementById(DRAFTS_POST_TRIGGER_ID)?.remove();
    document.getElementById(DRAFTS_POST_PANEL_ID)?.remove();
    document.getElementById(DRAFTS_POST_BUTTON_ID)?.remove();
    return;
  }

  injectHelperStyles();

  if (existing) return;

  const root = document.createElement('div');
  root.id = DRAFTS_POST_ACTIONS_ID;
  root.dataset.soraHelper = 'true';
  root.dataset.open = 'false';

  const trigger = document.createElement('button');
  trigger.id = DRAFTS_POST_TRIGGER_ID;
  trigger.type = 'button';
  trigger.dataset.soraHelper = 'true';
  trigger.setAttribute('aria-expanded', 'false');
  trigger.innerHTML = '<span class="sora-badge">P</span><span class="sora-label">Post Tools</span>';

  const buttonAll = document.createElement('button');
  buttonAll.id = DRAFTS_POST_BUTTON_ID;
  buttonAll.type = 'button';
  buttonAll.dataset.soraHelper = 'true';
  buttonAll.innerHTML = '<span class="sora-badge">P</span><span class="sora-label">Post All Found</span>';
  buttonAll.addEventListener('click', () => startDraftsPagePostQueue(null, 'All', buttonAll));

  const buttonFive = document.createElement('button');
  buttonFive.id = DRAFTS_POST_FIVE_BUTTON_ID;
  buttonFive.type = 'button';
  buttonFive.dataset.soraHelper = 'true';
  buttonFive.innerHTML = '<span class="sora-badge">5</span><span class="sora-label">Post 5 Found</span>';
  buttonFive.addEventListener('click', () => startDraftsPagePostQueue(5, '5', buttonFive));

  const buttonTen = document.createElement('button');
  buttonTen.id = DRAFTS_POST_TEN_BUTTON_ID;
  buttonTen.type = 'button';
  buttonTen.dataset.soraHelper = 'true';
  buttonTen.innerHTML = '<span class="sora-badge">10</span><span class="sora-label">Post 10 Found</span>';
  buttonTen.addEventListener('click', () => startDraftsPagePostQueue(10, '10', buttonTen));

  const panel = document.createElement('div');
  panel.id = DRAFTS_POST_PANEL_ID;
  panel.dataset.soraHelper = 'true';
  panel.append(buttonFive, buttonTen, buttonAll);

  const setOpen = open => {
    root.dataset.open = open ? 'true' : 'false';
    trigger.dataset.open = open ? 'true' : 'false';
    trigger.setAttribute('aria-expanded', open ? 'true' : 'false');
  };

  trigger.addEventListener('mouseenter', () => setOpen(true));
  trigger.addEventListener('click', event => {
    event.preventDefault();
    event.stopPropagation();
    setOpen(root.dataset.open !== 'true');
  });
  root.addEventListener('mouseenter', () => setOpen(true));
  root.addEventListener('focusin', () => setOpen(true));
  document.addEventListener('click', event => {
    if (!root.contains(event.target)) {
      setOpen(false);
    }
  }, true);

  root.append(trigger, panel);
  document.documentElement.appendChild(root);
}

function setProfileButtonBusy(button, busy, label) {
  if (!button) return;
  button.disabled = Boolean(busy);
  button.setAttribute('data-busy', busy ? 'true' : 'false');
  if (label) button.textContent = label;
}

function createProfileActionButton(label, tone, onClick) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'sora-profile-button';
  button.dataset.tone = tone;
  button.dataset.soraHelper = 'true';
  button.dataset.baseLabel = label;
  button.textContent = label;
  button.addEventListener('click', onClick);
  return button;
}

function getLicenseDaysLeftLabel(status) {
  const expiresAtMs = Date.parse(String(status?.expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return '';
  const diffMs = expiresAtMs - Date.now();
  if (diffMs <= 0) return 'Expired';
  const minutesLeft = Math.max(1, Math.ceil(diffMs / (60 * 1000)));
  if (minutesLeft < 60) return `${minutesLeft}m left`;
  const hoursLeft = Math.max(1, Math.ceil(diffMs / (60 * 60 * 1000)));
  if (hoursLeft < 24) return `${hoursLeft}h left`;
  const daysLeft = Math.max(1, Math.ceil(diffMs / (24 * 60 * 60 * 1000)));
  return `${daysLeft}d left`;
}

function escapeProfileBuyHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function getProfileBuyAmountDisplay(plan) {
  const rawLabel = String(
    plan?.amountKhrLabel ||
    plan?.amountUsdLabel ||
    ''
  ).trim();

  if (!rawLabel) {
    return { amount: '0', currency: 'USD', combined: '0 USD' };
  }

  if (/khr/i.test(rawLabel)) {
    const amount = rawLabel.replace(/\s*khr\s*/i, '').trim();
    return { amount, currency: 'KHR', combined: `${amount} KHR` };
  }

  if (/usd/i.test(rawLabel)) {
    const amount = rawLabel.replace(/\s*usd\s*/i, '').trim();
    return { amount, currency: 'USD', combined: `${amount} USD` };
  }

  if (rawLabel.includes('$')) {
    const amount = rawLabel.replace('$', '').trim();
    return { amount, currency: 'USD', combined: `${amount} USD` };
  }

  return { amount: rawLabel, currency: 'USD', combined: `${rawLabel} USD` };
}

function getProfileBuyQrBadgeSymbol(currency) {
  return String(currency || '').trim().toUpperCase() === 'KHR' ? '៛' : '$';
}

function formatProfileBuyExpiryCountdown(expiresAt) {
  const expiresAtMs = Date.parse(String(expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return '';
  const diffMs = expiresAtMs - Date.now();
  if (diffMs <= 0) return '0 វិនាទី';
  const totalSeconds = Math.max(1, Math.ceil(diffMs / 1000));
  if (totalSeconds < 60) return `${totalSeconds} វិនាទី`;
  const totalMinutes = Math.max(1, Math.ceil(totalSeconds / 60));
  return `${totalMinutes} នាទី`;
}

function stopProfileBuyPolling() {
  if (!profileBuyPollTimer) return;
  window.clearInterval(profileBuyPollTimer);
  profileBuyPollTimer = null;
}

function stopProfileBuyCountdown() {
  if (!profileBuyCountdownTimer) return;
  window.clearInterval(profileBuyCountdownTimer);
  profileBuyCountdownTimer = null;
}

function closeProfileBuyModal() {
  stopProfileBuyPolling();
  stopProfileBuyCountdown();
  document.getElementById(PROFILE_BUY_MODAL_ID)?.remove();
}

async function profileBuyApi(path, body, method = 'POST') {
  return await new Promise((resolve, reject) => {
    try {
      chrome.runtime.sendMessage(
        {
          action: 'license_server_request',
          path,
          method,
          body: body || {}
        },
        (response) => {
          const runtimeError = chrome.runtime?.lastError;
          if (runtimeError) {
            reject(new Error(runtimeError.message || 'Could not reach license server.'));
            return;
          }
          if (!response?.ok) {
            reject(new Error(response?.message || 'Could not reach license server.'));
            return;
          }
          resolve(response.payload || {});
        }
      );
    } catch (error) {
      reject(error);
    }
  });
}

function getProfileBuyPlans() {
  return Array.isArray(profileBuyConfig?.plans) ? profileBuyConfig.plans : [];
}

function getProfileBuySelectedPlan() {
  const plans = getProfileBuyPlans();
  return plans.find(plan => String(plan.id || '') === profileBuySelectedPlanId) || plans[0] || null;
}

async function loadProfileBuyConfig() {
  const data = await profileBuyApi('/api/buy/config', {}, 'GET');
  profileBuyConfig = data?.config || null;
  if (!profileBuySelectedPlanId) {
    profileBuySelectedPlanId = String(getProfileBuyPlans()[0]?.id || '');
  }
  return profileBuyConfig;
}

function ensureProfileBuyModal() {
  let modal = document.getElementById(PROFILE_BUY_MODAL_ID);
  if (modal) return modal;

  modal = document.createElement('div');
  modal.id = PROFILE_BUY_MODAL_ID;
  modal.innerHTML = `
    <div id="${PROFILE_BUY_DIALOG_ID}" role="dialog" aria-modal="true" aria-label="Buy License With KHQR">
      <div class="sora-buy-head">
        <div class="sora-buy-title">Buy License With KHQR</div>
        <button class="sora-buy-close" type="button" aria-label="Close buy popup">×</button>
      </div>
      <div id="${PROFILE_BUY_CONTENT_ID}"></div>
    </div>
  `;
  modal.addEventListener('click', event => {
    if (event.target === modal) {
      closeProfileBuyModal();
    }
  });
  modal.querySelector('.sora-buy-close')?.addEventListener('click', () => {
    closeProfileBuyModal();
  });
  document.documentElement.appendChild(modal);

  if (!profileBuyModalEscapeHooked) {
    profileBuyModalEscapeHooked = true;
    window.addEventListener('keydown', event => {
      if (event.key === 'Escape') {
        closeProfileBuyModal();
      }
    });
  }

  return modal;
}

function renderProfileBuyPlanView() {
  const modal = ensureProfileBuyModal();
  const content = modal.querySelector(`#${PROFILE_BUY_CONTENT_ID}`);
  if (!content) return;

  const plans = getProfileBuyPlans();
  if (!plans.length) {
    content.innerHTML = '<div class="sora-buy-empty">Buy plans are not configured yet.</div>';
    return;
  }

  content.innerHTML = `
    <div class="sora-buy-plan-grid">
      ${plans.map(plan => {
        const price = getProfileBuyAmountDisplay(plan).combined;
        return `
          <button class="sora-buy-plan" type="button" data-plan-id="${escapeProfileBuyHtml(String(plan.id || ''))}">
            <div class="sora-buy-plan-title">${escapeProfileBuyHtml(String(plan.label || ''))}</div>
            <div class="sora-buy-plan-price">${escapeProfileBuyHtml(price)}</div>
            <div class="sora-buy-plan-help">${escapeProfileBuyHtml(String(plan.description || ''))}</div>
          </button>
        `;
      }).join('')}
    </div>
  `;

  content.querySelectorAll('.sora-buy-plan[data-plan-id]').forEach(button => {
    button.addEventListener('click', () => {
      const planId = String(button.getAttribute('data-plan-id') || '').trim();
      handleProfileBuyPlanSelection(planId).catch(error => {
        setProfileActionsStatus(error?.message || 'Could not prepare KHQR.');
      });
    });
  });
}

function renderProfileBuyQrView(order, preparingLabel = '') {
  const modal = ensureProfileBuyModal();
  const content = modal.querySelector(`#${PROFILE_BUY_CONTENT_ID}`);
  if (!content) return;

  const plan = getProfileBuySelectedPlan();
  const amount = getProfileBuyAmountDisplay(plan);
  const badge = getProfileBuyQrBadgeSymbol(amount.currency);
  const expiryLabel = order?.orderExpiresAt
    ? `ផុតកំណត់ក្នុងរយះពេល ${formatProfileBuyExpiryCountdown(order.orderExpiresAt)}`
    : '';
  const merchantName = String(
    profileBuyConfig?.merchantName ||
    profileBuyConfig?.bakongAccountId ||
    'Bakong Payment'
  ).trim();

  if (profileBuyPreparing) {
    content.innerHTML = `
      <div class="sora-buy-qr-stage">
        <div class="sora-khqr-card">
          <div class="sora-khqr-head">KHQR</div>
          <div class="sora-khqr-body">
            <div class="sora-khqr-merchant">${escapeProfileBuyHtml(merchantName)}</div>
            <div class="sora-khqr-amount-row">
              <div class="sora-khqr-amount">${escapeProfileBuyHtml(amount.amount)}</div>
              <div class="sora-khqr-currency">${escapeProfileBuyHtml(amount.currency)}</div>
            </div>
            <div class="sora-khqr-expiry" id="soraProfileBuyExpiryLabel">${escapeProfileBuyHtml(expiryLabel)}</div>
            <div class="sora-khqr-divider"></div>
            <div class="sora-buy-loading">Preparing fresh KHQR for ${escapeProfileBuyHtml(preparingLabel || 'selected plan')}...</div>
          </div>
        </div>
      </div>
    `;
    return;
  }

  const payload = String(order?.khqrString || '').trim();
  if (!payload) {
    content.innerHTML = '<div class="sora-buy-empty">Could not prepare KHQR for this plan.</div>';
    return;
  }

  const imageUrl = `https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=${encodeURIComponent(payload)}`;
  content.innerHTML = `
    <div class="sora-buy-qr-stage">
      <div class="sora-khqr-card">
        <div class="sora-khqr-head">KHQR</div>
        <div class="sora-khqr-body">
          <div class="sora-khqr-merchant">${escapeProfileBuyHtml(merchantName)}</div>
          <div class="sora-khqr-amount-row">
            <div class="sora-khqr-amount">${escapeProfileBuyHtml(amount.amount)}</div>
            <div class="sora-khqr-currency">${escapeProfileBuyHtml(amount.currency)}</div>
          </div>
          <div class="sora-khqr-expiry" id="soraProfileBuyExpiryLabel">${escapeProfileBuyHtml(expiryLabel)}</div>
          <div class="sora-khqr-divider"></div>
          <div class="sora-khqr-qr-wrap">
            <img src="${imageUrl}" alt="KHQR payment QR" />
            <div class="sora-khqr-badge">${escapeProfileBuyHtml(badge)}</div>
          </div>
        </div>
      </div>
    </div>
  `;
}

function refreshProfileBuyExpiryLabel() {
  const node = document.getElementById('soraProfileBuyExpiryLabel');
  if (!node) return;
  const expiresAt = String(profileBuyOrder?.orderExpiresAt || '').trim();
  const expiresAtMs = Date.parse(expiresAt);
  if (!Number.isFinite(expiresAtMs)) {
    node.textContent = '';
    return;
  }
  if (expiresAtMs <= Date.now()) {
    node.textContent = 'ផុតកំណត់ក្នុងរយះពេល 0 វិនាទី';
    expireProfileBuyQrLocally().catch(() => {});
    return;
  }
  node.textContent = `ផុតកំណត់ក្នុងរយះពេល ${formatProfileBuyExpiryCountdown(expiresAt)}`;
}

function startProfileBuyCountdown(expiresAt) {
  stopProfileBuyCountdown();
  const expiresAtMs = Date.parse(String(expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return;
  refreshProfileBuyExpiryLabel();
  profileBuyCountdownTimer = window.setInterval(() => {
    refreshProfileBuyExpiryLabel();
  }, 1000);
}

async function expireProfileBuyQrLocally() {
  stopProfileBuyPolling();
  stopProfileBuyCountdown();
  profileBuyOrder = null;
  renderProfileBuyPlanView();
  setProfileActionsStatus('QR ផុតកំណត់ហើយ។ សូមរើស plan ម្តងទៀត។');
}

function startProfileBuyPolling(orderId) {
  stopProfileBuyPolling();
  if (!orderId) return;
  profileBuyPollTimer = window.setInterval(async () => {
    try {
      const data = await profileBuyApi(`/api/buy/order-status?orderId=${encodeURIComponent(orderId)}`, {}, 'GET');
      const order = data?.order || null;
      if (!order) return;
      profileBuyOrder = order;
      if (String(order.status || '').trim().toLowerCase() === 'expired') {
        await expireProfileBuyQrLocally();
        return;
      }
      if (String(order.status || '').trim().toLowerCase() === 'approved') {
        stopProfileBuyPolling();
        stopProfileBuyCountdown();
        closeProfileBuyModal();
        clearPageProtectionCache();
        await updateProfileLicenseLabel(document.getElementById(PROFILE_ACTIONS_ID));
        setProfileActionsStatus('Payment approved. License restored for this computer.');
        showHelperStatus('Payment approved. License restored.');
      }
    } catch {}
  }, 15000);
}

async function handleProfileBuyPlanSelection(planId) {
  profileBuySelectedPlanId = String(planId || '').trim();
  const plan = getProfileBuySelectedPlan();
  if (!plan?.id) {
    throw new Error('No buy plan is configured yet.');
  }

  const deviceId = await globalThis.SoraLicense?.getDeviceId?.();
  if (!deviceId) {
    throw new Error('Device ID is not ready yet.');
  }

  stopProfileBuyCountdown();
  profileBuyPreparing = true;
  profileBuyOrder = null;
  renderProfileBuyQrView(null, String(plan.label || 'license'));
  setProfileActionsStatus(`Preparing ${plan.label || 'license'} KHQR...`);

  try {
    const data = await profileBuyApi('/api/buy/request', {
      deviceId,
      planId: plan.id
    });
    profileBuyOrder = data?.order || null;
    profileBuyConfig = data?.config || profileBuyConfig;
    profileBuyPreparing = false;
    renderProfileBuyQrView(profileBuyOrder);
    startProfileBuyCountdown(profileBuyOrder?.orderExpiresAt || '');
    if (profileBuyOrder?.orderId) {
      startProfileBuyPolling(profileBuyOrder.orderId);
    }
    setProfileActionsStatus(`KHQR ready for ${plan.label || 'selected plan'}.`);
  } catch (error) {
    profileBuyPreparing = false;
    renderProfileBuyPlanView();
    throw error;
  }
}

async function openProfileBuyLicensePage() {
  await loadProfileBuyConfig();
  stopProfileBuyPolling();
  stopProfileBuyCountdown();
  profileBuyOrder = null;
  profileBuyPreparing = false;
  renderProfileBuyPlanView();
  return 'modal-opened';
}

async function updateProfileLicenseLabel(root) {
  const copyButton = root?.querySelector?.('.sora-profile-button[data-tone="copy"]');
  if (!copyButton) return;

  const baseLabel = copyButton.dataset.baseLabel || 'Copy All Video URLs';
  const buyLabel = 'Buy License / KHQR';
  try {
    const protection = await getPageProtectionStatus();
    if (protection?.type === 'integrity') {
      copyButton.dataset.actionMode = 'blocked';
      copyButton.textContent = `${baseLabel} (Modified)`;
      return;
    }
    if (protection?.license?.valid) {
      copyButton.dataset.actionMode = 'copy';
      const suffix = getLicenseDaysLeftLabel(protection.license);
      copyButton.textContent = protection?.license?.trialActive
        ? (protection?.license?.trialForever || protection?.license?.trial?.forever
          ? `${baseLabel} (Free)`
          : (suffix ? `${baseLabel} (Trial ${suffix})` : `${baseLabel} (Trial)`))
        : (suffix ? `${baseLabel} (${suffix})` : baseLabel);
      return;
    }
    if (protection?.type === 'license') {
      copyButton.dataset.actionMode = 'buy';
      copyButton.textContent = buyLabel;
      return;
    }
  } catch {}

  copyButton.dataset.actionMode = 'blocked';
  copyButton.textContent = `${baseLabel} (Locked)`;
}

function setProfileActionsStatus(message) {
  const node = document.getElementById(PROFILE_ACTIONS_STATUS_ID);
  if (!node) return;
  node.textContent = String(message || '').trim() || 'Ready.';
}

async function collectProfileDeleteActionUrls() {
  let scanResult = null;
  try {
    scanResult = await scanProfileVideos();
  } catch {}

  const scannedUrls = Array.from(new Set(
    (scanResult?.items || [])
      .map(item => normalizeUrl(item?.url || ''))
      .filter(isSoraPublishedUrl)
  ));

  const globalUrls = Array.from(new Set(getGlobalProfileProjectUrls().filter(isSoraPublishedUrl)));
  const fallbackUrls = Array.from(new Set(
    scanForProjectUrls()
      .map(item => normalizeUrl(item?.url || ''))
      .filter(isSoraPublishedUrl)
  ));

  const mergedUrls = Array.from(new Set([
    ...scannedUrls,
    ...globalUrls,
    ...fallbackUrls
  ]));

  const sources = [];
  if (scannedUrls.length) sources.push(`visible:${scannedUrls.length}`);
  if (globalUrls.length) sources.push(`profile:${globalUrls.length}`);
  if (fallbackUrls.length) sources.push(`scan:${fallbackUrls.length}`);

  return {
    urls: mergedUrls,
    source: `delete:${sources.join(' + ') || 'none'}`,
    scanResult
  };
}

async function collectProfileDownloadActionUrls() {
  let scanResult = null;
  try {
    scanResult = await scanProfileVideos();
  } catch {}

  const scannedUrls = Array.from(new Set(
    (scanResult?.items || [])
      .map(item => normalizeUrl(item?.url || ''))
      .filter(isSoraPublishedUrl)
  ));

  const globalUrls = Array.from(new Set(getGlobalProfileProjectUrls().filter(isSoraPublishedUrl)));
  const fallbackUrls = Array.from(new Set(
    scanForProjectUrls()
      .map(item => normalizeUrl(item?.url || ''))
      .filter(isSoraPublishedUrl)
  ));

  const mergedUrls = Array.from(new Set([
    ...scannedUrls,
    ...globalUrls,
    ...fallbackUrls
  ]));

  if (mergedUrls.length) {
    savePublishedVideoUrls(mergedUrls).catch(() => {});
  }

  const sources = [];
  if (scannedUrls.length) sources.push(`visible:${scannedUrls.length}`);
  if (globalUrls.length) sources.push(`profile:${globalUrls.length}`);
  if (fallbackUrls.length) sources.push(`scan:${fallbackUrls.length}`);

  return {
    urls: mergedUrls,
    source: `download:${sources.join(' + ') || 'none'}`,
    scanResult
  };
}

async function collectAllProfileDeleteActionUrls(maxPasses = PROFILE_ACTION_SCAN_PASSES) {
  const startScrollY = window.scrollY || 0;
  const mergedUrls = new Set();
  let lastResult = null;

  for (let pass = 0; pass < Math.max(1, maxPasses); pass += 1) {
    lastResult = await collectProfileDeleteActionUrls();
    for (const url of Array.isArray(lastResult?.urls) ? lastResult.urls : []) {
      const normalized = normalizeUrl(url);
      if (isSoraPublishedUrl(normalized)) mergedUrls.add(normalized);
    }

    if (pass >= Math.max(1, maxPasses) - 1) break;
    const loadedMore = await scrollForMoreCards();
    if (!loadedMore) break;
    await sleep(PROFILE_ACTION_SCAN_SETTLE_MS);
  }

  window.scrollTo({ top: startScrollY, behavior: 'auto' });
  await sleep(120);

  return {
    urls: Array.from(mergedUrls),
    source: mergedUrls.size
      ? `delete-profile-scan:${mergedUrls.size}`
      : (lastResult?.source || 'none'),
    scanResult: lastResult?.scanResult || null
  };
}

async function collectAllProfileDownloadActionUrls(maxPasses = PROFILE_ACTION_SCAN_PASSES) {
  const startScrollY = window.scrollY || 0;
  const mergedUrls = new Set();
  let lastResult = null;

  for (let pass = 0; pass < Math.max(1, maxPasses); pass += 1) {
    lastResult = await collectProfileDownloadActionUrls();
    for (const url of Array.isArray(lastResult?.urls) ? lastResult.urls : []) {
      const normalized = normalizeUrl(url);
      if (isSoraPublishedUrl(normalized)) mergedUrls.add(normalized);
    }

    if (pass >= Math.max(1, maxPasses) - 1) break;
    const loadedMore = await scrollForMoreCards();
    if (!loadedMore) break;
    await sleep(PROFILE_ACTION_SCAN_SETTLE_MS);
  }

  window.scrollTo({ top: startScrollY, behavior: 'auto' });
  await sleep(120);

  const urls = Array.from(mergedUrls);
  if (urls.length) {
    savePublishedVideoUrls(urls).catch(() => {});
  }

  return {
    urls,
    source: urls.length
      ? `download-profile-scan:${urls.length}`
      : (lastResult?.source || 'none'),
    scanResult: lastResult?.scanResult || null
  };
}

async function collectAllExploreDownloadActionUrls(maxPasses = PROFILE_ACTION_SCAN_PASSES) {
  return await collectAllProfileDownloadActionUrls(maxPasses);
}

function ensureExplorePageActionButton() {
  document.getElementById(EXPLORE_ACTIONS_ID)?.remove();

  if (!isSoraExplorePage() && !isSoraPublicProfilePage()) {
    document.querySelectorAll(`.${EXPLORE_CARD_DOWNLOAD_CLASS}`).forEach(node => node.remove());
    document.querySelectorAll(`.${EXPLORE_CARD_HOST_CLASS}`).forEach(node => node.classList.remove(EXPLORE_CARD_HOST_CLASS));
    return;
  }

  injectHelperStyles();

  let entries = getProfileCardEntries().filter(entry => isSoraPublishedUrl(entry?.url));
  const anchorEntries = getPublishedAnchorCardEntries();
  if (anchorEntries.length >= entries.length) {
    entries = anchorEntries;
  }
  const activeKeys = new Set(entries.map(entry => entry.key));

  document.querySelectorAll(`.${EXPLORE_CARD_DOWNLOAD_CLASS}`).forEach(button => {
    const key = String(button.dataset.urlKey || '').trim();
    if (!activeKeys.has(key)) {
      button.remove();
    }
  });

  entries.forEach(entry => {
    const card = entry?.card;
    if (!card || !entry?.url) return;

    card.classList.add(EXPLORE_CARD_HOST_CLASS);

    let button = card.querySelector(`.${EXPLORE_CARD_DOWNLOAD_CLASS}`);
    if (!button) {
      button = document.createElement('button');
      button.type = 'button';
      button.className = EXPLORE_CARD_DOWNLOAD_CLASS;
      button.dataset.soraHelper = 'true';
      button.dataset.baseLabel = 'Download';
      button.textContent = 'Download';
      button.addEventListener('pointerdown', event => {
        event.preventDefault();
        event.stopPropagation();
      });
      button.addEventListener('click', async event => {
        event.preventDefault();
        event.stopPropagation();
        const targetUrl = normalizeUrl(button.dataset.url || '');
        if (!targetUrl) return;

        try {
          setProfileButtonBusy(button, true, 'Checking...');
          let protection = await getPageProtectionStatus();
          if (!protection?.valid) {
            protection = await getPageProtectionStatus({ force: true });
          }
          if (!protection?.valid) {
            if (protection?.type === 'license') {
              setProfileButtonBusy(button, true, 'Opening...');
              await openProfileBuyLicensePage();
              showHelperStatus('Opened Buy License / KHQR.');
              return;
            }
            throw new Error(protection?.reason || 'This action is locked.');
          }

          setProfileButtonBusy(button, true, 'Starting...');
          const response = await chrome.runtime.sendMessage({
            action: 'download_sora_urls',
            urls: [targetUrl],
            forceRedownload: true
          });
          if (!response?.ok) {
            throw new Error(response?.message || 'Could not start downloading this explore video.');
          }
          showHelperStatus(response?.message || 'Started download.');
        } catch (error) {
          showHelperStatus(error?.message || 'Could not start downloading this explore video.');
        } finally {
          setProfileButtonBusy(button, false, 'Download');
        }
      });
      card.appendChild(button);
    }

    button.dataset.urlKey = entry.key;
    button.dataset.url = entry.url;
    button.title = entry.title ? `Download ${entry.title}` : 'Download this video';
    button.dataset.layout = (window.innerWidth <= 1100 || window.innerHeight > window.innerWidth)
      ? 'compact'
      : 'default';
    const anchor = entry.visual || card;
    const cardRect = card.getBoundingClientRect();
    const anchorRect = anchor.getBoundingClientRect();
    button.style.top = `${Math.max(8, Math.round(anchorRect.top - cardRect.top + 12))}px`;
    button.style.left = `${Math.max(8, Math.round(anchorRect.left - cardRect.left + 12))}px`;
  });
}

function ensureProfilePageActionButtons() {
  const existing = document.getElementById(PROFILE_ACTIONS_ID);
  if (!isSoraProfilePage()) {
    existing?.remove();
    return;
  }

  injectHelperStyles();

  if (existing) {
    updateProfileLicenseLabel(existing).catch(() => {});
    return;
  }

  const root = document.createElement('div');
  root.id = PROFILE_ACTIONS_ID;
  root.dataset.soraHelper = 'true';
  root.dataset.open = 'false';
  const status = document.createElement('div');
  status.id = PROFILE_ACTIONS_STATUS_ID;
  status.dataset.soraHelper = 'true';
  status.textContent = 'Ready on profile page.';

  const withDeleteUrls = async task => {
    const result = await collectAllProfileDeleteActionUrls();
    const urls = result.urls || [];
    if (!urls.length) {
      throw new Error('No Sora video URLs found on this profile page yet.');
    }

    setProfileActionsStatus(`Found ${urls.length} URL(s) from ${result.source}.`);
    return task(urls, result);
  };

  const withDownloadUrlsOrSaved = async task => {
    const result = await collectAllProfileDownloadActionUrls();
    const urls = result.urls || [];
    if (urls.length) {
      setProfileActionsStatus(`Found ${urls.length} URL(s) from ${result.source}.`);
      return task(urls, result);
    }

    const savedUrls = await getSavedPublishedVideoUrls();
    if (!savedUrls.length) {
      throw new Error('No Sora video URLs found on this profile page yet.');
    }

    setProfileActionsStatus(`Using ${savedUrls.length} cached URL(s) from earlier profile scans.`);
    return task(savedUrls, {
      ...result,
      urls: savedUrls,
      source: `cache:${savedUrls.length}`
    });
  };

  const copyButton = createProfileActionButton('Copy All Video URLs', 'copy', async () => {
    const originalLabel = 'Copy All Video URLs';
    const buyLabel = 'Buy License / KHQR';
    try {
      setProfileButtonBusy(copyButton, true, 'Checking...');
      let protection = await getPageProtectionStatus();
      if (!protection?.valid) {
        protection = await getPageProtectionStatus({ force: true });
      }
      if (!protection?.valid) {
        if (protection?.type === 'license') {
          setProfileButtonBusy(copyButton, true, 'Opening...');
          setProfileActionsStatus('Opening Buy License / KHQR...');
          await openProfileBuyLicensePage();
          showHelperStatus('Opened Buy License / KHQR.');
          return;
        }
        const message = protection?.reason || 'This action is locked.';
        showHelperStatus(message);
        throw new Error(message);
      }
      setProfileButtonBusy(copyButton, true, 'Copying...');
      setProfileActionsStatus('Scanning visible videos...');
      const copied = await withDownloadUrlsOrSaved(async urls => {
        await copyTextToClipboard(urls.join('\n'));
        return urls.length;
      });
      setProfileActionsStatus(`Copied ${copied} video URL(s).`);
      showHelperStatus(`Copied ${copied} video URL(s).`);
    } catch (error) {
      setProfileActionsStatus(error?.message || 'Could not copy the visible video URLs.');
      showHelperStatus(error?.message || 'Could not copy the visible video URLs.');
    } finally {
      const fallbackLabel = copyButton.dataset.actionMode === 'buy' ? buyLabel : originalLabel;
      setProfileButtonBusy(copyButton, false, fallbackLabel);
      updateProfileLicenseLabel(root).catch(() => {});
    }
  });

  const runProfileDeleteAction = async (button, label, limit) => {
    const originalLabel = label;
    try {
      await ensureProtectedPageAction();
      setProfileButtonBusy(button, true, 'Deleting...');
      setProfileActionsStatus('Scanning profile videos for delete...');
      const response = await withDeleteUrls(async urls => {
        return await chrome.runtime.sendMessage({
          action: 'start_delete_queue',
          urls,
          limit: limit ?? null,
          limitLabel: limit ? String(limit) : 'All',
          skipFailed: true,
          fastMode: false,
          forceParallelTabs: urls.length > 1
        });
      });
      setProfileActionsStatus(response?.message || `Started deleting ${label.toLowerCase()}.`);
      showHelperStatus(response?.message || `Started deleting ${label.toLowerCase()}.`);
    } catch (error) {
      setProfileActionsStatus(error?.message || 'Could not start deleting the visible videos.');
      showHelperStatus(error?.message || 'Could not start deleting the visible videos.');
    } finally {
      setProfileButtonBusy(button, false, originalLabel);
    }
  };

  const deleteFiveButton = createProfileActionButton('Delete 5', 'delete', async () => {
    await runProfileDeleteAction(deleteFiveButton, 'Delete 5', 5);
  });

  root.append(copyButton, deleteFiveButton, status);
  document.documentElement.appendChild(root);
  updateProfileLicenseLabel(root).catch(() => {});
}

function ensureProjectPageDownloadButton() {
  const existing = document.getElementById(PROJECT_DOWNLOAD_ACTIONS_ID);
  if (!isSoraPublishedProjectPage()) {
    existing?.remove();
    document.querySelectorAll(`.${PROJECT_PAGE_DOWNLOAD_CLASS}`).forEach(node => node.remove());
    document.querySelectorAll(`.${PROJECT_PAGE_HOST_CLASS}`).forEach(node => node.classList.remove(PROJECT_PAGE_HOST_CLASS));
    return;
  }

  injectHelperStyles();

  const visualCandidates = Array.from(document.querySelectorAll('video, img, canvas, picture'))
    .filter(node => isVisible(node, 180, 180));
  const bestVisual = visualCandidates
    .map(node => {
      const rect = node.getBoundingClientRect();
      const centerX = rect.left + (rect.width / 2);
      const centerY = rect.top + (rect.height / 2);
      const distancePenalty = Math.abs(centerX - (window.innerWidth / 2)) + Math.abs(centerY - (window.innerHeight / 2));
      return {
        node,
        score: (rect.width * rect.height) - (distancePenalty * 300)
      };
    })
    .sort((left, right) => right.score - left.score)[0]?.node || null;
  const host = getCardFromProjectNode(bestVisual) || bestVisual?.parentElement || null;

  if (!host || !isVisible(host, 220, 220)) {
    existing?.remove();
    return;
  }

  let button = existing;
  if (button && button.parentElement !== document.body) {
    button.remove();
    button = null;
  }

  if (!button) {
    button = document.createElement('button');
    button.id = PROJECT_DOWNLOAD_ACTIONS_ID;
    button.type = 'button';
    button.className = PROJECT_PAGE_DOWNLOAD_CLASS;
    button.dataset.soraHelper = 'true';
    button.dataset.baseLabel = 'Download';
    button.textContent = 'Download';
    button.addEventListener('pointerdown', event => {
      event.preventDefault();
      event.stopPropagation();
    });
    button.addEventListener('click', async event => {
      event.preventDefault();
      event.stopPropagation();
      const originalLabel = 'Download';
      const targetUrl = normalizeUrl(location.href);
      if (!targetUrl) return;

      try {
        setProfileButtonBusy(button, true, 'Checking...');
        let protection = await getPageProtectionStatus();
        if (!protection?.valid) {
          protection = await getPageProtectionStatus({ force: true });
        }
        if (!protection?.valid) {
          if (protection?.type === 'license') {
            setProfileButtonBusy(button, true, 'Opening...');
            await openProfileBuyLicensePage();
            showHelperStatus('Opened Buy License / KHQR.');
            return;
          }
          throw new Error(protection?.reason || 'This action is locked.');
        }

        setProfileButtonBusy(button, true, 'Starting...');
        const response = await chrome.runtime.sendMessage({
          action: 'download_sora_urls',
          urls: [targetUrl],
          forceRedownload: true
        });
        if (!response?.ok) {
          throw new Error(response?.message || 'Could not start downloading this video.');
        }
        showHelperStatus(response?.message || 'Started download for this video.');
      } catch (error) {
        showHelperStatus(error?.message || 'Could not start downloading this video.');
      } finally {
        setProfileButtonBusy(button, false, originalLabel);
      }
    });
  }

  const anchorRect = (bestVisual || host).getBoundingClientRect();
  const useRailLayout = window.innerWidth <= 1100 || window.innerHeight > window.innerWidth;
  if (button.parentElement !== document.body) {
    document.body.appendChild(button);
  }

  if (useRailLayout) {
    const railCandidates = Array.from(document.querySelectorAll('button, a, [role="button"]'))
      .filter(node => isVisible(node, 20, 20))
      .map(node => {
        const rect = node.getBoundingClientRect();
        const label = `${getNodeLabel(node)} ${getNodeHint(node)}`.toLowerCase();
        return { node, rect, label };
      })
      .filter(entry => entry.rect.left >= (window.innerWidth * 0.72))
      .filter(entry => /share|remix|reply|like/.test(entry.label));
    const railAnchor =
      railCandidates.find(entry => entry.label.includes('like')) ||
      railCandidates.find(entry => entry.label.includes('reply')) ||
      railCandidates.find(entry => entry.label.includes('remix')) ||
      railCandidates.find(entry => entry.label.includes('share')) ||
      null;
    button.dataset.layout = 'rail';
    const buttonWidth = Math.max(button.getBoundingClientRect().width || 78, 78);
    const buttonHeight = Math.max(button.getBoundingClientRect().height || 30, 30);
    if (railAnchor) {
      const railTop = Math.round(railAnchor.rect.top - buttonHeight - 16);
      const railLeft = Math.round(railAnchor.rect.left + ((railAnchor.rect.width - buttonWidth) / 2) + 18);
      button.style.top = `${Math.max(96, railTop)}px`;
      button.style.left = `${Math.max(8, railLeft)}px`;
      button.style.right = 'auto';
    } else {
      const railTop = Math.round(window.innerHeight * 0.4);
      button.style.top = `${Math.max(120, railTop)}px`;
      button.style.left = 'auto';
      button.style.right = '56px';
    }
  } else {
    const top = Math.max(12, Math.round(anchorRect.top + 12));
    const left = Math.max(72, Math.round(anchorRect.left + 12));
    button.dataset.layout = 'corner';
    button.style.top = `${top}px`;
    button.style.left = `${left}px`;
    button.style.right = 'auto';
  }

}

function ensurePageActionButtons() {
  ensureDraftsPagePostButton();
  ensureProfilePageActionButtons();
  ensureExplorePageActionButton();
  ensureProjectPageDownloadButton();
}

function ensurePageMenu() {
  removeInjectedHelperUi();
  const existing = document.getElementById(HELPER_MENU_ROOT_ID);
  if (!ENABLE_PAGE_HELPERS || !isSoraDomainPage()) {
    existing?.remove();
    return;
  }

  injectHelperStyles();

  if (existing) {
    positionPageMenu(existing);
    existing.setAttribute('data-open', helperMenuOpen ? 'true' : 'false');
    return;
  }

  const root = document.createElement('div');
  root.id = HELPER_MENU_ROOT_ID;
  root.dataset.soraHelper = 'true';
  root.setAttribute('data-open', 'false');

  const trigger = document.createElement('button');
  trigger.id = HELPER_MENU_TRIGGER_ID;
  trigger.type = 'button';
  trigger.textContent = 'Show All Menu';
  trigger.dataset.soraHelper = 'true';
  trigger.addEventListener('click', event => {
    event.preventDefault();
    event.stopPropagation();
    setPageMenuOpen(!helperMenuOpen);
  });

  const panel = document.createElement('div');
  panel.id = HELPER_MENU_PANEL_ID;
  panel.dataset.soraHelper = 'true';
  panel.innerHTML = `
    <div class="sora-menu-title">Sora Tools</div>
    <div class="sora-menu-subtitle">Quick actions near your profile menu.</div>
    <div class="sora-menu-grid">
      <button type="button" class="sora-menu-button" data-action="scan-posts" data-tone="post">Scan Posts</button>
      <button type="button" class="sora-menu-button" data-action="post-all" data-tone="post">Post All</button>
      <button type="button" class="sora-menu-button" data-action="scan-videos" data-tone="delete">Scan Videos</button>
      <button type="button" class="sora-menu-button" data-action="delete-all" data-tone="delete">Delete All</button>
      <button type="button" class="sora-menu-button" data-action="copy-urls" data-tone="neutral">Copy URLs</button>
      <button type="button" class="sora-menu-button" data-action="open-hidden" data-tone="neutral">Open Hidden</button>
    </div>
    <div id="${HELPER_MENU_META_ID}">Ready.</div>
  `;

  panel.querySelector('[data-action="scan-posts"]')?.addEventListener('click', event => {
    const button = event.currentTarget;
    runPageMenuAction(button, 'Scanning...', async () => {
      const urls = scanForProjectUrls();
      showHelperStatus(`Found ${urls.length} Sora URL(s).`);
    });
  });

  panel.querySelector('[data-action="post-all"]')?.addEventListener('click', event => {
    const button = event.currentTarget;
    runPageMenuAction(button, 'Starting...', async () => {
      const draftUrls = getDraftUrlsForMenu();
      if (!draftUrls.length) {
        showHelperStatus('No draft URLs found. Scan posts first.');
        return;
      }

      if (isSoraDraftsPage()) {
        const response = await runInlineDraftQueueFlow({
          limit: null,
          skipFailed: true,
          targetUrls: draftUrls,
          listPageUrl: normalizeUrl(location.href)
        });
        showHelperStatus(response?.message || 'Started inline post queue.');
        return;
      }

      const response = await chrome.runtime.sendMessage({
        action: 'start_run_queue',
        urls: draftUrls,
        limit: null,
        limitLabel: 'All',
        skipFailed: true
      });
      showHelperStatus(response?.message || 'Started post queue.');
    });
  });

  panel.querySelector('[data-action="scan-videos"]')?.addEventListener('click', event => {
    const button = event.currentTarget;
    runPageMenuAction(button, 'Scanning...', async () => {
      const result = await scanProfileVideos();
      showHelperStatus(result?.message || 'Scan finished.');
    });
  });

  panel.querySelector('[data-action="delete-all"]')?.addEventListener('click', event => {
    const button = event.currentTarget;
    runPageMenuAction(button, 'Starting...', async () => {
      const scan = await saveDeleteScanResult();
      if (!scan.items.length) {
        showHelperStatus('No scanned Sora video URLs found. Scan videos first.');
        return;
      }

      const saved = await chrome.storage.local.get(DELETE_FAST_MODE_KEY);
      if (isProfileListPage()) {
        const response = await runDeleteQueueFlow({
          limit: null,
          skipFailed: true,
          targetUrls: scan.items.map(item => item.url),
          fastMode: saved?.[DELETE_FAST_MODE_KEY] !== false
        });
        showHelperStatus(response?.message || 'Started delete script queue.');
        return;
      }

      const response = await chrome.runtime.sendMessage({
        action: 'start_delete_queue',
        urls: scan.items.map(item => item.url),
        limit: null,
        limitLabel: 'All',
        skipFailed: true,
        fastMode: saved?.[DELETE_FAST_MODE_KEY] !== false
      });
      showHelperStatus(response?.message || 'Started delete queue.');
    });
  });

  panel.querySelector('[data-action="copy-urls"]')?.addEventListener('click', event => {
    const button = event.currentTarget;
    runPageMenuAction(button, 'Copying...', async () => {
      const urls = getMenuCopyUrls();
      if (!urls.length) {
        showHelperStatus('No Sora URLs found yet.');
        return;
      }
      await copyTextToClipboard(urls.join('\n'));
      showHelperStatus(`Copied ${urls.length} URL(s).`);
    });
  });

  panel.querySelector('[data-action="open-hidden"]')?.addEventListener('click', event => {
    const button = event.currentTarget;
    runPageMenuAction(button, 'Starting...', async () => {
      const urls = getMenuCopyUrls();
      if (!urls.length) {
        showHelperStatus('No Sora URLs found to open.');
        return;
      }
      const response = await chrome.runtime.sendMessage({
        action: 'open_hidden_urls',
        urls,
        limitLabel: 'All'
      });
      showHelperStatus(response?.message || 'Started hidden open queue.');
    });
  });

  root.appendChild(trigger);
  root.appendChild(panel);
  document.documentElement.appendChild(root);
  positionPageMenu(root);

  document.addEventListener('click', event => {
    if (!root.contains(event.target)) setPageMenuOpen(false);
  }, true);

  window.addEventListener('resize', () => positionPageMenu(root));
  window.addEventListener('scroll', () => positionPageMenu(root), { passive: true });
}

function reportPostStatus(message, silent) {
  if (!silent) showHelperStatus(message);
}

function getPostTimings(fastMode = true) {
  return {
    actionDelay: fastMode ? FAST_POST_ACTION_DELAY_MS : NORMAL_POST_ACTION_DELAY_MS,
    menuDelay: fastMode ? FAST_POST_MENU_DELAY_MS : NORMAL_POST_MENU_DELAY_MS,
    retryDelay: fastMode ? FAST_POST_RETRY_DELAY_MS : NORMAL_POST_RETRY_DELAY_MS,
    completePollDelay: fastMode ? FAST_POST_COMPLETE_POLL_MS : NORMAL_POST_COMPLETE_POLL_MS,
    completeTimeout: fastMode ? FAST_POST_COMPLETE_TIMEOUT_MS : NORMAL_POST_COMPLETE_TIMEOUT_MS
  };
}

async function waitForPostControls(timeoutMs = 2200) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (findPostAction(document) || findMenuAction(document) || findDraftAction(document)) return true;
    await sleep(120);
  }
  return false;
}

function hasPostSuccessSignal(startUrl) {
  const currentUrl = normalizeUrl(location.href);
  if (currentUrl && currentUrl !== startUrl && isSoraPublishedUrl(currentUrl)) return true;
  if (isSoraPublishedUrl(currentUrl)) return true;

  const statusText = normalizeText(
    Array.from(document.querySelectorAll('[role="status"], [role="alert"], [data-sonner-toast], [data-toast]'))
      .map(textOf)
      .join(' ')
  );

  return matchesAny(statusText, ['posted', 'published', 'success']);
}

function hasPostTransitionSignal(node) {
  if (!node) return false;
  if (!node.isConnected) return true;

  const ariaDisabled = String(node.getAttribute?.('aria-disabled') || '').toLowerCase();
  const disabled = Boolean(node.disabled) || ariaDisabled === 'true';
  if (disabled) return true;

  const label = getNodeLabel(node);
  const hint = getNodeHint(node);
  if (matchesAny(`${label} ${hint}`, ['posting', 'publishing', 'processing', 'submitted'])) return true;

  const rect = node.getBoundingClientRect?.() || null;
  if (rect && (rect.width < 8 || rect.height < 8)) return true;

  return false;
}

async function waitForPostCompletion(startUrl, timings) {
  const start = Date.now();

  while (Date.now() - start < timings.completeTimeout) {
    if (hasPostSuccessSignal(startUrl)) return true;
    await sleep(Math.max(70, timings.completePollDelay));
  }

  return false;
}

async function clickPostActionAndWait(node, timings, meta = {}) {
  if (!node) return null;

  const startUrl = normalizeUrl(location.href);
  clickNode(node);
  await sleep(Math.max(50, timings.actionDelay));

  if (await waitForPostCompletion(startUrl, timings)) {
    return {
      ok: true,
      message: 'Posted draft.',
      via: meta.via || 'post-action',
      url: normalizeUrl(location.href) || startUrl
    };
  }

  if (hasPostTransitionSignal(node)) {
    return {
      ok: true,
      message: 'Post started.',
      via: meta.via || 'post-action',
      url: normalizeUrl(location.href) || startUrl
    };
  }

  return null;
}

async function runPostDraftFlow(options = {}) {
  const {
    silent = false,
    fastMode = false,
    attempts = null,
    controlsTimeoutMs = null,
    prepareDraftBeforePost = true
  } = options;
  const timings = getPostTimings(fastMode);

  if (!isSoraProjectUrl(location.href)) {
    const message = 'Open a Sora project or draft page first.';
    reportPostStatus(message, silent);
    return { ok: false, message };
  }

  const isDraftPage = isSoraDraftUrl(location.href);
  const maxAttempts = Number.isFinite(attempts) && attempts > 0
    ? Math.floor(attempts)
    : (fastMode ? 4 : 6);
  const controlsTimeout = Number.isFinite(controlsTimeoutMs) && controlsTimeoutMs > 0
    ? Math.floor(controlsTimeoutMs)
    : (isDraftPage ? (fastMode ? 2200 : 5200) : (fastMode ? 1600 : 3200));
  await waitForPostControls(controlsTimeout);

  if (isDraftPage && prepareDraftBeforePost) {
    await prepareDraftDescriptionBeforePost(silent);
    await waitForPostControls(Math.max(1200, controlsTimeout));
  }

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (isDraftPage) {
      const directPost = findPostAction(document);
      if (directPost) {
        const result = await clickPostActionAndWait(directPost, timings, { via: 'direct-post' });
        if (result?.ok) {
          reportPostStatus(result.message, silent);
          return result;
        }
      }
    }

    if (!isDraftPage) {
      const directDraft = findDraftAction(document);
      if (directDraft) {
        clickNode(directDraft);
        const message = 'Clicked Draft action.';
        reportPostStatus(message, silent);
        return { ok: true, message, via: 'direct-draft' };
      }
    }

    const opener = findMenuAction(document);
    if (opener) {
      clickNode(opener);
      await sleep(Math.max(90, Math.floor(timings.menuDelay / 2)));

      const dialogRoots = getDialogRoots();
      for (const root of dialogRoots) {
        if (isDraftPage) {
          const nestedPost = findPostAction(root, { inDialog: true });
          if (nestedPost) {
            const result = await clickPostActionAndWait(nestedPost, timings, { via: 'menu-post' });
            if (result?.ok) {
              reportPostStatus(result.message, silent);
              return result;
            }
          }
        }

        if (!isDraftPage) {
          const nestedDraft = findDraftAction(root);
          if (nestedDraft) {
            clickNode(nestedDraft);
            const message = 'Opened menu and clicked Draft.';
            reportPostStatus(message, silent);
            return { ok: true, message, via: 'menu-draft' };
          }
        }
      }

      await sleep(Math.max(80, Math.floor(timings.menuDelay / 2)));

      if (isDraftPage) {
        const latePost = findPostAction(document);
        if (latePost) {
          const result = await clickPostActionAndWait(latePost, timings, { via: 'late-post' });
          if (result?.ok) {
            reportPostStatus(result.message, silent);
            return result;
          }
        }
      }

      if (!isDraftPage) {
        const lateDraft = findDraftAction(document);
        if (lateDraft) {
          clickNode(lateDraft);
          const message = 'Clicked Draft after opening menu.';
          reportPostStatus(message, silent);
          return { ok: true, message, via: 'late-draft' };
        }
      }
    }

    await sleep(timings.retryDelay);
  }

  const message = isDraftPage
    ? 'Post or Publish action was not found on this draft page.'
    : 'Draft or Share menu not found on this page.';
  reportPostStatus(message, silent);
  return { ok: false, message };
}

function findDialogPostAction() {
  for (const root of getDialogRoots()) {
    const action = findPostAction(root, { inDialog: true });
    if (action) return action;
  }
  return null;
}

async function waitForCurrentUrl(targetUrl, timeoutMs = 15000) {
  const target = normalizeUrl(targetUrl);
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    if (normalizeUrl(location.href) === target) return true;
    await sleep(120);
  }

  return false;
}

function findDraftCardLink(entry) {
  const targetUrl = normalizeUrl(entry?.url || '');
  const card = entry?.card || null;
  if (!targetUrl || !card) return null;

  const candidates = [card, ...getProjectLinkElements(card)];
  for (const node of candidates) {
    if (getProjectLinkUrl(node) === targetUrl) return node;
  }

  return null;
}

async function openDraftInCurrentTab(entry) {
  const targetUrl = normalizeUrl(entry?.url || '');
  if (!targetUrl) return false;

  const directLink = findDraftCardLink(entry);
  if (directLink) {
    clickNode(directLink);
  } else if (entry?.card) {
    clickNode(entry.card);
  } else {
    location.href = targetUrl;
  }

  const reached = await waitForCurrentUrl(targetUrl, 12000);
  if (!reached && normalizeUrl(location.href) !== targetUrl) {
    location.href = targetUrl;
    if (!await waitForCurrentUrl(targetUrl, 12000)) return false;
  }

  await sleep(INLINE_POST_OPEN_SETTLE_MS);
  await waitForPostControls(5200);
  return true;
}

async function returnToDraftsList(listPageUrl) {
  const targetUrl = normalizeUrl(listPageUrl || 'https://sora.chatgpt.com/drafts');
  if (isSoraDraftsPage() && normalizeUrl(location.href) === targetUrl) {
    await waitForDraftListPage(6000);
    await sleep(INLINE_POST_RETURN_SETTLE_MS);
    return true;
  }

  history.back();
  await sleep(500);
  if (isSoraDraftsPage()) {
    await waitForDraftListPage(8000);
    await sleep(INLINE_POST_RETURN_SETTLE_MS);
    return true;
  }

  location.href = targetUrl;
  if (!await waitForCurrentUrl(targetUrl, 12000)) return false;
  await waitForDraftListPage(8000);
  await sleep(INLINE_POST_RETURN_SETTLE_MS);
  return true;
}

async function waitForInlineDraftPostCompletion(targetUrl, card, timings) {
  const target = normalizeUrl(targetUrl);
  const start = Date.now();

  while (Date.now() - start < timings.completeTimeout) {
    if (hasPostSuccessSignal(normalizeUrl(location.href))) return true;

    const stillPresent = getDraftCardEntries().some(entry => entry.url === target);
    if (!stillPresent) return true;

    if (card && !card.isConnected && !stillPresent) return true;

    await sleep(Math.max(70, timings.completePollDelay));
  }

  return false;
}

async function clickInlinePostSequence(targetUrl, card, initialNode, timings, via) {
  let node = initialNode;
  let stepVia = via;

  for (let step = 0; step < 3; step += 1) {
    if (!node) break;

    clickNode(node);
    await sleep(Math.max(60, timings.actionDelay));

    if (await waitForInlineDraftPostCompletion(targetUrl, card, timings)) {
      return {
        ok: true,
        message: 'Posted draft from the drafts page.',
        via: stepVia,
        url: targetUrl
      };
    }

    const dialogAction = findDialogPostAction();
    if (!dialogAction || dialogAction === node) break;
    node = dialogAction;
    stepVia = `${via}-dialog`;
  }

  return null;
}

async function postSingleDraftCard(entry, options = {}) {
  const targetUrl = normalizeUrl(entry?.url || '');
  const listPageUrl = normalizeUrl(options.listPageUrl || 'https://sora.chatgpt.com/drafts');
  if (!targetUrl || !entry?.card) {
    return { ok: false, message: 'Draft card was not found on the drafts page.' };
  }

  let currentEntry = entry;

  for (let attempt = 0; attempt < INLINE_POST_REOPEN_RETRY_COUNT; attempt += 1) {
    const opened = await openDraftInCurrentTab(currentEntry);
    if (!opened) {
      if (attempt < INLINE_POST_REOPEN_RETRY_COUNT - 1) {
        await sleep(INLINE_POST_RETURN_SETTLE_MS);
        const refreshedEntry = await findDraftEntryByUrlWithScroll(targetUrl);
        if (refreshedEntry) currentEntry = refreshedEntry;
        continue;
      }
      break;
    }

    const result = await runPostDraftFlow({
      silent: true,
      fastMode: false,
      attempts: 6,
      controlsTimeoutMs: 5200
    });
    await returnToDraftsList(listPageUrl).catch(() => {});

    if (result?.ok) {
      return {
        ...result,
        message: 'Opened draft, waited, and posted it from the current tab.',
        via: 'current-tab-open-post',
        url: targetUrl
      };
    }

    if (attempt < INLINE_POST_REOPEN_RETRY_COUNT - 1) {
      await sleep(INLINE_POST_RETURN_SETTLE_MS);
      const refreshedEntry = await findDraftEntryByUrlWithScroll(targetUrl);
      if (refreshedEntry) currentEntry = refreshedEntry;
    }
  }

  return {
    ok: false,
    message: 'Post or Publish action was not found after reopening this draft.',
    url: targetUrl
  };
}

async function findDraftEntryByUrlWithScroll(targetUrl) {
  const target = normalizeUrl(targetUrl);
  if (!target) return null;

  window.scrollTo({ top: 0, behavior: 'auto' });
  await sleep(500);

  for (let pass = 0; pass < 18; pass += 1) {
    const match = getDraftCardEntries().find(entry => entry.url === target);
    if (match) return match;

    const loadedMore = await scrollForMoreCards();
    if (!loadedMore) break;
  }

  return null;
}

async function runInlineDraftQueueFlow(options = {}) {
  const {
    limit = null,
    skipFailed = true,
    targetUrls = [],
    listPageUrl = null
  } = options;

  if (inlineDraftPostRunning) {
    return { ok: false, message: 'Draft page post script is already running.' };
  }

  const ready = await waitForDraftListPage();
  if (!ready) {
    const message = 'Open the Sora drafts page with visible draft cards first.';
    showHelperStatus(message);
    return { ok: false, message, posted: 0, failed: 0, done: 0, total: 0, results: [] };
  }

  const queueUrls = Array.from(new Set((Array.isArray(targetUrls) ? targetUrls : [])
    .map(url => normalizeUrl(url))
    .filter(isSoraDraftUrl)));
  const resolvedListPageUrl = normalizeUrl(listPageUrl || location.href || 'https://sora.chatgpt.com/drafts');
  const fallbackUrls = !queueUrls.length ? getGlobalDraftProjectUrls() : [];
  const orderedUrls = queueUrls.length ? queueUrls : Array.from(new Set(fallbackUrls));
  const activeUrls = limit ? orderedUrls.slice(0, limit) : orderedUrls;

  if (!activeUrls.length) {
    const message = 'No draft URLs found on the drafts page. Scan Post URLs first.';
    showHelperStatus(message);
    return { ok: false, message, posted: 0, failed: 0, done: 0, total: 0, results: [] };
  }

  inlineDraftPostRunning = true;
  inlineDraftPostStopRequested = false;

  let posted = 0;
  let failed = 0;
  const results = [];
  const total = activeUrls.length;

  try {
    for (const [index, targetUrl] of activeUrls.entries()) {
      if (inlineDraftPostStopRequested) break;

      const entry = await findDraftEntryByUrlWithScroll(targetUrl);
      if (!entry) {
        const missing = {
          ok: false,
          url: targetUrl,
          title: '',
          message: 'Could not find that draft card on the drafts page.'
        };
        failed += 1;
        results.push(missing);
        showHelperStatus(`Failed ${failed}/${total}: draft card not found.`);

        if (!skipFailed) break;
        await sleep(280);
        continue;
      }

      showHelperStatus(`Posting ${index + 1}/${total}: ${entry.title || entry.url}...`);
      const result = await postSingleDraftCard(entry, { listPageUrl: resolvedListPageUrl });
      const item = {
        ok: Boolean(result?.ok),
        url: entry.url,
        title: entry.title,
        message: result?.message || (result?.ok ? 'Posted draft.' : 'Post action not found.')
      };
      results.push(item);

      if (item.ok) {
        posted += 1;
        await sleep(220);
      } else {
        failed += 1;
        if (!skipFailed) break;
        await sleep(280);
      }
    }
  } finally {
    inlineDraftPostRunning = false;
    inlineDraftPostStopRequested = false;
  }

  const done = results.length;
  const remaining = Math.max(total - done, 0);
  const stopped = done < total;
  const message = stopped
    ? `Stopped after posting ${posted}/${total} draft(s). ${failed} failed.`
    : `Posted ${posted}/${total} draft(s). ${failed} failed.`;

  showHelperStatus(message);
  if (posted > 0) {
    await goToSoraProfilePage().catch(() => {});
  }
  return {
    ok: posted > 0,
    message,
    posted,
    failed,
    done,
    total,
    remaining,
    stopped,
    results
  };
}

function reportDeleteStatus(message, silent) {
  if (!silent) showHelperStatus(message);
}

async function runDeleteProjectFlow(options = {}) {
  const { silent = false, fastMode = false } = options;
  const timings = getDeleteTimings(fastMode);

  if (!isSoraProjectUrl(location.href)) {
    const message = 'Open a Sora video page first.';
    reportDeleteStatus(message, silent);
    return { ok: false, message };
  }

  const targetUrl = normalizeUrl(location.href);

  for (let attempt = 0; attempt < (fastMode ? 5 : 7); attempt += 1) {
    const confirmedFirst = await confirmProjectDelete(targetUrl, { fastMode });
    if (confirmedFirst) {
      const message = 'Deleted video.';
      reportDeleteStatus(message, silent);
      return { ok: true, message, via: 'confirm-dialog', url: targetUrl };
    }

    const menuOpened = await openDeleteProjectMenu({ fastMode });
    if (menuOpened) {
      const deleteClicked = await clickDeleteAction({ fastMode });
      if (deleteClicked) {
        const confirmed = await confirmProjectDelete(targetUrl, { fastMode });
        if (confirmed || await waitForProjectDeletion(targetUrl, { fastMode })) {
          const message = 'Deleted video.';
          reportDeleteStatus(message, silent);
          return { ok: true, message, via: 'three-dots-menu', url: targetUrl };
        }
      }
    }

    const directDelete = await clickDeleteAction({ fastMode });
    if (directDelete) {
      const confirmed = await confirmProjectDelete(targetUrl, { fastMode });
      if (confirmed || await waitForProjectDeletion(targetUrl, { fastMode })) {
        const message = 'Deleted video.';
        reportDeleteStatus(message, silent);
        return { ok: true, message, via: 'direct-delete', url: targetUrl };
      }
    }

    await sleep(timings.retryDelay);
  }

  const message = 'Delete action was not found on this video page.';
  reportDeleteStatus(message, silent);
  return { ok: false, message, url: targetUrl };
}

async function reportDeleteProgress(state) {
  try {
    await chrome.runtime.sendMessage({
      action: 'delete_queue_progress',
      state
    });
  } catch {}
}

function buildDeleteScanResult() {
  return {
    pageUrl: normalizeUrl(location.href),
    items: getProfileCardEntries().map(entry => ({
      key: entry.key,
      url: entry.url,
      title: entry.title
    }))
  };
}

async function getSavedPublishedVideoUrls() {
  const saved = await chrome.storage.local.get(PUBLISHED_VIDEO_STORAGE_KEY);
  const items = Array.isArray(saved?.[PUBLISHED_VIDEO_STORAGE_KEY]) ? saved[PUBLISHED_VIDEO_STORAGE_KEY] : [];
  return Array.from(new Set(items.map(item => normalizeUrl(item)).filter(isSoraPublishedUrl)));
}

async function savePublishedVideoUrls(urls = []) {
  const existing = await getSavedPublishedVideoUrls();
  const merged = Array.from(new Set([
    ...existing,
    ...(Array.isArray(urls) ? urls : []).map(item => normalizeUrl(item)).filter(isSoraPublishedUrl)
  ]));
  await chrome.storage.local.set({ [PUBLISHED_VIDEO_STORAGE_KEY]: merged });
  return merged;
}

async function saveDeleteScanResult() {
  const result = buildDeleteScanResult();
  await chrome.storage.local.set({ [DELETE_STORAGE_KEY]: result });
  await savePublishedVideoUrls(result.items.map(item => item?.url || ''));
  return result;
}

async function scanProfileVideos() {
  const ready = await waitForProfileListPage();
  if (!ready) {
    const message = 'Open a Sora profile/list page with videos first.';
    showHelperStatus(message);
    return { ok: false, message, pageUrl: normalizeUrl(location.href), items: [] };
  }

  const result = await saveDeleteScanResult();
  showHelperStatus(`Found ${result.items.length} visible video card(s).`);
  return {
    ok: true,
    message: `Found ${result.items.length} visible video card(s).`,
    ...result
  };
}

async function findEntryByUrlWithScroll(targetUrl) {
  const target = normalizeUrl(targetUrl);
  if (!target) return null;

  window.scrollTo({ top: 0, behavior: 'auto' });
  await sleep(500);

  for (let pass = 0; pass < 18; pass += 1) {
    const match = getProfileCardEntries().find(entry => entry.url === target);
    if (match) return match;

    const loadedMore = await scrollForMoreCards();
    if (!loadedMore) break;
  }

  return null;
}

async function deleteOneByUrl(targetUrl, options = {}) {
  const ready = await waitForProfileListPage();
  if (!ready) {
    const message = 'Open a Sora profile/list page with videos first.';
    showHelperStatus(message);
    return { ok: false, message };
  }

  const entry = await findEntryByUrlWithScroll(targetUrl);
  if (!entry) {
    const message = 'Could not find that video card on the profile/list page.';
    showHelperStatus(message);
    return { ok: false, message };
  }

  showHelperStatus(`Deleting ${entry.title || entry.url}...`);
  const result = await deleteSingleProfileCard(entry, {
    fastMode: options.fastMode !== false
  });
  const message = result.ok
    ? `Deleted ${entry.title || entry.url}.`
    : result.reason || 'Delete failed.';
  if (result.ok) {
    await sleep(Math.max(90, getDeleteTimings(Boolean(options.fastMode)).confirmDelay));
    await saveDeleteScanResult();
  }
  showHelperStatus(message);
  return {
    ...result,
    message
  };
}

async function runDeleteQueueFlow(options = {}) {
  const { limit = null, skipFailed = true, targetUrls = [], fastMode = true } = options;
  const timings = getDeleteTimings(Boolean(fastMode));

  const ready = await waitForProfileListPage();
  if (!ready) {
    const message = 'Open a Sora profile/list page with videos first.';
    showHelperStatus(message);
    return { ok: false, message, deleted: 0, failed: 0, done: 0, total: limit || 0, results: [] };
  }

  const queueUrls = Array.from(new Set((Array.isArray(targetUrls) ? targetUrls : [])
    .map(url => normalizeUrl(url))
    .filter(isSoraProjectUrl)));
  const fallbackUrls = !queueUrls.length
    ? buildDeleteScanResult().items.map(item => item.url).map(url => normalizeUrl(url)).filter(isSoraProjectUrl)
    : [];
  const orderedUrls = queueUrls.length ? queueUrls : Array.from(new Set(fallbackUrls));
  const activeUrls = limit ? orderedUrls.slice(0, limit) : orderedUrls;

  if (!activeUrls.length) {
    const message = 'No scanned Sora video URLs found. Scan visible cards first.';
    showHelperStatus(message);
    return { ok: false, message, deleted: 0, failed: 0, done: 0, total: 0, results: [] };
  }

  deleteStopRequested = false;
  let deleted = 0;
  let failed = 0;
  const results = [];
  const targetTotal = activeUrls.length;

  await reportDeleteProgress({
    running: true,
    stopRequested: false,
    total: targetTotal,
    done: 0,
    deleted: 0,
    failed: 0,
    remaining: targetTotal,
    currentUrl: null,
    currentTitle: null,
    fastMode,
    lastMessage: 'Preparing delete queue...'
  });

  for (const [index, targetUrl] of activeUrls.entries()) {
    if (deleteStopRequested) break;

    const entry = await findEntryByUrlWithScroll(targetUrl);
    if (!entry) {
      const missingResult = {
        ok: false,
        url: targetUrl,
        title: '',
        reason: 'Could not find that video card on the profile/list page.'
      };
      failed += 1;
      results.push(missingResult);

      await reportDeleteProgress({
        running: true,
        stopRequested: deleteStopRequested,
        total: targetTotal,
        done: results.length,
        deleted,
        failed,
        remaining: Math.max(targetTotal - results.length, 0),
        currentUrl: targetUrl,
        currentTitle: null,
        fastMode,
        lastMessage: `Failed ${failed} video(s).`
      });

      if (!skipFailed) break;
      await sleep(Math.max(100, timings.retryDelay));
      continue;
    }

    showHelperStatus(`Deleting ${entry.title || entry.url}...`);
    await reportDeleteProgress({
      running: true,
      stopRequested: deleteStopRequested,
      total: targetTotal,
      done: results.length,
      deleted,
      failed,
      remaining: Math.max(targetTotal - index, 0),
      currentUrl: entry.url,
      currentTitle: entry.title,
      fastMode,
      lastMessage: `Deleting ${entry.title || entry.url}...`
    });

    const result = await deleteSingleProfileCard(entry, { fastMode });
    results.push(result);

    if (result.ok) {
      deleted += 1;
      await sleep(Math.max(90, timings.confirmDelay));
      await saveDeleteScanResult();
    } else {
      failed += 1;
      if (!skipFailed) break;
    }

    await reportDeleteProgress({
      running: true,
      stopRequested: deleteStopRequested,
      total: targetTotal,
      done: results.length,
      deleted,
      failed,
      remaining: Math.max(targetTotal - results.length, 0),
      currentUrl: result.url || entry.url,
      currentTitle: result.title || entry.title,
      fastMode,
      lastMessage: result.ok
        ? `Deleted ${deleted} video(s).`
        : `Failed ${failed} video(s).`
    });

    await sleep(result.ok ? Math.max(80, timings.actionDelay) : Math.max(100, timings.retryDelay));
  }

  let message = `Deleted ${deleted} video(s). ${failed} failed.`;
  if (deleteStopRequested) {
    message = `Stopped after deleting ${deleted} video(s). ${failed} failed.`;
  } else if (limit && deleted >= targetTotal) {
    message = `Deleted ${deleted}/${targetTotal} video(s). ${failed} failed.`;
  }

  await saveDeleteScanResult();
  await reportDeleteProgress({
    running: false,
    stopRequested: false,
    total: targetTotal || results.length,
    done: results.length,
    deleted,
    failed,
    remaining: Math.max(targetTotal - results.length, 0),
    currentUrl: null,
    currentTitle: null,
    fastMode,
    lastMessage: message,
    results
  });
  showHelperStatus(message);

  return {
    ok: deleted > 0,
    message,
    deleted,
    failed,
    done: results.length,
    total: targetTotal || results.length,
    remaining: Math.max(targetTotal - results.length, 0),
    results
  };
}

function ensureDraftHelper() {
  ensurePageActionButtons();
}

function ensureDeleteHelper() {
  ensurePageActionButtons();
}

function initializeCollector() {
  removeInjectedHelperUi();
  window.addEventListener('message', handleBridgeMessage);
  installHistoryWatchers();
  ensureHelperKeepAlive();
  injectPageHook();
  scanForProjectUrls();
  ensurePageActionButtons();

  const observer = new MutationObserver(() => {
    scheduleRescan(150);
  });

  observer.observe(document.documentElement || document, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['href', 'data-href', 'data-url', 'data-link', 'data-path', 'title', 'aria-label', 'class']
  });

  setTimeout(() => {
    scanForProjectUrls();
    ensurePageActionButtons();
  }, 800);
  setTimeout(() => {
    scanForProjectUrls();
    ensurePageActionButtons();
  }, 2000);
  setTimeout(() => {
    scanForProjectUrls();
    ensurePageActionButtons();
  }, 4000);
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.action === 'scan_project_urls') {
    sendResponse({ urls: scanForProjectUrls() });
    return true;
  }

  if (msg.action === 'scan_profile_videos') {
    scanProfileVideos()
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error',
        pageUrl: normalizeUrl(location.href),
        items: []
      }));
    return true;
  }

  if (msg.action === 'resolve_downloadable_media') {
    resolveCurrentProjectMediaUrl(Number(msg.timeoutMs) > 0 ? Number(msg.timeoutMs) : 9000)
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        pageUrl: normalizeUrl(location.href),
        mediaUrl: null,
        candidates: [],
        message: error?.message || 'Could not resolve a direct media URL.'
      }));
    return true;
  }

  if (msg.action === 'clear_project_urls') {
    discoveredUrls.clear();
    chrome.storage.local.set({ [STORAGE_KEY]: [] });
    sendResponse({ urls: [] });
    return true;
  }

  if (msg.action === 'clear_delete_scan') {
    chrome.storage.local.set({
      [DELETE_STORAGE_KEY]: {
        pageUrl: null,
        items: []
      }
    })
      .then(() => sendResponse({ ok: true }))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));
    return true;
  }

  if (msg.action === 'post_with_draft') {
    runPostDraftFlow({
      silent: Boolean(msg.silent),
      fastMode: Boolean(msg.fastMode),
      attempts: msg.attempts,
      controlsTimeoutMs: msg.controlsTimeoutMs,
      prepareDraftBeforePost: msg.prepareDraftBeforePost !== false
    })
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));
    return true;
  }

  if (msg.action === 'post_visible_drafts_inline') {
    const limitValue = Number(msg.limit);
    runInlineDraftQueueFlow({
      limit: Number.isFinite(limitValue) && limitValue > 0 ? Math.floor(limitValue) : null,
      skipFailed: msg.skipFailed !== false,
      targetUrls: Array.isArray(msg.urls) ? msg.urls : [],
      listPageUrl: msg.listPageUrl || null
    })
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));
    return true;
  }

  if (msg.action === 'request_stop_inline_post_queue') {
    if (!inlineDraftPostRunning) {
      sendResponse({
        ok: false,
        message: 'No draft page post script is running right now.'
      });
      return true;
    }

    inlineDraftPostStopRequested = true;
    sendResponse({
      ok: true,
      message: 'Stop requested. Finishing the current draft card...'
    });
    return true;
  }

  if (msg.action === 'delete_current_project') {
    runDeleteProjectFlow({
      silent: Boolean(msg.silent),
      fastMode: msg.fastMode !== false
    })
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));
    return true;
  }

  if (msg.action === 'delete_one_by_url') {
    deleteOneByUrl(msg.targetUrl, {
      fastMode: msg.fastMode !== false
    })
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));
    return true;
  }

  if (msg.action === 'run_delete_queue') {
    runDeleteQueueFlow({
      limit: msg.limit || null,
      skipFailed: msg.skipFailed !== false,
      targetUrls: Array.isArray(msg.targetUrls) ? msg.targetUrls : [],
      fastMode: msg.fastMode !== false
    })
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error',
        deleted: 0,
        failed: 0,
        done: 0,
        total: msg.limit || 0,
        results: []
      }));
    return true;
  }

  if (msg.action === 'request_stop_delete_queue') {
    deleteStopRequested = true;
    sendResponse({ ok: true });
    return true;
  }

});

initializeCollector();
