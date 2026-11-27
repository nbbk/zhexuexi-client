import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/app_tokens.dart';
import '../../core/userinfo.dart';
import '../../services/announcement_service.dart';
import '../../widgets/glass_card.dart';

/// 公告列表页（2026-11-26 0.1.2 第 3 条）：首页跑马灯 / “我的”页
/// 公告卡点进来，不做单条详情页（全文直接在列表里看）。
///
/// - 置顶在前、其余 `created_at` 倒序；
/// - 每行标题＋正文全文＋时间＋置顶角标；
/// - 空态“暂无公告”只在页内出现（首页与“我的”页没有公告时整卡隐藏）；
/// - 下拉刷新。
class AnnouncementListPage extends ConsumerWidget {
  const AnnouncementListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcements = ref.watch(announcementsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('公告')),
      body: GlassBackground(
        child: announcements.when(
          data: (list) {
            final sorted = Announcement.sortForDisplay(list);
            if (sorted.isEmpty) {
              return RefreshIndicator(
                onRefresh: () => ref.refresh(announcementsProvider.future),
                child: ListView(
                  padding: const EdgeInsets.all(AppTokens.spacingMd),
                  children: const [
                    SizedBox(height: 120),
                    Center(child: Text('暂无公告')),
                  ],
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: () => ref.refresh(announcementsProvider.future),
              child: ListView.separated(
                padding: const EdgeInsets.all(AppTokens.spacingMd),
                itemCount: sorted.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppTokens.spacingSm),
                itemBuilder: (context, index) {
                  final a = sorted[index];
                  return GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTokens.spacingMd),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  a.title.isEmpty ? a.displayLine : a.title,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              if (a.pinned)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      AppTokens.radiusSmall,
                                    ),
                                    border: Border.all(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                  child: const Text('置顶'),
                                ),
                            ],
                          ),
                          const SizedBox(height: AppTokens.spacingXs),
                          Text(a.body),
                          if (a.createdAt != null) ...[
                            const SizedBox(height: AppTokens.spacingXs),
                            Text(
                              formatDateTime(a.createdAt!),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('公告拉取失败'),
                const SizedBox(height: AppTokens.spacingSm),
                FilledButton(
                  onPressed: () => ref.invalidate(announcementsProvider),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
