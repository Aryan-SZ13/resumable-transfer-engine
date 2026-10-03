/// Interface for executing multi-step persistence workflows within an atomic transaction.
abstract interface class TransactionRunner {
  /// Executes [action] inside an atomic database transaction.
  /// If [action] throws an error, the transaction is rolled back and the error is rethrown.
  Future<T> runTransaction<T>(Future<T> Function() action);
}
