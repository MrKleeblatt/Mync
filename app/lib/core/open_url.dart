import 'dart:io';

import 'package:flutter/services.dart';

import '../log.dart';

/// Öffnet [url] im Browser (Linux: xdg-open, Android: Kanal „mync/app“).
Future<void> openUrl(String url) async {
  try {
    if (Platform.isAndroid) {
      await const MethodChannel('mync/app')
          .invokeMethod('openUrl', {'url': url});
    } else {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    }
  } catch (e) {
    logWarning('Adresse nicht zu öffnen: $url ($e)');
  }
}
