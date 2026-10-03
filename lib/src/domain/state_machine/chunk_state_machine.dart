import '../models/chunk.dart';
import '../models/enums.dart';
import 'exceptions.dart';

/// Events that trigger transitions in the [ChunkStateMachine].
enum ChunkEventTrigger {
  dispatchWorker,
  ackReceived,
  networkError,
  abortToPending,
  requeue,
}

/// Authoritative state transition engine for [Chunk] entities.
class ChunkStateMachine {
  const ChunkStateMachine();

  /// Evaluates and applies a transition to [current] based on [trigger].
  static Chunk transition(
    Chunk current,
    ChunkEventTrigger trigger, {
    String? sha256,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now().toUtc();

    // 1. Guard Terminal State
    if (current.state == ChunkState.completed) {
      throw IllegalStateTransitionException(
        entity: 'Chunk',
        currentState: current.state.name,
        attemptedTarget: trigger.name,
        reason: 'Chunk is already COMPLETED and is immutable.',
      );
    }

    // 2. Evaluate Transitions
    switch (current.state) {
      case ChunkState.pending:
        switch (trigger) {
          case ChunkEventTrigger.dispatchWorker:
            return current.copyWith(
              state: ChunkState.uploading,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case ChunkState.uploading:
        switch (trigger) {
          case ChunkEventTrigger.ackReceived:
            return current.copyWith(
              state: ChunkState.completed,
              sha256: sha256 ?? current.sha256,
              updatedAt: timestamp,
            );
          case ChunkEventTrigger.networkError:
            return current.copyWith(
              state: ChunkState.failed,
              retryCount: current.retryCount + 1,
              updatedAt: timestamp,
            );
          case ChunkEventTrigger.abortToPending:
            // Used for graceful pause or cold-start recovery of in-flight chunks
            return current.copyWith(
              state: ChunkState.pending,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case ChunkState.failed:
        switch (trigger) {
          case ChunkEventTrigger.dispatchWorker:
            return current.copyWith(
              state: ChunkState.uploading,
              updatedAt: timestamp,
            );
          case ChunkEventTrigger.requeue:
            return current.copyWith(
              state: ChunkState.pending,
              updatedAt: timestamp,
            );
          default:
            _throwIllegal(current.state, trigger);
        }

      case ChunkState.completed:
        _throwIllegal(current.state, trigger,
            reason: 'Chunk is already COMPLETED and cannot be mutated.');
    }
  }

  static Never _throwIllegal(
    ChunkState current,
    ChunkEventTrigger trigger, {
    String? reason,
  }) {
    throw IllegalStateTransitionException(
      entity: 'Chunk',
      currentState: current.name,
      attemptedTarget: trigger.name,
      reason: reason ??
          'Trigger "${trigger.name}" is not permitted from state "${current.name}".',
    );
  }
}
