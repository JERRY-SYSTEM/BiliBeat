import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Small, in-memory diagnostic history: writing a diagnostic file is unreliable
/// precisely when a long-running iOS process cannot open any more files.
class RuntimeHealth with WidgetsBindingObserver {
  RuntimeHealth._();
  static final instance = RuntimeHealth._();
  static const _channel = MethodChannel('bilibeat/runtime');
  final List<String> _samples = [];
  Timer? _timer;
  bool _sampling = false;
  DateTime? _lastErrorSample;
  String get report => _samples.join('\n');

  void start() {
    if (kIsWeb || !Platform.isIOS || _timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => sample('periodic'));
    unawaited(sample('startup'));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(sample(state.name));
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(sample('memory-pressure'));
  }

  Future<void> sample(String reason) async {
    if (kIsWeb || !Platform.isIOS || _sampling) return;
    if (reason == 'socket-error' || reason == 'file-error') {
      final now = DateTime.now();
      if (_lastErrorSample != null && now.difference(_lastErrorSample!) < const Duration(seconds: 10)) return;
      _lastErrorSample = now;
    }
    _sampling = true;
    try {
      final resources = await _channel.invokeMapMethod<String, dynamic>('resources')
          .timeout(const Duration(seconds: 3));
      final line = '${DateTime.now().toIso8601String()} $reason $resources';
      _samples.add(line);
      if (_samples.length > 30) _samples.removeAt(0);
      debugPrint('BiliBeat runtime: $line');
    } catch (error) {
      debugPrint('Runtime diagnostics unavailable: $error');
    } finally {
      _sampling = false;
    }
  }
}
