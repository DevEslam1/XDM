# DMX Clean Architecture & Layer Rules

## 1. Architectural Layers & Boundaries

```
[Presentation Layer] (Widgets, Screens, Dialogs)
         │
         ▼
[Provider / State Layer] (ChangeNotifiers, Controllers)
         │
         ▼
[Domain Layer] (Entities, Value Objects, State Machine, Ports)
         │
         ▼
[Data / Infrastructure Layer] (Drift DB, libtorrent FFI, Network, Platform Channels)
```

### Layer Constraints (Non-Negotiable)
1. **Domain Layer**: Must be pure Dart. Zero imports from `flutter/material.dart`, `flutter_inappwebview`, or other UI/platform packages.
2. **Provider Layer**: Orchestrates domain business logic and exposes reactive state via ChangeNotifier. Must never leak direct database handles to presentation widgets.
3. **Presentation Layer**: Exclusively handles layout rendering and user interaction. All actions dispatch through Providers.
4. **Data Layer**: Implements ports defined in the domain layer and handles data serialization/deserialization.

## 2. Platform Subsystems
- **AppWidgets (Android & iOS)**:
  - Single source of truth for aggregation and 20-task capping resides in `WidgetDashboard.fromTasks` in `lib/core/services/widget_data_bridge.dart`.
  - Android Kotlin `DMXRemoteViewsFactory` operates strictly as a stateless view builder, delegating pure formatting to `WidgetFormatters.kt`.
- **Browser Feature**:
  - Embedded WebView with granular scriptlet ad-blocking, canvas randomization, and User-Agent spoofing in `FingerprintManager`.
  - Isolated background tab lifecycle managed by `InactivityWatchdog`.
