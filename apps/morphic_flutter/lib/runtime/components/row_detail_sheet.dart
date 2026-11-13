/// Row detail bottom sheet (M1.3 task 1.3.3).
///
/// A table cell is ellipsised and a wide table scrolls horizontally, so the full record is not
/// readable in the grid. This sheet shows every field of one row, selectable, with nulls said
/// out loud rather than rendered as blank. It replaces the old single-cell dialog: one gesture
/// on a row now reveals the whole record, which is what someone inspecting a row actually wants.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../value_format.dart';

Future<void> showRowDetail(
  BuildContext context, {
  required int rowNumber,
  required List<String> columns,
  required List<dynamic> values,
  String? highlighted,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RowDetail(
        rowNumber: rowNumber,
        columns: columns,
        values: values,
        highlighted: highlighted,
      ),
    );

class _RowDetail extends StatelessWidget {
  const _RowDetail({
    required this.rowNumber,
    required this.columns,
    required this.values,
    this.highlighted,
  });

  final int rowNumber;
  final List<String> columns;
  final List<dynamic> values;
  final String? highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nullStyle = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(
          MorphicSpace.lg,
          0,
          MorphicSpace.lg,
          MorphicSpace.lg,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Row $rowNumber', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                key: const Key('row-detail-close'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: MorphicSpace.sm),
          for (var i = 0; i < columns.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: MorphicSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    columns[i],
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: columns[i] == highlighted
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: MorphicSpace.xs),
                  if (i < values.length && values[i] != null)
                    SelectableText(
                      formatCell(values[i]),
                      style: theme.textTheme.bodyMedium,
                    )
                  else
                    Text('No value (null)', style: nullStyle),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
