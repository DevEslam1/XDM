import 'package:dmx/features/downloads/domain/state_machine/domain_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DomainStateMachine Transition Table', () {
    late TransitionAuditLog auditLog;

    setUp(() {
      auditLog = TransitionAuditLog();
      auditLog.clear();
    });

    // Exact transition matrix per ARCH-1 specifications
    final expectedTransitions = <DomainDownloadState, Set<DomainDownloadState>>{
      DomainDownloadState.idle: {
        DomainDownloadState.idle,
        DomainDownloadState.queued,
        DomainDownloadState.starting,
        DomainDownloadState.downloading,
        DomainDownloadState.failed,
      },
      DomainDownloadState.queued: {
        DomainDownloadState.queued,
        DomainDownloadState.starting,
        DomainDownloadState.downloading,
        DomainDownloadState.paused,
        DomainDownloadState.failed,
        DomainDownloadState.idle,
      },
      DomainDownloadState.starting: {
        DomainDownloadState.starting,
        DomainDownloadState.downloading,
        DomainDownloadState.merging,
        DomainDownloadState.paused,
        DomainDownloadState.failed,
        DomainDownloadState.retrying,
      },
      DomainDownloadState.downloading: {
        DomainDownloadState.downloading,
        DomainDownloadState.queued,
        DomainDownloadState.paused,
        DomainDownloadState.merging,
        DomainDownloadState.completing,
        DomainDownloadState.completed,
        DomainDownloadState.failed,
        DomainDownloadState.retrying,
      },
      DomainDownloadState.paused: {
        DomainDownloadState.paused,
        DomainDownloadState.queued,
        DomainDownloadState.starting,
        DomainDownloadState.downloading,
        DomainDownloadState.failed,
        DomainDownloadState.idle,
      },
      DomainDownloadState.merging: {
        DomainDownloadState.merging,
        DomainDownloadState.completing,
        DomainDownloadState.completed,
        DomainDownloadState.failed,
        DomainDownloadState.paused,
        DomainDownloadState.retrying,
      },
      DomainDownloadState.completing: {
        DomainDownloadState.completing,
        DomainDownloadState.completed,
        DomainDownloadState.failed,
      },
      DomainDownloadState.completed: {
        DomainDownloadState.completed,
        DomainDownloadState.queued,
        DomainDownloadState.downloading,
        DomainDownloadState.idle,
        DomainDownloadState.paused,
      },
      DomainDownloadState.failed: {
        DomainDownloadState.failed,
        DomainDownloadState.queued,
        DomainDownloadState.starting,
        DomainDownloadState.retrying,
        DomainDownloadState.idle,
      },
      DomainDownloadState.retrying: {
        DomainDownloadState.retrying,
        DomainDownloadState.starting,
        DomainDownloadState.downloading,
        DomainDownloadState.paused,
        DomainDownloadState.failed,
      },
    };

    test('validates every (from, to) state pair across all DomainDownloadState values', () async {
      for (final fromState in DomainDownloadState.values) {
        final allowedTargets = expectedTransitions[fromState] ?? {};

        for (final toState in DomainDownloadState.values) {
          final isAllowed = allowedTargets.contains(toState);
          expect(
            DomainStateMachine.canTransition(fromState, toState),
            isAllowed,
            reason: '$fromState -> $toState should be ${isAllowed ? 'allowed' : 'rejected'}',
          );

          final sm = DomainStateMachine(
            taskId: 'test-task-${fromState.name}-${toState.name}',
            initialState: fromState,
            auditLog: auditLog,
          );

          if (isAllowed) {
            final entryCountBefore = auditLog.entries.length;
            sm.transition(
              toState,
              command: 'test-command',
              caller: 'test-caller',
              engine: 'test-engine',
            );
            expect(sm.currentState, toState);
            expect(auditLog.entries.length, entryCountBefore + 1);
            final latest = auditLog.entries.last;
            expect(latest.from, fromState);
            expect(latest.to, toState);
            expect(latest.command, 'test-command');
          } else {
            expect(
              () => sm.transition(toState, command: 'illegal-command'),
              throwsA(
                isA<InvalidTransitionError>()
                    .having((e) => e.taskId, 'taskId', sm.taskId)
                    .having((e) => e.fromState, 'fromState', fromState)
                    .having((e) => e.command, 'command', 'illegal-command'),
              ),
            );
          }
        }
      }
    });
  });
}
