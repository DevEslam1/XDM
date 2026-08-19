// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $DownloadTasksTable extends DownloadTasks
    with TableInfo<$DownloadTasksTable, DbDownloadTask> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadTasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fileNameMeta =
      const VerificationMeta('fileName');
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
      'file_name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
      'url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fileSizeMeta =
      const VerificationMeta('fileSize');
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
      'file_size', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _downloadedBytesMeta =
      const VerificationMeta('downloadedBytes');
  @override
  late final GeneratedColumn<int> downloadedBytes = GeneratedColumn<int>(
      'downloaded_bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _speedMeta = const VerificationMeta('speed');
  @override
  late final GeneratedColumn<double> speed = GeneratedColumn<double>(
      'speed', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _etaMeta = const VerificationMeta('eta');
  @override
  late final GeneratedColumn<int> eta = GeneratedColumn<int>(
      'eta', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _savePathMeta =
      const VerificationMeta('savePath');
  @override
  late final GeneratedColumn<String> savePath = GeneratedColumn<String>(
      'save_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localFilePathMeta =
      const VerificationMeta('localFilePath');
  @override
  late final GeneratedColumn<String> localFilePath = GeneratedColumn<String>(
      'local_file_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _tempFilePathMeta =
      const VerificationMeta('tempFilePath');
  @override
  late final GeneratedColumn<String> tempFilePath = GeneratedColumn<String>(
      'temp_file_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _errorMessageMeta =
      const VerificationMeta('errorMessage');
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
      'error_message', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _threadCountMeta =
      const VerificationMeta('threadCount');
  @override
  late final GeneratedColumn<int> threadCount = GeneratedColumn<int>(
      'thread_count', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  late final GeneratedColumnWithTypeConverter<List<double>?, String> chunks =
      GeneratedColumn<String>('chunks', aliasedName, true,
              type: DriftSqlType.string, requiredDuringInsert: false)
          .withConverter<List<double>?>($DownloadTasksTable.$converterchunks);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _completedAtMeta =
      const VerificationMeta('completedAt');
  @override
  late final GeneratedColumn<int> completedAt = GeneratedColumn<int>(
      'completed_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _scheduledAtMeta =
      const VerificationMeta('scheduledAt');
  @override
  late final GeneratedColumn<int> scheduledAt = GeneratedColumn<int>(
      'scheduled_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _supportsResumeMeta =
      const VerificationMeta('supportsResume');
  @override
  late final GeneratedColumn<bool> supportsResume = GeneratedColumn<bool>(
      'supports_resume', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("supports_resume" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _speedLimitKbpsMeta =
      const VerificationMeta('speedLimitKbps');
  @override
  late final GeneratedColumn<int> speedLimitKbps = GeneratedColumn<int>(
      'speed_limit_kbps', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _seedingEnabledMeta =
      const VerificationMeta('seedingEnabled');
  @override
  late final GeneratedColumn<bool> seedingEnabled = GeneratedColumn<bool>(
      'seeding_enabled', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("seeding_enabled" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _seedingLimitedMeta =
      const VerificationMeta('seedingLimited');
  @override
  late final GeneratedColumn<bool> seedingLimited = GeneratedColumn<bool>(
      'seeding_limited', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("seeding_limited" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _seedingLimitKbpsMeta =
      const VerificationMeta('seedingLimitKbps');
  @override
  late final GeneratedColumn<int> seedingLimitKbps = GeneratedColumn<int>(
      'seeding_limit_kbps', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(500));
  @override
  late final GeneratedColumnWithTypeConverter<List<Map<String, dynamic>>?,
      String> torrentFiles = GeneratedColumn<String>(
          'torrent_files', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false)
      .withConverter<List<Map<String, dynamic>>?>(
          $DownloadTasksTable.$convertertorrentFiles);
  static const VerificationMeta _downloadPageUrlMeta =
      const VerificationMeta('downloadPageUrl');
  @override
  late final GeneratedColumn<String> downloadPageUrl = GeneratedColumn<String>(
      'download_page_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _mergedAudioUrlMeta =
      const VerificationMeta('mergedAudioUrl');
  @override
  late final GeneratedColumn<String> mergedAudioUrl = GeneratedColumn<String>(
      'merged_audio_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _audioSizeMeta =
      const VerificationMeta('audioSize');
  @override
  late final GeneratedColumn<int> audioSize = GeneratedColumn<int>(
      'audio_size', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _audioDownloadedBytesMeta =
      const VerificationMeta('audioDownloadedBytes');
  @override
  late final GeneratedColumn<int> audioDownloadedBytes = GeneratedColumn<int>(
      'audio_downloaded_bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _videoStreamSizeMeta =
      const VerificationMeta('videoStreamSize');
  @override
  late final GeneratedColumn<int> videoStreamSize = GeneratedColumn<int>(
      'video_stream_size', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _audioProgressMeta =
      const VerificationMeta('audioProgress');
  @override
  late final GeneratedColumn<double> audioProgress = GeneratedColumn<double>(
      'audio_progress', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _pausedByUserMeta =
      const VerificationMeta('pausedByUser');
  @override
  late final GeneratedColumn<bool> pausedByUser = GeneratedColumn<bool>(
      'paused_by_user', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("paused_by_user" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _youtubeQualityPresetMeta =
      const VerificationMeta('youtubeQualityPreset');
  @override
  late final GeneratedColumn<String> youtubeQualityPreset =
      GeneratedColumn<String>('youtube_quality_preset', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
      'notes', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _playlistIdMeta =
      const VerificationMeta('playlistId');
  @override
  late final GeneratedColumn<String> playlistId = GeneratedColumn<String>(
      'playlist_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _playlistTitleMeta =
      const VerificationMeta('playlistTitle');
  @override
  late final GeneratedColumn<String> playlistTitle = GeneratedColumn<String>(
      'playlist_title', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _thumbnailUrlMeta =
      const VerificationMeta('thumbnailUrl');
  @override
  late final GeneratedColumn<String> thumbnailUrl = GeneratedColumn<String>(
      'thumbnail_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _isAppUpdateMeta =
      const VerificationMeta('isAppUpdate');
  @override
  late final GeneratedColumn<bool> isAppUpdate = GeneratedColumn<bool>(
      'is_app_update', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("is_app_update" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _uploadedBytesMeta =
      const VerificationMeta('uploadedBytes');
  @override
  late final GeneratedColumn<int> uploadedBytes = GeneratedColumn<int>(
      'uploaded_bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _priorityMeta =
      const VerificationMeta('priority');
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
      'priority', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _queueOrderMeta =
      const VerificationMeta('queueOrder');
  @override
  late final GeneratedColumn<int> queueOrder = GeneratedColumn<int>(
      'queue_order', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _expectedSha256Meta =
      const VerificationMeta('expectedSha256');
  @override
  late final GeneratedColumn<String> expectedSha256 = GeneratedColumn<String>(
      'expected_sha256', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  late final GeneratedColumnWithTypeConverter<List<String>?, String>
      mirrorUrls = GeneratedColumn<String>('mirror_urls', aliasedName, true,
              type: DriftSqlType.string, requiredDuringInsert: false)
          .withConverter<List<String>?>(
              $DownloadTasksTable.$convertermirrorUrls);
  static const VerificationMeta _pauseReasonMeta =
      const VerificationMeta('pauseReason');
  @override
  late final GeneratedColumn<String> pauseReason = GeneratedColumn<String>(
      'pause_reason', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _totalPiecesMeta =
      const VerificationMeta('totalPieces');
  @override
  late final GeneratedColumn<int> totalPieces = GeneratedColumn<int>(
      'total_pieces', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _completedPiecesMeta =
      const VerificationMeta('completedPieces');
  @override
  late final GeneratedColumn<int> completedPieces = GeneratedColumn<int>(
      'completed_pieces', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _ytCounterpartDownloadedBytesMeta =
      const VerificationMeta('ytCounterpartDownloadedBytes');
  @override
  late final GeneratedColumn<int> ytCounterpartDownloadedBytes =
      GeneratedColumn<int>('yt_counterpart_downloaded_bytes', aliasedName, true,
          type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _cycleStateMeta =
      const VerificationMeta('cycleState');
  @override
  late final GeneratedColumn<String> cycleState = GeneratedColumn<String>(
      'cycle_state', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  late final GeneratedColumnWithTypeConverter<List<double>?, String>
      audioChunks = GeneratedColumn<String>('audio_chunks', aliasedName, true,
              type: DriftSqlType.string, requiredDuringInsert: false)
          .withConverter<List<double>?>(
              $DownloadTasksTable.$converteraudioChunks);
  static const VerificationMeta _httpPartsMeta =
      const VerificationMeta('httpParts');
  @override
  late final GeneratedColumn<String> httpParts = GeneratedColumn<String>(
      'http_parts', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _torrentPieceProgressMeta =
      const VerificationMeta('torrentPieceProgress');
  @override
  late final GeneratedColumn<double> torrentPieceProgress =
      GeneratedColumn<double>('torrent_piece_progress', aliasedName, true,
          type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _audioChunksCompletedMeta =
      const VerificationMeta('audioChunksCompleted');
  @override
  late final GeneratedColumn<int> audioChunksCompleted = GeneratedColumn<int>(
      'audio_chunks_completed', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _audioChunksTotalMeta =
      const VerificationMeta('audioChunksTotal');
  @override
  late final GeneratedColumn<int> audioChunksTotal = GeneratedColumn<int>(
      'audio_chunks_total', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _httpPartsCompletedMeta =
      const VerificationMeta('httpPartsCompleted');
  @override
  late final GeneratedColumn<int> httpPartsCompleted = GeneratedColumn<int>(
      'http_parts_completed', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _httpPartsTotalMeta =
      const VerificationMeta('httpPartsTotal');
  @override
  late final GeneratedColumn<int> httpPartsTotal = GeneratedColumn<int>(
      'http_parts_total', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _previousCycleStateMeta =
      const VerificationMeta('previousCycleState');
  @override
  late final GeneratedColumn<String> previousCycleState =
      GeneratedColumn<String>('previous_cycle_state', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _infoHashMeta =
      const VerificationMeta('infoHash');
  @override
  late final GeneratedColumn<String> infoHash = GeneratedColumn<String>(
      'info_hash', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        fileName,
        url,
        fileSize,
        downloadedBytes,
        speed,
        eta,
        category,
        status,
        savePath,
        localFilePath,
        tempFilePath,
        errorMessage,
        threadCount,
        chunks,
        createdAt,
        updatedAt,
        completedAt,
        scheduledAt,
        supportsResume,
        speedLimitKbps,
        seedingEnabled,
        seedingLimited,
        seedingLimitKbps,
        torrentFiles,
        downloadPageUrl,
        mergedAudioUrl,
        audioSize,
        audioDownloadedBytes,
        videoStreamSize,
        audioProgress,
        pausedByUser,
        youtubeQualityPreset,
        notes,
        playlistId,
        playlistTitle,
        thumbnailUrl,
        isAppUpdate,
        uploadedBytes,
        priority,
        queueOrder,
        expectedSha256,
        mirrorUrls,
        pauseReason,
        totalPieces,
        completedPieces,
        ytCounterpartDownloadedBytes,
        cycleState,
        audioChunks,
        httpParts,
        torrentPieceProgress,
        audioChunksCompleted,
        audioChunksTotal,
        httpPartsCompleted,
        httpPartsTotal,
        previousCycleState,
        infoHash
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_tasks';
  @override
  VerificationContext validateIntegrity(Insertable<DbDownloadTask> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(_fileNameMeta,
          fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta));
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
          _urlMeta, url.isAcceptableOrUnknown(data['url']!, _urlMeta));
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('file_size')) {
      context.handle(_fileSizeMeta,
          fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta));
    }
    if (data.containsKey('downloaded_bytes')) {
      context.handle(
          _downloadedBytesMeta,
          downloadedBytes.isAcceptableOrUnknown(
              data['downloaded_bytes']!, _downloadedBytesMeta));
    }
    if (data.containsKey('speed')) {
      context.handle(
          _speedMeta, speed.isAcceptableOrUnknown(data['speed']!, _speedMeta));
    }
    if (data.containsKey('eta')) {
      context.handle(
          _etaMeta, eta.isAcceptableOrUnknown(data['eta']!, _etaMeta));
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('save_path')) {
      context.handle(_savePathMeta,
          savePath.isAcceptableOrUnknown(data['save_path']!, _savePathMeta));
    } else if (isInserting) {
      context.missing(_savePathMeta);
    }
    if (data.containsKey('local_file_path')) {
      context.handle(
          _localFilePathMeta,
          localFilePath.isAcceptableOrUnknown(
              data['local_file_path']!, _localFilePathMeta));
    } else if (isInserting) {
      context.missing(_localFilePathMeta);
    }
    if (data.containsKey('temp_file_path')) {
      context.handle(
          _tempFilePathMeta,
          tempFilePath.isAcceptableOrUnknown(
              data['temp_file_path']!, _tempFilePathMeta));
    } else if (isInserting) {
      context.missing(_tempFilePathMeta);
    }
    if (data.containsKey('error_message')) {
      context.handle(
          _errorMessageMeta,
          errorMessage.isAcceptableOrUnknown(
              data['error_message']!, _errorMessageMeta));
    }
    if (data.containsKey('thread_count')) {
      context.handle(
          _threadCountMeta,
          threadCount.isAcceptableOrUnknown(
              data['thread_count']!, _threadCountMeta));
    } else if (isInserting) {
      context.missing(_threadCountMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('completed_at')) {
      context.handle(
          _completedAtMeta,
          completedAt.isAcceptableOrUnknown(
              data['completed_at']!, _completedAtMeta));
    }
    if (data.containsKey('scheduled_at')) {
      context.handle(
          _scheduledAtMeta,
          scheduledAt.isAcceptableOrUnknown(
              data['scheduled_at']!, _scheduledAtMeta));
    }
    if (data.containsKey('supports_resume')) {
      context.handle(
          _supportsResumeMeta,
          supportsResume.isAcceptableOrUnknown(
              data['supports_resume']!, _supportsResumeMeta));
    }
    if (data.containsKey('speed_limit_kbps')) {
      context.handle(
          _speedLimitKbpsMeta,
          speedLimitKbps.isAcceptableOrUnknown(
              data['speed_limit_kbps']!, _speedLimitKbpsMeta));
    }
    if (data.containsKey('seeding_enabled')) {
      context.handle(
          _seedingEnabledMeta,
          seedingEnabled.isAcceptableOrUnknown(
              data['seeding_enabled']!, _seedingEnabledMeta));
    }
    if (data.containsKey('seeding_limited')) {
      context.handle(
          _seedingLimitedMeta,
          seedingLimited.isAcceptableOrUnknown(
              data['seeding_limited']!, _seedingLimitedMeta));
    }
    if (data.containsKey('seeding_limit_kbps')) {
      context.handle(
          _seedingLimitKbpsMeta,
          seedingLimitKbps.isAcceptableOrUnknown(
              data['seeding_limit_kbps']!, _seedingLimitKbpsMeta));
    }
    if (data.containsKey('download_page_url')) {
      context.handle(
          _downloadPageUrlMeta,
          downloadPageUrl.isAcceptableOrUnknown(
              data['download_page_url']!, _downloadPageUrlMeta));
    }
    if (data.containsKey('merged_audio_url')) {
      context.handle(
          _mergedAudioUrlMeta,
          mergedAudioUrl.isAcceptableOrUnknown(
              data['merged_audio_url']!, _mergedAudioUrlMeta));
    }
    if (data.containsKey('audio_size')) {
      context.handle(_audioSizeMeta,
          audioSize.isAcceptableOrUnknown(data['audio_size']!, _audioSizeMeta));
    }
    if (data.containsKey('audio_downloaded_bytes')) {
      context.handle(
          _audioDownloadedBytesMeta,
          audioDownloadedBytes.isAcceptableOrUnknown(
              data['audio_downloaded_bytes']!, _audioDownloadedBytesMeta));
    }
    if (data.containsKey('video_stream_size')) {
      context.handle(
          _videoStreamSizeMeta,
          videoStreamSize.isAcceptableOrUnknown(
              data['video_stream_size']!, _videoStreamSizeMeta));
    }
    if (data.containsKey('audio_progress')) {
      context.handle(
          _audioProgressMeta,
          audioProgress.isAcceptableOrUnknown(
              data['audio_progress']!, _audioProgressMeta));
    }
    if (data.containsKey('paused_by_user')) {
      context.handle(
          _pausedByUserMeta,
          pausedByUser.isAcceptableOrUnknown(
              data['paused_by_user']!, _pausedByUserMeta));
    }
    if (data.containsKey('youtube_quality_preset')) {
      context.handle(
          _youtubeQualityPresetMeta,
          youtubeQualityPreset.isAcceptableOrUnknown(
              data['youtube_quality_preset']!, _youtubeQualityPresetMeta));
    }
    if (data.containsKey('notes')) {
      context.handle(
          _notesMeta, notes.isAcceptableOrUnknown(data['notes']!, _notesMeta));
    }
    if (data.containsKey('playlist_id')) {
      context.handle(
          _playlistIdMeta,
          playlistId.isAcceptableOrUnknown(
              data['playlist_id']!, _playlistIdMeta));
    }
    if (data.containsKey('playlist_title')) {
      context.handle(
          _playlistTitleMeta,
          playlistTitle.isAcceptableOrUnknown(
              data['playlist_title']!, _playlistTitleMeta));
    }
    if (data.containsKey('thumbnail_url')) {
      context.handle(
          _thumbnailUrlMeta,
          thumbnailUrl.isAcceptableOrUnknown(
              data['thumbnail_url']!, _thumbnailUrlMeta));
    }
    if (data.containsKey('is_app_update')) {
      context.handle(
          _isAppUpdateMeta,
          isAppUpdate.isAcceptableOrUnknown(
              data['is_app_update']!, _isAppUpdateMeta));
    }
    if (data.containsKey('uploaded_bytes')) {
      context.handle(
          _uploadedBytesMeta,
          uploadedBytes.isAcceptableOrUnknown(
              data['uploaded_bytes']!, _uploadedBytesMeta));
    }
    if (data.containsKey('priority')) {
      context.handle(_priorityMeta,
          priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta));
    }
    if (data.containsKey('queue_order')) {
      context.handle(
          _queueOrderMeta,
          queueOrder.isAcceptableOrUnknown(
              data['queue_order']!, _queueOrderMeta));
    }
    if (data.containsKey('expected_sha256')) {
      context.handle(
          _expectedSha256Meta,
          expectedSha256.isAcceptableOrUnknown(
              data['expected_sha256']!, _expectedSha256Meta));
    }
    if (data.containsKey('pause_reason')) {
      context.handle(
          _pauseReasonMeta,
          pauseReason.isAcceptableOrUnknown(
              data['pause_reason']!, _pauseReasonMeta));
    }
    if (data.containsKey('total_pieces')) {
      context.handle(
          _totalPiecesMeta,
          totalPieces.isAcceptableOrUnknown(
              data['total_pieces']!, _totalPiecesMeta));
    }
    if (data.containsKey('completed_pieces')) {
      context.handle(
          _completedPiecesMeta,
          completedPieces.isAcceptableOrUnknown(
              data['completed_pieces']!, _completedPiecesMeta));
    }
    if (data.containsKey('yt_counterpart_downloaded_bytes')) {
      context.handle(
          _ytCounterpartDownloadedBytesMeta,
          ytCounterpartDownloadedBytes.isAcceptableOrUnknown(
              data['yt_counterpart_downloaded_bytes']!,
              _ytCounterpartDownloadedBytesMeta));
    }
    if (data.containsKey('cycle_state')) {
      context.handle(
          _cycleStateMeta,
          cycleState.isAcceptableOrUnknown(
              data['cycle_state']!, _cycleStateMeta));
    }
    if (data.containsKey('http_parts')) {
      context.handle(_httpPartsMeta,
          httpParts.isAcceptableOrUnknown(data['http_parts']!, _httpPartsMeta));
    }
    if (data.containsKey('torrent_piece_progress')) {
      context.handle(
          _torrentPieceProgressMeta,
          torrentPieceProgress.isAcceptableOrUnknown(
              data['torrent_piece_progress']!, _torrentPieceProgressMeta));
    }
    if (data.containsKey('audio_chunks_completed')) {
      context.handle(
          _audioChunksCompletedMeta,
          audioChunksCompleted.isAcceptableOrUnknown(
              data['audio_chunks_completed']!, _audioChunksCompletedMeta));
    }
    if (data.containsKey('audio_chunks_total')) {
      context.handle(
          _audioChunksTotalMeta,
          audioChunksTotal.isAcceptableOrUnknown(
              data['audio_chunks_total']!, _audioChunksTotalMeta));
    }
    if (data.containsKey('http_parts_completed')) {
      context.handle(
          _httpPartsCompletedMeta,
          httpPartsCompleted.isAcceptableOrUnknown(
              data['http_parts_completed']!, _httpPartsCompletedMeta));
    }
    if (data.containsKey('http_parts_total')) {
      context.handle(
          _httpPartsTotalMeta,
          httpPartsTotal.isAcceptableOrUnknown(
              data['http_parts_total']!, _httpPartsTotalMeta));
    }
    if (data.containsKey('previous_cycle_state')) {
      context.handle(
          _previousCycleStateMeta,
          previousCycleState.isAcceptableOrUnknown(
              data['previous_cycle_state']!, _previousCycleStateMeta));
    }
    if (data.containsKey('info_hash')) {
      context.handle(_infoHashMeta,
          infoHash.isAcceptableOrUnknown(data['info_hash']!, _infoHashMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbDownloadTask map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbDownloadTask(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      fileName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}file_name'])!,
      url: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}url'])!,
      fileSize: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}file_size'])!,
      downloadedBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}downloaded_bytes'])!,
      speed: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}speed'])!,
      eta: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}eta']),
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      savePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}save_path'])!,
      localFilePath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_file_path'])!,
      tempFilePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}temp_file_path'])!,
      errorMessage: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}error_message']),
      threadCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}thread_count'])!,
      chunks: $DownloadTasksTable.$converterchunks.fromSql(attachedDatabase
          .typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}chunks'])),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
      completedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}completed_at']),
      scheduledAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}scheduled_at']),
      supportsResume: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}supports_resume'])!,
      speedLimitKbps: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}speed_limit_kbps'])!,
      seedingEnabled: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}seeding_enabled'])!,
      seedingLimited: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}seeding_limited'])!,
      seedingLimitKbps: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}seeding_limit_kbps'])!,
      torrentFiles: $DownloadTasksTable.$convertertorrentFiles.fromSql(
          attachedDatabase.typeMapping.read(
              DriftSqlType.string, data['${effectivePrefix}torrent_files'])),
      downloadPageUrl: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}download_page_url']),
      mergedAudioUrl: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}merged_audio_url']),
      audioSize: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}audio_size'])!,
      audioDownloadedBytes: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}audio_downloaded_bytes'])!,
      videoStreamSize: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}video_stream_size'])!,
      audioProgress: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}audio_progress'])!,
      pausedByUser: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}paused_by_user'])!,
      youtubeQualityPreset: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}youtube_quality_preset']),
      notes: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}notes']),
      playlistId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}playlist_id']),
      playlistTitle: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}playlist_title']),
      thumbnailUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}thumbnail_url']),
      isAppUpdate: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_app_update'])!,
      uploadedBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}uploaded_bytes'])!,
      priority: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}priority'])!,
      queueOrder: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}queue_order'])!,
      expectedSha256: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}expected_sha256']),
      mirrorUrls: $DownloadTasksTable.$convertermirrorUrls.fromSql(
          attachedDatabase.typeMapping.read(
              DriftSqlType.string, data['${effectivePrefix}mirror_urls'])),
      pauseReason: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}pause_reason']),
      totalPieces: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_pieces']),
      completedPieces: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}completed_pieces']),
      ytCounterpartDownloadedBytes: attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}yt_counterpart_downloaded_bytes']),
      cycleState: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cycle_state']),
      audioChunks: $DownloadTasksTable.$converteraudioChunks.fromSql(
          attachedDatabase.typeMapping.read(
              DriftSqlType.string, data['${effectivePrefix}audio_chunks'])),
      httpParts: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}http_parts']),
      torrentPieceProgress: attachedDatabase.typeMapping.read(
          DriftSqlType.double,
          data['${effectivePrefix}torrent_piece_progress']),
      audioChunksCompleted: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}audio_chunks_completed']),
      audioChunksTotal: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}audio_chunks_total']),
      httpPartsCompleted: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}http_parts_completed']),
      httpPartsTotal: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}http_parts_total']),
      previousCycleState: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}previous_cycle_state']),
      infoHash: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}info_hash']),
    );
  }

  @override
  $DownloadTasksTable createAlias(String alias) {
    return $DownloadTasksTable(attachedDatabase, alias);
  }

  static TypeConverter<List<double>?, String?> $converterchunks =
      const NullAwareTypeConverter.wrap(DoubleListConverter());
  static TypeConverter<List<Map<String, dynamic>>?, String?>
      $convertertorrentFiles =
      const NullAwareTypeConverter.wrap(TorrentFilesConverter());
  static TypeConverter<List<String>?, String?> $convertermirrorUrls =
      const NullAwareTypeConverter.wrap(StringListConverter());
  static TypeConverter<List<double>?, String?> $converteraudioChunks =
      const NullAwareTypeConverter.wrap(DoubleListConverter());
}

class DbDownloadTask extends DataClass implements Insertable<DbDownloadTask> {
  final String id;
  final String fileName;
  final String url;
  final int fileSize;
  final int downloadedBytes;
  final double speed;
  final int? eta;
  final String category;
  final String status;
  final String savePath;
  final String localFilePath;
  final String tempFilePath;
  final String? errorMessage;
  final int threadCount;
  final List<double>? chunks;
  final int createdAt;
  final int updatedAt;
  final int? completedAt;
  final int? scheduledAt;
  final bool supportsResume;
  final int speedLimitKbps;
  final bool seedingEnabled;
  final bool seedingLimited;
  final int seedingLimitKbps;
  final List<Map<String, dynamic>>? torrentFiles;
  final String? downloadPageUrl;
  final String? mergedAudioUrl;
  final int audioSize;
  final int audioDownloadedBytes;
  final int videoStreamSize;
  final double audioProgress;
  final bool pausedByUser;
  final String? youtubeQualityPreset;
  final String? notes;
  final String? playlistId;
  final String? playlistTitle;
  final String? thumbnailUrl;
  final bool isAppUpdate;
  final int uploadedBytes;
  final int priority;
  final int queueOrder;
  final String? expectedSha256;
  final List<String>? mirrorUrls;
  final String? pauseReason;
  final int? totalPieces;
  final int? completedPieces;
  final int? ytCounterpartDownloadedBytes;
  final String? cycleState;
  final List<double>? audioChunks;
  final String? httpParts;
  final double? torrentPieceProgress;
  final int? audioChunksCompleted;
  final int? audioChunksTotal;
  final int? httpPartsCompleted;
  final int? httpPartsTotal;
  final String? previousCycleState;
  final String? infoHash;
  const DbDownloadTask(
      {required this.id,
      required this.fileName,
      required this.url,
      required this.fileSize,
      required this.downloadedBytes,
      required this.speed,
      this.eta,
      required this.category,
      required this.status,
      required this.savePath,
      required this.localFilePath,
      required this.tempFilePath,
      this.errorMessage,
      required this.threadCount,
      this.chunks,
      required this.createdAt,
      required this.updatedAt,
      this.completedAt,
      this.scheduledAt,
      required this.supportsResume,
      required this.speedLimitKbps,
      required this.seedingEnabled,
      required this.seedingLimited,
      required this.seedingLimitKbps,
      this.torrentFiles,
      this.downloadPageUrl,
      this.mergedAudioUrl,
      required this.audioSize,
      required this.audioDownloadedBytes,
      required this.videoStreamSize,
      required this.audioProgress,
      required this.pausedByUser,
      this.youtubeQualityPreset,
      this.notes,
      this.playlistId,
      this.playlistTitle,
      this.thumbnailUrl,
      required this.isAppUpdate,
      required this.uploadedBytes,
      required this.priority,
      required this.queueOrder,
      this.expectedSha256,
      this.mirrorUrls,
      this.pauseReason,
      this.totalPieces,
      this.completedPieces,
      this.ytCounterpartDownloadedBytes,
      this.cycleState,
      this.audioChunks,
      this.httpParts,
      this.torrentPieceProgress,
      this.audioChunksCompleted,
      this.audioChunksTotal,
      this.httpPartsCompleted,
      this.httpPartsTotal,
      this.previousCycleState,
      this.infoHash});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['file_name'] = Variable<String>(fileName);
    map['url'] = Variable<String>(url);
    map['file_size'] = Variable<int>(fileSize);
    map['downloaded_bytes'] = Variable<int>(downloadedBytes);
    map['speed'] = Variable<double>(speed);
    if (!nullToAbsent || eta != null) {
      map['eta'] = Variable<int>(eta);
    }
    map['category'] = Variable<String>(category);
    map['status'] = Variable<String>(status);
    map['save_path'] = Variable<String>(savePath);
    map['local_file_path'] = Variable<String>(localFilePath);
    map['temp_file_path'] = Variable<String>(tempFilePath);
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    map['thread_count'] = Variable<int>(threadCount);
    if (!nullToAbsent || chunks != null) {
      map['chunks'] =
          Variable<String>($DownloadTasksTable.$converterchunks.toSql(chunks));
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<int>(completedAt);
    }
    if (!nullToAbsent || scheduledAt != null) {
      map['scheduled_at'] = Variable<int>(scheduledAt);
    }
    map['supports_resume'] = Variable<bool>(supportsResume);
    map['speed_limit_kbps'] = Variable<int>(speedLimitKbps);
    map['seeding_enabled'] = Variable<bool>(seedingEnabled);
    map['seeding_limited'] = Variable<bool>(seedingLimited);
    map['seeding_limit_kbps'] = Variable<int>(seedingLimitKbps);
    if (!nullToAbsent || torrentFiles != null) {
      map['torrent_files'] = Variable<String>(
          $DownloadTasksTable.$convertertorrentFiles.toSql(torrentFiles));
    }
    if (!nullToAbsent || downloadPageUrl != null) {
      map['download_page_url'] = Variable<String>(downloadPageUrl);
    }
    if (!nullToAbsent || mergedAudioUrl != null) {
      map['merged_audio_url'] = Variable<String>(mergedAudioUrl);
    }
    map['audio_size'] = Variable<int>(audioSize);
    map['audio_downloaded_bytes'] = Variable<int>(audioDownloadedBytes);
    map['video_stream_size'] = Variable<int>(videoStreamSize);
    map['audio_progress'] = Variable<double>(audioProgress);
    map['paused_by_user'] = Variable<bool>(pausedByUser);
    if (!nullToAbsent || youtubeQualityPreset != null) {
      map['youtube_quality_preset'] = Variable<String>(youtubeQualityPreset);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
    }
    if (!nullToAbsent || playlistId != null) {
      map['playlist_id'] = Variable<String>(playlistId);
    }
    if (!nullToAbsent || playlistTitle != null) {
      map['playlist_title'] = Variable<String>(playlistTitle);
    }
    if (!nullToAbsent || thumbnailUrl != null) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl);
    }
    map['is_app_update'] = Variable<bool>(isAppUpdate);
    map['uploaded_bytes'] = Variable<int>(uploadedBytes);
    map['priority'] = Variable<int>(priority);
    map['queue_order'] = Variable<int>(queueOrder);
    if (!nullToAbsent || expectedSha256 != null) {
      map['expected_sha256'] = Variable<String>(expectedSha256);
    }
    if (!nullToAbsent || mirrorUrls != null) {
      map['mirror_urls'] = Variable<String>(
          $DownloadTasksTable.$convertermirrorUrls.toSql(mirrorUrls));
    }
    if (!nullToAbsent || pauseReason != null) {
      map['pause_reason'] = Variable<String>(pauseReason);
    }
    if (!nullToAbsent || totalPieces != null) {
      map['total_pieces'] = Variable<int>(totalPieces);
    }
    if (!nullToAbsent || completedPieces != null) {
      map['completed_pieces'] = Variable<int>(completedPieces);
    }
    if (!nullToAbsent || ytCounterpartDownloadedBytes != null) {
      map['yt_counterpart_downloaded_bytes'] =
          Variable<int>(ytCounterpartDownloadedBytes);
    }
    if (!nullToAbsent || cycleState != null) {
      map['cycle_state'] = Variable<String>(cycleState);
    }
    if (!nullToAbsent || audioChunks != null) {
      map['audio_chunks'] = Variable<String>(
          $DownloadTasksTable.$converteraudioChunks.toSql(audioChunks));
    }
    if (!nullToAbsent || httpParts != null) {
      map['http_parts'] = Variable<String>(httpParts);
    }
    if (!nullToAbsent || torrentPieceProgress != null) {
      map['torrent_piece_progress'] = Variable<double>(torrentPieceProgress);
    }
    if (!nullToAbsent || audioChunksCompleted != null) {
      map['audio_chunks_completed'] = Variable<int>(audioChunksCompleted);
    }
    if (!nullToAbsent || audioChunksTotal != null) {
      map['audio_chunks_total'] = Variable<int>(audioChunksTotal);
    }
    if (!nullToAbsent || httpPartsCompleted != null) {
      map['http_parts_completed'] = Variable<int>(httpPartsCompleted);
    }
    if (!nullToAbsent || httpPartsTotal != null) {
      map['http_parts_total'] = Variable<int>(httpPartsTotal);
    }
    if (!nullToAbsent || previousCycleState != null) {
      map['previous_cycle_state'] = Variable<String>(previousCycleState);
    }
    if (!nullToAbsent || infoHash != null) {
      map['info_hash'] = Variable<String>(infoHash);
    }
    return map;
  }

  DownloadTasksCompanion toCompanion(bool nullToAbsent) {
    return DownloadTasksCompanion(
      id: Value(id),
      fileName: Value(fileName),
      url: Value(url),
      fileSize: Value(fileSize),
      downloadedBytes: Value(downloadedBytes),
      speed: Value(speed),
      eta: eta == null && nullToAbsent ? const Value.absent() : Value(eta),
      category: Value(category),
      status: Value(status),
      savePath: Value(savePath),
      localFilePath: Value(localFilePath),
      tempFilePath: Value(tempFilePath),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      threadCount: Value(threadCount),
      chunks:
          chunks == null && nullToAbsent ? const Value.absent() : Value(chunks),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      scheduledAt: scheduledAt == null && nullToAbsent
          ? const Value.absent()
          : Value(scheduledAt),
      supportsResume: Value(supportsResume),
      speedLimitKbps: Value(speedLimitKbps),
      seedingEnabled: Value(seedingEnabled),
      seedingLimited: Value(seedingLimited),
      seedingLimitKbps: Value(seedingLimitKbps),
      torrentFiles: torrentFiles == null && nullToAbsent
          ? const Value.absent()
          : Value(torrentFiles),
      downloadPageUrl: downloadPageUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(downloadPageUrl),
      mergedAudioUrl: mergedAudioUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(mergedAudioUrl),
      audioSize: Value(audioSize),
      audioDownloadedBytes: Value(audioDownloadedBytes),
      videoStreamSize: Value(videoStreamSize),
      audioProgress: Value(audioProgress),
      pausedByUser: Value(pausedByUser),
      youtubeQualityPreset: youtubeQualityPreset == null && nullToAbsent
          ? const Value.absent()
          : Value(youtubeQualityPreset),
      notes:
          notes == null && nullToAbsent ? const Value.absent() : Value(notes),
      playlistId: playlistId == null && nullToAbsent
          ? const Value.absent()
          : Value(playlistId),
      playlistTitle: playlistTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(playlistTitle),
      thumbnailUrl: thumbnailUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(thumbnailUrl),
      isAppUpdate: Value(isAppUpdate),
      uploadedBytes: Value(uploadedBytes),
      priority: Value(priority),
      queueOrder: Value(queueOrder),
      expectedSha256: expectedSha256 == null && nullToAbsent
          ? const Value.absent()
          : Value(expectedSha256),
      mirrorUrls: mirrorUrls == null && nullToAbsent
          ? const Value.absent()
          : Value(mirrorUrls),
      pauseReason: pauseReason == null && nullToAbsent
          ? const Value.absent()
          : Value(pauseReason),
      totalPieces: totalPieces == null && nullToAbsent
          ? const Value.absent()
          : Value(totalPieces),
      completedPieces: completedPieces == null && nullToAbsent
          ? const Value.absent()
          : Value(completedPieces),
      ytCounterpartDownloadedBytes:
          ytCounterpartDownloadedBytes == null && nullToAbsent
              ? const Value.absent()
              : Value(ytCounterpartDownloadedBytes),
      cycleState: cycleState == null && nullToAbsent
          ? const Value.absent()
          : Value(cycleState),
      audioChunks: audioChunks == null && nullToAbsent
          ? const Value.absent()
          : Value(audioChunks),
      httpParts: httpParts == null && nullToAbsent
          ? const Value.absent()
          : Value(httpParts),
      torrentPieceProgress: torrentPieceProgress == null && nullToAbsent
          ? const Value.absent()
          : Value(torrentPieceProgress),
      audioChunksCompleted: audioChunksCompleted == null && nullToAbsent
          ? const Value.absent()
          : Value(audioChunksCompleted),
      audioChunksTotal: audioChunksTotal == null && nullToAbsent
          ? const Value.absent()
          : Value(audioChunksTotal),
      httpPartsCompleted: httpPartsCompleted == null && nullToAbsent
          ? const Value.absent()
          : Value(httpPartsCompleted),
      httpPartsTotal: httpPartsTotal == null && nullToAbsent
          ? const Value.absent()
          : Value(httpPartsTotal),
      previousCycleState: previousCycleState == null && nullToAbsent
          ? const Value.absent()
          : Value(previousCycleState),
      infoHash: infoHash == null && nullToAbsent
          ? const Value.absent()
          : Value(infoHash),
    );
  }

  factory DbDownloadTask.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbDownloadTask(
      id: serializer.fromJson<String>(json['id']),
      fileName: serializer.fromJson<String>(json['fileName']),
      url: serializer.fromJson<String>(json['url']),
      fileSize: serializer.fromJson<int>(json['fileSize']),
      downloadedBytes: serializer.fromJson<int>(json['downloadedBytes']),
      speed: serializer.fromJson<double>(json['speed']),
      eta: serializer.fromJson<int?>(json['eta']),
      category: serializer.fromJson<String>(json['category']),
      status: serializer.fromJson<String>(json['status']),
      savePath: serializer.fromJson<String>(json['savePath']),
      localFilePath: serializer.fromJson<String>(json['localFilePath']),
      tempFilePath: serializer.fromJson<String>(json['tempFilePath']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      threadCount: serializer.fromJson<int>(json['threadCount']),
      chunks: serializer.fromJson<List<double>?>(json['chunks']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      completedAt: serializer.fromJson<int?>(json['completedAt']),
      scheduledAt: serializer.fromJson<int?>(json['scheduledAt']),
      supportsResume: serializer.fromJson<bool>(json['supportsResume']),
      speedLimitKbps: serializer.fromJson<int>(json['speedLimitKbps']),
      seedingEnabled: serializer.fromJson<bool>(json['seedingEnabled']),
      seedingLimited: serializer.fromJson<bool>(json['seedingLimited']),
      seedingLimitKbps: serializer.fromJson<int>(json['seedingLimitKbps']),
      torrentFiles: serializer
          .fromJson<List<Map<String, dynamic>>?>(json['torrentFiles']),
      downloadPageUrl: serializer.fromJson<String?>(json['downloadPageUrl']),
      mergedAudioUrl: serializer.fromJson<String?>(json['mergedAudioUrl']),
      audioSize: serializer.fromJson<int>(json['audioSize']),
      audioDownloadedBytes:
          serializer.fromJson<int>(json['audioDownloadedBytes']),
      videoStreamSize: serializer.fromJson<int>(json['videoStreamSize']),
      audioProgress: serializer.fromJson<double>(json['audioProgress']),
      pausedByUser: serializer.fromJson<bool>(json['pausedByUser']),
      youtubeQualityPreset:
          serializer.fromJson<String?>(json['youtubeQualityPreset']),
      notes: serializer.fromJson<String?>(json['notes']),
      playlistId: serializer.fromJson<String?>(json['playlistId']),
      playlistTitle: serializer.fromJson<String?>(json['playlistTitle']),
      thumbnailUrl: serializer.fromJson<String?>(json['thumbnailUrl']),
      isAppUpdate: serializer.fromJson<bool>(json['isAppUpdate']),
      uploadedBytes: serializer.fromJson<int>(json['uploadedBytes']),
      priority: serializer.fromJson<int>(json['priority']),
      queueOrder: serializer.fromJson<int>(json['queueOrder']),
      expectedSha256: serializer.fromJson<String?>(json['expectedSha256']),
      mirrorUrls: serializer.fromJson<List<String>?>(json['mirrorUrls']),
      pauseReason: serializer.fromJson<String?>(json['pauseReason']),
      totalPieces: serializer.fromJson<int?>(json['totalPieces']),
      completedPieces: serializer.fromJson<int?>(json['completedPieces']),
      ytCounterpartDownloadedBytes:
          serializer.fromJson<int?>(json['ytCounterpartDownloadedBytes']),
      cycleState: serializer.fromJson<String?>(json['cycleState']),
      audioChunks: serializer.fromJson<List<double>?>(json['audioChunks']),
      httpParts: serializer.fromJson<String?>(json['httpParts']),
      torrentPieceProgress:
          serializer.fromJson<double?>(json['torrentPieceProgress']),
      audioChunksCompleted:
          serializer.fromJson<int?>(json['audioChunksCompleted']),
      audioChunksTotal: serializer.fromJson<int?>(json['audioChunksTotal']),
      httpPartsCompleted: serializer.fromJson<int?>(json['httpPartsCompleted']),
      httpPartsTotal: serializer.fromJson<int?>(json['httpPartsTotal']),
      previousCycleState:
          serializer.fromJson<String?>(json['previousCycleState']),
      infoHash: serializer.fromJson<String?>(json['infoHash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'fileName': serializer.toJson<String>(fileName),
      'url': serializer.toJson<String>(url),
      'fileSize': serializer.toJson<int>(fileSize),
      'downloadedBytes': serializer.toJson<int>(downloadedBytes),
      'speed': serializer.toJson<double>(speed),
      'eta': serializer.toJson<int?>(eta),
      'category': serializer.toJson<String>(category),
      'status': serializer.toJson<String>(status),
      'savePath': serializer.toJson<String>(savePath),
      'localFilePath': serializer.toJson<String>(localFilePath),
      'tempFilePath': serializer.toJson<String>(tempFilePath),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'threadCount': serializer.toJson<int>(threadCount),
      'chunks': serializer.toJson<List<double>?>(chunks),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'completedAt': serializer.toJson<int?>(completedAt),
      'scheduledAt': serializer.toJson<int?>(scheduledAt),
      'supportsResume': serializer.toJson<bool>(supportsResume),
      'speedLimitKbps': serializer.toJson<int>(speedLimitKbps),
      'seedingEnabled': serializer.toJson<bool>(seedingEnabled),
      'seedingLimited': serializer.toJson<bool>(seedingLimited),
      'seedingLimitKbps': serializer.toJson<int>(seedingLimitKbps),
      'torrentFiles':
          serializer.toJson<List<Map<String, dynamic>>?>(torrentFiles),
      'downloadPageUrl': serializer.toJson<String?>(downloadPageUrl),
      'mergedAudioUrl': serializer.toJson<String?>(mergedAudioUrl),
      'audioSize': serializer.toJson<int>(audioSize),
      'audioDownloadedBytes': serializer.toJson<int>(audioDownloadedBytes),
      'videoStreamSize': serializer.toJson<int>(videoStreamSize),
      'audioProgress': serializer.toJson<double>(audioProgress),
      'pausedByUser': serializer.toJson<bool>(pausedByUser),
      'youtubeQualityPreset': serializer.toJson<String?>(youtubeQualityPreset),
      'notes': serializer.toJson<String?>(notes),
      'playlistId': serializer.toJson<String?>(playlistId),
      'playlistTitle': serializer.toJson<String?>(playlistTitle),
      'thumbnailUrl': serializer.toJson<String?>(thumbnailUrl),
      'isAppUpdate': serializer.toJson<bool>(isAppUpdate),
      'uploadedBytes': serializer.toJson<int>(uploadedBytes),
      'priority': serializer.toJson<int>(priority),
      'queueOrder': serializer.toJson<int>(queueOrder),
      'expectedSha256': serializer.toJson<String?>(expectedSha256),
      'mirrorUrls': serializer.toJson<List<String>?>(mirrorUrls),
      'pauseReason': serializer.toJson<String?>(pauseReason),
      'totalPieces': serializer.toJson<int?>(totalPieces),
      'completedPieces': serializer.toJson<int?>(completedPieces),
      'ytCounterpartDownloadedBytes':
          serializer.toJson<int?>(ytCounterpartDownloadedBytes),
      'cycleState': serializer.toJson<String?>(cycleState),
      'audioChunks': serializer.toJson<List<double>?>(audioChunks),
      'httpParts': serializer.toJson<String?>(httpParts),
      'torrentPieceProgress': serializer.toJson<double?>(torrentPieceProgress),
      'audioChunksCompleted': serializer.toJson<int?>(audioChunksCompleted),
      'audioChunksTotal': serializer.toJson<int?>(audioChunksTotal),
      'httpPartsCompleted': serializer.toJson<int?>(httpPartsCompleted),
      'httpPartsTotal': serializer.toJson<int?>(httpPartsTotal),
      'previousCycleState': serializer.toJson<String?>(previousCycleState),
      'infoHash': serializer.toJson<String?>(infoHash),
    };
  }

  DbDownloadTask copyWith(
          {String? id,
          String? fileName,
          String? url,
          int? fileSize,
          int? downloadedBytes,
          double? speed,
          Value<int?> eta = const Value.absent(),
          String? category,
          String? status,
          String? savePath,
          String? localFilePath,
          String? tempFilePath,
          Value<String?> errorMessage = const Value.absent(),
          int? threadCount,
          Value<List<double>?> chunks = const Value.absent(),
          int? createdAt,
          int? updatedAt,
          Value<int?> completedAt = const Value.absent(),
          Value<int?> scheduledAt = const Value.absent(),
          bool? supportsResume,
          int? speedLimitKbps,
          bool? seedingEnabled,
          bool? seedingLimited,
          int? seedingLimitKbps,
          Value<List<Map<String, dynamic>>?> torrentFiles =
              const Value.absent(),
          Value<String?> downloadPageUrl = const Value.absent(),
          Value<String?> mergedAudioUrl = const Value.absent(),
          int? audioSize,
          int? audioDownloadedBytes,
          int? videoStreamSize,
          double? audioProgress,
          bool? pausedByUser,
          Value<String?> youtubeQualityPreset = const Value.absent(),
          Value<String?> notes = const Value.absent(),
          Value<String?> playlistId = const Value.absent(),
          Value<String?> playlistTitle = const Value.absent(),
          Value<String?> thumbnailUrl = const Value.absent(),
          bool? isAppUpdate,
          int? uploadedBytes,
          int? priority,
          int? queueOrder,
          Value<String?> expectedSha256 = const Value.absent(),
          Value<List<String>?> mirrorUrls = const Value.absent(),
          Value<String?> pauseReason = const Value.absent(),
          Value<int?> totalPieces = const Value.absent(),
          Value<int?> completedPieces = const Value.absent(),
          Value<int?> ytCounterpartDownloadedBytes = const Value.absent(),
          Value<String?> cycleState = const Value.absent(),
          Value<List<double>?> audioChunks = const Value.absent(),
          Value<String?> httpParts = const Value.absent(),
          Value<double?> torrentPieceProgress = const Value.absent(),
          Value<int?> audioChunksCompleted = const Value.absent(),
          Value<int?> audioChunksTotal = const Value.absent(),
          Value<int?> httpPartsCompleted = const Value.absent(),
          Value<int?> httpPartsTotal = const Value.absent(),
          Value<String?> previousCycleState = const Value.absent(),
          Value<String?> infoHash = const Value.absent()}) =>
      DbDownloadTask(
        id: id ?? this.id,
        fileName: fileName ?? this.fileName,
        url: url ?? this.url,
        fileSize: fileSize ?? this.fileSize,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        speed: speed ?? this.speed,
        eta: eta.present ? eta.value : this.eta,
        category: category ?? this.category,
        status: status ?? this.status,
        savePath: savePath ?? this.savePath,
        localFilePath: localFilePath ?? this.localFilePath,
        tempFilePath: tempFilePath ?? this.tempFilePath,
        errorMessage:
            errorMessage.present ? errorMessage.value : this.errorMessage,
        threadCount: threadCount ?? this.threadCount,
        chunks: chunks.present ? chunks.value : this.chunks,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        completedAt: completedAt.present ? completedAt.value : this.completedAt,
        scheduledAt: scheduledAt.present ? scheduledAt.value : this.scheduledAt,
        supportsResume: supportsResume ?? this.supportsResume,
        speedLimitKbps: speedLimitKbps ?? this.speedLimitKbps,
        seedingEnabled: seedingEnabled ?? this.seedingEnabled,
        seedingLimited: seedingLimited ?? this.seedingLimited,
        seedingLimitKbps: seedingLimitKbps ?? this.seedingLimitKbps,
        torrentFiles:
            torrentFiles.present ? torrentFiles.value : this.torrentFiles,
        downloadPageUrl: downloadPageUrl.present
            ? downloadPageUrl.value
            : this.downloadPageUrl,
        mergedAudioUrl:
            mergedAudioUrl.present ? mergedAudioUrl.value : this.mergedAudioUrl,
        audioSize: audioSize ?? this.audioSize,
        audioDownloadedBytes: audioDownloadedBytes ?? this.audioDownloadedBytes,
        videoStreamSize: videoStreamSize ?? this.videoStreamSize,
        audioProgress: audioProgress ?? this.audioProgress,
        pausedByUser: pausedByUser ?? this.pausedByUser,
        youtubeQualityPreset: youtubeQualityPreset.present
            ? youtubeQualityPreset.value
            : this.youtubeQualityPreset,
        notes: notes.present ? notes.value : this.notes,
        playlistId: playlistId.present ? playlistId.value : this.playlistId,
        playlistTitle:
            playlistTitle.present ? playlistTitle.value : this.playlistTitle,
        thumbnailUrl:
            thumbnailUrl.present ? thumbnailUrl.value : this.thumbnailUrl,
        isAppUpdate: isAppUpdate ?? this.isAppUpdate,
        uploadedBytes: uploadedBytes ?? this.uploadedBytes,
        priority: priority ?? this.priority,
        queueOrder: queueOrder ?? this.queueOrder,
        expectedSha256:
            expectedSha256.present ? expectedSha256.value : this.expectedSha256,
        mirrorUrls: mirrorUrls.present ? mirrorUrls.value : this.mirrorUrls,
        pauseReason: pauseReason.present ? pauseReason.value : this.pauseReason,
        totalPieces: totalPieces.present ? totalPieces.value : this.totalPieces,
        completedPieces: completedPieces.present
            ? completedPieces.value
            : this.completedPieces,
        ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes.present
            ? ytCounterpartDownloadedBytes.value
            : this.ytCounterpartDownloadedBytes,
        cycleState: cycleState.present ? cycleState.value : this.cycleState,
        audioChunks: audioChunks.present ? audioChunks.value : this.audioChunks,
        httpParts: httpParts.present ? httpParts.value : this.httpParts,
        torrentPieceProgress: torrentPieceProgress.present
            ? torrentPieceProgress.value
            : this.torrentPieceProgress,
        audioChunksCompleted: audioChunksCompleted.present
            ? audioChunksCompleted.value
            : this.audioChunksCompleted,
        audioChunksTotal: audioChunksTotal.present
            ? audioChunksTotal.value
            : this.audioChunksTotal,
        httpPartsCompleted: httpPartsCompleted.present
            ? httpPartsCompleted.value
            : this.httpPartsCompleted,
        httpPartsTotal:
            httpPartsTotal.present ? httpPartsTotal.value : this.httpPartsTotal,
        previousCycleState: previousCycleState.present
            ? previousCycleState.value
            : this.previousCycleState,
        infoHash: infoHash.present ? infoHash.value : this.infoHash,
      );
  DbDownloadTask copyWithCompanion(DownloadTasksCompanion data) {
    return DbDownloadTask(
      id: data.id.present ? data.id.value : this.id,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      url: data.url.present ? data.url.value : this.url,
      fileSize: data.fileSize.present ? data.fileSize.value : this.fileSize,
      downloadedBytes: data.downloadedBytes.present
          ? data.downloadedBytes.value
          : this.downloadedBytes,
      speed: data.speed.present ? data.speed.value : this.speed,
      eta: data.eta.present ? data.eta.value : this.eta,
      category: data.category.present ? data.category.value : this.category,
      status: data.status.present ? data.status.value : this.status,
      savePath: data.savePath.present ? data.savePath.value : this.savePath,
      localFilePath: data.localFilePath.present
          ? data.localFilePath.value
          : this.localFilePath,
      tempFilePath: data.tempFilePath.present
          ? data.tempFilePath.value
          : this.tempFilePath,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      threadCount:
          data.threadCount.present ? data.threadCount.value : this.threadCount,
      chunks: data.chunks.present ? data.chunks.value : this.chunks,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      completedAt:
          data.completedAt.present ? data.completedAt.value : this.completedAt,
      scheduledAt:
          data.scheduledAt.present ? data.scheduledAt.value : this.scheduledAt,
      supportsResume: data.supportsResume.present
          ? data.supportsResume.value
          : this.supportsResume,
      speedLimitKbps: data.speedLimitKbps.present
          ? data.speedLimitKbps.value
          : this.speedLimitKbps,
      seedingEnabled: data.seedingEnabled.present
          ? data.seedingEnabled.value
          : this.seedingEnabled,
      seedingLimited: data.seedingLimited.present
          ? data.seedingLimited.value
          : this.seedingLimited,
      seedingLimitKbps: data.seedingLimitKbps.present
          ? data.seedingLimitKbps.value
          : this.seedingLimitKbps,
      torrentFiles: data.torrentFiles.present
          ? data.torrentFiles.value
          : this.torrentFiles,
      downloadPageUrl: data.downloadPageUrl.present
          ? data.downloadPageUrl.value
          : this.downloadPageUrl,
      mergedAudioUrl: data.mergedAudioUrl.present
          ? data.mergedAudioUrl.value
          : this.mergedAudioUrl,
      audioSize: data.audioSize.present ? data.audioSize.value : this.audioSize,
      audioDownloadedBytes: data.audioDownloadedBytes.present
          ? data.audioDownloadedBytes.value
          : this.audioDownloadedBytes,
      videoStreamSize: data.videoStreamSize.present
          ? data.videoStreamSize.value
          : this.videoStreamSize,
      audioProgress: data.audioProgress.present
          ? data.audioProgress.value
          : this.audioProgress,
      pausedByUser: data.pausedByUser.present
          ? data.pausedByUser.value
          : this.pausedByUser,
      youtubeQualityPreset: data.youtubeQualityPreset.present
          ? data.youtubeQualityPreset.value
          : this.youtubeQualityPreset,
      notes: data.notes.present ? data.notes.value : this.notes,
      playlistId:
          data.playlistId.present ? data.playlistId.value : this.playlistId,
      playlistTitle: data.playlistTitle.present
          ? data.playlistTitle.value
          : this.playlistTitle,
      thumbnailUrl: data.thumbnailUrl.present
          ? data.thumbnailUrl.value
          : this.thumbnailUrl,
      isAppUpdate:
          data.isAppUpdate.present ? data.isAppUpdate.value : this.isAppUpdate,
      uploadedBytes: data.uploadedBytes.present
          ? data.uploadedBytes.value
          : this.uploadedBytes,
      priority: data.priority.present ? data.priority.value : this.priority,
      queueOrder:
          data.queueOrder.present ? data.queueOrder.value : this.queueOrder,
      expectedSha256: data.expectedSha256.present
          ? data.expectedSha256.value
          : this.expectedSha256,
      mirrorUrls:
          data.mirrorUrls.present ? data.mirrorUrls.value : this.mirrorUrls,
      pauseReason:
          data.pauseReason.present ? data.pauseReason.value : this.pauseReason,
      totalPieces:
          data.totalPieces.present ? data.totalPieces.value : this.totalPieces,
      completedPieces: data.completedPieces.present
          ? data.completedPieces.value
          : this.completedPieces,
      ytCounterpartDownloadedBytes: data.ytCounterpartDownloadedBytes.present
          ? data.ytCounterpartDownloadedBytes.value
          : this.ytCounterpartDownloadedBytes,
      cycleState:
          data.cycleState.present ? data.cycleState.value : this.cycleState,
      audioChunks:
          data.audioChunks.present ? data.audioChunks.value : this.audioChunks,
      httpParts: data.httpParts.present ? data.httpParts.value : this.httpParts,
      torrentPieceProgress: data.torrentPieceProgress.present
          ? data.torrentPieceProgress.value
          : this.torrentPieceProgress,
      audioChunksCompleted: data.audioChunksCompleted.present
          ? data.audioChunksCompleted.value
          : this.audioChunksCompleted,
      audioChunksTotal: data.audioChunksTotal.present
          ? data.audioChunksTotal.value
          : this.audioChunksTotal,
      httpPartsCompleted: data.httpPartsCompleted.present
          ? data.httpPartsCompleted.value
          : this.httpPartsCompleted,
      httpPartsTotal: data.httpPartsTotal.present
          ? data.httpPartsTotal.value
          : this.httpPartsTotal,
      previousCycleState: data.previousCycleState.present
          ? data.previousCycleState.value
          : this.previousCycleState,
      infoHash: data.infoHash.present ? data.infoHash.value : this.infoHash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbDownloadTask(')
          ..write('id: $id, ')
          ..write('fileName: $fileName, ')
          ..write('url: $url, ')
          ..write('fileSize: $fileSize, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('speed: $speed, ')
          ..write('eta: $eta, ')
          ..write('category: $category, ')
          ..write('status: $status, ')
          ..write('savePath: $savePath, ')
          ..write('localFilePath: $localFilePath, ')
          ..write('tempFilePath: $tempFilePath, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('threadCount: $threadCount, ')
          ..write('chunks: $chunks, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('completedAt: $completedAt, ')
          ..write('scheduledAt: $scheduledAt, ')
          ..write('supportsResume: $supportsResume, ')
          ..write('speedLimitKbps: $speedLimitKbps, ')
          ..write('seedingEnabled: $seedingEnabled, ')
          ..write('seedingLimited: $seedingLimited, ')
          ..write('seedingLimitKbps: $seedingLimitKbps, ')
          ..write('torrentFiles: $torrentFiles, ')
          ..write('downloadPageUrl: $downloadPageUrl, ')
          ..write('mergedAudioUrl: $mergedAudioUrl, ')
          ..write('audioSize: $audioSize, ')
          ..write('audioDownloadedBytes: $audioDownloadedBytes, ')
          ..write('videoStreamSize: $videoStreamSize, ')
          ..write('audioProgress: $audioProgress, ')
          ..write('pausedByUser: $pausedByUser, ')
          ..write('youtubeQualityPreset: $youtubeQualityPreset, ')
          ..write('notes: $notes, ')
          ..write('playlistId: $playlistId, ')
          ..write('playlistTitle: $playlistTitle, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('isAppUpdate: $isAppUpdate, ')
          ..write('uploadedBytes: $uploadedBytes, ')
          ..write('priority: $priority, ')
          ..write('queueOrder: $queueOrder, ')
          ..write('expectedSha256: $expectedSha256, ')
          ..write('mirrorUrls: $mirrorUrls, ')
          ..write('pauseReason: $pauseReason, ')
          ..write('totalPieces: $totalPieces, ')
          ..write('completedPieces: $completedPieces, ')
          ..write(
              'ytCounterpartDownloadedBytes: $ytCounterpartDownloadedBytes, ')
          ..write('cycleState: $cycleState, ')
          ..write('audioChunks: $audioChunks, ')
          ..write('httpParts: $httpParts, ')
          ..write('torrentPieceProgress: $torrentPieceProgress, ')
          ..write('audioChunksCompleted: $audioChunksCompleted, ')
          ..write('audioChunksTotal: $audioChunksTotal, ')
          ..write('httpPartsCompleted: $httpPartsCompleted, ')
          ..write('httpPartsTotal: $httpPartsTotal, ')
          ..write('previousCycleState: $previousCycleState, ')
          ..write('infoHash: $infoHash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        fileName,
        url,
        fileSize,
        downloadedBytes,
        speed,
        eta,
        category,
        status,
        savePath,
        localFilePath,
        tempFilePath,
        errorMessage,
        threadCount,
        chunks,
        createdAt,
        updatedAt,
        completedAt,
        scheduledAt,
        supportsResume,
        speedLimitKbps,
        seedingEnabled,
        seedingLimited,
        seedingLimitKbps,
        torrentFiles,
        downloadPageUrl,
        mergedAudioUrl,
        audioSize,
        audioDownloadedBytes,
        videoStreamSize,
        audioProgress,
        pausedByUser,
        youtubeQualityPreset,
        notes,
        playlistId,
        playlistTitle,
        thumbnailUrl,
        isAppUpdate,
        uploadedBytes,
        priority,
        queueOrder,
        expectedSha256,
        mirrorUrls,
        pauseReason,
        totalPieces,
        completedPieces,
        ytCounterpartDownloadedBytes,
        cycleState,
        audioChunks,
        httpParts,
        torrentPieceProgress,
        audioChunksCompleted,
        audioChunksTotal,
        httpPartsCompleted,
        httpPartsTotal,
        previousCycleState,
        infoHash
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbDownloadTask &&
          other.id == this.id &&
          other.fileName == this.fileName &&
          other.url == this.url &&
          other.fileSize == this.fileSize &&
          other.downloadedBytes == this.downloadedBytes &&
          other.speed == this.speed &&
          other.eta == this.eta &&
          other.category == this.category &&
          other.status == this.status &&
          other.savePath == this.savePath &&
          other.localFilePath == this.localFilePath &&
          other.tempFilePath == this.tempFilePath &&
          other.errorMessage == this.errorMessage &&
          other.threadCount == this.threadCount &&
          other.chunks == this.chunks &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.completedAt == this.completedAt &&
          other.scheduledAt == this.scheduledAt &&
          other.supportsResume == this.supportsResume &&
          other.speedLimitKbps == this.speedLimitKbps &&
          other.seedingEnabled == this.seedingEnabled &&
          other.seedingLimited == this.seedingLimited &&
          other.seedingLimitKbps == this.seedingLimitKbps &&
          other.torrentFiles == this.torrentFiles &&
          other.downloadPageUrl == this.downloadPageUrl &&
          other.mergedAudioUrl == this.mergedAudioUrl &&
          other.audioSize == this.audioSize &&
          other.audioDownloadedBytes == this.audioDownloadedBytes &&
          other.videoStreamSize == this.videoStreamSize &&
          other.audioProgress == this.audioProgress &&
          other.pausedByUser == this.pausedByUser &&
          other.youtubeQualityPreset == this.youtubeQualityPreset &&
          other.notes == this.notes &&
          other.playlistId == this.playlistId &&
          other.playlistTitle == this.playlistTitle &&
          other.thumbnailUrl == this.thumbnailUrl &&
          other.isAppUpdate == this.isAppUpdate &&
          other.uploadedBytes == this.uploadedBytes &&
          other.priority == this.priority &&
          other.queueOrder == this.queueOrder &&
          other.expectedSha256 == this.expectedSha256 &&
          other.mirrorUrls == this.mirrorUrls &&
          other.pauseReason == this.pauseReason &&
          other.totalPieces == this.totalPieces &&
          other.completedPieces == this.completedPieces &&
          other.ytCounterpartDownloadedBytes ==
              this.ytCounterpartDownloadedBytes &&
          other.cycleState == this.cycleState &&
          other.audioChunks == this.audioChunks &&
          other.httpParts == this.httpParts &&
          other.torrentPieceProgress == this.torrentPieceProgress &&
          other.audioChunksCompleted == this.audioChunksCompleted &&
          other.audioChunksTotal == this.audioChunksTotal &&
          other.httpPartsCompleted == this.httpPartsCompleted &&
          other.httpPartsTotal == this.httpPartsTotal &&
          other.previousCycleState == this.previousCycleState &&
          other.infoHash == this.infoHash);
}

class DownloadTasksCompanion extends UpdateCompanion<DbDownloadTask> {
  final Value<String> id;
  final Value<String> fileName;
  final Value<String> url;
  final Value<int> fileSize;
  final Value<int> downloadedBytes;
  final Value<double> speed;
  final Value<int?> eta;
  final Value<String> category;
  final Value<String> status;
  final Value<String> savePath;
  final Value<String> localFilePath;
  final Value<String> tempFilePath;
  final Value<String?> errorMessage;
  final Value<int> threadCount;
  final Value<List<double>?> chunks;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> completedAt;
  final Value<int?> scheduledAt;
  final Value<bool> supportsResume;
  final Value<int> speedLimitKbps;
  final Value<bool> seedingEnabled;
  final Value<bool> seedingLimited;
  final Value<int> seedingLimitKbps;
  final Value<List<Map<String, dynamic>>?> torrentFiles;
  final Value<String?> downloadPageUrl;
  final Value<String?> mergedAudioUrl;
  final Value<int> audioSize;
  final Value<int> audioDownloadedBytes;
  final Value<int> videoStreamSize;
  final Value<double> audioProgress;
  final Value<bool> pausedByUser;
  final Value<String?> youtubeQualityPreset;
  final Value<String?> notes;
  final Value<String?> playlistId;
  final Value<String?> playlistTitle;
  final Value<String?> thumbnailUrl;
  final Value<bool> isAppUpdate;
  final Value<int> uploadedBytes;
  final Value<int> priority;
  final Value<int> queueOrder;
  final Value<String?> expectedSha256;
  final Value<List<String>?> mirrorUrls;
  final Value<String?> pauseReason;
  final Value<int?> totalPieces;
  final Value<int?> completedPieces;
  final Value<int?> ytCounterpartDownloadedBytes;
  final Value<String?> cycleState;
  final Value<List<double>?> audioChunks;
  final Value<String?> httpParts;
  final Value<double?> torrentPieceProgress;
  final Value<int?> audioChunksCompleted;
  final Value<int?> audioChunksTotal;
  final Value<int?> httpPartsCompleted;
  final Value<int?> httpPartsTotal;
  final Value<String?> previousCycleState;
  final Value<String?> infoHash;
  final Value<int> rowid;
  const DownloadTasksCompanion({
    this.id = const Value.absent(),
    this.fileName = const Value.absent(),
    this.url = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.speed = const Value.absent(),
    this.eta = const Value.absent(),
    this.category = const Value.absent(),
    this.status = const Value.absent(),
    this.savePath = const Value.absent(),
    this.localFilePath = const Value.absent(),
    this.tempFilePath = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.threadCount = const Value.absent(),
    this.chunks = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.scheduledAt = const Value.absent(),
    this.supportsResume = const Value.absent(),
    this.speedLimitKbps = const Value.absent(),
    this.seedingEnabled = const Value.absent(),
    this.seedingLimited = const Value.absent(),
    this.seedingLimitKbps = const Value.absent(),
    this.torrentFiles = const Value.absent(),
    this.downloadPageUrl = const Value.absent(),
    this.mergedAudioUrl = const Value.absent(),
    this.audioSize = const Value.absent(),
    this.audioDownloadedBytes = const Value.absent(),
    this.videoStreamSize = const Value.absent(),
    this.audioProgress = const Value.absent(),
    this.pausedByUser = const Value.absent(),
    this.youtubeQualityPreset = const Value.absent(),
    this.notes = const Value.absent(),
    this.playlistId = const Value.absent(),
    this.playlistTitle = const Value.absent(),
    this.thumbnailUrl = const Value.absent(),
    this.isAppUpdate = const Value.absent(),
    this.uploadedBytes = const Value.absent(),
    this.priority = const Value.absent(),
    this.queueOrder = const Value.absent(),
    this.expectedSha256 = const Value.absent(),
    this.mirrorUrls = const Value.absent(),
    this.pauseReason = const Value.absent(),
    this.totalPieces = const Value.absent(),
    this.completedPieces = const Value.absent(),
    this.ytCounterpartDownloadedBytes = const Value.absent(),
    this.cycleState = const Value.absent(),
    this.audioChunks = const Value.absent(),
    this.httpParts = const Value.absent(),
    this.torrentPieceProgress = const Value.absent(),
    this.audioChunksCompleted = const Value.absent(),
    this.audioChunksTotal = const Value.absent(),
    this.httpPartsCompleted = const Value.absent(),
    this.httpPartsTotal = const Value.absent(),
    this.previousCycleState = const Value.absent(),
    this.infoHash = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadTasksCompanion.insert({
    required String id,
    required String fileName,
    required String url,
    this.fileSize = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.speed = const Value.absent(),
    this.eta = const Value.absent(),
    required String category,
    required String status,
    required String savePath,
    required String localFilePath,
    required String tempFilePath,
    this.errorMessage = const Value.absent(),
    required int threadCount,
    this.chunks = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.completedAt = const Value.absent(),
    this.scheduledAt = const Value.absent(),
    this.supportsResume = const Value.absent(),
    this.speedLimitKbps = const Value.absent(),
    this.seedingEnabled = const Value.absent(),
    this.seedingLimited = const Value.absent(),
    this.seedingLimitKbps = const Value.absent(),
    this.torrentFiles = const Value.absent(),
    this.downloadPageUrl = const Value.absent(),
    this.mergedAudioUrl = const Value.absent(),
    this.audioSize = const Value.absent(),
    this.audioDownloadedBytes = const Value.absent(),
    this.videoStreamSize = const Value.absent(),
    this.audioProgress = const Value.absent(),
    this.pausedByUser = const Value.absent(),
    this.youtubeQualityPreset = const Value.absent(),
    this.notes = const Value.absent(),
    this.playlistId = const Value.absent(),
    this.playlistTitle = const Value.absent(),
    this.thumbnailUrl = const Value.absent(),
    this.isAppUpdate = const Value.absent(),
    this.uploadedBytes = const Value.absent(),
    this.priority = const Value.absent(),
    this.queueOrder = const Value.absent(),
    this.expectedSha256 = const Value.absent(),
    this.mirrorUrls = const Value.absent(),
    this.pauseReason = const Value.absent(),
    this.totalPieces = const Value.absent(),
    this.completedPieces = const Value.absent(),
    this.ytCounterpartDownloadedBytes = const Value.absent(),
    this.cycleState = const Value.absent(),
    this.audioChunks = const Value.absent(),
    this.httpParts = const Value.absent(),
    this.torrentPieceProgress = const Value.absent(),
    this.audioChunksCompleted = const Value.absent(),
    this.audioChunksTotal = const Value.absent(),
    this.httpPartsCompleted = const Value.absent(),
    this.httpPartsTotal = const Value.absent(),
    this.previousCycleState = const Value.absent(),
    this.infoHash = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        fileName = Value(fileName),
        url = Value(url),
        category = Value(category),
        status = Value(status),
        savePath = Value(savePath),
        localFilePath = Value(localFilePath),
        tempFilePath = Value(tempFilePath),
        threadCount = Value(threadCount),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt);
  static Insertable<DbDownloadTask> custom({
    Expression<String>? id,
    Expression<String>? fileName,
    Expression<String>? url,
    Expression<int>? fileSize,
    Expression<int>? downloadedBytes,
    Expression<double>? speed,
    Expression<int>? eta,
    Expression<String>? category,
    Expression<String>? status,
    Expression<String>? savePath,
    Expression<String>? localFilePath,
    Expression<String>? tempFilePath,
    Expression<String>? errorMessage,
    Expression<int>? threadCount,
    Expression<String>? chunks,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? completedAt,
    Expression<int>? scheduledAt,
    Expression<bool>? supportsResume,
    Expression<int>? speedLimitKbps,
    Expression<bool>? seedingEnabled,
    Expression<bool>? seedingLimited,
    Expression<int>? seedingLimitKbps,
    Expression<String>? torrentFiles,
    Expression<String>? downloadPageUrl,
    Expression<String>? mergedAudioUrl,
    Expression<int>? audioSize,
    Expression<int>? audioDownloadedBytes,
    Expression<int>? videoStreamSize,
    Expression<double>? audioProgress,
    Expression<bool>? pausedByUser,
    Expression<String>? youtubeQualityPreset,
    Expression<String>? notes,
    Expression<String>? playlistId,
    Expression<String>? playlistTitle,
    Expression<String>? thumbnailUrl,
    Expression<bool>? isAppUpdate,
    Expression<int>? uploadedBytes,
    Expression<int>? priority,
    Expression<int>? queueOrder,
    Expression<String>? expectedSha256,
    Expression<String>? mirrorUrls,
    Expression<String>? pauseReason,
    Expression<int>? totalPieces,
    Expression<int>? completedPieces,
    Expression<int>? ytCounterpartDownloadedBytes,
    Expression<String>? cycleState,
    Expression<String>? audioChunks,
    Expression<String>? httpParts,
    Expression<double>? torrentPieceProgress,
    Expression<int>? audioChunksCompleted,
    Expression<int>? audioChunksTotal,
    Expression<int>? httpPartsCompleted,
    Expression<int>? httpPartsTotal,
    Expression<String>? previousCycleState,
    Expression<String>? infoHash,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (fileName != null) 'file_name': fileName,
      if (url != null) 'url': url,
      if (fileSize != null) 'file_size': fileSize,
      if (downloadedBytes != null) 'downloaded_bytes': downloadedBytes,
      if (speed != null) 'speed': speed,
      if (eta != null) 'eta': eta,
      if (category != null) 'category': category,
      if (status != null) 'status': status,
      if (savePath != null) 'save_path': savePath,
      if (localFilePath != null) 'local_file_path': localFilePath,
      if (tempFilePath != null) 'temp_file_path': tempFilePath,
      if (errorMessage != null) 'error_message': errorMessage,
      if (threadCount != null) 'thread_count': threadCount,
      if (chunks != null) 'chunks': chunks,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (completedAt != null) 'completed_at': completedAt,
      if (scheduledAt != null) 'scheduled_at': scheduledAt,
      if (supportsResume != null) 'supports_resume': supportsResume,
      if (speedLimitKbps != null) 'speed_limit_kbps': speedLimitKbps,
      if (seedingEnabled != null) 'seeding_enabled': seedingEnabled,
      if (seedingLimited != null) 'seeding_limited': seedingLimited,
      if (seedingLimitKbps != null) 'seeding_limit_kbps': seedingLimitKbps,
      if (torrentFiles != null) 'torrent_files': torrentFiles,
      if (downloadPageUrl != null) 'download_page_url': downloadPageUrl,
      if (mergedAudioUrl != null) 'merged_audio_url': mergedAudioUrl,
      if (audioSize != null) 'audio_size': audioSize,
      if (audioDownloadedBytes != null)
        'audio_downloaded_bytes': audioDownloadedBytes,
      if (videoStreamSize != null) 'video_stream_size': videoStreamSize,
      if (audioProgress != null) 'audio_progress': audioProgress,
      if (pausedByUser != null) 'paused_by_user': pausedByUser,
      if (youtubeQualityPreset != null)
        'youtube_quality_preset': youtubeQualityPreset,
      if (notes != null) 'notes': notes,
      if (playlistId != null) 'playlist_id': playlistId,
      if (playlistTitle != null) 'playlist_title': playlistTitle,
      if (thumbnailUrl != null) 'thumbnail_url': thumbnailUrl,
      if (isAppUpdate != null) 'is_app_update': isAppUpdate,
      if (uploadedBytes != null) 'uploaded_bytes': uploadedBytes,
      if (priority != null) 'priority': priority,
      if (queueOrder != null) 'queue_order': queueOrder,
      if (expectedSha256 != null) 'expected_sha256': expectedSha256,
      if (mirrorUrls != null) 'mirror_urls': mirrorUrls,
      if (pauseReason != null) 'pause_reason': pauseReason,
      if (totalPieces != null) 'total_pieces': totalPieces,
      if (completedPieces != null) 'completed_pieces': completedPieces,
      if (ytCounterpartDownloadedBytes != null)
        'yt_counterpart_downloaded_bytes': ytCounterpartDownloadedBytes,
      if (cycleState != null) 'cycle_state': cycleState,
      if (audioChunks != null) 'audio_chunks': audioChunks,
      if (httpParts != null) 'http_parts': httpParts,
      if (torrentPieceProgress != null)
        'torrent_piece_progress': torrentPieceProgress,
      if (audioChunksCompleted != null)
        'audio_chunks_completed': audioChunksCompleted,
      if (audioChunksTotal != null) 'audio_chunks_total': audioChunksTotal,
      if (httpPartsCompleted != null)
        'http_parts_completed': httpPartsCompleted,
      if (httpPartsTotal != null) 'http_parts_total': httpPartsTotal,
      if (previousCycleState != null)
        'previous_cycle_state': previousCycleState,
      if (infoHash != null) 'info_hash': infoHash,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadTasksCompanion copyWith(
      {Value<String>? id,
      Value<String>? fileName,
      Value<String>? url,
      Value<int>? fileSize,
      Value<int>? downloadedBytes,
      Value<double>? speed,
      Value<int?>? eta,
      Value<String>? category,
      Value<String>? status,
      Value<String>? savePath,
      Value<String>? localFilePath,
      Value<String>? tempFilePath,
      Value<String?>? errorMessage,
      Value<int>? threadCount,
      Value<List<double>?>? chunks,
      Value<int>? createdAt,
      Value<int>? updatedAt,
      Value<int?>? completedAt,
      Value<int?>? scheduledAt,
      Value<bool>? supportsResume,
      Value<int>? speedLimitKbps,
      Value<bool>? seedingEnabled,
      Value<bool>? seedingLimited,
      Value<int>? seedingLimitKbps,
      Value<List<Map<String, dynamic>>?>? torrentFiles,
      Value<String?>? downloadPageUrl,
      Value<String?>? mergedAudioUrl,
      Value<int>? audioSize,
      Value<int>? audioDownloadedBytes,
      Value<int>? videoStreamSize,
      Value<double>? audioProgress,
      Value<bool>? pausedByUser,
      Value<String?>? youtubeQualityPreset,
      Value<String?>? notes,
      Value<String?>? playlistId,
      Value<String?>? playlistTitle,
      Value<String?>? thumbnailUrl,
      Value<bool>? isAppUpdate,
      Value<int>? uploadedBytes,
      Value<int>? priority,
      Value<int>? queueOrder,
      Value<String?>? expectedSha256,
      Value<List<String>?>? mirrorUrls,
      Value<String?>? pauseReason,
      Value<int?>? totalPieces,
      Value<int?>? completedPieces,
      Value<int?>? ytCounterpartDownloadedBytes,
      Value<String?>? cycleState,
      Value<List<double>?>? audioChunks,
      Value<String?>? httpParts,
      Value<double?>? torrentPieceProgress,
      Value<int?>? audioChunksCompleted,
      Value<int?>? audioChunksTotal,
      Value<int?>? httpPartsCompleted,
      Value<int?>? httpPartsTotal,
      Value<String?>? previousCycleState,
      Value<String?>? infoHash,
      Value<int>? rowid}) {
    return DownloadTasksCompanion(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      url: url ?? this.url,
      fileSize: fileSize ?? this.fileSize,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      speed: speed ?? this.speed,
      eta: eta ?? this.eta,
      category: category ?? this.category,
      status: status ?? this.status,
      savePath: savePath ?? this.savePath,
      localFilePath: localFilePath ?? this.localFilePath,
      tempFilePath: tempFilePath ?? this.tempFilePath,
      errorMessage: errorMessage ?? this.errorMessage,
      threadCount: threadCount ?? this.threadCount,
      chunks: chunks ?? this.chunks,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedAt: completedAt ?? this.completedAt,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      supportsResume: supportsResume ?? this.supportsResume,
      speedLimitKbps: speedLimitKbps ?? this.speedLimitKbps,
      seedingEnabled: seedingEnabled ?? this.seedingEnabled,
      seedingLimited: seedingLimited ?? this.seedingLimited,
      seedingLimitKbps: seedingLimitKbps ?? this.seedingLimitKbps,
      torrentFiles: torrentFiles ?? this.torrentFiles,
      downloadPageUrl: downloadPageUrl ?? this.downloadPageUrl,
      mergedAudioUrl: mergedAudioUrl ?? this.mergedAudioUrl,
      audioSize: audioSize ?? this.audioSize,
      audioDownloadedBytes: audioDownloadedBytes ?? this.audioDownloadedBytes,
      videoStreamSize: videoStreamSize ?? this.videoStreamSize,
      audioProgress: audioProgress ?? this.audioProgress,
      pausedByUser: pausedByUser ?? this.pausedByUser,
      youtubeQualityPreset: youtubeQualityPreset ?? this.youtubeQualityPreset,
      notes: notes ?? this.notes,
      playlistId: playlistId ?? this.playlistId,
      playlistTitle: playlistTitle ?? this.playlistTitle,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      isAppUpdate: isAppUpdate ?? this.isAppUpdate,
      uploadedBytes: uploadedBytes ?? this.uploadedBytes,
      priority: priority ?? this.priority,
      queueOrder: queueOrder ?? this.queueOrder,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      mirrorUrls: mirrorUrls ?? this.mirrorUrls,
      pauseReason: pauseReason ?? this.pauseReason,
      totalPieces: totalPieces ?? this.totalPieces,
      completedPieces: completedPieces ?? this.completedPieces,
      ytCounterpartDownloadedBytes:
          ytCounterpartDownloadedBytes ?? this.ytCounterpartDownloadedBytes,
      cycleState: cycleState ?? this.cycleState,
      audioChunks: audioChunks ?? this.audioChunks,
      httpParts: httpParts ?? this.httpParts,
      torrentPieceProgress: torrentPieceProgress ?? this.torrentPieceProgress,
      audioChunksCompleted: audioChunksCompleted ?? this.audioChunksCompleted,
      audioChunksTotal: audioChunksTotal ?? this.audioChunksTotal,
      httpPartsCompleted: httpPartsCompleted ?? this.httpPartsCompleted,
      httpPartsTotal: httpPartsTotal ?? this.httpPartsTotal,
      previousCycleState: previousCycleState ?? this.previousCycleState,
      infoHash: infoHash ?? this.infoHash,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (fileSize.present) {
      map['file_size'] = Variable<int>(fileSize.value);
    }
    if (downloadedBytes.present) {
      map['downloaded_bytes'] = Variable<int>(downloadedBytes.value);
    }
    if (speed.present) {
      map['speed'] = Variable<double>(speed.value);
    }
    if (eta.present) {
      map['eta'] = Variable<int>(eta.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (savePath.present) {
      map['save_path'] = Variable<String>(savePath.value);
    }
    if (localFilePath.present) {
      map['local_file_path'] = Variable<String>(localFilePath.value);
    }
    if (tempFilePath.present) {
      map['temp_file_path'] = Variable<String>(tempFilePath.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (threadCount.present) {
      map['thread_count'] = Variable<int>(threadCount.value);
    }
    if (chunks.present) {
      map['chunks'] = Variable<String>(
          $DownloadTasksTable.$converterchunks.toSql(chunks.value));
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<int>(completedAt.value);
    }
    if (scheduledAt.present) {
      map['scheduled_at'] = Variable<int>(scheduledAt.value);
    }
    if (supportsResume.present) {
      map['supports_resume'] = Variable<bool>(supportsResume.value);
    }
    if (speedLimitKbps.present) {
      map['speed_limit_kbps'] = Variable<int>(speedLimitKbps.value);
    }
    if (seedingEnabled.present) {
      map['seeding_enabled'] = Variable<bool>(seedingEnabled.value);
    }
    if (seedingLimited.present) {
      map['seeding_limited'] = Variable<bool>(seedingLimited.value);
    }
    if (seedingLimitKbps.present) {
      map['seeding_limit_kbps'] = Variable<int>(seedingLimitKbps.value);
    }
    if (torrentFiles.present) {
      map['torrent_files'] = Variable<String>(
          $DownloadTasksTable.$convertertorrentFiles.toSql(torrentFiles.value));
    }
    if (downloadPageUrl.present) {
      map['download_page_url'] = Variable<String>(downloadPageUrl.value);
    }
    if (mergedAudioUrl.present) {
      map['merged_audio_url'] = Variable<String>(mergedAudioUrl.value);
    }
    if (audioSize.present) {
      map['audio_size'] = Variable<int>(audioSize.value);
    }
    if (audioDownloadedBytes.present) {
      map['audio_downloaded_bytes'] = Variable<int>(audioDownloadedBytes.value);
    }
    if (videoStreamSize.present) {
      map['video_stream_size'] = Variable<int>(videoStreamSize.value);
    }
    if (audioProgress.present) {
      map['audio_progress'] = Variable<double>(audioProgress.value);
    }
    if (pausedByUser.present) {
      map['paused_by_user'] = Variable<bool>(pausedByUser.value);
    }
    if (youtubeQualityPreset.present) {
      map['youtube_quality_preset'] =
          Variable<String>(youtubeQualityPreset.value);
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
    }
    if (playlistId.present) {
      map['playlist_id'] = Variable<String>(playlistId.value);
    }
    if (playlistTitle.present) {
      map['playlist_title'] = Variable<String>(playlistTitle.value);
    }
    if (thumbnailUrl.present) {
      map['thumbnail_url'] = Variable<String>(thumbnailUrl.value);
    }
    if (isAppUpdate.present) {
      map['is_app_update'] = Variable<bool>(isAppUpdate.value);
    }
    if (uploadedBytes.present) {
      map['uploaded_bytes'] = Variable<int>(uploadedBytes.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    if (queueOrder.present) {
      map['queue_order'] = Variable<int>(queueOrder.value);
    }
    if (expectedSha256.present) {
      map['expected_sha256'] = Variable<String>(expectedSha256.value);
    }
    if (mirrorUrls.present) {
      map['mirror_urls'] = Variable<String>(
          $DownloadTasksTable.$convertermirrorUrls.toSql(mirrorUrls.value));
    }
    if (pauseReason.present) {
      map['pause_reason'] = Variable<String>(pauseReason.value);
    }
    if (totalPieces.present) {
      map['total_pieces'] = Variable<int>(totalPieces.value);
    }
    if (completedPieces.present) {
      map['completed_pieces'] = Variable<int>(completedPieces.value);
    }
    if (ytCounterpartDownloadedBytes.present) {
      map['yt_counterpart_downloaded_bytes'] =
          Variable<int>(ytCounterpartDownloadedBytes.value);
    }
    if (cycleState.present) {
      map['cycle_state'] = Variable<String>(cycleState.value);
    }
    if (audioChunks.present) {
      map['audio_chunks'] = Variable<String>(
          $DownloadTasksTable.$converteraudioChunks.toSql(audioChunks.value));
    }
    if (httpParts.present) {
      map['http_parts'] = Variable<String>(httpParts.value);
    }
    if (torrentPieceProgress.present) {
      map['torrent_piece_progress'] =
          Variable<double>(torrentPieceProgress.value);
    }
    if (audioChunksCompleted.present) {
      map['audio_chunks_completed'] = Variable<int>(audioChunksCompleted.value);
    }
    if (audioChunksTotal.present) {
      map['audio_chunks_total'] = Variable<int>(audioChunksTotal.value);
    }
    if (httpPartsCompleted.present) {
      map['http_parts_completed'] = Variable<int>(httpPartsCompleted.value);
    }
    if (httpPartsTotal.present) {
      map['http_parts_total'] = Variable<int>(httpPartsTotal.value);
    }
    if (previousCycleState.present) {
      map['previous_cycle_state'] = Variable<String>(previousCycleState.value);
    }
    if (infoHash.present) {
      map['info_hash'] = Variable<String>(infoHash.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadTasksCompanion(')
          ..write('id: $id, ')
          ..write('fileName: $fileName, ')
          ..write('url: $url, ')
          ..write('fileSize: $fileSize, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('speed: $speed, ')
          ..write('eta: $eta, ')
          ..write('category: $category, ')
          ..write('status: $status, ')
          ..write('savePath: $savePath, ')
          ..write('localFilePath: $localFilePath, ')
          ..write('tempFilePath: $tempFilePath, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('threadCount: $threadCount, ')
          ..write('chunks: $chunks, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('completedAt: $completedAt, ')
          ..write('scheduledAt: $scheduledAt, ')
          ..write('supportsResume: $supportsResume, ')
          ..write('speedLimitKbps: $speedLimitKbps, ')
          ..write('seedingEnabled: $seedingEnabled, ')
          ..write('seedingLimited: $seedingLimited, ')
          ..write('seedingLimitKbps: $seedingLimitKbps, ')
          ..write('torrentFiles: $torrentFiles, ')
          ..write('downloadPageUrl: $downloadPageUrl, ')
          ..write('mergedAudioUrl: $mergedAudioUrl, ')
          ..write('audioSize: $audioSize, ')
          ..write('audioDownloadedBytes: $audioDownloadedBytes, ')
          ..write('videoStreamSize: $videoStreamSize, ')
          ..write('audioProgress: $audioProgress, ')
          ..write('pausedByUser: $pausedByUser, ')
          ..write('youtubeQualityPreset: $youtubeQualityPreset, ')
          ..write('notes: $notes, ')
          ..write('playlistId: $playlistId, ')
          ..write('playlistTitle: $playlistTitle, ')
          ..write('thumbnailUrl: $thumbnailUrl, ')
          ..write('isAppUpdate: $isAppUpdate, ')
          ..write('uploadedBytes: $uploadedBytes, ')
          ..write('priority: $priority, ')
          ..write('queueOrder: $queueOrder, ')
          ..write('expectedSha256: $expectedSha256, ')
          ..write('mirrorUrls: $mirrorUrls, ')
          ..write('pauseReason: $pauseReason, ')
          ..write('totalPieces: $totalPieces, ')
          ..write('completedPieces: $completedPieces, ')
          ..write(
              'ytCounterpartDownloadedBytes: $ytCounterpartDownloadedBytes, ')
          ..write('cycleState: $cycleState, ')
          ..write('audioChunks: $audioChunks, ')
          ..write('httpParts: $httpParts, ')
          ..write('torrentPieceProgress: $torrentPieceProgress, ')
          ..write('audioChunksCompleted: $audioChunksCompleted, ')
          ..write('audioChunksTotal: $audioChunksTotal, ')
          ..write('httpPartsCompleted: $httpPartsCompleted, ')
          ..write('httpPartsTotal: $httpPartsTotal, ')
          ..write('previousCycleState: $previousCycleState, ')
          ..write('infoHash: $infoHash, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BookmarksTable extends Bookmarks
    with TableInfo<$BookmarksTable, DbBookmark> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookmarksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
      'url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _folderMeta = const VerificationMeta('folder');
  @override
  late final GeneratedColumn<String> folder = GeneratedColumn<String>(
      'folder', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, title, url, folder, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bookmarks';
  @override
  VerificationContext validateIntegrity(Insertable<DbBookmark> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
          _urlMeta, url.isAcceptableOrUnknown(data['url']!, _urlMeta));
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('folder')) {
      context.handle(_folderMeta,
          folder.isAcceptableOrUnknown(data['folder']!, _folderMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbBookmark map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbBookmark(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      url: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}url'])!,
      folder: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}folder']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $BookmarksTable createAlias(String alias) {
    return $BookmarksTable(attachedDatabase, alias);
  }
}

class DbBookmark extends DataClass implements Insertable<DbBookmark> {
  final String id;
  final String title;
  final String url;
  final String? folder;
  final int createdAt;
  const DbBookmark(
      {required this.id,
      required this.title,
      required this.url,
      this.folder,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['url'] = Variable<String>(url);
    if (!nullToAbsent || folder != null) {
      map['folder'] = Variable<String>(folder);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  BookmarksCompanion toCompanion(bool nullToAbsent) {
    return BookmarksCompanion(
      id: Value(id),
      title: Value(title),
      url: Value(url),
      folder:
          folder == null && nullToAbsent ? const Value.absent() : Value(folder),
      createdAt: Value(createdAt),
    );
  }

  factory DbBookmark.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbBookmark(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      url: serializer.fromJson<String>(json['url']),
      folder: serializer.fromJson<String?>(json['folder']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'url': serializer.toJson<String>(url),
      'folder': serializer.toJson<String?>(folder),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  DbBookmark copyWith(
          {String? id,
          String? title,
          String? url,
          Value<String?> folder = const Value.absent(),
          int? createdAt}) =>
      DbBookmark(
        id: id ?? this.id,
        title: title ?? this.title,
        url: url ?? this.url,
        folder: folder.present ? folder.value : this.folder,
        createdAt: createdAt ?? this.createdAt,
      );
  DbBookmark copyWithCompanion(BookmarksCompanion data) {
    return DbBookmark(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      url: data.url.present ? data.url.value : this.url,
      folder: data.folder.present ? data.folder.value : this.folder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbBookmark(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('url: $url, ')
          ..write('folder: $folder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, url, folder, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbBookmark &&
          other.id == this.id &&
          other.title == this.title &&
          other.url == this.url &&
          other.folder == this.folder &&
          other.createdAt == this.createdAt);
}

class BookmarksCompanion extends UpdateCompanion<DbBookmark> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> url;
  final Value<String?> folder;
  final Value<int> createdAt;
  final Value<int> rowid;
  const BookmarksCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.url = const Value.absent(),
    this.folder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BookmarksCompanion.insert({
    required String id,
    required String title,
    required String url,
    this.folder = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        title = Value(title),
        url = Value(url),
        createdAt = Value(createdAt);
  static Insertable<DbBookmark> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? url,
    Expression<String>? folder,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (url != null) 'url': url,
      if (folder != null) 'folder': folder,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BookmarksCompanion copyWith(
      {Value<String>? id,
      Value<String>? title,
      Value<String>? url,
      Value<String?>? folder,
      Value<int>? createdAt,
      Value<int>? rowid}) {
    return BookmarksCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      url: url ?? this.url,
      folder: folder ?? this.folder,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (folder.present) {
      map['folder'] = Variable<String>(folder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookmarksCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('url: $url, ')
          ..write('folder: $folder, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BrowserHistoryTable extends BrowserHistory
    with TableInfo<$BrowserHistoryTable, DbBrowserHistory> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BrowserHistoryTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
      'url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _visitedAtMeta =
      const VerificationMeta('visitedAt');
  @override
  late final GeneratedColumn<int> visitedAt = GeneratedColumn<int>(
      'visited_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _visitCountMeta =
      const VerificationMeta('visitCount');
  @override
  late final GeneratedColumn<int> visitCount = GeneratedColumn<int>(
      'visit_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(1));
  static const VerificationMeta _faviconUrlMeta =
      const VerificationMeta('faviconUrl');
  @override
  late final GeneratedColumn<String> faviconUrl = GeneratedColumn<String>(
      'favicon_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, url, title, visitedAt, visitCount, faviconUrl];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'browser_history';
  @override
  VerificationContext validateIntegrity(Insertable<DbBrowserHistory> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('url')) {
      context.handle(
          _urlMeta, url.isAcceptableOrUnknown(data['url']!, _urlMeta));
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('visited_at')) {
      context.handle(_visitedAtMeta,
          visitedAt.isAcceptableOrUnknown(data['visited_at']!, _visitedAtMeta));
    } else if (isInserting) {
      context.missing(_visitedAtMeta);
    }
    if (data.containsKey('visit_count')) {
      context.handle(
          _visitCountMeta,
          visitCount.isAcceptableOrUnknown(
              data['visit_count']!, _visitCountMeta));
    }
    if (data.containsKey('favicon_url')) {
      context.handle(
          _faviconUrlMeta,
          faviconUrl.isAcceptableOrUnknown(
              data['favicon_url']!, _faviconUrlMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbBrowserHistory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbBrowserHistory(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      url: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}url'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      visitedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}visited_at'])!,
      visitCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}visit_count'])!,
      faviconUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}favicon_url']),
    );
  }

  @override
  $BrowserHistoryTable createAlias(String alias) {
    return $BrowserHistoryTable(attachedDatabase, alias);
  }
}

class DbBrowserHistory extends DataClass
    implements Insertable<DbBrowserHistory> {
  final int id;
  final String url;
  final String title;
  final int visitedAt;
  final int visitCount;
  final String? faviconUrl;
  const DbBrowserHistory(
      {required this.id,
      required this.url,
      required this.title,
      required this.visitedAt,
      required this.visitCount,
      this.faviconUrl});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['url'] = Variable<String>(url);
    map['title'] = Variable<String>(title);
    map['visited_at'] = Variable<int>(visitedAt);
    map['visit_count'] = Variable<int>(visitCount);
    if (!nullToAbsent || faviconUrl != null) {
      map['favicon_url'] = Variable<String>(faviconUrl);
    }
    return map;
  }

  BrowserHistoryCompanion toCompanion(bool nullToAbsent) {
    return BrowserHistoryCompanion(
      id: Value(id),
      url: Value(url),
      title: Value(title),
      visitedAt: Value(visitedAt),
      visitCount: Value(visitCount),
      faviconUrl: faviconUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(faviconUrl),
    );
  }

  factory DbBrowserHistory.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbBrowserHistory(
      id: serializer.fromJson<int>(json['id']),
      url: serializer.fromJson<String>(json['url']),
      title: serializer.fromJson<String>(json['title']),
      visitedAt: serializer.fromJson<int>(json['visitedAt']),
      visitCount: serializer.fromJson<int>(json['visitCount']),
      faviconUrl: serializer.fromJson<String?>(json['faviconUrl']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'url': serializer.toJson<String>(url),
      'title': serializer.toJson<String>(title),
      'visitedAt': serializer.toJson<int>(visitedAt),
      'visitCount': serializer.toJson<int>(visitCount),
      'faviconUrl': serializer.toJson<String?>(faviconUrl),
    };
  }

  DbBrowserHistory copyWith(
          {int? id,
          String? url,
          String? title,
          int? visitedAt,
          int? visitCount,
          Value<String?> faviconUrl = const Value.absent()}) =>
      DbBrowserHistory(
        id: id ?? this.id,
        url: url ?? this.url,
        title: title ?? this.title,
        visitedAt: visitedAt ?? this.visitedAt,
        visitCount: visitCount ?? this.visitCount,
        faviconUrl: faviconUrl.present ? faviconUrl.value : this.faviconUrl,
      );
  DbBrowserHistory copyWithCompanion(BrowserHistoryCompanion data) {
    return DbBrowserHistory(
      id: data.id.present ? data.id.value : this.id,
      url: data.url.present ? data.url.value : this.url,
      title: data.title.present ? data.title.value : this.title,
      visitedAt: data.visitedAt.present ? data.visitedAt.value : this.visitedAt,
      visitCount:
          data.visitCount.present ? data.visitCount.value : this.visitCount,
      faviconUrl:
          data.faviconUrl.present ? data.faviconUrl.value : this.faviconUrl,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbBrowserHistory(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('title: $title, ')
          ..write('visitedAt: $visitedAt, ')
          ..write('visitCount: $visitCount, ')
          ..write('faviconUrl: $faviconUrl')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, url, title, visitedAt, visitCount, faviconUrl);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbBrowserHistory &&
          other.id == this.id &&
          other.url == this.url &&
          other.title == this.title &&
          other.visitedAt == this.visitedAt &&
          other.visitCount == this.visitCount &&
          other.faviconUrl == this.faviconUrl);
}

class BrowserHistoryCompanion extends UpdateCompanion<DbBrowserHistory> {
  final Value<int> id;
  final Value<String> url;
  final Value<String> title;
  final Value<int> visitedAt;
  final Value<int> visitCount;
  final Value<String?> faviconUrl;
  const BrowserHistoryCompanion({
    this.id = const Value.absent(),
    this.url = const Value.absent(),
    this.title = const Value.absent(),
    this.visitedAt = const Value.absent(),
    this.visitCount = const Value.absent(),
    this.faviconUrl = const Value.absent(),
  });
  BrowserHistoryCompanion.insert({
    this.id = const Value.absent(),
    required String url,
    required String title,
    required int visitedAt,
    this.visitCount = const Value.absent(),
    this.faviconUrl = const Value.absent(),
  })  : url = Value(url),
        title = Value(title),
        visitedAt = Value(visitedAt);
  static Insertable<DbBrowserHistory> custom({
    Expression<int>? id,
    Expression<String>? url,
    Expression<String>? title,
    Expression<int>? visitedAt,
    Expression<int>? visitCount,
    Expression<String>? faviconUrl,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (url != null) 'url': url,
      if (title != null) 'title': title,
      if (visitedAt != null) 'visited_at': visitedAt,
      if (visitCount != null) 'visit_count': visitCount,
      if (faviconUrl != null) 'favicon_url': faviconUrl,
    });
  }

  BrowserHistoryCompanion copyWith(
      {Value<int>? id,
      Value<String>? url,
      Value<String>? title,
      Value<int>? visitedAt,
      Value<int>? visitCount,
      Value<String?>? faviconUrl}) {
    return BrowserHistoryCompanion(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      visitedAt: visitedAt ?? this.visitedAt,
      visitCount: visitCount ?? this.visitCount,
      faviconUrl: faviconUrl ?? this.faviconUrl,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (visitedAt.present) {
      map['visited_at'] = Variable<int>(visitedAt.value);
    }
    if (visitCount.present) {
      map['visit_count'] = Variable<int>(visitCount.value);
    }
    if (faviconUrl.present) {
      map['favicon_url'] = Variable<String>(faviconUrl.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BrowserHistoryCompanion(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('title: $title, ')
          ..write('visitedAt: $visitedAt, ')
          ..write('visitCount: $visitCount, ')
          ..write('faviconUrl: $faviconUrl')
          ..write(')'))
        .toString();
  }
}

class $BrowserTabsTable extends BrowserTabs
    with TableInfo<$BrowserTabsTable, SavedBrowserTab> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BrowserTabsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
      'url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _isActiveMeta =
      const VerificationMeta('isActive');
  @override
  late final GeneratedColumn<bool> isActive = GeneratedColumn<bool>(
      'is_active', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_active" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _positionMeta =
      const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
      'position', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _lastVisitedAtMeta =
      const VerificationMeta('lastVisitedAt');
  @override
  late final GeneratedColumn<int> lastVisitedAt = GeneratedColumn<int>(
      'last_visited_at', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _faviconUrlMeta =
      const VerificationMeta('faviconUrl');
  @override
  late final GeneratedColumn<String> faviconUrl = GeneratedColumn<String>(
      'favicon_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        url,
        title,
        isActive,
        position,
        createdAt,
        lastVisitedAt,
        faviconUrl
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'browser_tabs';
  @override
  VerificationContext validateIntegrity(Insertable<SavedBrowserTab> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
          _urlMeta, url.isAcceptableOrUnknown(data['url']!, _urlMeta));
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    }
    if (data.containsKey('is_active')) {
      context.handle(_isActiveMeta,
          isActive.isAcceptableOrUnknown(data['is_active']!, _isActiveMeta));
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta,
          position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_visited_at')) {
      context.handle(
          _lastVisitedAtMeta,
          lastVisitedAt.isAcceptableOrUnknown(
              data['last_visited_at']!, _lastVisitedAtMeta));
    }
    if (data.containsKey('favicon_url')) {
      context.handle(
          _faviconUrlMeta,
          faviconUrl.isAcceptableOrUnknown(
              data['favicon_url']!, _faviconUrlMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SavedBrowserTab map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SavedBrowserTab(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      url: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}url'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      isActive: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_active'])!,
      position: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}position'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
      lastVisitedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_visited_at'])!,
      faviconUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}favicon_url']),
    );
  }

  @override
  $BrowserTabsTable createAlias(String alias) {
    return $BrowserTabsTable(attachedDatabase, alias);
  }
}

class SavedBrowserTab extends DataClass implements Insertable<SavedBrowserTab> {
  final String id;
  final String url;
  final String title;
  final bool isActive;
  final int position;
  final int createdAt;
  final int lastVisitedAt;
  final String? faviconUrl;
  const SavedBrowserTab(
      {required this.id,
      required this.url,
      required this.title,
      required this.isActive,
      required this.position,
      required this.createdAt,
      required this.lastVisitedAt,
      this.faviconUrl});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['url'] = Variable<String>(url);
    map['title'] = Variable<String>(title);
    map['is_active'] = Variable<bool>(isActive);
    map['position'] = Variable<int>(position);
    map['created_at'] = Variable<int>(createdAt);
    map['last_visited_at'] = Variable<int>(lastVisitedAt);
    if (!nullToAbsent || faviconUrl != null) {
      map['favicon_url'] = Variable<String>(faviconUrl);
    }
    return map;
  }

  BrowserTabsCompanion toCompanion(bool nullToAbsent) {
    return BrowserTabsCompanion(
      id: Value(id),
      url: Value(url),
      title: Value(title),
      isActive: Value(isActive),
      position: Value(position),
      createdAt: Value(createdAt),
      lastVisitedAt: Value(lastVisitedAt),
      faviconUrl: faviconUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(faviconUrl),
    );
  }

  factory SavedBrowserTab.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SavedBrowserTab(
      id: serializer.fromJson<String>(json['id']),
      url: serializer.fromJson<String>(json['url']),
      title: serializer.fromJson<String>(json['title']),
      isActive: serializer.fromJson<bool>(json['isActive']),
      position: serializer.fromJson<int>(json['position']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastVisitedAt: serializer.fromJson<int>(json['lastVisitedAt']),
      faviconUrl: serializer.fromJson<String?>(json['faviconUrl']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'url': serializer.toJson<String>(url),
      'title': serializer.toJson<String>(title),
      'isActive': serializer.toJson<bool>(isActive),
      'position': serializer.toJson<int>(position),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastVisitedAt': serializer.toJson<int>(lastVisitedAt),
      'faviconUrl': serializer.toJson<String?>(faviconUrl),
    };
  }

  SavedBrowserTab copyWith(
          {String? id,
          String? url,
          String? title,
          bool? isActive,
          int? position,
          int? createdAt,
          int? lastVisitedAt,
          Value<String?> faviconUrl = const Value.absent()}) =>
      SavedBrowserTab(
        id: id ?? this.id,
        url: url ?? this.url,
        title: title ?? this.title,
        isActive: isActive ?? this.isActive,
        position: position ?? this.position,
        createdAt: createdAt ?? this.createdAt,
        lastVisitedAt: lastVisitedAt ?? this.lastVisitedAt,
        faviconUrl: faviconUrl.present ? faviconUrl.value : this.faviconUrl,
      );
  SavedBrowserTab copyWithCompanion(BrowserTabsCompanion data) {
    return SavedBrowserTab(
      id: data.id.present ? data.id.value : this.id,
      url: data.url.present ? data.url.value : this.url,
      title: data.title.present ? data.title.value : this.title,
      isActive: data.isActive.present ? data.isActive.value : this.isActive,
      position: data.position.present ? data.position.value : this.position,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastVisitedAt: data.lastVisitedAt.present
          ? data.lastVisitedAt.value
          : this.lastVisitedAt,
      faviconUrl:
          data.faviconUrl.present ? data.faviconUrl.value : this.faviconUrl,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SavedBrowserTab(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('title: $title, ')
          ..write('isActive: $isActive, ')
          ..write('position: $position, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastVisitedAt: $lastVisitedAt, ')
          ..write('faviconUrl: $faviconUrl')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, url, title, isActive, position, createdAt, lastVisitedAt, faviconUrl);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SavedBrowserTab &&
          other.id == this.id &&
          other.url == this.url &&
          other.title == this.title &&
          other.isActive == this.isActive &&
          other.position == this.position &&
          other.createdAt == this.createdAt &&
          other.lastVisitedAt == this.lastVisitedAt &&
          other.faviconUrl == this.faviconUrl);
}

class BrowserTabsCompanion extends UpdateCompanion<SavedBrowserTab> {
  final Value<String> id;
  final Value<String> url;
  final Value<String> title;
  final Value<bool> isActive;
  final Value<int> position;
  final Value<int> createdAt;
  final Value<int> lastVisitedAt;
  final Value<String?> faviconUrl;
  final Value<int> rowid;
  const BrowserTabsCompanion({
    this.id = const Value.absent(),
    this.url = const Value.absent(),
    this.title = const Value.absent(),
    this.isActive = const Value.absent(),
    this.position = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastVisitedAt = const Value.absent(),
    this.faviconUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BrowserTabsCompanion.insert({
    required String id,
    required String url,
    this.title = const Value.absent(),
    this.isActive = const Value.absent(),
    this.position = const Value.absent(),
    required int createdAt,
    this.lastVisitedAt = const Value.absent(),
    this.faviconUrl = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        url = Value(url),
        createdAt = Value(createdAt);
  static Insertable<SavedBrowserTab> custom({
    Expression<String>? id,
    Expression<String>? url,
    Expression<String>? title,
    Expression<bool>? isActive,
    Expression<int>? position,
    Expression<int>? createdAt,
    Expression<int>? lastVisitedAt,
    Expression<String>? faviconUrl,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (url != null) 'url': url,
      if (title != null) 'title': title,
      if (isActive != null) 'is_active': isActive,
      if (position != null) 'position': position,
      if (createdAt != null) 'created_at': createdAt,
      if (lastVisitedAt != null) 'last_visited_at': lastVisitedAt,
      if (faviconUrl != null) 'favicon_url': faviconUrl,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BrowserTabsCompanion copyWith(
      {Value<String>? id,
      Value<String>? url,
      Value<String>? title,
      Value<bool>? isActive,
      Value<int>? position,
      Value<int>? createdAt,
      Value<int>? lastVisitedAt,
      Value<String?>? faviconUrl,
      Value<int>? rowid}) {
    return BrowserTabsCompanion(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      isActive: isActive ?? this.isActive,
      position: position ?? this.position,
      createdAt: createdAt ?? this.createdAt,
      lastVisitedAt: lastVisitedAt ?? this.lastVisitedAt,
      faviconUrl: faviconUrl ?? this.faviconUrl,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (isActive.present) {
      map['is_active'] = Variable<bool>(isActive.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastVisitedAt.present) {
      map['last_visited_at'] = Variable<int>(lastVisitedAt.value);
    }
    if (faviconUrl.present) {
      map['favicon_url'] = Variable<String>(faviconUrl.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BrowserTabsCompanion(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('title: $title, ')
          ..write('isActive: $isActive, ')
          ..write('position: $position, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastVisitedAt: $lastVisitedAt, ')
          ..write('faviconUrl: $faviconUrl, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MirrorHealthTable extends MirrorHealth
    with TableInfo<$MirrorHealthTable, DbMirrorHealth> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MirrorHealthTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
      'url', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _failuresMeta =
      const VerificationMeta('failures');
  @override
  late final GeneratedColumn<int> failures = GeneratedColumn<int>(
      'failures', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastFailureMeta =
      const VerificationMeta('lastFailure');
  @override
  late final GeneratedColumn<int> lastFailure = GeneratedColumn<int>(
      'last_failure', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastSuccessMeta =
      const VerificationMeta('lastSuccess');
  @override
  late final GeneratedColumn<int> lastSuccess = GeneratedColumn<int>(
      'last_success', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastStatusCodeMeta =
      const VerificationMeta('lastStatusCode');
  @override
  late final GeneratedColumn<int> lastStatusCode = GeneratedColumn<int>(
      'last_status_code', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _blacklistedUntilMeta =
      const VerificationMeta('blacklistedUntil');
  @override
  late final GeneratedColumn<int> blacklistedUntil = GeneratedColumn<int>(
      'blacklisted_until', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _averageSpeedBpsMeta =
      const VerificationMeta('averageSpeedBps');
  @override
  late final GeneratedColumn<double> averageSpeedBps = GeneratedColumn<double>(
      'average_speed_bps', aliasedName, false,
      type: DriftSqlType.double,
      requiredDuringInsert: false,
      defaultValue: const Constant(0.0));
  static const VerificationMeta _speedSamplesMeta =
      const VerificationMeta('speedSamples');
  @override
  late final GeneratedColumn<String> speedSamples = GeneratedColumn<String>(
      'speed_samples', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        url,
        failures,
        lastFailure,
        lastSuccess,
        lastStatusCode,
        blacklistedUntil,
        averageSpeedBps,
        speedSamples
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mirror_health';
  @override
  VerificationContext validateIntegrity(Insertable<DbMirrorHealth> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('url')) {
      context.handle(
          _urlMeta, url.isAcceptableOrUnknown(data['url']!, _urlMeta));
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('failures')) {
      context.handle(_failuresMeta,
          failures.isAcceptableOrUnknown(data['failures']!, _failuresMeta));
    }
    if (data.containsKey('last_failure')) {
      context.handle(
          _lastFailureMeta,
          lastFailure.isAcceptableOrUnknown(
              data['last_failure']!, _lastFailureMeta));
    }
    if (data.containsKey('last_success')) {
      context.handle(
          _lastSuccessMeta,
          lastSuccess.isAcceptableOrUnknown(
              data['last_success']!, _lastSuccessMeta));
    }
    if (data.containsKey('last_status_code')) {
      context.handle(
          _lastStatusCodeMeta,
          lastStatusCode.isAcceptableOrUnknown(
              data['last_status_code']!, _lastStatusCodeMeta));
    }
    if (data.containsKey('blacklisted_until')) {
      context.handle(
          _blacklistedUntilMeta,
          blacklistedUntil.isAcceptableOrUnknown(
              data['blacklisted_until']!, _blacklistedUntilMeta));
    }
    if (data.containsKey('average_speed_bps')) {
      context.handle(
          _averageSpeedBpsMeta,
          averageSpeedBps.isAcceptableOrUnknown(
              data['average_speed_bps']!, _averageSpeedBpsMeta));
    }
    if (data.containsKey('speed_samples')) {
      context.handle(
          _speedSamplesMeta,
          speedSamples.isAcceptableOrUnknown(
              data['speed_samples']!, _speedSamplesMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {url};
  @override
  DbMirrorHealth map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbMirrorHealth(
      url: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}url'])!,
      failures: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}failures'])!,
      lastFailure: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_failure'])!,
      lastSuccess: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_success'])!,
      lastStatusCode: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_status_code'])!,
      blacklistedUntil: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}blacklisted_until'])!,
      averageSpeedBps: attachedDatabase.typeMapping.read(
          DriftSqlType.double, data['${effectivePrefix}average_speed_bps'])!,
      speedSamples: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}speed_samples']),
    );
  }

  @override
  $MirrorHealthTable createAlias(String alias) {
    return $MirrorHealthTable(attachedDatabase, alias);
  }
}

class DbMirrorHealth extends DataClass implements Insertable<DbMirrorHealth> {
  final String url;
  final int failures;
  final int lastFailure;
  final int lastSuccess;
  final int lastStatusCode;
  final int blacklistedUntil;
  final double averageSpeedBps;
  final String? speedSamples;
  const DbMirrorHealth(
      {required this.url,
      required this.failures,
      required this.lastFailure,
      required this.lastSuccess,
      required this.lastStatusCode,
      required this.blacklistedUntil,
      required this.averageSpeedBps,
      this.speedSamples});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['url'] = Variable<String>(url);
    map['failures'] = Variable<int>(failures);
    map['last_failure'] = Variable<int>(lastFailure);
    map['last_success'] = Variable<int>(lastSuccess);
    map['last_status_code'] = Variable<int>(lastStatusCode);
    map['blacklisted_until'] = Variable<int>(blacklistedUntil);
    map['average_speed_bps'] = Variable<double>(averageSpeedBps);
    if (!nullToAbsent || speedSamples != null) {
      map['speed_samples'] = Variable<String>(speedSamples);
    }
    return map;
  }

  MirrorHealthCompanion toCompanion(bool nullToAbsent) {
    return MirrorHealthCompanion(
      url: Value(url),
      failures: Value(failures),
      lastFailure: Value(lastFailure),
      lastSuccess: Value(lastSuccess),
      lastStatusCode: Value(lastStatusCode),
      blacklistedUntil: Value(blacklistedUntil),
      averageSpeedBps: Value(averageSpeedBps),
      speedSamples: speedSamples == null && nullToAbsent
          ? const Value.absent()
          : Value(speedSamples),
    );
  }

  factory DbMirrorHealth.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbMirrorHealth(
      url: serializer.fromJson<String>(json['url']),
      failures: serializer.fromJson<int>(json['failures']),
      lastFailure: serializer.fromJson<int>(json['lastFailure']),
      lastSuccess: serializer.fromJson<int>(json['lastSuccess']),
      lastStatusCode: serializer.fromJson<int>(json['lastStatusCode']),
      blacklistedUntil: serializer.fromJson<int>(json['blacklistedUntil']),
      averageSpeedBps: serializer.fromJson<double>(json['averageSpeedBps']),
      speedSamples: serializer.fromJson<String?>(json['speedSamples']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'url': serializer.toJson<String>(url),
      'failures': serializer.toJson<int>(failures),
      'lastFailure': serializer.toJson<int>(lastFailure),
      'lastSuccess': serializer.toJson<int>(lastSuccess),
      'lastStatusCode': serializer.toJson<int>(lastStatusCode),
      'blacklistedUntil': serializer.toJson<int>(blacklistedUntil),
      'averageSpeedBps': serializer.toJson<double>(averageSpeedBps),
      'speedSamples': serializer.toJson<String?>(speedSamples),
    };
  }

  DbMirrorHealth copyWith(
          {String? url,
          int? failures,
          int? lastFailure,
          int? lastSuccess,
          int? lastStatusCode,
          int? blacklistedUntil,
          double? averageSpeedBps,
          Value<String?> speedSamples = const Value.absent()}) =>
      DbMirrorHealth(
        url: url ?? this.url,
        failures: failures ?? this.failures,
        lastFailure: lastFailure ?? this.lastFailure,
        lastSuccess: lastSuccess ?? this.lastSuccess,
        lastStatusCode: lastStatusCode ?? this.lastStatusCode,
        blacklistedUntil: blacklistedUntil ?? this.blacklistedUntil,
        averageSpeedBps: averageSpeedBps ?? this.averageSpeedBps,
        speedSamples:
            speedSamples.present ? speedSamples.value : this.speedSamples,
      );
  DbMirrorHealth copyWithCompanion(MirrorHealthCompanion data) {
    return DbMirrorHealth(
      url: data.url.present ? data.url.value : this.url,
      failures: data.failures.present ? data.failures.value : this.failures,
      lastFailure:
          data.lastFailure.present ? data.lastFailure.value : this.lastFailure,
      lastSuccess:
          data.lastSuccess.present ? data.lastSuccess.value : this.lastSuccess,
      lastStatusCode: data.lastStatusCode.present
          ? data.lastStatusCode.value
          : this.lastStatusCode,
      blacklistedUntil: data.blacklistedUntil.present
          ? data.blacklistedUntil.value
          : this.blacklistedUntil,
      averageSpeedBps: data.averageSpeedBps.present
          ? data.averageSpeedBps.value
          : this.averageSpeedBps,
      speedSamples: data.speedSamples.present
          ? data.speedSamples.value
          : this.speedSamples,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbMirrorHealth(')
          ..write('url: $url, ')
          ..write('failures: $failures, ')
          ..write('lastFailure: $lastFailure, ')
          ..write('lastSuccess: $lastSuccess, ')
          ..write('lastStatusCode: $lastStatusCode, ')
          ..write('blacklistedUntil: $blacklistedUntil, ')
          ..write('averageSpeedBps: $averageSpeedBps, ')
          ..write('speedSamples: $speedSamples')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(url, failures, lastFailure, lastSuccess,
      lastStatusCode, blacklistedUntil, averageSpeedBps, speedSamples);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbMirrorHealth &&
          other.url == this.url &&
          other.failures == this.failures &&
          other.lastFailure == this.lastFailure &&
          other.lastSuccess == this.lastSuccess &&
          other.lastStatusCode == this.lastStatusCode &&
          other.blacklistedUntil == this.blacklistedUntil &&
          other.averageSpeedBps == this.averageSpeedBps &&
          other.speedSamples == this.speedSamples);
}

class MirrorHealthCompanion extends UpdateCompanion<DbMirrorHealth> {
  final Value<String> url;
  final Value<int> failures;
  final Value<int> lastFailure;
  final Value<int> lastSuccess;
  final Value<int> lastStatusCode;
  final Value<int> blacklistedUntil;
  final Value<double> averageSpeedBps;
  final Value<String?> speedSamples;
  final Value<int> rowid;
  const MirrorHealthCompanion({
    this.url = const Value.absent(),
    this.failures = const Value.absent(),
    this.lastFailure = const Value.absent(),
    this.lastSuccess = const Value.absent(),
    this.lastStatusCode = const Value.absent(),
    this.blacklistedUntil = const Value.absent(),
    this.averageSpeedBps = const Value.absent(),
    this.speedSamples = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MirrorHealthCompanion.insert({
    required String url,
    this.failures = const Value.absent(),
    this.lastFailure = const Value.absent(),
    this.lastSuccess = const Value.absent(),
    this.lastStatusCode = const Value.absent(),
    this.blacklistedUntil = const Value.absent(),
    this.averageSpeedBps = const Value.absent(),
    this.speedSamples = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : url = Value(url);
  static Insertable<DbMirrorHealth> custom({
    Expression<String>? url,
    Expression<int>? failures,
    Expression<int>? lastFailure,
    Expression<int>? lastSuccess,
    Expression<int>? lastStatusCode,
    Expression<int>? blacklistedUntil,
    Expression<double>? averageSpeedBps,
    Expression<String>? speedSamples,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (url != null) 'url': url,
      if (failures != null) 'failures': failures,
      if (lastFailure != null) 'last_failure': lastFailure,
      if (lastSuccess != null) 'last_success': lastSuccess,
      if (lastStatusCode != null) 'last_status_code': lastStatusCode,
      if (blacklistedUntil != null) 'blacklisted_until': blacklistedUntil,
      if (averageSpeedBps != null) 'average_speed_bps': averageSpeedBps,
      if (speedSamples != null) 'speed_samples': speedSamples,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MirrorHealthCompanion copyWith(
      {Value<String>? url,
      Value<int>? failures,
      Value<int>? lastFailure,
      Value<int>? lastSuccess,
      Value<int>? lastStatusCode,
      Value<int>? blacklistedUntil,
      Value<double>? averageSpeedBps,
      Value<String?>? speedSamples,
      Value<int>? rowid}) {
    return MirrorHealthCompanion(
      url: url ?? this.url,
      failures: failures ?? this.failures,
      lastFailure: lastFailure ?? this.lastFailure,
      lastSuccess: lastSuccess ?? this.lastSuccess,
      lastStatusCode: lastStatusCode ?? this.lastStatusCode,
      blacklistedUntil: blacklistedUntil ?? this.blacklistedUntil,
      averageSpeedBps: averageSpeedBps ?? this.averageSpeedBps,
      speedSamples: speedSamples ?? this.speedSamples,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (failures.present) {
      map['failures'] = Variable<int>(failures.value);
    }
    if (lastFailure.present) {
      map['last_failure'] = Variable<int>(lastFailure.value);
    }
    if (lastSuccess.present) {
      map['last_success'] = Variable<int>(lastSuccess.value);
    }
    if (lastStatusCode.present) {
      map['last_status_code'] = Variable<int>(lastStatusCode.value);
    }
    if (blacklistedUntil.present) {
      map['blacklisted_until'] = Variable<int>(blacklistedUntil.value);
    }
    if (averageSpeedBps.present) {
      map['average_speed_bps'] = Variable<double>(averageSpeedBps.value);
    }
    if (speedSamples.present) {
      map['speed_samples'] = Variable<String>(speedSamples.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MirrorHealthCompanion(')
          ..write('url: $url, ')
          ..write('failures: $failures, ')
          ..write('lastFailure: $lastFailure, ')
          ..write('lastSuccess: $lastSuccess, ')
          ..write('lastStatusCode: $lastStatusCode, ')
          ..write('blacklistedUntil: $blacklistedUntil, ')
          ..write('averageSpeedBps: $averageSpeedBps, ')
          ..write('speedSamples: $speedSamples, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DownloadTasksTable downloadTasks = $DownloadTasksTable(this);
  late final $BookmarksTable bookmarks = $BookmarksTable(this);
  late final $BrowserHistoryTable browserHistory = $BrowserHistoryTable(this);
  late final $BrowserTabsTable browserTabs = $BrowserTabsTable(this);
  late final $MirrorHealthTable mirrorHealth = $MirrorHealthTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [downloadTasks, bookmarks, browserHistory, browserTabs, mirrorHealth];
}

typedef $$DownloadTasksTableCreateCompanionBuilder = DownloadTasksCompanion
    Function({
  required String id,
  required String fileName,
  required String url,
  Value<int> fileSize,
  Value<int> downloadedBytes,
  Value<double> speed,
  Value<int?> eta,
  required String category,
  required String status,
  required String savePath,
  required String localFilePath,
  required String tempFilePath,
  Value<String?> errorMessage,
  required int threadCount,
  Value<List<double>?> chunks,
  required int createdAt,
  required int updatedAt,
  Value<int?> completedAt,
  Value<int?> scheduledAt,
  Value<bool> supportsResume,
  Value<int> speedLimitKbps,
  Value<bool> seedingEnabled,
  Value<bool> seedingLimited,
  Value<int> seedingLimitKbps,
  Value<List<Map<String, dynamic>>?> torrentFiles,
  Value<String?> downloadPageUrl,
  Value<String?> mergedAudioUrl,
  Value<int> audioSize,
  Value<int> audioDownloadedBytes,
  Value<int> videoStreamSize,
  Value<double> audioProgress,
  Value<bool> pausedByUser,
  Value<String?> youtubeQualityPreset,
  Value<String?> notes,
  Value<String?> playlistId,
  Value<String?> playlistTitle,
  Value<String?> thumbnailUrl,
  Value<bool> isAppUpdate,
  Value<int> uploadedBytes,
  Value<int> priority,
  Value<int> queueOrder,
  Value<String?> expectedSha256,
  Value<List<String>?> mirrorUrls,
  Value<String?> pauseReason,
  Value<int?> totalPieces,
  Value<int?> completedPieces,
  Value<int?> ytCounterpartDownloadedBytes,
  Value<String?> cycleState,
  Value<List<double>?> audioChunks,
  Value<String?> httpParts,
  Value<double?> torrentPieceProgress,
  Value<int?> audioChunksCompleted,
  Value<int?> audioChunksTotal,
  Value<int?> httpPartsCompleted,
  Value<int?> httpPartsTotal,
  Value<String?> previousCycleState,
  Value<String?> infoHash,
  Value<int> rowid,
});
typedef $$DownloadTasksTableUpdateCompanionBuilder = DownloadTasksCompanion
    Function({
  Value<String> id,
  Value<String> fileName,
  Value<String> url,
  Value<int> fileSize,
  Value<int> downloadedBytes,
  Value<double> speed,
  Value<int?> eta,
  Value<String> category,
  Value<String> status,
  Value<String> savePath,
  Value<String> localFilePath,
  Value<String> tempFilePath,
  Value<String?> errorMessage,
  Value<int> threadCount,
  Value<List<double>?> chunks,
  Value<int> createdAt,
  Value<int> updatedAt,
  Value<int?> completedAt,
  Value<int?> scheduledAt,
  Value<bool> supportsResume,
  Value<int> speedLimitKbps,
  Value<bool> seedingEnabled,
  Value<bool> seedingLimited,
  Value<int> seedingLimitKbps,
  Value<List<Map<String, dynamic>>?> torrentFiles,
  Value<String?> downloadPageUrl,
  Value<String?> mergedAudioUrl,
  Value<int> audioSize,
  Value<int> audioDownloadedBytes,
  Value<int> videoStreamSize,
  Value<double> audioProgress,
  Value<bool> pausedByUser,
  Value<String?> youtubeQualityPreset,
  Value<String?> notes,
  Value<String?> playlistId,
  Value<String?> playlistTitle,
  Value<String?> thumbnailUrl,
  Value<bool> isAppUpdate,
  Value<int> uploadedBytes,
  Value<int> priority,
  Value<int> queueOrder,
  Value<String?> expectedSha256,
  Value<List<String>?> mirrorUrls,
  Value<String?> pauseReason,
  Value<int?> totalPieces,
  Value<int?> completedPieces,
  Value<int?> ytCounterpartDownloadedBytes,
  Value<String?> cycleState,
  Value<List<double>?> audioChunks,
  Value<String?> httpParts,
  Value<double?> torrentPieceProgress,
  Value<int?> audioChunksCompleted,
  Value<int?> audioChunksTotal,
  Value<int?> httpPartsCompleted,
  Value<int?> httpPartsTotal,
  Value<String?> previousCycleState,
  Value<String?> infoHash,
  Value<int> rowid,
});

class $$DownloadTasksTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadTasksTable> {
  $$DownloadTasksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fileName => $composableBuilder(
      column: $table.fileName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fileSize => $composableBuilder(
      column: $table.fileSize, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get downloadedBytes => $composableBuilder(
      column: $table.downloadedBytes,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get speed => $composableBuilder(
      column: $table.speed, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get eta => $composableBuilder(
      column: $table.eta, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get savePath => $composableBuilder(
      column: $table.savePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localFilePath => $composableBuilder(
      column: $table.localFilePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tempFilePath => $composableBuilder(
      column: $table.tempFilePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get threadCount => $composableBuilder(
      column: $table.threadCount, builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<List<double>?, List<double>, String>
      get chunks => $composableBuilder(
          column: $table.chunks,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get scheduledAt => $composableBuilder(
      column: $table.scheduledAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get supportsResume => $composableBuilder(
      column: $table.supportsResume,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get speedLimitKbps => $composableBuilder(
      column: $table.speedLimitKbps,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get seedingEnabled => $composableBuilder(
      column: $table.seedingEnabled,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get seedingLimited => $composableBuilder(
      column: $table.seedingLimited,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get seedingLimitKbps => $composableBuilder(
      column: $table.seedingLimitKbps,
      builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<List<Map<String, dynamic>>?,
          List<Map<String, dynamic>>, String>
      get torrentFiles => $composableBuilder(
          column: $table.torrentFiles,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<String> get downloadPageUrl => $composableBuilder(
      column: $table.downloadPageUrl,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mergedAudioUrl => $composableBuilder(
      column: $table.mergedAudioUrl,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get audioSize => $composableBuilder(
      column: $table.audioSize, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get audioDownloadedBytes => $composableBuilder(
      column: $table.audioDownloadedBytes,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get videoStreamSize => $composableBuilder(
      column: $table.videoStreamSize,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get audioProgress => $composableBuilder(
      column: $table.audioProgress, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get pausedByUser => $composableBuilder(
      column: $table.pausedByUser, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get youtubeQualityPreset => $composableBuilder(
      column: $table.youtubeQualityPreset,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get playlistId => $composableBuilder(
      column: $table.playlistId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get playlistTitle => $composableBuilder(
      column: $table.playlistTitle, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get thumbnailUrl => $composableBuilder(
      column: $table.thumbnailUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isAppUpdate => $composableBuilder(
      column: $table.isAppUpdate, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get uploadedBytes => $composableBuilder(
      column: $table.uploadedBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get priority => $composableBuilder(
      column: $table.priority, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get queueOrder => $composableBuilder(
      column: $table.queueOrder, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get expectedSha256 => $composableBuilder(
      column: $table.expectedSha256,
      builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<List<String>?, List<String>, String>
      get mirrorUrls => $composableBuilder(
          column: $table.mirrorUrls,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<String> get pauseReason => $composableBuilder(
      column: $table.pauseReason, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalPieces => $composableBuilder(
      column: $table.totalPieces, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get completedPieces => $composableBuilder(
      column: $table.completedPieces,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get ytCounterpartDownloadedBytes => $composableBuilder(
      column: $table.ytCounterpartDownloadedBytes,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get cycleState => $composableBuilder(
      column: $table.cycleState, builder: (column) => ColumnFilters(column));

  ColumnWithTypeConverterFilters<List<double>?, List<double>, String>
      get audioChunks => $composableBuilder(
          column: $table.audioChunks,
          builder: (column) => ColumnWithTypeConverterFilters(column));

  ColumnFilters<String> get httpParts => $composableBuilder(
      column: $table.httpParts, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get torrentPieceProgress => $composableBuilder(
      column: $table.torrentPieceProgress,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get audioChunksCompleted => $composableBuilder(
      column: $table.audioChunksCompleted,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get audioChunksTotal => $composableBuilder(
      column: $table.audioChunksTotal,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get httpPartsCompleted => $composableBuilder(
      column: $table.httpPartsCompleted,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get httpPartsTotal => $composableBuilder(
      column: $table.httpPartsTotal,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get previousCycleState => $composableBuilder(
      column: $table.previousCycleState,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get infoHash => $composableBuilder(
      column: $table.infoHash, builder: (column) => ColumnFilters(column));
}

class $$DownloadTasksTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadTasksTable> {
  $$DownloadTasksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fileName => $composableBuilder(
      column: $table.fileName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fileSize => $composableBuilder(
      column: $table.fileSize, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get downloadedBytes => $composableBuilder(
      column: $table.downloadedBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get speed => $composableBuilder(
      column: $table.speed, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get eta => $composableBuilder(
      column: $table.eta, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get savePath => $composableBuilder(
      column: $table.savePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localFilePath => $composableBuilder(
      column: $table.localFilePath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tempFilePath => $composableBuilder(
      column: $table.tempFilePath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get threadCount => $composableBuilder(
      column: $table.threadCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get chunks => $composableBuilder(
      column: $table.chunks, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get scheduledAt => $composableBuilder(
      column: $table.scheduledAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get supportsResume => $composableBuilder(
      column: $table.supportsResume,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get speedLimitKbps => $composableBuilder(
      column: $table.speedLimitKbps,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get seedingEnabled => $composableBuilder(
      column: $table.seedingEnabled,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get seedingLimited => $composableBuilder(
      column: $table.seedingLimited,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get seedingLimitKbps => $composableBuilder(
      column: $table.seedingLimitKbps,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get torrentFiles => $composableBuilder(
      column: $table.torrentFiles,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get downloadPageUrl => $composableBuilder(
      column: $table.downloadPageUrl,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mergedAudioUrl => $composableBuilder(
      column: $table.mergedAudioUrl,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get audioSize => $composableBuilder(
      column: $table.audioSize, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get audioDownloadedBytes => $composableBuilder(
      column: $table.audioDownloadedBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get videoStreamSize => $composableBuilder(
      column: $table.videoStreamSize,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get audioProgress => $composableBuilder(
      column: $table.audioProgress,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get pausedByUser => $composableBuilder(
      column: $table.pausedByUser,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get youtubeQualityPreset => $composableBuilder(
      column: $table.youtubeQualityPreset,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get notes => $composableBuilder(
      column: $table.notes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get playlistId => $composableBuilder(
      column: $table.playlistId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get playlistTitle => $composableBuilder(
      column: $table.playlistTitle,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get thumbnailUrl => $composableBuilder(
      column: $table.thumbnailUrl,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isAppUpdate => $composableBuilder(
      column: $table.isAppUpdate, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get uploadedBytes => $composableBuilder(
      column: $table.uploadedBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get priority => $composableBuilder(
      column: $table.priority, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get queueOrder => $composableBuilder(
      column: $table.queueOrder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get expectedSha256 => $composableBuilder(
      column: $table.expectedSha256,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mirrorUrls => $composableBuilder(
      column: $table.mirrorUrls, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get pauseReason => $composableBuilder(
      column: $table.pauseReason, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalPieces => $composableBuilder(
      column: $table.totalPieces, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get completedPieces => $composableBuilder(
      column: $table.completedPieces,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get ytCounterpartDownloadedBytes => $composableBuilder(
      column: $table.ytCounterpartDownloadedBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get cycleState => $composableBuilder(
      column: $table.cycleState, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioChunks => $composableBuilder(
      column: $table.audioChunks, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get httpParts => $composableBuilder(
      column: $table.httpParts, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get torrentPieceProgress => $composableBuilder(
      column: $table.torrentPieceProgress,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get audioChunksCompleted => $composableBuilder(
      column: $table.audioChunksCompleted,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get audioChunksTotal => $composableBuilder(
      column: $table.audioChunksTotal,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get httpPartsCompleted => $composableBuilder(
      column: $table.httpPartsCompleted,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get httpPartsTotal => $composableBuilder(
      column: $table.httpPartsTotal,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get previousCycleState => $composableBuilder(
      column: $table.previousCycleState,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get infoHash => $composableBuilder(
      column: $table.infoHash, builder: (column) => ColumnOrderings(column));
}

class $$DownloadTasksTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadTasksTable> {
  $$DownloadTasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<int> get fileSize =>
      $composableBuilder(column: $table.fileSize, builder: (column) => column);

  GeneratedColumn<int> get downloadedBytes => $composableBuilder(
      column: $table.downloadedBytes, builder: (column) => column);

  GeneratedColumn<double> get speed =>
      $composableBuilder(column: $table.speed, builder: (column) => column);

  GeneratedColumn<int> get eta =>
      $composableBuilder(column: $table.eta, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get savePath =>
      $composableBuilder(column: $table.savePath, builder: (column) => column);

  GeneratedColumn<String> get localFilePath => $composableBuilder(
      column: $table.localFilePath, builder: (column) => column);

  GeneratedColumn<String> get tempFilePath => $composableBuilder(
      column: $table.tempFilePath, builder: (column) => column);

  GeneratedColumn<String> get errorMessage => $composableBuilder(
      column: $table.errorMessage, builder: (column) => column);

  GeneratedColumn<int> get threadCount => $composableBuilder(
      column: $table.threadCount, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<double>?, String> get chunks =>
      $composableBuilder(column: $table.chunks, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get completedAt => $composableBuilder(
      column: $table.completedAt, builder: (column) => column);

  GeneratedColumn<int> get scheduledAt => $composableBuilder(
      column: $table.scheduledAt, builder: (column) => column);

  GeneratedColumn<bool> get supportsResume => $composableBuilder(
      column: $table.supportsResume, builder: (column) => column);

  GeneratedColumn<int> get speedLimitKbps => $composableBuilder(
      column: $table.speedLimitKbps, builder: (column) => column);

  GeneratedColumn<bool> get seedingEnabled => $composableBuilder(
      column: $table.seedingEnabled, builder: (column) => column);

  GeneratedColumn<bool> get seedingLimited => $composableBuilder(
      column: $table.seedingLimited, builder: (column) => column);

  GeneratedColumn<int> get seedingLimitKbps => $composableBuilder(
      column: $table.seedingLimitKbps, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<Map<String, dynamic>>?, String>
      get torrentFiles => $composableBuilder(
          column: $table.torrentFiles, builder: (column) => column);

  GeneratedColumn<String> get downloadPageUrl => $composableBuilder(
      column: $table.downloadPageUrl, builder: (column) => column);

  GeneratedColumn<String> get mergedAudioUrl => $composableBuilder(
      column: $table.mergedAudioUrl, builder: (column) => column);

  GeneratedColumn<int> get audioSize =>
      $composableBuilder(column: $table.audioSize, builder: (column) => column);

  GeneratedColumn<int> get audioDownloadedBytes => $composableBuilder(
      column: $table.audioDownloadedBytes, builder: (column) => column);

  GeneratedColumn<int> get videoStreamSize => $composableBuilder(
      column: $table.videoStreamSize, builder: (column) => column);

  GeneratedColumn<double> get audioProgress => $composableBuilder(
      column: $table.audioProgress, builder: (column) => column);

  GeneratedColumn<bool> get pausedByUser => $composableBuilder(
      column: $table.pausedByUser, builder: (column) => column);

  GeneratedColumn<String> get youtubeQualityPreset => $composableBuilder(
      column: $table.youtubeQualityPreset, builder: (column) => column);

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);

  GeneratedColumn<String> get playlistId => $composableBuilder(
      column: $table.playlistId, builder: (column) => column);

  GeneratedColumn<String> get playlistTitle => $composableBuilder(
      column: $table.playlistTitle, builder: (column) => column);

  GeneratedColumn<String> get thumbnailUrl => $composableBuilder(
      column: $table.thumbnailUrl, builder: (column) => column);

  GeneratedColumn<bool> get isAppUpdate => $composableBuilder(
      column: $table.isAppUpdate, builder: (column) => column);

  GeneratedColumn<int> get uploadedBytes => $composableBuilder(
      column: $table.uploadedBytes, builder: (column) => column);

  GeneratedColumn<int> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<int> get queueOrder => $composableBuilder(
      column: $table.queueOrder, builder: (column) => column);

  GeneratedColumn<String> get expectedSha256 => $composableBuilder(
      column: $table.expectedSha256, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<String>?, String> get mirrorUrls =>
      $composableBuilder(
          column: $table.mirrorUrls, builder: (column) => column);

  GeneratedColumn<String> get pauseReason => $composableBuilder(
      column: $table.pauseReason, builder: (column) => column);

  GeneratedColumn<int> get totalPieces => $composableBuilder(
      column: $table.totalPieces, builder: (column) => column);

  GeneratedColumn<int> get completedPieces => $composableBuilder(
      column: $table.completedPieces, builder: (column) => column);

  GeneratedColumn<int> get ytCounterpartDownloadedBytes => $composableBuilder(
      column: $table.ytCounterpartDownloadedBytes, builder: (column) => column);

  GeneratedColumn<String> get cycleState => $composableBuilder(
      column: $table.cycleState, builder: (column) => column);

  GeneratedColumnWithTypeConverter<List<double>?, String> get audioChunks =>
      $composableBuilder(
          column: $table.audioChunks, builder: (column) => column);

  GeneratedColumn<String> get httpParts =>
      $composableBuilder(column: $table.httpParts, builder: (column) => column);

  GeneratedColumn<double> get torrentPieceProgress => $composableBuilder(
      column: $table.torrentPieceProgress, builder: (column) => column);

  GeneratedColumn<int> get audioChunksCompleted => $composableBuilder(
      column: $table.audioChunksCompleted, builder: (column) => column);

  GeneratedColumn<int> get audioChunksTotal => $composableBuilder(
      column: $table.audioChunksTotal, builder: (column) => column);

  GeneratedColumn<int> get httpPartsCompleted => $composableBuilder(
      column: $table.httpPartsCompleted, builder: (column) => column);

  GeneratedColumn<int> get httpPartsTotal => $composableBuilder(
      column: $table.httpPartsTotal, builder: (column) => column);

  GeneratedColumn<String> get previousCycleState => $composableBuilder(
      column: $table.previousCycleState, builder: (column) => column);

  GeneratedColumn<String> get infoHash =>
      $composableBuilder(column: $table.infoHash, builder: (column) => column);
}

class $$DownloadTasksTableTableManager extends RootTableManager<
    _$AppDatabase,
    $DownloadTasksTable,
    DbDownloadTask,
    $$DownloadTasksTableFilterComposer,
    $$DownloadTasksTableOrderingComposer,
    $$DownloadTasksTableAnnotationComposer,
    $$DownloadTasksTableCreateCompanionBuilder,
    $$DownloadTasksTableUpdateCompanionBuilder,
    (
      DbDownloadTask,
      BaseReferences<_$AppDatabase, $DownloadTasksTable, DbDownloadTask>
    ),
    DbDownloadTask,
    PrefetchHooks Function()> {
  $$DownloadTasksTableTableManager(_$AppDatabase db, $DownloadTasksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadTasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadTasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadTasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> fileName = const Value.absent(),
            Value<String> url = const Value.absent(),
            Value<int> fileSize = const Value.absent(),
            Value<int> downloadedBytes = const Value.absent(),
            Value<double> speed = const Value.absent(),
            Value<int?> eta = const Value.absent(),
            Value<String> category = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<String> savePath = const Value.absent(),
            Value<String> localFilePath = const Value.absent(),
            Value<String> tempFilePath = const Value.absent(),
            Value<String?> errorMessage = const Value.absent(),
            Value<int> threadCount = const Value.absent(),
            Value<List<double>?> chunks = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int?> completedAt = const Value.absent(),
            Value<int?> scheduledAt = const Value.absent(),
            Value<bool> supportsResume = const Value.absent(),
            Value<int> speedLimitKbps = const Value.absent(),
            Value<bool> seedingEnabled = const Value.absent(),
            Value<bool> seedingLimited = const Value.absent(),
            Value<int> seedingLimitKbps = const Value.absent(),
            Value<List<Map<String, dynamic>>?> torrentFiles =
                const Value.absent(),
            Value<String?> downloadPageUrl = const Value.absent(),
            Value<String?> mergedAudioUrl = const Value.absent(),
            Value<int> audioSize = const Value.absent(),
            Value<int> audioDownloadedBytes = const Value.absent(),
            Value<int> videoStreamSize = const Value.absent(),
            Value<double> audioProgress = const Value.absent(),
            Value<bool> pausedByUser = const Value.absent(),
            Value<String?> youtubeQualityPreset = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<String?> playlistId = const Value.absent(),
            Value<String?> playlistTitle = const Value.absent(),
            Value<String?> thumbnailUrl = const Value.absent(),
            Value<bool> isAppUpdate = const Value.absent(),
            Value<int> uploadedBytes = const Value.absent(),
            Value<int> priority = const Value.absent(),
            Value<int> queueOrder = const Value.absent(),
            Value<String?> expectedSha256 = const Value.absent(),
            Value<List<String>?> mirrorUrls = const Value.absent(),
            Value<String?> pauseReason = const Value.absent(),
            Value<int?> totalPieces = const Value.absent(),
            Value<int?> completedPieces = const Value.absent(),
            Value<int?> ytCounterpartDownloadedBytes = const Value.absent(),
            Value<String?> cycleState = const Value.absent(),
            Value<List<double>?> audioChunks = const Value.absent(),
            Value<String?> httpParts = const Value.absent(),
            Value<double?> torrentPieceProgress = const Value.absent(),
            Value<int?> audioChunksCompleted = const Value.absent(),
            Value<int?> audioChunksTotal = const Value.absent(),
            Value<int?> httpPartsCompleted = const Value.absent(),
            Value<int?> httpPartsTotal = const Value.absent(),
            Value<String?> previousCycleState = const Value.absent(),
            Value<String?> infoHash = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DownloadTasksCompanion(
            id: id,
            fileName: fileName,
            url: url,
            fileSize: fileSize,
            downloadedBytes: downloadedBytes,
            speed: speed,
            eta: eta,
            category: category,
            status: status,
            savePath: savePath,
            localFilePath: localFilePath,
            tempFilePath: tempFilePath,
            errorMessage: errorMessage,
            threadCount: threadCount,
            chunks: chunks,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            scheduledAt: scheduledAt,
            supportsResume: supportsResume,
            speedLimitKbps: speedLimitKbps,
            seedingEnabled: seedingEnabled,
            seedingLimited: seedingLimited,
            seedingLimitKbps: seedingLimitKbps,
            torrentFiles: torrentFiles,
            downloadPageUrl: downloadPageUrl,
            mergedAudioUrl: mergedAudioUrl,
            audioSize: audioSize,
            audioDownloadedBytes: audioDownloadedBytes,
            videoStreamSize: videoStreamSize,
            audioProgress: audioProgress,
            pausedByUser: pausedByUser,
            youtubeQualityPreset: youtubeQualityPreset,
            notes: notes,
            playlistId: playlistId,
            playlistTitle: playlistTitle,
            thumbnailUrl: thumbnailUrl,
            isAppUpdate: isAppUpdate,
            uploadedBytes: uploadedBytes,
            priority: priority,
            queueOrder: queueOrder,
            expectedSha256: expectedSha256,
            mirrorUrls: mirrorUrls,
            pauseReason: pauseReason,
            totalPieces: totalPieces,
            completedPieces: completedPieces,
            ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
            cycleState: cycleState,
            audioChunks: audioChunks,
            httpParts: httpParts,
            torrentPieceProgress: torrentPieceProgress,
            audioChunksCompleted: audioChunksCompleted,
            audioChunksTotal: audioChunksTotal,
            httpPartsCompleted: httpPartsCompleted,
            httpPartsTotal: httpPartsTotal,
            previousCycleState: previousCycleState,
            infoHash: infoHash,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String fileName,
            required String url,
            Value<int> fileSize = const Value.absent(),
            Value<int> downloadedBytes = const Value.absent(),
            Value<double> speed = const Value.absent(),
            Value<int?> eta = const Value.absent(),
            required String category,
            required String status,
            required String savePath,
            required String localFilePath,
            required String tempFilePath,
            Value<String?> errorMessage = const Value.absent(),
            required int threadCount,
            Value<List<double>?> chunks = const Value.absent(),
            required int createdAt,
            required int updatedAt,
            Value<int?> completedAt = const Value.absent(),
            Value<int?> scheduledAt = const Value.absent(),
            Value<bool> supportsResume = const Value.absent(),
            Value<int> speedLimitKbps = const Value.absent(),
            Value<bool> seedingEnabled = const Value.absent(),
            Value<bool> seedingLimited = const Value.absent(),
            Value<int> seedingLimitKbps = const Value.absent(),
            Value<List<Map<String, dynamic>>?> torrentFiles =
                const Value.absent(),
            Value<String?> downloadPageUrl = const Value.absent(),
            Value<String?> mergedAudioUrl = const Value.absent(),
            Value<int> audioSize = const Value.absent(),
            Value<int> audioDownloadedBytes = const Value.absent(),
            Value<int> videoStreamSize = const Value.absent(),
            Value<double> audioProgress = const Value.absent(),
            Value<bool> pausedByUser = const Value.absent(),
            Value<String?> youtubeQualityPreset = const Value.absent(),
            Value<String?> notes = const Value.absent(),
            Value<String?> playlistId = const Value.absent(),
            Value<String?> playlistTitle = const Value.absent(),
            Value<String?> thumbnailUrl = const Value.absent(),
            Value<bool> isAppUpdate = const Value.absent(),
            Value<int> uploadedBytes = const Value.absent(),
            Value<int> priority = const Value.absent(),
            Value<int> queueOrder = const Value.absent(),
            Value<String?> expectedSha256 = const Value.absent(),
            Value<List<String>?> mirrorUrls = const Value.absent(),
            Value<String?> pauseReason = const Value.absent(),
            Value<int?> totalPieces = const Value.absent(),
            Value<int?> completedPieces = const Value.absent(),
            Value<int?> ytCounterpartDownloadedBytes = const Value.absent(),
            Value<String?> cycleState = const Value.absent(),
            Value<List<double>?> audioChunks = const Value.absent(),
            Value<String?> httpParts = const Value.absent(),
            Value<double?> torrentPieceProgress = const Value.absent(),
            Value<int?> audioChunksCompleted = const Value.absent(),
            Value<int?> audioChunksTotal = const Value.absent(),
            Value<int?> httpPartsCompleted = const Value.absent(),
            Value<int?> httpPartsTotal = const Value.absent(),
            Value<String?> previousCycleState = const Value.absent(),
            Value<String?> infoHash = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DownloadTasksCompanion.insert(
            id: id,
            fileName: fileName,
            url: url,
            fileSize: fileSize,
            downloadedBytes: downloadedBytes,
            speed: speed,
            eta: eta,
            category: category,
            status: status,
            savePath: savePath,
            localFilePath: localFilePath,
            tempFilePath: tempFilePath,
            errorMessage: errorMessage,
            threadCount: threadCount,
            chunks: chunks,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            scheduledAt: scheduledAt,
            supportsResume: supportsResume,
            speedLimitKbps: speedLimitKbps,
            seedingEnabled: seedingEnabled,
            seedingLimited: seedingLimited,
            seedingLimitKbps: seedingLimitKbps,
            torrentFiles: torrentFiles,
            downloadPageUrl: downloadPageUrl,
            mergedAudioUrl: mergedAudioUrl,
            audioSize: audioSize,
            audioDownloadedBytes: audioDownloadedBytes,
            videoStreamSize: videoStreamSize,
            audioProgress: audioProgress,
            pausedByUser: pausedByUser,
            youtubeQualityPreset: youtubeQualityPreset,
            notes: notes,
            playlistId: playlistId,
            playlistTitle: playlistTitle,
            thumbnailUrl: thumbnailUrl,
            isAppUpdate: isAppUpdate,
            uploadedBytes: uploadedBytes,
            priority: priority,
            queueOrder: queueOrder,
            expectedSha256: expectedSha256,
            mirrorUrls: mirrorUrls,
            pauseReason: pauseReason,
            totalPieces: totalPieces,
            completedPieces: completedPieces,
            ytCounterpartDownloadedBytes: ytCounterpartDownloadedBytes,
            cycleState: cycleState,
            audioChunks: audioChunks,
            httpParts: httpParts,
            torrentPieceProgress: torrentPieceProgress,
            audioChunksCompleted: audioChunksCompleted,
            audioChunksTotal: audioChunksTotal,
            httpPartsCompleted: httpPartsCompleted,
            httpPartsTotal: httpPartsTotal,
            previousCycleState: previousCycleState,
            infoHash: infoHash,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$DownloadTasksTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $DownloadTasksTable,
    DbDownloadTask,
    $$DownloadTasksTableFilterComposer,
    $$DownloadTasksTableOrderingComposer,
    $$DownloadTasksTableAnnotationComposer,
    $$DownloadTasksTableCreateCompanionBuilder,
    $$DownloadTasksTableUpdateCompanionBuilder,
    (
      DbDownloadTask,
      BaseReferences<_$AppDatabase, $DownloadTasksTable, DbDownloadTask>
    ),
    DbDownloadTask,
    PrefetchHooks Function()>;
typedef $$BookmarksTableCreateCompanionBuilder = BookmarksCompanion Function({
  required String id,
  required String title,
  required String url,
  Value<String?> folder,
  required int createdAt,
  Value<int> rowid,
});
typedef $$BookmarksTableUpdateCompanionBuilder = BookmarksCompanion Function({
  Value<String> id,
  Value<String> title,
  Value<String> url,
  Value<String?> folder,
  Value<int> createdAt,
  Value<int> rowid,
});

class $$BookmarksTableFilterComposer
    extends Composer<_$AppDatabase, $BookmarksTable> {
  $$BookmarksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get folder => $composableBuilder(
      column: $table.folder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$BookmarksTableOrderingComposer
    extends Composer<_$AppDatabase, $BookmarksTable> {
  $$BookmarksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get folder => $composableBuilder(
      column: $table.folder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$BookmarksTableAnnotationComposer
    extends Composer<_$AppDatabase, $BookmarksTable> {
  $$BookmarksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get folder =>
      $composableBuilder(column: $table.folder, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$BookmarksTableTableManager extends RootTableManager<
    _$AppDatabase,
    $BookmarksTable,
    DbBookmark,
    $$BookmarksTableFilterComposer,
    $$BookmarksTableOrderingComposer,
    $$BookmarksTableAnnotationComposer,
    $$BookmarksTableCreateCompanionBuilder,
    $$BookmarksTableUpdateCompanionBuilder,
    (DbBookmark, BaseReferences<_$AppDatabase, $BookmarksTable, DbBookmark>),
    DbBookmark,
    PrefetchHooks Function()> {
  $$BookmarksTableTableManager(_$AppDatabase db, $BookmarksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookmarksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookmarksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookmarksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> url = const Value.absent(),
            Value<String?> folder = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BookmarksCompanion(
            id: id,
            title: title,
            url: url,
            folder: folder,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String title,
            required String url,
            Value<String?> folder = const Value.absent(),
            required int createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              BookmarksCompanion.insert(
            id: id,
            title: title,
            url: url,
            folder: folder,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BookmarksTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $BookmarksTable,
    DbBookmark,
    $$BookmarksTableFilterComposer,
    $$BookmarksTableOrderingComposer,
    $$BookmarksTableAnnotationComposer,
    $$BookmarksTableCreateCompanionBuilder,
    $$BookmarksTableUpdateCompanionBuilder,
    (DbBookmark, BaseReferences<_$AppDatabase, $BookmarksTable, DbBookmark>),
    DbBookmark,
    PrefetchHooks Function()>;
typedef $$BrowserHistoryTableCreateCompanionBuilder = BrowserHistoryCompanion
    Function({
  Value<int> id,
  required String url,
  required String title,
  required int visitedAt,
  Value<int> visitCount,
  Value<String?> faviconUrl,
});
typedef $$BrowserHistoryTableUpdateCompanionBuilder = BrowserHistoryCompanion
    Function({
  Value<int> id,
  Value<String> url,
  Value<String> title,
  Value<int> visitedAt,
  Value<int> visitCount,
  Value<String?> faviconUrl,
});

class $$BrowserHistoryTableFilterComposer
    extends Composer<_$AppDatabase, $BrowserHistoryTable> {
  $$BrowserHistoryTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get visitedAt => $composableBuilder(
      column: $table.visitedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get visitCount => $composableBuilder(
      column: $table.visitCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get faviconUrl => $composableBuilder(
      column: $table.faviconUrl, builder: (column) => ColumnFilters(column));
}

class $$BrowserHistoryTableOrderingComposer
    extends Composer<_$AppDatabase, $BrowserHistoryTable> {
  $$BrowserHistoryTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get visitedAt => $composableBuilder(
      column: $table.visitedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get visitCount => $composableBuilder(
      column: $table.visitCount, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get faviconUrl => $composableBuilder(
      column: $table.faviconUrl, builder: (column) => ColumnOrderings(column));
}

class $$BrowserHistoryTableAnnotationComposer
    extends Composer<_$AppDatabase, $BrowserHistoryTable> {
  $$BrowserHistoryTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get visitedAt =>
      $composableBuilder(column: $table.visitedAt, builder: (column) => column);

  GeneratedColumn<int> get visitCount => $composableBuilder(
      column: $table.visitCount, builder: (column) => column);

  GeneratedColumn<String> get faviconUrl => $composableBuilder(
      column: $table.faviconUrl, builder: (column) => column);
}

class $$BrowserHistoryTableTableManager extends RootTableManager<
    _$AppDatabase,
    $BrowserHistoryTable,
    DbBrowserHistory,
    $$BrowserHistoryTableFilterComposer,
    $$BrowserHistoryTableOrderingComposer,
    $$BrowserHistoryTableAnnotationComposer,
    $$BrowserHistoryTableCreateCompanionBuilder,
    $$BrowserHistoryTableUpdateCompanionBuilder,
    (
      DbBrowserHistory,
      BaseReferences<_$AppDatabase, $BrowserHistoryTable, DbBrowserHistory>
    ),
    DbBrowserHistory,
    PrefetchHooks Function()> {
  $$BrowserHistoryTableTableManager(
      _$AppDatabase db, $BrowserHistoryTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BrowserHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BrowserHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BrowserHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> url = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<int> visitedAt = const Value.absent(),
            Value<int> visitCount = const Value.absent(),
            Value<String?> faviconUrl = const Value.absent(),
          }) =>
              BrowserHistoryCompanion(
            id: id,
            url: url,
            title: title,
            visitedAt: visitedAt,
            visitCount: visitCount,
            faviconUrl: faviconUrl,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String url,
            required String title,
            required int visitedAt,
            Value<int> visitCount = const Value.absent(),
            Value<String?> faviconUrl = const Value.absent(),
          }) =>
              BrowserHistoryCompanion.insert(
            id: id,
            url: url,
            title: title,
            visitedAt: visitedAt,
            visitCount: visitCount,
            faviconUrl: faviconUrl,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BrowserHistoryTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $BrowserHistoryTable,
    DbBrowserHistory,
    $$BrowserHistoryTableFilterComposer,
    $$BrowserHistoryTableOrderingComposer,
    $$BrowserHistoryTableAnnotationComposer,
    $$BrowserHistoryTableCreateCompanionBuilder,
    $$BrowserHistoryTableUpdateCompanionBuilder,
    (
      DbBrowserHistory,
      BaseReferences<_$AppDatabase, $BrowserHistoryTable, DbBrowserHistory>
    ),
    DbBrowserHistory,
    PrefetchHooks Function()>;
typedef $$BrowserTabsTableCreateCompanionBuilder = BrowserTabsCompanion
    Function({
  required String id,
  required String url,
  Value<String> title,
  Value<bool> isActive,
  Value<int> position,
  required int createdAt,
  Value<int> lastVisitedAt,
  Value<String?> faviconUrl,
  Value<int> rowid,
});
typedef $$BrowserTabsTableUpdateCompanionBuilder = BrowserTabsCompanion
    Function({
  Value<String> id,
  Value<String> url,
  Value<String> title,
  Value<bool> isActive,
  Value<int> position,
  Value<int> createdAt,
  Value<int> lastVisitedAt,
  Value<String?> faviconUrl,
  Value<int> rowid,
});

class $$BrowserTabsTableFilterComposer
    extends Composer<_$AppDatabase, $BrowserTabsTable> {
  $$BrowserTabsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastVisitedAt => $composableBuilder(
      column: $table.lastVisitedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get faviconUrl => $composableBuilder(
      column: $table.faviconUrl, builder: (column) => ColumnFilters(column));
}

class $$BrowserTabsTableOrderingComposer
    extends Composer<_$AppDatabase, $BrowserTabsTable> {
  $$BrowserTabsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isActive => $composableBuilder(
      column: $table.isActive, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position => $composableBuilder(
      column: $table.position, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastVisitedAt => $composableBuilder(
      column: $table.lastVisitedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get faviconUrl => $composableBuilder(
      column: $table.faviconUrl, builder: (column) => ColumnOrderings(column));
}

class $$BrowserTabsTableAnnotationComposer
    extends Composer<_$AppDatabase, $BrowserTabsTable> {
  $$BrowserTabsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<bool> get isActive =>
      $composableBuilder(column: $table.isActive, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastVisitedAt => $composableBuilder(
      column: $table.lastVisitedAt, builder: (column) => column);

  GeneratedColumn<String> get faviconUrl => $composableBuilder(
      column: $table.faviconUrl, builder: (column) => column);
}

class $$BrowserTabsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $BrowserTabsTable,
    SavedBrowserTab,
    $$BrowserTabsTableFilterComposer,
    $$BrowserTabsTableOrderingComposer,
    $$BrowserTabsTableAnnotationComposer,
    $$BrowserTabsTableCreateCompanionBuilder,
    $$BrowserTabsTableUpdateCompanionBuilder,
    (
      SavedBrowserTab,
      BaseReferences<_$AppDatabase, $BrowserTabsTable, SavedBrowserTab>
    ),
    SavedBrowserTab,
    PrefetchHooks Function()> {
  $$BrowserTabsTableTableManager(_$AppDatabase db, $BrowserTabsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BrowserTabsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BrowserTabsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BrowserTabsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> url = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
            Value<int> lastVisitedAt = const Value.absent(),
            Value<String?> faviconUrl = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BrowserTabsCompanion(
            id: id,
            url: url,
            title: title,
            isActive: isActive,
            position: position,
            createdAt: createdAt,
            lastVisitedAt: lastVisitedAt,
            faviconUrl: faviconUrl,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String url,
            Value<String> title = const Value.absent(),
            Value<bool> isActive = const Value.absent(),
            Value<int> position = const Value.absent(),
            required int createdAt,
            Value<int> lastVisitedAt = const Value.absent(),
            Value<String?> faviconUrl = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              BrowserTabsCompanion.insert(
            id: id,
            url: url,
            title: title,
            isActive: isActive,
            position: position,
            createdAt: createdAt,
            lastVisitedAt: lastVisitedAt,
            faviconUrl: faviconUrl,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$BrowserTabsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $BrowserTabsTable,
    SavedBrowserTab,
    $$BrowserTabsTableFilterComposer,
    $$BrowserTabsTableOrderingComposer,
    $$BrowserTabsTableAnnotationComposer,
    $$BrowserTabsTableCreateCompanionBuilder,
    $$BrowserTabsTableUpdateCompanionBuilder,
    (
      SavedBrowserTab,
      BaseReferences<_$AppDatabase, $BrowserTabsTable, SavedBrowserTab>
    ),
    SavedBrowserTab,
    PrefetchHooks Function()>;
typedef $$MirrorHealthTableCreateCompanionBuilder = MirrorHealthCompanion
    Function({
  required String url,
  Value<int> failures,
  Value<int> lastFailure,
  Value<int> lastSuccess,
  Value<int> lastStatusCode,
  Value<int> blacklistedUntil,
  Value<double> averageSpeedBps,
  Value<String?> speedSamples,
  Value<int> rowid,
});
typedef $$MirrorHealthTableUpdateCompanionBuilder = MirrorHealthCompanion
    Function({
  Value<String> url,
  Value<int> failures,
  Value<int> lastFailure,
  Value<int> lastSuccess,
  Value<int> lastStatusCode,
  Value<int> blacklistedUntil,
  Value<double> averageSpeedBps,
  Value<String?> speedSamples,
  Value<int> rowid,
});

class $$MirrorHealthTableFilterComposer
    extends Composer<_$AppDatabase, $MirrorHealthTable> {
  $$MirrorHealthTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get failures => $composableBuilder(
      column: $table.failures, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastFailure => $composableBuilder(
      column: $table.lastFailure, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSuccess => $composableBuilder(
      column: $table.lastSuccess, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastStatusCode => $composableBuilder(
      column: $table.lastStatusCode,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get blacklistedUntil => $composableBuilder(
      column: $table.blacklistedUntil,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get averageSpeedBps => $composableBuilder(
      column: $table.averageSpeedBps,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get speedSamples => $composableBuilder(
      column: $table.speedSamples, builder: (column) => ColumnFilters(column));
}

class $$MirrorHealthTableOrderingComposer
    extends Composer<_$AppDatabase, $MirrorHealthTable> {
  $$MirrorHealthTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get failures => $composableBuilder(
      column: $table.failures, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastFailure => $composableBuilder(
      column: $table.lastFailure, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSuccess => $composableBuilder(
      column: $table.lastSuccess, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastStatusCode => $composableBuilder(
      column: $table.lastStatusCode,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get blacklistedUntil => $composableBuilder(
      column: $table.blacklistedUntil,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get averageSpeedBps => $composableBuilder(
      column: $table.averageSpeedBps,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get speedSamples => $composableBuilder(
      column: $table.speedSamples,
      builder: (column) => ColumnOrderings(column));
}

class $$MirrorHealthTableAnnotationComposer
    extends Composer<_$AppDatabase, $MirrorHealthTable> {
  $$MirrorHealthTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<int> get failures =>
      $composableBuilder(column: $table.failures, builder: (column) => column);

  GeneratedColumn<int> get lastFailure => $composableBuilder(
      column: $table.lastFailure, builder: (column) => column);

  GeneratedColumn<int> get lastSuccess => $composableBuilder(
      column: $table.lastSuccess, builder: (column) => column);

  GeneratedColumn<int> get lastStatusCode => $composableBuilder(
      column: $table.lastStatusCode, builder: (column) => column);

  GeneratedColumn<int> get blacklistedUntil => $composableBuilder(
      column: $table.blacklistedUntil, builder: (column) => column);

  GeneratedColumn<double> get averageSpeedBps => $composableBuilder(
      column: $table.averageSpeedBps, builder: (column) => column);

  GeneratedColumn<String> get speedSamples => $composableBuilder(
      column: $table.speedSamples, builder: (column) => column);
}

class $$MirrorHealthTableTableManager extends RootTableManager<
    _$AppDatabase,
    $MirrorHealthTable,
    DbMirrorHealth,
    $$MirrorHealthTableFilterComposer,
    $$MirrorHealthTableOrderingComposer,
    $$MirrorHealthTableAnnotationComposer,
    $$MirrorHealthTableCreateCompanionBuilder,
    $$MirrorHealthTableUpdateCompanionBuilder,
    (
      DbMirrorHealth,
      BaseReferences<_$AppDatabase, $MirrorHealthTable, DbMirrorHealth>
    ),
    DbMirrorHealth,
    PrefetchHooks Function()> {
  $$MirrorHealthTableTableManager(_$AppDatabase db, $MirrorHealthTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MirrorHealthTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MirrorHealthTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MirrorHealthTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> url = const Value.absent(),
            Value<int> failures = const Value.absent(),
            Value<int> lastFailure = const Value.absent(),
            Value<int> lastSuccess = const Value.absent(),
            Value<int> lastStatusCode = const Value.absent(),
            Value<int> blacklistedUntil = const Value.absent(),
            Value<double> averageSpeedBps = const Value.absent(),
            Value<String?> speedSamples = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MirrorHealthCompanion(
            url: url,
            failures: failures,
            lastFailure: lastFailure,
            lastSuccess: lastSuccess,
            lastStatusCode: lastStatusCode,
            blacklistedUntil: blacklistedUntil,
            averageSpeedBps: averageSpeedBps,
            speedSamples: speedSamples,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String url,
            Value<int> failures = const Value.absent(),
            Value<int> lastFailure = const Value.absent(),
            Value<int> lastSuccess = const Value.absent(),
            Value<int> lastStatusCode = const Value.absent(),
            Value<int> blacklistedUntil = const Value.absent(),
            Value<double> averageSpeedBps = const Value.absent(),
            Value<String?> speedSamples = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              MirrorHealthCompanion.insert(
            url: url,
            failures: failures,
            lastFailure: lastFailure,
            lastSuccess: lastSuccess,
            lastStatusCode: lastStatusCode,
            blacklistedUntil: blacklistedUntil,
            averageSpeedBps: averageSpeedBps,
            speedSamples: speedSamples,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$MirrorHealthTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $MirrorHealthTable,
    DbMirrorHealth,
    $$MirrorHealthTableFilterComposer,
    $$MirrorHealthTableOrderingComposer,
    $$MirrorHealthTableAnnotationComposer,
    $$MirrorHealthTableCreateCompanionBuilder,
    $$MirrorHealthTableUpdateCompanionBuilder,
    (
      DbMirrorHealth,
      BaseReferences<_$AppDatabase, $MirrorHealthTable, DbMirrorHealth>
    ),
    DbMirrorHealth,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DownloadTasksTableTableManager get downloadTasks =>
      $$DownloadTasksTableTableManager(_db, _db.downloadTasks);
  $$BookmarksTableTableManager get bookmarks =>
      $$BookmarksTableTableManager(_db, _db.bookmarks);
  $$BrowserHistoryTableTableManager get browserHistory =>
      $$BrowserHistoryTableTableManager(_db, _db.browserHistory);
  $$BrowserTabsTableTableManager get browserTabs =>
      $$BrowserTabsTableTableManager(_db, _db.browserTabs);
  $$MirrorHealthTableTableManager get mirrorHealth =>
      $$MirrorHealthTableTableManager(_db, _db.mirrorHealth);
}
