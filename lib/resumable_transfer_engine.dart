/// Resumable Transfer Engine — Fault-tolerant resumable file transfer core.
library resumable_transfer_engine;

// Domain Models & Enums
export 'src/domain/models/chunk.dart';
export 'src/domain/models/enums.dart';
export 'src/domain/models/transfer.dart';
export 'src/domain/models/transfer_event.dart';

// Chunk Math
export 'src/domain/chunking/chunk_calculator.dart';

// State Machine
export 'src/domain/state_machine/chunk_state_machine.dart';
export 'src/domain/state_machine/exceptions.dart';
export 'src/domain/state_machine/transfer_state_machine.dart';

// Repositories
export 'src/domain/repositories/chunk_repository.dart';
export 'src/domain/repositories/transaction_runner.dart';
export 'src/domain/repositories/transfer_event_repository.dart';
export 'src/domain/repositories/transfer_repository.dart';

// Recovery Service
export 'src/domain/recovery/cold_start_recovery_service.dart';

// SQLite Infrastructure
export 'src/infrastructure/persistence/sqlite/sqlite_transfer_database.dart';
export 'src/infrastructure/persistence/sqlite/sqlite_transfer_repository.dart';

// Transport Abstraction & Models
export 'src/domain/transport/transfer_transport.dart';
export 'src/domain/transport/transport_exceptions.dart';
export 'src/domain/transport/transport_models.dart';
export 'src/infrastructure/transport/http/http_transfer_transport.dart';

// Mock Server & Fault Injection
export 'src/mock_server/fault_injector.dart';
export 'src/mock_server/mock_transfer_server.dart';
export 'src/mock_server/server_transfer_state.dart';
