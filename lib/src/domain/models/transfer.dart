import 'package:meta/meta.dart';
import 'enums.dart';

/// Represents a file transfer operation (upload or download) with persistent metadata.
@immutable
class Transfer {
  final String id;
  final String fileName;
  final String filePath;
  final int fileSize;
  final TransferDirection direction;
  final TransferState state;
  final int chunkSize;
  final int totalChunks;
  final int completedChunks;
  final int bytesTransferred;
  final String fileSha256;
  final int retryCount;
  final int maxRetries;
  final String? errorMessage;
  final PauseReason? pauseReason;
  final DateTime createdAt;
  final DateTime updatedAt;

  Transfer({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.direction,
    required this.state,
    required this.chunkSize,
    required this.totalChunks,
    this.completedChunks = 0,
    this.bytesTransferred = 0,
    required this.fileSha256,
    this.retryCount = 0,
    this.maxRetries = 5,
    this.errorMessage,
    this.pauseReason,
    required this.createdAt,
    required this.updatedAt,
  }) {
    if (fileSize < 0) {
      throw ArgumentError.value(
          fileSize, 'fileSize', 'fileSize must be non-negative');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(
          chunkSize, 'chunkSize', 'chunkSize must be positive');
    }
    if (totalChunks < 0) {
      throw ArgumentError.value(
          totalChunks, 'totalChunks', 'totalChunks must be non-negative');
    }
    if (completedChunks < 0) {
      throw ArgumentError.value(completedChunks, 'completedChunks',
          'completedChunks must be non-negative');
    }
    if (completedChunks > totalChunks && totalChunks > 0) {
      throw ArgumentError.value(
        completedChunks,
        'completedChunks',
        'completedChunks ($completedChunks) cannot exceed totalChunks ($totalChunks)',
      );
    }
    if (bytesTransferred < 0) {
      throw ArgumentError.value(bytesTransferred, 'bytesTransferred',
          'bytesTransferred must be non-negative');
    }
    if (bytesTransferred > fileSize && fileSize > 0) {
      throw ArgumentError.value(
        bytesTransferred,
        'bytesTransferred',
        'bytesTransferred ($bytesTransferred) cannot exceed fileSize ($fileSize)',
      );
    }
    if (retryCount < 0) {
      throw ArgumentError.value(
          retryCount, 'retryCount', 'retryCount must be non-negative');
    }
    if (maxRetries < 0) {
      throw ArgumentError.value(
          maxRetries, 'maxRetries', 'maxRetries must be non-negative');
    }
  }

  /// Derived progress ratio between 0.0 and 1.0.
  double get progressFraction {
    if (fileSize == 0) return 1.0;
    final fraction = bytesTransferred / fileSize;
    return fraction.clamp(0.0, 1.0);
  }

  /// Derived human-readable progress percentage (e.g. 42.5%).
  double get progressPercentage => progressFraction * 100.0;

  /// Whether all chunks have been completed.
  bool get allChunksCompleted =>
      totalChunks > 0 && completedChunks >= totalChunks;

  /// Whether the transfer is in an unmodifiable terminal state.
  bool get isTerminal => state.isTerminal;

  Transfer copyWith({
    String? id,
    String? fileName,
    String? filePath,
    int? fileSize,
    TransferDirection? direction,
    TransferState? state,
    int? chunkSize,
    int? totalChunks,
    int? completedChunks,
    int? bytesTransferred,
    String? fileSha256,
    int? retryCount,
    int? maxRetries,
    String? errorMessage,
    bool clearErrorMessage = false,
    PauseReason? pauseReason,
    bool clearPauseReason = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Transfer(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      direction: direction ?? this.direction,
      state: state ?? this.state,
      chunkSize: chunkSize ?? this.chunkSize,
      totalChunks: totalChunks ?? this.totalChunks,
      completedChunks: completedChunks ?? this.completedChunks,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      fileSha256: fileSha256 ?? this.fileSha256,
      retryCount: retryCount ?? this.retryCount,
      maxRetries: maxRetries ?? this.maxRetries,
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      pauseReason: clearPauseReason ? null : (pauseReason ?? this.pauseReason),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Transfer &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          fileName == other.fileName &&
          filePath == other.filePath &&
          fileSize == other.fileSize &&
          direction == other.direction &&
          state == other.state &&
          chunkSize == other.chunkSize &&
          totalChunks == other.totalChunks &&
          completedChunks == other.completedChunks &&
          bytesTransferred == other.bytesTransferred &&
          fileSha256 == other.fileSha256 &&
          retryCount == other.retryCount &&
          maxRetries == other.maxRetries &&
          errorMessage == other.errorMessage &&
          pauseReason == other.pauseReason &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hashAll([
        id,
        fileName,
        filePath,
        fileSize,
        direction,
        state,
        chunkSize,
        totalChunks,
        completedChunks,
        bytesTransferred,
        fileSha256,
        retryCount,
        maxRetries,
        errorMessage,
        pauseReason,
        createdAt,
        updatedAt,
      ]);

  @override
  String toString() =>
      'Transfer(id: $id, name: $fileName, direction: ${direction.name}, state: ${state.name}, progress: ${progressPercentage.toStringAsFixed(1)}%, chunks: $completedChunks/$totalChunks)';
}
