import 'dart:developer';

import 'package:flutter/services.dart';

class BarcodeViewController {
  BarcodeViewController.data(int id)
      : _channel =
            MethodChannel('plugins.codingwithtashi/barcode_scanner_view_$id') {
    log("Initializing BarcodeViewController with id: $id");
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  final MethodChannel _channel;
  Function(String)? _onScanned;
  void Function(String code, String message)? _onError;
  bool _continuous = true;
  Duration _delay = Duration.zero;
  DateTime? _lastScanTime;
  bool _hasScanned = false;

  /// Applies `continuous` and `delayMillis` here so iOS and Android behave the same.
  void setScanOptions({required bool continuous, int? delayMillis}) {
    _continuous = continuous;
    _delay = Duration(milliseconds: delayMillis ?? 0);
  }

  void setOnScanned(Function(String) callback) {
    log("Setting onScanned callback");
    _onScanned = callback;
  }

  void setOnError(void Function(String code, String message) callback) {
    _onError = callback;
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    print("Received method call: ${call.method}"); // Debug log
    switch (call.method) {
      case 'onBarcodeDetected':
        if (!_continuous && _hasScanned) break;
        final now = DateTime.now();
        if (_lastScanTime != null && now.difference(_lastScanTime!) < _delay) {
          break;
        }
        _lastScanTime = now;
        if (!_continuous) {
          _hasScanned = true;
          // Stop native detection too; resumeScanning re-arms it.
          pauseScanning();
        }
        if (_onScanned != null) {
          _onScanned!(call.arguments as String);
        }
        break;
      case 'onError':
        log('Barcode Scanner Error: ${call.arguments}');
        final args = call.arguments;
        if (args is Map) {
          _onError?.call(args['code'] as String, args['message'] as String);
        } else {
          _onError?.call('UNKNOWN', '$args');
        }
        break;
      default:
        log('Unhandled method: ${call.method}');
        break;
    }
  }

  Future<void> toggleFlash() {
    return _channel.invokeMethod('toggleFlash');
  }

  Future<void> pauseScanning() {
    return _channel.invokeMethod('pauseScanning');
  }

  Future<void> resumeScanning() {
    _hasScanned = false;
    return _channel.invokeMethod('resumeScanning');
  }

  /// Tells the native view to start the camera. Called once the handler is attached.
  Future<void> startScanning() {
    return _channel.invokeMethod('startScanning');
  }
}
