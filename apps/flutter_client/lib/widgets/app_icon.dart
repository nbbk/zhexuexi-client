import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../core/app_tokens.dart';

/// 全端统一图标（Lucide 细线，24px 网格、2px 线、圆角端点）。
///
/// 所有页面都用它，不直接用 Material Icons（安卓味重）：
/// 图标名走 [AppIcons] 的映射表（Material 旧名 → Lucide），
/// 尺寸只走 [AppIconSize] 四档（16/20/24/32），不写死像素值。
class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.icon,
    this.size = AppIconSize.md,
    this.color,
  });

  /// 图标（取 [AppIcons] 里的映射，不要直接传 Material 的 [Icons]）。
  final IconData icon;

  /// 尺寸档（默认 md 24px）。
  final AppIconSize size;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: size.pixels, color: color);
  }
}

/// 图标映射：Material 旧名 → Lucide（全端统一 Lucide 细线）。
///
/// flutter_lucide 1.x 用 snake_case 命名（与 Lucide 官方 kebab-case
/// 对应）：`house`（旧 home）、`circle_check`、`refresh_cw`、
/// `eye_closed`（旧 eye-off）等，见包内 flutter_lucide.dart。
class AppIcons {
  AppIcons._();

  /// 首页（Material Icons.home）。
  static const IconData home = LucideIcons.house;

  /// 地球 / 节点（Icons.public）。
  static const IconData globe = LucideIcons.globe;

  /// 用户 / 我的（Icons.person）。
  static const IconData user = LucideIcons.user;

  /// 设置（Icons.settings）。
  static const IconData settings = LucideIcons.settings;

  /// 搜索（Icons.search）。
  static const IconData search = LucideIcons.search;

  /// 测速（Icons.speed_outlined）。
  static const IconData gauge = LucideIcons.gauge;

  /// 自动选择（Icons.auto_awesome_outlined）。
  static const IconData sparkles = LucideIcons.sparkles;

  /// 关闭（Icons.close）。
  static const IconData x = LucideIcons.x;

  /// 订阅列表（Icons.subscriptions_outlined）。
  static const IconData layers = LucideIcons.layers;

  /// 勾选圆圈（Icons.check_circle_outline）。
  static const IconData circleCheck = LucideIcons.circle_check;

  /// 刷新（Icons.refresh_outlined）。
  static const IconData refresh = LucideIcons.refresh_cw;

  /// 添加（Icons.add）。
  static const IconData plus = LucideIcons.plus;

  /// 扫码（Icons.qr_code_scanner）。
  static const IconData scan = LucideIcons.scan_line;

  /// 手电筒（Icons.flashlight_on）。
  static const IconData flashlight = LucideIcons.flashlight;

  /// 编辑（Icons.edit_outlined）。
  static const IconData pencil = LucideIcons.pencil;

  /// 删除 / 清除（Icons.delete_outline、Icons.delete_sweep_outlined）。
  static const IconData trash = LucideIcons.trash;

  /// 下载 / 更新（Icons.system_update_outlined）。
  static const IconData download = LucideIcons.arrow_down_to_line;

  /// 离线（Icons.cloud_off_outlined）。
  static const IconData cloudOff = LucideIcons.cloud_off;

  /// 公告（Icons.campaign_outlined）。
  static const IconData megaphone = LucideIcons.megaphone;

  /// 登录（Icons.login）。
  static const IconData logIn = LucideIcons.log_in;

  /// 退出登录（Icons.logout）。
  static const IconData logOut = LucideIcons.log_out;

  /// 切换（Icons.swap_horiz）。
  static const IconData swap = LucideIcons.arrow_left_right;

  /// 右箭头（Icons.chevron_right）。
  static const IconData chevronRight = LucideIcons.chevron_right;

  /// 诊断 / 反馈（Icons.bug_report_outlined）。
  static const IconData bug = LucideIcons.bug;

  /// 网络检测（Icons.network_check_outlined）。
  static const IconData network = LucideIcons.network;

  /// 显示密码（Icons.visibility）。
  static const IconData eye = LucideIcons.eye;

  /// 隐藏密码（Icons.visibility_off）。
  static const IconData eyeOff = LucideIcons.eye_closed;
}
