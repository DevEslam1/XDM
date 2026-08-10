const toggleEnabled = document.getElementById("toggleEnabled");
const toggleAll     = document.getElementById("toggleAll");
const statusText    = document.getElementById("statusText");

browser.storage.local.get(["xdmEnabled", "interceptAll"]).then(r => {
  toggleEnabled.checked = r.xdmEnabled    ?? true;
  toggleAll.checked     = r.interceptAll  ?? true;
  updateStatus(toggleEnabled.checked);
});

toggleEnabled.addEventListener("change", () => {
  const isEnabled = toggleEnabled.checked;
  browser.storage.local.set({ xdmEnabled: isEnabled });
  updateStatus(isEnabled);
});

toggleAll.addEventListener("change", () => {
  browser.storage.local.set({ interceptAll: toggleAll.checked });
});

function updateStatus(isEnabled) {
  statusText.textContent = isEnabled ? "XDM: Intercepting active" : "XDM: Disabled";
  statusText.style.color = isEnabled ? "#00E5FF" : "#FF5252";
  statusText.style.borderColor = isEnabled ? "rgba(0, 229, 255, 0.2)" : "rgba(255, 82, 82, 0.2)";
  statusText.style.background = isEnabled ? "rgba(0, 229, 255, 0.08)" : "rgba(255, 82, 82, 0.08)";
}
