import '../models/enums.dart';
import '../models/transfer.dart';
import 'exceptions.dart';

/// Events that trigger transitions in the [TransferStateMachine].
enum TransferEventTrigger {
  queueSchedule,
  userPause,
  userResume,
  userCancel,
  retryableError,
  backoffElapsed,
  fatalError,
  allChunksCompleted,
  integrityVerified,
  integrityFailed,
  reconcileInterrupted,
}

/// The single authoritative state transition engine for [Transfer] entities.
class TransferStateMachine {
  const TransferStateMachine();

  /// Evaluates and applies a transition to [current] based on [trigger].
  /// Returns a new [Transfer] instance with the updated state and audit metadata,
  /// or throws [IllegalStateTransitionException] / [TerminalStateViolationException] / [InvariantViolationException].
  static Transfer transition(
    Transfer current,
    TransferEventTrigger trigger, {
    String? errorMessage,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now().toUtc();

    // 1. Guard Terminal States
    if (current.state.isTerminal) {
      if (current.state == TransferState.completed) {
        throw TerminalStateViolationException(
          state: current.state,
          reason:
              'A COMPLETED transfer is immutable and cannot be re-transitioned.',
        );
      }
      if (current.state == TransferState.cancelled) {
        throw TerminalStateViolationException(
          state: current.state,
          reason:
              'A CANCELLED transfer is permanently terminal and can never resurrect or transition.',
        );
      }
      if (current.state == TransferState.failed) {
        throw TerminalStateViolationException(
          state: current.state,
          reason:
              'A FAILED transfer cannot directly transition; a new transfer operation must be initiated.',
        );
      }
    }

    // 2. Evaluate State Transitions
    switch (current.state) {
      case TransferState.queued:
        switch (trigger) {
          case TransferEventTrigger.queueSchedule:
            return current.copyWith(
              state: TransferState.transferring,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userPause:
            return current.copyWith(
              state: TransferState.paused,
              pauseReason: PauseReason.userPaused,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userCancel:
            return current.copyWith(
              state: TransferState.cancelled,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case TransferState.transferring:
        switch (trigger) {
          case TransferEventTrigger.allChunksCompleted:
            // S-1 Invariant: Must prove all chunks completed before transitioning to VERIFYING
            if (current.totalChunks == 0 ||
                current.completedChunks < current.totalChunks) {
              throw InvariantViolationException(
                'Cannot transition transfer "${current.id}" to VERIFYING: '
                'only ${current.completedChunks}/${current.totalChunks} chunks are completed.',
              );
            }
            return current.copyWith(
              state: TransferState.verifying,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.retryableError:
            final nextRetry = current.retryCount + 1;
            if (nextRetry >= current.maxRetries) {
              return current.copyWith(
                state: TransferState.failed,
                retryCount: nextRetry,
                errorMessage: errorMessage ??
                    'Max retry attempts (${current.maxRetries}) exceeded',
                updatedAt: timestamp,
              );
            }
            return current.copyWith(
              state: TransferState.retrying,
              retryCount: nextRetry,
              errorMessage: errorMessage,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.fatalError:
            return current.copyWith(
              state: TransferState.failed,
              errorMessage:
                  errorMessage ?? 'Fatal unrecoverable transfer error',
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userPause:
            return current.copyWith(
              state: TransferState.paused,
              pauseReason: PauseReason.userPaused,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userCancel:
            return current.copyWith(
              state: TransferState.cancelled,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.reconcileInterrupted:
            // Cold-start unexpected interruption: auto-resumes by entering QUEUED
            return current.copyWith(
              state: TransferState.queued,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case TransferState.retrying:
        switch (trigger) {
          case TransferEventTrigger.backoffElapsed:
            return current.copyWith(
              state: TransferState.transferring,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userPause:
            return current.copyWith(
              state: TransferState.paused,
              pauseReason: PauseReason.userPaused,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userCancel:
            return current.copyWith(
              state: TransferState.cancelled,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.fatalError:
            return current.copyWith(
              state: TransferState.failed,
              errorMessage: errorMessage,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.reconcileInterrupted:
            return current.copyWith(
              state: TransferState.queued,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case TransferState.paused:
        switch (trigger) {
          case TransferEventTrigger.userResume:
            // S-2 Guard: userResume is strictly permitted only for USER_PAUSED
            if (current.pauseReason != PauseReason.userPaused) {
              _throwIllegal(
                current.state,
                trigger,
                reason:
                    'userResume requires pauseReason == USER_PAUSED, but actual reason is ${current.pauseReason?.name ?? 'null'}.',
              );
            }
            return current.copyWith(
              state: TransferState.queued,
              clearPauseReason: true,
              clearErrorMessage: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userCancel:
            return current.copyWith(
              state: TransferState.cancelled,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(
              current.state,
              trigger,
              reason: current.pauseReason == PauseReason.userPaused
                  ? 'A user-paused transfer requires explicit userResume to transition.'
                  : null,
            );
        }

      case TransferState.verifying:
        switch (trigger) {
          case TransferEventTrigger.integrityVerified:
            return current.copyWith(
              state: TransferState.completed,
              clearPauseReason: true,
              clearErrorMessage: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.integrityFailed:
            return current.copyWith(
              state: TransferState.failed,
              errorMessage: errorMessage ??
                  'Integrity verification failed (SHA-256 mismatch)',
              updatedAt: timestamp,
            );
          case TransferEventTrigger.userCancel:
            return current.copyWith(
              state: TransferState.cancelled,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          case TransferEventTrigger.reconcileInterrupted:
            // Interrupted during verification: restart verification through QUEUED
            return current.copyWith(
              state: TransferState.queued,
              clearPauseReason: true,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case TransferState.completed:
      case TransferState.failed:
      case TransferState.cancelled:
        throw TerminalStateViolationException(
          state: current.state,
          reason: 'Cannot transition from terminal state',
        );
    }
  }

  static Never _throwIllegal(
    TransferState current,
    TransferEventTrigger trigger, {
    String? reason,
  }) {
    throw IllegalStateTransitionException(
      entity: 'Transfer',
      currentState: current.name,
      attemptedTarget: trigger.name,
      reason: reason ??
          'Trigger "${trigger.name}" is not permitted from state "${current.name}".',
    );
  }
}
