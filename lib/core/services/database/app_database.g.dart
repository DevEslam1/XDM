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
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileSizeMeta = const VerificationMeta(
    'fileSize',
  );
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
    'file_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _downloadedBytesMeta = const VerificationMeta(
    'downloadedBytes',
  );
  @override
  late final GeneratedColumn<int> downloadedBytes = GeneratedColumn<int>(
    'downloaded_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _speedMeta = const VerificationMeta('speed');
  @override
  late final GeneratedColumn<double> speed = GeneratedColumn<double>(
    'speed',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _etaMeta = const VerificationMeta('eta');
  @override
  late final GeneratedColumn<int> eta = GeneratedColumn<int>(
    'eta',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savePathMeta = const VerificationMeta(
    'savePath',
  );
  @override
  late final GeneratedColumn<String> savePath = GeneratedColumn<String>(
    'save_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localFilePathMeta = const VerificationMeta(
    'localFilePath',
  );
  @override
  late final GeneratedColumn<String> localFilePath = GeneratedColumn<String>(
    'local_file_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tempFilePathMeta = const VerificationMeta(
    'tempFilePath',
  );
  @override
  late final GeneratedColumn<String> tempFilePath = GeneratedColumn<String>(
    'temp_file_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorMessageMeta = const VerificationMeta(
    'errorMessage',
  );
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
    'error_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _threadCountMeta = const VerificationMeta(
    'threadCount',
  );
  @override
  late final GeneratedColumn<int> threadCount = GeneratedColumn<int>(
    'thread_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<List<double>?, String> chunks =
      GeneratedColumn<String>(
        'chunks',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<List<double>?>($DownloadTasksTable.$converterchunks);
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<int> completedAt = GeneratedColumn<int>(
    'completed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scheduledAtMeta = const VerificationMeta(
    'scheduledAt',
  );
  @override
  late final GeneratedColumn<int> scheduledAt = GeneratedColumn<int>(
    'scheduled_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _supportsResumeMeta = const VerificationMeta(
    'supportsResume',
  );
  @override
  late final GeneratedColumn<bool> supportsResume = GeneratedColumn<bool>(
    'supports_resume',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("supports_resume" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _speedLimitKbpsMeta = const VerificationMeta(
    'speedLimitKbps',
  );
  @override
  late final GeneratedColumn<int> speedLimitKbps = GeneratedColumn<int>(
    'speed_limit_kbps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _seedingEnabledMeta = const VerificationMeta(
    'seedingEnabled',
  );
  @override
  late final GeneratedColumn<bool> seedingEnabled = GeneratedColumn<bool>(
    'seeding_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("seeding_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _seedingLimitedMeta = const VerificationMeta(
    'seedingLimited',
  );
  @override
  late final GeneratedColumn<bool> seedingLimited = GeneratedColumn<bool>(
    'seeding_limited',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("seeding_limited" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _seedingLimitKbpsMeta = const VerificationMeta(
    'seedingLimitKbps',
  );
  @override
  late final GeneratedColumn<int> seedingLimitKbps = GeneratedColumn<int>(
    'seeding_limit_kbps',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(500),
  );
  @override
  late final GeneratedColumnWithTypeConverter<
    List<Map<String, dynamic>>?,
    String
  >
  torrentFiles =
      GeneratedColumn<String>(
        'torrent_files',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<List<Map<String, dynamic>>?>(
        $DownloadTasksTable.$convertertorrentFiles,
      );
  static const VerificationMeta _downloadPageUrlMeta = const VerificationMeta(
    'downloadPageUrl',
  );
  @override
  late final GeneratedColumn<String> downloadPageUrl = GeneratedColumn<String>(
    'download_page_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mergedAudioUrlMeta = const VerificationMeta(
    'mergedAudioUrl',
  );
  @override
  late final GeneratedColumn<String> mergedAudioUrl = GeneratedColumn<String>(
    'merged_audio_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioSizeMeta = const VerificationMeta(
    'audioSize',
  );
  @override
  late final GeneratedColumn<int> audioSize = GeneratedColumn<int>(
    'audio_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _audioProgressMeta = const VerificationMeta(
    'audioProgress',
  );
  @override
  late final GeneratedColumn<double> audioProgress = GeneratedColumn<double>(
    'audio_progress',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _pausedByUserMeta = const VerificationMeta(
    'pausedByUser',
  );
  @override
  late final GeneratedColumn<bool> pausedByUser = GeneratedColumn<bool>(
    'paused_by_user',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("paused_by_user" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _youtubeQualityPresetMeta =
      const VerificationMeta('youtubeQualityPreset');
  @override
  late final GeneratedColumn<String> youtubeQualityPreset =
      GeneratedColumn<String>(
        'youtube_quality_preset',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _notesMeta = const VerificationMeta('notes');
  @override
  late final GeneratedColumn<String> notes = GeneratedColumn<String>(
    'notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
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
    audioProgress,
    pausedByUser,
    youtubeQualityPreset,
    notes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbDownloadTask> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('file_size')) {
      context.handle(
        _fileSizeMeta,
        fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta),
      );
    }
    if (data.containsKey('downloaded_bytes')) {
      context.handle(
        _downloadedBytesMeta,
        downloadedBytes.isAcceptableOrUnknown(
          data['downloaded_bytes']!,
          _downloadedBytesMeta,
        ),
      );
    }
    if (data.containsKey('speed')) {
      context.handle(
        _speedMeta,
        speed.isAcceptableOrUnknown(data['speed']!, _speedMeta),
      );
    }
    if (data.containsKey('eta')) {
      context.handle(
        _etaMeta,
        eta.isAcceptableOrUnknown(data['eta']!, _etaMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    } else if (isInserting) {
      context.missing(_categoryMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('save_path')) {
      context.handle(
        _savePathMeta,
        savePath.isAcceptableOrUnknown(data['save_path']!, _savePathMeta),
      );
    } else if (isInserting) {
      context.missing(_savePathMeta);
    }
    if (data.containsKey('local_file_path')) {
      context.handle(
        _localFilePathMeta,
        localFilePath.isAcceptableOrUnknown(
          data['local_file_path']!,
          _localFilePathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_localFilePathMeta);
    }
    if (data.containsKey('temp_file_path')) {
      context.handle(
        _tempFilePathMeta,
        tempFilePath.isAcceptableOrUnknown(
          data['temp_file_path']!,
          _tempFilePathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_tempFilePathMeta);
    }
    if (data.containsKey('error_message')) {
      context.handle(
        _errorMessageMeta,
        errorMessage.isAcceptableOrUnknown(
          data['error_message']!,
          _errorMessageMeta,
        ),
      );
    }
    if (data.containsKey('thread_count')) {
      context.handle(
        _threadCountMeta,
        threadCount.isAcceptableOrUnknown(
          data['thread_count']!,
          _threadCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_threadCountMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    }
    if (data.containsKey('scheduled_at')) {
      context.handle(
        _scheduledAtMeta,
        scheduledAt.isAcceptableOrUnknown(
          data['scheduled_at']!,
          _scheduledAtMeta,
        ),
      );
    }
    if (data.containsKey('supports_resume')) {
      context.handle(
        _supportsResumeMeta,
        supportsResume.isAcceptableOrUnknown(
          data['supports_resume']!,
          _supportsResumeMeta,
        ),
      );
    }
    if (data.containsKey('speed_limit_kbps')) {
      context.handle(
        _speedLimitKbpsMeta,
        speedLimitKbps.isAcceptableOrUnknown(
          data['speed_limit_kbps']!,
          _speedLimitKbpsMeta,
        ),
      );
    }
    if (data.containsKey('seeding_enabled')) {
      context.handle(
        _seedingEnabledMeta,
        seedingEnabled.isAcceptableOrUnknown(
          data['seeding_enabled']!,
          _seedingEnabledMeta,
        ),
      );
    }
    if (data.containsKey('seeding_limited')) {
      context.handle(
        _seedingLimitedMeta,
        seedingLimited.isAcceptableOrUnknown(
          data['seeding_limited']!,
          _seedingLimitedMeta,
        ),
      );
    }
    if (data.containsKey('seeding_limit_kbps')) {
      context.handle(
        _seedingLimitKbpsMeta,
        seedingLimitKbps.isAcceptableOrUnknown(
          data['seeding_limit_kbps']!,
          _seedingLimitKbpsMeta,
        ),
      );
    }
    if (data.containsKey('download_page_url')) {
      context.handle(
        _downloadPageUrlMeta,
        downloadPageUrl.isAcceptableOrUnknown(
          data['download_page_url']!,
          _downloadPageUrlMeta,
        ),
      );
    }
    if (data.containsKey('merged_audio_url')) {
      context.handle(
        _mergedAudioUrlMeta,
        mergedAudioUrl.isAcceptableOrUnknown(
          data['merged_audio_url']!,
          _mergedAudioUrlMeta,
        ),
      );
    }
    if (data.containsKey('audio_size')) {
      context.handle(
        _audioSizeMeta,
        audioSize.isAcceptableOrUnknown(data['audio_size']!, _audioSizeMeta),
      );
    }
    if (data.containsKey('audio_progress')) {
      context.handle(
        _audioProgressMeta,
        audioProgress.isAcceptableOrUnknown(
          data['audio_progress']!,
          _audioProgressMeta,
        ),
      );
    }
    if (data.containsKey('paused_by_user')) {
      context.handle(
        _pausedByUserMeta,
        pausedByUser.isAcceptableOrUnknown(
          data['paused_by_user']!,
          _pausedByUserMeta,
        ),
      );
    }
    if (data.containsKey('youtube_quality_preset')) {
      context.handle(
        _youtubeQualityPresetMeta,
        youtubeQualityPreset.isAcceptableOrUnknown(
          data['youtube_quality_preset']!,
          _youtubeQualityPresetMeta,
        ),
      );
    }
    if (data.containsKey('notes')) {
      context.handle(
        _notesMeta,
        notes.isAcceptableOrUnknown(data['notes']!, _notesMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbDownloadTask map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbDownloadTask(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      )!,
      fileSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_size'],
      )!,
      downloadedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}downloaded_bytes'],
      )!,
      speed: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}speed'],
      )!,
      eta: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}eta'],
      ),
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      savePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}save_path'],
      )!,
      localFilePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_file_path'],
      )!,
      tempFilePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}temp_file_path'],
      )!,
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
      threadCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thread_count'],
      )!,
      chunks: $DownloadTasksTable.$converterchunks.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}chunks'],
        ),
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}completed_at'],
      ),
      scheduledAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scheduled_at'],
      ),
      supportsResume: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}supports_resume'],
      )!,
      speedLimitKbps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}speed_limit_kbps'],
      )!,
      seedingEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}seeding_enabled'],
      )!,
      seedingLimited: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}seeding_limited'],
      )!,
      seedingLimitKbps: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seeding_limit_kbps'],
      )!,
      torrentFiles: $DownloadTasksTable.$convertertorrentFiles.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}torrent_files'],
        ),
      ),
      downloadPageUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}download_page_url'],
      ),
      mergedAudioUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}merged_audio_url'],
      ),
      audioSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}audio_size'],
      )!,
      audioProgress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}audio_progress'],
      )!,
      pausedByUser: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}paused_by_user'],
      )!,
      youtubeQualityPreset: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}youtube_quality_preset'],
      ),
      notes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notes'],
      ),
    );
  }

  @override
  $DownloadTasksTable createAlias(String alias) {
    return $DownloadTasksTable(attachedDatabase, alias);
  }

  static TypeConverter<List<double>?, String?> $converterchunks =
      NullAwareTypeConverter.wrap(const DoubleListConverter());
  static TypeConverter<List<Map<String, dynamic>>?, String?>
  $convertertorrentFiles = NullAwareTypeConverter.wrap(
    const TorrentFilesConverter(),
  );
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
  final double audioProgress;
  final bool pausedByUser;
  final String? youtubeQualityPreset;
  final String? notes;
  const DbDownloadTask({
    required this.id,
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
    required this.audioProgress,
    required this.pausedByUser,
    this.youtubeQualityPreset,
    this.notes,
  });
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
      map['chunks'] = Variable<String>(
        $DownloadTasksTable.$converterchunks.toSql(chunks),
      );
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
        $DownloadTasksTable.$convertertorrentFiles.toSql(torrentFiles),
      );
    }
    if (!nullToAbsent || downloadPageUrl != null) {
      map['download_page_url'] = Variable<String>(downloadPageUrl);
    }
    if (!nullToAbsent || mergedAudioUrl != null) {
      map['merged_audio_url'] = Variable<String>(mergedAudioUrl);
    }
    map['audio_size'] = Variable<int>(audioSize);
    map['audio_progress'] = Variable<double>(audioProgress);
    map['paused_by_user'] = Variable<bool>(pausedByUser);
    if (!nullToAbsent || youtubeQualityPreset != null) {
      map['youtube_quality_preset'] = Variable<String>(youtubeQualityPreset);
    }
    if (!nullToAbsent || notes != null) {
      map['notes'] = Variable<String>(notes);
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
      chunks: chunks == null && nullToAbsent
          ? const Value.absent()
          : Value(chunks),
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
      audioProgress: Value(audioProgress),
      pausedByUser: Value(pausedByUser),
      youtubeQualityPreset: youtubeQualityPreset == null && nullToAbsent
          ? const Value.absent()
          : Value(youtubeQualityPreset),
      notes: notes == null && nullToAbsent
          ? const Value.absent()
          : Value(notes),
    );
  }

  factory DbDownloadTask.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
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
      torrentFiles: serializer.fromJson<List<Map<String, dynamic>>?>(
        json['torrentFiles'],
      ),
      downloadPageUrl: serializer.fromJson<String?>(json['downloadPageUrl']),
      mergedAudioUrl: serializer.fromJson<String?>(json['mergedAudioUrl']),
      audioSize: serializer.fromJson<int>(json['audioSize']),
      audioProgress: serializer.fromJson<double>(json['audioProgress']),
      pausedByUser: serializer.fromJson<bool>(json['pausedByUser']),
      youtubeQualityPreset: serializer.fromJson<String?>(
        json['youtubeQualityPreset'],
      ),
      notes: serializer.fromJson<String?>(json['notes']),
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
      'torrentFiles': serializer.toJson<List<Map<String, dynamic>>?>(
        torrentFiles,
      ),
      'downloadPageUrl': serializer.toJson<String?>(downloadPageUrl),
      'mergedAudioUrl': serializer.toJson<String?>(mergedAudioUrl),
      'audioSize': serializer.toJson<int>(audioSize),
      'audioProgress': serializer.toJson<double>(audioProgress),
      'pausedByUser': serializer.toJson<bool>(pausedByUser),
      'youtubeQualityPreset': serializer.toJson<String?>(youtubeQualityPreset),
      'notes': serializer.toJson<String?>(notes),
    };
  }

  DbDownloadTask copyWith({
    String? id,
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
    Value<List<Map<String, dynamic>>?> torrentFiles = const Value.absent(),
    Value<String?> downloadPageUrl = const Value.absent(),
    Value<String?> mergedAudioUrl = const Value.absent(),
    int? audioSize,
    double? audioProgress,
    bool? pausedByUser,
    Value<String?> youtubeQualityPreset = const Value.absent(),
    Value<String?> notes = const Value.absent(),
  }) => DbDownloadTask(
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
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
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
    torrentFiles: torrentFiles.present ? torrentFiles.value : this.torrentFiles,
    downloadPageUrl: downloadPageUrl.present
        ? downloadPageUrl.value
        : this.downloadPageUrl,
    mergedAudioUrl: mergedAudioUrl.present
        ? mergedAudioUrl.value
        : this.mergedAudioUrl,
    audioSize: audioSize ?? this.audioSize,
    audioProgress: audioProgress ?? this.audioProgress,
    pausedByUser: pausedByUser ?? this.pausedByUser,
    youtubeQualityPreset: youtubeQualityPreset.present
        ? youtubeQualityPreset.value
        : this.youtubeQualityPreset,
    notes: notes.present ? notes.value : this.notes,
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
      threadCount: data.threadCount.present
          ? data.threadCount.value
          : this.threadCount,
      chunks: data.chunks.present ? data.chunks.value : this.chunks,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
      scheduledAt: data.scheduledAt.present
          ? data.scheduledAt.value
          : this.scheduledAt,
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
          ..write('audioProgress: $audioProgress, ')
          ..write('pausedByUser: $pausedByUser, ')
          ..write('youtubeQualityPreset: $youtubeQualityPreset, ')
          ..write('notes: $notes')
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
    audioProgress,
    pausedByUser,
    youtubeQualityPreset,
    notes,
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
          other.audioProgress == this.audioProgress &&
          other.pausedByUser == this.pausedByUser &&
          other.youtubeQualityPreset == this.youtubeQualityPreset &&
          other.notes == this.notes);
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
  final Value<double> audioProgress;
  final Value<bool> pausedByUser;
  final Value<String?> youtubeQualityPreset;
  final Value<String?> notes;
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
    this.audioProgress = const Value.absent(),
    this.pausedByUser = const Value.absent(),
    this.youtubeQualityPreset = const Value.absent(),
    this.notes = const Value.absent(),
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
    this.audioProgress = const Value.absent(),
    this.pausedByUser = const Value.absent(),
    this.youtubeQualityPreset = const Value.absent(),
    this.notes = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
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
    Expression<double>? audioProgress,
    Expression<bool>? pausedByUser,
    Expression<String>? youtubeQualityPreset,
    Expression<String>? notes,
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
      if (audioProgress != null) 'audio_progress': audioProgress,
      if (pausedByUser != null) 'paused_by_user': pausedByUser,
      if (youtubeQualityPreset != null)
        'youtube_quality_preset': youtubeQualityPreset,
      if (notes != null) 'notes': notes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadTasksCompanion copyWith({
    Value<String>? id,
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
    Value<double>? audioProgress,
    Value<bool>? pausedByUser,
    Value<String?>? youtubeQualityPreset,
    Value<String?>? notes,
    Value<int>? rowid,
  }) {
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
      audioProgress: audioProgress ?? this.audioProgress,
      pausedByUser: pausedByUser ?? this.pausedByUser,
      youtubeQualityPreset: youtubeQualityPreset ?? this.youtubeQualityPreset,
      notes: notes ?? this.notes,
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
        $DownloadTasksTable.$converterchunks.toSql(chunks.value),
      );
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
        $DownloadTasksTable.$convertertorrentFiles.toSql(torrentFiles.value),
      );
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
    if (audioProgress.present) {
      map['audio_progress'] = Variable<double>(audioProgress.value);
    }
    if (pausedByUser.present) {
      map['paused_by_user'] = Variable<bool>(pausedByUser.value);
    }
    if (youtubeQualityPreset.present) {
      map['youtube_quality_preset'] = Variable<String>(
        youtubeQualityPreset.value,
      );
    }
    if (notes.present) {
      map['notes'] = Variable<String>(notes.value);
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
          ..write('audioProgress: $audioProgress, ')
          ..write('pausedByUser: $pausedByUser, ')
          ..write('youtubeQualityPreset: $youtubeQualityPreset, ')
          ..write('notes: $notes, ')
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
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderMeta = const VerificationMeta('folder');
  @override
  late final GeneratedColumn<String> folder = GeneratedColumn<String>(
    'folder',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, title, url, folder, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bookmarks';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbBookmark> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('folder')) {
      context.handle(
        _folderMeta,
        folder.isAcceptableOrUnknown(data['folder']!, _folderMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
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
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      )!,
      folder: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
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
  final String createdAt;
  const DbBookmark({
    required this.id,
    required this.title,
    required this.url,
    this.folder,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['url'] = Variable<String>(url);
    if (!nullToAbsent || folder != null) {
      map['folder'] = Variable<String>(folder);
    }
    map['created_at'] = Variable<String>(createdAt);
    return map;
  }

  BookmarksCompanion toCompanion(bool nullToAbsent) {
    return BookmarksCompanion(
      id: Value(id),
      title: Value(title),
      url: Value(url),
      folder: folder == null && nullToAbsent
          ? const Value.absent()
          : Value(folder),
      createdAt: Value(createdAt),
    );
  }

  factory DbBookmark.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbBookmark(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      url: serializer.fromJson<String>(json['url']),
      folder: serializer.fromJson<String?>(json['folder']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
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
      'createdAt': serializer.toJson<String>(createdAt),
    };
  }

  DbBookmark copyWith({
    String? id,
    String? title,
    String? url,
    Value<String?> folder = const Value.absent(),
    String? createdAt,
  }) => DbBookmark(
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
  final Value<String> createdAt;
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
    required String createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       url = Value(url),
       createdAt = Value(createdAt);
  static Insertable<DbBookmark> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? url,
    Expression<String>? folder,
    Expression<String>? createdAt,
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

  BookmarksCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? url,
    Value<String?>? folder,
    Value<String>? createdAt,
    Value<int>? rowid,
  }) {
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
      map['created_at'] = Variable<String>(createdAt.value);
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
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _visitedAtMeta = const VerificationMeta(
    'visitedAt',
  );
  @override
  late final GeneratedColumn<String> visitedAt = GeneratedColumn<String>(
    'visited_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, url, title, visitedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'browser_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<DbBrowserHistory> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('visited_at')) {
      context.handle(
        _visitedAtMeta,
        visitedAt.isAcceptableOrUnknown(data['visited_at']!, _visitedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_visitedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DbBrowserHistory map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DbBrowserHistory(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      visitedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}visited_at'],
      )!,
    );
  }

  @override
  $BrowserHistoryTable createAlias(String alias) {
    return $BrowserHistoryTable(attachedDatabase, alias);
  }
}

class DbBrowserHistory extends DataClass
    implements Insertable<DbBrowserHistory> {
  final String id;
  final String url;
  final String title;
  final String visitedAt;
  const DbBrowserHistory({
    required this.id,
    required this.url,
    required this.title,
    required this.visitedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['url'] = Variable<String>(url);
    map['title'] = Variable<String>(title);
    map['visited_at'] = Variable<String>(visitedAt);
    return map;
  }

  BrowserHistoryCompanion toCompanion(bool nullToAbsent) {
    return BrowserHistoryCompanion(
      id: Value(id),
      url: Value(url),
      title: Value(title),
      visitedAt: Value(visitedAt),
    );
  }

  factory DbBrowserHistory.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DbBrowserHistory(
      id: serializer.fromJson<String>(json['id']),
      url: serializer.fromJson<String>(json['url']),
      title: serializer.fromJson<String>(json['title']),
      visitedAt: serializer.fromJson<String>(json['visitedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'url': serializer.toJson<String>(url),
      'title': serializer.toJson<String>(title),
      'visitedAt': serializer.toJson<String>(visitedAt),
    };
  }

  DbBrowserHistory copyWith({
    String? id,
    String? url,
    String? title,
    String? visitedAt,
  }) => DbBrowserHistory(
    id: id ?? this.id,
    url: url ?? this.url,
    title: title ?? this.title,
    visitedAt: visitedAt ?? this.visitedAt,
  );
  DbBrowserHistory copyWithCompanion(BrowserHistoryCompanion data) {
    return DbBrowserHistory(
      id: data.id.present ? data.id.value : this.id,
      url: data.url.present ? data.url.value : this.url,
      title: data.title.present ? data.title.value : this.title,
      visitedAt: data.visitedAt.present ? data.visitedAt.value : this.visitedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DbBrowserHistory(')
          ..write('id: $id, ')
          ..write('url: $url, ')
          ..write('title: $title, ')
          ..write('visitedAt: $visitedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, url, title, visitedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DbBrowserHistory &&
          other.id == this.id &&
          other.url == this.url &&
          other.title == this.title &&
          other.visitedAt == this.visitedAt);
}

class BrowserHistoryCompanion extends UpdateCompanion<DbBrowserHistory> {
  final Value<String> id;
  final Value<String> url;
  final Value<String> title;
  final Value<String> visitedAt;
  final Value<int> rowid;
  const BrowserHistoryCompanion({
    this.id = const Value.absent(),
    this.url = const Value.absent(),
    this.title = const Value.absent(),
    this.visitedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BrowserHistoryCompanion.insert({
    required String id,
    required String url,
    required String title,
    required String visitedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       url = Value(url),
       title = Value(title),
       visitedAt = Value(visitedAt);
  static Insertable<DbBrowserHistory> custom({
    Expression<String>? id,
    Expression<String>? url,
    Expression<String>? title,
    Expression<String>? visitedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (url != null) 'url': url,
      if (title != null) 'title': title,
      if (visitedAt != null) 'visited_at': visitedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BrowserHistoryCompanion copyWith({
    Value<String>? id,
    Value<String>? url,
    Value<String>? title,
    Value<String>? visitedAt,
    Value<int>? rowid,
  }) {
    return BrowserHistoryCompanion(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      visitedAt: visitedAt ?? this.visitedAt,
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
    if (visitedAt.present) {
      map['visited_at'] = Variable<String>(visitedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
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
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    downloadTasks,
    bookmarks,
    browserHistory,
  ];
}

typedef $$DownloadTasksTableCreateCompanionBuilder =
    DownloadTasksCompanion Function({
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
      Value<double> audioProgress,
      Value<bool> pausedByUser,
      Value<String?> youtubeQualityPreset,
      Value<String?> notes,
      Value<int> rowid,
    });
typedef $$DownloadTasksTableUpdateCompanionBuilder =
    DownloadTasksCompanion Function({
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
      Value<double> audioProgress,
      Value<bool> pausedByUser,
      Value<String?> youtubeQualityPreset,
      Value<String?> notes,
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
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get speed => $composableBuilder(
    column: $table.speed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get eta => $composableBuilder(
    column: $table.eta,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get savePath => $composableBuilder(
    column: $table.savePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localFilePath => $composableBuilder(
    column: $table.localFilePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tempFilePath => $composableBuilder(
    column: $table.tempFilePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get threadCount => $composableBuilder(
    column: $table.threadCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<List<double>?, List<double>, String>
  get chunks => $composableBuilder(
    column: $table.chunks,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scheduledAt => $composableBuilder(
    column: $table.scheduledAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get supportsResume => $composableBuilder(
    column: $table.supportsResume,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get speedLimitKbps => $composableBuilder(
    column: $table.speedLimitKbps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get seedingEnabled => $composableBuilder(
    column: $table.seedingEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get seedingLimited => $composableBuilder(
    column: $table.seedingLimited,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seedingLimitKbps => $composableBuilder(
    column: $table.seedingLimitKbps,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<
    List<Map<String, dynamic>>?,
    List<Map<String, dynamic>>,
    String
  >
  get torrentFiles => $composableBuilder(
    column: $table.torrentFiles,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get downloadPageUrl => $composableBuilder(
    column: $table.downloadPageUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mergedAudioUrl => $composableBuilder(
    column: $table.mergedAudioUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get audioSize => $composableBuilder(
    column: $table.audioSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get audioProgress => $composableBuilder(
    column: $table.audioProgress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pausedByUser => $composableBuilder(
    column: $table.pausedByUser,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get youtubeQualityPreset => $composableBuilder(
    column: $table.youtubeQualityPreset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnFilters(column),
  );
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
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get speed => $composableBuilder(
    column: $table.speed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get eta => $composableBuilder(
    column: $table.eta,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get savePath => $composableBuilder(
    column: $table.savePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localFilePath => $composableBuilder(
    column: $table.localFilePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tempFilePath => $composableBuilder(
    column: $table.tempFilePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get threadCount => $composableBuilder(
    column: $table.threadCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get chunks => $composableBuilder(
    column: $table.chunks,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scheduledAt => $composableBuilder(
    column: $table.scheduledAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get supportsResume => $composableBuilder(
    column: $table.supportsResume,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get speedLimitKbps => $composableBuilder(
    column: $table.speedLimitKbps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get seedingEnabled => $composableBuilder(
    column: $table.seedingEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get seedingLimited => $composableBuilder(
    column: $table.seedingLimited,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seedingLimitKbps => $composableBuilder(
    column: $table.seedingLimitKbps,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get torrentFiles => $composableBuilder(
    column: $table.torrentFiles,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get downloadPageUrl => $composableBuilder(
    column: $table.downloadPageUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mergedAudioUrl => $composableBuilder(
    column: $table.mergedAudioUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get audioSize => $composableBuilder(
    column: $table.audioSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get audioProgress => $composableBuilder(
    column: $table.audioProgress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pausedByUser => $composableBuilder(
    column: $table.pausedByUser,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get youtubeQualityPreset => $composableBuilder(
    column: $table.youtubeQualityPreset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notes => $composableBuilder(
    column: $table.notes,
    builder: (column) => ColumnOrderings(column),
  );
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
    column: $table.downloadedBytes,
    builder: (column) => column,
  );

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
    column: $table.localFilePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tempFilePath => $composableBuilder(
    column: $table.tempFilePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get threadCount => $composableBuilder(
    column: $table.threadCount,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<List<double>?, String> get chunks =>
      $composableBuilder(column: $table.chunks, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get scheduledAt => $composableBuilder(
    column: $table.scheduledAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get supportsResume => $composableBuilder(
    column: $table.supportsResume,
    builder: (column) => column,
  );

  GeneratedColumn<int> get speedLimitKbps => $composableBuilder(
    column: $table.speedLimitKbps,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get seedingEnabled => $composableBuilder(
    column: $table.seedingEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get seedingLimited => $composableBuilder(
    column: $table.seedingLimited,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seedingLimitKbps => $composableBuilder(
    column: $table.seedingLimitKbps,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<List<Map<String, dynamic>>?, String>
  get torrentFiles => $composableBuilder(
    column: $table.torrentFiles,
    builder: (column) => column,
  );

  GeneratedColumn<String> get downloadPageUrl => $composableBuilder(
    column: $table.downloadPageUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mergedAudioUrl => $composableBuilder(
    column: $table.mergedAudioUrl,
    builder: (column) => column,
  );

  GeneratedColumn<int> get audioSize =>
      $composableBuilder(column: $table.audioSize, builder: (column) => column);

  GeneratedColumn<double> get audioProgress => $composableBuilder(
    column: $table.audioProgress,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get pausedByUser => $composableBuilder(
    column: $table.pausedByUser,
    builder: (column) => column,
  );

  GeneratedColumn<String> get youtubeQualityPreset => $composableBuilder(
    column: $table.youtubeQualityPreset,
    builder: (column) => column,
  );

  GeneratedColumn<String> get notes =>
      $composableBuilder(column: $table.notes, builder: (column) => column);
}

class $$DownloadTasksTableTableManager
    extends
        RootTableManager<
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
            BaseReferences<_$AppDatabase, $DownloadTasksTable, DbDownloadTask>,
          ),
          DbDownloadTask,
          PrefetchHooks Function()
        > {
  $$DownloadTasksTableTableManager(_$AppDatabase db, $DownloadTasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadTasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadTasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadTasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
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
                Value<double> audioProgress = const Value.absent(),
                Value<bool> pausedByUser = const Value.absent(),
                Value<String?> youtubeQualityPreset = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadTasksCompanion(
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
                audioProgress: audioProgress,
                pausedByUser: pausedByUser,
                youtubeQualityPreset: youtubeQualityPreset,
                notes: notes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
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
                Value<double> audioProgress = const Value.absent(),
                Value<bool> pausedByUser = const Value.absent(),
                Value<String?> youtubeQualityPreset = const Value.absent(),
                Value<String?> notes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadTasksCompanion.insert(
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
                audioProgress: audioProgress,
                pausedByUser: pausedByUser,
                youtubeQualityPreset: youtubeQualityPreset,
                notes: notes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadTasksTableProcessedTableManager =
    ProcessedTableManager<
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
        BaseReferences<_$AppDatabase, $DownloadTasksTable, DbDownloadTask>,
      ),
      DbDownloadTask,
      PrefetchHooks Function()
    >;
typedef $$BookmarksTableCreateCompanionBuilder =
    BookmarksCompanion Function({
      required String id,
      required String title,
      required String url,
      Value<String?> folder,
      required String createdAt,
      Value<int> rowid,
    });
typedef $$BookmarksTableUpdateCompanionBuilder =
    BookmarksCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> url,
      Value<String?> folder,
      Value<String> createdAt,
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
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folder => $composableBuilder(
    column: $table.folder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
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
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folder => $composableBuilder(
    column: $table.folder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
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

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$BookmarksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BookmarksTable,
          DbBookmark,
          $$BookmarksTableFilterComposer,
          $$BookmarksTableOrderingComposer,
          $$BookmarksTableAnnotationComposer,
          $$BookmarksTableCreateCompanionBuilder,
          $$BookmarksTableUpdateCompanionBuilder,
          (
            DbBookmark,
            BaseReferences<_$AppDatabase, $BookmarksTable, DbBookmark>,
          ),
          DbBookmark,
          PrefetchHooks Function()
        > {
  $$BookmarksTableTableManager(_$AppDatabase db, $BookmarksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookmarksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookmarksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookmarksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> url = const Value.absent(),
                Value<String?> folder = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookmarksCompanion(
                id: id,
                title: title,
                url: url,
                folder: folder,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String url,
                Value<String?> folder = const Value.absent(),
                required String createdAt,
                Value<int> rowid = const Value.absent(),
              }) => BookmarksCompanion.insert(
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
        ),
      );
}

typedef $$BookmarksTableProcessedTableManager =
    ProcessedTableManager<
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
      PrefetchHooks Function()
    >;
typedef $$BrowserHistoryTableCreateCompanionBuilder =
    BrowserHistoryCompanion Function({
      required String id,
      required String url,
      required String title,
      required String visitedAt,
      Value<int> rowid,
    });
typedef $$BrowserHistoryTableUpdateCompanionBuilder =
    BrowserHistoryCompanion Function({
      Value<String> id,
      Value<String> url,
      Value<String> title,
      Value<String> visitedAt,
      Value<int> rowid,
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
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnFilters(column),
  );
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
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnOrderings(column),
  );
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
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get visitedAt =>
      $composableBuilder(column: $table.visitedAt, builder: (column) => column);
}

class $$BrowserHistoryTableTableManager
    extends
        RootTableManager<
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
            BaseReferences<
              _$AppDatabase,
              $BrowserHistoryTable,
              DbBrowserHistory
            >,
          ),
          DbBrowserHistory,
          PrefetchHooks Function()
        > {
  $$BrowserHistoryTableTableManager(
    _$AppDatabase db,
    $BrowserHistoryTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BrowserHistoryTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BrowserHistoryTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BrowserHistoryTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> url = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> visitedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BrowserHistoryCompanion(
                id: id,
                url: url,
                title: title,
                visitedAt: visitedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String url,
                required String title,
                required String visitedAt,
                Value<int> rowid = const Value.absent(),
              }) => BrowserHistoryCompanion.insert(
                id: id,
                url: url,
                title: title,
                visitedAt: visitedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BrowserHistoryTableProcessedTableManager =
    ProcessedTableManager<
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
        BaseReferences<_$AppDatabase, $BrowserHistoryTable, DbBrowserHistory>,
      ),
      DbBrowserHistory,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DownloadTasksTableTableManager get downloadTasks =>
      $$DownloadTasksTableTableManager(_db, _db.downloadTasks);
  $$BookmarksTableTableManager get bookmarks =>
      $$BookmarksTableTableManager(_db, _db.bookmarks);
  $$BrowserHistoryTableTableManager get browserHistory =>
      $$BrowserHistoryTableTableManager(_db, _db.browserHistory);
}
