import 'dart:io';

import 'package:flutter/services.dart';

import '../library/library.dart';
import '../settings.dart';
import 'sync_session.dart';

/// Verbindet den Sync mit der Bibliothek der App.
class LibrarySyncHost implements SyncHost {
  LibrarySyncHost(this.library, this.settings);
  final Library library;
  final AppSettings settings;

  static const _channel = MethodChannel('mync/storage');

  @override
  String get root => settings.musicDir;
  @override
  String get db => settings.manifestDb;

  @override
  Future<void> rescan() async {
    // Läuft schon ein Scan, auf ihn warten und danach erneut einlesen
    while (library.scanning) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await library.refresh();
  }

  @override
  Future<void> afterApply(List<String> changedPaths) async {
    if (!Platform.isAndroid) return;
    // Android-MediaScanner, damit Musicolet die Änderungen sieht
    try {
      await _channel.invokeMethod<void>('scanFiles', [
        for (final p in changedPaths) '$root/$p',
      ]);
    } catch (_) {}
  }
}
