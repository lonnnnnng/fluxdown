// Rust core（crates/fluxdown-ffi）的移动端桥接层。
//
// 策略：动态库加载成功时协议能力走 FFI 优先（与桌面端共享 Rust core），
// 加载失败或调用异常回退 Dart 自实现；下载执行默认仍由移动端控制器负责，
// 迁移验证可通过 RustQueueBackend 显式注入 Rust 队列。
// 动态库由 CI 的 Android 构建打进 jniLibs（libfluxdown_ffi.so），
// iOS 静态库产物见 docs/build-release.md 的 FFI 章节。

import 'dart:async';

import 'ffi/fluxdown_ffi.dart';

class FluxDownCoreBridge {
  FluxDownCoreBridge._();

  static FluxDownCoreFfi? _core;
  static bool _probed = false;

  /// 惰性探测动态库；失败只记一次，后续调用直接走 Dart 回退。
  static FluxDownCoreFfi? get _ffi {
    if (!_probed) {
      _probed = true;
      try {
        _core = FluxDownCoreFfi.open();
      } catch (_) {
        _core = null;
      }
    }
    return _core;
  }

  /// FFI 引擎是否可用（用于设置页/诊断展示）。
  static bool get available => _ffi != null;

  /// FFI 引擎版本号；不可用时返回 null。
  static String? get version {
    try {
      return _ffi?.version();
    } catch (_) {
      return null;
    }
  }

  /// FFI 协议识别；不可用或调用失败返回 null（调用方回退 Dart 实现）。
  static String? detectProtocol(String source, {FluxDownCoreFfi? core}) {
    final engine = core ?? _ffi;
    if (engine == null) return null;
    try {
      // 作者: long
      // 绑定层已经解包 data，桥接层直接读取协议，避免二次解包误判为不可用并回退。
      final data = engine.detect(source);
      if (data['protocol'] is String) {
        return data['protocol'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 异步读取 Torrent/Magnet 元数据；Rust 失败时直接抛出，让新建任务显示明确错误。
  static Future<Map<String, Object?>?> inspectTorrentMetadata(
    String source, {
    String? taskId,
    Duration timeout = const Duration(minutes: 3),
    Duration pollInterval = const Duration(milliseconds: 200),
    FluxDownCoreFfi? core,
  }) async {
    final engine = core ?? _ffi;
    if (engine == null) return null;

    final start = engine.torrentDetailsAsync(source, taskId: taskId);
    final runId = start['runId'];
    if (runId is! String || runId.trim().isEmpty) return null;

    final deadline = DateTime.now().add(timeout);
    var terminal = false;
    try {
      while (DateTime.now().isBefore(deadline)) {
        final status = engine.queueRunStatus(runId);
        final state = status['state'] as String?;
        if (state == 'finished') {
          terminal = true;
          final report = status['report'];
          return report is Map<String, Object?>
              ? Map<String, Object?>.from(report)
              : report is Map
              ? Map<String, Object?>.from(report)
              : null;
        }
        if (state == 'failed') {
          terminal = true;
          throw FluxDownCoreException(
            status['error'] as String? ?? 'Rust Torrent/Magnet metadata 解析失败',
          );
        }
        await Future<void>.delayed(pollInterval);
      }
      return null;
    } finally {
      // 作者: long
      // 仅回收已结束的句柄；超时期间 Rust 仍可能在等待 tracker，不能误删运行态记录。
      if (terminal) {
        try {
          engine.queueRunForget(runId);
        } on Object {
          // 句柄回收失败不改变已经得到的 metadata 结果；下次进程启动时由 Rust 注册表兜底释放。
        }
      }
    }
  }
}
