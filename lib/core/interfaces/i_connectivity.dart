/// Abstract contract for querying network connectivity without coupling
/// core engine services to UI-layer or feature-layer providers.
abstract class IConnectivity {
  bool get hasConnection;
}
