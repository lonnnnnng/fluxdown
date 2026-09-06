// Rust core（crates/fluxdown-ffi）的移动端桥接层。
//
// 策略：动态库加载成功时协议能力走 FFI 优先（与桌面端共享 Rust core），
// 加载失败或调用异常一律回退 Dart 自实现，保证零行为回归。
// 动态库由 CI 的 Android 构建打进 jniLibs（libfluxdown_ffi.so），
// iOS 静态库产物见 docs/build-release.md 的 FFI 章节。

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
  static String? detectProtocol(String source) {
    final core = _ffi;
    if (core == null) return null;
    try {
      final envelope = core.detect(source);
      final data = envelope['data'];
      if (data is Map && data['protocol'] is String) {
        return data['protocol'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
