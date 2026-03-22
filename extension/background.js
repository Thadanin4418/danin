importScripts('integrity.js', 'license.js');

const STORAGE_KEY = 'soraPageUrlResults';
const AUTO_POST_KEY = 'soraAutoPostEnabled';
const PROCESSED_DRAFTS_KEY = 'soraProcessedDraftUrls';
const DELETE_SCAN_KEY = 'soraDeleteScanResults';
const DOWNLOAD_HISTORY_KEY = 'soraDownloadedVideoIds';
const FAILED_DOWNLOAD_URLS_KEY = 'soraFailedDownloadUrls';
const DOWNLOAD_MEDIA_CACHE_KEY = 'soraResolvedDownloadMediaCache';
const WORKER_START_URL = 'https://sora.chatgpt.com/';
const SORA_PROFILE_URL = 'https://sora.chatgpt.com/profile';
const POST_PROFILE_REDIRECT_DELAY_MS = 3000;
const POST_PROJECT_ACTION_DELAY_MS = 180;
const POST_PARALLEL_TAB_SETTLE_DELAY_MS = 1200;
const POST_REFRESH_RETRY_SETTLE_DELAY_MS = 1600;
const POST_RETRY_DELAY_MS = 140;
const POST_NEXT_DELAY_MS = 140;
const POST_FAIL_DELAY_MS = 220;
const POST_PARALLEL_MESSAGE_ATTEMPTS = 8;
const POST_PARALLEL_FLOW_ATTEMPTS = 5;
const POST_PARALLEL_CONTROLS_TIMEOUT_MS = 4800;
const NORMAL_PROJECT_ACTION_DELAY_MS = 1200;
const FAST_PROJECT_ACTION_DELAY_MS = 140;
const DELETE_PARALLEL_TAB_SETTLE_DELAY_MS = 4500;
const DELETE_REFRESH_RETRY_SETTLE_DELAY_MS = 4500;
const NORMAL_DELETE_RETRY_DELAY_MS = 900;
const FAST_DELETE_RETRY_DELAY_MS = 110;
const NORMAL_DELETE_NEXT_DELAY_MS = 2500;
const FAST_DELETE_NEXT_DELAY_MS = 80;
const NORMAL_DELETE_FAIL_DELAY_MS = 1000;
const FAST_DELETE_FAIL_DELAY_MS = 100;
const HIDDEN_OPEN_SETTLE_DELAY_MS = 160;
const HIDDEN_OPEN_NEXT_DELAY_MS = 80;
const DOWNLOAD_MEDIA_SETTLE_DELAY_MS = 2600;
const DOWNLOAD_MEDIA_RETRY_DELAY_MS = 500;
const DOWNLOAD_MEDIA_TIMEOUT_MS = 10000;
const SORAVDL_PROXY_BASE_URL = 'https://soravdl.com/api/proxy/video/';
const SORAVDL_PROXY_PUBLIC_BASE_URL = 'https://soravdl.com/public/api/proxy/video/';
const SORADOWN_STREAM_BASE_URL = 'https://soradown.online/api/stream.php?id=';
const FACEBOOK_RESOLVE_BASE_URLS = [
  'https://soradown.online',
  'https://soravdl.com',
  'https://sora-license-server-op4k.onrender.com',
  'http://127.0.0.1:8765',
  'http://localhost:8765'
];
const POST_QUEUE_CONCURRENCY = 1;
const DELETE_QUEUE_CONCURRENCY = 1;
const LICENSE_REQUIRED_MESSAGE = 'License required. Open the extension popup and activate a valid key first.';
const INTEGRITY_REQUIRED_MESSAGE = 'Extension files were changed. Reinstall the original package.';

let autoPostRunning = false;
let autoPostQueued = false;
let workerTabId = null;
let workerWindowId = null;
const parallelWorkerTabIds = new Set();
let manualRunState = createEmptyRunState();
let deleteRunState = createEmptyDeleteRunState();
let openRunState = createEmptyOpenRunState();
let downloadRunState = createEmptyDownloadRunState();
const activeDownloadItems = new Map();
let pendingDownloadJobs = [];
let downloadJobStarterBusy = false;
let downloadBadgeClearTimer = null;

async function getBackgroundLicenseStatus() {
  if (!globalThis.SoraLicense) {
    return {
      valid: false,
      reason: 'License module is unavailable.'
    };
  }
  return await SoraLicense.getStoredLicenseStatus(chrome.storage.local);
}

async function getBackgroundIntegrityStatus() {
  if (!globalThis.SoraIntegrity) {
    return {
      valid: false,
      message: 'Integrity module is unavailable.'
    };
  }
  return await SoraIntegrity.getIntegrityStatus();
}

async function replyIfLicenseInvalid(sendResponse) {
  const status = await getBackgroundLicenseStatus();
  if (status.valid) return false;
  sendResponse({
    ok: false,
    message: status.reason || LICENSE_REQUIRED_MESSAGE,
    license: status
  });
  return true;
}

function createEmptyRunState() {
  return {
    running: false,
    stopRequested: false,
    mode: 'idle',
    total: 0,
    done: 0,
    posted: 0,
    failed: 0,
    remaining: 0,
    currentIndex: 0,
    currentUrl: null,
    skipFailed: true,
    batchLabel: 'All',
    startedAt: null,
    finishedAt: null,
    lastMessage: 'Ready.',
    results: []
  };
}

function getRunStatus() {
  return {
    ...manualRunState,
    results: manualRunState.results.slice(-10)
  };
}

function prepareRunState(options = {}) {
  manualRunState = {
    ...createEmptyRunState(),
    running: true,
    mode: options.mode || 'manual',
    stopRequested: false,
    skipFailed: options.skipFailed !== false,
    batchLabel: options.batchLabel || 'All',
    startedAt: Date.now(),
    lastMessage: options.lastMessage || 'Preparing queue...'
  };
}

function finishRunState(message, extra = {}) {
  manualRunState = {
    ...manualRunState,
    ...extra,
    running: false,
    currentUrl: null,
    currentIndex: 0,
    stopRequested: false,
    finishedAt: Date.now(),
    lastMessage: message || manualRunState.lastMessage
  };
}

function createEmptyDeleteRunState() {
  return {
    running: false,
    stopRequested: false,
    total: 0,
    done: 0,
    deleted: 0,
    failed: 0,
    remaining: 0,
    currentUrl: null,
    currentTitle: null,
    batchLabel: 'All',
    skipFailed: true,
    fastMode: true,
    startedAt: null,
    finishedAt: null,
    lastMessage: 'Ready.',
    results: []
  };
}

function getDeleteRunStatus() {
  return {
    ...deleteRunState,
    results: deleteRunState.results.slice(-10)
  };
}

function createEmptyOpenRunState() {
  return {
    running: false,
    stopRequested: false,
    total: 0,
    done: 0,
    remaining: 0,
    currentUrl: null,
    batchLabel: 'All',
    startedAt: null,
    finishedAt: null,
    lastMessage: 'Hidden open queue idle.',
    results: []
  };
}

function getOpenRunStatus() {
  return {
    ...openRunState,
    results: openRunState.results.slice(-10)
  };
}

function createEmptyDownloadRunState() {
  return {
    running: false,
    total: 0,
    done: 0,
    started: 0,
    completed: 0,
    failed: 0,
    remaining: 0,
    invalidCount: 0,
    duplicateCount: 0,
    downloadedBeforeCount: 0,
    currentIndex: 0,
    currentId: null,
    startedAt: null,
    finishedAt: null,
    lastMessage: 'Download queue idle.',
    results: []
  };
}

function getDownloadRunStatus() {
  return {
    ...downloadRunState,
    results: downloadRunState.results.slice(-10)
  };
}

function prepareDownloadRunState(options = {}) {
  downloadRunState = {
    ...createEmptyDownloadRunState(),
    running: true,
    total: options.total || 0,
    remaining: options.total || 0,
    invalidCount: options.invalidCount || 0,
    duplicateCount: options.duplicateCount || 0,
    downloadedBeforeCount: options.downloadedBeforeCount || 0,
    startedAt: Date.now(),
    lastMessage: options.lastMessage || 'Preparing download queue...'
  };
}

function finishDownloadRunState(message, extra = {}) {
  downloadRunState = {
    ...downloadRunState,
    ...extra,
    running: false,
    currentIndex: 0,
    currentId: null,
    finishedAt: Date.now(),
    lastMessage: message || downloadRunState.lastMessage
  };
  activeDownloadItems.clear();
  pendingDownloadJobs = [];
  downloadJobStarterBusy = false;
}

function clearDownloadBadgeTimer() {
  if (!downloadBadgeClearTimer) return;
  clearTimeout(downloadBadgeClearTimer);
  downloadBadgeClearTimer = null;
}

async function setDownloadBadge(text, color, title) {
  try {
    if (typeof text === 'string') {
      await chrome.action.setBadgeText({ text });
    }
    if (color) {
      await chrome.action.setBadgeBackgroundColor({ color });
    }
    if (title) {
      await chrome.action.setTitle({ title });
    }
  } catch {}
}

function markDownloadBadgeRunning(total = 0) {
  clearDownloadBadgeTimer();
  setDownloadBadge('DL', '#1d4ed8', total
    ? `Downloading ${total} Sora video(s)...`
    : 'Downloading Sora videos...').catch(() => {});
}

function markDownloadBadgeFinished(completed = 0, failed = 0) {
  clearDownloadBadgeTimer();
  const hasFailures = failed > 0;
  setDownloadBadge(
    hasFailures ? '!' : 'OK',
    hasFailures ? '#d97706' : '#15803d',
    hasFailures
      ? `Downloads finished. Done ${completed}. Failed ${failed}.`
      : `Downloads finished. Done ${completed}.`
  ).catch(() => {});
  downloadBadgeClearTimer = setTimeout(() => {
    setDownloadBadge('', '#00000000', 'Sora All In One').catch(() => {});
    downloadBadgeClearTimer = null;
  }, 15000);
}

function prepareDeleteRunState(options = {}) {
  deleteRunState = {
    ...createEmptyDeleteRunState(),
    running: true,
    batchLabel: options.batchLabel || 'All',
    skipFailed: options.skipFailed !== false,
    fastMode: options.fastMode !== false,
    total: options.total || 0,
    remaining: options.total || 0,
    startedAt: Date.now(),
    lastMessage: options.lastMessage || 'Preparing delete queue...'
  };
}

function finishDeleteRunState(message, extra = {}) {
  deleteRunState = {
    ...deleteRunState,
    ...extra,
    running: false,
    stopRequested: false,
    currentUrl: null,
    currentTitle: null,
    finishedAt: Date.now(),
    lastMessage: message || deleteRunState.lastMessage
  };
}

function prepareOpenRunState(options = {}) {
  openRunState = {
    ...createEmptyOpenRunState(),
    running: true,
    batchLabel: options.batchLabel || 'All',
    total: options.total || 0,
    remaining: options.total || 0,
    startedAt: Date.now(),
    lastMessage: options.lastMessage || 'Preparing hidden open queue...'
  };
}

function finishOpenRunState(message, extra = {}) {
  openRunState = {
    ...openRunState,
    ...extra,
    running: false,
    stopRequested: false,
    currentUrl: null,
    finishedAt: Date.now(),
    lastMessage: message || openRunState.lastMessage
  };
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function normalizeUrl(raw) {
  if (!raw || typeof raw !== 'string') return null;

  const cleaned = raw.trim().replace(/^['"]|['"]$/g, '');
  if (!cleaned || cleaned.startsWith('javascript:') || cleaned.startsWith('data:') || cleaned.startsWith('blob:')) {
    return null;
  }

  try {
    return new URL(cleaned).href;
  } catch {
    return null;
  }
}

function isSamePageTarget(rawLeft, rawRight) {
  const left = normalizeUrl(rawLeft);
  const right = normalizeUrl(rawRight);
  if (!left || !right) return false;

  try {
    const leftUrl = new URL(left);
    const rightUrl = new URL(right);
    const leftPath = leftUrl.pathname.replace(/\/+$/, '') || '/';
    const rightPath = rightUrl.pathname.replace(/\/+$/, '') || '/';
    return leftUrl.origin === rightUrl.origin && leftPath === rightPath;
  } catch {
    return left === right;
  }
}

function stripEdgePunctuation(value) {
  return String(value || '')
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .replace(/^[\s"'`([{<]+/, '')
    .replace(/[\s"'`)\]}>.,;:!?]+$/, '');
}

function extractFacebookSourceUrl(value) {
  const cleaned = stripEdgePunctuation(value);
  if (!cleaned) return '';

  const match = cleaned.match(/(?:(?:https?:\/\/)?(?:[\w-]+\.)?(?:facebook\.com|fb\.watch)\/[^\s<>'"]+)/i);
  if (!match?.[0]) return '';

  let url = stripEdgePunctuation(match[0]);
  if (!/^https?:\/\//i.test(url)) {
    url = `https://${url.replace(/^\/+/, '')}`;
  }

  try {
    const parsed = new URL(url);
    const host = parsed.hostname.toLowerCase();
    if (
      host !== 'fb.watch' &&
      !host.endsWith('.fb.watch') &&
      host !== 'facebook.com' &&
      !host.endsWith('.facebook.com')
    ) {
      return '';
    }
    return parsed.toString();
  } catch {
    return '';
  }
}

function extractFacebookNumericId(raw) {
  const url = extractFacebookSourceUrl(raw);
  if (!url) return '';

  try {
    const parsed = new URL(url);
    const path = (parsed.pathname || '').replace(/\/+$/, '');
    const reelMatch = path.match(/\/reel\/(\d+)/i);
    if (reelMatch?.[1]) return reelMatch[1];

    if (/\/watch$/i.test(path)) {
      const watchId = stripEdgePunctuation(parsed.searchParams.get('v') || '');
      if (/^\d+$/.test(watchId)) return watchId;
    }

    const videoMatch = path.match(/\/videos\/(?:[^/]+\/)?(\d+)(?:\/|$)/i);
    if (videoMatch?.[1]) return videoMatch[1];

    const shareMatch = path.match(/\/share\/(?:r|v)\/([^/?#]+)/i);
    if (shareMatch?.[1]) return shareMatch[1];
   } catch {}

  return '';
}

function hashString(value) {
  let hash = 0;
  const text = String(value || '');
  for (let index = 0; index < text.length; index += 1) {
    hash = ((hash << 5) - hash) + text.charCodeAt(index);
    hash |= 0;
  }
  return Math.abs(hash >>> 0).toString(36);
}

function buildFacebookDownloadId(raw) {
  const exactId = extractFacebookNumericId(raw);
  if (exactId) return `facebook_${exactId}`;
  return `facebook_${hashString(extractFacebookSourceUrl(raw) || raw)}`;
}

function sanitizeDownloadFilename(value, fallback = 'video.mp4') {
  const cleaned = String(value || '')
    .replace(/[\\/:*?"<>|]+/g, '_')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^[._\s]+|[._\s]+$/g, '');
  const base = cleaned || fallback;
  return /\.mp4$/i.test(base) ? base : `${base}.mp4`;
}

async function resolveFacebookDownloadCandidates(job) {
  const sourceUrl = extractFacebookSourceUrl(job?.source || '');
  if (!sourceUrl) {
    throw new Error('No supported Facebook URL found for this job.');
  }

  let lastError = '';

  for (const baseUrl of FACEBOOK_RESOLVE_BASE_URLS) {
    const endpoint = `${baseUrl.replace(/\/+$/, '')}/facebook-resolve`;
    try {
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          url: sourceUrl,
          quality: 'auto'
        })
      });

      const payload = await response.json().catch(() => ({}));
      if (!response.ok || payload?.ok === false) {
        lastError = typeof payload?.message === 'string' && payload.message.trim()
          ? payload.message.trim()
          : `HTTP ${response.status}`;
        continue;
      }

      const candidates = Array.isArray(payload?.candidates) ? payload.candidates : [];
      const urls = candidates
        .map(candidate => (typeof candidate?.url === 'string' ? candidate.url.trim() : ''))
        .filter(Boolean);

      if (!urls.length) {
        lastError = 'Facebook resolver returned no direct video URLs.';
        continue;
      }

      const preferredFilename = sanitizeDownloadFilename(
        payload?.preferred_filename || payload?.metadata?.title || job.id,
        `${job.id}.mp4`
      );

      job.downloadFilename = `facebook/${preferredFilename}`;
      job.resolvedSource = typeof payload?.normalized_url === 'string' && payload.normalized_url.trim()
        ? payload.normalized_url.trim()
        : sourceUrl;
      return urls;
    } catch (error) {
      lastError = error?.message || 'Facebook resolver request failed.';
    }
  }

  throw new Error(lastError || 'Could not reach the Facebook resolver server.');
}

function extractSoraVideoId(value) {
  const cleaned = stripEdgePunctuation(value);
  if (!cleaned) return '';

  const patterns = [
    /api\/proxy\/video\/([A-Za-z0-9_-]{8,})/i,
    /\/videos?\/([A-Za-z0-9_-]{8,})/i,
    /\/watch\/([A-Za-z0-9_-]{8,})/i,
    /\/p\/(s_[A-Za-z0-9_-]{8,})/i,
    /\/d\/(gen_[A-Za-z0-9_-]{8,})/i,
    /\b(sora_[A-Za-z0-9]+)\b/i,
    /\b(s_[A-Za-z0-9_-]{8,})\b/i,
    /\b(gen_[A-Za-z0-9_-]{8,})\b/i
  ];

  for (const pattern of patterns) {
    const match = cleaned.match(pattern);
    if (match?.[1]) return match[1];
  }

  try {
    const parsed = new URL(cleaned);
    const parts = parsed.pathname.split('/').filter(Boolean);
    for (let index = parts.length - 1; index >= 0; index -= 1) {
      const candidate = stripEdgePunctuation(parts[index]);
      const previous = stripEdgePunctuation(parts[index - 1] || '');
      if (previous === 'd' && !/^gen_[A-Za-z0-9_-]{8,}$/i.test(candidate)) continue;
      if (previous === 'p' && !/^s_[A-Za-z0-9_-]{8,}$/i.test(candidate)) continue;
      if (/^[A-Za-z0-9_-]{8,}$/.test(candidate) && !['video', 'videos', 'watch', 'd', 'p'].includes(candidate)) {
        return candidate;
      }
    }

    for (const name of ['id', 'video', 'videoId', 'vid']) {
      const candidate = stripEdgePunctuation(parsed.searchParams.get(name) || '');
      if (/^[A-Za-z0-9_-]{8,}$/.test(candidate)) return candidate;
    }
  } catch {}

  if (/^[A-Za-z0-9_-]{8,}$/.test(cleaned) && !/^https?:/i.test(cleaned)) {
    return cleaned;
  }

  return '';
}

function isPublishedSoraVideoId(value) {
  return /^s_[A-Za-z0-9_-]{8,}$/i.test(String(value || '').trim());
}

function buildSoravdlProxyUrl(id) {
  if (!isPublishedSoraVideoId(id)) return '';
  return `${SORAVDL_PROXY_BASE_URL}${encodeURIComponent(id)}`;
}

function buildSoravdlPublicProxyUrl(id) {
  if (!isPublishedSoraVideoId(id)) return '';
  return `${SORAVDL_PROXY_PUBLIC_BASE_URL}${encodeURIComponent(id)}`;
}

function buildSoradownStreamUrl(id) {
  if (!isPublishedSoraVideoId(id)) return '';
  return `${SORADOWN_STREAM_BASE_URL}${encodeURIComponent(id)}`;
}

function buildDownloadProxyCandidates(id) {
  if (!isPublishedSoraVideoId(id)) return [];
  return [...new Set([
    buildSoravdlProxyUrl(id),
    buildSoravdlPublicProxyUrl(id),
    buildSoradownStreamUrl(id)
  ].filter(Boolean))];
}

function isLikelyDirectMediaUrl(raw, options = {}) {
  const { allowStreaming = true, allowUnknownVideo = false } = options;
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    if (!/^https?:$/i.test(parsed.protocol)) return false;
    const full = `${parsed.pathname}${parsed.search}`.toLowerCase();
    if (/\.(mp4|webm|mov|m4v)(?:$|[?#])/i.test(full)) return true;
    if (allowStreaming && /\.(m3u8|mpd)(?:$|[?#])/i.test(full)) return true;
    if (allowUnknownVideo && parsed.origin !== 'https://sora.chatgpt.com') return true;
    return false;
  } catch {
    return false;
  }
}

async function buildDownloadJobs(rawUrls, options = {}) {
  const seenKeys = new Set();
  const downloadedIds = new Set(await getDownloadedVideoIds());
  const jobs = [];
  let invalidCount = 0;
  let duplicateCount = 0;
  let downloadedBeforeCount = 0;
  const skipDownloadedHistory = options.skipDownloadedHistory !== false;

  for (const rawUrl of Array.isArray(rawUrls) ? rawUrls : []) {
    const normalizedSource = normalizeUrl(rawUrl) || rawUrl;
    const facebookUrl = extractFacebookSourceUrl(normalizedSource);
    if (facebookUrl) {
      const key = `facebook:${facebookUrl.toLowerCase()}`;
      if (seenKeys.has(key)) {
        duplicateCount += 1;
        continue;
      }

      seenKeys.add(key);
      jobs.push({
        index: jobs.length + 1,
        kind: 'facebook',
        id: buildFacebookDownloadId(facebookUrl),
        source: facebookUrl,
        pageUrl: null,
        directUrl: null,
        proxyCandidates: [],
        downloadFolder: 'facebook'
      });
      continue;
    }

    const id = extractSoraVideoId(rawUrl);
    if (!id || !isPublishedSoraVideoId(id)) {
      invalidCount += 1;
      continue;
    }

    const key = `sora:${id.toLowerCase()}`;
    if (seenKeys.has(key)) {
      duplicateCount += 1;
      continue;
    }

    if (skipDownloadedHistory && downloadedIds.has(id)) {
      downloadedBeforeCount += 1;
      continue;
    }

    seenKeys.add(key);
    jobs.push({
      index: jobs.length + 1,
      kind: 'sora',
      id,
      source: normalizedSource,
      pageUrl: isSoraPublishedUrl(normalizedSource) ? normalizedSource : null,
      directUrl: isLikelyDirectMediaUrl(normalizedSource) ? normalizedSource : null,
      proxyCandidates: buildDownloadProxyCandidates(id),
      downloadFolder: 'sora'
    });
  }

  return {
    jobs,
    invalidCount,
    duplicateCount,
    downloadedBeforeCount
  };
}

async function startBulkDownload(rawUrls, options = {}) {
  const { jobs, invalidCount, duplicateCount, downloadedBeforeCount } = await buildDownloadJobs(rawUrls, options);

  if (manualRunState.running || deleteRunState.running || autoPostRunning || openRunState.running || downloadRunState.running) {
    return {
      ok: false,
      message: 'Another queue is already running. Wait until it finishes.',
      started: 0,
      invalidCount,
      duplicateCount,
      downloadedBeforeCount,
      failedCount: 0,
      state: getDownloadRunStatus()
    };
  }

  if (!jobs.length) {
    finishDownloadRunState(
      downloadedBeforeCount
        ? `No new video URLs found to download. Skipped ${downloadedBeforeCount} previously downloaded Sora item(s).`
        : 'No valid Sora or Facebook video URLs found to download.',
      {
      total: 0,
      done: 0,
      started: 0,
      completed: 0,
      failed: 0,
      remaining: 0,
      invalidCount,
      duplicateCount,
      downloadedBeforeCount,
      results: []
      }
    );
    return {
      ok: false,
      message: downloadedBeforeCount
        ? `No new video URLs found to download. Skipped ${downloadedBeforeCount} previously downloaded Sora item(s).`
        : 'No valid Sora or Facebook video URLs found to download.',
      started: 0,
      invalidCount,
      duplicateCount,
      downloadedBeforeCount,
      failedCount: 0
    };
  }

  activeDownloadItems.clear();
  pendingDownloadJobs = jobs.slice();
  prepareDownloadRunState({
    total: jobs.length,
    invalidCount,
    duplicateCount,
    downloadedBeforeCount,
    lastMessage: `Preparing ${jobs.length} download(s)...`
  });
  markDownloadBadgeRunning(jobs.length);
  await processNextDownloadJob();
  const state = getDownloadRunStatus();
  return {
    ok: state.running || state.done > 0,
    message: state.running
      ? `Started download queue for ${jobs.length} item(s).`
      : state.lastMessage,
    started: state.started || 0,
    invalidCount,
    duplicateCount,
    downloadedBeforeCount,
    failedCount: state.failed || 0,
    state
  };
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

function isSoraDraftsPageUrl(raw) {
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    return parsed.origin === 'https://sora.chatgpt.com' && /^\/drafts\/?$/i.test(parsed.pathname);
  } catch {
    return false;
  }
}

function isSoraProfilePageUrl(raw) {
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    return parsed.origin === 'https://sora.chatgpt.com' && /^\/profile\/?$/i.test(parsed.pathname);
  } catch {
    return false;
  }
}

function isSoraListPageUrl(raw) {
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    const parsed = new URL(url);
    return parsed.origin === 'https://sora.chatgpt.com' && !isSoraProjectUrl(url);
  } catch {
    return false;
  }
}

function isSoraDomainUrl(raw) {
  const url = normalizeUrl(raw);
  if (!url) return false;

  try {
    return new URL(url).origin === 'https://sora.chatgpt.com';
  } catch {
    return false;
  }
}

async function getActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab || null;
}

async function getWorkerTab() {
  if (workerTabId) {
    try {
      const existing = await chrome.tabs.get(workerTabId);
      const existingWindow = existing?.windowId ? await chrome.windows.get(existing.windowId) : null;
      if (existingWindow?.id) {
        workerWindowId = null;
        return existing;
      }
    } catch {}
    workerTabId = null;
  }

  if (workerWindowId) {
    try {
      await chrome.windows.remove(workerWindowId);
    } catch {}
    workerWindowId = null;
    workerTabId = null;
  }

  const activeTab = await getActiveTab();
  const fallbackTab = await chrome.tabs.create({
    url: WORKER_START_URL,
    active: false,
    windowId: activeTab?.windowId
  });
  workerWindowId = null;
  workerTabId = fallbackTab?.id || null;
  if (!fallbackTab?.id) throw new Error('Could not create a background worker tab.');
  return fallbackTab;
}

async function closeWorkerTab() {
  if (workerWindowId) {
    try {
      await chrome.windows.remove(workerWindowId);
    } catch {}
    workerWindowId = null;
    workerTabId = null;
    return;
  }

  if (!workerTabId) return;
  try {
    await chrome.tabs.remove(workerTabId);
  } catch {}
  workerTabId = null;
}

async function openParallelWorkerTab(targetUrl) {
  const activeTab = await getActiveTab();
  const tab = await chrome.tabs.create({
    url: targetUrl || WORKER_START_URL,
    active: false,
    windowId: activeTab?.windowId
  });
  if (!tab?.id) throw new Error('Could not create a parallel background worker tab.');
  parallelWorkerTabIds.add(tab.id);
  return tab.id;
}

async function closeParallelWorkerTab(tabId) {
  if (!tabId) return;
  try {
    await chrome.tabs.remove(tabId);
  } catch {}
  parallelWorkerTabIds.delete(tabId);
}

async function closeParallelWorkerTabs() {
  if (!parallelWorkerTabIds.size) return;
  const tabIds = Array.from(parallelWorkerTabIds);
  await Promise.all(tabIds.map(tabId => closeParallelWorkerTab(tabId)));
}

function getQueueConcurrency(total, preferred) {
  const limit = Number(preferred);
  if (!Number.isFinite(limit) || limit <= 1) return 1;
  return Math.max(1, Math.min(Math.floor(limit), Math.max(1, total || 1)));
}

function getPostQueueConcurrencyForUrl(raw, total = 1) {
  return POST_QUEUE_CONCURRENCY;
}

function getDeleteQueueConcurrencyForUrl(raw, total = 1) {
  return DELETE_QUEUE_CONCURRENCY;
}

async function getSavedProjectUrls() {
  const saved = await chrome.storage.local.get(STORAGE_KEY);
  const items = saved?.[STORAGE_KEY] || [];
  return items
    .map(item => normalizeUrl(item?.url || ''))
    .filter(isSoraProjectUrl);
}

async function getSavedDeleteScanData() {
  const saved = await chrome.storage.local.get(DELETE_SCAN_KEY);
  const scan = saved?.[DELETE_SCAN_KEY] || {};
  return {
    pageUrl: normalizeUrl(scan.pageUrl || ''),
    items: Array.isArray(scan.items) ? scan.items : []
  };
}

async function getSavedDeleteTargetUrls() {
  const scan = await getSavedDeleteScanData();
  return uniqueUrls(scan.items.map(item => item?.url || '')).filter(isSoraProjectUrl);
}

async function removeSavedDeleteTargetUrls(urlsToRemove = []) {
  const scan = await getSavedDeleteScanData();
  const removeSet = new Set(uniqueUrls(urlsToRemove));
  const nextItems = (scan.items || []).filter(item => {
    const url = normalizeUrl(item?.url || '');
    return url && !removeSet.has(url);
  });

  await chrome.storage.local.set({
    [DELETE_SCAN_KEY]: {
      pageUrl: scan.pageUrl || null,
      items: nextItems
    }
  });
}

async function getSavedDraftUrls() {
  const urls = await getSavedProjectUrls();
  return urls.filter(isSoraDraftUrl);
}

async function getDownloadedVideoIds() {
  const saved = await chrome.storage.local.get(DOWNLOAD_HISTORY_KEY);
  const items = Array.isArray(saved?.[DOWNLOAD_HISTORY_KEY]) ? saved[DOWNLOAD_HISTORY_KEY] : [];
  const seen = new Set();
  const result = [];
  for (const raw of items) {
    const id = extractSoraVideoId(raw);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    result.push(id);
  }
  return result;
}

async function setDownloadedVideoIds(ids = []) {
  const seen = new Set();
  const result = [];
  for (const raw of Array.isArray(ids) ? ids : []) {
    const id = extractSoraVideoId(raw);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    result.push(id);
  }
  await chrome.storage.local.set({
    [DOWNLOAD_HISTORY_KEY]: result
  });
}

async function addDownloadedVideoIds(ids = []) {
  const existing = await getDownloadedVideoIds();
  await setDownloadedVideoIds([...existing, ...ids]);
}

async function getFailedDownloadUrls() {
  const saved = await chrome.storage.local.get(FAILED_DOWNLOAD_URLS_KEY);
  const items = Array.isArray(saved?.[FAILED_DOWNLOAD_URLS_KEY]) ? saved[FAILED_DOWNLOAD_URLS_KEY] : [];
  const seen = new Set();
  const result = [];
  for (const raw of items) {
    const value = typeof raw === 'string' ? raw.trim() : '';
    if (!value || seen.has(value)) continue;
    seen.add(value);
    result.push(value);
  }
  return result;
}

async function setFailedDownloadUrls(urls = []) {
  const seen = new Set();
  const result = [];
  for (const raw of Array.isArray(urls) ? urls : []) {
    const value = typeof raw === 'string' ? raw.trim() : '';
    if (!value || seen.has(value)) continue;
    seen.add(value);
    result.push(value);
  }
  await chrome.storage.local.set({
    [FAILED_DOWNLOAD_URLS_KEY]: result
  });
}

async function getDownloadMediaCache() {
  const saved = await chrome.storage.local.get(DOWNLOAD_MEDIA_CACHE_KEY);
  const cache = saved?.[DOWNLOAD_MEDIA_CACHE_KEY];
  return cache && typeof cache === 'object' ? cache : {};
}

async function getCachedDownloadMediaUrl(pageUrl) {
  const normalized = normalizeUrl(pageUrl);
  if (!normalized) return null;
  const cache = await getDownloadMediaCache();
  const raw = typeof cache[normalized] === 'string' ? cache[normalized] : '';
  return isLikelyDirectMediaUrl(raw, { allowStreaming: true, allowUnknownVideo: true }) ? raw : null;
}

async function setCachedDownloadMediaUrl(pageUrl, mediaUrl) {
  const normalizedPageUrl = normalizeUrl(pageUrl);
  const normalizedMediaUrl = normalizeUrl(mediaUrl);
  if (!normalizedPageUrl || !isLikelyDirectMediaUrl(normalizedMediaUrl, { allowStreaming: true, allowUnknownVideo: true })) {
    return;
  }
  const cache = await getDownloadMediaCache();
  cache[normalizedPageUrl] = normalizedMediaUrl;
  await chrome.storage.local.set({ [DOWNLOAD_MEDIA_CACHE_KEY]: cache });
}

async function addFailedDownloadUrls(urls = []) {
  const existing = await getFailedDownloadUrls();
  await setFailedDownloadUrls([...existing, ...urls]);
}

async function removeFailedDownloadUrls(urls = []) {
  if (!Array.isArray(urls) || !urls.length) return;
  const removeSet = new Set(urls.map(raw => (typeof raw === 'string' ? raw.trim() : '')).filter(Boolean));
  const existing = await getFailedDownloadUrls();
  await setFailedDownloadUrls(existing.filter(url => !removeSet.has(url)));
}

async function isAutoPostEnabled() {
  const saved = await chrome.storage.local.get(AUTO_POST_KEY);
  return saved?.[AUTO_POST_KEY] === true;
}

async function getProcessedDraftUrls() {
  const saved = await chrome.storage.local.get(PROCESSED_DRAFTS_KEY);
  const items = Array.isArray(saved?.[PROCESSED_DRAFTS_KEY]) ? saved[PROCESSED_DRAFTS_KEY] : [];
  return uniqueUrls(items).filter(isSoraDraftUrl);
}

async function setProcessedDraftUrls(urls) {
  await chrome.storage.local.set({
    [PROCESSED_DRAFTS_KEY]: uniqueUrls(urls).filter(isSoraDraftUrl)
  });
}

async function addProcessedDraftUrls(urls) {
  const existing = await getProcessedDraftUrls();
  await setProcessedDraftUrls([...existing, ...urls]);
}

function uniqueUrls(urls) {
  const seen = new Set();
  const result = [];
  for (const raw of urls) {
    const url = normalizeUrl(raw);
    if (!url || seen.has(url)) continue;
    seen.add(url);
    result.push(url);
  }
  return result;
}

async function filterProtectedDownloadRetryUrls(urls = []) {
  const failedDownloadUrls = await getFailedDownloadUrls();
  const protectedSet = new Set(
    failedDownloadUrls
      .map(raw => normalizeUrl(raw))
      .filter(isSoraProjectUrl)
  );

  if (!protectedSet.size) return uniqueUrls(urls);
  return uniqueUrls(urls).filter(url => !protectedSet.has(url));
}

function normalizeBatchLimit(rawLimit) {
  const value = Number(rawLimit);
  if (!Number.isFinite(value) || value <= 0) return null;
  return Math.floor(value);
}

async function resolveTargetUrl(preferredUrl) {
  if (isSoraProjectUrl(preferredUrl)) return normalizeUrl(preferredUrl);

  const activeTab = await getActiveTab();
  if (isSoraProjectUrl(activeTab?.url || '')) return normalizeUrl(activeTab.url);

  const savedUrls = await getSavedProjectUrls();
  return savedUrls.find(isSoraDraftUrl) || savedUrls[0] || null;
}

async function resolveDraftTargets(preferredUrls = []) {
  const normalizedPreferred = Array.isArray(preferredUrls)
    ? uniqueUrls(preferredUrls).filter(isSoraDraftUrl)
    : [];

  if (normalizedPreferred.length) return normalizedPreferred;

  const activeTab = await getActiveTab();
  const activeDraft = normalizeUrl(activeTab?.url || '');
  if (isSoraDraftUrl(activeDraft)) return [activeDraft];

  const savedDrafts = await getSavedDraftUrls();
  return uniqueUrls(savedDrafts);
}

async function resolveDeleteTargetPageUrl(preferredUrl) {
  if (isSoraListPageUrl(preferredUrl)) return normalizeUrl(preferredUrl);

  const activeTab = await getActiveTab();
  if (isSoraListPageUrl(activeTab?.url || '')) return normalizeUrl(activeTab.url);

  const saved = await getSavedDeleteScanData();
  if (isSoraListPageUrl(saved.pageUrl || '')) return saved.pageUrl;

  return null;
}

async function resolveDeleteTargetUrls(preferredUrls = []) {
  const normalizedPreferred = Array.isArray(preferredUrls)
    ? uniqueUrls(preferredUrls).filter(isSoraProjectUrl)
    : [];

  if (normalizedPreferred.length) return filterProtectedDownloadRetryUrls(normalizedPreferred);
  const savedDeleteUrls = await getSavedDeleteTargetUrls();
  return filterProtectedDownloadRetryUrls(savedDeleteUrls);
}

async function resolveHiddenOpenTargetUrls(preferredUrls = []) {
  const normalizedPreferred = Array.isArray(preferredUrls)
    ? uniqueUrls(preferredUrls).filter(isSoraProjectUrl)
    : [];

  if (normalizedPreferred.length) return filterProtectedDownloadRetryUrls(normalizedPreferred);

  const deleteUrls = await getSavedDeleteTargetUrls();
  if (deleteUrls.length) return filterProtectedDownloadRetryUrls(deleteUrls);

  const projectUrls = await getSavedProjectUrls();
  return filterProtectedDownloadRetryUrls(projectUrls.filter(isSoraPublishedUrl));
}

async function getPendingAutoDraftUrls() {
  const [drafts, processed] = await Promise.all([
    getSavedDraftUrls(),
    getProcessedDraftUrls()
  ]);

  const done = new Set(processed);
  return drafts.filter(url => !done.has(url));
}

async function ensureWorkerTabAtUrl(targetUrl) {
  const workerTab = await getWorkerTab();
  if (!workerTab?.id) throw new Error('Could not create a background worker page.');

  if (isSamePageTarget(workerTab.url || '', targetUrl) && workerTab.status === 'complete') {
    return workerTab.id;
  }

  await chrome.tabs.update(workerTab.id, { url: targetUrl, active: false });
  await waitForTabComplete(workerTab.id, targetUrl);
  return workerTab.id;
}

async function waitForTabComplete(tabId, targetUrl, timeoutMs = 20000) {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    try {
      const tab = await chrome.tabs.get(tabId);
      if (isSamePageTarget(tab?.url || '', targetUrl) && tab.status === 'complete') {
        return;
      }
    } catch {}

    await sleep(120);
  }

  throw new Error('Timed out waiting for Sora page to load.');
}

async function refreshTabIfSora(tabId) {
  if (!tabId) return false;

  try {
    const tab = await chrome.tabs.get(tabId);
    if (!isSoraDomainUrl(tab?.url || '')) return false;
    await chrome.tabs.reload(tabId);
    return true;
  } catch {
    return false;
  }
}

async function navigateTabToProfileIfSora(tabId) {
  if (!tabId) return false;

  try {
    const tab = await chrome.tabs.get(tabId);
    if (!isSoraDomainUrl(tab?.url || '') || isSoraProfilePageUrl(tab?.url || '')) return false;
    await sleep(POST_PROFILE_REDIRECT_DELAY_MS);
    await chrome.tabs.update(tabId, { url: SORA_PROFILE_URL });
    return true;
  } catch {
    return false;
  }
}

async function sendWorkerMessage(tabId, payload, attempts = 8) {
  let lastError = null;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await chrome.tabs.sendMessage(tabId, payload);
    } catch (error) {
      lastError = error;
      await sleep(700);
    }
  }

  throw lastError || new Error('Could not contact the worker page.');
}

async function tryResolveDownloadMediaOnTab(tabId, targetUrl, options = {}) {
  const attempts = Number(options.attempts) > 0 ? Number(options.attempts) : 4;
  let lastResult = null;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const result = await sendWorkerMessage(tabId, {
        action: 'resolve_downloadable_media',
        timeoutMs: DOWNLOAD_MEDIA_TIMEOUT_MS
      }, 4);
      lastResult = result;
      if (result?.ok && isLikelyDirectMediaUrl(result.mediaUrl, { allowStreaming: true, allowUnknownVideo: true })) {
        return result;
      }
    } catch (error) {
      lastResult = {
        ok: false,
        mediaUrl: null,
        message: error?.message || `Could not resolve media for ${targetUrl}.`
      };
    }

    await sleep(DOWNLOAD_MEDIA_RETRY_DELAY_MS);
  }

  return lastResult || {
    ok: false,
    mediaUrl: null,
    message: `Could not resolve media for ${targetUrl}.`
  };
}

async function tryResolveDownloadMediaOnTabWithRefreshRetry(tabId, targetUrl) {
  const firstResult = await tryResolveDownloadMediaOnTab(tabId, targetUrl);
  if (firstResult?.ok && firstResult.mediaUrl) return firstResult;

  try {
    await chrome.tabs.reload(tabId);
    await waitForTabComplete(tabId, targetUrl);
    await sleep(DOWNLOAD_MEDIA_SETTLE_DELAY_MS);
    const retryResult = await tryResolveDownloadMediaOnTab(tabId, targetUrl);
    if (retryResult?.ok && retryResult.mediaUrl) return retryResult;
    return retryResult || firstResult || {
      ok: false,
      mediaUrl: null,
      message: `Could not resolve media for ${targetUrl} after refresh.`
    };
  } catch (error) {
    return {
      ...(firstResult || {}),
      ok: false,
      mediaUrl: null,
      message: error?.message || firstResult?.message || `Could not resolve media for ${targetUrl} after refresh.`
    };
  }
}

async function maybeFinishDownloadQueue() {
  if (!downloadRunState.running) return false;
  if (activeDownloadItems.size || pendingDownloadJobs.length) return false;

  const completed = downloadRunState.completed || 0;
  const failed = downloadRunState.failed || 0;
  const total = downloadRunState.total || completed + failed;
  const message = `Downloads finished. Done ${completed}/${total}. Failed ${failed}.`;

  finishDownloadRunState(message, {
    total,
    done: completed + failed,
    started: downloadRunState.started,
    completed,
    failed,
    remaining: 0,
    invalidCount: downloadRunState.invalidCount,
    duplicateCount: downloadRunState.duplicateCount,
    downloadedBeforeCount: downloadRunState.downloadedBeforeCount,
    results: downloadRunState.results
  });
  markDownloadBadgeFinished(completed, failed);
  await closeParallelWorkerTabs().catch(() => {});
  await closeWorkerTab().catch(() => {});
  return true;
}

async function resolveDownloadCandidatesForJob(job) {
  if (job?.kind === 'facebook') {
    return resolveFacebookDownloadCandidates(job);
  }

  if (Array.isArray(job.proxyCandidates) && job.proxyCandidates.length) {
    return job.proxyCandidates.slice();
  }

  if (job.proxyUrl) return [job.proxyUrl];

  if (job.pageUrl) {
    const cachedMediaUrl = await getCachedDownloadMediaUrl(job.pageUrl);
    if (cachedMediaUrl) return [cachedMediaUrl];
  }

  if (job.pageUrl) {
    let tabId = null;
    try {
      tabId = await openParallelWorkerTab(job.pageUrl);
      await waitForTabComplete(tabId, job.pageUrl);
      await sleep(DOWNLOAD_MEDIA_SETTLE_DELAY_MS);
      const resolved = await tryResolveDownloadMediaOnTabWithRefreshRetry(tabId, job.pageUrl);
      if (resolved?.ok && isLikelyDirectMediaUrl(resolved.mediaUrl, { allowStreaming: true, allowUnknownVideo: true })) {
        await setCachedDownloadMediaUrl(job.pageUrl, resolved.mediaUrl).catch(() => {});
        return [resolved.mediaUrl];
      }
    } finally {
      await closeParallelWorkerTab(tabId);
    }
  }

  if (isLikelyDirectMediaUrl(job.directUrl, { allowStreaming: true, allowUnknownVideo: true })) {
    return [job.directUrl];
  }

  return [];
}

async function failDownloadJob(job, message) {
  const failed = (downloadRunState.failed || 0) + 1;
  const done = (downloadRunState.done || 0) + 1;
  downloadRunState = {
    ...downloadRunState,
    failed,
    done,
    remaining: Math.max((downloadRunState.total || 0) - done, 0),
    results: [
      ...downloadRunState.results,
      {
        id: job.id,
        ok: false,
        message
      }
    ].slice(-10),
    lastMessage: `Failed ${failed}/${downloadRunState.total || 0}: ${job.id}`
  };
  await addFailedDownloadUrls([job.source]).catch(() => {});
}

async function startResolvedDownloadAttempt(job, downloadUrl, remainingCandidates = [], attemptIndex = 1, totalAttempts = 1) {
  try {
    const downloadId = await chrome.downloads.download({
      url: downloadUrl,
      filename: job.downloadFilename || `${job.downloadFolder || 'sora'}/${job.id}.mp4`,
      conflictAction: 'uniquify',
      saveAs: false
    });

    activeDownloadItems.set(downloadId, {
      id: job.id,
      index: job.index,
      source: job.source,
      remainingCandidates: remainingCandidates.slice(),
      attemptIndex,
      totalAttempts,
      downloadUrl,
      kind: job.kind || 'sora'
    });

    downloadRunState = {
      ...downloadRunState,
      started: job.__downloadStarted
        ? (downloadRunState.started || 0)
        : (downloadRunState.started || 0) + 1,
      currentIndex: job.index,
      currentId: job.id,
      lastMessage: totalAttempts > 1
        ? `Downloading ${job.index}/${downloadRunState.total || 0}: ${job.id} (${attemptIndex}/${totalAttempts})`
        : `Downloading ${job.index}/${downloadRunState.total || 0}: ${job.id}`
    };

    job.__downloadStarted = true;
    return true;
  } catch (error) {
    if (remainingCandidates.length) {
      const [nextUrl, ...nextRemaining] = remainingCandidates;
      const nextAttemptIndex = attemptIndex + 1;
      downloadRunState = {
        ...downloadRunState,
        currentIndex: job.index,
        currentId: job.id,
        lastMessage: `Primary download failed. Switching to backup ${nextAttemptIndex}/${totalAttempts}: ${job.id}`
      };
      return startResolvedDownloadAttempt(job, nextUrl, nextRemaining, nextAttemptIndex, totalAttempts);
    }

    await failDownloadJob(job, error?.message || 'Download failed.');
    return false;
  }
}

async function startSingleDownloadJob(job) {
  downloadRunState = {
    ...downloadRunState,
    currentIndex: job.index || ((downloadRunState.done || 0) + 1),
    currentId: job.id,
    lastMessage: `Preparing download ${job.index || ((downloadRunState.done || 0) + 1)}/${downloadRunState.total || 0}: ${job.id}`
  };

  try {
    const downloadCandidates = await resolveDownloadCandidatesForJob(job);
    if (!downloadCandidates.length) {
      await failDownloadJob(
        job,
        job?.kind === 'facebook'
          ? 'Could not resolve a direct Facebook video download URL.'
          : 'Could not build a soravdl proxy download URL for this Sora video ID.'
      );
      return;
    }

    const [downloadUrl, ...remainingCandidates] = downloadCandidates;
    await startResolvedDownloadAttempt(
      job,
      downloadUrl,
      remainingCandidates,
      1,
      downloadCandidates.length
    );
  } catch (error) {
    await failDownloadJob(job, error?.message || 'Download failed.');
  }
}

async function processNextDownloadJob() {
  if (!downloadRunState.running || downloadJobStarterBusy) return false;
  if (!pendingDownloadJobs.length) {
    await maybeFinishDownloadQueue();
    return false;
  }

  downloadJobStarterBusy = true;

  try {
    const jobs = pendingDownloadJobs.splice(0);
    await Promise.allSettled(jobs.map(job => startSingleDownloadJob(job)));
    await maybeFinishDownloadQueue();
    return true;
  } finally {
    downloadJobStarterBusy = false;
  }

  return false;
}

async function tryDeleteProjectOnTab(tabId, targetUrl, options = {}) {
  const { silent = false, fastMode = false } = options;
  let lastResult = null;
  const attempts = fastMode ? 6 : 8;
  const retryDelay = fastMode ? FAST_DELETE_RETRY_DELAY_MS : NORMAL_DELETE_RETRY_DELAY_MS;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const result = await sendWorkerMessage(tabId, {
        action: 'delete_current_project',
        silent,
        fastMode
      }, fastMode ? 4 : 6);
      lastResult = result;
      if (result?.ok) return result;
    } catch {}

    await sleep(retryDelay);
  }

  return lastResult || {
    ok: false,
    message: `Opened ${targetUrl}, but Delete action was not found.`
  };
}

async function tryDeleteProjectOnTabWithRefreshRetry(tabId, targetUrl, options = {}) {
  const { silent = false, fastMode = false } = options;
  const firstResult = await tryDeleteProjectOnTab(tabId, targetUrl, { silent, fastMode });
  if (firstResult?.ok) return firstResult;

  try {
    await chrome.tabs.reload(tabId);
    await waitForTabComplete(tabId, targetUrl);
    await sleep(Math.max(
      fastMode ? FAST_PROJECT_ACTION_DELAY_MS : NORMAL_PROJECT_ACTION_DELAY_MS,
      DELETE_REFRESH_RETRY_SETTLE_DELAY_MS
    ));
    const retryResult = await tryDeleteProjectOnTab(tabId, targetUrl, { silent, fastMode });
    if (retryResult?.ok) {
      return {
        ...retryResult,
        message: retryResult.message || 'Deleted after refreshing the tab.'
      };
    }
    return retryResult || {
      ...firstResult,
      message: firstResult?.message || `Opened ${targetUrl}, refreshed it once, but Delete still failed.`
    };
  } catch (error) {
    return {
      ...(firstResult || {}),
      ok: false,
      message: error?.message || firstResult?.message || `Opened ${targetUrl}, refreshed it once, but Delete still failed.`
    };
  }
}

async function tryPostDraftOnTab(tabId, targetUrl, options = {}) {
  const {
    silent = false,
    fastMode = false,
    flowAttempts = 3,
    controlsTimeoutMs = null,
    messageAttempts = 5,
    prepareDraftBeforePost = true
  } = options;
  let lastError = null;

  for (let attempt = 0; attempt < flowAttempts; attempt += 1) {
    try {
      const result = await sendWorkerMessage(tabId, {
        action: 'post_with_draft',
        silent,
        fastMode,
        attempts: flowAttempts,
        controlsTimeoutMs,
        prepareDraftBeforePost
      }, messageAttempts);
      if (result?.ok) return result;
      lastError = new Error(result?.message || 'Post action not found.');
    } catch (error) {
      lastError = error;
    }

    await sleep(POST_RETRY_DELAY_MS);
  }

  return {
    ok: false,
    message: lastError?.message || `Opened ${targetUrl}, but Post action was not found.`
  };
}

async function tryPostDraftOnTabWithRefreshRetry(tabId, targetUrl, options = {}) {
  const {
    silent = false,
    fastMode = false,
    flowAttempts = 3,
    controlsTimeoutMs = null,
    messageAttempts = 5,
    prepareDraftBeforePost = true
  } = options;
  const firstResult = await tryPostDraftOnTab(tabId, targetUrl, {
    silent,
    fastMode,
    flowAttempts,
    controlsTimeoutMs,
    messageAttempts,
    prepareDraftBeforePost
  });
  if (firstResult?.ok) return firstResult;

  try {
    await chrome.tabs.reload(tabId);
    await waitForTabComplete(tabId, targetUrl);
    await sleep(Math.max(POST_PROJECT_ACTION_DELAY_MS, POST_REFRESH_RETRY_SETTLE_DELAY_MS));
    const retryResult = await tryPostDraftOnTab(tabId, targetUrl, {
      silent,
      fastMode,
      flowAttempts,
      controlsTimeoutMs,
      messageAttempts,
      prepareDraftBeforePost
    });
    if (retryResult?.ok) {
      return {
        ...retryResult,
        message: retryResult.message || 'Posted after refreshing the tab.'
      };
    }
    return retryResult || {
      ...firstResult,
      message: firstResult?.message || `Opened ${targetUrl}, refreshed it once, but Post still failed.`
    };
  } catch (error) {
    return {
      ...(firstResult || {}),
      ok: false,
      message: error?.message || firstResult?.message || `Opened ${targetUrl}, refreshed it once, but Post still failed.`
    };
  }
}

async function runDraftQueue(targetUrls, options = {}) {
  const {
    silent = false,
    skipFailed = true,
    limit = null,
    trackState = false,
    mode = 'manual',
    batchLabel = 'All',
    refreshTabId = null,
    parallelWorkers = 1,
    useActiveTabNavigation = false,
    activeTabId = null,
    listPageUrl = null,
    preopenParallelTabs = false
  } = options;

  const allUrls = await resolveDraftTargets(targetUrls);
  const queueUrls = limit ? allUrls.slice(0, limit) : allUrls;

  if (!queueUrls.length) {
    const message = 'No Sora draft URLs found. Scan URLs first.';
    if (trackState) finishRunState(message, { total: 0, done: 0, remaining: 0, results: [] });
    return {
      ok: false,
      message,
      posted: 0,
      failed: 0,
      total: 0,
      results: []
    };
  }

  if (trackState) {
    manualRunState = {
      ...manualRunState,
      mode,
      running: true,
      total: queueUrls.length,
      remaining: queueUrls.length,
      batchLabel,
      skipFailed,
      lastMessage: `Started queue for ${queueUrls.length} draft(s).`
    };
  }

  const results = [];
  let posted = 0;
  let failed = 0;
  let stopped = false;
  let stoppedOnFailure = false;
  const concurrency = getQueueConcurrency(queueUrls.length, parallelWorkers);
  const canUseActiveTabNavigation = Boolean(useActiveTabNavigation && activeTabId && isSoraDraftsPageUrl(listPageUrl));
  const useParallelTabBatch = Boolean(preopenParallelTabs && !canUseActiveTabNavigation && queueUrls.length > 0);

  const navigateTabToUrl = async (tabId, targetUrl) => {
    await chrome.tabs.update(tabId, { url: targetUrl });
    await waitForTabComplete(tabId, targetUrl);
    return tabId;
  };

  const runSingleDraft = async targetUrl => {
    if (canUseActiveTabNavigation) {
      const tabId = await navigateTabToUrl(activeTabId, targetUrl);
      await sleep(POST_PROJECT_ACTION_DELAY_MS);
      return await tryPostDraftOnTab(tabId, targetUrl, { silent, fastMode: true });
    }

    if (concurrency === 1) {
      const tabId = await ensureWorkerTabAtUrl(targetUrl);
      await sleep(POST_PROJECT_ACTION_DELAY_MS);
      return await tryPostDraftOnTab(tabId, targetUrl, { silent, fastMode: true });
    }

    let tabId = null;
    try {
      tabId = await openParallelWorkerTab(targetUrl);
      await waitForTabComplete(tabId, targetUrl);
      await sleep(POST_PROJECT_ACTION_DELAY_MS);
      return await tryPostDraftOnTab(tabId, targetUrl, { silent, fastMode: true });
    } finally {
      await closeParallelWorkerTab(tabId);
    }
  };

  const handleDraftResult = (targetUrl, item) => {
    results.push(item);
    if (item.ok) posted += 1;
    else failed += 1;

    if (trackState) {
      manualRunState = {
        ...manualRunState,
        done: results.length,
        posted,
        failed,
        remaining: Math.max(queueUrls.length - results.length, 0),
        results: results.slice(-10),
        lastMessage: item.ok
          ? `Posted ${posted}/${queueUrls.length} draft(s).`
          : `Failed ${results.length}/${queueUrls.length}: ${targetUrl}`
      };
    }
  };

  if (useParallelTabBatch) {
    const openedTabs = [];

    try {
      for (let index = 0; index < queueUrls.length; index += 1) {
        if (trackState && manualRunState.stopRequested) {
          stopped = true;
          break;
        }

        const targetUrl = queueUrls[index];
        const tabId = await openParallelWorkerTab(targetUrl);
        openedTabs.push({ tabId, targetUrl, index });

        if (trackState) {
          manualRunState = {
            ...manualRunState,
            currentIndex: index + 1,
            currentUrl: targetUrl,
            remaining: Math.max(queueUrls.length - index, 0),
            lastMessage: `Opening draft tab ${index + 1}/${queueUrls.length}...`
          };
        }
      }

      if (!stopped && openedTabs.length) {
        if (trackState) {
          manualRunState = {
            ...manualRunState,
            currentIndex: 0,
            currentUrl: null,
            lastMessage: `Waiting for ${openedTabs.length} draft tab(s) to finish loading...`
          };
        }

        await Promise.all(openedTabs.map(async entry => {
          await waitForTabComplete(entry.tabId, entry.targetUrl);
          await sleep(POST_PARALLEL_TAB_SETTLE_DELAY_MS);
        }));

        if (trackState) {
          manualRunState = {
            ...manualRunState,
            currentIndex: 0,
            currentUrl: null,
            lastMessage: `Posting ${openedTabs.length} loaded draft tab(s)...`
          };
        }

        const batchResults = await Promise.all(openedTabs.map(async entry => {
          let result;
          try {
            if (trackState) {
              manualRunState = {
                ...manualRunState,
                currentIndex: entry.index + 1,
                currentUrl: entry.targetUrl,
                lastMessage: `Posting ${entry.targetUrl}...`
              };
            }
            result = await tryPostDraftOnTabWithRefreshRetry(entry.tabId, entry.targetUrl, {
              silent,
              fastMode: true,
              flowAttempts: POST_PARALLEL_FLOW_ATTEMPTS,
              controlsTimeoutMs: POST_PARALLEL_CONTROLS_TIMEOUT_MS,
              messageAttempts: POST_PARALLEL_MESSAGE_ATTEMPTS,
              prepareDraftBeforePost: false
            });
          } catch (error) {
            result = {
              ok: false,
              message: error?.message || `Opened ${entry.targetUrl}, but Post action was not found.`
            };
          } finally {
            await closeParallelWorkerTab(entry.tabId);
          }

          return {
            url: entry.targetUrl,
            ok: Boolean(result?.ok),
            message: result?.message || (result?.ok ? 'Posted.' : 'Post action not found.')
          };
        }));

        batchResults.forEach(item => {
          handleDraftResult(item.url, item);
        });

        if (!skipFailed && batchResults.some(item => !item.ok)) {
          stoppedOnFailure = true;
        }
      }
    } finally {
      await closeParallelWorkerTabs();
    }
  } else if (concurrency === 1) {
    for (let index = 0; index < queueUrls.length; index += 1) {
      if (trackState && manualRunState.stopRequested) {
        stopped = true;
        break;
      }

      const targetUrl = queueUrls[index];

      if (trackState) {
        manualRunState = {
          ...manualRunState,
          currentIndex: index + 1,
          currentUrl: targetUrl,
          remaining: Math.max(queueUrls.length - index, 0),
          lastMessage: `Posting draft ${index + 1}/${queueUrls.length}...`
        };
      }

      let result;
      try {
        result = await runSingleDraft(targetUrl);
      } catch (error) {
        result = {
          ok: false,
          message: error?.message || `Opened ${targetUrl}, but Post action was not found.`
        };
      }

      const item = {
        url: targetUrl,
        ok: Boolean(result?.ok),
        message: result?.message || (result?.ok ? 'Posted.' : 'Post action not found.')
      };

      handleDraftResult(targetUrl, item);

      if (canUseActiveTabNavigation) {
        try {
          await navigateTabToUrl(activeTabId, listPageUrl);
          await sleep(Math.max(120, item.ok ? POST_NEXT_DELAY_MS : POST_FAIL_DELAY_MS));
        } catch {}
      }

      if (!item.ok && !skipFailed) {
        stoppedOnFailure = true;
        break;
      }

      if (!canUseActiveTabNavigation) {
        await sleep(item.ok ? POST_NEXT_DELAY_MS : POST_FAIL_DELAY_MS);
      }
    }
  } else {
    let nextIndex = 0;
    let stopScheduling = false;

    const workerLoop = async () => {
      while (true) {
        if (stopScheduling) return;
        if (trackState && manualRunState.stopRequested) {
          stopped = true;
          stopScheduling = true;
          return;
        }

        const index = nextIndex;
        if (index >= queueUrls.length) return;
        nextIndex += 1;

        const targetUrl = queueUrls[index];

        if (trackState) {
          manualRunState = {
            ...manualRunState,
            currentIndex: index + 1,
            currentUrl: targetUrl,
            remaining: Math.max(queueUrls.length - index, 0),
            lastMessage: `Posting draft ${index + 1}/${queueUrls.length} in background tabs...`
          };
        }

        let result;
        try {
          result = await runSingleDraft(targetUrl);
        } catch (error) {
          result = {
            ok: false,
            message: error?.message || `Opened ${targetUrl}, but Post action was not found.`
          };
        }

        const item = {
          url: targetUrl,
          ok: Boolean(result?.ok),
          message: result?.message || (result?.ok ? 'Posted.' : 'Post action not found.')
        };

        handleDraftResult(targetUrl, item);

        if (!item.ok && !skipFailed) {
          stoppedOnFailure = true;
          stopScheduling = true;
          return;
        }

        await sleep(item.ok ? POST_NEXT_DELAY_MS : POST_FAIL_DELAY_MS);
      }
    };

    try {
      await Promise.all(Array.from({ length: concurrency }, () => workerLoop()));
    } finally {
      await closeParallelWorkerTabs();
    }
  }

  if (concurrency === 1) {
    if (canUseActiveTabNavigation) {
      try {
        await navigateTabToUrl(activeTabId, listPageUrl);
      } catch {}
    } else {
      await closeWorkerTab();
    }
  }

  const total = queueUrls.length;
  let message = `Posted ${posted}/${total} draft(s). ${failed} failed.`;
  if (stopped && manualRunState.stopRequested) {
    message = `Stopped after ${results.length}/${total} draft(s). Posted ${posted}. Failed ${failed}.`;
  } else if (stoppedOnFailure) {
    message = `Stopped on first failed draft. Posted ${posted}/${total}. Failed ${failed}.`;
  }

  if (trackState) {
    finishRunState(message, {
      mode,
      total,
      done: results.length,
      posted,
      failed,
      remaining: total - results.length,
      results
    });
  }

  if (posted > 0) {
    await navigateTabToProfileIfSora(refreshTabId).catch(() => {});
  } else {
    refreshTabIfSora(refreshTabId).catch(() => {});
  }

  return {
    ok: posted > 0,
    posted,
    failed,
    total,
    results,
    stopped,
    stoppedOnFailure,
    message
  };
}

async function runDeleteUrlQueue(targetUrls, options = {}) {
  const {
    skipFailed = true,
    limit = null,
    fastMode = true,
    refreshTabId = null,
    parallelWorkers = 1,
    preopenParallelTabs = false
  } = options;

  const queue = limit ? targetUrls.slice(0, limit) : targetUrls.slice();
  const total = queue.length;
  const pageDelay = fastMode ? FAST_PROJECT_ACTION_DELAY_MS : NORMAL_PROJECT_ACTION_DELAY_MS;
  const nextDelay = fastMode ? FAST_DELETE_NEXT_DELAY_MS : NORMAL_DELETE_NEXT_DELAY_MS;
  const failDelay = fastMode ? FAST_DELETE_FAIL_DELAY_MS : NORMAL_DELETE_FAIL_DELAY_MS;
  const concurrency = getQueueConcurrency(queue.length, parallelWorkers);
  const useParallelTabBatch = Boolean(preopenParallelTabs && concurrency > 1);
  const parallelSettleDelay = Math.max(pageDelay, DELETE_PARALLEL_TAB_SETTLE_DELAY_MS);

  const results = [];
  const removedUrls = [];
  let deleted = 0;
  let failed = 0;
  let stopped = false;
  let stoppedOnFailure = false;

  const runSingleDelete = async targetUrl => {
    if (concurrency === 1) {
      const tabId = await ensureWorkerTabAtUrl(targetUrl);
      await sleep(pageDelay);
      return await tryDeleteProjectOnTabWithRefreshRetry(tabId, targetUrl, { silent: true, fastMode });
    }

    let tabId = null;
    try {
      tabId = await openParallelWorkerTab(targetUrl);
      await waitForTabComplete(tabId, targetUrl);
      await sleep(pageDelay);
      return await tryDeleteProjectOnTabWithRefreshRetry(tabId, targetUrl, { silent: true, fastMode });
    } finally {
      await closeParallelWorkerTab(tabId);
    }
  };

  const handleDeleteResult = (targetUrl, item) => {
    results.push(item);
    if (item.ok) {
      deleted += 1;
      removedUrls.push(targetUrl);
    } else {
      failed += 1;
    }

    deleteRunState = {
      ...deleteRunState,
      done: results.length,
      deleted,
      failed,
      remaining: Math.max(queue.length - results.length, 0),
      results: results.slice(-10),
      fastMode,
      lastMessage: item.ok
        ? `Deleted ${deleted}/${queue.length} video(s).`
        : `Failed ${results.length}/${queue.length}: ${targetUrl}`
    };
  };

  if (useParallelTabBatch) {
    const openedTabs = [];

    try {
      for (let index = 0; index < queue.length; index += 1) {
        if (deleteRunState.stopRequested) {
          stopped = true;
          break;
        }

        const targetUrl = queue[index];
        const tabId = await openParallelWorkerTab(targetUrl);
        openedTabs.push({ tabId, targetUrl, index });

        deleteRunState = {
          ...deleteRunState,
          running: true,
          done: results.length,
          deleted,
          failed,
          currentUrl: targetUrl,
          currentTitle: null,
          remaining: Math.max(queue.length - index, 0),
          fastMode,
          lastMessage: `Opening delete tab ${index + 1}/${queue.length}...`
        };
      }

      if (!stopped && openedTabs.length) {
        deleteRunState = {
          ...deleteRunState,
          running: true,
          currentUrl: null,
          currentTitle: null,
          lastMessage: `Waiting for ${openedTabs.length} delete tab(s) to finish loading...`
        };

        await Promise.all(openedTabs.map(async entry => {
          await waitForTabComplete(entry.tabId, entry.targetUrl);
          await sleep(parallelSettleDelay);
        }));

        deleteRunState = {
          ...deleteRunState,
          running: true,
          currentUrl: null,
          currentTitle: null,
          lastMessage: `Deleting ${openedTabs.length} loaded video tab(s)...`
        };

        const batchResults = await Promise.all(openedTabs.map(async entry => {
          let result;
          try {
            deleteRunState = {
              ...deleteRunState,
              running: true,
              currentUrl: entry.targetUrl,
              currentTitle: null,
              lastMessage: `Deleting ${entry.targetUrl}...`
            };
            result = await tryDeleteProjectOnTabWithRefreshRetry(entry.tabId, entry.targetUrl, { silent: true, fastMode });
          } catch (error) {
            result = {
              ok: false,
              message: error?.message || `Opened ${entry.targetUrl}, but Delete action was not found.`
            };
          } finally {
            await closeParallelWorkerTab(entry.tabId);
          }

          return {
            url: entry.targetUrl,
            ok: Boolean(result?.ok),
            message: result?.message || (result?.ok ? 'Deleted.' : 'Delete action not found.')
          };
        }));

        batchResults.forEach(item => {
          handleDeleteResult(item.url, item);
        });

        if (!skipFailed && batchResults.some(item => !item.ok)) {
          stoppedOnFailure = true;
        }
      }
    } finally {
      await closeParallelWorkerTabs();
    }
  } else if (concurrency === 1) {
    for (let index = 0; index < queue.length; index += 1) {
      if (deleteRunState.stopRequested) {
        stopped = true;
        break;
      }

      const targetUrl = queue[index];

      deleteRunState = {
        ...deleteRunState,
        running: true,
        done: results.length,
        deleted,
        failed,
        currentUrl: targetUrl,
        currentTitle: null,
        remaining: Math.max(queue.length - index, 0),
        fastMode,
        lastMessage: `${fastMode ? 'Fast deleting' : 'Deleting'} video ${index + 1}/${queue.length}...`
      };

      let result;
      try {
        result = await runSingleDelete(targetUrl);
      } catch (error) {
        result = {
          ok: false,
          message: error?.message || `Opened ${targetUrl}, but Delete action was not found.`
        };
      }

      const item = {
        url: targetUrl,
        ok: Boolean(result?.ok),
        message: result?.message || (result?.ok ? 'Deleted.' : 'Delete action not found.')
      };

      handleDeleteResult(targetUrl, item);

      if (!item.ok && skipFailed === false) {
        stoppedOnFailure = true;
        break;
      }

      await sleep(item.ok ? nextDelay : failDelay);
    }
  } else {
    let nextIndex = 0;
    let stopScheduling = false;

    const workerLoop = async () => {
      while (true) {
        if (stopScheduling) return;
        if (deleteRunState.stopRequested) {
          stopped = true;
          stopScheduling = true;
          return;
        }

        const index = nextIndex;
        if (index >= queue.length) return;
        nextIndex += 1;

        const targetUrl = queue[index];

        deleteRunState = {
          ...deleteRunState,
          running: true,
          done: results.length,
          deleted,
          failed,
          currentUrl: targetUrl,
          currentTitle: null,
          remaining: Math.max(queue.length - index, 0),
          fastMode,
          lastMessage: `${fastMode ? 'Fast deleting' : 'Deleting'} video ${index + 1}/${queue.length} in background tabs...`
        };

        let result;
        try {
          result = await runSingleDelete(targetUrl);
        } catch (error) {
          result = {
            ok: false,
            message: error?.message || `Opened ${targetUrl}, but Delete action was not found.`
          };
        }

        const item = {
          url: targetUrl,
          ok: Boolean(result?.ok),
          message: result?.message || (result?.ok ? 'Deleted.' : 'Delete action not found.')
        };

        handleDeleteResult(targetUrl, item);

        if (!item.ok && skipFailed === false) {
          stoppedOnFailure = true;
          stopScheduling = true;
          return;
        }

        await sleep(item.ok ? nextDelay : failDelay);
      }
    };

    try {
      await Promise.all(Array.from({ length: concurrency }, () => workerLoop()));
    } finally {
      await closeParallelWorkerTabs();
    }
  }

  if (concurrency === 1) {
    await closeWorkerTab();
  }

  if (removedUrls.length) {
    await removeSavedDeleteTargetUrls(removedUrls);
  }

  let message = `Deleted ${deleted}/${total} video(s). ${failed} failed.`;
  if (stopped) {
    message = `Stopped after ${results.length}/${total} video(s). Deleted ${deleted}. Failed ${failed}.`;
  } else if (stoppedOnFailure) {
    message = `Stopped on first failed delete. Deleted ${deleted}/${total}. Failed ${failed}.`;
  }

  finishDeleteRunState(message, {
    total,
    done: results.length,
    deleted,
    failed,
    remaining: total - results.length,
    results
  });

  refreshTabIfSora(refreshTabId).catch(() => {});

  return {
    ok: deleted > 0,
    message,
    total,
    done: results.length,
    deleted,
    failed,
    remaining: total - results.length,
    results,
    stopped,
    stoppedOnFailure,
    state: getDeleteRunStatus()
  };
}

async function runHiddenOpenQueue(targetUrls, options = {}) {
  const { limit = null, batchLabel = 'All' } = options;
  const queue = limit ? targetUrls.slice(0, limit) : targetUrls.slice();

  if (!queue.length) {
    finishOpenRunState('No Sora video URLs found to open in the background.', {
      total: 0,
      done: 0,
      remaining: 0,
      results: []
    });
    return {
      ok: false,
      message: openRunState.lastMessage,
      total: 0,
      done: 0,
      results: [],
      state: getOpenRunStatus()
    };
  }

  openRunState = {
    ...openRunState,
    running: true,
    total: queue.length,
    remaining: queue.length,
    batchLabel,
    lastMessage: `Started hidden open queue for ${queue.length} video URL(s).`
  };

  const results = [];
  let opened = 0;
  let stopped = false;

  for (let index = 0; index < queue.length; index += 1) {
    if (openRunState.stopRequested) {
      stopped = true;
      break;
    }

    const targetUrl = queue[index];
    openRunState = {
      ...openRunState,
      running: true,
      done: results.length,
      currentUrl: targetUrl,
      remaining: Math.max(queue.length - index, 0),
      lastMessage: `Opening video ${index + 1}/${queue.length} in the background tab...`
    };

    const tabId = await ensureWorkerTabAtUrl(targetUrl);
    await sleep(HIDDEN_OPEN_SETTLE_DELAY_MS);

    const item = {
      url: targetUrl,
      ok: Boolean(tabId),
      message: 'Opened in the background worker tab.'
    };
    results.push(item);
    opened += 1;

    openRunState = {
      ...openRunState,
      done: results.length,
      remaining: Math.max(queue.length - results.length, 0),
      results: results.slice(-10),
      lastMessage: `Opened ${opened}/${queue.length} video URL(s) in the background tab.`
    };

    await sleep(HIDDEN_OPEN_NEXT_DELAY_MS);
  }

  const total = queue.length;
  const message = stopped
    ? `Stopped after opening ${results.length}/${total} video URL(s).`
    : `Opened ${opened}/${total} video URL(s) in the background tab.`;

  finishOpenRunState(message, {
    total,
    done: results.length,
    remaining: total - results.length,
    results
  });

  await closeWorkerTab();

  return {
    ok: opened > 0,
    message,
    total,
    done: results.length,
    opened,
    stopped,
    results,
    state: getOpenRunStatus()
  };
}

async function maybeRunAutoPost() {
  const enabled = await isAutoPostEnabled();
  if (!enabled) return;
  if (manualRunState.running) return;
  if (deleteRunState.running) return;
  if (openRunState.running) return;

  const activeTab = await getActiveTab();
  const activeUrl = normalizeUrl(activeTab?.url || '');
  const isDraftPage = isSoraDraftUrl(activeUrl);
  const isDraftsPage = isSoraDraftsPageUrl(activeUrl);
  if (!isDraftPage && !isDraftsPage) return;

  if (autoPostRunning) {
    autoPostQueued = true;
    return;
  }

  autoPostRunning = true;
  try {
    do {
      autoPostQueued = false;
      const pending = await getPendingAutoDraftUrls();
      if (!pending.length) break;
      const useActiveTabNavigation = isSoraDraftsPageUrl(activeUrl);

      const result = await runDraftQueue(pending, {
        silent: true,
        skipFailed: true,
        trackState: false,
        mode: 'auto',
        refreshTabId: activeTab?.id || null,
        parallelWorkers: useActiveTabNavigation ? 1 : getPostQueueConcurrencyForUrl(activeUrl, pending.length),
        useActiveTabNavigation,
        activeTabId: activeTab?.id || null,
        listPageUrl: activeUrl
      });
      const successful = (result?.results || []).filter(item => item.ok).map(item => item.url);
      if (successful.length) {
        await addProcessedDraftUrls(successful);
      } else {
        break;
      }
    } while (autoPostQueued);
  } finally {
    autoPostRunning = false;
  }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.action === 'get_integrity_status') {
    getBackgroundIntegrityStatus()
      .then(status => sendResponse({
        ok: status.valid === true,
        valid: status.valid === true,
        status
      }))
      .catch(error => sendResponse({
        ok: false,
        valid: false,
        message: error?.message || 'Could not check package integrity.'
      }));
    return true;
  }

  if (msg.action === 'get_license_status') {
    getBackgroundLicenseStatus()
      .then(status => sendResponse({
        ok: status.valid === true,
        licensed: status.valid === true,
        status
      }))
      .catch(error => sendResponse({
        ok: false,
        licensed: false,
        message: error?.message || 'Could not check license status.'
      }));
    return true;
  }

  if (msg.action === 'license_server_request') {
    if (!globalThis.SoraLicense?.getStoredServerUrl) {
      sendResponse({
        ok: false,
        message: 'Background license proxy is unavailable.'
      });
      return true;
    }

    globalThis.SoraLicense.getStoredServerUrl(chrome.storage.local)
      .then(serverUrl => {
        const targetUrl = new URL(String(msg.path || '/'), `${serverUrl}/`).toString();
        const method = String(msg.method || 'POST').trim().toUpperCase() || 'POST';
        const requestInit = {
          method,
          headers: {
            'Content-Type': 'application/json'
          }
        };
        if (method !== 'GET' && method !== 'HEAD') {
          requestInit.body = JSON.stringify(msg.body || {});
        }
        return fetch(targetUrl, requestInit)
          .then(async response => {
            const payload = await response.json().catch(() => ({}));
            if (!response.ok || payload?.ok === false) {
              throw new Error(payload?.message || 'License server request failed.');
            }
            return {
              ok: true,
              serverUrl,
              payload
            };
          });
      })
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Could not reach license server.'
      }));
    return true;
  }

  if (msg.action === 'get_run_status') {
    sendResponse({ ok: true, state: getRunStatus() });
    return true;
  }

  if (msg.action === 'get_delete_run_status') {
    sendResponse({ ok: true, state: getDeleteRunStatus() });
    return true;
  }

  if (msg.action === 'get_open_run_status') {
    sendResponse({ ok: true, state: getOpenRunStatus() });
    return true;
  }

  if (msg.action === 'get_download_run_status') {
    sendResponse({ ok: true, state: getDownloadRunStatus() });
    return true;
  }

  if (msg.action === 'get_failed_download_urls') {
    getFailedDownloadUrls()
      .then(urls => sendResponse({
        ok: true,
        urls
      }))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error',
        urls: []
      }));
    return true;
  }

  if (msg.action === 'clear_failed_download_urls') {
    setFailedDownloadUrls([])
      .then(() => sendResponse({ ok: true }))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));
    return true;
  }

  if (msg.action === 'delete_queue_progress') {
    if (sender.tab?.id && workerTabId && sender.tab.id !== workerTabId) {
      sendResponse({ ok: false });
      return true;
    }

    const isRunning = msg.state?.running !== false;
    deleteRunState = {
      ...deleteRunState,
      ...msg.state,
      running: isRunning,
      stopRequested: isRunning ? deleteRunState.stopRequested : false,
      finishedAt: isRunning ? deleteRunState.finishedAt : Date.now(),
      currentUrl: isRunning ? (msg.state?.currentUrl ?? deleteRunState.currentUrl) : null,
      currentTitle: isRunning ? (msg.state?.currentTitle ?? deleteRunState.currentTitle) : null,
      results: Array.isArray(msg.state?.results) ? msg.state.results.slice(-10) : deleteRunState.results
    };
    sendResponse({ ok: true });
    return true;
  }

  if (msg.action === 'stop_run_queue') {
    if (!manualRunState.running) {
      sendResponse({
        ok: false,
        message: 'No queue is running right now.',
        state: getRunStatus()
      });
      return true;
    }

    manualRunState = {
      ...manualRunState,
      stopRequested: true,
      lastMessage: 'Stop requested. Finishing the current draft...'
    };

    sendResponse({
      ok: true,
      message: manualRunState.lastMessage,
      state: getRunStatus()
    });
    return true;
  }

  if (msg.action === 'stop_delete_queue') {
    if (!deleteRunState.running) {
      sendResponse({
        ok: false,
        message: 'No delete queue is running right now.',
        state: getDeleteRunStatus()
      });
      return true;
    }

    deleteRunState = {
      ...deleteRunState,
      stopRequested: true,
      lastMessage: 'Stop requested. Finishing the current delete...'
    };

    if (workerTabId) {
      sendWorkerMessage(workerTabId, { action: 'request_stop_delete_queue' }, 2).catch(() => {});
    }
    if (parallelWorkerTabIds.size) {
      Promise.all(Array.from(parallelWorkerTabIds).map(tabId => (
        sendWorkerMessage(tabId, { action: 'request_stop_delete_queue' }, 1).catch(() => {})
      ))).catch(() => {});
    }

    sendResponse({
      ok: true,
      message: deleteRunState.lastMessage,
      state: getDeleteRunStatus()
    });
    return true;
  }

  if (msg.action === 'stop_open_queue') {
    if (!openRunState.running) {
      sendResponse({
        ok: false,
        message: 'No hidden open queue is running right now.',
        state: getOpenRunStatus()
      });
      return true;
    }

    openRunState = {
      ...openRunState,
      stopRequested: true,
      lastMessage: 'Stop requested. Finishing the current background URL...'
    };

    sendResponse({
      ok: true,
      message: openRunState.lastMessage,
      state: getOpenRunStatus()
    });
    return true;
  }

  if (msg.action === 'start_run_queue') {
    getBackgroundIntegrityStatus()
      .then(async integrity => {
        if (!integrity.valid) {
          sendResponse({
            ok: false,
            message: integrity.message || INTEGRITY_REQUIRED_MESSAGE,
            integrity
          });
          return;
        }

        return getBackgroundLicenseStatus();
      })
      .then(async license => {
        if (!license) return;
        if (!license.valid) {
          sendResponse({
            ok: false,
            message: license.reason || LICENSE_REQUIRED_MESSAGE,
            license
          });
          return;
        }

        if (manualRunState.running) {
          sendResponse({
            ok: false,
            message: 'A queue is already running.',
            state: getRunStatus()
          });
          return;
        }

        if (deleteRunState.running) {
          sendResponse({
            ok: false,
            message: 'Delete queue is running. Stop it first or wait until it finishes.',
            state: getDeleteRunStatus()
          });
          return;
        }

        if (openRunState.running) {
          sendResponse({
            ok: false,
            message: 'Hidden open queue is running. Stop it first or wait until it finishes.',
            state: getOpenRunStatus()
          });
          return;
        }

        if (autoPostRunning) {
          sendResponse({
            ok: false,
            message: 'Auto Post Drafts is running. Turn it off or wait for it to finish.',
            state: getRunStatus()
          });
          return;
        }

        const limit = normalizeBatchLimit(msg.limit);
        prepareRunState({
          mode: 'manual',
          skipFailed: msg.skipFailed !== false,
          batchLabel: msg.limitLabel || (limit ? String(limit) : 'All'),
          lastMessage: 'Preparing queue...'
        });

        (async () => {
          const activeTab = await getActiveTab();
          const activeUrl = normalizeUrl(activeTab?.url || '');
          const refreshTabId = activeTab?.id || null;
          const forceParallelTabs = msg.forceParallelTabs === true;
          const useActiveTabNavigation = isSoraDraftsPageUrl(activeUrl) && !forceParallelTabs;
          const requestedUrlCount = Array.isArray(msg.urls) ? msg.urls.length : 1;
          return await runDraftQueue(msg.urls, {
            silent: true,
            skipFailed: msg.skipFailed !== false,
            limit,
            trackState: true,
            mode: 'manual',
            batchLabel: msg.limitLabel || (limit ? String(limit) : 'All'),
            refreshTabId,
            parallelWorkers: forceParallelTabs
              ? requestedUrlCount
              : useActiveTabNavigation
                ? 1
                : getPostQueueConcurrencyForUrl(activeUrl, requestedUrlCount),
            useActiveTabNavigation,
            activeTabId: activeTab?.id || null,
            listPageUrl: activeUrl,
            preopenParallelTabs: forceParallelTabs
          });
        })()
          .then(result => sendResponse({
            ...result,
            state: getRunStatus()
          }))
          .catch(error => {
            finishRunState(error?.message || 'Unknown error');
            sendResponse({
              ok: false,
              message: error?.message || 'Unknown error',
              state: getRunStatus()
            });
          });
      })
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Could not validate extension protection.',
        state: getRunStatus()
      }));

    return true;
  }

  if (msg.action === 'start_delete_queue') {
    getBackgroundIntegrityStatus()
      .then(async integrity => {
        if (!integrity.valid) {
          sendResponse({
            ok: false,
            message: integrity.message || INTEGRITY_REQUIRED_MESSAGE,
            integrity
          });
          return;
        }

        return getBackgroundLicenseStatus();
      })
      .then(async license => {
        if (!license) return;
        if (!license.valid) {
          sendResponse({
            ok: false,
            message: license.reason || LICENSE_REQUIRED_MESSAGE,
            license
          });
          return;
        }

        if (deleteRunState.running) {
          sendResponse({
            ok: false,
            message: 'A delete queue is already running.',
            state: getDeleteRunStatus()
          });
          return;
        }

        if (manualRunState.running || autoPostRunning) {
          sendResponse({
            ok: false,
            message: 'Post queue is running. Stop it first or wait until it finishes.',
            state: getRunStatus()
          });
          return;
        }

        if (openRunState.running) {
          sendResponse({
            ok: false,
            message: 'Hidden open queue is running. Stop it first or wait until it finishes.',
            state: getOpenRunStatus()
          });
          return;
        }

        const limit = normalizeBatchLimit(msg.limit);
        const fastMode = msg.fastMode !== false;
        prepareDeleteRunState({
          total: 0,
          batchLabel: msg.limitLabel || (limit ? String(limit) : 'All'),
          skipFailed: msg.skipFailed !== false,
          fastMode,
          lastMessage: 'Preparing delete queue...'
        });

        (async () => {
          const activeTab = await getActiveTab();
          const activeUrl = normalizeUrl(activeTab?.url || '');
          const refreshTabId = activeTab?.id || null;
          const forceParallelTabs = msg.forceParallelTabs === true;
          const targetUrls = await resolveDeleteTargetUrls(msg.urls);
          if (!targetUrls.length) {
            const protectedFailedUrls = await getFailedDownloadUrls();
            finishDeleteRunState(
              protectedFailedUrls.length
                ? 'No deletable Sora video URLs found. Failed download URLs were protected for retry.'
                : 'No scanned Sora video URLs found. Scan visible cards first.'
            );
            return {
              ok: false,
              message: deleteRunState.lastMessage,
              state: getDeleteRunStatus()
            };
          }

          const queueTotal = limit ? Math.min(limit, targetUrls.length) : targetUrls.length;
          deleteRunState = {
            ...deleteRunState,
            total: queueTotal,
            remaining: queueTotal,
            fastMode,
            lastMessage: `Started delete queue for ${queueTotal} video(s).`
          };
          return await runDeleteUrlQueue(targetUrls, {
            skipFailed: msg.skipFailed !== false,
            limit,
            fastMode,
            refreshTabId,
            parallelWorkers: forceParallelTabs
              ? targetUrls.length
              : getDeleteQueueConcurrencyForUrl(activeUrl, targetUrls.length),
            preopenParallelTabs: forceParallelTabs
          });
        })()
          .then(result => sendResponse(result))
          .catch(error => {
            finishDeleteRunState(error?.message || 'Unknown error');
            sendResponse({
              ok: false,
              message: error?.message || 'Unknown error',
              state: getDeleteRunStatus()
            });
          });
      })
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Could not validate extension protection.',
        state: getDeleteRunStatus()
      }));

    return true;
  }

  if (msg.action === 'post_draft_for_url') {
    if (manualRunState.running || deleteRunState.running || openRunState.running) {
      sendResponse({
        ok: false,
        message: 'Another queue is already running. Stop it first or wait until it finishes.',
        state: getRunStatus()
      });
      return true;
    }

    (async () => {
      const integrity = await getBackgroundIntegrityStatus();
      if (!integrity.valid) {
        return {
          ok: false,
          message: integrity.message || INTEGRITY_REQUIRED_MESSAGE
        };
      }

      const license = await getBackgroundLicenseStatus();
      if (!license.valid) {
        return {
          ok: false,
          message: license.reason || LICENSE_REQUIRED_MESSAGE
        };
      }

      const refreshTabId = (await getActiveTab())?.id || null;
      const targetUrl = await resolveTargetUrl(msg.url);
      if (!targetUrl) {
        return {
          ok: false,
          message: 'No Sora project or draft URL found. Scan URLs first or open a Sora page.'
        };
      }

      const tabId = await ensureWorkerTabAtUrl(targetUrl);
      await sleep(POST_PROJECT_ACTION_DELAY_MS);
      const result = await tryPostDraftOnTab(tabId, targetUrl, { silent: false });
      if (result?.ok) {
        await navigateTabToProfileIfSora(refreshTabId).catch(() => {});
      } else {
        refreshTabIfSora(refreshTabId).catch(() => {});
      }
      return {
        ...result,
        targetUrl
      };
    })()
      .finally(() => closeWorkerTab())
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));

    return true;
  }

  if (msg.action === 'delete_single_video') {
    if (manualRunState.running || deleteRunState.running || autoPostRunning || openRunState.running) {
      sendResponse({
        ok: false,
        message: 'Another queue is already running. Stop it first or wait until it finishes.',
        state: getDeleteRunStatus()
      });
      return true;
    }

    (async () => {
      const integrity = await getBackgroundIntegrityStatus();
      if (!integrity.valid) {
        return {
          ok: false,
          message: integrity.message || INTEGRITY_REQUIRED_MESSAGE
        };
      }

      const license = await getBackgroundLicenseStatus();
      if (!license.valid) {
        return {
          ok: false,
          message: license.reason || LICENSE_REQUIRED_MESSAGE
        };
      }

      const refreshTabId = (await getActiveTab())?.id || null;
      const fastMode = msg.fastMode !== false;
      const targetUrls = await resolveDeleteTargetUrls([msg.targetUrl]);
      const targetUrl = targetUrls[0] || null;
      if (!targetUrl) {
        const protectedFailedUrls = await getFailedDownloadUrls();
        return {
          ok: false,
          message: protectedFailedUrls.length
            ? 'This video URL is protected because its download failed and it is kept for retry.'
            : 'No Sora video URL found for this delete action.'
        };
      }

      const tabId = await ensureWorkerTabAtUrl(targetUrl);
      await sleep(fastMode ? FAST_PROJECT_ACTION_DELAY_MS : NORMAL_PROJECT_ACTION_DELAY_MS);
      const result = await tryDeleteProjectOnTab(tabId, targetUrl, { silent: false, fastMode });
      if (result?.ok) {
        await removeSavedDeleteTargetUrls([targetUrl]);
      }
      refreshTabIfSora(refreshTabId).catch(() => {});
      return {
        ...result,
        targetUrl,
        fastMode
      };
    })()
      .finally(() => closeWorkerTab())
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));

    return true;
  }

  if (msg.action === 'download_sora_urls') {
    getBackgroundIntegrityStatus()
      .then(async integrity => {
        if (!integrity.valid) {
          sendResponse({
            ok: false,
            message: integrity.message || INTEGRITY_REQUIRED_MESSAGE,
            integrity
          });
          return;
        }

        return getBackgroundLicenseStatus();
      })
      .then(async license => {
        if (!license) return;
        if (!license.valid) {
          sendResponse({
            ok: false,
            message: license.reason || LICENSE_REQUIRED_MESSAGE,
            license
          });
          return;
        }

        startBulkDownload(msg.urls, {
          skipDownloadedHistory: msg.forceRedownload !== true
        })
          .then(result => sendResponse(result))
          .catch(error => sendResponse({
            ok: false,
            message: error?.message || 'Could not start the bulk download action.',
            started: 0,
            invalidCount: 0,
            duplicateCount: 0,
            failedCount: 0
          }));
      })
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Could not validate extension protection.',
        started: 0,
        invalidCount: 0,
        duplicateCount: 0,
        failedCount: 0
      }));
    return true;
  }

  if (msg.action === 'post_all_drafts') {
    if (manualRunState.running || deleteRunState.running || openRunState.running) {
      sendResponse({
        ok: false,
        message: 'Another queue is already running. Stop it first or wait until it finishes.',
        state: getRunStatus()
      });
      return true;
    }

    (async () => {
      const activeTab = await getActiveTab();
      const activeUrl = normalizeUrl(activeTab?.url || '');
      const refreshTabId = activeTab?.id || null;
      const useActiveTabNavigation = isSoraDraftsPageUrl(activeUrl);
      return await runDraftQueue(msg.urls, {
        silent: true,
        skipFailed: true,
        trackState: false,
        mode: 'manual',
        refreshTabId,
        parallelWorkers: useActiveTabNavigation ? 1 : getPostQueueConcurrencyForUrl(activeUrl, Array.isArray(msg.urls) ? msg.urls.length : 1),
        useActiveTabNavigation,
        activeTabId: activeTab?.id || null,
        listPageUrl: activeUrl
      });
    })()
      .then(result => sendResponse(result))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));

    return true;
  }

  if (msg.action === 'open_hidden_urls') {
    if (manualRunState.running || deleteRunState.running || autoPostRunning || openRunState.running) {
      sendResponse({
        ok: false,
        message: 'Another queue is already running. Stop it first or wait until it finishes.',
        state: getOpenRunStatus()
      });
      return true;
    }

    const limit = normalizeBatchLimit(msg.limit);
    const batchLabel = msg.limitLabel || (limit ? String(limit) : 'All');
    prepareOpenRunState({
      total: 0,
      batchLabel,
      lastMessage: 'Preparing hidden open queue...'
    });

    (async () => {
      const targetUrls = await resolveHiddenOpenTargetUrls(msg.urls);
      const queueTotal = limit ? Math.min(limit, targetUrls.length) : targetUrls.length;
      const protectedFailedUrls = queueTotal ? [] : await getFailedDownloadUrls();
      openRunState = {
        ...openRunState,
        total: queueTotal,
        remaining: queueTotal,
        batchLabel,
        lastMessage: queueTotal
          ? `Started hidden open queue for ${queueTotal} video URL(s).`
          : protectedFailedUrls.length
            ? 'No openable Sora video URLs found. Failed download URLs were protected for retry.'
            : 'No Sora video URLs found to open in the background.'
      };

      return await runHiddenOpenQueue(targetUrls, {
        limit,
        batchLabel
      });
    })()
      .then(result => sendResponse(result))
      .catch(error => {
        finishOpenRunState(error?.message || 'Unknown error');
        sendResponse({
          ok: false,
          message: error?.message || 'Unknown error',
          state: getOpenRunStatus()
        });
      });

    return true;
  }

  if (msg.action === 'clear_processed_drafts') {
    setProcessedDraftUrls([])
      .then(() => sendResponse({ ok: true }))
      .catch(error => sendResponse({
        ok: false,
        message: error?.message || 'Unknown error'
      }));

    return true;
  }
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName !== 'local') return;

  if (changes[STORAGE_KEY] || changes[AUTO_POST_KEY]) {
    maybeRunAutoPost();
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete') {
    maybeRunAutoPost();
  }
});

chrome.tabs.onActivated.addListener(() => {
  maybeRunAutoPost();
});

chrome.downloads.onChanged.addListener(delta => {
  if (!downloadRunState.running || !delta?.state?.current) return;
  const tracked = activeDownloadItems.get(delta.id);
  if (!tracked) return;

  if (delta.state.current !== 'complete' && delta.state.current !== 'interrupted') return;

  activeDownloadItems.delete(delta.id);
  const ok = delta.state.current === 'complete';
  const message = ok ? 'Download completed.' : (delta.error?.current || 'Download interrupted.');

  if (!ok && Array.isArray(tracked.remainingCandidates) && tracked.remainingCandidates.length) {
    const [nextUrl, ...nextRemaining] = tracked.remainingCandidates;
    const retryJob = {
      id: tracked.id,
      index: tracked.index,
      source: tracked.source,
      __downloadStarted: true
    };

    downloadRunState = {
      ...downloadRunState,
      currentIndex: tracked.index,
      currentId: tracked.id,
      lastMessage: `Primary download failed. Switching to backup ${Math.min((tracked.attemptIndex || 1) + 1, tracked.totalAttempts || 1)}/${tracked.totalAttempts || 1}: ${tracked.id}`
    };

    startResolvedDownloadAttempt(
      retryJob,
      nextUrl,
      nextRemaining,
      (tracked.attemptIndex || 1) + 1,
      tracked.totalAttempts || (tracked.remainingCandidates.length + 1)
    ).then(started => {
      if (started) return;
      maybeFinishDownloadQueue().catch(() => {});
      processNextDownloadJob().catch(() => {});
    }).catch(() => {
      maybeFinishDownloadQueue().catch(() => {});
      processNextDownloadJob().catch(() => {});
    });
    return;
  }

  const completed = (downloadRunState.completed || 0) + (ok ? 1 : 0);
  const failed = (downloadRunState.failed || 0) + (ok ? 0 : 1);
  const done = completed + failed;
  const results = [
    ...downloadRunState.results,
    {
      id: tracked.id,
      ok,
      message
    }
  ].slice(-10);

  if (ok) {
    if (tracked.kind === 'sora') {
      addDownloadedVideoIds([tracked.id]).catch(() => {});
    }
    removeFailedDownloadUrls([tracked.source]).catch(() => {});
  } else {
    addFailedDownloadUrls([tracked.source]).catch(() => {});
  }

  downloadRunState = {
    ...downloadRunState,
    completed,
    failed,
    done,
    remaining: Math.max((downloadRunState.total || 0) - done, 0),
    results,
    currentIndex: 0,
    currentId: null,
    lastMessage: ok
      ? `Completed ${completed}/${downloadRunState.total || 0} download(s).`
      : `Failed ${failed}/${downloadRunState.total || 0}: ${tracked.id}`
  };

  maybeFinishDownloadQueue().catch(() => {});
  processNextDownloadJob().catch(() => {});
});

chrome.tabs.onRemoved.addListener(tabId => {
  parallelWorkerTabIds.delete(tabId);
  if (tabId !== workerTabId) return;
  workerTabId = null;
  if (manualRunState.running) finishRunState('Post worker tab closed unexpectedly.');
  if (deleteRunState.running) finishDeleteRunState('Delete worker tab closed unexpectedly.');
  if (openRunState.running) finishOpenRunState('Hidden open worker tab closed unexpectedly.');
});

chrome.windows.onRemoved.addListener(windowId => {
  if (windowId === workerWindowId) {
    workerWindowId = null;
    workerTabId = null;
    if (manualRunState.running) finishRunState('Post worker window closed unexpectedly.');
    if (deleteRunState.running) finishDeleteRunState('Delete worker window closed unexpectedly.');
    if (openRunState.running) finishOpenRunState('Hidden open worker window closed unexpectedly.');
  }
});
