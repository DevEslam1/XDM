# Android & iOS Widget Smoke Test Checklist [Manual Verification Gate N-2]

## 1. Android AppWidget Smoke Tests
| Test Case | Steps | Expected Result | Pass/Fail |
| :--- | :--- | :--- | :---: |
| **TC-W1: Empty State** | 1. Add 4x4 Dashboard widget on clean install.<br>2. Switch between Downloading and Completed tabs. | Renders *"All clear — nothing downloading"* and *"No completed downloads yet"* with no red screen / crash. | [ ] |
| **TC-W2: Live Speed & ETA** | 1. Start a high-speed download.<br>2. Check 4x4 and 4x2 widgets. | Live speed badge displays green text (e.g., `4.2 MB/s`), row progress bar updates, ETA shows `~Xm left`. | [ ] |
| **TC-W3: Pause / Resume Action** | 1. Tap action button (pause icon) on widget row.<br>2. Verify download transitions to paused. | State updates within 500ms; dot color changes to amber (`COLOR_NEON_AMBER`). | [ ] |
| **TC-W4: Storage Warning** | 1. Simulate < 500MB free disk space.<br>2. Inspect widget dashboard. | Orange/Red warning banner appears (`⚠ Low storage: ... free`). | [ ] |
| **TC-W5: Deep Link Dispatch** | 1. Tap completed download item.<br>2. Tap `+ NEW` button. | Opens file opener or app detail view; `dmx://add` opens the Add Download modal. | [ ] |

## 2. iOS Live Activity / WidgetKit
| Test Case | Steps | Expected Result | Pass/Fail |
| :--- | :--- | :--- | :---: |
| **TC-L1: Live Activity Lockscreen** | 1. Lock phone during active transfer. | Live Activity banner reflects current download progress and speed. | [ ] |
| **TC-L2: Dynamic Island** | 1. Minimize app on iPhone 14 Pro+. | Compact leading/trailing views display speed and progress circle. | [ ] |
