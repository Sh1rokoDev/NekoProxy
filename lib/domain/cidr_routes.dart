import 'dart:io';
import 'dart:typed_data';

/// Returns the CIDRs in [routes] that are not covered by [exceptions].
/// Both lists must contain validated, canonical network prefixes.
List<String> subtractRoutePrefixes(
  List<String> routes,
  List<String> exceptions,
) {
  final excluded = exceptions.map(_RoutePrefix.parse).toList();
  return [
    for (final route in routes)
      for (final prefix in _RoutePrefix.parse(route).subtract(excluded))
        prefix.toString(),
  ];
}

class _RoutePrefix {
  const _RoutePrefix(this.bytes, this.length);

  factory _RoutePrefix.parse(String value) {
    final slash = value.indexOf('/');
    final address = InternetAddress(value.substring(0, slash));
    return _RoutePrefix(
      address.rawAddress,
      int.parse(value.substring(slash + 1)),
    );
  }

  final Uint8List bytes;
  final int length;

  bool contains(_RoutePrefix other) {
    if (bytes.length != other.bytes.length || length > other.length) {
      return false;
    }
    final wholeBytes = length ~/ 8;
    for (var index = 0; index < wholeBytes; index++) {
      if (bytes[index] != other.bytes[index]) return false;
    }
    final bits = length % 8;
    return bits == 0 ||
        ((bytes[wholeBytes] ^ other.bytes[wholeBytes]) >> (8 - bits)) == 0;
  }

  Iterable<_RoutePrefix> subtract(List<_RoutePrefix> exceptions) sync* {
    final nested = <_RoutePrefix>[];
    for (final exception in exceptions) {
      if (exception.contains(this)) return;
      if (contains(exception)) nested.add(exception);
    }
    if (nested.isEmpty) {
      yield this;
      return;
    }
    // An overlapping CIDR either contains this prefix or fits in one child.
    final upperHalf = Uint8List.fromList(bytes);
    upperHalf[length ~/ 8] |= 128 >> (length % 8);
    yield* _RoutePrefix(bytes, length + 1).subtract(nested);
    yield* _RoutePrefix(upperHalf, length + 1).subtract(nested);
  }

  @override
  String toString() =>
      '${InternetAddress.fromRawAddress(bytes).address}/$length';
}
