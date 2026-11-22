/// 订阅 `subscription-userinfo` 响应头的解析。
///
/// 头格式（见 docs/api/panel-adapter.md §2.1）：
///   `upload=123; download=456; total=1073741824; expire=1790000000`
/// 四个字段全是整数：upload/download/total 是字节数，expire 是 Unix 秒时间戳。
/// 注意：这是**中转口径**——直连流量不经过中转机，不在头里（面板 1.3.27
/// 已验证小火箭到期显示正常，但直连流量要靠节点侧计量，见方案 §0）。
///
/// 缺失语义（panel-adapter.md §2.3，三个层次都要分清，绝不能混成 0）：
/// - 整个头没有（三项全都没有时面板不返回这个头）→ [parse] 返回 null，
///   界面显示“—”，**没有头 ≠ 用量为 0**；
/// - 头里缺某个字段（例如管理面板模式下只有 `expire`，没有 upload /
///   download）→ 该字段为 null，界面对应格显示“—”，不编数据；
/// - 字段值非法（不是整数）→ 按缺失处理，同样为 null。
class SubscriptionUserinfo {
  const SubscriptionUserinfo({
    required this.upload,
    required this.download,
    required this.total,
    required this.expire,
  });

  /// 已用上行字节数；头里没有该字段时为 null。
  final int? upload;

  /// 已用下行字节数；头里没有该字段时为 null。
  final int? download;

  /// 总流量字节数；头里没有该字段时为 null。值为 0 表示不限量。
  final int? total;

  /// 到期 Unix 秒时间戳；头里没有该字段时为 null。值为 0 表示永不过期。
  final int? expire;

  /// 已用（上行 + 下行）；任一分量缺失时为 null。
  int? get used =>
      upload == null || download == null ? null : upload! + download!;

  /// 剩余字节数；total 为 null（头里没给）或 0（不限量）或已用未知时为 null。
  /// 超量时为负数，调用方按“已超量”展示。
  int? get remaining {
    final u = used;
    if (total == null || total == 0 || u == null) return null;
    return total! - u;
  }

  /// 是否不限量：total 为 null（头里没给）或 0。
  bool get isUnlimited => total == null || total == 0;

  /// 已用占比 0.0–1.0；不限量或已用未知时为 null。
  double? get usedRatio {
    final u = used;
    if (total == null || total == 0 || u == null) return null;
    if (u <= 0) return 0;
    return (u / total!).clamp(0.0, 1.0);
  }

  /// 是否已到期（expire 为 null 或 0 表示永不过期）。
  bool get isExpired =>
      expire != null &&
      expire != 0 &&
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expire!;

  /// 到期日期；expire 为 null 或 0 时返回 null。
  DateTime? get expireDate => expire == null || expire == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expire! * 1000);

  /// 解析响应头；没有头（null 或空串）返回 null。缺字段与非法值按
  /// 该字段缺失处理，不按 0 兜底（见文件头注释）。
  static SubscriptionUserinfo? parse(String? headerValue) {
    if (headerValue == null || headerValue.trim().isEmpty) return null;
    int? upload;
    int? download;
    int? total;
    int? expire;
    for (final part in headerValue.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length != 2) continue;
      final value = int.tryParse(kv[1].trim());
      if (value == null) continue;
      switch (kv[0].trim()) {
        case 'upload':
          upload = value;
        case 'download':
          download = value;
        case 'total':
          total = value;
        case 'expire':
          expire = value;
      }
    }
    return SubscriptionUserinfo(
      upload: upload,
      download: download,
      total: total,
      expire: expire,
    );
  }

  @override
  String toString() =>
      'SubscriptionUserinfo(used=$used, total=$total, expire=$expire)';
}

/// 字节数转人类可读串：`123 B` / `1.5 KB` / `2.3 MB` / `1.2 GB`。
/// 负数按 0 算（调用方先判超量再格式化）。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// 速率（字节/秒）转人类可读串：`1.5 KB/s`。
String formatSpeed(int bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// 已用 / 总量格：没有 userinfo 头或已用未知时显示“—”，不编数据；
/// 不限量（total 为 null 或 0）时只写已用 + “不限量”。
String usedTotalText(SubscriptionUserinfo? info) {
  if (info == null) return '—';
  final used = info.used;
  if (used == null) return '—';
  if (info.isUnlimited) return '${formatBytes(used)} / 不限量';
  return '${formatBytes(used)} / ${formatBytes(info.total!)}';
}

/// 剩余格：没有头或已用未知时“—”；不限量时“不限量”；超量时“已超量”。
String remainingText(SubscriptionUserinfo? info) {
  if (info == null) return '—';
  if (info.isUnlimited) return '不限量';
  final remaining = info.remaining;
  if (remaining == null) return '—';
  if (remaining < 0) return '已超量';
  if (remaining == 0) return '已用完';
  return formatBytes(remaining);
}

/// 到期格：没有头或头里没给 expire 时“—”；expire 为 0 时“永不过期”；
/// 否则写日期＋剩余天数（当天到期写“今天到期”，已过期写“已到期”）。
String expireText(SubscriptionUserinfo? info) {
  if (info == null || info.expire == null) return '—';
  if (info.expire == 0) return '永不过期';
  final date = info.expireDate;
  if (date == null) return '—';
  if (info.isExpired) return '已到期';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final days = date.difference(today).inDays;
  if (days <= 0) return '${formatDateYmd(date)}（今天到期）';
  return '${formatDateYmd(date)}（剩 $days 天）';
}

/// 日期时间转 `yyyy-MM-dd HH:mm`（“上次更新”用，不引 intl）。
String formatDateTime(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  final hh = date.hour.toString().padLeft(2, '0');
  final mm = date.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

/// 流量限流状态（切片 8）：只按 userinfo 头里已有的数判断，
/// 面板没给的状态（停用原因、重置日期、限流百分比）一律不猜
///（panel-adapter.md §2.3）。
enum TrafficLimitStatus {
  /// 不限量、没拉到用量、或已用占比不到 80%：不用提醒。
  none,

  /// 已用 ≥80% 且未超量：接近限额，提醒一次（文案里写清后果）。
  approaching,

  /// 已用完 / 已超量：面板可能已停用该订阅——只说“可能”，
  /// 停用只表现为节点连不上 + 用量已满，客户端看不到停用状态本身。
  exceeded,
}

/// 限流状态判定：不限量（total 为 null 或 0）或已用未知时一律 none；
/// 剩余 ≤0 时 exceeded；已用占比 ≥80% 时 approaching。
TrafficLimitStatus trafficLimitStatus(SubscriptionUserinfo? info) {
  if (info == null || info.isUnlimited) return TrafficLimitStatus.none;
  final remaining = info.remaining;
  if (remaining == null) return TrafficLimitStatus.none;
  if (remaining <= 0) return TrafficLimitStatus.exceeded;
  final ratio = info.usedRatio;
  if (ratio != null && ratio >= 0.8) return TrafficLimitStatus.approaching;
  return TrafficLimitStatus.none;
}

/// 限流状态文案：none 时返回 null（界面不显示这一行）。
/// approaching 写已用百分比；exceeded 写“可能已停用”，不写成定论。
String? trafficLimitText(SubscriptionUserinfo? info) {
  switch (trafficLimitStatus(info)) {
    case TrafficLimitStatus.approaching:
      final percent = ((info!.usedRatio ?? 0) * 100).round();
      return '已用 $percent%，接近限额，超量后节点可能停用';
    case TrafficLimitStatus.exceeded:
      return '已超量：面板可能已停用该订阅，节点连不上时请联系管理员';
    case TrafficLimitStatus.none:
      return null;
  }
}

/// 日期转 `yyyy-MM-dd`（不引 intl，只为这一处显示）。
String formatDateYmd(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
