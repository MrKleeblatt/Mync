import 'package:flutter/material.dart';

import '../core/mync_core.dart';
import '../log.dart';
import 'log_page.dart';

/// Kurzer Zustand einer Aktion: dreht sich (lädt), Haken (erfolgreich) oder
/// Warnsymbol (fehlgeschlagen). Fehler lassen sich antippen und öffnen das
/// Logbuch – dort stehen die Details.
class StatusLine extends StatelessWidget {
  const StatusLine(this.status, {super.key, this.dense = false});
  final OpStatus? status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final size = dense ? 14.0 : 16.0;
    final Widget icon = switch (s.kind) {
      OpKind.busy => SizedBox.square(
        dimension: size,
        child: const CircularProgressIndicator(strokeWidth: 2),
      ),
      OpKind.ok => Icon(
        Icons.check_circle_outline,
        size: size,
        color: c.primary,
      ),
      OpKind.error => Icon(Icons.error_outline, size: size, color: c.error),
    };
    final style =
        (dense ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
            ?.copyWith(color: s.failed ? c.error : null);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            s.failed ? '${s.text} – Details im Logbuch' : s.text,
            style: style,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (!s.failed) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => openLogPage(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      ),
    );
  }
}

/// Kurze, verständliche Meldung für ein Widget (die Einzelheiten stehen im
/// Logbuch): bekannte Kernfehler im Klartext, sonst [fallback].
String shortError(Object e, String fallback) =>
    e is MyncCoreException && e.userMessage != e.message
    ? e.userMessage
    : fallback;
