// ── State ──
let enabled = true;
let interceptAll = true;   // intercept ALL downloads, no exceptions
const XDM_SCHEME = "dmx";

// Load persisted settings
browser.storage.local.get(["xdmEnabled", "interceptAll"]).then(r => {
  enabled      = r.xdmEnabled    ?? true;
  interceptAll = r.interceptAll  ?? true;
});

browser.storage.onChanged.addListener((changes) => {
  if (changes.xdmEnabled)    enabled      = changes.xdmEnabled.newValue;
  if (changes.interceptAll)  interceptAll = changes.interceptAll.newValue;
});

// Helper to determine ignored URL protocols/schemes
function shouldIgnoreUrl(url) {
  if (!url) return true;
  const ignoredPrefixes = [
    "dmx://",
    "about:",
    "chrome://",
    "moz-extension://",
    "safari-web-extension://"
  ];
  return ignoredPrefixes.some(prefix => url.startsWith(prefix));
}

// ──────────────────────────────────────────────────────────────
// PRIMARY: Intercept every download the browser tries to start
// ──────────────────────────────────────────────────────────────
browser.downloads.onCreated.addListener((downloadItem) => {
  if (!enabled) return;

  const url = downloadItem.url || downloadItem.finalUrl;
  if (shouldIgnoreUrl(url)) return;

  console.log("[XDM] Intercepting download:", url);

  // 1. CANCEL the browser download immediately
  browser.downloads.cancel(downloadItem.id).catch(() => {});

  // 2. Fire deep link into XDM
  openInXdm(url, downloadItem.filename || "");
});

// ──────────────────────────────────────────────────────────────
// SECONDARY: Intercept magnet: link navigation before it navigates
// ──────────────────────────────────────────────────────────────
browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (!enabled) return {};
    if (details.url && details.url.startsWith("magnet:")) {
      console.log("[XDM] Intercepting magnet:", details.url);
      openInXdm(details.url, "");
      return { cancel: true };          // block the navigation
    }
    return {};
  },
  { urls: ["<all_urls>"] },
  ["blocking"]
);

// ──────────────────────────────────────────────────────────────
// Listen for messages from content.js (e.g. blob downloads)
// ──────────────────────────────────────────────────────────────
browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === "blobDownload") {
    if (!enabled) return;
    console.log("[XDM] Blob download captured:", msg.filename);
    openInXdm(msg.url, msg.filename || "download");
  }
});

// ──────────────────────────────────────────────────────────────
// Build & fire the dmx:// deep link
// ──────────────────────────────────────────────────────────────
function openInXdm(url, filename) {
  const encoded = encodeURIComponent(url);
  let deepLink = `${XDM_SCHEME}://add?url=${encoded}`;
  if (filename) {
    deepLink += `&name=${encodeURIComponent(filename)}`;
  }
  deepLink += `&source=browser_ext`;

  browser.tabs.create({ url: deepLink }).catch((err) => {
    console.warn("[XDM] Could not open XDM app via tabs.create:", err);
    // Fallback: try as a navigation in the current tab
    browser.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
      if (tabs[0] && tabs[0].id) {
        browser.tabs.update(tabs[0].id, { url: deepLink });
      }
    }).catch(e => console.error("[XDM] Fallback tab update failed:", e));
  });
}
