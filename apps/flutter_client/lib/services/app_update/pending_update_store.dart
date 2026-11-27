import 'package:shared_preferences/shared_preferences.dart';

/// 待安装的更新：下载完、SHA-256 校验通过后持久化。
///
/// 解决“错过安装提示就得重新下载”：安装包本身一直存在应用文档
/// 目录 `updates/` 下（只有校验不对才删），但“下好等安装”这件事
/// 以前只记在更新弹窗的内存里（`_downloaded`），弹窗一关入口就
/// 没了。有了这条记录，设置页随时能重调安装，不用重下。
class PendingUpdate {
  const PendingUpdate({
    required this.version,
    required this.filePath,
    required this.sha256,
  });

  /// 待安装的版本号（去 `v` 前缀，如 `0.1.17`）。
  final String version;

  /// 安装包在本机上的完整路径。
  final String filePath;

  /// 期望的 SHA-256（小写 hex）；重调安装前先重核，对不上不装。
  final String sha256;
}

/// 待安装记录的存取（可注入 fake 做测试；生产走 SharedPreferences，
/// 沿用客户端已有的偏好存储习惯）。
abstract class PendingUpdateStore {
  /// 保存待安装记录（覆盖旧的）。
  Future<void> save(PendingUpdate record);

  /// 读待安装记录；没有或三字段缺任何一个（写一半被杀掉）时返回 null。
  Future<PendingUpdate?> read();

  /// 清掉待安装记录（不删文件；删文件由调用方决定）。
  Future<void> clear();

  /// 今天有没有提醒过装这个版本（启动提醒一天只弹一次用）。
  Future<bool> remindedToday(String version);

  /// 记下“今天已提醒过装这个版本”。
  Future<void> markRemindedToday(String version);
}

/// SharedPreferences 实现。
class SharedPreferencesPendingUpdateStore implements PendingUpdateStore {
  static const _versionKey = 'pending_update_version';
  static const _pathKey = 'pending_update_path';
  static const _sha256Key = 'pending_update_sha256';
  static const _remindedVersionKey = 'pending_update_reminded_version';
  static const _remindedDateKey = 'pending_update_reminded_date';

  /// 当天日期（本地时区，yyyy-MM-dd）；测试可传 now 定住日期。
  static String todayString([DateTime? now]) {
    final d = now ?? DateTime.now();
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  @override
  Future<void> save(PendingUpdate record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_versionKey, record.version);
    await prefs.setString(_pathKey, record.filePath);
    await prefs.setString(_sha256Key, record.sha256);
  }

  @override
  Future<PendingUpdate?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final version = prefs.getString(_versionKey);
    final path = prefs.getString(_pathKey);
    final sha256 = prefs.getString(_sha256Key);
    if (version == null || path == null || sha256 == null) return null;
    return PendingUpdate(version: version, filePath: path, sha256: sha256);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_versionKey);
    await prefs.remove(_pathKey);
    await prefs.remove(_sha256Key);
  }

  @override
  Future<bool> remindedToday(String version) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_remindedVersionKey) == version &&
        prefs.getString(_remindedDateKey) == todayString();
  }

  @override
  Future<void> markRemindedToday(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_remindedVersionKey, version);
    await prefs.setString(_remindedDateKey, todayString());
  }
}
