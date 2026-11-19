import 'package:flutter/widgets.dart';

import '../library/library.dart';
import '../player/player_controller.dart';
import '../settings.dart';

/// Stellt Einstellungen, Bibliothek und Player im Widget-Baum bereit.
class MyncScope extends InheritedWidget {
  const MyncScope({
    super.key,
    required this.settings,
    required this.library,
    required this.player,
    required super.child,
  });

  final AppSettings settings;
  final Library library;
  final PlayerController player;

  static MyncScope of(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<MyncScope>();
    assert(s != null, 'MyncScope fehlt');
    return s!;
  }

  @override
  bool updateShouldNotify(MyncScope oldWidget) => false;
}

extension MyncContext on BuildContext {
  Library get library => MyncScope.of(this).library;
  PlayerController get player => MyncScope.of(this).player;
  AppSettings get settings => MyncScope.of(this).settings;
}
