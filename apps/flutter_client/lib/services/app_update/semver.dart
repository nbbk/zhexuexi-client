/// SemVer 版本号比对（应用内更新用）。
///
/// 口径（与 `remote_config.dart` 里那个只比 `x.y.z` 数字段的
/// [compareVersions] 不同，这里按 semver 2.0 规则来，因为 Release
/// 的 tag 可能带预发布后缀）：
/// - 去首尾空白、去 `v` / `V` 前缀（`v1.2.3` 与 `1.2.3` 同版）；
/// - `+build` 构建元数据忽略（`1.0.0+2` 与 `1.0.0` 同版）；
/// - 核心段按数字比，缺段补 0（`1.0` == `1.0.0`），非数字段按 0；
/// - 预发布：正式版 > 预发布版（`1.0.0` > `1.0.0-rc.1`）；
///   预发布标识符逐个比：纯数字 < 字母数字，数字按数值、字母按字典序，
///   前者是后者前缀时短的更小
///   （`alpha` < `alpha.1` < `alpha.beta` < `beta` < `beta.2`
///   < `beta.11` < `rc.1`）。
///
/// 返回负数表示 a < b，0 表示相等，正数表示 a > b；不抛错。
int compareSemver(String a, String b) {
  final pa = _SemverParts.parse(a);
  final pb = _SemverParts.parse(b);
  final len = pa.core.length > pb.core.length ? pa.core.length : pb.core.length;
  for (var i = 0; i < len; i++) {
    final av = i < pa.core.length ? pa.core[i] : 0;
    final bv = i < pb.core.length ? pb.core[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  // 核心段相等：无预发布 > 有预发布；都有预发布时按标识符逐个比。
  if (pa.prerelease.isEmpty && pb.prerelease.isEmpty) return 0;
  if (pa.prerelease.isEmpty) return 1;
  if (pb.prerelease.isEmpty) return -1;
  final idLen = pa.prerelease.length > pb.prerelease.length
      ? pa.prerelease.length
      : pb.prerelease.length;
  for (var i = 0; i < idLen; i++) {
    if (i >= pa.prerelease.length) return -1;
    if (i >= pb.prerelease.length) return 1;
    final cmp = _comparePrereleaseId(pa.prerelease[i], pb.prerelease[i]);
    if (cmp != 0) return cmp;
  }
  return 0;
}

/// 去掉 `v` 前缀与 `+build` 后缀后的版本号（展示用，如 `v1.2.3` → `1.2.3`）。
String normalizeSemver(String version) {
  var v = version.trim();
  if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
  final plus = v.indexOf('+');
  if (plus >= 0) v = v.substring(0, plus);
  return v;
}

int _comparePrereleaseId(String a, String b) {
  final aNum = int.tryParse(a);
  final bNum = int.tryParse(b);
  if (aNum != null && bNum != null) return aNum.compareTo(bNum);
  // 纯数字标识符 < 字母数字标识符（semver 规则）。
  if (aNum != null) return -1;
  if (bNum != null) return 1;
  return a.compareTo(b);
}

class _SemverParts {
  _SemverParts(this.core, this.prerelease);

  factory _SemverParts.parse(String version) {
    var v = normalizeSemver(version);
    var prerelease = <String>[];
    final dash = v.indexOf('-');
    if (dash >= 0) {
      prerelease = v
          .substring(dash + 1)
          .split('.')
          .where((s) => s.isNotEmpty)
          .toList();
      v = v.substring(0, dash);
    }
    final core = v
        .split('.')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .toList();
    return _SemverParts(core, prerelease);
  }

  final List<int> core;
  final List<String> prerelease;
}
