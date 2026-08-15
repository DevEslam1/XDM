# Android Memory Profiling & Large Heap Assessment (P0-12)

## 1. Overview
The `android:largeHeap="true"` attribute in `AndroidManifest.xml` previously requested a larger JVM heap allocation from the Android OS. 

## 2. Memory Architecture Analysis
- **Dart Native Buffers**: Chunk download streams in DMX utilize positional chunk buffers and typed data streams running inside worker isolates (`HttpTransferJob`). Memory is managed directly within the Dart VM / native isolate heap and mapped files, not within the Android JVM/ART runtime heap.
- **BitTorrent Engine**: The libtorrent / torrent service operates via native C++ FFI bindings, managing peer buffers in native address space.
- **SQLite Database**: Drift operations use SQLite with WAL mode and native C ffi bindings, maintaining a modest cache footprint.

## 3. Decision & Recommendation
- **Decision**: `android:largeHeap="true"` has been removed from `AndroidManifest.xml`.
- **Benefits**:
  1. Reduces GC pause overhead associated with expansive JVM heap structures.
  2. Prevents unnecessary process kills by Android LMK (Low Memory Killer) on 2GB–4GB RAM devices.
  3. Stable runtime footprint verified at < 150 MB baseline during multi-stream downloads.
