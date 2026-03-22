const POST_STORAGE_KEY = 'soraPageUrlResults';
const AUTO_POST_KEY = 'soraAutoPostEnabled';
const DELETE_STORAGE_KEY = 'soraDeleteScanResults';
const PUBLISHED_VIDEO_STORAGE_KEY = 'soraPublishedVideoUrlCache';
const DELETE_FAST_MODE_KEY = 'soraFastDeleteEnabled';
const SHOW_ALL_TOOLS_KEY = 'soraShowAllTools';
const POPUP_VIEW_MODE_KEY = 'soraPopupViewMode';
const BUY_ORDER_STORAGE_KEY = 'soraBuyOrderState';

let postCollected = [];
let deleteCollected = [];
let publishedVideoCollected = [];
let deletePageUrl = null;
let postRunState = { running: false, total: 0, lastMessage: 'Ready.' };
let deleteRunState = { running: false, total: 0, lastMessage: 'Ready.' };
let openRunState = { running: false, total: 0, lastMessage: 'Hidden open queue idle.' };
let downloadRunState = { running: false, total: 0, lastMessage: 'Download queue idle.' };
let failedDownloadUrls = [];
let inlinePostRunning = false;
let inlineDeleteRunning = false;
let downloadRequestPending = false;
let pollTimer = null;
let popupViewMode = 'all';
let popupContext = 'general';
let currentLicenseState = null;
let autoClipboardLicenseTried = false;
let licenseActivationBusy = false;
let licenseUiTimer = null;
let licenseExpiryRefreshTimer = null;
let buyConfig = null;
let buyOrder = null;
let buySelectedPlanId = '';
let buyPollTimer = null;
let buyConfigLoaded = false;
let buyPrepareInFlight = false;
let buyPreparingPlanLabel = '';
let buyPrepareSequence = 0;
let buyModalStage = 'plans';
let buyCountdownTimer = null;
const LICENSE_PENDING_REFRESH_INTERVAL_MS = 5000;
const LICENSE_ACTIVE_REFRESH_INTERVAL_MS = 15000;
const BUY_ORDER_POLL_INTERVAL_MS = 3000;

async function getActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function sendMessageToActiveTab(action) {
  const tab = await getActiveTab();
  const payload = typeof action === 'string' ? { action } : action;
  return chrome.tabs.sendMessage(tab.id, payload);
}

function setStatus(text) {
  document.getElementById('status').textContent = text;
}

function setLicenseStatusText(text, ok) {
  const node = document.getElementById('licenseStatus');
  if (!node) return;
  node.textContent = text;
  node.classList.toggle('ok', Boolean(ok));
  node.classList.toggle('bad', !ok);
}

function formatShortTimeLeft(expiresAt) {
  const expiresAtMs = Date.parse(String(expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return '';
  const diffMs = expiresAtMs - Date.now();
  if (diffMs <= 0) return 'Expired';
  const totalMinutes = Math.max(1, Math.ceil(diffMs / (60 * 1000)));
  if (totalMinutes < 60) return `${totalMinutes}m left`;
  const totalHours = Math.max(1, Math.ceil(diffMs / (60 * 60 * 1000)));
  if (totalHours < 24) return `${totalHours}h left`;
  const totalDays = Math.max(1, Math.ceil(diffMs / (24 * 60 * 60 * 1000)));
  return `${totalDays}d left`;
}

async function refreshIntegrityUi() {
  const node = document.getElementById('integrityMeta');
  if (!node) return null;
  try {
    const res = await chrome.runtime.sendMessage({ action: 'get_integrity_status' });
    const status = res?.status || null;
    node.textContent = status?.valid
      ? 'Build status: original package verified.'
      : `Build status: ${status?.message || 'package changed.'}`;
    return status;
  } catch (error) {
    node.textContent = `Build status: ${error?.message || 'unavailable.'}`;
    return null;
  }
}

async function refreshLicenseUi() {
  if (!globalThis.SoraLicense) {
    setLicenseStatusText('License module is unavailable.', false);
    return null;
  }

  const state = await SoraLicense.getStoredLicenseStatus(chrome.storage.local);
  const serverUrl = await SoraLicense.getStoredServerUrl(chrome.storage.local);
  currentLicenseState = state;
  const deviceId = state?.deviceId || await SoraLicense.getDeviceId();
  document.getElementById('licenseDeviceId').textContent = deviceId || 'Unavailable';
  const clearLicenseButton = document.getElementById('clearLicense');
  const copyLicenseKeyButton = document.getElementById('copyLicenseKey');
  if (clearLicenseButton) clearLicenseButton.hidden = !state.licensed;
  if (copyLicenseKeyButton) copyLicenseKeyButton.hidden = !state.licensed;

  if (state.trialActive) {
    if (state.trialForever || state?.trial?.forever) {
      setLicenseStatusText('Free access enabled', true);
      document.getElementById('licenseMeta').textContent =
        'Free access is currently enabled by the server without an expiry date. You can change this policy later from the server.';
    } else {
      setLicenseStatusText(`Free access: ${formatShortTimeLeft(state.expiresAt)}`, true);
      document.getElementById('licenseMeta').textContent =
        `This computer can use the extension free for ${state.trialPolicyLabel || state?.trial?.policyLabel || 'a limited time'}. Access ends on ${state.expiresAtLabel}. After that you must activate a license key.`;
    }
  } else if (state.valid) {
    setLicenseStatusText(
      state.autoActivated
        ? `Licensed until ${state.expiresAtLabel} (Auto restored)`
        : `Licensed until ${state.expiresAtLabel}`,
      true
    );
    document.getElementById('licenseMeta').textContent =
      `1 license = 1 computer. The same key can be activated on all Chrome profiles on this computer. Expires on ${state.expiresAtLabel}.`;
    if (state.autoActivated) {
      document.getElementById('licenseMeta').textContent += state.autoActivatedFastPath
        ? ' Restored automatically from the server for this computer with a faster one-step check.'
        : ' Restored automatically from the server for this computer.';
    }
    if (state.usingOfflineGrace) {
      document.getElementById('licenseMeta').textContent += ' Using recent cached validation because the server is temporarily offline.';
    }
  } else {
    setLicenseStatusText(state.reason || 'License key is not activated.', false);
    document.getElementById('licenseMeta').textContent =
      state.trialDisabled
        ? 'Free access is disabled on the server. Activate a valid license key to continue.'
        : state.trialExpired
        ? 'Your free access period has ended. Activate a valid license key to continue.'
        : 'Use Buy License / KHQR, or copy a valid license key to clipboard to auto-activate it on this computer.';
  }

  scheduleLicenseUiTimers();
  return state;
}

function stopLicenseUiTimers() {
  if (licenseUiTimer) {
    window.clearInterval(licenseUiTimer);
    licenseUiTimer = null;
  }
  if (licenseExpiryRefreshTimer) {
    window.clearTimeout(licenseExpiryRefreshTimer);
    licenseExpiryRefreshTimer = null;
  }
}

function scheduleLicenseUiTimers() {
  stopLicenseUiTimers();
  if (!currentLicenseState?.expiresAt && !currentLicenseState?.valid && !currentLicenseState?.trialActive) {
    licenseUiTimer = window.setInterval(() => {
      refreshLicenseUi().catch(() => {});
    }, LICENSE_PENDING_REFRESH_INTERVAL_MS);
    return;
  }

  licenseUiTimer = window.setInterval(async () => {
    if (!currentLicenseState?.expiresAt) return;

    const expiresAtMs = Date.parse(String(currentLicenseState.expiresAt || ''));
    if (!Number.isFinite(expiresAtMs)) return;

    if (expiresAtMs <= Date.now()) {
      await refreshLicenseUi();
      return;
    }

    if (currentLicenseState.trialActive) {
      if (currentLicenseState.trialForever || currentLicenseState?.trial?.forever) {
        setLicenseStatusText('Free access enabled', true);
        return;
      }
      setLicenseStatusText(`Free access: ${formatShortTimeLeft(currentLicenseState.expiresAt)}`, true);
      return;
    }

    if (currentLicenseState.valid) {
      setLicenseStatusText(
        currentLicenseState.autoActivated
          ? `Licensed until ${currentLicenseState.expiresAtLabel} (Auto restored)`
          : `Licensed until ${currentLicenseState.expiresAtLabel}`,
        true
      );
    }
  }, LICENSE_ACTIVE_REFRESH_INTERVAL_MS);

  const expiresAtMs = Date.parse(String(currentLicenseState?.expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return;
  const delayMs = Math.max(250, expiresAtMs - Date.now() + 250);
  licenseExpiryRefreshTimer = window.setTimeout(() => {
    refreshLicenseUi().catch(() => {});
  }, delayMs);
}

async function refreshLicenseServerUi() {
  if (!globalThis.SoraLicense) return '';
  const serverUrl = await SoraLicense.getStoredServerUrl(chrome.storage.local);
  const input = document.getElementById('licenseServerUrl');
  const meta = document.getElementById('licenseServerMeta');
  if (input && document.activeElement !== input) {
    input.value = serverUrl || '';
  }
  if (meta) {
    meta.textContent = '';
  }
  return serverUrl;
}

async function handleCopyDeviceId() {
  const value = document.getElementById('licenseDeviceId').textContent || '';
  if (!value || value === 'Loading...') {
    setStatus('Device ID is not ready yet.');
    return;
  }

  try {
    await copyTextToClipboard(value);
    setStatus('Copied device ID.');
  } catch {
    setStatus('Could not copy device ID.');
  }
}

async function handleCopyLicenseKey() {
  const key = String(currentLicenseState?.token || '').trim();
  if (!key) {
    setStatus('No active license key to copy.');
    return;
  }

  try {
    await copyTextToClipboard(key);
    setStatus('Copied license key.');
  } catch {
    setStatus('Could not copy license key.');
  }
}

function setBuyPanelVisible(visible) {
  const panel = document.getElementById('buyPanel');
  const button = document.getElementById('buyLicenseBtn');
  if (panel) panel.hidden = !visible;
  if (button) button.textContent = visible ? 'Hide Buy / KHQR' : 'Buy License / KHQR';
  if (!visible) {
    stopBuyPolling();
    stopBuyCountdown();
  } else if (buyOrder?.orderId && String(buyOrder.status || '').trim().toLowerCase() !== 'approved') {
    startBuyPolling(buyOrder.orderId);
  }
}

function resetBuyModalToPlans() {
  buyPrepareInFlight = false;
  buyPreparingPlanLabel = '';
  stopBuyPolling();
  stopBuyCountdown();
  setBuyModalStage('plans');
  if (!buySelectedPlanId) {
    const firstPlan = Array.isArray(buyConfig?.plans) ? buyConfig.plans[0] : null;
    buySelectedPlanId = String(firstPlan?.id || '');
  }
  renderBuyPlanCards();
  renderBuyConfigSummary();
  updateBuyQr();
}

async function readSavedBuyOrder() {
  const saved = await chrome.storage.local.get(BUY_ORDER_STORAGE_KEY);
  const order = saved?.[BUY_ORDER_STORAGE_KEY];
  return order && typeof order === 'object' ? order : null;
}

async function writeSavedBuyOrder(order) {
  await chrome.storage.local.set({ [BUY_ORDER_STORAGE_KEY]: order || null });
}

async function buyApi(path, options = {}) {
  const serverUrl = await SoraLicense.getStoredServerUrl(chrome.storage.local);
  const targetUrl = new URL(path, `${serverUrl}/`).toString();
  const response = await fetch(targetUrl, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data?.ok === false) {
    throw new Error(data?.message || 'Buy request failed.');
  }
  return data;
}

function getSelectedBuyPlan() {
  const plans = Array.isArray(buyConfig?.plans) ? buyConfig.plans : [];
  return plans.find(plan => String(plan.id || '') === buySelectedPlanId) || plans[0] || null;
}

function buildBuyQrPayload() {
  if (buyOrder?.khqrString) {
    return String(buyOrder.khqrString || '').trim();
  }
  const parts = [];
  if (buyConfig?.bakongAccountId) {
    parts.push(`Bakong ID: ${buyConfig.bakongAccountId}`);
  }
  const selectedPlan = getSelectedBuyPlan();
  if (selectedPlan?.amountUsdLabel) {
    parts.push(`Amount: ${selectedPlan.amountUsdLabel}`);
  } else if (selectedPlan?.amountKhrLabel) {
    parts.push(`Amount: ${selectedPlan.amountKhrLabel}`);
  }
  if (buyOrder?.orderId) {
    parts.push(`Order ID: ${buyOrder.orderId}`);
  }
  if (buyOrder?.planLabel) {
    parts.push(`Plan: ${buyOrder.planLabel}`);
  }
  if (buyOrder?.deviceId) {
    parts.push(`Device ID: ${buyOrder.deviceId}`);
  }
  const paymentNote = String(document.getElementById('buyPaymentNote')?.value || '').trim();
  if (paymentNote) {
    parts.push('', paymentNote);
  }
  return parts.join('\n').trim();
}

function getSelectedPlanAmountDisplay() {
  const selectedPlan = getSelectedBuyPlan();
  const rawLabel = String(
    selectedPlan?.amountKhrLabel ||
    selectedPlan?.amountUsdLabel ||
    ''
  ).trim();

  if (!rawLabel) {
    return { amount: '0', currency: 'USD' };
  }

  if (/khr/i.test(rawLabel)) {
    return {
      amount: rawLabel.replace(/\s*khr\s*/i, '').trim(),
      currency: 'KHR'
    };
  }

  if (/usd/i.test(rawLabel)) {
    return {
      amount: rawLabel.replace(/\s*usd\s*/i, '').trim(),
      currency: 'USD'
    };
  }

  if (rawLabel.includes('$')) {
    return {
      amount: rawLabel.replace('$', '').trim(),
      currency: 'USD'
    };
  }

  return {
    amount: rawLabel,
    currency: 'USD'
  };
}

function getPlanAmountDisplay(plan) {
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

function getQrBadgeSymbol(currency) {
  return String(currency || '').trim().toUpperCase() === 'KHR' ? '៛' : '$';
}

function formatBuyExpiryCountdown(expiresAt) {
  const expiresAtMs = Date.parse(String(expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return '';
  const diffMs = expiresAtMs - Date.now();
  if (diffMs <= 0) return '0 វិនាទី';
  const totalSeconds = Math.max(1, Math.ceil(diffMs / 1000));
  if (totalSeconds < 60) return `${totalSeconds} វិនាទី`;
  const totalMinutes = Math.max(1, Math.ceil(totalSeconds / 60));
  return `${totalMinutes} នាទី`;
}

function stopBuyCountdown() {
  if (!buyCountdownTimer) return;
  window.clearInterval(buyCountdownTimer);
  buyCountdownTimer = null;
}

async function expireBuyQrLocally() {
  stopBuyPolling();
  stopBuyCountdown();
  buyOrder = null;
  await writeSavedBuyOrder(null);
  setBuyModalStage('plans');
  renderBuyPlanCards();
  renderBuyConfigSummary();
  updateBuyQr();
  setStatus('QR ផុតកំណត់ហើយ។ សូមរើស plan ម្តងទៀត។');
}

function refreshBuyExpiryLabel() {
  const node = document.getElementById('buyQrExpiryLabel');
  if (!node) return;
  const expiresAt = String(buyOrder?.orderExpiresAt || '').trim();
  const expiresAtMs = Date.parse(expiresAt);
  if (!Number.isFinite(expiresAtMs)) {
    node.textContent = '';
    return;
  }
  if (expiresAtMs <= Date.now()) {
    node.textContent = 'ផុតកំណត់ក្នុងរយះពេល 0 វិនាទី';
    expireBuyQrLocally().catch(() => {});
    return;
  }
  node.textContent = `ផុតកំណត់ក្នុងរយះពេល ${formatBuyExpiryCountdown(expiresAt)}`;
}

function startBuyCountdown(expiresAt) {
  stopBuyCountdown();
  const expiresAtMs = Date.parse(String(expiresAt || ''));
  if (!Number.isFinite(expiresAtMs)) return;
  refreshBuyExpiryLabel();
  buyCountdownTimer = window.setInterval(() => {
    refreshBuyExpiryLabel();
  }, 1000);
}

function setBuyModalStage(stage) {
  buyModalStage = stage === 'qr' ? 'qr' : 'plans';
  updateBuyModalStage();
}

function updateBuyModalStage() {
  const planGrid = document.getElementById('buyPlanGrid');
  const qrBox = document.getElementById('buyQrBox');
  if (!planGrid || !qrBox) return;

  const showQrOnly = buyModalStage === 'qr';
  planGrid.hidden = showQrOnly;
  qrBox.hidden = !showQrOnly;
}

function updateBuyQr() {
  const payload = buildBuyQrPayload();
  const qrBox = document.getElementById('buyQrBox');
  const qrPreview = document.getElementById('buyQrPreview');
  if (!qrBox || !qrPreview) return;

  updateBuyModalStage();

  const merchantName = String(
    buyConfig?.merchantName ||
    buyConfig?.bakongAccountId ||
    'Bakong Payment'
  ).trim();
  const amountInfo = getSelectedPlanAmountDisplay();
  const badgeSymbol = getQrBadgeSymbol(amountInfo.currency);
  const expiryLabel = buyOrder?.orderExpiresAt
    ? `ផុតកំណត់ក្នុងរយះពេល ${formatBuyExpiryCountdown(buyOrder.orderExpiresAt)}`
    : '';

  if (buyPrepareInFlight) {
    const preparingLabel = buyPreparingPlanLabel || 'selected plan';
    qrPreview.textContent = `Preparing fresh KHQR for ${preparingLabel}...`;
    qrBox.innerHTML = `
      <div class="khqr-card">
        <div class="khqr-card-head">KHQR</div>
        <div class="khqr-card-body">
          <div class="khqr-merchant-name">${escapeHtml(merchantName)}</div>
          <div class="khqr-amount-row">
            <div class="khqr-amount-main">${escapeHtml(amountInfo.amount)}</div>
            <div class="khqr-amount-currency">${escapeHtml(amountInfo.currency)}</div>
          </div>
          <div class="khqr-expiry" id="buyQrExpiryLabel">${escapeHtml(expiryLabel)}</div>
          <div class="khqr-divider"></div>
          <div class="khqr-empty">Preparing fresh KHQR for ${escapeHtml(preparingLabel)}...</div>
        </div>
      </div>
    `;
    return;
  }

  qrPreview.textContent = buyOrder?.khqrMd5
    ? `KHQR ready\nMD5: ${buyOrder.khqrMd5}`
    : payload || 'KHQR details will appear here after the order is prepared.';

  if (!payload) {
    qrBox.innerHTML = `
      <div class="khqr-card">
        <div class="khqr-card-head">KHQR</div>
        <div class="khqr-card-body">
          <div class="khqr-merchant-name">${escapeHtml(merchantName)}</div>
          <div class="khqr-amount-row">
            <div class="khqr-amount-main">${escapeHtml(amountInfo.amount)}</div>
            <div class="khqr-amount-currency">${escapeHtml(amountInfo.currency)}</div>
          </div>
          <div class="khqr-expiry" id="buyQrExpiryLabel">${escapeHtml(expiryLabel)}</div>
          <div class="khqr-divider"></div>
          <div class="khqr-empty">Choose a plan to prepare a fresh KHQR and show it here.</div>
        </div>
      </div>
    `;
    return;
  }

  const imageUrl = `https://api.qrserver.com/v1/create-qr-code/?size=220x220&data=${encodeURIComponent(payload)}`;
  qrBox.innerHTML = `
    <div class="khqr-card">
      <div class="khqr-card-head">KHQR</div>
      <div class="khqr-card-body">
        <div class="khqr-merchant-name">${escapeHtml(merchantName)}</div>
        <div class="khqr-amount-row">
          <div class="khqr-amount-main">${escapeHtml(amountInfo.amount)}</div>
          <div class="khqr-amount-currency">${escapeHtml(amountInfo.currency)}</div>
        </div>
        <div class="khqr-expiry" id="buyQrExpiryLabel">${escapeHtml(expiryLabel)}</div>
        <div class="khqr-divider"></div>
        <div class="khqr-qr-wrap">
          <img src="${imageUrl}" alt="KHQR payment QR" />
          <div class="khqr-qr-badge">${escapeHtml(badgeSymbol)}</div>
        </div>
      </div>
    </div>
  `;
}

function renderBuyPlanCards() {
  const planGrid = document.getElementById('buyPlanGrid');
  if (!planGrid) return;

  const plans = Array.isArray(buyConfig?.plans) ? buyConfig.plans : [];
  if (!plans.length) {
    planGrid.innerHTML = `
      <button class="buy-plan-card active" type="button">
        <div class="buy-plan-title">Unavailable</div>
        <div class="buy-plan-price">...</div>
        <div class="buy-plan-help">Buy plans are not configured yet.</div>
      </button>
    `;
    return;
  }

  planGrid.innerHTML = plans.map(plan => {
    const active = String(plan.id || '') === buySelectedPlanId;
    const price = getPlanAmountDisplay(plan).combined;
    return `
      <button class="buy-plan-card ${active ? 'active' : ''}" data-plan-id="${escapeHtml(String(plan.id || ''))}" type="button">
        <div class="buy-plan-title">${escapeHtml(String(plan.label || ''))}</div>
        <div class="buy-plan-price">${escapeHtml(price)}</div>
        <div class="buy-plan-help">${escapeHtml(String(plan.description || ''))}</div>
      </button>
    `;
  }).join('');

  planGrid.querySelectorAll('.buy-plan-card[data-plan-id]').forEach(button => {
    button.addEventListener('click', () => {
      buySelectedPlanId = String(button.getAttribute('data-plan-id') || '').trim();
      renderBuyPlanCards();
      renderBuyConfigSummary();
      updateBuyQr();
      handlePrepareBuyOrder().catch(() => {});
    });
  });
}

function renderBuyConfigSummary() {
  const selectedPlan = getSelectedBuyPlan();
  document.getElementById('buyPriceValue').textContent =
    selectedPlan?.amountUsdLabel || selectedPlan?.amountKhrLabel || 'Not configured';
  document.getElementById('buyPriceHelp').textContent =
    selectedPlan?.description || 'This license will be bound to one computer.';
  document.getElementById('buyBakongValue').textContent = buyConfig?.bakongAccountId || 'Not configured';
  document.getElementById('buyConfigMeta').textContent = buyConfig?.enabled
    ? `Payment mode: ${buyConfig.paymentMode}. ${buyConfig.autoPaymentEnabled ? 'After payment, the extension will keep checking the order automatically.' : 'Manual approval is still required.'}`
    : 'Buy flow is not configured on the server yet.';
}

async function renderBuyOrder(order, options = {}) {
  const persist = options.persist !== false;
  buyOrder = order || null;
  document.getElementById('buyOrderId').value = String(order?.orderId || '');
  document.getElementById('buyPaymentNote').value = String(order?.paymentNote || '');

  if (order?.planId) {
    buySelectedPlanId = String(order.planId || '').trim();
  }

  if (persist) {
    await writeSavedBuyOrder(order || null);
  }

  if (!order) {
    stopBuyCountdown();
    document.getElementById('buyOrderMeta').textContent = 'No active buy order yet.';
    updateBuyQr();
    return;
  }

  const approved = String(order.status || '').trim().toLowerCase() === 'approved';
  const expired = String(order.status || '').trim().toLowerCase() === 'expired';
  if (approved) {
    document.getElementById('buyOrderMeta').textContent =
      `Order approved.\nPlan: ${order.planLabel || 'License'}\nOrder ID: ${order.orderId}\nLicense expires: ${order.licenseExpiresAtLabel || order.licenseExpiresAt}`;
    setStatus('Payment approved. Restoring license for this computer...');
    stopBuyPolling();
    stopBuyCountdown();
    await refreshLicenseUi();
    return;
  }

  if (expired) {
    await expireBuyQrLocally();
    return;
  }

  document.getElementById('buyOrderMeta').textContent =
    `Order prepared.\nPlan: ${order.planLabel || 'License'}\nOrder ID: ${order.orderId}\nStatus: ${order.status}\nBakong ID: ${order.bakongAccountId || 'Not configured'}`;
  updateBuyQr();
  startBuyCountdown(order.orderExpiresAt);
}

function stopBuyPolling() {
  if (!buyPollTimer) return;
  window.clearInterval(buyPollTimer);
  buyPollTimer = null;
}

function startBuyPolling(orderId) {
  stopBuyPolling();
  if (!orderId) return;
  const tick = async () => {
    try {
      const data = await buyApi(`/api/buy/order-status?orderId=${encodeURIComponent(orderId)}`, {
        method: 'GET'
      });
      if (data?.order) {
        await renderBuyOrder(data.order);
      }
    } catch {
      // Keep the last visible buy status if polling fails temporarily.
    }
  };
  tick().catch(() => {});
  buyPollTimer = window.setInterval(() => {
    tick().catch(() => {});
  }, BUY_ORDER_POLL_INTERVAL_MS);
}

async function loadBuyConfig(options = {}) {
  const force = options.force === true;
  if (buyConfigLoaded && !force && buyConfig) return buyConfig;

  const data = await buyApi('/api/buy/config', { method: 'GET' });
  buyConfig = data?.config || null;
  buyConfigLoaded = true;

  const firstPlan = Array.isArray(buyConfig?.plans) ? buyConfig.plans[0] : null;
  if (!buySelectedPlanId) {
    buySelectedPlanId = String(firstPlan?.id || '');
  }
  renderBuyPlanCards();
  renderBuyConfigSummary();
  updateBuyQr();
  return buyConfig;
}

async function restoreSavedBuyOrder() {
  const savedOrder = await readSavedBuyOrder();
  if (!savedOrder) return;
  buyOrder = savedOrder;
  if (savedOrder?.planId) {
    buySelectedPlanId = String(savedOrder.planId || '').trim();
  }
}

async function handlePrepareBuyOrder() {
  const requestSequence = ++buyPrepareSequence;
  const previousOrder = buyOrder ? { ...buyOrder } : null;

  try {
    await loadBuyConfig();
    const configEnabled = Boolean(buyConfig?.enabled);
    if (!configEnabled) {
      setStatus('Buy flow is not configured on the server yet.');
      return;
    }

    const deviceId = String(document.getElementById('licenseDeviceId').textContent || '').trim();
    if (!deviceId || deviceId === 'Loading...' || deviceId === 'Unavailable') {
      setStatus('Device ID is not ready yet.');
      return;
    }

    const selectedPlan = getSelectedBuyPlan();
    if (!selectedPlan?.id) {
      setStatus('No buy plan is configured yet.');
      return;
    }

    stopBuyPolling();
    stopBuyCountdown();
    setBuyModalStage('qr');
    buyPrepareInFlight = true;
    buyPreparingPlanLabel = String(selectedPlan.label || 'license').trim();
    buyOrder = null;
    updateBuyQr();
    setStatus(`Preparing ${selectedPlan.label || 'license'} KHQR order...`);
    const data = await buyApi('/api/buy/request', {
      method: 'POST',
      body: JSON.stringify({
        deviceId,
        planId: selectedPlan.id
      })
    });
    if (requestSequence !== buyPrepareSequence) return;
    buyConfig = data?.config || buyConfig;
    renderBuyPlanCards();
    renderBuyConfigSummary();
    await renderBuyOrder(data?.order || null);
    if (data?.order?.orderId) {
      startBuyPolling(data.order.orderId);
    }
    setStatus(`Prepared ${selectedPlan.label || 'license'} order.`);
  } catch (error) {
    if (requestSequence === buyPrepareSequence && previousOrder) {
      await renderBuyOrder(previousOrder, { persist: false });
    } else if (requestSequence === buyPrepareSequence) {
      buyOrder = null;
      updateBuyQr();
    }
    setStatus(error?.message || 'Could not prepare the KHQR order.');
  } finally {
    if (requestSequence === buyPrepareSequence) {
      buyPrepareInFlight = false;
      buyPreparingPlanLabel = '';
      updateBuyQr();
    }
  }
}

async function handleOpenBuyPage() {
  try {
    const serverUrl = await SoraLicense.getStoredServerUrl(chrome.storage.local);
    const deviceId = String(document.getElementById('licenseDeviceId').textContent || '').trim();
    const url = new URL('/buy', `${serverUrl}/`);
    if (deviceId && deviceId !== 'Loading...' && deviceId !== 'Unavailable') {
      url.searchParams.set('deviceId', deviceId);
    }
    if (buySelectedPlanId) {
      url.searchParams.set('plan', buySelectedPlanId);
    }
    await chrome.tabs.create({ url: url.toString() });
    setStatus('Opened the full KHQR payment page.');
  } catch (error) {
    setStatus(error?.message || 'Could not open the full KHQR page.');
  }
}

async function handleBuyLicense() {
  const panel = document.getElementById('buyPanel');
  const nextVisible = Boolean(panel?.hidden);
  setBuyPanelVisible(nextVisible);
  if (!nextVisible) return;

  try {
    await loadBuyConfig();
    await restoreSavedBuyOrder();
    resetBuyModalToPlans();
    setStatus('KHQR buy panel is ready.');
  } catch (error) {
    setStatus(error?.message || 'Could not load the KHQR buy panel.');
  }
}

async function readClipboardTextSafely() {
  if (!navigator.clipboard?.readText) return '';
  try {
    return String(await navigator.clipboard.readText() || '').trim();
  } catch {
    return '';
  }
}

function looksLikeLicenseToken(value) {
  const text = String(value || '').trim();
  return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(text);
}

async function activateLicenseKeyValue(key, successLabel = 'License activated.') {
  if (licenseActivationBusy) return false;
  licenseActivationBusy = true;
  if (!globalThis.SoraLicense) {
    setStatus('License module is unavailable.');
    licenseActivationBusy = false;
    return false;
  }

  try {
    const result = await SoraLicense.activateLicenseToken(key, chrome.storage.local);
    await refreshLicenseUi();
    if (result.valid) {
      const input = document.getElementById('licenseKeyInput');
      if (input) input.value = '';
      setStatus(successLabel);
      return true;
    }
    setStatus(result.reason || 'License activation failed.');
    return false;
  } catch (error) {
    setStatus(error?.message || 'License activation failed.');
    return false;
  } finally {
    licenseActivationBusy = false;
  }
}

async function maybeAutoActivateFromClipboard() {
  if (autoClipboardLicenseTried) return false;
  autoClipboardLicenseTried = true;

  const clipboardText = await readClipboardTextSafely();
  if (!looksLikeLicenseToken(clipboardText)) return false;

  const input = document.getElementById('licenseKeyInput');
  if (input) input.value = clipboardText;
  return await activateLicenseKeyValue(clipboardText, 'License activated from clipboard.');
}

async function handleActivateLicense() {
  const input = document.getElementById('licenseKeyInput');
  let key = String(input?.value || '').trim();
  if (!key) {
    key = await readClipboardTextSafely();
    if (key) {
      if (input) input.value = key;
    }
  }
  if (!key) {
    setStatus('Paste a license key or copy it to clipboard first.');
    return;
  }

  if (!looksLikeLicenseToken(key)) {
    setStatus('Clipboard/input does not contain a valid license key format yet.');
    return;
  }

  await activateLicenseKeyValue(key, 'License activated.');
}

async function maybeActivateFromInputField() {
  const input = document.getElementById('licenseKeyInput');
  const key = String(input?.value || '').trim();
  if (!looksLikeLicenseToken(key)) return false;
  return await activateLicenseKeyValue(key, 'License activated from pasted key.');
}

async function handleClearLicense() {
  if (!globalThis.SoraLicense) {
    setStatus('License module is unavailable.');
    return;
  }

  try {
    await SoraLicense.clearStoredLicense(chrome.storage.local);
    const input = document.getElementById('licenseKeyInput');
    if (input) input.value = '';
    await refreshLicenseUi();
    setStatus('License key cleared.');
  } catch {
    setStatus('Could not clear the license key.');
  }
}

async function handleServerUrlChange() {
  if (!globalThis.SoraLicense) {
    setStatus('License module is unavailable.');
    return;
  }

  const input = document.getElementById('licenseServerUrl');
  const nextUrl = String(input?.value || '').trim();
  try {
    const savedUrl = await SoraLicense.setStoredServerUrl(nextUrl, chrome.storage.local);
    await refreshLicenseServerUi();
    await refreshLicenseUi();
    setStatus(`Saved license server: ${savedUrl}`);
  } catch (error) {
    setStatus(error?.message || 'Could not save the license server URL.');
  }
}

function setInlinePostRunning(running) {
  inlinePostRunning = Boolean(running);
  if (inlinePostRunning) {
    document.getElementById('postRunMeta').textContent = 'Posting drafts from the current tab...';
  }
  updateControls();
}

function setInlineDeleteRunning(running) {
  inlineDeleteRunning = Boolean(running);
  if (inlineDeleteRunning) {
    document.getElementById('deleteRunMeta').textContent = 'Deleting videos from the current page...';
  }
  updateControls();
}

function setDownloadRequestPending(running) {
  downloadRequestPending = Boolean(running);
  if (downloadRequestPending) {
    document.getElementById('downloadRunMeta').textContent = 'Preparing one-click download queue...';
  }
  updateControls();
}

function isPublishedProjectUrl(url) {
  return /^https:\/\/sora\.chatgpt\.com\/p\/s_[a-z0-9]+\/?$/i.test(String(url || '').trim());
}

function isSoraUrl(url) {
  return /^https:\/\/sora\.chatgpt\.com\/?/i.test(String(url || '').trim());
}

function isDraftsPageUrl(url) {
  return /^https:\/\/sora\.chatgpt\.com\/drafts\/?$/i.test(String(url || '').trim());
}

function detectPopupContext(url) {
  if (isDraftsPageUrl(url)) return 'drafts';
  if (isDraftUrl(url) || isPublishedProjectUrl(url)) return 'post';
  if (isSoraUrl(url)) return 'delete';
  return 'general';
}

function getEffectiveViewMode() {
  if (popupViewMode === 'post' || popupViewMode === 'delete' || popupViewMode === 'all') {
    return popupViewMode;
  }

  return 'all';
}

function setActiveViewButton(buttonId, active) {
  const button = document.getElementById(buttonId);
  if (!button) return;
  button.classList.toggle('active', Boolean(active));
}

function applyPopupView() {
  const quickCopyButton = document.getElementById('quickCopyVideoUrls');
  const quickDeleteButton = document.getElementById('quickDeleteNow');
  const quickOpenButton = document.getElementById('quickOpenHidden');
  const quickDownloadButton = document.getElementById('quickDownloadAll');
  const stopOpenButton = document.getElementById('stopOpenQueue');
  const toolPanels = document.getElementById('toolPanels');
  const viewMeta = document.getElementById('viewMeta');

  quickCopyButton.hidden = false;
  quickDeleteButton.hidden = false;
  quickOpenButton.hidden = true;
  if (quickDownloadButton) quickDownloadButton.hidden = false;
  if (stopOpenButton) stopOpenButton.hidden = true;
  if (toolPanels) toolPanels.hidden = true;

  setActiveViewButton('viewPost', popupViewMode === 'post');
  setActiveViewButton('viewDelete', popupViewMode === 'delete');
  setActiveViewButton('viewAll', popupViewMode === 'all');

  const contextLabel = popupContext === 'drafts'
    ? 'Drafts page detected'
    : popupContext === 'post'
      ? 'Post page detected'
      : popupContext === 'delete'
        ? 'Delete page detected'
        : 'General page detected';
  const viewLabel = 'Quick actions only';
  viewMeta.textContent = `${contextLabel}. ${viewLabel}.`;
}

async function setPopupViewMode(mode, options = {}) {
  popupViewMode = ['post', 'delete', 'all'].includes(mode) ? mode : 'all';
  applyPopupView();
  if (options.persist === false) return;
  await chrome.storage.local.set({ [POPUP_VIEW_MODE_KEY]: popupViewMode });
}

function escapeHtml(value) {
  return String(value || '').replace(/[&<>"']/g, char => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  }[char]));
}

function shortenUrl(url, maxLength = 54) {
  const value = String(url || '');
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength - 1)}...`;
}

function extractVideoIdFromUrl(value) {
  const text = String(value || '').trim();
  const match = text.match(/\/(?:p\/)?(s_[a-z0-9_-]{8,})\/?$/i)
    || text.match(/\/(?:d\/)?(gen_[a-z0-9_-]{8,})\/?$/i)
    || text.match(/\b(s_[a-z0-9_-]{8,}|gen_[a-z0-9_-]{8,}|sora_[a-z0-9]+)\b/i);
  return match?.[1] || '';
}

function isDraftUrl(url) {
  return /^https:\/\/sora\.chatgpt\.com\/d\/[^/?#]+\/?$/i.test(String(url || '').trim());
}

function isProjectUrl(url) {
  return /^https:\/\/sora\.chatgpt\.com\/(?:p\/s_[a-z0-9]+|d\/[^/?#]+)\/?$/i.test(String(url || '').trim());
}

function getDraftUrls() {
  return postCollected
    .map(item => item?.url || '')
    .filter(url => isDraftUrl(url));
}

function getDeleteUrls() {
  const seen = new Set();
  return deleteCollected
    .map(item => item?.url || '')
    .filter(url => {
      if (!isProjectUrl(url) || seen.has(url)) return false;
      seen.add(url);
      return true;
    });
}

function usesParallelDraftOpen(urlCount = 0) {
  return false;
}

function usesParallelDeleteOpen(urlCount = 0) {
  return false;
}

function getPublishedVideoUrls() {
  const seen = new Set();
  return [
    ...deleteCollected.map(item => item?.url || ''),
    ...postCollected.map(item => item?.url || ''),
    ...publishedVideoCollected
  ]
    .filter(url => /^https:\/\/sora\.chatgpt\.com\/p\/s_[a-z0-9]+\/?$/i.test(String(url || '').trim()))
    .filter(url => {
      if (seen.has(url)) return false;
      seen.add(url);
      return true;
    });
}

function getCopyableVideoUrls() {
  return getPublishedVideoUrls();
}

function mergePublishedVideoUrls(rawUrls = []) {
  const seen = new Set();
  const merged = [
    ...publishedVideoCollected,
    ...(Array.isArray(rawUrls) ? rawUrls : [])
  ]
    .filter(isPublishedProjectUrl)
    .filter(url => {
      const normalized = String(url || '').trim();
      if (!normalized || seen.has(normalized)) return false;
      seen.add(normalized);
      return true;
    });
  publishedVideoCollected = merged;
  return merged;
}

function persistPublishedVideoUrls(rawUrls = []) {
  const merged = mergePublishedVideoUrls(rawUrls);
  chrome.storage.local.set({ [PUBLISHED_VIDEO_STORAGE_KEY]: merged });
  return merged;
}

function uniqueProjectUrls(items) {
  const seen = new Set();
  const urls = [];

  (Array.isArray(items) ? items : []).forEach(item => {
    const url = typeof item === 'string' ? item : item?.url;
    if (!isProjectUrl(url) || seen.has(url)) return;
    seen.add(url);
    urls.push(url);
  });

  return urls;
}

function getAllKnownProjectUrls() {
  return uniqueProjectUrls([
    ...postCollected,
    ...deleteCollected
  ]);
}

async function copyTextToClipboard(text) {
  const value = String(text || '');
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

async function refreshDeleteResultsFromStorage() {
  const saved = await chrome.storage.local.get(DELETE_STORAGE_KEY);
  const deleteData = saved?.[DELETE_STORAGE_KEY] || { pageUrl: null, items: [] };
  renderDeleteResults(deleteData);
}

function formatPostRunMeta(state) {
  if (!state?.running && !state?.total) return 'Post queue idle.';
  if (state?.running) {
    const parts = [
      `Running ${state.done || 0}/${state.total || 0}`,
      `Posted ${state.posted || 0}`,
      `Failed ${state.failed || 0}`
    ];
    if (state.currentUrl) parts.push(shortenUrl(state.currentUrl));
    if (state.stopRequested) parts.push('Stopping...');
    return parts.join(' | ');
  }
  return state?.lastMessage || 'Post queue idle.';
}

function formatDeleteRunMeta(state) {
  if (!state?.running && !state?.total) return 'Delete queue idle.';
  if (state?.running) {
    const totalText = state.total ? String(state.total) : '?';
    const parts = [
      state.fastMode ? 'Fast' : 'Normal',
      `Running ${state.done || 0}/${totalText}`,
      `Deleted ${state.deleted || 0}`,
      `Failed ${state.failed || 0}`
    ];
    if (state.currentTitle) parts.push(state.currentTitle);
    else if (state.currentUrl) parts.push(shortenUrl(state.currentUrl));
    if (state.stopRequested) parts.push('Stopping...');
    return parts.join(' | ');
  }
  return state?.lastMessage || 'Delete queue idle.';
}

function formatOpenRunMeta(state) {
  if (!state?.running && !state?.total) return 'Hidden open queue idle.';
  if (state?.running) {
    const parts = [
      `Opening ${state.done || 0}/${state.total || 0}`
    ];
    if (state.currentUrl) parts.push(shortenUrl(state.currentUrl));
    if (state.stopRequested) parts.push('Stopping...');
    return parts.join(' | ');
  }
  return state?.lastMessage || 'Hidden open queue idle.';
}

function getFailedDownloadIds(state, limit = 3) {
  const failedResults = Array.isArray(state?.results)
    ? state.results.filter(item => item && item.ok === false && item.id)
    : [];
  if (!failedResults.length) return [];
  return failedResults.slice(-limit).map(item => item.id);
}

function formatDownloadRunMeta(state) {
  if (!state?.running && !state?.total) return 'Download queue idle.';
  if (state?.running) {
    const totalText = state.total ? String(state.total) : '?';
    const parts = [
      `Running ${state.done || 0}/${totalText}`,
      `Started ${state.started || 0}`,
      `Done ${state.completed || 0}`,
      `Failed ${state.failed || 0}`
    ];
    if (state.downloadedBeforeCount) {
      parts.push(`Skipped ${state.downloadedBeforeCount}`);
    }
    if (state.currentIndex) {
      parts.push(`#${state.currentIndex}`);
    }
    if (state.currentId) {
      parts.push(state.currentId);
    }
    const failedIds = getFailedDownloadIds(state, 2);
    if (failedIds.length) {
      parts.push(`Fail IDs: ${failedIds.join(', ')}`);
    }
    return parts.join(' | ');
  }
  const failedIds = getFailedDownloadIds(state, 3);
  if (failedIds.length) {
    return `${state?.lastMessage || 'Download queue idle.'} | Failed IDs: ${failedIds.join(', ')}`;
  }
  return state?.lastMessage || 'Download queue idle.';
}

function renderFailedDownloadUrls(urls = []) {
  failedDownloadUrls = Array.from(new Set((Array.isArray(urls) ? urls : [])
    .map(url => String(url || '').trim())
    .filter(Boolean)));

  const box = document.getElementById('failedDownloadsBox');
  const list = document.getElementById('failedDownloadsList');
  if (!box || !list) return;

  if (!failedDownloadUrls.length) {
    box.hidden = true;
    list.innerHTML = '<div class="failed-empty">No failed download URLs.</div>';
    return;
  }

  box.hidden = false;
  list.innerHTML = failedDownloadUrls.map(url => {
    const id = extractVideoIdFromUrl(url) || 'Unknown ID';
    return `
      <div class="failed-item">
        <div class="failed-id">${escapeHtml(id)}</div>
        <a class="failed-link" href="${escapeHtml(url)}" target="_blank">${escapeHtml(shortenUrl(url, 88))}</a>
      </div>
    `;
  }).join('');
}

async function refreshFailedDownloadUrls() {
  try {
    const res = await chrome.runtime.sendMessage({ action: 'get_failed_download_urls' });
    renderFailedDownloadUrls(res?.urls || []);
  } catch {
    renderFailedDownloadUrls([]);
  }
}

function startPolling() {
  if (pollTimer) return;
  pollTimer = window.setInterval(() => {
    refreshRunStates();
  }, 1000);
}

function stopPolling() {
  if (!pollTimer) return;
  window.clearInterval(pollTimer);
  pollTimer = null;
}

function updateControls() {
  const postRunning = Boolean(postRunState?.running) || inlinePostRunning;
  const deleteRunning = Boolean(deleteRunState?.running) || inlineDeleteRunning;
  const openRunning = Boolean(openRunState?.running);
  const downloadRunning = Boolean(downloadRunState?.running) || downloadRequestPending;
  const anyRunning = postRunning || deleteRunning || openRunning || downloadRunning;
  const hasDraftTargets = getDraftUrls().length > 0;
  const hasDeleteTargets = getDeleteUrls().length > 0;
  const hasVideoUrls = getCopyableVideoUrls().length > 0;

  const setDisabled = (id, value) => {
    const node = document.getElementById(id);
    if (node) node.disabled = value;
  };

  setDisabled('quickCopyVideoUrls', anyRunning || !hasVideoUrls);
  setDisabled('logoPostAllFound', anyRunning);
  setDisabled('quickPostFive', anyRunning);
  setDisabled('quickPostTen', anyRunning);
  setDisabled('quickDeleteNow', anyRunning);
  setDisabled('quickOpenHidden', anyRunning || !hasVideoUrls);
  setDisabled('quickDownloadAll', anyRunning);
  setDisabled('retryFailedDownloads', anyRunning || !failedDownloadUrls.length);
  setDisabled('clearFailedDownloads', anyRunning || !failedDownloadUrls.length);
  setDisabled('stopOpenQueue', !openRunning);
  setDisabled('scanPosts', anyRunning);
  setDisabled('copyPostUrls', anyRunning || !postCollected.length);
  setDisabled('clearPosts', anyRunning);
  setDisabled('postDraft', anyRunning);
  setDisabled('postAllFoundInline', anyRunning);
  setDisabled('startPostFive', anyRunning || !hasDraftTargets);
  setDisabled('startPostTen', anyRunning || !hasDraftTargets);
  setDisabled('startPostAll', anyRunning || !hasDraftTargets);
  setDisabled('stopPostQueue', !postRunning);

  setDisabled('scanDeletes', anyRunning);
  setDisabled('copyDeleteUrls', anyRunning || !getDeleteUrls().length);
  setDisabled('clearDeletes', anyRunning);
  setDisabled('deleteFive', anyRunning || !hasDeleteTargets);
  setDisabled('deleteTen', anyRunning || !hasDeleteTargets);
  setDisabled('deleteAll', anyRunning || !hasDeleteTargets);
  setDisabled('stopDeleteQueue', !deleteRunning);
  setDisabled('fastDeleteEnabled', anyRunning);

  renderPostList(postCollected);
  renderDeleteList(deleteCollected);
  applyPopupView();
}

async function refreshRunStates() {
  try {
    const [postRes, deleteRes, openRes, downloadRes] = await Promise.all([
      chrome.runtime.sendMessage({ action: 'get_run_status' }),
      chrome.runtime.sendMessage({ action: 'get_delete_run_status' }),
      chrome.runtime.sendMessage({ action: 'get_open_run_status' }),
      chrome.runtime.sendMessage({ action: 'get_download_run_status' })
    ]);
    postRunState = postRes?.state || { running: false, total: 0, lastMessage: 'Ready.' };
    deleteRunState = deleteRes?.state || { running: false, total: 0, lastMessage: 'Ready.' };
    openRunState = openRes?.state || { running: false, total: 0, lastMessage: 'Hidden open queue idle.' };
    downloadRunState = downloadRes?.state || { running: false, total: 0, lastMessage: 'Download queue idle.' };
    document.getElementById('postRunMeta').textContent = formatPostRunMeta(postRunState);
    document.getElementById('deleteRunMeta').textContent = formatDeleteRunMeta(deleteRunState);
    document.getElementById('openRunMeta').textContent = formatOpenRunMeta(openRunState);
    document.getElementById('downloadRunMeta').textContent = formatDownloadRunMeta(downloadRunState);
    await refreshFailedDownloadUrls().catch(() => {});
    updateControls();
    if (postRunState.running || deleteRunState.running || openRunState.running || downloadRunState.running || downloadRequestPending) startPolling();
    else stopPolling();
  } catch {
    postRunState = { running: false, total: 0, lastMessage: 'Ready.' };
    deleteRunState = { running: false, total: 0, lastMessage: 'Ready.' };
    openRunState = { running: false, total: 0, lastMessage: 'Hidden open queue idle.' };
    downloadRunState = { running: false, total: 0, lastMessage: 'Download queue idle.' };
    document.getElementById('postRunMeta').textContent = 'Post queue status unavailable.';
    document.getElementById('deleteRunMeta').textContent = 'Delete queue status unavailable.';
    document.getElementById('openRunMeta').textContent = 'Hidden open queue status unavailable.';
    document.getElementById('downloadRunMeta').textContent = 'Download queue status unavailable.';
    renderFailedDownloadUrls([]);
    stopPolling();
    updateControls();
  }
}

async function handleOpenHidden() {
  const videoUrls = getCopyableVideoUrls();
  if (!videoUrls.length) {
    setStatus('No video URLs found yet. Scan visible cards or scan post URLs first.');
    return;
  }

  try {
    setStatus(`Opening ${videoUrls.length} video URL(s) in the background worker tab...`);
    startPolling();
    const res = await chrome.runtime.sendMessage({
      action: 'open_hidden_urls',
      urls: videoUrls,
      limitLabel: 'All'
    });
    setStatus(res?.message || 'Hidden open queue finished.');
  } catch {
    setStatus('Could not open the video URLs in the background worker tab.');
  } finally {
    refreshRunStates();
  }
}

function renderPostList(items) {
  const box = document.getElementById('postList');
  if (!items.length) {
    box.innerHTML = '<div style="font-size:12px;color:#6b7280;">No Sora project or draft URL found yet.</div>';
    return;
  }

  const disabled = postRunState.running || deleteRunState.running || openRunState.running ? 'disabled' : '';
  box.innerHTML = items.map((item, index) => `
    <div class="item">
      <div>${index + 1}</div>
      <div>
        <a class="link" href="${escapeHtml(item.url)}" target="_blank">${escapeHtml(item.url)}</a>
      </div>
      <div style="display:flex;flex-direction:column;gap:6px;align-items:flex-end;">
        <div style="font-size:11px;color:#6b7280;">${escapeHtml(item.source || 'scan')}</div>
        <button class="mini post post-row-action" data-index="${index}" ${disabled}>${isDraftUrl(item.url) ? 'Post' : 'Draft'}</button>
      </div>
    </div>
  `).join('');

  box.querySelectorAll('.post-row-action').forEach(button => {
    button.addEventListener('click', async () => {
      const index = Number(button.getAttribute('data-index'));
      const item = postCollected[index];
      if (!item?.url) {
        setStatus('No Sora project URL available for this item.');
        return;
      }

      button.disabled = true;
      const originalText = button.textContent;
      button.textContent = 'Running...';

      try {
        setStatus(`Running ${isDraftUrl(item.url) ? 'Post' : 'Draft'} for ${item.url} in the background worker tab...`);
        const res = await chrome.runtime.sendMessage({
          action: 'post_draft_for_url',
          url: item.url
        });
        setStatus(res?.message || (res?.ok ? 'Post/Draft action clicked.' : 'Post/Draft action not found.'));
      } catch {
        setStatus('Could not open the URL and run Post/Draft.');
      } finally {
        button.disabled = false;
        button.textContent = originalText;
        refreshRunStates();
      }
    });
  });
}

function renderDeleteList(items) {
  const box = document.getElementById('deleteList');
  if (!items.length) {
    box.innerHTML = '<div style="font-size:12px;color:#6b7280;">No visible Sora video cards found yet.</div>';
    return;
  }

  const disabled = postRunState.running || deleteRunState.running || openRunState.running ? 'disabled' : '';
  box.innerHTML = items.map((item, index) => `
    <div class="item">
      <div>${index + 1}</div>
      <div>
        <div class="title">${escapeHtml(item.title || `Video ${index + 1}`)}</div>
        <a class="link" href="${escapeHtml(item.url)}" target="_blank">${escapeHtml(item.url)}</a>
      </div>
      <div>
        <button class="mini delete delete-row-action" data-index="${index}" ${disabled}>Delete</button>
      </div>
    </div>
  `).join('');

  box.querySelectorAll('.delete-row-action').forEach(button => {
    button.addEventListener('click', async () => {
      const index = Number(button.getAttribute('data-index'));
      const item = deleteCollected[index];
      if (!item?.url) {
        setStatus('No video URL available for this item.');
        return;
      }

      button.disabled = true;
      const originalText = button.textContent;
      button.textContent = 'Deleting...';

      try {
        const fastMode = document.getElementById('fastDeleteEnabled').checked;
        const runInlineDelete = popupContext === 'delete';
        if (runInlineDelete) {
          setStatus(`Deleting ${item.title || item.url} in the current page script...`);
          setInlineDeleteRunning(true);
        } else {
          setStatus(`Deleting ${item.title || item.url} in the background worker tab...`);
        }

        const res = runInlineDelete
          ? await sendMessageToActiveTab({
              action: 'delete_one_by_url',
              targetUrl: item.url,
              fastMode
            })
          : await chrome.runtime.sendMessage({
              action: 'delete_single_video',
              targetUrl: item.url,
              fastMode
            });

        setStatus(res?.message || (res?.ok ? 'Video deleted.' : 'Delete failed.'));
        if (res?.ok) {
          await refreshDeleteResultsFromStorage();
        }
      } catch {
        setStatus('Could not delete this video.');
      } finally {
        if (popupContext === 'delete') {
          setInlineDeleteRunning(false);
        }
        button.disabled = false;
        button.textContent = originalText;
        refreshRunStates();
      }
    });
  });
}

function renderPostResults(items, statusText) {
  postCollected = Array.isArray(items) ? items : [];
  document.getElementById('postResult').value = postCollected.map(item => item.url).join('\n');
  renderPostList(postCollected);
  if (statusText) setStatus(statusText);
  chrome.storage.local.set({ [POST_STORAGE_KEY]: postCollected });
  persistPublishedVideoUrls(postCollected.map(item => item?.url || ''));
}

function renderDeleteResults(data, statusText) {
  deletePageUrl = data?.pageUrl || null;
  deleteCollected = Array.isArray(data?.items) ? data.items : [];
  document.getElementById('deleteResult').value = deleteCollected.map(item => item.url).join('\n');
  renderDeleteList(deleteCollected);
  if (statusText) setStatus(statusText);
  chrome.storage.local.set({
    [DELETE_STORAGE_KEY]: {
      pageUrl: deletePageUrl,
      items: deleteCollected
    }
  });
  persistPublishedVideoUrls(deleteCollected.map(item => item?.url || ''));
}

function startPostQueue(limit, label) {
  const draftUrls = getDraftUrls();
  if (!draftUrls.length) {
    setStatus('No draft URLs found. Scan Post URLs first.');
    return;
  }

  const skipFailed = document.getElementById('skipPostFailed').checked;
  if (popupContext === 'drafts') {
    setStatus(`Starting ${label} post queue in the current tab, one-by-one...`);
    setInlinePostRunning(true);
    sendMessageToActiveTab({
      action: 'post_visible_drafts_inline',
      urls: draftUrls,
      limit,
      skipFailed,
      listPageUrl: 'https://sora.chatgpt.com/drafts'
    })
      .then(res => {
        setStatus(res?.message || 'Inline post queue finished.');
      })
      .catch(() => {
        setStatus('Inline post queue failed.');
      })
      .finally(() => {
        setInlinePostRunning(false);
      });
    return;
  }

  setStatus(popupContext === 'drafts'
    ? `Starting ${label} post queue in the current tab, one-by-one...`
    : `Starting ${label} post queue in the background tab...`);
  chrome.runtime.sendMessage({
    action: 'start_run_queue',
    urls: draftUrls,
    limit,
    limitLabel: label,
    skipFailed
  })
    .then(res => {
      setStatus(res?.message || 'Post queue finished.');
      refreshRunStates();
    })
    .catch(() => {
      setStatus('Post queue failed.');
      refreshRunStates();
    });
  startPolling();
}

function startDeleteQueue(limit, label) {
  const deleteUrls = getDeleteUrls();
  if (!deleteUrls.length) {
    setStatus('Scan visible cards first on a Sora profile/list page.');
    return;
  }

  const skipFailed = document.getElementById('skipDeleteFailed').checked;
  const fastMode = document.getElementById('fastDeleteEnabled').checked;
  if (popupContext === 'delete') {
    setStatus(`Starting ${label} delete queue in the current page, one-by-one...`);
    setInlineDeleteRunning(true);
    sendMessageToActiveTab({
      action: 'run_delete_queue',
      targetUrls: deleteUrls,
      limit,
      skipFailed,
      fastMode
    })
      .then(async res => {
        setStatus(res?.message || 'Inline delete queue finished.');
        await refreshDeleteResultsFromStorage().catch(() => {});
      })
      .catch(() => {
        setStatus('Inline delete queue failed.');
      })
      .finally(() => {
        setInlineDeleteRunning(false);
        refreshRunStates();
      });
    return;
  }

  setStatus(`Starting ${label} delete queue in the background tab...`);
  chrome.runtime.sendMessage({
    action: 'start_delete_queue',
    urls: deleteUrls,
    limit,
    limitLabel: label,
    skipFailed,
    fastMode
  })
    .then(res => {
      setStatus(res?.message || 'Delete queue finished.');
      refreshDeleteResultsFromStorage().catch(() => {});
      refreshRunStates();
    })
    .catch(() => {
      setStatus('Delete queue failed.');
      refreshRunStates();
    });
  startPolling();
}

async function handleQuickPost(limit = null, label = 'All Found') {
  const introLabel = limit ? `Post ${limit} Found` : 'Post All Found';
  setStatus(`Checking all found draft URLs for ${introLabel}...`);
  const draftUrls = await collectDraftUrlsForQuickPost();
  const targetUrls = limit ? draftUrls.slice(0, limit) : draftUrls.slice();

  if (!targetUrls.length) {
    setStatus('No draft URLs found on this page.');
    return;
  }

  if (popupContext === 'drafts' && targetUrls.length) {
    try {
      setStatus(`Opening ${targetUrls.length} found draft URL(s) in new background tabs, waiting for load, then clicking Post on all tabs...`);
      startPolling();
      const res = await chrome.runtime.sendMessage({
        action: 'start_run_queue',
        urls: targetUrls,
        limit: null,
        limitLabel: label,
        skipFailed: document.getElementById('skipPostFailed').checked,
        forceParallelTabs: true
      });
      setStatus(res?.message || 'Post queue finished.');
    } catch {
      setStatus(`${introLabel} failed.`);
    } finally {
      refreshRunStates();
    }
    return;
  }

  if (targetUrls.length > 1) {
    try {
      setStatus(`Opening ${targetUrls.length} found draft URL(s) in new background tabs, waiting for load, then posting all of them...`);
      startPolling();
      const res = await chrome.runtime.sendMessage({
        action: 'start_run_queue',
        urls: targetUrls,
        limit: null,
        limitLabel: label,
        skipFailed: document.getElementById('skipPostFailed').checked,
        forceParallelTabs: true
      });
      setStatus(res?.message || 'Post queue finished.');
    } catch {
      setStatus(`${introLabel} failed.`);
    } finally {
      refreshRunStates();
    }
    return;
  }

  try {
    setStatus(popupContext === 'drafts'
      ? 'Opening this draft in the current tab and clicking Post...'
      : 'Running Post/Draft in the background worker tab...');
    const res = await chrome.runtime.sendMessage({
      action: 'post_draft_for_url',
      url: targetUrls[0] || null
    });
    setStatus(res?.message || (res?.ok ? 'Post/Draft action clicked.' : 'Post/Draft action not found.'));
  } catch {
    setStatus('Post failed. Scan Post URLs first or open a Sora project/draft page.');
  } finally {
    refreshRunStates();
  }
}

async function handlePostNow() {
  return handleQuickPost(null, 'All');
}

async function handleDeleteNow() {
  setStatus('Checking Sora video URLs for Delete All Found...');
  const deleteUrls = await collectDeleteUrlsForQuickDelete();
  if (!deleteUrls.length) {
    setStatus('No video URLs found on this page.');
    return;
  }

  if (popupContext === 'delete' && deleteUrls.length === 1) {
    try {
      setStatus('Deleting this found video URL from the current page...');
      setInlineDeleteRunning(true);
      const res = await sendMessageToActiveTab({
        action: 'run_delete_queue',
        targetUrls: deleteUrls,
        limit: null,
        skipFailed: document.getElementById('skipDeleteFailed').checked,
        fastMode: document.getElementById('fastDeleteEnabled').checked
      });
      setStatus(res?.message || 'Inline delete queue finished.');
      await refreshDeleteResultsFromStorage().catch(() => {});
    } catch {
      setStatus('Delete All Found failed.');
    } finally {
      setInlineDeleteRunning(false);
      refreshRunStates();
    }
    return;
  }

  try {
    setStatus(popupContext === 'delete'
      ? `Opening ${deleteUrls.length} found video URL(s) in new background tabs and deleting all of them...`
      : `Opening and deleting ${deleteUrls.length} found video URL(s) in the background tab...`);
    startPolling();
    const res = await chrome.runtime.sendMessage({
      action: 'start_delete_queue',
      urls: deleteUrls,
      limit: null,
      limitLabel: 'All',
      skipFailed: document.getElementById('skipDeleteFailed').checked,
      fastMode: document.getElementById('fastDeleteEnabled').checked,
      forceParallelTabs: popupContext === 'delete' && deleteUrls.length > 1
    });
    setStatus(res?.message || 'Delete queue finished.');
    refreshDeleteResultsFromStorage().catch(() => {});
  } catch {
    setStatus('Delete All Found failed.');
  } finally {
    refreshRunStates();
  }
}

async function handleCopyVideoUrls() {
  const videoUrls = await collectVideoUrlsForQuickCopy();
  if (!videoUrls.length) {
    setStatus('No video URLs found on this page.');
    return;
  }

  try {
    await copyTextToClipboard(videoUrls.join('\n'));
    setStatus(`Copied ${videoUrls.length} video URL(s).`);
  } catch {
    setStatus('Could not copy the video URLs.');
  }
}

async function collectVideoUrlsForQuickCopy() {
  if (popupContext === 'delete') {
    try {
      const res = await sendMessageToActiveTab('scan_profile_videos');
      if (res?.ok && Array.isArray(res.items) && res.items.length) {
        renderDeleteResults(res, res.message || `Found ${res.items.length} visible video card(s).`);
        return uniqueProjectUrls(res.items);
      }
    } catch {}
  }

  if (popupContext === 'drafts' || popupContext === 'post') {
    try {
      const res = await sendMessageToActiveTab('scan_project_urls');
      const items = Array.isArray(res?.urls) ? res.urls : [];
      if (items.length) {
        renderPostResults(items, `Found ${items.length} Sora URL(s).`);
        return uniqueProjectUrls(items);
      }
    } catch {}
  }

  return getCopyableVideoUrls();
}

async function collectDraftUrlsForQuickPost() {
  try {
    const res = await sendMessageToActiveTab('scan_project_urls');
    const items = Array.isArray(res?.urls) ? res.urls : [];
    if (items.length) {
      renderPostResults(items, `Found ${items.length} Sora URL(s).`);
      return uniqueProjectUrls(items).filter(isDraftUrl);
    }
  } catch {}

  const existing = getDraftUrls();
  if (existing.length) return existing;

  return getDraftUrls();
}

async function collectDeleteUrlsForQuickDelete() {
  try {
    const res = await sendMessageToActiveTab('scan_profile_videos');
    if (res?.ok && Array.isArray(res.items) && res.items.length) {
      renderDeleteResults(res, res.message || `Found ${res.items.length} visible video card(s).`);
      return uniqueProjectUrls(res.items);
    }
  } catch {}

  const existing = getDeleteUrls();
  if (existing.length) return existing;

  return getDeleteUrls();
}

async function collectUrlsForDownload() {
  if (popupContext === 'delete') {
    try {
      const res = await sendMessageToActiveTab('scan_profile_videos');
      if (res?.ok && Array.isArray(res.items) && res.items.length) {
        renderDeleteResults(res, res.message || `Found ${res.items.length} visible video card(s).`);
        const urls = uniqueProjectUrls(res.items).filter(isPublishedProjectUrl);
        if (urls.length) return urls;
      }
    } catch {}
  }

  if (popupContext === 'drafts' || popupContext === 'post') {
    try {
      const res = await sendMessageToActiveTab('scan_project_urls');
      const items = Array.isArray(res?.urls) ? res.urls : [];
      if (items.length) {
        renderPostResults(items, `Found ${items.length} Sora URL(s).`);
        const urls = uniqueProjectUrls(items).filter(isPublishedProjectUrl);
        if (urls.length) return urls;
      }
    } catch {}
  }

  const cachedUrls = getPublishedVideoUrls();
  if (cachedUrls.length) return cachedUrls;

  return getCopyableVideoUrls().filter(isPublishedProjectUrl);
}

async function handleDownloadAll() {
  if (downloadRequestPending || downloadRunState?.running) {
    setStatus(downloadRunState?.lastMessage || 'Download queue is already running.');
    return;
  }

  setDownloadRequestPending(true);
  try {
    const failedRes = await chrome.runtime.sendMessage({ action: 'get_failed_download_urls' }).catch(() => null);
    const failedUrls = Array.isArray(failedRes?.urls) ? failedRes.urls : [];
    const retryFailedOnly = failedUrls.length > 0;
    setStatus(retryFailedOnly
      ? `Retrying ${failedUrls.length} failed download URL(s) only...`
      : 'Collecting Sora URLs for one-click download...');
    const urls = retryFailedOnly ? failedUrls : await collectUrlsForDownload();
    if (!urls.length) {
      setStatus('No Sora video URLs found to download.');
      document.getElementById('downloadRunMeta').textContent = 'Download queue idle.';
      return;
    }

    startPolling();
    const res = await chrome.runtime.sendMessage({
      action: 'download_sora_urls',
      urls
    });
    setStatus(res?.message || `Started ${urls.length} download(s).`);
    await refreshRunStates();
  } catch {
    setStatus('Could not start the one-click download action.');
    document.getElementById('downloadRunMeta').textContent = 'Download queue failed to start.';
  } finally {
    setDownloadRequestPending(false);
    await refreshRunStates().catch(() => {});
  }
}

async function handleRetryFailedDownloads() {
  if (!failedDownloadUrls.length) {
    setStatus('No failed download URLs to retry.');
    return;
  }
  await handleDownloadAll();
}

async function handleClearFailedDownloads() {
  try {
    await chrome.runtime.sendMessage({ action: 'clear_failed_download_urls' });
    renderFailedDownloadUrls([]);
    setStatus('Cleared failed download URLs.');
  } catch {
    setStatus('Could not clear the failed download URLs.');
  } finally {
    updateControls();
  }
}

document.getElementById('quickCopyVideoUrls').addEventListener('click', handleCopyVideoUrls);
document.getElementById('logoPostAllFound').addEventListener('click', handlePostNow);
document.getElementById('quickPostFive')?.addEventListener('click', () => handleQuickPost(5, '5'));
document.getElementById('quickPostTen')?.addEventListener('click', () => handleQuickPost(10, '10'));
document.getElementById('quickDeleteNow').addEventListener('click', handleDeleteNow);
document.getElementById('quickOpenHidden').addEventListener('click', handleOpenHidden);
document.getElementById('quickDownloadAll').addEventListener('click', handleDownloadAll);
document.getElementById('retryFailedDownloads').addEventListener('click', handleRetryFailedDownloads);
document.getElementById('clearFailedDownloads').addEventListener('click', handleClearFailedDownloads);
document.getElementById('copyDeviceId').addEventListener('click', handleCopyDeviceId);
document.getElementById('copyLicenseKey')?.addEventListener('click', handleCopyLicenseKey);
document.getElementById('buyLicenseBtn').addEventListener('click', handleBuyLicense);
document.getElementById('buyCloseBtn').addEventListener('click', () => {
  resetBuyModalToPlans();
  setBuyPanelVisible(false);
  setStatus('Closed KHQR buy panel.');
});
document.getElementById('clearLicense')?.addEventListener('click', handleClearLicense);
document.getElementById('licenseServerUrl').addEventListener('change', () => {
  handleServerUrlChange().catch(() => {});
});
document.getElementById('licenseServerUrl').addEventListener('blur', () => {
  handleServerUrlChange().catch(() => {});
});
document.getElementById('viewPost').addEventListener('click', () => setPopupViewMode('post'));
document.getElementById('viewDelete').addEventListener('click', () => setPopupViewMode('delete'));
document.getElementById('viewAll').addEventListener('click', () => setPopupViewMode('all'));

document.getElementById('scanPosts').addEventListener('click', async () => {
  try {
    setStatus('Scanning for Sora project and draft URLs...');
    const res = await sendMessageToActiveTab('scan_project_urls');
    const urls = res?.urls || [];
    renderPostResults(urls, `Found ${urls.length} Sora URL(s).`);
  } catch {
    setStatus('Post scan failed. Open Sora, refresh the page, and try again.');
  }
});

document.getElementById('copyPostUrls').addEventListener('click', async () => {
  if (!postCollected.length) {
    setStatus('No Sora post URLs found yet. Scan Post URLs first.');
    return;
  }

  try {
    await copyTextToClipboard(postCollected.map(item => item.url).join('\n'));
    setStatus(`Copied ${postCollected.length} Sora post URL(s).`);
  } catch {
    setStatus('Could not copy the post URLs.');
  }
});

document.getElementById('clearPosts').addEventListener('click', async () => {
  try {
    await sendMessageToActiveTab('clear_project_urls');
    await chrome.runtime.sendMessage({ action: 'clear_processed_drafts' });
  } catch {}
  renderPostResults([], 'Cleared saved post URLs.');
});

document.getElementById('postDraft').addEventListener('click', handlePostNow);
document.getElementById('postAllFoundInline').addEventListener('click', handlePostNow);

document.getElementById('startPostFive').addEventListener('click', () => startPostQueue(5, '5'));
document.getElementById('startPostTen').addEventListener('click', () => startPostQueue(10, '10'));
document.getElementById('startPostAll').addEventListener('click', () => startPostQueue(null, 'All'));

document.getElementById('stopPostQueue').addEventListener('click', async () => {
  try {
    const res = popupContext === 'drafts'
      ? await sendMessageToActiveTab({ action: 'request_stop_inline_post_queue' })
      : await chrome.runtime.sendMessage({ action: 'stop_run_queue' });
    setStatus(res?.message || 'Stop requested.');
  } catch {
    setStatus('Could not stop the post queue.');
  } finally {
    refreshRunStates();
  }
});

document.getElementById('scanDeletes').addEventListener('click', async () => {
  try {
    setStatus('Scanning visible Sora video cards...');
    const res = await sendMessageToActiveTab('scan_profile_videos');
    if (!res?.ok) {
      setStatus(res?.message || 'Delete scan failed.');
      renderDeleteResults({ pageUrl: null, items: [] });
      return;
    }
    renderDeleteResults(res, res.message || `Found ${res.items?.length || 0} visible video card(s).`);
  } catch {
    setStatus('Delete scan failed. Open a Sora profile/list page, refresh it, and try again.');
  }
});

document.getElementById('clearDeletes').addEventListener('click', async () => {
  try {
    await sendMessageToActiveTab('clear_delete_scan');
  } catch {}
  renderDeleteResults({ pageUrl: null, items: [] }, 'Cleared saved delete scan.');
});

document.getElementById('copyDeleteUrls').addEventListener('click', handleCopyVideoUrls);

document.getElementById('deleteFive').addEventListener('click', () => startDeleteQueue(5, '5'));
document.getElementById('deleteTen').addEventListener('click', () => startDeleteQueue(10, '10'));
document.getElementById('deleteAll').addEventListener('click', () => startDeleteQueue(null, 'All'));

document.getElementById('stopDeleteQueue').addEventListener('click', async () => {
  try {
    const res = popupContext === 'delete'
      ? await sendMessageToActiveTab({ action: 'request_stop_delete_queue' })
      : await chrome.runtime.sendMessage({ action: 'stop_delete_queue' });
    setStatus(res?.message || 'Stop requested.');
  } catch {
    setStatus('Could not stop the delete queue.');
  } finally {
    refreshRunStates();
  }
});

document.getElementById('stopOpenQueue').addEventListener('click', async () => {
  try {
    const res = await chrome.runtime.sendMessage({ action: 'stop_open_queue' });
    setStatus(res?.message || 'Stop requested.');
  } catch {
    setStatus('Could not stop the hidden open queue.');
  } finally {
    refreshRunStates();
  }
});

document.getElementById('fastDeleteEnabled').addEventListener('change', async event => {
  const enabled = Boolean(event.target.checked);
  await chrome.storage.local.set({ [DELETE_FAST_MODE_KEY]: enabled });
  setStatus(enabled
    ? 'Fast Delete Mode is enabled.'
    : 'Fast Delete Mode is disabled.');
});

(async function init() {
  const activeTab = await getActiveTab().catch(() => null);
  popupContext = detectPopupContext(activeTab?.url || '');
  const saved = await chrome.storage.local.get([
    POST_STORAGE_KEY,
    AUTO_POST_KEY,
    DELETE_STORAGE_KEY,
    PUBLISHED_VIDEO_STORAGE_KEY,
    DELETE_FAST_MODE_KEY,
    SHOW_ALL_TOOLS_KEY,
    POPUP_VIEW_MODE_KEY
  ]);
  const postItems = saved?.[POST_STORAGE_KEY] || [];
  const deleteData = saved?.[DELETE_STORAGE_KEY] || { pageUrl: null, items: [] };
  publishedVideoCollected = Array.isArray(saved?.[PUBLISHED_VIDEO_STORAGE_KEY])
    ? mergePublishedVideoUrls(saved[PUBLISHED_VIDEO_STORAGE_KEY])
    : [];

  document.getElementById('skipPostFailed').checked = true;
  document.getElementById('skipDeleteFailed').checked = true;
  document.getElementById('fastDeleteEnabled').checked = saved?.[DELETE_FAST_MODE_KEY] !== false;
  await chrome.storage.local.set({ [AUTO_POST_KEY]: false });

  const savedViewMode = typeof saved?.[POPUP_VIEW_MODE_KEY] === 'string'
    ? saved[POPUP_VIEW_MODE_KEY]
    : saved?.[SHOW_ALL_TOOLS_KEY] === true
      ? 'all'
      : 'all';
  await setPopupViewMode(savedViewMode, { persist: false });

  if (postItems.length) renderPostResults(postItems);
  else renderPostList([]);

  if (Array.isArray(deleteData.items) && deleteData.items.length) renderDeleteResults(deleteData);
  else renderDeleteList([]);

  const licenseState = await refreshLicenseUi();
  await refreshLicenseServerUi();
  await refreshIntegrityUi();
  if (!licenseState?.valid) {
    await maybeAutoActivateFromClipboard();
  }
  await refreshRunStates();
  await refreshFailedDownloadUrls();
})();
