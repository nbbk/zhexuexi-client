import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_sing_box/flutter_sing_box.dart';

import 'clash_api_client.dart';
import 'config_validator.dart';
import 'custom_rule.dart';
import 'node_model.dart';
import 'routing_mode.dart';
import 'singbox_config.dart';

/// 核心状态（界面只认这个枚举，不直接认插件的 [ProxyState]）。
enum CoreStatus { stopped, starting, started, stopping, error }

/// 一次启动探活的结果（独立于 [CoreStatus]，见 [CoreService]）。
///
/// 2026-11-26 二轮修复（方案 A）：拨测失败不再翻 [CoreStatus.error]——
/// 核心明明在跑，翻 error 会闩锁首页（_syncTraffic/_syncDurationTimer
/// 按 started 跑，error 一闩锁速率与计时全停），还让节点页误判成
/// “开关关着”静默切回直连探测。探活失败只写这里：首页保持“运行中”，
/// 另起一行写拨测失败；节点页据此决定测速口径。
class ProbeState {
  const ProbeState({required this.failed, this.error, this.at});

  /// 没探活过、或最近一次探活通过时为 false。
  final bool failed;

  /// 失败原因（人话，界面直接显示）；通过时为 null。
  final String? error;

  /// 最近一次探活完成的时间；没探活过时为 null。
  final DateTime? at;
}

/// 应用一次配置的结果。
class ConfigApplyResult {
  const ConfigApplyResult({
    required this.ok,
    this.errors = const [],
    this.skipped = const [],
    this.nodeCount = 0,
  });

  /// 是否成功写入并（已运行时）重载。
  final bool ok;

  /// 校验失败时的原因（诊断与日志用，不直接展示给用户）。
  final List<String> errors;

  /// 生成时跳过的节点（`名字：原因`），界面可提示。
  final List<String> skipped;

  /// 成功写入的节点出站数。
  final int nodeCount;
}

/// sing-box 核心的封装（切片 2：配置生成＋接线完成）。
///
/// 插件接线方式（已核对 flutter_sing_box 3.1.0 源码，见
/// docs/api/plugin-decision.md“阶段 1 接线结论”）：
/// - 配置体写插件的 `using_config.json`（`ProfileStorage.getUsingConfig()`），
///   原子写（临时文件＋改名），Android 与 Windows 的原生侧都从这里读配置；
/// - Android 启动要求 MMKV 里有一个已选档案（否则报 EmptyConfiguration），
///   首次启动时建一个名为“哲学系”的本地档案（只写元数据，不动配置体）；
/// - 插件没有“设置配置”的 API：已运行时换配置调 `serviceReload()`，
///   未运行时调 `startVpn()`；`serviceReload()` 在插件里实现为重启
///   （停＋起），换配置会有短暂断开，不是无缝热重载——校验失败时不写文件、
///   不调重载，旧配置继续跑（这就是本片的保证）；
/// - 校验分两层：插件内置的官方 JSON Schema（纯离线）＋结构检查
///   （legacy 写法、tag 重复、default_domain_resolver 缺失等）。
class CoreService {
  CoreService({
    FlutterSingBox? plugin,
    ConfigValidator? validator,
    Future<String> Function()? usingConfigPath,
    Future<void> Function(String configPath)? ensureSelectedProfile,
    ClashApiClient? clashApiClient,
    // 启动拨测的容错参数（默认即线上值；测试可传 0 缩短等待）：
    // - probeTimeout 10 秒：冷 VLESS/REALITY 首次握手（手机→中转→落地
    //   多段 RTT）＋落地解析测速域名＋到 Google 的 TLS＋GET 串行完成，
    //   5 秒预算一次丢包重传或落地 DNS 一慢就越线；sing-box 按 16 位
    //   解析超时毫秒数，10000 合法；
    // - probeWarmup 2 秒：取到 /traffic 帧后先预热再拨，给核心与出站
    //   冷握手留时间；
    // - probeRetryDelay 2 秒：拨测失败后隔这么久重试一次，仍失败才翻
    //   error；重试期间保持 started，不闪 error。
    // - realTrafficProbe（0.1.3 D 路修复 2）：delay 通过后的真实
    //   流量复核（经本地 mixed 入站的 HTTPS GET）；默认走真实现，
    //   测试可注入 fake（测试环境没有真 mixed 入站）。
    this.probeTimeout = const Duration(seconds: 10),
    this.probeWarmup = const Duration(seconds: 2),
    this.probeRetryDelay = const Duration(seconds: 2),
    Future<bool> Function()? realTrafficProbe,
    // 0.1.9 采样时序（见 [_startSampling] 的注释）：默认每 20 秒
    // 采一次、环形缓冲只留最近 90 条（≈30 分钟），测试可传短间隔。
    this.sampleInterval = const Duration(seconds: 20),
    this.sampleMaxEntries = 90,
    // 核心日志尾巴：内存里只留最近 50 行，不写盘。
    this.coreLogMaxLines = 50,
  }) : _plugin = plugin ?? FlutterSingBox(),
       _validator = validator ?? SingBoxSchemaConfigValidator(),
       _usingConfigPath =
           usingConfigPath ?? _defaultUsingConfigPath,
       _ensureSelectedProfile =
           ensureSelectedProfile ?? _defaultEnsureSelectedProfile,
       _clashApi = clashApiClient ?? ClashApiClient(),
       // ignore: prefer_initializing_formals
       _realTrafficProbe = realTrafficProbe;

  final FlutterSingBox _plugin;
  final ConfigValidator _validator;
  final Future<String> Function() _usingConfigPath;
  final Future<void> Function(String configPath) _ensureSelectedProfile;

  /// 启动后校验用的 Clash API 客户端（可注入 fake 做测试）。
  final ClashApiClient _clashApi;

  /// 启动拨测的超时预算（默认 10 秒，见构造函数注释）。
  final Duration probeTimeout;

  /// 取到 /traffic 帧后、拨测前的预热等待（默认 2 秒）。
  final Duration probeWarmup;

  /// 拨测失败后、重试前的等待（默认 2 秒）。
  final Duration probeRetryDelay;

  /// delay 通过后的真实流量复核（可注入 fake 做测试；不注入时走
  /// [_probeRealTraffic] 的真实现）。
  final Future<bool> Function()? _realTrafficProbe;

  CoreStatus _status = CoreStatus.stopped;
  String? _lastError;

  /// 启动探活位（2026-11-26 二轮修复）：只反映出站拨测，不改
  /// [_status]。新一轮启动时清掉，停核心时也清掉。
  ProbeState _probe = const ProbeState(failed: false);

  /// 正在跑的启动校验（[_verifyControlApi]）——“重新拨测”与启动
  /// 校验撞上时不重开第二轮，等正在跑的那轮出结果。
  bool _verifying = false;

  /// 最后一份成功写入的配置 JSON（内存里的一份；重启后由 [init] 从磁盘读回）。
  String? _currentConfigJson;

  /// 最后一份配置里的节点出站数。
  int _appliedNodeCount = 0;

  /// 最后一份配置的写入时间。
  DateTime? _lastAppliedAt;

  final _statusController = StreamController<CoreStatus>.broadcast();
  StreamSubscription<ProxyState>? _pluginSubscription;

  /// 启动探活变化流（界面订阅它刷新“出站拨测失败”提示与重测按钮）。
  final _probeController = StreamController<ProbeState>.broadcast();

  /// 当前核心状态。
  CoreStatus get status => _status;

  /// 最近一次异常停止的原因；正常停止时为 null。
  String? get lastError => _lastError;

  /// 最近一次启动探活是否失败（核心在跑但出站不通时为 true）。
  bool get probeFailed => _probe.failed;

  /// 最近一次启动探活的失败原因（人话）；通过时为 null。
  String? get lastProbeError => _probe.error;

  /// 最近一次启动探活完成的时间；没探活过时为 null。
  DateTime? get lastProbeAt => _probe.at;

  /// 当前探活位。
  ProbeState get probeState => _probe;

  /// 探活位变化流（界面订阅它刷新拨测提示；状态流不动它）。
  Stream<ProbeState> get probeStream => _probeController.stream;

  /// 当前生效的配置 JSON（诊断与设置页“DNS 配置查看”用；没有时为 null）。
  String? get currentConfigJson => _currentConfigJson;

  /// 当前生效配置里的节点出站数。
  int get appliedNodeCount => _appliedNodeCount;

  /// 当前生效配置的写入时间。
  DateTime? get lastAppliedAt => _lastAppliedAt;

  /// 状态变化流（界面订阅它刷新大开关）。
  Stream<CoreStatus> get statusStream => _statusController.stream;

  /// 初始化插件，并把磁盘上最后一份配置读回内存（App 重启后 start 能用）。
  ///
  /// 前置条件：main() 已在 runApp 之前调过 `MMKV.initialize()`。
  /// [_usingConfigPath] 默认走 ProfileStorage（MMKV），未初始化时抛
  /// StateError（“forget initialize MMKV first?”）；这个错必须抛出去，
  /// 不能当成“磁盘上没有配置”吞掉——否则 start() 只会报一个毫不相干的
  /// “没有可用配置”，真正原因被掩盖（小米真机 2026-11-25 就是这么丢的）。
  /// 磁盘配置本身读不到（文件不存在/读失败）才不影响启动。
  Future<void> init() async {
    await _plugin.init();
    // 0.1.9 核心日志尾巴：Dart 侧能取到核心日志——插件
    // `FlutterSingBox.logStream`（EventChannel `log_event`，原生侧
    // `SingBoxConnector.LogClient.appendLogs` 按批推，`ClientLog`
    // 含 level/message）。订阅包在 runZonedGuarded 里：平台通道
    // 未初始化/未接时，`EventChannel.receiveBroadcastStream` 的
    // listen 会在 zone 回调里抛错、逃出普通 try/catch（纯 test()
    // 里 ServicesBinding 未初始化时即如此），zone 兜底吞掉；
    // 订阅失败只记一行 debugPrint，诊断包里尾巴为空即表示
    // “没取到行”，不编造。
    runZonedGuarded(() {
      _logSubscription = _plugin.logStream.listen(
        (batch) {
          for (final log in batch) {
            _coreLogTail.add('[${_logLevelName(log.level)}] ${log.message}');
            while (_coreLogTail.length > coreLogMaxLines) {
              _coreLogTail.removeAt(0);
            }
          }
        },
        onError: (_) {},
      );
    }, (Object e, StackTrace _) {
      debugPrint('[CoreService] 订阅核心日志流失败 $e');
    });
    _pluginSubscription = _plugin.proxyStateStream.listen((state) {
      _status = switch (state) {
        ProxyStarted() => CoreStatus.started,
        ProxyStarting() => CoreStatus.starting,
        ProxyStopping() => CoreStatus.stopping,
        ProxyStopped(:final errMessage) => errMessage == null
            ? CoreStatus.stopped
            : CoreStatus.error,
      };
      if (state is ProxyStopped) _lastError = state.errMessage;
      // 新一轮启动：上一轮的异常原因与探活失败都清掉（2026-11-26
      // 二轮修复：started 时清 _lastError，首页不再把上一轮的
      // “连接失败”带到新一轮；探活位也从头算，不沿用旧结论）。
      // 停核心时同样清探活位：停了就没有什么“出站拨测失败”可言。
      if (state is ProxyStarted) {
        _lastError = null;
        _setProbe(const ProbeState(failed: false));
        _startSampling();
      } else if (state is ProxyStopped) {
        _setProbe(const ProbeState(failed: false));
        _stopSampling();
      }
      _statusController.add(_status);
      // Started 只说明 :remote 里的 commandServer 起来了，不等于代理
      // 真可用：mixed-only 配置（没有 tun 入站）时核心照样 Started、
      // 首页照样显示“运行中”，但没有任何流量进核心（假运行）。
      // 所以 Started 之后再探一次 Clash API，探不到就翻成 error，
      // 不要让“运行中”只由 AIDL 状态说了算。TUN 默认开启本身在
      // SettingsState（新装与从未改过开关的用户默认开），这里是
      // 启动后的第二道校验。
      if (state is ProxyStarted) unawaited(_verifyControlApi());
    });
    try {
      final path = await _usingConfigPath();
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) _currentConfigJson = content;
      }
    } on StateError {
      // MMKV 未初始化等致命错误：重新抛出，不吞。
      rethrow;
    } catch (_) {
      // 磁盘配置读不到不影响启动：start 时会因无配置而明确报错。
      _currentConfigJson = null;
    }
  }

  /// 用节点列表生成配置并应用。
  ///
  /// 顺序：生成 → 校验 → 写盘 →（已运行时）重载。校验失败时不写文件、
  /// 不调重载，旧配置继续跑，返回 [ConfigApplyResult.ok] = false 与原因。
  /// [mode] 只改 route 与 DNS 规则的解析路径（见
  /// [SingboxConfigBuilder.build]），默认规则模式。
  /// [selectedNodeName]（切片 4）：selector `Proxy` 的默认出站，
  /// 没给时按默认规则（第一个直连节点，没有时第一个）。
  /// [customRules]（切片 6）：已启用的自定义规则，插在内置规则前面。
  /// [tunEnabled]（切片 6）：为 true 时配置里加一条 tun 入站。
  Future<ConfigApplyResult> applyNodes(
    List<Node> nodes, {
    RoutingMode mode = RoutingMode.rule,
    String? selectedNodeName,
    List<CustomRule> customRules = const [],
    bool tunEnabled = false,
  }) async {
    final built = SingboxConfigBuilder.build(
      nodes,
      mode: mode,
      selectedNodeName: selectedNodeName,
      customRules: customRules,
      tunEnabled: tunEnabled,
    );
    final errors = await _validator.validate(built.config);
    if (errors.isNotEmpty) {
      return ConfigApplyResult(
        ok: false,
        errors: errors,
        skipped: built.skipped,
      );
    }
    final json = built.toJsonString();
    final path = await _usingConfigPath();
    await _writeAtomically(path, json);
    _currentConfigJson = json;
    _appliedNodeCount = nodes.length - built.skipped.length;
    _lastAppliedAt = DateTime.now();
    // 只在已运行时重载；停止状态下只写盘，等 start() 时再读。
    if (_status == CoreStatus.started) {
      await _plugin.serviceReload();
    }
    return ConfigApplyResult(
      ok: true,
      skipped: built.skipped,
      nodeCount: _appliedNodeCount,
    );
  }

  /// 只改已写入磁盘的配置里 selector `Proxy` 的默认出站（[tag] 是
  /// 配置里的出站 tag，见 [SingboxConfigBuilder.tagForNode]），
  /// 不校验、不重载、不动其它字段。
  ///
  /// 用途（切片 4）：节点页切换节点时，运行时选择走 Clash API
  /// 立即生效，下次启动用的默认选择要跟着落盘——不然重启后又回到
  /// 旧默认。直接改 JSON 的 `default` 字段比整份重新生成更安全：
  /// 不经过校验与重载，不会因为别的字段出问题把好端端的配置写坏；
  /// 改完仍是同一份已校验过的配置，只是换了个默认值。
  /// 没有已写入的配置、配置里没有 Proxy 组、或写盘失败时返回 false。
  Future<bool> updateSelectorDefault(String tag) async {
    final json = _currentConfigJson;
    if (json == null) return false;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return false;
      final outbounds = decoded['outbounds'];
      if (outbounds is! List) return false;
      var found = false;
      for (final outbound in outbounds) {
        if (outbound is Map<String, dynamic> &&
            outbound['tag'] == 'Proxy' &&
            outbound['type'] == 'selector') {
          final members = outbound['outbounds'];
          if (members is List && !members.contains(tag)) return false;
          outbound['default'] = tag;
          found = true;
        }
      }
      if (!found) return false;
      final updated = jsonEncode(decoded);
      final path = await _usingConfigPath();
      await _writeAtomically(path, updated);
      _currentConfigJson = updated;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 写探活位并推流（controller 已关时只记值不推，避免 dispose 后
  /// 插件再推状态时抛错）。
  void _setProbe(ProbeState next) {
    _probe = next;
    if (!_probeController.isClosed) _probeController.add(next);
  }

  /// 启动后校验：Started 之后先去 Clash API 取一帧 `/traffic`
  /// （5 秒超时；空闲时核心也每秒推一帧 `{"up":0,"down":0}`，
  /// 真 sing-box 1.14.4 实测），预热 2 秒后对当前默认出站做一次
  /// 真实拨测，失败重试一次，仍失败才记探活失败。
  ///
  /// `/traffic` 只能证明控制接口在推帧——空闲时也是 0/0——不证明
  /// 代理能出网（2026-11-26：DNS 全死时 /traffic 照常推帧，首页
  /// 显示“运行中”，实际没网络、测速全红点）。所以取到帧后再调一次
  /// Clash API delay（与开着开关测速同一条路）。
  ///
  /// 拨测走当前默认出站，测速域名由出站（落地服务器）解析，不走
  /// 客户端本地 DNS：VLESS/VMess/Trojan/HY2/TUIC 类出站的 delay
  /// 根本不经过客户端 DNS（dns-direct/dns-proxy/final 只影响
  /// direct 出站、节点 server 地址是域名时的解析，以及 TUN 真实
  /// 流量）。所以拨测超时≠客户端 DNS 有问题，不要往 DNS 方向修。
  ///
  /// 2026-11-26 二轮修复（方案 A）：校验失败只写探活位、不翻
  /// [CoreStatus.error]——核心在跑，翻 error 会闩锁首页（速率与
  /// 计时都按 started 跑），还让节点页误判成“开关关着”静默切回
  /// 直连探测。首页保持“运行中”，另起探活失败提示＋“重新拨测”
  /// 按钮；[CoreStatus.error] 只留给插件原生 `ProxyStopped(err)`
  /// （核心真停了、真崩了）。没有已写入配置 / 没有 Proxy 组时
  /// （无节点启动）跳过拨测，只认 /traffic，不误报。
  Future<void> _verifyControlApi() async {
    if (_verifying) return;
    _verifying = true;
    try {
      await _verifyControlApiInner();
    } finally {
      _verifying = false;
    }
  }

  Future<void> _verifyControlApiInner() async {
    try {
      await _clashApi.trafficSample(timeout: const Duration(seconds: 5));
    } catch (_) {
      if (_status != CoreStatus.started) return;
      // 校验还没跑完就 dispose 了：controller 已关，不能再往里写事件。
      if (_statusController.isClosed) return;
      // 控制接口无响应：只记探活失败，不翻 error（见上）。
      _setProbe(
        ProbeState(
          failed: true,
          error: '核心已启动但控制接口无响应',
          at: DateTime.now(),
        ),
      );
      return;
    }
    final probeTag = _egressProbeTag();
    if (probeTag == null) return;
    // 预热：给核心与出站冷握手留时间；等完再看一眼状态，用户可能
    // 已经点了关、或 service 已 dispose。
    await Future<void>.delayed(probeWarmup);
    if (_status != CoreStatus.started) return;
    if (_statusController.isClosed) return;
    var probe = await _probeOnce(probeTag);
    if (probe.delay != null) {
      // delay 通过 ≠ 真实流量通（0.1.3 D 路修复 2）：再经本地
      // mixed 入站复核一次 DNS＋路由＋出站整条路。
      await _probeRealTrafficAfterDelay();
      return;
    }
    // 失败重试一次（超时、503 快失败都可能是冷启动瞬态）；重试期间
    // 保持 started，不闪 error。
    await Future<void>.delayed(probeRetryDelay);
    if (_status != CoreStatus.started) return;
    if (_statusController.isClosed) return;
    probe = await _probeOnce(probeTag);
    if (probe.delay != null) {
      await _probeRealTrafficAfterDelay();
      return;
    }
    if (_status != CoreStatus.started) return;
    if (_statusController.isClosed) return;
    _setProbe(
      ProbeState(
        failed: true,
        error: '代理出站拨测失败：${_delayFailureText(probe.failure)}',
        at: DateTime.now(),
      ),
    );
  }

  /// 手动重新拨测（首页“重新拨测”按钮调）：只在核心在跑时跑，
  /// 与正在跑的启动校验撞上时等那轮出结果，不重开第二轮。
  /// 拨测通过会清探活失败，失败会刷新失败原因与时间。
  Future<void> retryProbe() async {
    if (_status != CoreStatus.started) return;
    await _verifyControlApi();
  }

  /// 一次启动拨测，并记一行日志（tag、结果、耗时毫秒），以后不用
  /// logcat 也能定位拨测是慢、是快失败、还是重试后才通。
  Future<ProxyDelayResult> _probeOnce(String tag) async {
    final stopwatch = Stopwatch()..start();
    final result = await _clashApi.proxyDelayDetailed(
      tag,
      timeout: probeTimeout,
    );
    stopwatch.stop();
    debugPrint(
      '[CoreService] 启动拨测 tag=$tag delay=${result.delay} '
      'failure=${result.failure} ${stopwatch.elapsedMilliseconds}ms',
    );
    return result;
  }

  /// delay 拨测通过后的真实流量复核（0.1.3 D 路修复 2）：经本地
  /// mixed 入站（127.0.0.1:2080）发一次 HTTPS GET，覆盖 DNS＋
  /// 路由＋出站整条路。0.1.2 的启动探活只拨 Clash API delay，直
  /// 拨出站，绕过 TUN、绕过路由规则、绕过客户端 DNS——所以 0.1.2
  /// “运行中”时真实流量可能早已死掉（DNS 全死时 /traffic 照常
  /// 推帧、delay 照常通）。失败只写探活位、不翻 CoreStatus.error
  ///（见 _verifyControlApiInner 的注释）。
  ///
  /// 注意：应用内任何探针都测不到 TUN 入口——App 自身流量因 UID
  /// 排除根本不走 TUN，mixed 入站只覆盖“核心收到流量后的路”
  /// （DNS＋路由＋出站）；TUN 入口本身只能看 Clash API
  /// /connections 的实时连接链（诊断包的“实时连接”行）。
  ///
  /// 通过时清掉上一轮的探活失败（“重新拨测”成功后首页的失败提示
  /// 要跟着消失，不留旧结论）。
  Future<void> _probeRealTrafficAfterDelay() async {
    if (_status != CoreStatus.started) return;
    if (_statusController.isClosed) return;
    final ok = await (_realTrafficProbe?.call() ?? _probeRealTraffic());
    if (ok) {
      _setProbe(ProbeState(failed: false, at: DateTime.now()));
    } else {
      _setProbe(
        ProbeState(
          failed: true,
          error: '真实流量不通：DNS 或路由可能有问题',
          at: DateTime.now(),
        ),
      );
    }
  }

  /// 经本地 mixed 入站的 HTTPS GET：收到任何 HTTP 响应即算通
  /// （状态码不限，204 只是约定）；连不上、超时、握手失败都算不通。
  Future<bool> _probeRealTraffic() async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
      client.connectionTimeout = const Duration(seconds: 10);
      final request = await client.getUrl(
        Uri.parse('https://www.gstatic.com/generate_204'),
      );
      final response = await request
          .close()
          .timeout(const Duration(seconds: 10));
      await response.drain<void>();
      debugPrint(
        '[CoreService] 真实流量拨测 status=${response.statusCode}',
      );
      return true;
    } catch (e) {
      debugPrint('[CoreService] 真实流量拨测失败 $e');
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// 拨测用的出站 tag：当前配置里 selector `Proxy` 的默认出站，
  /// 是什么就拨什么——组 tag 直接拨，不再沿成员表解到叶子。
  ///
  /// 真 sing-box 1.14.4 本地实测：`GET /proxies/{组 tag}/delay`
  /// 返回组内当前选用（urltest 的 `now` / selector 的 `now`）的
  /// 延迟；旧写法拨 `members.first`，成组（twin）节点时它不一定
  /// 是组实际选用的入站，测的不是当前生效的路。没有已写入配置、
  /// 没有 Proxy 组、或没有默认出站时返回 null（调用方跳过拨测，
  /// 不误报）。
  String? _egressProbeTag() {
    final json = _currentConfigJson;
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final outbounds = decoded['outbounds'];
      if (outbounds is! List) return null;
      for (final ob in outbounds) {
        if (ob is Map<String, dynamic> &&
            ob['tag'] == 'Proxy' &&
            ob['type'] == 'selector') {
          final tag = ob['default'] as String?;
          if (tag == null || tag.isEmpty) return null;
          return tag;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 采样间隔（默认 20 秒，见 [_startSampling]）。
  final Duration sampleInterval;

  /// 采样环形缓冲上限（默认 90 条 ≈ 30 分钟）。
  final int sampleMaxEntries;

  /// 核心日志尾巴上限（默认最近 50 行）。
  final int coreLogMaxLines;

  /// 采样时序环形缓冲（内存，核心停即清空，不写盘）。
  final List<String> _timeline = [];

  /// 采样计时起点（自开开关起的相对秒数由此算）。
  DateTime? _sampleStartedAt;

  /// 疑似黑断时刻（代理路 DNS 探针从通过变失败的那一次采样）；
  /// 之前至少通过过一次才标，之后每次失败不再重复标。
  DateTime? _blackoutAt;

  /// 代理路 DNS 是否曾经通过过（黑断标记的前提）。
  bool _proxyDnsEverOk = false;

  /// 采样定时器（核心成功启动后起，核心停即停）。
  Timer? _sampleTimer;

  /// 本轮采样是否正在跑（上一轮没跑完时跳过本轮，不重叠、不排队）。
  bool _sampling = false;

  /// 核心日志尾巴（内存，核心停即清空，不写盘）。
  final List<String> _coreLogTail = [];

  /// 核心日志流的订阅（init 时建，dispose 时取消）。
  StreamSubscription<List<ClientLog>>? _logSubscription;

  /// 采样时序（格式化好的行；诊断包直接用）。
  List<String> get samplingTimeline => List.unmodifiable(_timeline);

  /// 疑似黑断时刻；没标过时为 null。
  DateTime? get blackoutAt => _blackoutAt;

  /// 核心日志尾巴（最近若干行；没有时为空列表）。
  List<String> get coreLogTail => List.unmodifiable(_coreLogTail);

  /// 拨测失败原因的人话（界面直接显示这句）。
  ///
  /// 超时是重试都失败后的结论：写明已重试、节点响应慢或不通，并给
  /// 下一步（换节点或再点一次开关），不要只留一句“超时”。
  /// 503 类快失败与控制接口无响应保持原有区分。
  static String _delayFailureText(ProxyDelayFailure? failure) =>
      switch (failure) {
        ProxyDelayFailure.notFound => '节点不在运行配置里',
        ProxyDelayFailure.timeout =>
          '拨测超时（10 秒无响应，已重试一次）：节点响应慢或不通，'
              '建议换个节点或点「重新拨测」再试一次',
        ProxyDelayFailure.apiUnreachable => '控制接口无响应',
        _ => '拨测失败，可能是 DNS 或节点不通',
      };

  /// 启动代理。没有可用配置时直接报错，不让核心空跑。
  Future<void> start() async {
    if (_currentConfigJson == null) {
      throw StateError('没有可用配置：请先拉取订阅生成配置再启动');
    }
    final path = await _usingConfigPath();
    await _ensureSelectedProfile(path);
    await _plugin.startVpn();
  }

  /// 停止代理。
  Future<void> stop() async {
    await _plugin.stopVpn();
  }

  /// 读底层 sing-box 内核版本号（“关于”页展示用）。
  Future<String> coreVersion() => _plugin.getSingBoxVersion();

  /// 释放流控制器与插件状态流的订阅（订阅不取消时，dispose 后插件再推
  /// 状态会往已关闭的控制器里写，直接抛错）。
  void dispose() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    unawaited(_logSubscription?.cancel());
    _logSubscription = null;
    _pluginSubscription?.cancel();
    _statusController.close();
    _probeController.close();
  }

  /// 0.1.9 采样时序：核心成功启动后起 `Timer.periodic`，核心停即停。
  ///
  /// 每轮采三样（全部 try/catch，失败只记一行、不抛、不崩）：
  /// - 实时连接快照（`GET /connections` 完整条目，按 chain 首元＝叶子
  ///   出站聚合：每出站的连接数与累计上下行字节）；
  /// - 两路 DNS 探针：直连路 `www.baidu.com`（.cn 规则→dns-direct）、
  ///   代理路 `www.youtube.com`（流媒体规则→dns-proxy），各记成败与延迟；
  /// - 黑断标记：代理路 DNS 从通过变失败的那一次采样行内标
  ///   `疑似黑断 HH:MM:SS`（之前至少通过过一次才标，之后不再重复标）。
  /// 探活在跑（`_verifying`）时跳过本轮，不与启动探活抢跑；核心没跑
  /// 时不采样。行格式：相对秒数、两路 DNS 成败与延迟、各出站连接数
  /// 与流量、黑断标记（有时才有）。
  void _startSampling() {
    _stopSampling();
    _sampleStartedAt = DateTime.now();
    _blackoutAt = null;
    _proxyDnsEverOk = false;
    _timeline.clear();
    _coreLogTail.clear();
    _sampleTimer = Timer.periodic(sampleInterval, (_) {
      unawaited(_sampleOnce());
    });
  }

  void _stopSampling() {
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _timeline.clear();
    _sampleStartedAt = null;
    _blackoutAt = null;
    _proxyDnsEverOk = false;
  }

  Future<void> _sampleOnce() async {
    if (_status != CoreStatus.started) return;
    if (_verifying) return;
    if (_sampling) return;
    if (_sampleStartedAt == null) return;
    _sampling = true;
    try {
      final rel = DateTime.now().difference(_sampleStartedAt!).inSeconds;
      final results = await Future.wait([
        _clashApi.queryDns('www.baidu.com'),
        _clashApi.queryDns('www.youtube.com'),
        _clashApi.getConnectionEntries(),
      ]);
      final directDns = results[0] as DnsQueryResult;
      final proxyDns = results[1] as DnsQueryResult;
      final entries = results[2] as List<ConnectionEntry>;
      String? blackoutMark;
      if (proxyDns.ok) {
        _proxyDnsEverOk = true;
      } else if (_proxyDnsEverOk && _blackoutAt == null) {
        _blackoutAt = DateTime.now();
        blackoutMark =
            '疑似黑断 ${_blackoutAt!.hour.toString().padLeft(2, '0')}:'
            '${_blackoutAt!.minute.toString().padLeft(2, '0')}:'
            '${_blackoutAt!.second.toString().padLeft(2, '0')}';
      }
      // 按 chain 首元（叶子出站）聚合连接数与累计流量。
      final byOutbound = <String, _OutboundAggregate>{};
      for (final entry in entries) {
        final leaf = entry.chains.first;
        final agg = byOutbound.putIfAbsent(
          leaf,
          () => _OutboundAggregate(),
        );
        agg.count++;
        agg.upload += entry.upload;
        agg.download += entry.download;
      }
      final outboundText = byOutbound.isEmpty
          ? '无连接'
          : byOutbound.entries
                .map(
                  (e) =>
                      '${e.key}：${e.value.count}条 '
                      '↑${_formatBytes(e.value.upload)} '
                      '↓${_formatBytes(e.value.download)}',
                )
                .join('；');
      final row =
          '+${rel}s 直连DNS ${_dnsText(directDns)} '
          '| 代理DNS ${_dnsText(proxyDns)} '
          '| 连接 ${entries.length}条 '
          '| $outboundText'
          '${blackoutMark == null ? '' : ' ｜ $blackoutMark'}';
      _timeline.add(row);
      while (_timeline.length > sampleMaxEntries) {
        _timeline.removeAt(0);
      }
    } catch (e) {
      final rel = _sampleStartedAt == null
          ? '?'
          : DateTime.now().difference(_sampleStartedAt!).inSeconds.toString();
      _timeline.add('+${rel}s 采样失败：$e');
      while (_timeline.length > sampleMaxEntries) {
        _timeline.removeAt(0);
      }
    } finally {
      _sampling = false;
    }
  }

  static String _dnsText(DnsQueryResult result) =>
      result.ok ? '通过 ${result.latencyMs}ms' : '失败（${result.error}）';

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  static String _logLevelName(int level) => switch (level) {
    0 => 'Panic',
    1 => 'Fatal',
    2 => 'Error',
    3 => 'Warn',
    4 => 'Info',
    5 => 'Debug',
    6 => 'Trace',
    _ => 'L$level',
  };

  /// 原子写盘：先写同目录临时文件，再改名覆盖（Windows 上改名覆盖会
  /// 失败，失败时删旧文件再改名）。
  static Future<void> _writeAtomically(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content);
    try {
      await tmp.rename(path);
    } on FileSystemException {
      await File(path).delete();
      await tmp.rename(path);
    }
  }

  static Future<String> _defaultUsingConfigPath() async {
    return (await ProfileStorage().getUsingConfig()).path;
  }

  /// 默认的建档案逻辑：MMKV 里没有已选档案时，建一个名为“哲学系”的
  /// 本地档案并选中（只写元数据，配置体仍是 using_config.json）。
  ///
  /// 只在 start() 里调（在 [_usingConfigPath] 之后），而 start() 只在
  /// main() 已调过 `MMKV.initialize()` 之后才可能被点到，所以这里的
  /// ProfileStorage 访问一定发生在 MMKV 初始化之后；首次启动建好档案
  /// 再调 startVpn，不会报 EmptyConfiguration。
  static Future<void> _defaultEnsureSelectedProfile(
    String configPath,
  ) async {
    final storage = ProfileStorage();
    if (storage.getSelectedProfile() != null) return;
    final id = storage.generateProfileId;
    final profile = Profile(
      id: id,
      order: 0,
      name: '哲学系',
      outboundsCount: null,
      typed: TypedProfile(
        type: ProfileType.local,
        path: configPath,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    storage.updateProfile(profile);
    storage.setSelectedProfile(id);
  }
}

/// 采样聚合：一个叶子出站的连接数与累计上下行字节（0.1.9 采样时序）。
class _OutboundAggregate {
  int count = 0;
  int upload = 0;
  int download = 0;
}
