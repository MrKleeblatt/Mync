import '../library/library.dart';
import '../settings.dart';
import 'sync_session.dart';

/// Verbindet den Sync mit der Bibliothek der App.
class LibrarySyncHost implements SyncHost {
  LibrarySyncHost(this.library, this.settings);
  final Library library;
  final AppSettings settings;

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
    // Android: Änderungen über die Ordnerfreigabe sieht die Medien-
    // datenbank (Musicolet & Co.) von selbst – nichts zu tun.
  }
}
