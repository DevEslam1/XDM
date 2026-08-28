import 'dart:math';
import 'package:dmx/features/downloads/domain/state_machine/domain_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Domain State Machine Exhaustive Matrix & Property Tests', () {
    test('Verifies exhaustive state transition matrix', () {
      for (final fromState in DomainDownloadState.values) {
        for (final toState in DomainDownloadState.values) {
          final sm = DomainStateMachine(
            taskId: 'test_task',
            initialState: fromState,
          );

          final isValid = DomainStateMachine.canTransition(fromState, toState);
          if (isValid) {
            expect(
              () => sm.transition(toState),
              returnsNormally,
              reason:
                  'Transition $fromState -> $toState is valid and should succeed',
            );
            expect(sm.currentState, equals(toState));
          } else {
            expect(
              () => sm.transition(toState),
              throwsA(isA<InvalidTransitionError>()),
              reason:
                  'Transition $fromState -> $toState is invalid and must throw InvalidTransitionError',
            );
            expect(sm.currentState, equals(fromState));
          }
        }
      }
    });

    test('Self-transition is permitted as a no-op state preservation', () {
      for (final state in DomainDownloadState.values) {
        expect(
          DomainStateMachine.canTransition(state, state),
          isTrue,
          reason: 'Self-transition $state -> $state is legal',
        );
      }
    });

    test(
        'Property-based randomized state machine random-walk invariant testing',
        () {
      final random = Random(42);
      const allStates = DomainDownloadState.values;

      for (var run = 0; run < 100; run++) {
        final startState = allStates[random.nextInt(allStates.length)];
        final sm = DomainStateMachine(
            taskId: 'prop_test_$run', initialState: startState);

        for (var step = 0; step < 20; step++) {
          final targetState = allStates[random.nextInt(allStates.length)];
          final current = sm.currentState;
          final can = DomainStateMachine.canTransition(current, targetState);

          if (can) {
            sm.transition(targetState);
            expect(sm.currentState, equals(targetState));
          } else {
            expect(() => sm.transition(targetState),
                throwsA(isA<InvalidTransitionError>()));
            expect(sm.currentState, equals(current));
          }
        }
      }
    });
  });
}
