import 'package:flutter/services.dart';

/// 移动端下载运行时的系统后台边界。
///
/// Android 使用前台服务提升进程存活优先级并展示进度通知；iOS 只申请系统允许的
/// 短时后台窗口，窗口结束后仍由队列恢复逻辑接管，避免把不可保证的后台常驻伪装成已完成。
class MobileBackgroundService {
  static const _channel = MethodChannel('dev.fluxdown.mobile/background');

  Future<void> start({int runningTasks = 0}) async {
    try {
      await _channel.invokeMethod<void>('startForegroundDownload', {
        'runningTasks': runningTasks,
      });
    } on MissingPluginException {
      // 桌面/测试运行时没有移动原生通道，按前台模式继续工作。
    } on PlatformException {
      // 后台通知权限或系统策略拒绝时不阻断下载，前台队列仍可继续执行。
    }
  }

  Future<void> update({
    required int runningTasks,
    required int finishedTasks,
    required int totalTasks,
    required int progressPercent,
  }) async {
    try {
      await _channel.invokeMethod<void>('updateForegroundDownload', {
        'runningTasks': runningTasks,
        'finishedTasks': finishedTasks,
        'totalTasks': totalTasks,
        'progressPercent': progressPercent.clamp(0, 100),
      });
    } on MissingPluginException {
      // 非移动运行时没有系统通知。
    } on PlatformException {
      // 通知更新失败不应影响下载任务本身。
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopForegroundDownload');
    } on MissingPluginException {
      // 非移动运行时没有系统通知。
    } on PlatformException {
      // 服务已被系统回收时停止本身就是幂等操作。
    }
  }

  Future<void> beginIosBackgroundWindow() async {
    try {
      await _channel.invokeMethod<void>('beginBackgroundWindow');
    } on MissingPluginException {
      // Android、桌面和测试运行时忽略 iOS 专属窗口。
    } on PlatformException {
      // iOS 后台时间申请失败时由现有断点恢复逻辑兜底。
    }
  }

  Future<void> endIosBackgroundWindow() async {
    try {
      await _channel.invokeMethod<void>('endBackgroundWindow');
    } on MissingPluginException {
      // Android、桌面和测试运行时忽略 iOS 专属窗口。
    } on PlatformException {
      // 结束已失效的后台任务不应影响前台恢复。
    }
  }
}
