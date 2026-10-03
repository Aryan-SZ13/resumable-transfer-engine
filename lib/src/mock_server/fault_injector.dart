import 'package:meta/meta.dart';

/// Available deterministic fault actions that can be injected by tests.
@immutable
sealed class FaultAction {
  const FaultAction();

  /// Closes the incoming connection immediately before parsing or processing.
  const factory FaultAction.dropConnectionBeforeProcessing() =
      DropConnectionBeforeProcessingFault;

  /// Delays the response by [delay] to trigger a client-side timeout.
  const factory FaultAction.timeout(Duration delay) = TimeoutFault;

  /// Returns an HTTP error status code (e.g. 500, 503, 429).
  const factory FaultAction.httpStatus(
    int statusCode, {
    String message,
  }) = HttpStatusFault;

  /// Crucial failure scenario:
  /// The server successfully processes and persists the chunk, but deliberately
  /// drops the connection before transmitting the HTTP 200/201 response.
  const factory FaultAction.dropResponseAfterProcessing() =
      DropResponseAfterProcessingFault;

  /// Injects a corrupt checksum response or checksum mismatch check.
  const factory FaultAction.corruptChecksum() = CorruptChecksumFault;
}

final class DropConnectionBeforeProcessingFault extends FaultAction {
  const DropConnectionBeforeProcessingFault();
}

final class TimeoutFault extends FaultAction {
  final Duration delay;
  const TimeoutFault(this.delay);
}

final class HttpStatusFault extends FaultAction {
  final int statusCode;
  final String message;
  const HttpStatusFault(this.statusCode,
      {this.message = 'Injected Server Error'});
}

final class DropResponseAfterProcessingFault extends FaultAction {
  const DropResponseAfterProcessingFault();
}

final class CorruptChecksumFault extends FaultAction {
  const CorruptChecksumFault();
}

/// Manages deterministic fault injection rules for the mock server.
class FaultInjector {
  FaultAction? _nextRequestFault;
  final Map<String, FaultAction> _chunkFaults = {};
  final Map<String, FaultAction> _transferFaults = {};

  /// Injects a fault on the very next HTTP request handled by the server.
  void failNextRequest(FaultAction action) {
    _nextRequestFault = action;
  }

  /// Injects a fault specifically targeting a given chunk upload.
  void failChunk({
    required String transferId,
    required int chunkIndex,
    required FaultAction action,
  }) {
    _chunkFaults['$transferId:$chunkIndex'] = action;
  }

  /// Convenience method to configure the drop-response-after-processing failure mode for a specific chunk.
  void dropResponseAfterChunk({
    required String transferId,
    required int chunkIndex,
  }) {
    failChunk(
      transferId: transferId,
      chunkIndex: chunkIndex,
      action: const FaultAction.dropResponseAfterProcessing(),
    );
  }

  /// Injects a fault targeting all operations on a specific transfer ID.
  void failTransfer({
    required String transferId,
    required FaultAction action,
  }) {
    _transferFaults[transferId] = action;
  }

  /// Evaluates and consumes any active fault rule matching the incoming request context.
  FaultAction? consumeFault({
    String? transferId,
    int? chunkIndex,
  }) {
    // 1. One-off next request fault takes top priority
    if (_nextRequestFault != null) {
      final fault = _nextRequestFault;
      _nextRequestFault = null;
      return fault;
    }

    // 2. Chunk-specific fault
    if (transferId != null && chunkIndex != null) {
      final key = '$transferId:$chunkIndex';
      final chunkFault = _chunkFaults.remove(key);
      if (chunkFault != null) {
        return chunkFault;
      }
    }

    // 3. Transfer-wide fault
    if (transferId != null) {
      final transferFault = _transferFaults.remove(transferId);
      if (transferFault != null) {
        return transferFault;
      }
    }

    return null;
  }

  /// Clears all active fault rules.
  void clear() {
    _nextRequestFault = null;
    _chunkFaults.clear;
    _transferFaults.clear();
  }
}
