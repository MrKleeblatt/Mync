import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/player_controller.dart';

/// Tastenkürzel für die Wiedergabe – gelten auf allen Seiten der App,
/// aber nicht, solange in einem Textfeld getippt wird (sonst würde z. B. die
/// Leertaste die Wiedergabe umschalten statt ein Leerzeichen einzufügen).
class GlobalShortcuts extends StatelessWidget {
  const GlobalShortcuts({super.key, required this.player, required this.child});

  final PlayerController player;
  final Widget child;

  Map<SingleActivator, VoidCallback> get _bindings {
    final p = player;
    return {
      const SingleActivator(LogicalKeyboardKey.space): p.playPause,
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): p.playPause,
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
          p.next,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
          p.previous,
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): p.next,
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): p.previous,
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          p.seekRelative(const Duration(seconds: 10)),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          p.seekRelative(const Duration(seconds: -10)),
      const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): () =>
          p.setVolume((p.volume + 5).clamp(0, 100)),
      const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): () =>
          p.setVolume((p.volume - 5).clamp(0, 100)),
      const SingleActivator(LogicalKeyboardKey.keyR, control: true):
          p.cycleRepeat,
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          p.shuffleQueue,
    };
  }

  /// Hat gerade ein Textfeld den Fokus?
  static bool isTyping() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || isTyping()) return KeyEventResult.ignored;
    for (final e in _bindings.entries) {
      if (e.key.accepts(event, HardwareKeyboard.instance)) {
        e.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(autofocus: true, onKeyEvent: _onKey, child: child);
}
