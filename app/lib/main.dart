import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'library/library.dart';
import 'player/mpris.dart';
import 'player/player_controller.dart';
import 'settings.dart';
import 'ui/global_shortcuts.dart';
import 'ui/home_shell.dart';
import 'ui/compact_window.dart';
import 'ui/scope.dart';
import 'sync/library_sync_host.dart';
import 'sync/sync_service.dart';
import 'ui/sync_page.dart';
import 'update/update_service.dart';

bool? _lastUpdateCheck;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final settings = await AppSettings.load();
  final library = Library(settings);
  final player = PlayerController(settings, library);
  await library.load();
  await player.init();
  final mpris = Mpris(player);
  unawaited(mpris.start());
  if (settings.scanOnStart) unawaited(library.refresh());

  // Sync mit gekoppelten Geräten im Heimnetz
  final sync = SyncService(
    dataDir: settings.dataDir,
    host: LibrarySyncHost(library, settings),
    deviceName: Platform.isAndroid ? 'Android-Handy' : Platform.localHostname,
  );
  SyncScope.service = sync;
  await sync.init();
  if (settings.syncEnabled) unawaited(sync.startServer());

  // Teil-Updates über GitHub-Releases (nur Linux)
  final updates = UpdateService(settings, beforeRestart: player.endListening);
  UpdateService.instance = updates;
  updates.start();
  settings.addListener(() {
    // Einstellung „Nach Updates suchen“ geändert → Zeitplan neu
    if (settings.updateCheck != _lastUpdateCheck) {
      _lastUpdateCheck = settings.updateCheck;
      updates.start();
    }
  });
  _lastUpdateCheck = settings.updateCheck;

  // Zustand beim Beenden sichern
  AppLifecycleListener(
    onExitRequested: () async {
      await player.endListening();
      await mpris.stop();
      return AppExitResponse.exit;
    },
    onPause: player.saveNow,
    onHide: player.saveNow,
  );

  runApp(MyncApp(settings: settings, library: library, player: player));
}

class MyncApp extends StatelessWidget {
  const MyncApp({
    super.key,
    required this.settings,
    required this.library,
    required this.player,
  });

  final AppSettings settings;
  final Library library;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7D6B),
        brightness: b,
      ),
      useMaterial3: true,
    );
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'mync',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: settings.themeMode,
        builder: (context, child) => GlobalShortcuts(
          player: player,
          child: ListenableBuilder(
            listenable: CompactWindow.instance,
            builder: (context, _) {
              final compact = CompactWindow.instance.active;
              // Das große Fenster bleibt erhalten (Offstage), damit offene
              // Seiten und Zustände beim Zurückschalten noch da sind.
              return Stack(
                children: [
                  Offstage(offstage: compact, child: child),
                  if (compact)
                    Positioned.fill(
                      child: Overlay(
                        initialEntries: [
                          OverlayEntry(
                            builder: (_) => MyncScope(
                              settings: settings,
                              library: library,
                              player: player,
                              // eigener Fokus, damit Tastenkürzel ankommen
                              child: Focus(
                                autofocus: true,
                                child: CompactPlayerView(player: player),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        home: MyncScope(
          settings: settings,
          library: library,
          player: player,
          child: const HomeShell(),
        ),
      ),
    );
  }
}
