# DMX State Management Architecture

This document describes the provider decomposition, synchronization models, and lock-free read access patterns in DMX.

```
┌────────────────────────────────────────────────────────┐
│               Provider Responsibilities                │
└────────────────────────────────────────────────────────┘
  ├── DownloadListProvider
  │   └── Task collection, CRUD operations, multi-selection
  ├── DownloadFilterProvider
  │   └── Category filter chips, search queries, sort orders
  └── DownloadStatsProvider
      └── Real-time aggregated speed counters, active counts, ETA
```

## 1. Concurrency & Deadlock Prevention
- Primitive mutations on `_tasks` and index lookups are protected by a localized re-entrant `_tasksLock`.
- Long-running async I/O (database writes, HTTP handshakes, filesystem allocations) is executed OUTSIDE lock acquisitions.
- Notifications are debounced and silenced when the device is locked/screen-off via `PowerMonitor.screenOff`.

## 2. Fine-Grained UI Consumption
- Widgets consume state via granular `context.select` queries to prevent full-screen tree invalidation on single byte updates.
- Isolated progress bars use `ValueListenable<double>` bindings and `RepaintBoundary` wrappers.
