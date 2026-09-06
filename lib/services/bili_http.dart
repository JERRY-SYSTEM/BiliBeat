import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'runtime_health.dart';

/// The desktop-Chrome user-agent Bilibili's APIs expect. Their risk control
/// rejects requests that look like a bare Dart http client, so every service
/// that talks to them sends this exact string.
const kBiliUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

/// Shared request policy. Raw clients have operation-scoped lifetimes, avoiding
/// permanently occupied connection pools after stalled background requests.
BiliHttpClient biliHttpClient({
  Duration connectionTimeout = const Duration(seconds: 10),
  Duration idleTimeout = const Duration(seconds: 30),
  int maxConnectionsPerHost = 4,
}) => BiliHttpClient(connectionTimeout, idleTimeout, maxConnectionsPerHost);

/// Owns connections for one operation, including consumption of the body.
/// A per-host pool limit is not a process-wide limit (CDN hosts vary per song).
/// Never return a request/response from [run]; consume it inside the callback.
class BiliHttpClient {
  BiliHttpClient(this.connectionTimeout, this.idleTimeout, this.maxConnectionsPerHost);

  final Duration connectionTimeout;
  final Duration idleTimeout;
  final int maxConnectionsPerHost;
  static final _slots = _RequestSlots(8);
  static final _downloadSlots = _RequestSlots(2);

  Future<T> run<T>(Future<T> Function(HttpClient) action, {
    bool download = false,
  }) async {
    final slots = download ? _downloadSlots : _slots;
    await slots.acquire();
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = connectionTimeout
        ..idleTimeout = idleTimeout
        ..maxConnectionsPerHost = maxConnectionsPerHost;
      // Each request also bounds header/body inactivity below. Closing in
      // finally releases sockets on parse failures and unconsumed responses.
      return await action(client);
    } on SocketException {
      unawaited(RuntimeHealth.instance.sample('socket-error'));
      rethrow;
    } on FileSystemException {
      unawaited(RuntimeHealth.instance.sample('file-error'));
      rethrow;
    } finally {
      client?.close(force: true);
      slots.release();
    }
  }
}

/// Bounds acquiring a connection and receiving headers; Future.timeout alone
/// does not cancel the underlying request, so abort it explicitly, including
/// a connection that arrives after the deadline.
Future<HttpClientResponse> biliGet(HttpClient client, Uri uri, {
  Map<String, String> headers = const {},
}) async {
  var expired = false;
  HttpClientRequest? request;
  try {
    request = await client.getUrl(uri).then((value) {
      if (expired) value.abort();
      return value;
    }).timeout(const Duration(seconds: 20));
    headers.forEach(request.headers.set);
    return await request.close().timeout(const Duration(seconds: 20));
  } catch (_) {
    expired = true;
    request?.abort();
    rethrow;
  }
}

extension BiliResponseBody on HttpClientResponse {
  Stream<List<int>> get boundedBody => timeout(const Duration(seconds: 30));
}

class _RequestSlots {
  _RequestSlots(this.limit);
  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<void> acquire() async {
    if (_active < limit) {
      _active++;
      return;
    }
    // A stalled background network must not grow an unbounded queue of jobs.
    if (_waiting.length >= 128) throw StateError('网络请求过多，请稍后重试');
    final waiter = Completer<void>();
    _waiting.add(waiter);
    try {
      await waiter.future.timeout(const Duration(seconds: 30));
    } catch (_) {
      // A slot may have been handed off just as the timeout fired.
      if (!_waiting.remove(waiter)) release();
      rethrow;
    }
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }
}
