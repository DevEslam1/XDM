import 'package:dmx/features/downloads/domain/commands/download_commands.dart';
import 'package:dmx/features/downloads/domain/models/domain_download_state.dart';
import 'package:dmx/features/downloads/domain/state_machine/domain_state_machine.dart';
import 'package:dmx/features/downloads/domain/state_machine/transition_audit_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransitionAuditLog User Journey Test', () {
    late TransitionAuditLog auditLog;

    setUp(() {
      auditLog = TransitionAuditLog();
      auditLog.clear();
    });

    test('captures from/to/command/caller/engine for a full scripted user journey', () async {
      const taskId = 'journey-task-101';
      final sm = DomainStateMachine(
        taskId: taskId,
        initialState: DomainDownloadState.idle,
        auditLog: auditLog,
      );

      final capturedStreamEntries = <TransitionAuditLogEntry>[];
      final subscription = auditLog.stream.listen((entry) {
        capturedStreamEntries.add(entry);
      });

      // 1. Task Enqueued
      await sm.transition(
        DomainDownloadState.queued,
        command: const StartTask(taskId),
        caller: 'UI_AddDialog',
      );

      // 2. Queue Engine Starts Task
      await sm.transition(
        DomainDownloadState.starting,
        command: const StartTask(taskId),
        caller: 'DownloadQueueEngine',
        engine: 'HttpDownloadEngine',
      );

      // 3. Engine confirms connection and begins downloading
      await sm.transition(
        DomainDownloadState.downloading,
        command: 'EngineConnectSuccess',
        caller: 'HttpDownloadEngine',
        engine: 'HttpDownloadEngine',
      );

      // 4. User Pauses Task
      await sm.transition(
        DomainDownloadState.paused,
        command: const PauseTask(taskId, reason: 'userRequested'),
        reason: 'userRequested',
        caller: 'UI_DownloadCard',
      );

      // 5. User Resumes Task
      await sm.transition(
        DomainDownloadState.queued,
        command: const ResumeTask(taskId),
        caller: 'UI_DownloadCard',
      );

      // 6. Started again
      await sm.transition(
        DomainDownloadState.starting,
        command: const StartTask(taskId),
        caller: 'DownloadQueueEngine',
      );
      await sm.transition(
        DomainDownloadState.downloading,
        command: 'EngineConnectSuccess',
        caller: 'HttpDownloadEngine',
      );

      // 7. Video stream completes, moves to merging
      await sm.transition(
        DomainDownloadState.merging,
        command: 'MuxBegin',
        caller: 'FFmpegMuxService',
        engine: 'FFmpegKit',
      );

      // 8. Completing
      await sm.transition(
        DomainDownloadState.completing,
        command: 'MuxSuccess',
        caller: 'FFmpegMuxService',
      );

      // 9. Completed
      await sm.transition(
        DomainDownloadState.completed,
        command: 'FinalizeSnapshot',
        caller: 'TaskExecutor',
      );

      // Allow stream microtasks to fire
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await subscription.cancel();

      expect(auditLog.entries.length, 10);
      expect(capturedStreamEntries.length, 10);

      expect(auditLog.entries[0].from, DomainDownloadState.idle);
      expect(auditLog.entries[0].to, DomainDownloadState.queued);
      expect(auditLog.entries[0].caller, 'UI_AddDialog');

      expect(auditLog.entries[1].from, DomainDownloadState.queued);
      expect(auditLog.entries[1].to, DomainDownloadState.starting);
      expect(auditLog.entries[1].engine, 'HttpDownloadEngine');

      expect(auditLog.entries[2].from, DomainDownloadState.starting);
      expect(auditLog.entries[2].to, DomainDownloadState.downloading);

      expect(auditLog.entries[3].from, DomainDownloadState.downloading);
      expect(auditLog.entries[3].to, DomainDownloadState.paused);

      expect(auditLog.entries[4].from, DomainDownloadState.paused);
      expect(auditLog.entries[4].to, DomainDownloadState.queued);

      expect(auditLog.entries[5].from, DomainDownloadState.queued);
      expect(auditLog.entries[5].to, DomainDownloadState.starting);

      expect(auditLog.entries[6].from, DomainDownloadState.starting);
      expect(auditLog.entries[6].to, DomainDownloadState.downloading);

      expect(auditLog.entries[7].from, DomainDownloadState.downloading);
      expect(auditLog.entries[7].to, DomainDownloadState.merging);
      expect(auditLog.entries[7].engine, 'FFmpegKit');

      expect(auditLog.entries[8].from, DomainDownloadState.merging);
      expect(auditLog.entries[8].to, DomainDownloadState.completing);

      expect(auditLog.entries[9].from, DomainDownloadState.completing);
      expect(auditLog.entries[9].to, DomainDownloadState.completed);
    });
  });
}
