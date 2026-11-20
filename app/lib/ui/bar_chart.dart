import 'package:flutter/material.dart';

/// Säulenfarbe (eine Reihe, daher keine Legende – der Titel benennt sie):
/// Kupfer, für Flächen auf Dunkel abgedunkelt. Geprüft mit dem
/// Palette-Validator gegen #16171A (Helligkeitsband, Kontrast ≥ 3:1).
Color barColor(BuildContext context) => const Color(0xFFBD8340);

/// Schlichtes Säulendiagramm: schmale Säulen mit 4-px-Rundung oben, 2 px
/// Abstand, zurückhaltende Grundlinie, Tooltip beim Überfahren (Trefferfläche
/// = ganze Spalte) und umschaltbare Tabellenansicht.
class BarChart extends StatefulWidget {
  const BarChart({
    super.key,
    required this.title,
    required this.values,
    required this.labels,
    required this.format,
    this.labelEvery = 1,
    this.height = 140,
  });

  final String title;
  final List<int> values;

  /// Beschriftung je Säule (auch für Tooltip und Tabelle).
  final List<String> labels;
  final String Function(int value) format;

  /// Nur jede n-te Beschriftung unter der Achse anzeigen.
  final int labelEvery;
  final double height;

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final maxV = widget.values.fold(0, (a, b) => a > b ? a : b);
    final color = barColor(context);

    final header = Row(
      children: [
        Expanded(child: Text(widget.title, style: theme.textTheme.titleSmall)),
        IconButton(
          tooltip: _table ? 'Als Diagramm' : 'Als Tabelle',
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _table = !_table),
          icon: Icon(
            _table ? Icons.bar_chart : Icons.table_rows_outlined,
            size: 20,
          ),
        ),
      ],
    );

    if (_table) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Table(
            columnWidths: const {0: IntrinsicColumnWidth()},
            children: [
              for (var i = 0; i < widget.values.length; i++)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 16, bottom: 2),
                      child: Text(
                        widget.labels[i],
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Text(
                      widget.format(widget.values[i]),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (maxV == 0)
          SizedBox(
            height: widget.height,
            child: Center(
              child: Text(
                'Noch keine Daten',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          )
        else ...[
          // Wert der höchsten Säule als einzige Skalenangabe
          Text(
            'max. ${widget.format(maxV)}',
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: widget.height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < widget.values.length; i++)
                  Expanded(
                    child: Tooltip(
                      message:
                          '${widget.labels[i]}: ${widget.format(widget.values[i])}',
                      waitDuration: Duration.zero,
                      child: Semantics(
                        label:
                            '${widget.labels[i]}: ${widget.format(widget.values[i])}',
                        child: Container(
                          // Trefferfläche: ganze Spalte
                          color: Colors.transparent,
                          alignment: Alignment.bottomCenter,
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          // schmale Säulen: höchstens 28 px breit
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 28),
                            child: FractionallySizedBox(
                              heightFactor: widget.values[i] == 0
                                  ? 0
                                  : (widget.values[i] / maxV).clamp(0.02, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (var i = 0; i < widget.values.length; i++)
                Expanded(
                  child: Text(
                    i % widget.labelEvery == 0 ? widget.labels[i] : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
