# Migration Guide — v3.2.0 Browser Architecture Overhaul

This guide details the architectural, model, and service changes introduced in the Browser Production-Readiness Overhaul (v3.2.0).

---

## 1. Architectural Changes: Monolith Mixin State -> BrowserController

### Prior Architecture (Deprecated)
- `BrowserScreen` held state via `_BrowserScreenState` implementing 9 disparate mixins across 14 `part` files (`browser_screen_*.dart`).
- State mutations were performed via implicit cross-mixin dependencies and direct `setState(...)` calls inside deep sub-widgets.

### New Architecture (v3.2.0)
- **Controller Layer**: `BrowserController extends ChangeNotifier` is the single source of truth for tabs, URL bar state, ad-blocking, media sniffer, downloads, reader mode, find-in-page, and site settings.
- **Presentation Widgets**:
  - `BrowserToolbar` (`lib/features/browser/widgets/browser_toolbar.dart`)
  - `BrowserTabStrip` (`lib/features/browser/widgets/browser_tab_strip.dart`)
  - `BrowserTabSwitcher` (`lib/features/browser/widgets/browser_tab_switcher.dart`)
  - `BrowserHomeDashboard` (`lib/features/browser/widgets/browser_home_dashboard.dart`)
  - `BrowserTabView` (`lib/features/browser/widgets/browser_tab_view.dart`)
  - `BrowserFindPanel` (`lib/features/browser/widgets/browser_find_panel.dart`)
  - `BrowserMiscDialogs` (`lib/features/browser/widgets/browser_misc_dialogs.dart`)
- **Dependency Injection**: Browser services are registered in `GetIt` (`lib/core/di/injection.dart`) and injected into `BrowserController`.

---

## 2. Dependency Injection (`GetIt`) Registrations

| Service / Interface | Registration Type | Lifecycle / Disposal |
|---|---|---|
| `AdBlockFilterUpdater` | `registerLazySingleton` | App Lifetime |
| `AdBlockerService` | `registerLazySingleton` (`AdBlockerService.instance`) | App Lifetime |
| `AdBlockerDelegate` | Injected into Controller | Per controller |
| `SiteSettingsStore` | `registerLazySingleton` | SQLite backed |
| `ReaderModeService` | `registerLazySingleton` | App Lifetime |
| `FingerprintManager` | `registerLazySingleton` | App Lifetime |
| `ScriptInjector` | `registerLazySingleton` | App Lifetime |
| `RedirectGuard` | `registerLazySingleton` | App Lifetime |
| `BrowserController` | `registerFactory` | Disposed when screen pops |

---

## 3. Domain Model Updates

### `BrowserTab`
- **Favicon Safety**: `faviconBytes` setter clones and caps byte arrays to 10 KB (`Uint8List.fromList(bytes.sublist(0, 10240))`), preventing parent buffer memory retention.
- **URL & Loading Notifiers**: Added `loadingNotifier` (`ValueNotifier<bool>`) and `urlNotifier` (`ValueNotifier<String>`) for isolated sub-widget rebuilds without re-rendering the WebView hierarchy.
- **URL Normalization**: Canonical blank tab URL is strictly defined as `about:blank`.

### `Bookmark`
- **Color Palette**: Replaced ad-hoc color generators with `AppTheme.bookmarkPalette` (7 curated tokens).
- **Serialization**: Added `toJson()` and `fromJson()` standard aliases alongside `toMap()` / `fromMap()`.

### `ClosedTab`
- Serialized record model in `lib/features/browser/models/closed_tab.dart` supporting JSON persistence and undo-restore workflows.

---

## 4. Parser & Engine Upgrades

### `FilterLineParser`
- Extracted filter parsing pipeline into pure, static `FilterLineParser` (`lib/features/browser/services/filter_line_parser.dart`).
- Pre-compiled regular expressions for network blockers, exception rules, and cosmetic selectors.
- Added strict parenthesis depth checking (`areParensBalanced`) on `##+js(...)` scriptlets to prevent syntax corruption.

### `AdBlockFilterUpdater`
- Added per-source regression thresholds (`0.30` for EasyList/EasyPrivacy, `0.50` for fixed lists) ensuring filter updates never degrade ad-blocking capacity.
- `_PathTrie.searchSubstrings` optimized for rapid path pattern matching.
