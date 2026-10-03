import 'package:meta/meta.dart';
import '../models/enums.dart';
import 'transport_exceptions.dart';

/// Sealed result container representing either a successful transport operation or a typed failure.
@immutable
sealed class TransportResult<T> {
  const TransportResult();

  factory TransportResult.success(T data) = TransportSuccess<T>;
  factory TransportResult.failure(TransportException error) =
      TransportFailure<T>;

  bool get isSuccess => this is TransportSuccess<T>;
  bool get isFailure => this is TransportFailure<T>;

  T? get dataOrNull => switch (this) {
        TransportSuccess<T>(:final data) => data,
        TransportFailure<T>() => null,
      };

  TransportException? get errorOrNull => switch (this) {
        TransportSuccess<T>() => null,
        TransportFailure<T>(:final error) => error,
      };

  R when<R>({
    required R Function(T data) success,
    required R Function(TransportException error) failure,
  }) {
    return switch (this) {
      TransportSuccess<T>(:final data) => success(data),
      TransportFailure<T>(:final error) => failure(error),
    };
  }

  TransportResult<R> map<R>(R Function(T data) transform) {
    return switch (this) {
      TransportSuccess<T>(:final data) =>
        TransportResult.success(transform(data)),
      TransportFailure<T>(:final error) => TransportResult.failure(error),
    };
  }
}

final class TransportSuccess<T> extends TransportResult<T> {
  final T data;
  const TransportSuccess(this.data);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportSuccess<T> &&
          runtimeType == other.runtimeType &&
          data == other.data;

  @override
  int get hashCode => data.hashCode;

  @override
  String toString() => 'TransportSuccess($data)';
}

final class TransportFailure<T> extends TransportResult<T> {
  final TransportException error;
  const TransportFailure(this.error);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportFailure<T> &&
          runtimeType == other.runtimeType &&
          error == other.error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'TransportFailure($error)';
}

// ==========================================
// REQUEST & RESPONSE MODELS
// ==========================================

/// Request to create/register a transfer session on the remote server.
@immutable
class CreateTransferRequest {
  final String transferId;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final int chunkSize;
  final int totalChunks;
  final String fileSha256;

  CreateTransferRequest({
    required this.transferId,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.chunkSize,
    required this.totalChunks,
    required this.fileSha256,
  }) {
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize', 'Must be non-negative');
    }
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive');
    }
    if (totalChunks < 0) {
      throw ArgumentError.value(
          totalChunks, 'totalChunks', 'Must be non-negative');
    }
  }
}

/// Server acknowledgement for a created transfer session.
@immutable
class CreateTransferResponse {
  final String transferId;
  final String status;
  final int chunkSize;
  final int totalChunks;
  final String protocolVersion;

  const CreateTransferResponse({
    required this.transferId,
    required this.status,
    required this.chunkSize,
    required this.totalChunks,
    this.protocolVersion = '1.0',
  });
}

/// Request to upload a single chunk payload.
@immutable
class UploadChunkRequest {
  final String transferId;
  final int chunkIndex;
  final int byteOffset;
  final int byteLength;
  final String sha256;
  final String idempotencyKey;
  final List<int> payload;

  UploadChunkRequest({
    required this.transferId,
    required this.chunkIndex,
    required this.byteOffset,
    required this.byteLength,
    required this.sha256,
    required this.idempotencyKey,
    required this.payload,
  }) {
    if (chunkIndex < 0) {
      throw ArgumentError.value(
          chunkIndex, 'chunkIndex', 'Must be non-negative');
    }
    if (byteOffset < 0) {
      throw ArgumentError.value(
          byteOffset, 'byteOffset', 'Must be non-negative');
    }
    if (byteLength < 0) {
      throw ArgumentError.value(
          byteLength, 'byteLength', 'Must be non-negative');
    }
    if (payload.length != byteLength) {
      throw ArgumentError(
        'Payload length (${payload.length}) must strictly equal byteLength ($byteLength).',
      );
    }
  }
}

/// Distinguishes a newly accepted chunk from an idempotent duplicate replay.
enum UploadChunkStatus {
  accepted,
  idempotentReplay,
}

/// Server response for an uploaded chunk.
@immutable
class UploadChunkResponse {
  final String transferId;
  final int chunkIndex;
  final UploadChunkStatus status;
  final String sha256;
  final int bytesReceived;

  const UploadChunkResponse({
    required this.transferId,
    required this.chunkIndex,
    required this.status,
    required this.sha256,
    required this.bytesReceived,
  });
}

/// Response containing current server-side state of a transfer session.
@immutable
class TransferStatusResponse {
  final String transferId;
  final String serverState;
  final Set<int> completedChunkIndexes;
  final int completedBytes;
  final int totalBytes;
  final bool isFinalized;
  final String serverFileSha256;

  const TransferStatusResponse({
    required this.transferId,
    required this.serverState,
    required this.completedChunkIndexes,
    required this.completedBytes,
    required this.totalBytes,
    required this.isFinalized,
    required this.serverFileSha256,
  });
}

/// Request to verify full file assembly and mark transfer finalized.
@immutable
class FinalizeTransferRequest {
  final String transferId;
  final String expectedFileSha256;

  const FinalizeTransferRequest({
    required this.transferId,
    required this.expectedFileSha256,
  });
}

/// Server response after reassembly and checksum verification.
@immutable
class FinalizeTransferResponse {
  final String transferId;
  final bool isVerified;
  final int verifiedBytes;
  final String actualFileSha256;

  const FinalizeTransferResponse({
    required this.transferId,
    required this.isVerified,
    required this.verifiedBytes,
    required this.actualFileSha256,
  });
}

/// Request to download a specific chunk range from the server.
@immutable
class DownloadChunkRequest {
  final String transferId;
  final int chunkIndex;
  final int byteOffset;
  final int byteLength;

  DownloadChunkRequest({
    required this.transferId,
    required this.chunkIndex,
    required this.byteOffset,
    required this.byteLength,
  }) {
    if (chunkIndex < 0) {
      throw ArgumentError.value(
          chunkIndex, 'chunkIndex', 'Must be non-negative');
    }
    if (byteOffset < 0) {
      throw ArgumentError.value(
          byteOffset, 'byteOffset', 'Must be non-negative');
    }
    if (byteLength < 0) {
      throw ArgumentError.value(
          byteLength, 'byteLength', 'Must be non-negative');
    }
  }
}

/// Response containing downloaded chunk binary payload and server checksum.
@immutable
class DownloadChunkResponse {
  final String transferId;
  final int chunkIndex;
  final int byteOffset;
  final int byteLength;
  final String sha256;
  final List<int> payload;

  const DownloadChunkResponse({
    required this.transferId,
    required this.chunkIndex,
    required this.byteOffset,
    required this.byteLength,
    required this.sha256,
    required this.payload,
  });
}
