/// Full row detail, presented as a sheet or in the workspace's expanded detail rail.
///
/// A table cell is ellipsised and a wide table scrolls horizontally, so the full record is
/// not readable in the grid. This view shows every field of one row, selectable, with nulls
/// said out loud rather than rendered as blank.
library;

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../responsive_detail.dart';
import '../value_format.dart';

Future<void> showRowDetail(
  BuildContext context, {
  required int rowNumber,
  required List<String> columns,
  required List<dynamic> values,
  String? highlighted,
}) =>
    showWorkspaceDetail(
      context,
      builder: (context, close) => SafeArea(
        child: _RowDetail(
          rowNumber: rowNumber,
          columns: columns,
          values: values,
          highlighted: highlighted,
          onClose: close,
        ),
      ),
      bottomBuilder: (context, close) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        builder: (context, controller) => _RowDetail(
          rowNumber: rowNumber,
          columns: columns,
          values: values,
          highlighted: highlighted,
          onClose: close,
          scrollController: controller,
        ),
      ),
    );

class _RowDetail extends StatelessWidget {
  const _RowDetail({
    required this.rowNumber,
    required this.columns,
    required this.values,
    required this.onClose,
    this.highlighted,
    this.scrollController,
  });

  final int rowNumber;
  final List<String> columns;
  final List<dynamic> values;
  final String? highlighted;
  final VoidCallback onClose;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nullStyle =
        theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListView(
      controller: scrollController,
      primary: false,
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
              onPressed: onClose,
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
                    fontWeight: columns[i] == highlighted ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                const SizedBox(height: MorphicSpace.xs),
                if (i >= values.length)
                  Text('Value unavailable', style: nullStyle)
                else if (values[i] == null)
                  Text('No value (null)', style: nullStyle)
                else if (values[i] is String && (values[i] as String).isEmpty)
                  Text('Empty string', style: nullStyle)
                else
                  SelectableText(
                    formatCell(values[i]),
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
