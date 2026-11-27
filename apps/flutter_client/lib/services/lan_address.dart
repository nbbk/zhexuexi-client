import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 本机局域网 IPv4（如 192.168.1.5），没有时返回 null。
/// 局域网代理开着时首页格子与设置页用它拼“IP:端口”；只作展示，
/// 拿不到也不影响代理本身（监听的是 0.0.0.0）。
Future<String?> fetchLanIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    // 先找私有地址（家里 Wi-Fi 常见段）。
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            _is172Private(ip)) {
          return ip;
        }
      }
    }
    // 没有私有地址时回落第一个非回环 IPv4（有总比没有强）。
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (!addr.address.startsWith('127.')) return addr.address;
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

bool _is172Private(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4 || parts[0] != '172') return false;
  final second = int.tryParse(parts[1]);
  return second != null && second >= 16 && second <= 31;
}

/// 首页格子与设置页共用的局域网 IP（只查一次，页面重建不重查；
/// 测试里用 override 固定返回值）。
final lanIpProvider = FutureProvider<String?>((_) => fetchLanIp());
