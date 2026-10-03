/// Strongly-typed domain enumerations for the Resumable Transfer Engine.
library;

/// Direction of a file transfer.
enum TransferDirection {
  upload,
  download;

  static TransferDirection fromString(String value) {
    return TransferDirection.values.firstWhere(
      (e) => e.name.toUpperCase() == value.toUpperCase(),
      orElse: () => throw ArgumentError('Unknown TransferDirection: $value'),
    );
  }
}

/// Lifecycle states of a [Transfer].
enum TransferState {
  queued,
  transferring,
  retrying,
  paused,
  verifying,
  completed,
  failed,
  cancelled;

  /// Whether this transfer is in an unmodifiable terminal state.
  bool get isTerminal =>
      this == TransferState.completed ||
      this == TransferState.failed ||
      this == TransferState.cancelled;

  /// Whether this transfer is actively in-flight or waiting on backoff timer.
  bool get isActive =>
      this == TransferState.transferring ||
      this == TransferState.retrying ||
      this == TransferState.verifying;

  /// Whether this transfer can be resumed by the user.
  bool get canResume => this == TransferState.paused;

  static TransferState fromString(String value) {
    return TransferState.values.firstWhere(
      (e) => e.name.toUpperCase() == value.toUpperCase(),
      orElse: () => throw ArgumentError('Unknown TransferState: $value'),
    );
  }
}

/// Clarifies the exact cause of a transfer entering or being in the paused state.
/// Crucial for distinguishing USER_PAUSED from INTERRUPTED.
enum PauseReason {
  userPaused,
  interrupted;

  static PauseReason? fromString(String? value) {
    if (value == null) return null;
    return PauseReason.values.firstWhere(
      (e) =>
          e.name.toUpperCase() == value.toUpperCase() ||
          (e == PauseReason.userPaused &&
              value.toUpperCase() == 'USER_PAUSED') ||
          (e == PauseReason.interrupted &&
              value.toUpperCase() == 'INTERRUPTED'),
      orElse: () => throw ArgumentError('Unknown PauseReason: $value'),
    );
  }

  String toDbValue() {
    switch (this) {
      case PauseReason.userPaused:
        return 'USER_PAUSED';
      case PauseReason.interrupted:
        return 'INTERRUPTED';
    }
  }
}

/// Lifecycle states of an individual [Chunk].
enum ChunkState {
  pending,
  uploading,
  completed,
  failed;

  /// Whether this chunk has reached permanent completion.
  bool get isCompleted => this == ChunkState.completed;

  /// Whether this chunk is in-flight on the wire.
  bool get isUploading => this == ChunkState.uploading;

  static ChunkState fromString(String value) {
    return ChunkState.values.firstWhere(
      (e) => e.name.toUpperCase() == value.toUpperCase(),
      orElse: () => throw ArgumentError('Unknown ChunkState: $value'),
    );
  }
}

/// Audit event types for [TransferEvent].
enum TransferEventType {
  created,
  started,
  chunkCompleted,
  chunkFailed,
  retryScheduled,
  paused,
  resumed,
  verifying,
  completed,
  failed,
  cancelled,
  reconciled;

  static TransferEventType fromString(String value) {
    final normalized = value.replaceAll('_', '').toUpperCase();
    return TransferEventType.values.firstWhere(
      (e) => e.name.toUpperCase() == normalized,
      orElse: () => throw ArgumentError('Unknown TransferEventType: $value'),
    );
  }

  String toDbString() {
    switch (this) {
      case TransferEventType.created:
        return 'CREATED';
      case TransferEventType.started:
        return 'STARTED';
      case TransferEventType.chunkCompleted:
        return 'CHUNK_COMPLETED';
      case TransferEventType.chunkFailed:
        return 'CHUNK_FAILED';
      case TransferEventType.retryScheduled:
        return 'RETRY_SCHEDULED';
      case TransferEventType.paused:
        return 'PAUSED';
      case TransferEventType.resumed:
        return 'RESUMED';
      case TransferEventType.verifying:
        return 'VERIFYING';
      case TransferEventType.completed:
        return 'COMPLETED';
      case TransferEventType.failed:
        return 'FAILED';
      case TransferEventType.cancelled:
        return 'CANCELLED';
      case TransferEventType.reconciled:
        return 'RECONCILED';
    }
  }
}
