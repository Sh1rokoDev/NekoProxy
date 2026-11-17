import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/widgets.dart';
import '../../domain/models.dart';
import '../../domain/node_view.dart';
import '../../services/qr_service.dart';
import '../../state/app_controller.dart';
import 'outbound_settings_page.dart';

class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final Set<String> _updating = {};
  final Set<String> _collapsed = {};
  bool _searchOpen = false;
  bool _savingSubscriptionOrder = false;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final dockInset = MediaQuery.paddingOf(context).bottom;
    final hasNodes = controller.hasNodes;
    final automatic = controller.settings.selectionMode == SelectionMode.auto;
    final highlightedNode = !automatic
        ? controller.currentNode
        : controller.running
        ? controller.reportedNode
        : controller.offlineRecommendedNode;
    final highlightedId = highlightedNode?.id;
    final groups = _buildGroups(controller, automatic ? null : highlightedId);
    final allTestRequested = controller.isNodeTestRequested(null);
    final testProgress = controller.testingAllNodes
        ? controller.testCompleted / controller.testTotal
        : null;
    final testLabel = testProgress != null
        ? '测速中 ${controller.testCompleted}/${controller.testTotal}'
        : allTestRequested
        ? '排队中'
        : '测速';
    return PageFrame(
      title: '节点',
      titleWidget: _searchOpen
          ? TextField(
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
              decoration: const InputDecoration(
                hintText: '搜索节点、地址或协议',
                isDense: true,
              ),
            )
          : null,
      wrapHeader: !_searchOpen,
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_searchOpen) ...[
            _SelectionToggle(controller: controller),
            const SizedBox(width: 8),
            HeaderIconButton(
              icon: Icons.settings_outlined,
              tooltip: '高级',
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => OutboundSettingsPage(controller: controller),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            icon: Icon(
              _searchOpen ? Icons.close_rounded : Icons.search_rounded,
            ),
            tooltip: _searchOpen ? '关闭搜索' : '搜索节点',
            onPressed: _searchOpen || hasNodes ? _toggleSearch : null,
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (hasNodes) ...[
            FloatingActionButton.extended(
              heroTag: 'nodes-speed',
              tooltip: allTestRequested ? null : '测速所有分组节点',
              onPressed: allTestRequested
                  ? null
                  : () => _startNodeTest(
                      context,
                      controller,
                      controller.snapshot.allNodes,
                    ),
              icon: allTestRequested
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        value: testProgress,
                        strokeWidth: 2.2,
                      ),
                    )
                  : const Icon(Icons.speed_rounded),
              label: Text(testLabel),
            ),
            const SizedBox(height: 12),
          ],
          FloatingActionButton.extended(
            heroTag: 'nodes-add',
            onPressed: () => _showAddSheet(context, controller),
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加'),
          ),
        ],
      ),
      slivers: [
        if (groups.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: dockInset),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: SizedBox(
                    width: double.infinity,
                    child: EmptyState(
                      icon: _query.isEmpty
                          ? Icons.hub_outlined
                          : Icons.search_off_rounded,
                      title: _query.isEmpty ? '暂无节点' : '没有匹配的节点',
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 168 + dockInset),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final gutter =
                    (constraints.crossAxisExtent - PageFrame.maxContentWidth)
                        .clamp(0.0, double.infinity) /
                    2;
                return SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: gutter),
                  sliver: SliverReorderableList(
                    proxyDecorator: (child, _, _) => child,
                    onReorderItem: (oldIndex, newIndex) =>
                        _reorderSubscriptions(
                          controller,
                          groups,
                          oldIndex,
                          newIndex,
                        ),
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      return Padding(
                        key: ValueKey(group.id),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _GroupCard(
                          group: group,
                          controller: controller,
                          reorderIndex:
                              group.subscription?.isUrlSubscription == true
                              ? index
                              : null,
                          reorderEnabled: !_savingSubscriptionOrder,
                          highlightedId: highlightedId,
                          expanded:
                              _query.isNotEmpty ||
                              !_collapsed.contains(group.id),
                          updating: _updating.contains(group.id),
                          countLabel: _countLabel(group),
                          onToggleExpanded: () => setState(() {
                            if (!_collapsed.remove(group.id)) {
                              _collapsed.add(group.id);
                            }
                          }),
                          onUpdate:
                              group.subscription?.isUrlSubscription == true
                              ? () => _updateSubscription(
                                  controller,
                                  group.subscription!,
                                )
                              : null,
                          onEditGroup: group.subscription == null
                              ? null
                              : () => _showEditGroup(
                                  context,
                                  controller,
                                  group.subscription!,
                                ),
                          onAddNode:
                              group.subscription != null &&
                                  !group.subscription!.isUrlSubscription
                              ? () => _showGroupAddSheet(
                                  context,
                                  controller,
                                  group.subscription!,
                                )
                              : null,
                          onDeleteGroup: group.subscription == null
                              ? null
                              : () => _deleteGroup(
                                  context,
                                  controller,
                                  group.subscription!,
                                ),
                          onFilter: group.subscription == null
                              ? null
                              : () => _showFilterDialog(
                                  context,
                                  controller,
                                  group.subscription!,
                                ),
                          onSort: group.subscription == null
                              ? null
                              : () => _showSortDialog(
                                  context,
                                  controller,
                                  group.subscription!,
                                ),
                          onToggleGroupAuto: group.subscription == null
                              ? null
                              : () => controller.toggleGroupAutoCandidate(
                                  group.subscription!.id,
                                ),
                          onTest: () => _startNodeTest(
                            context,
                            controller,
                            group.nodes,
                            groupId: group.id,
                          ),
                          onSelectNode: controller.selectNode,
                          onToggleAuto: controller.toggleAutoCandidate,
                          onToggleFavorite: controller.toggleFavorite,
                          onEditNode: (node) =>
                              _showEditNode(context, controller, node),
                          onDeleteNode: (node) =>
                              _deleteNode(context, controller, node),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _reorderSubscriptions(
    AppController controller,
    List<_NodeGroup> groups,
    int oldIndex,
    int newIndex,
  ) async {
    if (_savingSubscriptionOrder || oldIndex == newIndex) return;
    final reordered = groups.toList();
    reordered.insert(newIndex, reordered.removeAt(oldIndex));
    setState(() => _savingSubscriptionOrder = true);
    try {
      await controller.reorderSubscriptions([
        for (final group in reordered)
          if (group.subscription?.isUrlSubscription == true) group.id,
      ]);
    } finally {
      if (mounted) setState(() => _savingSubscriptionOrder = false);
    }
  }

  void _toggleSearch() => setState(() {
    _searchOpen = !_searchOpen;
    _query = '';
  });

  String _countLabel(_NodeGroup group) {
    if (_query.isNotEmpty) return '${group.nodes.length} 个匹配';
    if (group.filterActive) {
      return '${group.filteredCount}/${group.totalCount} 节点';
    }
    return '${group.totalCount} 节点';
  }

  List<_NodeGroup> _buildGroups(
    AppController controller,
    String? activeGroupNodeId,
  ) {
    final groups = <_NodeGroup>[];
    final subscriptions = controller.snapshot.subscriptions;
    final known = {for (final subscription in subscriptions) subscription.id};
    final query = _query;
    final orphans = <ProxyNode>[];
    final sortLatencies = controller.testingNodes
        ? const <String, int>{}
        : controller.latencies;
    for (final subscription in subscriptions) {
      var active = false;
      for (final node in subscription.nodes) {
        if (node.id == activeGroupNodeId) active = true;
        if (!known.contains(node.subscriptionId)) orphans.add(node);
      }
      final filtered = applyNodeView(
        nodes: subscription.nodes,
        includeFilter: subscription.includeFilter,
        excludeFilter: subscription.excludeFilter,
        sortMode: subscription.sortMode,
        sortDescending: subscription.sortDescending,
        latencies: sortLatencies,
      );
      final matched = query.isEmpty
          ? filtered
          : filtered.where((node) => _matchesQuery(node, query)).toList();
      if (subscription.id == 'local' &&
          subscription.nodes.isEmpty &&
          _query.isEmpty) {
        continue;
      }
      if (_query.isNotEmpty && matched.isEmpty) continue;
      groups.add(
        _NodeGroup(
          id: subscription.id,
          name: subscription.name,
          totalCount: subscription.nodes.length,
          filteredCount: filtered.length,
          filterActive:
              subscription.includeFilter.trim().isNotEmpty ||
              subscription.excludeFilter.trim().isNotEmpty,
          nodes: matched,
          subscription: subscription,
          active: active,
        ),
      );
    }
    if (orphans.isNotEmpty) {
      final matched = query.isEmpty
          ? orphans
          : orphans.where((node) => _matchesQuery(node, query)).toList();
      if (_query.isEmpty || matched.isNotEmpty) {
        groups.add(
          _NodeGroup(
            id: '__other',
            name: '其他',
            totalCount: orphans.length,
            filteredCount: orphans.length,
            filterActive: false,
            nodes: matched,
            active: orphans.any((node) => node.id == activeGroupNodeId),
          ),
        );
      }
    }
    return groups;
  }

  bool _matchesQuery(ProxyNode node, String query) {
    return node.name.toLowerCase().contains(query) ||
        node.server.toLowerCase().contains(query) ||
        node.protocol.toLowerCase().contains(query);
  }

  void _startNodeTest(
    BuildContext context,
    AppController controller,
    List<ProxyNode> nodes, {
    String? groupId,
  }) {
    if (!controller.canQueueNodeTest) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在应用设置，请稍候')));
      return;
    }
    if (nodes.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可测试的节点')));
      return;
    }
    controller.queueNodeTest(nodes, groupId: groupId);
  }

  Future<void> _updateSubscription(
    AppController controller,
    Subscription subscription,
  ) async {
    if (_updating.contains(subscription.id)) return;
    setState(() => _updating.add(subscription.id));
    try {
      await controller.updateSubscription(subscription.id);
    } finally {
      if (mounted) setState(() => _updating.remove(subscription.id));
    }
  }

  Future<void> _deleteGroup(
    BuildContext context,
    AppController controller,
    Subscription subscription,
  ) async {
    final confirmed = await confirmDialog(
      context,
      title: subscription.isUrlSubscription ? '删除订阅' : '删除分组',
      message: '删除「${subscription.name}」及其中 ${subscription.nodes.length} 个节点？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed) await controller.deleteSubscription(subscription.id);
  }

  Future<void> _showEditGroup(
    BuildContext context,
    AppController controller,
    Subscription subscription,
  ) async {
    final isSubscription = subscription.isUrlSubscription;
    final result = await showDialog<_EditSubscriptionResult>(
      context: context,
      builder: (context) => _EditSubscriptionDialog(subscription: subscription),
    );
    if (result == null) return;
    try {
      await controller.updateSubscriptionInfo(
        subscription.id,
        name: result.name,
        url: result.url,
        userAgent: result.userAgent,
        autoUpdate: result.autoUpdate,
        updateIntervalMinutes: result.updateIntervalMinutes,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(isSubscription ? '订阅信息已保存' : '分组已重命名')),
    );
    if (isSubscription &&
        result.url.isNotEmpty &&
        result.url != subscription.url) {
      await _updateSubscription(controller, subscription);
    }
  }

  Future<void> _showFilterDialog(
    BuildContext context,
    AppController controller,
    Subscription subscription,
  ) async {
    var include = subscription.includeFilter;
    var exclude = subscription.excludeFilter;
    final result = await showDialog<({String include, String exclude})>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('节点过滤'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                initialValue: subscription.includeFilter,
                onChanged: (value) => include = value,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '包含关键词',
                  hintText: '例：香港, 日本',
                  helperText: '留空显示全部；匹配名称、地址、协议',
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                initialValue: subscription.excludeFilter,
                onChanged: (value) => exclude = value,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '排除关键词',
                  hintText: '例：剩余流量, 到期',
                  helperText: '留空不排除；多个关键词用逗号分隔',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (subscription.includeFilter.isNotEmpty ||
              subscription.excludeFilter.isNotEmpty)
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (include: '', exclude: '')),
              child: const Text('清除过滤'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              include: include.trim(),
              exclude: exclude.trim(),
            )),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await controller.updateGroupPreferences(
      subscription.id,
      includeFilter: result.include,
      excludeFilter: result.exclude,
    );
  }

  Future<void> _showSortDialog(
    BuildContext context,
    AppController controller,
    Subscription subscription,
  ) async {
    var mode = subscription.sortMode;
    var descending = subscription.sortDescending;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('节点排序'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in const [
                      (NodeSortMode.manual, '默认顺序'),
                      (NodeSortMode.name, '名称'),
                      (NodeSortMode.protocol, '协议'),
                      (NodeSortMode.latency, '延迟'),
                      (NodeSortMode.favorite, '收藏优先'),
                    ])
                      ChoiceChip(
                        label: Text(item.$2),
                        selected: mode == item.$1,
                        onSelected: (_) => setDialogState(() => mode = item.$1),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('降序排列'),
                  value: descending,
                  onChanged: (value) =>
                      setDialogState(() => descending = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    await controller.updateGroupPreferences(
      subscription.id,
      sortMode: mode,
      sortDescending: descending,
    );
  }

  Future<void> _deleteNode(
    BuildContext context,
    AppController controller,
    ProxyNode node,
  ) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除节点',
      message: '删除「${node.name}」？订阅节点会在下次更新后恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed) await controller.deleteNode(node.id);
  }

  Future<void> _showAddSheet(
    BuildContext context,
    AppController controller,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('添加分组', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('订阅分组'),
              onTap: () => Navigator.pop(context, 'url'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('节点分组'),
              onTap: () => Navigator.pop(context, 'group'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'url':
        await _showUrlDialog(context, controller);
      case 'group':
        await _createGroup(context, controller);
    }
  }

  Future<void> _showGroupAddSheet(
    BuildContext context,
    AppController controller,
    Subscription group,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('添加节点', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.add_link_rounded),
              title: const Text('单个节点'),
              onTap: () => Navigator.pop(context, 'link'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.content_paste_rounded),
              title: const Text('从剪贴板导入'),
              onTap: () => Navigator.pop(context, 'clipboard'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('从文件导入'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.qr_code_2_rounded),
              title: const Text('从二维码图片导入'),
              onTap: () => Navigator.pop(context, 'qr'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'link':
        await _showNodeLinkDialog(context, controller, group: group);
      case 'clipboard':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text?.trim() ?? '';
        if (text.isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('剪贴板为空')));
          }
          return;
        }
        if (context.mounted) {
          await _showContentDialog(context, controller, text, group: group);
        }
      case 'file':
        final files = await FilePicker.pickFiles();
        final file = files.isEmpty ? null : files.first;
        if (file == null) return;
        final content = utf8.decode(await file.readAsBytes());
        if (context.mounted) {
          await _showContentDialog(context, controller, content, group: group);
        }
      case 'qr':
        final files = await FilePicker.pickFiles(
          type: FileType.image,
          dialogTitle: '选择二维码图片',
        );
        final file = files.isEmpty ? null : files.first;
        if (file == null) return;
        String? content;
        try {
          content = await decodeQrFromImageBytes(await file.readAsBytes());
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('读取图片失败：$e')));
          }
          return;
        }
        if (content == null || content.trim().isEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('图片中没有识别到二维码')));
          }
          return;
        }
        if (context.mounted) {
          await _showContentDialog(context, controller, content, group: group);
        }
    }
  }

  Future<void> _createGroup(
    BuildContext context,
    AppController controller,
  ) async {
    final formKey = GlobalKey<FormState>();
    var name = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建节点分组'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: formKey,
            child: TextFormField(
              onChanged: (value) => name = value,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '分组名称',
                hintText: '例：常用节点',
              ),
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? '请输入分组名称' : null,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(context, name.trim());
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      final group = await controller.createGroup(result);
      if (!mounted) return;
      setState(() => _collapsed.remove(group.id));
      ScaffoldMessenger.of(this.context)
          .showSnackBar(SnackBar(content: Text('已创建「${group.name}」')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _showNodeLinkDialog(
    BuildContext context,
    AppController controller, {
    required Subscription group,
  }) async {
    var link = '';
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('添加节点'),
        content: SizedBox(
          width: 560,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  onChanged: (value) => link = value,
                  minLines: 4,
                  maxLines: 8,
                  autofocus: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'ss://…  或  vless://…',
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? '请输入节点链接'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(context, link.trim());
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result == null || !context.mounted) return;
    try {
      final node = await controller.addNodeLink(result, groupId: group.id);
      if (!mounted) return;
      setState(() => _collapsed.remove(node.subscriptionId));
      ScaffoldMessenger.of(this.context)
          .showSnackBar(SnackBar(content: Text('已添加「${node.name}」')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _showUrlDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final submitted = await showDialog<bool>(
      context: context,
      builder: (_) => _SubscriptionImportDialog(controller: controller),
    );
    if (submitted == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('订阅已导入')));
    }
  }

  Future<void> _showContentDialog(
    BuildContext context,
    AppController controller,
    String content, {
    required Subscription group,
  }) async {
    var loading = false;
    String? error;
    final submitted = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('导入节点'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '目标分组：${group.name}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 150,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      content.length > 1600
                          ? '${content.substring(0, 1600)}\n…'
                          : content,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (loading) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: loading ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: loading
                  ? null
                  : () async {
                      setDialogState(() {
                        loading = true;
                        error = null;
                      });
                      try {
                        final count = await controller.importNodesToGroup(
                          group.id,
                          content,
                        );
                        if (context.mounted) Navigator.pop(context, count);
                      } catch (e) {
                        if (!context.mounted) return;
                        setDialogState(() {
                          loading = false;
                          error = e.toString();
                        });
                      }
                    },
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    if (submitted != null && context.mounted) {
      if (mounted) setState(() => _collapsed.remove(group.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $submitted 个节点到「${group.name}」')),
      );
    }
  }

  Future<void> _showEditNode(
    BuildContext context,
    AppController controller,
    ProxyNode node,
  ) async {
    final initialJson = const JsonEncoder.withIndent('  ')
        .convert(node.outbound);
    var name = node.name;
    var outboundJson = initialJson;
    String? error;
    final result =
        await showDialog<({String name, Map<String, dynamic> outbound})>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              scrollable: true,
              title: Text('编辑 ${node.name}'),
              content: SizedBox(
                width: 640,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      initialValue: node.name,
                      onChanged: (value) => name = value,
                      decoration: const InputDecoration(labelText: '名称'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: initialJson,
                      onChanged: (value) => outboundJson = value,
                      minLines: 10,
                      maxLines: 16,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'sing-box 出站 JSON',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    try {
                      final decoded = jsonDecode(outboundJson);
                      if (decoded is! Map) {
                        throw const FormatException('出站必须是 JSON 对象');
                      }
                      final map = Map<String, dynamic>.from(decoded);
                      if (map['type'] is! String) {
                        throw const FormatException('出站缺少 type');
                      }
                      final trimmedName = name.trim();
                      if (trimmedName.isEmpty) {
                        throw const FormatException('名称不能为空');
                      }
                      Navigator.pop(context, (
                        name: trimmedName,
                        outbound: map,
                      ));
                    } catch (e) {
                      setState(() => error = 'JSON 无效：$e');
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
    if (result != null) {
      await controller.updateNode(
        node.id,
        name: result.name,
        outbound: result.outbound,
      );
    }
  }
}

class _SubscriptionImportDialog extends StatefulWidget {
  const _SubscriptionImportDialog({required this.controller});

  final AppController controller;

  @override
  State<_SubscriptionImportDialog> createState() =>
      _SubscriptionImportDialogState();
}

class _SubscriptionImportDialogState extends State<_SubscriptionImportDialog> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _uaController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _uaController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading || _formKey.currentState?.validate() != true) return;
    final route = ModalRoute.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await widget.controller.importFromUrl(
        url: _urlController.text.trim(),
        name: _nameController.text,
        userAgent: _uaController.text.trim(),
      );
    } catch (error) {
      if (!mounted || route?.isActive != true) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
      return;
    }
    if (mounted && route?.isCurrent == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('新建订阅分组'),
    content: SizedBox(
      width: 520,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _urlController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '订阅 URL',
                hintText: 'https://example.com/sub',
              ),
              validator: (value) {
                final uri = Uri.tryParse(value?.trim() ?? '');
                if (uri == null ||
                    !(uri.scheme == 'http' || uri.scheme == 'https')) {
                  return '请输入有效的 http(s) 链接';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称（可选）'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _uaController,
              decoration: const InputDecoration(
                labelText: 'User-Agent（可选）',
                hintText: '留空使用 NekoProxy 默认值',
              ),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_loading) ...[
              const SizedBox(height: 14),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _loading ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _loading ? null : _submit,
        child: const Text('导入'),
      ),
    ],
  );
}

class _SelectionToggle extends StatelessWidget {
  const _SelectionToggle({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SlidingSegmentedControl<SelectionMode>(
      width: 142,
      segments: const [
        SlidingSegmentOption(
          value: SelectionMode.manual,
          label: '手动',
          icon: Icons.pan_tool_alt_rounded,
        ),
        SlidingSegmentOption(
          value: SelectionMode.auto,
          label: '自动',
          icon: Icons.auto_awesome_rounded,
        ),
      ],
      selected: controller.settings.selectionMode,
      onChanged: controller.busy ? null : controller.setSelectionMode,
    );
  }
}

String _updateHoursText(int minutes) {
  final hours = minutes / 60;
  if (hours == hours.roundToDouble()) return hours.round().toString();
  return hours
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

int? _updateMinutesFromHours(String value) {
  final hours = double.tryParse(value.trim());
  if (hours == null || !hours.isFinite || hours <= 0) return null;
  return (hours * 60).round();
}

String _protocolBadge(String protocol) => switch (protocol.toLowerCase()) {
  'shadowsocks' => 'SS',
  'shadowsocksr' => 'SSR',
  'vmess' => 'VM',
  'vless' => 'VLESS',
  'trojan' => 'TR',
  'hysteria' => 'HY',
  'hysteria2' => 'HY2',
  'tuic' => 'TUIC',
  'wireguard' => 'WG',
  'socks' => 'SOCKS',
  'http' => 'HTTP',
  'ssh' => 'SSH',
  'tor' => 'TOR',
  'anytls' => 'ANY',
  _ =>
    protocol.length <= 4
        ? protocol.toUpperCase()
        : protocol.substring(0, 3).toUpperCase(),
};

class _NodeGroup {
  const _NodeGroup({
    required this.id,
    required this.name,
    required this.nodes,
    required this.totalCount,
    required this.filteredCount,
    required this.filterActive,
    required this.active,
    this.subscription,
  });

  final String id;
  final String name;
  final List<ProxyNode> nodes;
  final int totalCount;
  final int filteredCount;
  final bool filterActive;
  final bool active;
  final Subscription? subscription;
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.controller,
    required this.reorderIndex,
    required this.reorderEnabled,
    required this.highlightedId,
    required this.expanded,
    required this.updating,
    required this.countLabel,
    required this.onToggleExpanded,
    required this.onUpdate,
    required this.onEditGroup,
    required this.onAddNode,
    required this.onDeleteGroup,
    required this.onFilter,
    required this.onSort,
    required this.onToggleGroupAuto,
    required this.onTest,
    required this.onSelectNode,
    required this.onToggleAuto,
    required this.onToggleFavorite,
    required this.onEditNode,
    required this.onDeleteNode,
  });

  final _NodeGroup group;
  final AppController controller;
  final int? reorderIndex;
  final bool reorderEnabled;
  final String? highlightedId;
  final bool expanded;
  final bool updating;
  final String countLabel;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onUpdate;
  final VoidCallback? onEditGroup;
  final VoidCallback? onAddNode;
  final VoidCallback? onDeleteGroup;
  final VoidCallback? onFilter;
  final VoidCallback? onSort;
  final VoidCallback? onToggleGroupAuto;
  final VoidCallback onTest;
  final ValueChanged<String> onSelectNode;
  final ValueChanged<String> onToggleAuto;
  final ValueChanged<String> onToggleFavorite;
  final ValueChanged<ProxyNode> onEditNode;
  final ValueChanged<ProxyNode> onDeleteNode;

  @override
  Widget build(BuildContext context) =>
      _GroupCardSurface(active: group.active, builder: _buildContent);

  Widget _buildContent(
    BuildContext context,
    bool hovered,
    ValueChanged<bool> onPressedChanged,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final subscription = group.subscription;
    final testRequested =
        controller.isNodeTestRequested(group.id) ||
        controller.isNodeTestRequested(null);
    final actionStyle = _groupActionStyle(scheme, background: false, size: 32);
    final isUrlSubscription = subscription?.isUrlSubscription ?? false;
    final filterActive =
        subscription != null &&
        (subscription.includeFilter.trim().isNotEmpty ||
            subscription.excludeFilter.trim().isNotEmpty);
    final sortActive =
        subscription != null && subscription.sortMode != NodeSortMode.manual;
    final typeLabel = subscription == null
        ? '节点'
        : isUrlSubscription
        ? '订阅'
        : '节点集合';
    final content = Padding(
      padding: EdgeInsets.only(left: reorderIndex == null ? 0 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggleExpanded,
              onHighlightChanged: onPressedChanged,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isUrlSubscription
                            ? Icons.cloud_outlined
                            : Icons.folder_outlined,
                        size: 19,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  group.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (subscription?.lastError != null) ...[
                                const SizedBox(width: 6),
                                Tooltip(
                                  message: subscription!.lastError!,
                                  child: Icon(
                                    Icons.error_outline_rounded,
                                    size: 16,
                                    color: scheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$typeLabel · $countLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 2),
                    if (subscription != null && !subscription.autoEnabled) ...[
                      _GroupActionButton(
                        tooltip: '已移出自动候选，点击恢复',
                        onPressed: onToggleGroupAuto,
                        child: Icon(
                          Icons.playlist_remove_rounded,
                          size: 17,
                          color: scheme.tertiary,
                        ),
                      ),
                      const SizedBox(width: 2),
                    ],
                    _GroupActionButton(
                      tooltip: '测试本组节点',
                      onPressed: testRequested || group.nodes.isEmpty
                          ? null
                          : onTest,
                      child: testRequested
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.speed_rounded, size: 18),
                    ),
                    if (onEditGroup != null ||
                        onDeleteGroup != null ||
                        onAddNode != null ||
                        onUpdate != null ||
                        onFilter != null ||
                        onSort != null ||
                        onToggleGroupAuto != null) ...[
                      const SizedBox(width: 2),
                      PopupMenuButton<String>(
                        tooltip: '分组设置',
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        menuPadding: const EdgeInsets.symmetric(vertical: 6),
                        style: actionStyle,
                        icon: updating
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.more_vert_rounded,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                        onSelected: (value) {
                          switch (value) {
                            case 'update':
                              onUpdate?.call();
                            case 'edit':
                              onEditGroup?.call();
                            case 'addNode':
                              onAddNode?.call();
                            case 'filter':
                              onFilter?.call();
                            case 'sort':
                              onSort?.call();
                            case 'groupAuto':
                              onToggleGroupAuto?.call();
                            case 'delete':
                              onDeleteGroup?.call();
                          }
                        },
                        itemBuilder: (context) => [
                          if (onUpdate != null)
                            _menuItem(
                              value: 'update',
                              icon: Icons.refresh_rounded,
                              label: updating ? '正在更新…' : '更新订阅',
                              enabled: !updating,
                            ),
                          if (onEditGroup != null)
                            _menuItem(
                              value: 'edit',
                              icon: Icons.edit_outlined,
                              label: isUrlSubscription ? '编辑订阅' : '重命名分组',
                            ),
                          if (onAddNode != null)
                            _menuItem(
                              value: 'addNode',
                              icon: Icons.add_rounded,
                              label: '添加节点',
                            ),
                          if (onFilter != null)
                            _menuItem(
                              value: 'filter',
                              icon: Icons.filter_alt_outlined,
                              label: '节点过滤',
                              trailing: filterActive
                                  ? '${group.filteredCount}/${group.totalCount}'
                                  : null,
                            ),
                          if (onSort != null)
                            _menuItem(
                              value: 'sort',
                              icon: Icons.sort_rounded,
                              label: '节点排序',
                              trailing: sortActive
                                  ? _sortLabel(
                                      subscription.sortMode,
                                      subscription.sortDescending,
                                    )
                                  : null,
                            ),
                          if (onToggleGroupAuto != null)
                            _menuItem(
                              value: 'groupAuto',
                              icon: subscription!.autoEnabled
                                  ? Icons.playlist_remove_rounded
                                  : Icons.playlist_add_check_rounded,
                              label: subscription.autoEnabled
                                  ? '移出自动候选'
                                  : '加入自动候选',
                            ),
                          if (onDeleteGroup != null) ...[
                            const PopupMenuDivider(height: 9),
                            _menuItem(
                              value: 'delete',
                              icon: Icons.delete_outline_rounded,
                              label: isUrlSubscription ? '删除订阅' : '删除分组',
                              color: scheme.error,
                            ),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(width: 4),
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: hovered
                            ? actionStyle.overlayColor?.resolve({
                                WidgetState.hovered,
                              })
                            : scheme.surfaceContainerHighest.withValues(
                                alpha: 0.55,
                              ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (subscription != null)
            _SubscriptionMeta(subscription: subscription),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: scheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                      if (group.nodes.isEmpty)
                        _EmptyGroup(
                          filterActive: group.filterActive,
                          canAdd: onAddNode != null,
                          onFilter: onFilter,
                          onAdd: onAddNode,
                        )
                      else
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = constraints.maxWidth >= 940
                                ? 4
                                : constraints.maxWidth >= 620
                                ? 3
                                : 2;
                            return GridView.builder(
                              shrinkWrap: true,
                              primary: false,
                              physics: const NeverScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                              itemCount: group.nodes.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisExtent: 74,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                  ),
                              itemBuilder: (context, index) {
                                final node = group.nodes[index];
                                return _NodeTile(
                                  node: node,
                                  controller: controller,
                                  current: node.id == highlightedId,
                                  onSelect: () => onSelectNode(node.id),
                                  onToggleAuto: () => onToggleAuto(node.id),
                                  onToggleFavorite: () =>
                                      onToggleFavorite(node.id),
                                  onEdit: () => onEditNode(node),
                                  onDelete: () => onDeleteNode(node),
                                );
                              },
                            );
                          },
                        ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        content,
        if (reorderIndex case final index?)
          Positioned(
            left: 0,
            child: ReorderableDragStartListener(
              index: index,
              enabled: reorderEnabled,
              child: Tooltip(
                message: '拖拽调整订阅顺序',
                child: MouseRegion(
                  cursor: reorderEnabled
                      ? SystemMouseCursors.grab
                      : MouseCursor.defer,
                  child: SizedBox(
                    width: 30,
                    height: 44,
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _GroupCardSurface extends StatefulWidget {
  const _GroupCardSurface({required this.active, required this.builder});

  final bool active;
  final Widget Function(
    BuildContext context,
    bool hovered,
    ValueChanged<bool> onPressedChanged,
  )
  builder;

  @override
  State<_GroupCardSurface> createState() => _GroupCardSurfaceState();
}

class _GroupCardSurfaceState extends State<_GroupCardSurface>
    with SingleTickerProviderStateMixin {
  late final _pressOpacity = AnimationController(
    vsync: this,
    reverseDuration: const Duration(milliseconds: 200),
  );
  bool _hovered = false;

  @override
  void dispose() {
    _pressOpacity.dispose();
    super.dispose();
  }

  void _updatePressHighlight(bool pressed) {
    if (pressed) {
      // Even a quick tap that ends before the next frame leaves a visible fade.
      _pressOpacity.value = 1;
    } else {
      _pressOpacity.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background = scheme.surfaceContainerLow;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _hovered
              ? Color.alphaBlend(theme.hoverColor, background)
              : background,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            width: widget.active ? 1.4 : 1,
            color: widget.active
                ? scheme.primary.withValues(alpha: 0.65)
                : scheme.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: FadeTransition(
                  opacity: _pressOpacity,
                  child: ColoredBox(color: theme.highlightColor),
                ),
              ),
            ),
            widget.builder(context, _hovered, _updatePressHighlight),
          ],
        ),
      ),
    );
  }
}

ButtonStyle _groupActionStyle(
  ColorScheme scheme, {
  bool background = true,
  double size = 36,
}) {
  return IconButton.styleFrom(
    backgroundColor: background
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
        : Colors.transparent,
    foregroundColor: scheme.onSurfaceVariant,
    disabledBackgroundColor: background
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.3)
        : Colors.transparent,
    disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.45),
    fixedSize: Size(size, size),
    minimumSize: Size(size, size),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
}

class _GroupActionButton extends StatelessWidget {
  const _GroupActionButton({
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: _groupActionStyle(scheme, background: false, size: 32),
      icon: child,
    );
  }
}

PopupMenuItem<String> _menuItem({
  required String value,
  required IconData icon,
  required String label,
  String? trailing,
  Color? color,
  bool enabled = true,
}) {
  return PopupMenuItem<String>(
    value: value,
    enabled: enabled,
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: _MenuRow(icon: icon, label: label, trailing: trailing, color: color),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.color,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = color ?? scheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 17, color: color ?? scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foreground,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          Text(
            trailing!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

String _sortLabel(NodeSortMode mode, bool descending) {
  if (mode == NodeSortMode.manual) return '排序';
  final label = switch (mode) {
    NodeSortMode.manual => '排序',
    NodeSortMode.name => '名称',
    NodeSortMode.protocol => '协议',
    NodeSortMode.latency => '延迟',
    NodeSortMode.favorite => '收藏',
  };
  return '$label ${descending ? '↓' : '↑'}';
}

class _EmptyGroup extends StatelessWidget {
  const _EmptyGroup({
    required this.filterActive,
    required this.canAdd,
    required this.onFilter,
    required this.onAdd,
  });

  final bool filterActive;
  final bool canAdd;
  final VoidCallback? onFilter;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 14, 16),
      child: Row(
        children: [
          Icon(
            filterActive ? Icons.filter_alt_off_outlined : Icons.inbox_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              filterActive ? '过滤后没有节点' : '暂无节点',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (filterActive && onFilter != null)
            TextButton(onPressed: onFilter, child: const Text('调整过滤'))
          else if (canAdd && onAdd != null)
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加节点'),
            ),
        ],
      ),
    );
  }
}

class _EditSubscriptionResult {
  const _EditSubscriptionResult({
    required this.name,
    required this.url,
    required this.userAgent,
    required this.autoUpdate,
    required this.updateIntervalMinutes,
  });

  final String name;
  final String url;
  final String userAgent;
  final bool? autoUpdate;
  final int? updateIntervalMinutes;
}

class _EditSubscriptionDialog extends StatefulWidget {
  const _EditSubscriptionDialog({required this.subscription});

  final Subscription subscription;

  @override
  State<_EditSubscriptionDialog> createState() =>
      _EditSubscriptionDialogState();
}

class _EditSubscriptionDialogState extends State<_EditSubscriptionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _userAgent;
  late final TextEditingController _updateInterval;
  late bool _autoUpdate;

  bool get _isSubscription => widget.subscription.isUrlSubscription;

  @override
  void initState() {
    super.initState();
    final subscription = widget.subscription;
    _name = TextEditingController(text: subscription.name);
    _url = TextEditingController(text: subscription.url);
    _userAgent = TextEditingController(text: subscription.userAgent);
    _updateInterval = TextEditingController(
      text: _updateHoursText(subscription.effectiveUpdateIntervalMinutes),
    );
    _autoUpdate = subscription.autoUpdate;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _userAgent.dispose();
    _updateInterval.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(
      _EditSubscriptionResult(
        name: _name.text.trim(),
        url: _isSubscription ? _url.text.trim() : '',
        userAgent: _isSubscription ? _userAgent.text.trim() : '',
        autoUpdate: _isSubscription ? _autoUpdate : null,
        updateIntervalMinutes: _isSubscription && _autoUpdate
            ? _updateMinutesFromHours(_updateInterval.text)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(_isSubscription ? '编辑订阅' : '重命名分组'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                autofocus: !_isSubscription,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? '请输入名称' : null,
              ),
              if (_isSubscription) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: '订阅链接',
                    hintText: 'https://example.com/sub',
                  ),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    if (text.isEmpty) return null;
                    final uri = Uri.tryParse(text);
                    if (uri == null ||
                        !(uri.scheme == 'http' || uri.scheme == 'https')) {
                      return '请输入有效的 http(s) 链接';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _userAgent,
                  decoration: const InputDecoration(
                    labelText: 'User-Agent（可选）',
                  ),
                ),
                const SizedBox(height: 8),
                SwitchRow(
                  title: '自动更新',
                  icon: Icons.update_rounded,
                  value: _autoUpdate,
                  onChanged: (value) => setState(() => _autoUpdate = value),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _updateInterval,
                  enabled: _autoUpdate,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '更新周期（小时）'),
                  validator: (value) {
                    if (!_autoUpdate) return null;
                    final minutes = _updateMinutesFromHours(value ?? '');
                    if (minutes == null) return '请输入有效的更新周期';
                    if (minutes < Subscription.minimumUpdateIntervalMinutes) {
                      return '更新周期不能短于 30 分钟';
                    }
                    if (minutes > Subscription.maximumUpdateIntervalMinutes) {
                      return '更新周期不能超过 30 天';
                    }
                    return null;
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

class _SubscriptionMeta extends StatelessWidget {
  const _SubscriptionMeta({required this.subscription});

  final Subscription subscription;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = subscription.totalBytes;
    final used =
        (subscription.uploadBytes ?? 0) + (subscription.downloadBytes ?? 0);
    final hasTraffic = total != null && total > 0;
    final showNoTraffic = subscription.isUrlSubscription && !hasTraffic;
    final progress = hasTraffic ? (used / total).clamp(0.0, 1.0) : 0.0;
    final expire = subscription.expireAt;
    final updated = subscription.lastUpdated;
    final error = subscription.lastError;
    final hasDetails =
        showNoTraffic || expire != null || updated != null || error != null;
    if (!hasTraffic && !hasDetails) {
      return const SizedBox.shrink();
    }
    final progressColor = progress >= 0.9 ? scheme.error : scheme.primary;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasTraffic) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '已用 ${formatBytes(used)} / ${formatBytes(total)}',
                    style: labelStyle,
                  ),
                ),
                Text(
                  '${(progress * 100).toStringAsFixed(progress < 0.1 ? 1 : 0)}%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: progressColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            _UsageBar(
              id: subscription.id,
              value: progress,
              color: progressColor,
              trackColor: scheme.surfaceContainerHighest,
            ),
          ],
          if (hasDetails)
            Padding(
              padding: EdgeInsets.only(top: hasTraffic ? 6 : 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (showNoTraffic || expire != null)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showNoTraffic) Text('暂无数据', style: labelStyle),
                          if (expire != null)
                            Text(
                              _expiryText(expire),
                              style: expire.isBefore(DateTime.now())
                                  ? labelStyle?.copyWith(color: scheme.error)
                                  : labelStyle,
                            ),
                        ],
                      ),
                    )
                  else
                    const Spacer(),
                  if (updated != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(_updatedText(updated), style: labelStyle),
                    ),
                ],
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 14,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.error,
                      ),
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

/// Group ids whose usage bar already played its first fill. The node list is a
/// lazy sliver, so a card scrolled out and back is rebuilt from scratch; without
/// this the bar would replay its growth animation on every visit.
final _animatedUsageBars = <String>{};

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.id,
    required this.value,
    required this.color,
    required this.trackColor,
  });

  final String id;
  final double value;
  final Color color;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    final firstBuild = _animatedUsageBars.add(id);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: firstBuild ? 0 : value, end: value),
      duration: Duration(milliseconds: firstBuild ? 500 : 220),
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: animated,
          minHeight: 6,
          backgroundColor: trackColor,
          color: color,
        ),
      ),
    );
  }
}

String _expiryText(DateTime expire) {
  final now = DateTime.now();
  final date = expire.year == now.year
      ? '${expire.month}月${expire.day}日'
      : '${expire.year}年${expire.month}月${expire.day}日';
  if (!expire.isAfter(now)) return '已到期 · $date';
  final days = expire.difference(now).inDays;
  if (days <= 0) return '今天到期 · $date';
  return '$date 到期 · 剩余 $days 天';
}

String _updatedText(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚更新';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前更新';
  if (diff.inHours < 24) return '${diff.inHours} 小时前更新';
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '更新于 ${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

class _NodeStatusTooltip extends StatelessWidget {
  const _NodeStatusTooltip({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Keep adjacent tooltip overlays from sharing a semantics traversal parent.
    return Semantics(
      container: true,
      child: Tooltip(message: message, child: child),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.node,
    required this.controller,
    required this.current,
    required this.onSelect,
    required this.onToggleAuto,
    required this.onToggleFavorite,
    required this.onEdit,
    required this.onDelete,
  });

  final ProxyNode node;
  final AppController controller;
  final bool current;
  final VoidCallback onSelect;
  final VoidCallback onToggleAuto;
  final VoidCallback onToggleFavorite;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final latency = controller.latencies[node.id];
    final latencyError = controller.latencyErrors[node.id];
    final latencyColor = latency == null
        ? scheme.outline
        : latency < 150
        ? const Color(0xFF1B9E63)
        : latency < 350
        ? const Color(0xFFC68A00)
        : scheme.error;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onSelect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 4),
          decoration: BoxDecoration(
            color: current
                ? scheme.primaryContainer.withValues(alpha: 0.5)
                : scheme.surfaceContainerHighest.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: current
                  ? scheme.primary.withValues(alpha: 0.6)
                  : scheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: current
                          ? scheme.primary
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      _protocolBadge(node.protocol),
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: current
                            ? scheme.onPrimary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '${node.server}:${node.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  if (latencyError != null)
                    _NodeStatusTooltip(
                      message: latencyError,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.error.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '失败',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                  else if (latency == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '—',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: latencyColor,
                        ),
                      ),
                    )
                  else
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: latencyColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        formatLatency(latency),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: latencyColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const Spacer(),
                  if (node.favorite) ...[
                    _NodeStatusTooltip(
                      message: '已收藏',
                      child: Icon(
                        Icons.star_rounded,
                        size: 14,
                        color: scheme.tertiary,
                      ),
                    ),
                    const SizedBox(width: 3),
                  ],
                  if (!node.autoEnabled) ...[
                    _NodeStatusTooltip(
                      message: '已移出自动候选',
                      child: Icon(
                        Icons.playlist_remove_rounded,
                        size: 15,
                        color: scheme.outline,
                      ),
                    ),
                    const SizedBox(width: 3),
                  ],
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: PopupMenuButton<String>(
                      tooltip: '节点操作',
                      padding: EdgeInsets.zero,
                      iconSize: 17,
                      onSelected: (value) {
                        switch (value) {
                          case 'edit':
                            onEdit();
                          case 'delete':
                            onDelete();
                          case 'favorite':
                            onToggleFavorite();
                          case 'auto':
                            onToggleAuto();
                        }
                      },
                      itemBuilder: (context) => [
                        _menuItem(
                          value: 'edit',
                          icon: Icons.edit_outlined,
                          label: '编辑节点',
                        ),
                        _menuItem(
                          value: 'favorite',
                          icon: node.favorite
                              ? Icons.star_outline_rounded
                              : Icons.star_rounded,
                          label: node.favorite ? '取消收藏' : '收藏',
                        ),
                        _menuItem(
                          value: 'auto',
                          icon: node.autoEnabled
                              ? Icons.remove_done_rounded
                              : Icons.playlist_add_check_rounded,
                          label: node.autoEnabled ? '移出自动候选' : '加入自动候选',
                        ),
                        const PopupMenuDivider(height: 9),
                        _menuItem(
                          value: 'delete',
                          icon: Icons.delete_outline_rounded,
                          label: '删除',
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
