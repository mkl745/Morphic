/// `data_table` renderer (M1.1 task 1.1.5; interactions M1.3 task 1.3.3).
///
/// Paging, search, sorting and filtering are all executed by Rust. This widget sends
/// **commands** to change persisted interaction state and then asks for the component's page;
/// it never slices, filters or sorts a row locally, so what the user sees cannot disagree with
/// canonical engine state — and a sort survives save and reopen because it lives in the
/// document, not in this State object.
///
/// Layout: the header sits *outside* the vertical scroll view but *inside* the shared
/// horizontal one, so it stays pinned while rows scroll vertically and moves in lockstep
/// with rows when scrolled horizontally.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/copy.dart';
import '../../design_system/tokens.dart';
import '../../engine/engine_controller.dart';
import '../../engine/interaction.dart';
import '../change_type_button.dart';
import '../component_registry.dart';
import '../explanation_sheet.dart';
import '../field_corrections.dart';
import '../filter_recovery.dart';
import '../value_format.dart';
import 'row_detail_sheet.dart';
import 'table_filter_menu.dart';

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
  int _attempt = 0;

  /// The revision this widget last rendered. Comparing `old.ctx.engine.revision` against
  /// `widget.ctx.engine.revision` cannot work — both contexts hold the *same* controller, so
  /// both sides always read the new value. The last rendered revision has to be remembered
  /// here, or a command sent by another component would never refresh this table.
  int _seenRevision = -1;

  /// What the engine has persisted for this component. Read from the document, never held
  /// independently, so a rejected command cannot leave the header showing a sort that is not
  /// actually applied.
  ComponentInteraction get _interaction => widget.ctx.state;
  String get _search => _interaction.search ?? '';

  /// Set while a command is in flight, so a second tap cannot race the first.
  bool _commandBusy = false;
  String? _commandError;

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

  /// Fields with a persisted correction, shown as a small badge in the header.
  Set<String> get _corrected {
    final ws = widget.ctx.engine.doc?['workspace'];
    if (ws is! Map) return const <String>{};
    return (ws['fieldOverrides'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((o) => o['field'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  /// AT-17: the header is the correction entry point. A long press opens the sheet for that
  /// column; a tap still sorts.
  Future<void> _openCorrections(String column) => showFieldCorrectionsSheet(
        context,
        engine: widget.ctx.engine,
        field: column,
      );

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = _search;
    _seenRevision = widget.ctx.engine.revision;
    _fetch();
  }

  @override
  void didUpdateWidget(DataTableView old) {
    super.didUpdateWidget(old);
    final revision = widget.ctx.engine.revision;
    if (old.ctx.id != widget.ctx.id) {
      _offset = 0;
      _seenRevision = revision;
      _searchCtrl.text = _search;
      _fetch();
      return;
    }
    if (revision != _seenRevision) {
      // A new revision means the interaction state or the data changed; either way the
      // current offset may not exist any more. Reset to the top (AT-07).
      _seenRevision = revision;
      _offset = 0;
      if (_searchCtrl.text != _search) _searchCtrl.text = _search;
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
    // The revision this read is *for*. Captured before the await so a response can be
    // checked against the document it was meant to describe (task 1.3.5).
    final revision = widget.ctx.engine.revision;
    setState(() {
      _state = _Load.pending;
      _error = null;
    });
    final res = await widget.ctx.engine.componentPage(
      widget.ctx.id,
      offset: _offset,
      limit: _pageSize,
    );
    if (!mounted || attempt != _attempt) return;
    if (revision != widget.ctx.engine.revision) {
      // The document moved while this read was in flight, so these rows belong to a
      // selection the workspace is no longer on. Adopting them would paint this component
      // on the old selection while another is already on the new one — the torn frame
      // task 1.3.5 exists to rule out. Read again instead.
      _fetch();
      return;
    }
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
      final trimmed = value.trim();
      if (trimmed == _search) return;
      _send([Commands.setSearch(widget.ctx.id, trimmed.isEmpty ? null : trimmed)]);
    });
  }

  /// Send a batch and let the controller's revision bump drive the rebuild. A rejected batch
  /// leaves the document alone, so the header keeps showing what is actually applied.
  Future<bool> _send(List<Map<String, dynamic>> commands) async {
    if (_commandBusy) return false;
    setState(() {
      _commandBusy = true;
      _commandError = null;
    });
    final affected = await widget.ctx.engine.applyCommands(commands);
    if (!mounted) return false;
    setState(() {
      _commandBusy = false;
      _commandError = affected == null ? widget.ctx.engine.error : null;
    });
    if (affected != null) {
      // Claim the revision before fetching, so the rebuild this command triggered does not
      // fetch the same page a second time.
      _seenRevision = widget.ctx.engine.revision;
      _offset = 0;
      await _fetch();
    }
    return affected != null;
  }

  void _toggleSort(String field) {
    if (!widget.ctx.canSort || _commandBusy) return;
    _send([
      Commands.setComponentSort(widget.ctx.id, cycledSort(_interaction.sort, field)),
    ]);
  }

  Future<void> _openFilter(String field) async {
    if (!widget.ctx.canFilter || _commandBusy) return;
    final choice = await showColumnFilterMenu(
      context,
      field: field,
      kind: fieldKindOf(widget.ctx.dtypeOf(field)),
      current: _interaction.filterFor(field),
      suggestions: widget.ctx.topValuesOf(field),
    );
    if (choice == null || !mounted) return;
    final next = withFieldFilter(
      _interaction.filter,
      field,
      choice.cleared ? null : choice.filter,
    );
    await _send([Commands.setComponentFilter(widget.ctx.id, next)]);
  }

  Future<void> _clearAll() async {
    if (_commandBusy) return;
    _debounce?.cancel();
    final commands = clearViewNarrowingCommands(widget.ctx);
    if (commands.isEmpty) return;
    // Leave the text intact if the engine rejects the batch.
    if (await _send(commands) && mounted) _searchCtrl.clear();
  }

  Future<void> _clearWorkspaceFilters() async {
    await _send([Commands.setGlobalFilter([])]);
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

  /// A capped or long value must still be readable in full, and a wide row is not readable in
  /// the grid at all. One tap opens the whole record.
  void _inspectRow(int index) {
    final page = _page;
    if (page == null || index >= page.rows.length) return;
    final cols = _columns;
    final row = page.rows[index];
    showRowDetail(
      context,
      rowNumber: page.offset + index + 1,
      columns: cols,
      values: [
        for (var i = 0; i < cols.length; i++) i < row.length ? row[i] : null,
      ],
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
                  ExplanationButton(
                    id: widget.ctx.id,
                    title: widget.ctx.title,
                    explanation: widget.ctx.explanation,
                  ),
                  ChangeTypeButton(
                    engine: widget.ctx.engine,
                    id: widget.ctx.id,
                    type: widget.ctx.type,
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
              Expanded(child: _content(theme, cols, totalWidth)),
              const SizedBox(height: MorphicSpace.sm),
              _footer(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Keep empty/error recovery and any engine evidence reachable even in a small table.
  /// The status body and its filter/error chrome scroll together; the populated grid keeps
  /// its own bounded viewport and gives a long command error a separate bounded scroll area.
  Widget _content(ThemeData theme, List<String> cols, double totalWidth) {
    final firstPageLoading = _state == _Load.pending && _page == null;
    final statusBody = _state == _Load.failed ||
        (!firstPageLoading && (_page == null || cols.isEmpty || _page!.rows.isEmpty));
    final chrome = <Widget>[
      if (widget.ctx.canFilter || widget.ctx.canSearch) _activeFilters(theme),
      if (_commandError != null) MorphicCommandError(evidence: _commandError!),
    ];
    final body = _body(theme, cols, totalWidth);
    if (statusBody) {
      return SingleChildScrollView(
        key: const Key('table-state-scroll'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...chrome,
            const SizedBox(height: MorphicSpace.sm),
            body,
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Leave room for the grid's 36 dp header, divider, and the gap below the chrome.
        final chromeHeight = constraints.maxHeight > 48 ? constraints.maxHeight - 48 : 0.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: chromeHeight),
              child: SingleChildScrollView(
                key: const Key('table-chrome-scroll'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: chrome,
                ),
              ),
            ),
            const SizedBox(height: MorphicSpace.sm),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  String _emptyLabel() {
    final bits = <String>[];
    if (_search.isNotEmpty) bits.add('“$_search”');
    final f = _interaction.filter;
    if (f != null) bits.add(describeFilter(f));
    if (widget.ctx.engine.globalFilters.isNotEmpty) {
      if (bits.isEmpty) return MorphicCopy.noWorkspaceRows;
      bits.add('workspace filters');
    }
    if (bits.isEmpty) return 'This dataset has no rows.';
    return 'No rows match ${bits.join(' and ')}.';
  }

  /// Active filters as removable chips, so a narrowed table always says why it is narrow.
  Widget _activeFilters(ThemeData theme) {
    final chips = <Widget>[];
    final filter = _interaction.filter;
    if (filter != null) {
      final parts = (filter['op'] as String?) == 'and'
          ? (filter['args'] as List? ?? const []).whereType<Map<String, dynamic>>()
          : <Map<String, dynamic>>[filter];
      for (final part in parts) {
        final field = part['field'] as String?;
        chips.add(InputChip(
          label: Text(describeFilter(part)),
          onDeleted: _commandBusy || field == null
              ? null
              : () => _send([
                    Commands.setComponentFilter(
                      widget.ctx.id,
                      withFieldFilter(_interaction.filter, field, null),
                    ),
                  ]),
        ));
      }
    }
    if (_search.isNotEmpty) {
      chips.add(InputChip(
        label: Text('Search: $_search'),
        onDeleted: _commandBusy
            ? null
            : () async {
                _debounce?.cancel();
                if (await _send([Commands.setSearch(widget.ctx.id, null)]) && mounted) {
                  _searchCtrl.clear();
                }
              },
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: MorphicSpace.sm),
      child: Wrap(
        spacing: MorphicSpace.xs,
        runSpacing: MorphicSpace.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...chips,
          TextButton(
            key: const Key('table-clear-all'),
            onPressed: _commandBusy ? null : _clearAll,
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, List<String> cols, double totalWidth) {
    if (_state == _Load.failed) {
      // _content scrolls this state together with filter chips and command errors, so even
      // a long engine message remains reachable inside the fixed-height table.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: MorphicSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load rows',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No page loaded.', style: theme.textTheme.bodySmall),
            TextButton(onPressed: _fetch, child: const Text(MorphicCopy.retry)),
          ],
        ),
      );
    }
    if (cols.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              // Preserve the engine's notice for a missing source.
              widget.ctx.engine.notice ?? 'No columns to display.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MorphicSpace.sm),
            Text(
              widget.ctx.engine.degraded
                  ? MorphicCopy.missingSourceDetail
                  : MorphicCopy.noColumnsDetail,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (page.rows.isEmpty) {
      final hasWorkspaceFilters = widget.ctx.engine.globalFilters.isNotEmpty;
      final viewCommands = clearViewNarrowingCommands(widget.ctx);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _emptyLabel(),
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MorphicSpace.sm),
            if (hasWorkspaceFilters || viewCommands.isNotEmpty)
              MorphicFilterActions(
                workspaceKey: const Key('table-clear-global-filters'),
                viewKey: const Key('table-clear-empty'),
                viewLabel: MorphicCopy.clearSearchAndFilters,
                onClearWorkspace: hasWorkspaceFilters ? _clearWorkspaceFilters : null,
                onClearView: viewCommands.isEmpty ? null : _clearAll,
                busy: _commandBusy,
              )
            else
              Text(
                MorphicCopy.noTableRowsDetail,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        child: Column(
          children: [
            _HeaderRow(
              columns: cols,
              widthOf: _columnWidth,
              interaction: _interaction,
              canSort: widget.ctx.canSort,
              canFilter: widget.ctx.canFilter,
              corrected: _corrected,
              busy: _commandBusy,
              onSort: _toggleSort,
              onFilter: _openFilter,
              onCorrect: _openCorrections,
            ),
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
                    onTap: () => _inspectRow(i),
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
    // Only a *settled* page may state a range. While the next selection is loading, the old
    // page's total is a claim about a selection the workspace has already left, and printing
    // it beside a metric card that has already updated is precisely the torn frame task 1.3.5
    // rules out. An empty label is honest; the header spinner says why.
    final p = _state == _Load.ready ? _page : null;
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
  const _HeaderRow({
    required this.columns,
    required this.widthOf,
    required this.interaction,
    required this.canSort,
    required this.canFilter,
    required this.corrected,
    required this.busy,
    required this.onSort,
    required this.onFilter,
    required this.onCorrect,
  });

  final List<String> columns;
  final double Function(String) widthOf;
  final ComponentInteraction interaction;
  final bool canSort;
  final bool canFilter;
  final Set<String> corrected;
  final bool busy;
  final void Function(String) onSort;
  final void Function(String) onFilter;
  final Future<void> Function(String) onCorrect;

  static String _sortLabel(SortRule rule) =>
      rule.dir == SortDir.asc ? 'Sorted ascending' : 'Sorted descending';

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
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: Key('sort-$c'),
                      onTap: canSort && !busy ? () => onSort(c) : null,
                      onLongPress: busy ? null : () => onCorrect(c),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: MorphicSpace.sm),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                c,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium,
                              ),
                            ),
                            if (corrected.contains(c))
                              Icon(
                                Icons.tune,
                                key: Key('corrected-$c'),
                                size: 12,
                                semanticLabel: 'Corrected field: $c',
                              ),
                            if (interaction.sortFor(c) != null)
                              Icon(
                                interaction.sortFor(c)!.dir == SortDir.asc
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward,
                                size: 14,
                                semanticLabel: _sortLabel(interaction.sortFor(c)!),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (canFilter)
                    SizedBox(
                      width: 28,
                      child: IconButton(
                        key: Key('filter-$c'),
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        tooltip: 'Filter $c',
                        icon: Icon(
                          interaction.filterFor(c) != null
                              ? Icons.filter_alt
                              : Icons.filter_alt_outlined,
                        ),
                        onPressed: busy ? null : () => onFilter(c),
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

class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.columns,
    required this.row,
    required this.widthOf,
    required this.striped,
    required this.rowNumber,
    required this.onTap,
  });

  final List<String> columns;
  final List<dynamic> row;
  final double Function(String) widthOf;
  final bool striped;

  /// Absolute row number in the dataset, not the index within this page.
  final int rowNumber;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dataStyle = MorphicTypography.dataStyle(theme.textTheme.bodySmall);
    final isNullStyle = dataStyle?.copyWith(color: theme.colorScheme.onSurfaceVariant);
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
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: MorphicSpace.sm),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        formatCell(values[i]),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: values[i] == null ? isNullStyle : dataStyle,
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
