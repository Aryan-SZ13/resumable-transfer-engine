/// Domain exceptions for invalid state machine operations and invariant violations.
library;

import '../models/enums.dart';

/// Thrown when an illegal transition is attempted on a Transfer or Chunk state machine.
class IllegalStateTransitionException implements Exception {
  final String entity;
  final String currentState;
  final String attemptedTarget;
  final String reason;

  const IllegalStateTransitionException({
    required this.entity,
    required this.currentState,
    required this.attemptedTarget,
    required this.reason,
  });

  @override
  String toString() =>
      'IllegalStateTransitionException[$entity]: Cannot transition from "$currentState" to "$attemptedTarget". Reason: $reason';
}

/// Thrown when a mutation is attempted on a terminal state (COMPLETED or CANCELLED).
class TerminalStateViolationException implements Exception {
  final TransferState state;
  final String reason;

  const TerminalStateViolationException({
    required this.state,
    required this.reason,
  });

  @override
  String toString() =>
      'TerminalStateViolationException: State "${state.name}" is permanent and cannot be modified. Reason: $reason';
}

/// Thrown when an invariant (e.g. progress consistency, chunk count check) is violated.
class InvariantViolationException implements Exception {
  final String message;

  const InvariantViolationException(this.message);

  @override
  String toString() => 'InvariantViolationException: $message';
}
