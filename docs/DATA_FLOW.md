# DMX Downloads Data-Flow Contract

This document specifies the unidirectional data flow, state guarantees, and persistence lifecycle for download management in DMX.

```mermaid
flowchart TD
    UserAction[User Action / UI Event] --> Command[Domain Command / TaskEnginePort]
    Command --> Orchestrator[Download Orchestrator]
    Orchestrator --> Engine[DownloadEngine / ITorrentService]
    
    Engine -. Progress & State .-> Journal[DownloadJournal / FastResume]
    Journal -. Checkpoints .-> StateStore[StateStore (Memory + .dmxpart JSON)]
    
    Orchestrator --> Repo[TaskRepository (Drift / SQLite WAL)]
    Repo --> Notifiers[DownloadListProvider / DownloadStatsProvider / DownloadFilterProvider]
    
    Notifiers --> Selectors[RepaintBoundaries & context.select Selectors]
    Selectors --> UI[DownloadCard & DownloadsScreen]
```

## Architectural Layers

1. **Presentation (UI Layer)**:
   - Consumer widgets subscribe via granular `context.select` queries to avoid rebuilds.
   - Heavy repaint widgets (`DownloadCard`, `ChannelProgressPainter`) are wrapped in `RepaintBoundary` nodes.

2. **State Management**:
   - `DownloadListProvider`: Task list mutations, multi-selection, bulk operations.
   - `DownloadFilterProvider`: Category/status filtering, search queries, sort options.
   - `DownloadStatsProvider`: Aggregate bandwidth speeds, active download count, global ETA.

3. **Domain & Orchestration**:
   - `DownloadOrchestrator`: Dispatches commands, manages retries, escalation, and lifecycle transitions.
   - `CycleState`: Canonical fine-grained engine execution phase (`starting`, `downloading`, `merging`, `verifying`, `paused`, `completed`, `failed`).

4. **Persistence & Durability**:
   - `TaskRepository`: Structured SQLite persistence using Drift in WAL mode.
   - `DownloadJournal`: Append-only binary journal for zero-loss recovery of fast chunk offsets.
   - `StateStore`: Periodic serialized snapshot with atomic file swapping (`.tmp` → rename).
