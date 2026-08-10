// Sends page context (referrer, title) so XDM can set proper headers if needed
browser.runtime.onMessage.addListener((msg) => {
  if (msg.type === "getPageContext") {
    return Promise.resolve({
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
    browser.runtime.sendMessage({
      type: "blobDownload",
      url: a.href,
      filename: a.getAttribute("download") || "download",
    });
  }
}, true);
