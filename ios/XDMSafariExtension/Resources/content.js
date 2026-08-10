const browserAPI = typeof browser !== "undefined" ? browser : chrome;

// Listen for page context requests
browserAPI.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "getPageContext") {
    sendResponse({
      pageUrl:   window.location.href,
      pageTitle: document.title,
      referrer:  document.referrer,
    });
  }
});

// Detect blob download triggers (JS-created downloads)
document.addEventListener("click", (e) => {
  const a = e.target.closest ? e.target.closest("a[download]") : null;
  if (a && a.href && a.href.startsWith("blob:")) {
    browserAPI.runtime.sendMessage({
      type: "blobDownload",
      url: a.href,
      filename: a.getAttribute("download") || "download",
    });
  }
}, true);
