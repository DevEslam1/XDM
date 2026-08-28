/// A/B experiment harness for dynamic download engine parameter exploration and tuning (Phase 6.2).
class EngineParameterExperiment {
  EngineParameterExperiment._();

  static const Map<String, List<dynamic>> defaultExperiments = {
    'chunk_size': [256 * 1024, 512 * 1024, 1024 * 1024],
    'thread_count': [4, 8, 12, 16],
    'write_buffer': [256 * 1024, 512 * 1024, 1024 * 1024],
    'poll_interval_ms': [300, 600, 1000],
  };

  /// Deterministically selects a parameter variant for a given [taskId] and [experimentName].
  static T selectParameter<T>({
    required String experimentName,
    required String taskId,
    List<T>? options,
  }) {
    final opts = options ?? (defaultExperiments[experimentName] as List<T>?);
    if (opts == null || opts.isEmpty) {
      throw ArgumentError(
          'No options available for experiment $experimentName');
    }
    final hash = (taskId + experimentName).hashCode.abs();
    return opts[hash % opts.length];
  }
}
