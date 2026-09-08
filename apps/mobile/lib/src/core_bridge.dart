// Rust core（crates/fluxdown-ffi）的移动端桥接层。
//
// 策略：动态库加载成功时协议能力走 FFI 优先（与桌面端共享 Rust core），
// 加载失败或调用异常回退 Dart 自实现；下载执行仍由移动端控制器负责。
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
}
