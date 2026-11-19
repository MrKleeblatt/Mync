import 'dart:io';

import 'package:flutter/services.dart';

/// „Zugriff auf alle Dateien“ (Android 11+) über den Kanal `mync/storage`
/// in `MainActivity.kt`. Auf Linux immer erlaubt.
class StorageAccess {
  static const _channel = MethodChannel('mync/storage');

  static Future<bool> granted() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  }

  /// Öffnet die Systemeinstellung, in der der Nutzer den Zugriff erlaubt.
  static Future<void> request() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('requestAllFilesAccess');
  }
}
