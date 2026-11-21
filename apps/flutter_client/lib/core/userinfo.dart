/// 订阅 `subscription-userinfo` 响应头的解析。
///
/// 头格式（见 docs/api/panel-adapter.md §2.1）：
///   `upload=123; download=456; total=1073741824; expire=1790000000`
/// 四个字段全是整数：upload/download/total 是字节数，expire 是 Unix 秒时间戳。
/// 注意：这是**中转口径**——直连流量不经过中转机，不在头里（面板 1.3.27
/// 已验证小火箭到期显示正常，但直连流量要靠节点侧计量，见方案 §0）。
class SubscriptionUserinfo {
  const SubscriptionUserinfo({
    required this.upload,
    required this.download,
    required this.total,
    required this.expire,
  });

  /// 已用上行字节数。
  final int upload;

  /// 已用下行字节数。
  final int download;

  /// 总流量字节数（0 表示不限量）。
  final int total;

  /// 到期 Unix 秒时间戳（0 表示永不过期）。
  final int expire;

  /// 已用（上行 + 下行）。
  int get used => upload + download;

  /// 剩余字节数；total 为 0（不限量）时返回 null。
  int? get remaining => total == 0 ? null : total - used;

  /// 已用占比 0.0–1.0；total 为 0 时返回 null。
  double? get usedRatio {
    if (total == 0) return null;
    if (used <= 0) return 0;
    return (used / total).clamp(0.0, 1.0);
  }

  /// 是否已到期（expire 为 0 表示永不过期）。
  bool get isExpired =>
      expire != 0 && DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expire;

  /// 到期日期；expire 为 0 时返回 null。
  DateTime? get expireDate => expire == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expire * 1000);

  /// 解析响应头；缺字段按 0 兜底（面板 1.3.24 起四个字段都会下发）。
  static SubscriptionUserinfo parse(String? headerValue) {
    var upload = 0;
    var download = 0;
    var total = 0;
    var expire = 0;
    if (headerValue != null && headerValue.isNotEmpty) {
      for (final part in headerValue.split(';')) {
        final kv = part.trim().split('=');
        if (kv.length != 2) continue;
        final value = int.tryParse(kv[1].trim()) ?? 0;
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
