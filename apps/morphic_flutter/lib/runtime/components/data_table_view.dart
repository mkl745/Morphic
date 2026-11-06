/// `data_table` renderer (M1.1 task 1.1.5).
///
/// Paging and search are executed by Rust: this widget sends a plan and draws the page it
/// gets back. It never slices or filters the full dataset locally, so what the user sees
/// cannot disagree with canonical engine state.
///
/// Layout: the header sits *outside* the vertical scroll view but *inside* the shared
/// horizontal one, so it stays pinned while rows scroll vertically and moves in lockstep
/// with rows when scrolled horizontally.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';
import '../component_registry.dart';
import '../../engine/engine_controller.dart';
import '../value_format.dart';

/// Hard ceiling mirrored from `MAX_PAGE_SIZE` in morphic-schema / morphic-query.
const int maxPageSize = 1024;
const int defaultPageSize = 256;

class DataTableView extends StatefulWidget {
  const DataTableView({
    super.key,
    required this.ctx,
    this.height,
    this.searchDebounce = const Duration(milliseconds: 250),
  });

  final ComponentContext ctx;

  /// Embedded tables need a bounded height. Null means "size to the viewport", which keeps
  /// the table usable on both a phone and a tablet without a magic constant.
  final double? height;
  final Duration searchDebounce;

  @override
  State<DataTableView> createState() => _DataTableViewState();
}

enum _Load { pending, ready, failed }

class _DataTableViewState extends State<DataTableView> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  _Load _state = _Load.pending;
  PageResult? _page;
  String? _error;
  int _offset = 0;
  String _search = '';
  int _attempt = 0;

  /// Column widths measured from real cell content, then **frozen** for the session so they
  /// do not jitter as you page. Sizing from the header alone made a 24-character ISO
  /// timestamp render as `2026-11-05T1…` in a 96 dp column — permanently unreadable, because
  /// the ellipsis is inside the column and horizontal scrolling cannot reveal it.
  Map<String, double>? _widths;
  List<String>? _widthsFor;

  int get _pageSize {
    final raw = (widget.ctx.binding['page_size'] as num?)?.toInt() ?? defaultPageSize;
    if (raw < 1) return 1;
    if (raw > maxPageSize) return maxPageSize;
    return raw;
  }

  /// Column order comes from the binding; an empty binding falls back to the profile's
  /// field order, which Rust already made deterministic.
  List<String> get _columns {
    final bound = (widget.ctx.binding['columns'] as List? ?? const [])
        .whereType<String>()
        .toList();
    if (bound.isNotEmpty) return bound;
    final profile = widget.ctx.engine.profile;
    final fields = (profile?['fields'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return fields.map((f) => f['name'] as String? ?? '').where((n) => n.isNotEmpty).toList();
  }

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(DataTableView old) {
    super.didUpdateWidget(old);
    if (old.ctx.id != widget.ctx.id ||
        old.ctx.engine.revision != widget.ctx.engine.revision) {
      _offset = 0;
      _fetch();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final attempt = ++_attempt;
    setState(() {
      _state = _Load.pending;
      _error = null;
    });
    final res = await widget.ctx.engine.page(
      offset: _offset,
      limit: _pageSize,
      search: _search.isEmpty ? null : _search,
    );
    if (!mounted || attempt != _attempt) return;
    setState(() {
      if (res == null) {
        _error = widget.ctx.engine.error ?? 'The engine did not return a page.';
        _state = _Load.failed;
      } else {
        _page = res;
        _state = _Load.ready;
        _measureColumns(res);
      }
    });
  }

  /// Size each column to the wider of its header and its longest visible value. Measured
  /// once per column set, from the first page that has rows, then kept stable.
  void _measureColumns(PageResult page) {
    final cols = _columns;
    if (cols.isEmpty || page.rows.isEmpty) return;
    if (_widths != null && _widthsFor != null && _listEquals(_widthsFor!, cols)) return;
    final measured = <String, double>{};
    for (var c = 0; c < cols.length; c++) {
      var longest = cols[c].length;
      for (final row in page.rows) {
        if (c >= row.length) continue;
        final s = formatCell(row[c]);
        if (s.length > longest) longest = s.length;
      }
      // ~7.2 dp per character at bodySmall, plus cell padding. Capped so one enormous text
      // blob cannot dominate the viewport; the full value is still reachable by tapping.
      final w = longest * 7.2 + 24;
      measured[cols[c]] = w < 96 ? 96 : (w > 300 ? 300 : w);
    }
    _widths = measured;
    _widthsFor = cols;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(widget.searchDebounce, () {
      if (!mounted) return;
      _search = value.trim();
      _offset = 0;
      _fetch();
    });
  }

  void _next() {
    final p = _page;
    if (p == null || !p.hasMore) return;
    _offset = p.offset + p.rows.length;
    _fetch();
  }

  void _prev() {
    if (_offset == 0) return;
    _offset = _offset > _pageSize ? _offset - _pageSize : 0;
    _fetch();
  }

  double _columnWidth(String name) {
    final measured = _widths?[name];
    if (measured != null) return measured;
    final w = name.length * 9.0 + 32;
    if (w < 96) return 96;
    if (w > 300) return 300;
    return w;
  }

  /// A capped or long value must still be readable in full.
  void _inspect(String column, Object? value) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(column),
        content: SelectableText(value == null ? 'No value (null)' : value.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cols = _columns;
    final totalWidth = cols.isEmpty
        ? 0.0
        : cols.fold<double>(0, (sum, c) => sum + _columnWidth(c));
    final height = widget.height ??
        (MediaQuery.sizeOf(context).height * 0.55).clamp(280.0, 560.0);

    return Card(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(MorphicSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(widget.ctx.title, style: theme.textTheme.titleSmall),
                  ),
                  if (_state == _Load.pending)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              if (widget.ctx.canSearch) ...[
                const SizedBox(height: MorphicSpace.sm),
                TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Search rows',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: MorphicSpace.sm),
              Expanded(child: _body(theme, cols, totalWidth)),
              const SizedBox(height: MorphicSpace.sm),
              _footer(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme, List<String> cols, double totalWidth) {
    if (_state == _Load.failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load rows',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: MorphicColors.error)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(MorphicSpace.sm),
                child: Text(_error!, style: theme.textTheme.bodySmall),
              ),
            TextButton(onPressed: _fetch, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_state == _Load.pending && _page == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final page = _page;
    if (page == null) {
      return Center(child: Text('No page loaded.', style: theme.textTheme.bodySmall));
    }
    if (cols.isEmpty) {
      return Center(
        child: Text(
          // A workspace can reopen without its source (docs/architecture/06 §3). Say why,
          // using the engine's wording, instead of implying the import was malformed.
          widget.ctx.engine.notice ?? 'No columns to display.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    if (page.rows.isEmpty) {
      return Center(
        child: Text(
          _search.isEmpty ? 'This dataset has no rows.' : 'No rows match “$_search”.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        child: Column(
          children: [
            _HeaderRow(columns: cols, widthOf: _columnWidth),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: page.rows.length,
                itemExtent: 40,
                itemBuilder: (context, i) {
                  final row = page.rows[i];
                  return _DataRow(
                    columns: cols,
                    row: row,
                    widthOf: _columnWidth,
                    striped: i.isOdd,
                    rowNumber: page.offset + i + 1,
                    onInspect: _inspect,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    final p = _page;
    final label = p == null
        ? ''
        : rowRangeLabel(
            offset: p.offset, rowCount: p.rows.length, totalRows: p.totalRows);
    return Row(
      children: [
        // An explicit semantics node: the range is the pager's state, so it must be
        // exposed to assistive tech and to UI automation rather than relying on how
        // Flutter happens to merge sibling text.
        Expanded(
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: label,
            child: Text(label, style: theme.textTheme.labelSmall),
          ),
        ),
        IconButton(
          onPressed: _offset > 0 && _state != _Load.pending ? _prev : null,
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Previous page',
        ),
        IconButton(
          onPressed: (p?.hasMore ?? false) && _state != _Load.pending ? _next : null,
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Next page',
        ),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.columns, required this.widthOf});

  final List<String> columns;
  final double Function(String) widthOf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          for (final c in columns)
            SizedBox(
              width: widthOf(c),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: MorphicSpace.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    c,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.columns,
    required this.row,
    required this.widthOf,
    required this.striped,
    required this.rowNumber,
    required this.onInspect,
  });

  final List<String> columns;
  final List<dynamic> row;
  final double Function(String) widthOf;
  final bool striped;

  /// Absolute row number in the dataset, not the index within this page.
  final int rowNumber;

  final void Function(String column, Object? value) onInspect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNullStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.55));
    final values = [
      for (var i = 0; i < columns.length; i++)
        i < row.length ? row[i] : null,
    ];

    // A row is one semantic unit with a stable identity: assistive tech reads
    // "Row 12: eu, 10, —" rather than five disconnected cells, and UI automation can tell a
    // data row apart from a header or a metric card.
    return Semantics(
      container: true,
      label: 'Row $rowNumber: ${values.map(formatCell).join(', ')}',
      child: ColoredBox(
        color: striped
            ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : const Color(0x00000000),
        child: Row(
          children: [
            for (var i = 0; i < columns.length; i++)
              SizedBox(
                width: widthOf(columns[i]),
                child: InkWell(
                  onTap: () => onInspect(columns[i], values[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: MorphicSpace.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatCell(values[i]),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: values[i] == null ? isNullStyle : theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
