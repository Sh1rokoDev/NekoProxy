import 'dart:async';

class ProxyApplyResult {
  const ProxyApplyResult({required this.ok, this.error});

  final bool ok;
  final String? error;
}

abstract interface class SystemProxy {
  FutureOr<ProxyApplyResult> enable(int port);
  FutureOr<ProxyApplyResult> disable();
  FutureOr<ProxyApplyResult> restoreIfOwned();
}
