import 'transport_models.dart';

/// Contract for transferring files and chunks across the network.
/// Translates wire interactions into strongly-typed [TransportResult]s.
///
/// NOTE: The transport layer solely executes and reports network interactions.
/// It deliberately DOES NOT own retry policies, backoff timers, or orchestration loops.
abstract interface class TransferTransport {
  /// Registers or initializes a transfer session on the remote server.
  Future<TransportResult<CreateTransferResponse>> createTransfer(
    CreateTransferRequest request,
  );

  /// Uploads a single byte chunk with verification and idempotency headers.
  Future<TransportResult<UploadChunkResponse>> uploadChunk(
    UploadChunkRequest request,
  );

  /// Queries the server's manifest of completed chunks and verified progress.
  Future<TransportResult<TransferStatusResponse>> getTransferStatus(
    String transferId,
  );

  /// Instructs the server to verify the reassembled file's SHA-256 integrity and mark complete.
  Future<TransportResult<FinalizeTransferResponse>> finalizeTransfer(
    FinalizeTransferRequest request,
  );

  /// Downloads a specific byte chunk with server-verified checksum validation.
  Future<TransportResult<DownloadChunkResponse>> downloadChunk(
    DownloadChunkRequest request,
  );
}
