const browserAPI = typeof browser !== "undefined" ? browser : chrome;

let enabled = true;

browserAPI.storage.local.get("xdmEnabled", (r) => {
  if (r && typeof r.xdmEnabled !== "undefined") {
    enabled = r.xdmEnabled;
  }
});

browserAPI.storage.onChanged.addListener((changes) => {
  if (changes.xdmEnabled) {
    enabled = changes.xdmEnabled.newValue;
  }
});

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

// ── Intercept every Safari download ──
browserAPI.downloads.onCreated.addListener((downloadItem) => {
  if (!enabled) return;

  const url = downloadItem.url || downloadItem.finalUrl;
  if (shouldIgnoreUrl(url)) return;

  console.log("[XDM] Safari download intercept:", url);

  // Cancel the Safari download
  try {
    browserAPI.downloads.cancel(downloadItem.id, () => {});
  } catch (e) {
    console.warn("[XDM] Failed to cancel browser download:", e);
  }

  // Build deep link
  const encoded = encodeURIComponent(url);
  let deepLink = `dmx://add?url=${encoded}`;
  if (downloadItem.filename) {
    deepLink += `&name=${encodeURIComponent(downloadItem.filename)}`;
  }
  deepLink += `&source=browser_ext`;

  // Open the deep link via tabs API
  browserAPI.tabs.create({ url: deepLink }, () => {
    if (browserAPI.runtime.lastError) {
      console.warn("[XDM] tabs.create error, sending native message fallback");
      try {
        browserAPI.runtime.sendNativeMessage("application.id", { openUrl: deepLink });
      } catch (err) {
        console.error("[XDM] Native message error:", err);
      }
    }
  });
});

// Listen for blob download messages from content script
browserAPI.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "blobDownload") {
    if (!enabled) return;
    const deepLink = `dmx://add?url=${encodeURIComponent(msg.url)}`
      + `&name=${encodeURIComponent(msg.filename || 'download')}`
      + `&source=browser_ext`;
    browserAPI.tabs.create({ url: deepLink });
  }
});
