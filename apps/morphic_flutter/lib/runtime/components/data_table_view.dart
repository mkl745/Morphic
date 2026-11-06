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
      }
    });
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
    final w = name.length * 9.0 + 32;
    if (w < 96) return 96;
    if (w > 240) return 240;
    return w;
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
        child: Text('No columns to display.', style: theme.textTheme.bodySmall),
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
        Expanded(child: Text(label, style: theme.textTheme.labelSmall)),
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
  });

  final List<String> columns;
  final List<dynamic> row;
  final double Function(String) widthOf;
  final bool striped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNullStyle = theme.textTheme.bodySmall
        ?.copyWith(color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.55));
    return ColoredBox(
      color: striped
          ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35)
          : const Color(0x00000000),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            SizedBox(
              width: widthOf(columns[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: MorphicSpace.sm),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatCell(i < row.length ? row[i] : null),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: (i < row.length && row[i] == null)
                        ? isNullStyle
                        : theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
