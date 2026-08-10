const browserAPI = typeof browser !== "undefined" ? browser : chrome;

const toggleEnabled = document.getElementById("toggleEnabled");
const statusText    = document.getElementById("statusText");

browserAPI.storage.local.get("xdmEnabled", (r) => {
  const isEnabled = (r && typeof r.xdmEnabled !== "undefined") ? r.xdmEnabled : true;
  toggleEnabled.checked = isEnabled;
  updateStatus(isEnabled);
});

toggleEnabled.addEventListener("change", () => {
  const isEnabled = toggleEnabled.checked;
  browserAPI.storage.local.set({ xdmEnabled: isEnabled });
  updateStatus(isEnabled);
});

function updateStatus(isEnabled) {
  statusText.textContent = isEnabled ? "XDM: Intercepting active" : "XDM: Disabled";
  statusText.style.color = isEnabled ? "#00E5FF" : "#FF5252";
  statusText.style.borderColor = isEnabled ? "rgba(0, 229, 255, 0.2)" : "rgba(255, 82, 82, 0.2)";
  statusText.style.background = isEnabled ? "rgba(0, 229, 255, 0.08)" : "rgba(255, 82, 82, 0.08)";
}
