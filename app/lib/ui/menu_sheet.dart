import 'package:flutter/material.dart';

import 'scope.dart';

/// Einheitliche Menüs der App: ein Blatt von unten mit Griff, Kopf
/// (Bild oder Symbol, Titel, Untertitel), Trennlinie und darunter Einträge
/// oder Regler. Gilt für Titel-Menüs, Warteschlangen, Sleeptimer, Tempo
/// und Klang – auf dem Handy wie am PC (dort auf lesbare Breite begrenzt).
Future<T?> showMenuSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData? icon,
  Widget? leading,
  required Widget Function(BuildContext context) builder,
}) {
  final settings = context.settings;
  final library = context.library;
  final player = context.player;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => MyncScope(
      settings: settings,
      library: library,
      player: player,
      child: Builder(
        builder: (ctx) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MenuHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                leading: leading,
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: builder(ctx),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Kopf eines Menüs (auch für Inhalte, die sich ändern – z. B. Tempo).
class MenuHeader extends StatelessWidget {
  const MenuHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lead =
        leading ??
        (icon == null
            ? null
            : Icon(icon, size: 28, color: theme.colorScheme.primary));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Row(
        children: [
          if (lead != null) ...[lead, const SizedBox(width: 16)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ein Eintrag eines Menüs; null in einer Liste = Trennlinie.
class MenuItem<T> {
  const MenuItem(this.value, this.icon, this.label, {this.selected = false});
  final T value;
  final IconData icon;
  final String label;

  /// Hervorgehoben (z. B. eingeschaltet).
  final bool selected;
}

/// Einträge eines Menüs; ein Eintrag schließt das Menü mit seinem Wert.
class MenuItems<T> extends StatelessWidget {
  const MenuItems(this.items, {super.key});
  final List<MenuItem<T>?> items;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final i in items)
        if (i == null)
          const Divider(indent: 24, endIndent: 24)
        else
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(i.icon),
            title: Text(i.label),
            selected: i.selected,
            onTap: () => Navigator.pop(context, i.value),
          ),
    ],
  );
}

/// Menü mit Einträgen; liefert den gewählten Wert (null = abgebrochen).
Future<T?> showActionSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData? icon,
  Widget? leading,
  required List<MenuItem<T>?> items,
}) => showMenuSheet<T>(
  context,
  title: title,
  subtitle: subtitle,
  icon: icon,
  leading: leading,
  builder: (_) => MenuItems<T>(items),
);
