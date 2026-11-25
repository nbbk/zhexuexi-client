/// 节点行左侧圆圈里的国家/地区旗标（离线判断，不引 GeoIP 数据库）。
///
/// 判断只看节点地址（与小火箭同一口径：中转节点显示的是中转机
/// 所在国家的旗，不要为了“纠正”去改它）：
/// - 本项目自有的中转域名写死在 [_knownHosts] 里（中转机在香港，
///   用户已确认）；换中转域名后这里要跟着换，换之前未知→ globe；
/// - 其余域名按国家顶级域（ccTLD）认，如 `.jp` → 日本、`.hk` → 中国香港；
/// - IP 地址（v4/v6）不猜国家：没有离线 IP 库，硬按号段猜会错，
///   一律未知→ globe。
///
/// 未知时返回 [CountryFlag.unknown]，界面放通用 globe 图标，不放旗。
class CountryFlag {
  const CountryFlag({
    required this.code,
    required this.emoji,
    required this.label,
  });

  /// 未知国家（没有旗标，界面放 globe 图标）。
  static const CountryFlag unknown = CountryFlag(
    code: '',
    emoji: '',
    label: '未知',
  );

  /// ISO 3166-1 alpha-2 国家码（未知时为空串）。
  final String code;

  /// 旗标 emoji（未知时为空串）。
  final String emoji;

  /// 给用户看的国家/地区名。
  final String label;

  bool get isKnown => code.isNotEmpty;
}

/// 按节点地址判断国家/地区旗标。
CountryFlag flagForAddress(String address) {
  var host = address.trim().toLowerCase();
  // IPv6 的方括号去掉；末尾的点去掉；端口不该出现在这里，出现了也去掉。
  if (host.startsWith('[') && host.contains(']')) {
    host = host.substring(1, host.indexOf(']'));
  }
  host = host.replaceAll(RegExp(r'\.$'), '');
  if (host.isEmpty) return CountryFlag.unknown;
  // 本项目自有中转域名：中转机在香港（用户已确认）。
  // 只有这个域名写死在这里；换中转域名后要跟着换。
  final known = _knownHosts[host];
  if (known != null) return known;
  // IP 地址不猜国家（没有离线 IP 库）。
  if (_isIpAddress(host)) return CountryFlag.unknown;
  // 其余域名按国家顶级域认；没有顶级域（如 localhost）→ 未知。
  final dot = host.lastIndexOf('.');
  if (dot < 0 || dot == host.length - 1) return CountryFlag.unknown;
  final tld = host.substring(dot + 1);
  final country = _ccTld[tld];
  if (country == null) return CountryFlag.unknown;
  return country;
}

/// 国家码 → 旗标 emoji（地区指示符：A=U+1F1E6，依次加）。
String _flagEmoji(String code) {
  return String.fromCharCodes(
    code.codeUnits.map((c) => 0x1F1E6 + c - 0x41),
  );
}

CountryFlag _flag(String code, String label) =>
    CountryFlag(code: code, emoji: _flagEmoji(code), label: label);

/// 本项目自有的中转域名 → 国家（中转机在香港，用户已确认）。
final Map<String, CountryFlag> _knownHosts = {
  'cp.jiankong.cf': _flag('HK', '中国香港'),
};

/// 国家顶级域（ccTLD）→ 国家/地区。
final Map<String, CountryFlag> _ccTld = {
  'hk': _flag('HK', '中国香港'),
  'cn': _flag('CN', '中国'),
  'tw': _flag('TW', '中国台湾'),
  'mo': _flag('MO', '中国澳门'),
  'jp': _flag('JP', '日本'),
  'kr': _flag('KR', '韩国'),
  'sg': _flag('SG', '新加坡'),
  'us': _flag('US', '美国'),
  'ca': _flag('CA', '加拿大'),
  'gb': _flag('GB', '英国'),
  'uk': _flag('GB', '英国'),
  'de': _flag('DE', '德国'),
  'fr': _flag('FR', '法国'),
  'nl': _flag('NL', '荷兰'),
  'au': _flag('AU', '澳大利亚'),
  'nz': _flag('NZ', '新西兰'),
  'in': _flag('IN', '印度'),
  'br': _flag('BR', '巴西'),
  'ru': _flag('RU', '俄罗斯'),
  'my': _flag('MY', '马来西亚'),
  'th': _flag('TH', '泰国'),
  'vn': _flag('VN', '越南'),
  'id': _flag('ID', '印度尼西亚'),
  'ph': _flag('PH', '菲律宾'),
  'tr': _flag('TR', '土耳其'),
  'ae': _flag('AE', '阿联酋'),
  'sa': _flag('SA', '沙特阿拉伯'),
  'za': _flag('ZA', '南非'),
  'mx': _flag('MX', '墨西哥'),
  'es': _flag('ES', '西班牙'),
  'it': _flag('IT', '意大利'),
  'se': _flag('SE', '瑞典'),
  'no': _flag('NO', '挪威'),
  'fi': _flag('FI', '芬兰'),
  'pl': _flag('PL', '波兰'),
  'ch': _flag('CH', '瑞士'),
  'at': _flag('AT', '奥地利'),
  'be': _flag('BE', '比利时'),
  'ie': _flag('IE', '爱尔兰'),
  'il': _flag('IL', '以色列'),
  'eg': _flag('EG', '埃及'),
  'ng': _flag('NG', '尼日利亚'),
  'ke': _flag('KE', '肯尼亚'),
  'cl': _flag('CL', '智利'),
  'ar': _flag('AR', '阿根廷'),
  'co': _flag('CO', '哥伦比亚'),
  'pe': _flag('PE', '秘鲁'),
  'ua': _flag('UA', '乌克兰'),
};

/// 是不是 IP 地址（v4 全数字加点，或含冒号的 v6）。
bool _isIpAddress(String host) {
  if (host.contains(':')) return true;
  return RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);
}
