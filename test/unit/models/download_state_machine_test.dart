import 'package:dmx/features/downloads/models/download_state_machine.dart';
import 'package:dmx/features/downloads/models/download_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadStateMachine', () {
    test('initializes with idle state by default', () {
      final sm = DownloadStateMachine(taskId: 'task-1');
      expect(sm.currentState, DownloadState.idle);
      sm.dispose();
    });

    test('valid lifecycle transitions succeed and emit events', () async {
      final sm = DownloadStateMachine(taskId: 'task-1');
      final events = <DownloadStateTransition>[];
      final sub = sm.transitions.listen(events.add);

      expect(sm.transition(DownloadState.queued, reason: 'user added'), isTrue);
      expect(sm.currentState, DownloadState.queued);

      expect(sm.transition(DownloadState.starting, reason: 'engine picked up'), isTrue);
      expect(sm.currentState, DownloadState.starting);

      expect(sm.transition(DownloadState.downloading, reason: 'data stream open'), isTrue);
      expect(sm.currentState, DownloadState.downloading);

      expect(sm.transition(DownloadState.paused, reason: 'user paused'), isTrue);
      expect(sm.currentState, DownloadState.paused);

      expect(sm.transition(DownloadState.downloading, reason: 'user resumed'), isTrue);
      expect(sm.currentState, DownloadState.downloading);

      expect(sm.transition(DownloadState.completing, reason: 'bytes finished'), isTrue);
      expect(sm.currentState, DownloadState.completing);

      expect(sm.transition(DownloadState.completed, reason: 'file finalized'), isTrue);
      expect(sm.currentState, DownloadState.completed);

      await Future.delayed(const Duration(milliseconds: 10));
      expect(events.length, 7);
      expect(events.first.from, DownloadState.idle);
      expect(events.first.to, DownloadState.queued);
      expect(events.last.to, DownloadState.completed);

      await sub.cancel();
      sm.dispose();
    });

    test('invalid transitions are rejected', () {
      final sm = DownloadStateMachine(
        taskId: 'task-2',
        initialState: DownloadState.idle,
      );

      // Cannot jump from idle directly to completed
      expect(sm.transition(DownloadState.completed), isFalse);
      expect(sm.currentState, DownloadState.idle);

      // Cannot jump from completed to merging
      final smCompleted = DownloadStateMachine(
        taskId: 'task-3',
        initialState: DownloadState.completed,
      );
      expect(smCompleted.transition(DownloadState.merging), isFalse);
      expect(smCompleted.currentState, DownloadState.completed);

      sm.dispose();
      smCompleted.dispose();
    });

    test('bidirectional mapping between DownloadStatus and DownloadState', () {
      expect(
        DownloadStateMachine.fromStatus(DownloadStatus.queued),
        DownloadState.queued,
      );
      expect(
        DownloadStateMachine.fromStatus(DownloadStatus.downloading),
        DownloadState.downloading,
      );
      expect(
        DownloadStateMachine.fromStatus(DownloadStatus.paused),
        DownloadState.paused,
      );
      expect(
        DownloadStateMachine.fromStatus(DownloadStatus.completed),
        DownloadState.completed,
      );
      expect(
        DownloadStateMachine.fromStatus(DownloadStatus.failed),
        DownloadState.failed,
      );
      expect(
        DownloadStateMachine.fromStatus(DownloadStatus.merging),
        DownloadState.merging,
      );

      expect(
        DownloadStateMachine.toStatus(DownloadState.downloading),
        DownloadStatus.downloading,
      );
      expect(
        DownloadStateMachine.toStatus(DownloadState.paused),
        DownloadStatus.paused,
      );
      expect(
        DownloadStateMachine.toStatus(DownloadState.completed),
        DownloadStatus.completed,
      );
    });

    test('canTransitionStatus enforces valid status transitions and blocks illegal ones', () {
      // Allowed transitions
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.queued, DownloadStatus.downloading), isTrue);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.downloading, DownloadStatus.paused), isTrue);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.downloading, DownloadStatus.merging), isTrue);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.merging, DownloadStatus.completed), isTrue);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.downloading, DownloadStatus.completed), isTrue);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.paused, DownloadStatus.downloading), isTrue);

      // Blocked / illegal transitions
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.completed, DownloadStatus.paused), isFalse);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.completed, DownloadStatus.merging), isFalse);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.failed, DownloadStatus.completed), isFalse);
      expect(DownloadStateMachine.canTransitionStatus(DownloadStatus.merging, DownloadStatus.queued), isFalse);
    });
  });
}
