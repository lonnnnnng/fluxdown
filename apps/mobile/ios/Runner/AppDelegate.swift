import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeChannelsRegistered = false
  private var storageChannel: FlutterMethodChannel?
  private var mediaChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerNativeChannelsFromRootController()
    return didFinish
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerNativeChannels(binaryMessenger: engineBridge.applicationRegistrar.messenger())
  }

  private func registerNativeChannelsFromRootController() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }
    registerNativeChannels(binaryMessenger: controller.binaryMessenger)
  }

  private func registerNativeChannels(binaryMessenger: FlutterBinaryMessenger) {
    guard !nativeChannelsRegistered else {
      return
    }
    nativeChannelsRegistered = true

    storageChannel = FlutterMethodChannel(
      name: "dev.fluxdown.mobile/storage",
      binaryMessenger: binaryMessenger
    )
    storageChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handleStorageMethod(call, result: result)
    }

    mediaChannel = FlutterMethodChannel(
      name: "dev.fluxdown.mobile/media",
      binaryMessenger: binaryMessenger
    )
    mediaChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handleMediaMethod(call, result: result)
    }
  }

  private func handleStorageMethod(_ call: FlutterMethodCall, result: FlutterResult) {
    guard call.method == "getStorageStats" else {
      result(FlutterMethodNotImplemented)
      return
    }

    let arguments = call.arguments as? [String: Any]
    let requestedPath = arguments?["path"] as? String
    let targetPath = resolveExistingPath(requestedPath)

    do {
      let attributes = try FileManager.default.attributesOfFileSystem(forPath: targetPath)
      let totalBytes = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
      let freeBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
      result([
        "totalBytes": totalBytes,
        "freeBytes": freeBytes,
      ])
    } catch {
      result(
        FlutterError(
          code: "storage_stats_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func handleMediaMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "remuxTsToMp4" else {
      result(FlutterMethodNotImplemented)
      return
    }

    let arguments = call.arguments as? [String: Any]
    guard
      let sourcePath = arguments?["sourcePath"] as? String,
      let outputPath = arguments?["outputPath"] as? String,
      !sourcePath.isEmpty,
      !outputPath.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "sourcePath and outputPath are required",
          details: nil
        )
      )
      return
    }

    remuxTsToMp4(sourcePath: sourcePath, outputPath: outputPath) { remuxResult in
      DispatchQueue.main.async {
        switch remuxResult {
        case .success(let outputBytes):
          result(["outputBytes": outputBytes])
        case .failure(let error):
          result(
            FlutterError(
              code: "remux_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func resolveExistingPath(_ path: String?) -> String {
    let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
      .first?
      .path ?? NSHomeDirectory()
    var current = (path?.isEmpty == false ? path : fallback) ?? fallback

    while !current.isEmpty && !FileManager.default.fileExists(atPath: current) {
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current {
        break
      }
      current = parent
    }

    return current.isEmpty ? fallback : current
  }

  private func remuxTsToMp4(
    sourcePath: String,
    outputPath: String,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourcePath) else {
      completion(.failure(NSError(
        domain: "FluxDownMedia",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Source TS file does not exist."]
      )))
      return
    }

    let sourceUrl = URL(fileURLWithPath: sourcePath)
    let outputUrl = URL(fileURLWithPath: outputPath)
    let tempUrl = outputUrl.appendingPathExtension("tmp")

    do {
      try fileManager.createDirectory(
        at: outputUrl.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: tempUrl.path) {
        try fileManager.removeItem(at: tempUrl)
      }
      if fileManager.fileExists(atPath: outputUrl.path) {
        try fileManager.removeItem(at: outputUrl)
      }
    } catch {
      completion(.failure(error))
      return
    }

    let asset = AVURLAsset(url: sourceUrl)
    guard let exportSession = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetPassthrough
    ) else {
      completion(.failure(NSError(
        domain: "FluxDownMedia",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Unable to create MP4 export session."]
      )))
      return
    }

    exportSession.outputURL = tempUrl
    exportSession.outputFileType = .mp4
    exportSession.shouldOptimizeForNetworkUse = true
    exportSession.exportAsynchronously {
      switch exportSession.status {
      case .completed:
        do {
          try fileManager.moveItem(at: tempUrl, to: outputUrl)
          let attributes = try fileManager.attributesOfItem(atPath: outputUrl.path)
          let outputBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
          completion(.success(outputBytes))
        } catch {
          completion(.failure(error))
        }
      default:
        if fileManager.fileExists(atPath: tempUrl.path) {
          try? fileManager.removeItem(at: tempUrl)
        }
        completion(.failure(exportSession.error ?? NSError(
          domain: "FluxDownMedia",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "MP4 export failed."]
        )))
      }
    }
  }
}
