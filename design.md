# XDM (dmx) — Design System & Architecture ("Signal Deck")

XDM uses a single source of truth for every visual decision: `lib/core/app_theme.dart` (tokens, motion, themes) and `lib/shared/design/dmx_design.dart` (the reusable component library). This document is the living spec for both.

---

## 1. Overview & Vision

XDM is a next-generation download manager, BitTorrent client, and web browser built with Flutter. The design system — codenamed **Signal Deck** — delivers a high-contrast, immersive, futuristic cockpit aesthetic: glassmorphism panels, a reactive geometric grid background, precise micro-animations, tactile haptics, and four theme modes (**Light**, **Dark**, **AMOLED**, **Follow System**) that swap instantly without restart.

Two rendering "families" are supported everywhere:
- **Signal Deck (glass)** — translucent surfaces, backdrop blur, neon accent borders, and glow.
- **Classic UI** — flat, opaque, high-contrast cards (also forced ON automatically by Battery Saver mode).

---

## 2. Color Palette & Tokens

All tokens are declared as `static const` in `AppTheme`. Every color is mode-aware (dark / light / amoled).

### 2.1 Surfaces

| Token | Dark | AMOLED | Light |
|---|---|---|---|
| Background | `#0F1117` | `#000000` | `#F3F5F9` |
| Sunken (`bgSunken`) | `#0B0D12` | `#000000` | `#E9EDF4` |
| Surface (L1) | `#161A22` | `#08090D` | `#FFFFFF` |
| Surface Raised (L2 / card) | `#1B202B` | `#10121A` | `#FBFCFE` |
| Card Background | `#1B202B` | `#0D0F16` | `#FBFCFE` |
| Overlay Scrim | `0xB3070910` | `0xCC000000` | `0x66101828` |

### 2.2 Borders

| Token | Dark | Light |
|---|---|---|
| Border (default) | `#2A3040` | `#D4DAE5` |
| Border Strong | `#3A4154` | `#B9C1D0` |
| Border Subtle | `#1E2330` | `#E4E8F0` |
| AMOLED border / subtle | `#1E2230` / `#141722` | — |

### 2.3 Glass (legacy)

| Token | Dark | Light |
|---|---|---|
| Glass BG | `0x0FFFFFFF` | `0x0A000000` |
| Glass Border | `0x16FFFFFF` | `0x14000000` |
| Glass Surface | `0x0AFFFFFF` | — |

### 2.4 Accent ("Neon") Palette

| Accent | Dark | Light | Usage |
|---|---|---|---|
| Neon Blue | `#3B82F6` | `#1D63D8` | Primary action, highlights, downloads tab |
| Neon Violet | `#8B5CF6` | `#6D3AC4` | Secondary, gradients, downloading status |
| Neon Green | `#10B981` | `#047857` | Success / completed |
| Neon Red | `#EF4444` | `#C21F1F` | Danger, paused, failed |
| Neon Amber | `#F59E0B` | `#B45309` | Warnings, settings accent, merging |
| Neon Yellow | `#FACC15` | `#A16207` | Emphasis |
| Neon Cyan | `#22D3EE` | `#0E7490` | Sniffer / scanner / network settings |
| Neon Orange | `#F97316` | `#EA580C` | Power settings |

Settings pages each carry their own accent for at-a-glance wayfinding:
Amber → Appearance · Blue → Downloads · Cyan → Network · Violet → Notifications · Green → Torrent · Orange → Power · Red → Advanced.

### 2.5 Typography Colors

| Role | Dark | Light |
|---|---|---|
| Primary Text | `#F2F4F8` | `#101828` |
| Secondary Text | `#9AA3B5` | `#475467` |
| Muted Text | `#5F6B82` | `#8A94A6` |

### 2.6 Accessibility / Semantic Colors

**Focus & selection**
- Focus ring: `#60A5FA` (dark) / `#1D4ED8` (light); focus fill `0x33008FE0`.

**Error / success pairings**
- Error on light: `#991B1B` on `#FEE2E2`; error on dark: `#FCA5A5` on `0x33EF4444`.
- Success on light: `#047857` on `#D1FAE5`; success on dark: `#34D399` on `0x3310B981`.

**Disabled**
- Dark: surface `#1F2937`, text `#6B7280`, icon `#4B5563`.
- Light: surface `#E5E7EB`, text `#9CA3AF`, icon `#D1D5DB`.

**High Contrast Mode** (auto when system accessibility requests it)
- Dark: bg `#000000`, surface `#121212`, text/border `#FFFFFF`.
- Light: bg/surface `#FFFFFF`, text/border `#000000`.

**Status→color mapping** (`DmxStatusColors`)
- Queued / Downloading → Neon Violet · Paused / Failed → Neon Red · Completed → Neon Green · Merging → Neon Amber.

---

## 3. Typography

### 3.1 Fonts
- **Space Grotesk** — Display / headings / stats / badges / buttons (the "signal" voice).
- **Inter** — Body text, labels, input fields (the "instrument" voice).

### 3.2 Type Scale (shared tokens, auto-switched per mode)
| Role | Size | Weight | Track | Notes |
|---|---|---|---|---|
| Display Large | 34 | 700 | −0.6 | Hero stats |
| Display Medium | 28 | 700 | −0.4 | Section heroes |
| Display Small | 22 | 700 | −0.2 | Panel titles |
| Headline Large / Medium / Small | 20 / 17 / 15 | 700 / 600 / 600 | 0 | Screen / section / sub headers |
| Title Large / Medium / Small | 14 / 13 / 12 | 600 | 0 | Card titles, list heading |
| Body Large / Medium / Small | 14 / 12.5 / 11 | 400 (h 1.45) | 0 | Body copy |
| Label Large / Medium / Small | 11 | 700/600/600 | 1.2 / 0.8 / 0.6 | UPPERCASE micro-labels |

**Helpers**
- `AppTheme.dataStyle()` — tabular-figure data (speed, size) with **11sp WCAG AA minimum**.
- `AppTheme.microLabel()` — uppercase letter-spaced eyebrow labels.
- User text scaling (`XdmTextScaler`) clamped to **0.8×–2.5×** with a dedicated settings control.

---

## 4. Motion & Micro-Animations

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motionFast` | 140ms | `easeOutCubic` | Button taps, hovers, icon toggles |
| `motionBase` | 240ms | `easeOutCubic` | Dialogs, tab switching, expansion panels, nav-bar slides |
| `motionSlow` | 420ms | `easeOutCubic` | Screen transitions, large drawer/sheet reveals |
| `motionReveal` | 600ms | — | App startup & hero (staggered fade + slide via `_stagger`) |
| `motionSpring` | — | `easeOutQuart` | Icon pulses, FAB emphasis |

Principles:
- Every interactive reward uses **haptics** (light/medium/heavy) gated by the vibration setting.
- Cross-tab switching uses a fade via `_FadeIndexedStack`.
- `PausableLoopAnimation` pauses looping decorations when the app is backgrounded.
- `Reduce Visual Effects` and `Battery Saver` disable animated grids/blur for performance.
- Respects `MediaQuery.disableAnimations` and the `XdmMotion` accessibility guard.

---

## 5. Key UI Components (Shared & Component Library)

### 5.1 `shared/widgets/`
- **`MainNavigationContainer`** — adaptive shell: phone floating bottom bar, tablet floating pill bar, desktop/tablet **Navigation Rail**. `PopScope` back handling + cross-fade `_FadeIndexedStack`. Rail/nav badges show live downloading counts.
- **`DmxAppIcon`** — the glowing app-mark used in the rail and splash.
- **`GeometricGridBackground`** — dynamic grid mesh behind screens with configurable opacity.
- **`DmxBackdropFilter`** — reusable frosted-glass (backdrop blur) wrapper.
- **`GlassCard`**, **`NeonGlowButton`**, **`SectionHeader`**, **`EmptyStateView`**, **`SkeletonLoader`** (loading placeholders), **`FadeInSlide`**, **`ThemedSnackbar`**.

### 5.2 `shared/design/dmx_design.dart` — the component library
- **`DmxCardShell`** — the universal card: accent rail, glow borders, backdrop blur, tap/long-press, classic-or-glass.
- **`DmxSectionGroup`** + **`DmxDivider` + `DmxSectionHeader`** — grouped list sections for settings and dashboards.
- **`DmxDialog`** / **`DmxConfirmDialog`** — unified modal system (title rail, icon, RTL-aware).
- **`DmxButton`** — filled / outline / destructive / ghost variants with glow and loading states.
- **`DmxTextField`** — branded input with prefix/suffix affordances.
- **`DmxEmptyState`** — branded empty/onboarding placeholder.
- **`DmxBanner`** — inline notice banners (iOS background warning, incognito, etc.).
- **`showMediaChoiceDialog`** — single-video vs playlist picker.

---

## 6. Screens & Layout Architecture

### 6.1 Root Shell (`MainNavigationContainer`)
Three primary destinations; `_FadeIndexedStack` cross-fades between them:
1. **Transmissions (Home)** — dashboard.
2. **Browser** — full WebView suite.
3. **Config (Settings)** — paginated sections.

Back behavior: on the Home/Settings tabs, system back returns Home; the Browser tab owns its own history back-navigation (`canPop: false` PopScope).

### 6.2 Transmissions / Home (`HomeScreen`)
- Staggered hero reveal, animated **Active/Completed** segmented control with live counts.
- **Collapsible Storage Analytics** — `fl_chart` donut of category sizes (Video/Audio/Document/Archive/APK/Other); tapping a slice sets a category filter.
- **Download Stats Panel** (active tab), **Filter Chips** (status + type), progressive search, sort menu, and one-tap clear-history.
- **Download cards** — gradient channel progress with per-chunk painters, telemetry strip (speed/ETA/threads/segments), media/thumbnail, torrent cards (seeding, peers, per-file list), playlist-group cards.
- **Batch mode** — multi-select pause / resume / delete / re-categorize.

### 6.3 Details (`DetailsScreen`)
- Live speed + chunk-progress graph, task integrity, notes, mirrors, torrent dashboard (peers, trackers, health indicator, speed graph), open file, delete (with file removal), priority and queue control.

### 6.4 Browser (`BrowserScreen`)
- Smart URL bar (suggestions, search engine, scheme indicator, ad-block counter, sniffer radar toggle, incognito chip).
- Tab strip, preview switcher, incognito banner, recently-closed restore, favicons.
- Overflow menu: force-dark, desktop mode, reader mode, find-in-page, zoom, translate, screenshot, print/PDF, save offline, site settings, custom JS/CSS, shortcuts, clear browsing data.
- Sheets: media sniffer/detected media, quality picker, download interception, bookmark manager, history, script manager.

### 6.5 Onboarding & Security
- 5-page onboarding with ambient particle animation; Android requires a download folder before first use (`PermissionRequestScreen`).
- **AppLockScreen** — PIN setup/verify with failed-attempt lockout countdown.

---

## 7. Accessibility & UX Standards
- **Focus system**: high-visibility rings (`#60A5FA` / `#1D4ED8`), focus-fill surfaces, and traversal helpers for keyboard/screen readers.
- **Touch targets** ≥ 44×44 logical px; buttons enforce min-height 48.
- **Semantics**: `Semantics` labels on nav items, buttons, progress; `XdmAnnouncer` for live-region status updates.
- **High contrast**: automated borders/background swaps via `HighContrastDetector`.
- **Min font size** 11sp (WCAG AA); user text scaling 0.8–2.5×.
- **RTL**: full Arabic layout mirrored via `Directionality` and directional widgets; L10n loads `en/ar/de/es/fr`.

---

## 8. Motion & Data Rendering Notes
- Speed/ETA strings use `AppTheme.dataStyle()` for tabular alignment (no jitter while counting).
- Number/date formatting is locale-aware via `intl` (`NumberFormat`, `DateFormat`).
- Glow is a token-controlled effect (`AppTheme.glow`, `glowGradient`) — toggled by `enableGlow` and disabled in Classic UI.