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
    let playlistUrlString = arguments?["playlistUrl"] as? String

    remuxTsToMp4(
      sourcePath: sourcePath,
      outputPath: outputPath,
      playlistUrlString: playlistUrlString
    ) { remuxResult in
      DispatchQueue.main.async {
        switch remuxResult {
        case .success(let outputBytes):
          result(["outputBytes": outputBytes])
        case .failure(let error):
          let nsError = error as NSError
          result(
            FlutterError(
              code: "remux_failed",
              message: describeNSError(nsError),
              details: [
                "domain": nsError.domain,
                "code": nsError.code,
                "reason": nsError.localizedFailureReason ?? "",
              ]
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
    playlistUrlString: String?,
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
    do {
      try fileManager.createDirectory(
        at: outputUrl.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: outputUrl.path) {
        try fileManager.removeItem(at: outputUrl)
      }
    } catch {
      completion(.failure(error))
      return
    }

    let asset = AVURLAsset(url: sourceUrl)
    exportHlsAsset(
      asset: asset,
      outputUrl: outputUrl,
      fileManager: fileManager,
      attempts: hlsExportAttempts(),
      errors: [],
      completion: { [weak self] result in
        switch result {
        case .success:
          completion(result)
        case .failure(let sourceError):
          self?.exportHlsPlaylistFallback(
            playlistUrlString: playlistUrlString,
            outputUrl: outputUrl,
            fileManager: fileManager,
            sourceError: sourceError,
            completion: completion
          ) ?? completion(.failure(sourceError))
        }
      }
    )
  }

  private func hlsExportAttempts() -> [(presetName: String, fileType: AVFileType)] {
    return [
      (AVAssetExportPresetPassthrough, .mp4),
      (AVAssetExportPresetPassthrough, .m4v),
      (AVAssetExportPresetHighestQuality, .mp4),
      (AVAssetExportPresetHighestQuality, .m4v),
      (AVAssetExportPresetMediumQuality, .mp4),
      (AVAssetExportPresetMediumQuality, .m4v),
    ]
  }

  private func exportHlsPlaylistFallback(
    playlistUrlString: String?,
    outputUrl: URL,
    fileManager: FileManager,
    sourceError: Error,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    guard
      let playlistUrlString,
      !playlistUrlString.isEmpty,
      let playlistUrl = URL(string: playlistUrlString)
    else {
      completion(.failure(sourceError))
      return
    }

    // 作者: long
    // iOS 的 AVFoundation 在 simulator/部分系统上不能稳定打开本地 TS 拼接文件，失败后改用原始 VOD playlist 导出，避免 HLS 任务只能落到失败态。
    let playlistAsset = AVURLAsset(url: playlistUrl)
    exportHlsAsset(
      asset: playlistAsset,
      outputUrl: outputUrl,
      fileManager: fileManager,
      attempts: hlsExportAttempts(),
      errors: ["local TS remux failed: \(describeNSError(sourceError as NSError))"],
      completion: completion
    )
  }

  private func exportHlsAsset(
    asset: AVURLAsset,
    outputUrl: URL,
    fileManager: FileManager,
    attempts: [(presetName: String, fileType: AVFileType)],
    errors: [String],
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    guard let attempt = attempts.first else {
      remuxHlsAssetWithReaderWriter(
        asset: asset,
        outputUrl: outputUrl,
        fileManager: fileManager,
        exportErrors: errors,
        completion: completion
      )
      return
    }

    let remainingAttempts = Array(attempts.dropFirst())
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: attempt.presetName) else {
      exportHlsAsset(
        asset: asset,
        outputUrl: outputUrl,
        fileManager: fileManager,
        attempts: remainingAttempts,
        errors: errors + ["\(attempt.presetName)/\(attempt.fileType.rawValue): export session unavailable"],
        completion: completion
      )
      return
    }

    guard exportSession.supportedFileTypes.contains(attempt.fileType) else {
      let supported = exportSession.supportedFileTypes.map { $0.rawValue }.joined(separator: ",")
      exportHlsAsset(
        asset: asset,
        outputUrl: outputUrl,
        fileManager: fileManager,
        attempts: remainingAttempts,
        errors: errors + ["\(attempt.presetName)/\(attempt.fileType.rawValue): unsupported (\(supported))"],
        completion: completion
      )
      return
    }

    let tempUrl = temporaryMediaUrl(for: outputUrl, fileType: attempt.fileType)
    try? fileManager.removeItem(at: tempUrl)

    // 作者: long
    // iOS simulator 对很小的 TS fixture 使用 passthrough 时可能拒绝导出，逐级回退到转码 preset 才能保住 HLS 输出为真实 MP4。
    exportSession.outputURL = tempUrl
    exportSession.outputFileType = attempt.fileType
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
        try? fileManager.removeItem(at: tempUrl)
        let exportError = describeNSError(exportSession.error as NSError?)
        self.exportHlsAsset(
          asset: asset,
          outputUrl: outputUrl,
          fileManager: fileManager,
          attempts: remainingAttempts,
          errors: errors + ["\(attempt.presetName)/\(attempt.fileType.rawValue): \(exportError)"],
          completion: completion
        )
      }
    }
  }

  private func remuxHlsAssetWithReaderWriter(
    asset: AVURLAsset,
    outputUrl: URL,
    fileManager: FileManager,
    exportErrors: [String],
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let tempUrl = temporaryMediaUrl(for: outputUrl, fileType: .mp4)
    try? fileManager.removeItem(at: tempUrl)

    do {
      let reader = try AVAssetReader(asset: asset)
      let writer = try AVAssetWriter(outputURL: tempUrl, fileType: .mp4)
      var pairs: [(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput)] = []

      // 作者: long
      // AVAssetExportSession 不能稳定把本地 TS 转为 MP4 时，直接搬运压缩 sample，避免把 HLS 输出降级成伪 mp4。
      for mediaType in [AVMediaType.video, AVMediaType.audio] {
        for track in asset.tracks(withMediaType: mediaType) {
          let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
          output.alwaysCopiesSampleData = false
          guard reader.canAdd(output) else {
            continue
          }

          let sourceFormatHint = track.formatDescriptions.first.map {
            unsafeBitCast($0, to: CMFormatDescription.self)
          }
          let input = AVAssetWriterInput(
            mediaType: mediaType,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
          )
          input.expectsMediaDataInRealTime = false
          guard writer.canAdd(input) else {
            continue
          }

          reader.add(output)
          writer.add(input)
          pairs.append((input, output))
        }
      }

      guard !pairs.isEmpty else {
        throw NSError(
          domain: "FluxDownMedia",
          code: 4,
          userInfo: [
            NSLocalizedDescriptionKey: "Unable to read audio or video tracks from HLS transport stream.",
            NSLocalizedFailureReasonErrorKey: exportErrors.joined(separator: " | "),
          ]
        )
      }

      guard reader.startReading() else {
        throw reader.error ?? NSError(
          domain: "FluxDownMedia",
          code: 5,
          userInfo: [NSLocalizedDescriptionKey: "Unable to start HLS reader."]
        )
      }
      guard writer.startWriting() else {
        reader.cancelReading()
        throw writer.error ?? NSError(
          domain: "FluxDownMedia",
          code: 6,
          userInfo: [NSLocalizedDescriptionKey: "Unable to start MP4 writer."]
        )
      }

      writer.startSession(atSourceTime: .zero)
      let group = DispatchGroup()
      let queue = DispatchQueue(label: "dev.fluxdown.mobile.hls-remux", qos: .userInitiated)
      let lock = NSLock()
      var appendError: Error?

      for pair in pairs {
        group.enter()
        var inputFinished = false
        pair.input.requestMediaDataWhenReady(on: queue) {
          guard !inputFinished else {
            return
          }
          while pair.input.isReadyForMoreMediaData {
            if let sampleBuffer = pair.output.copyNextSampleBuffer() {
              if !pair.input.append(sampleBuffer) {
                lock.lock()
                appendError = appendError ?? writer.error
                lock.unlock()
                inputFinished = true
                pair.input.markAsFinished()
                group.leave()
                return
              }
            } else {
              inputFinished = true
              pair.input.markAsFinished()
              group.leave()
              return
            }
          }
        }
      }

      group.notify(queue: queue) {
        lock.lock()
        let capturedError = appendError
        lock.unlock()

        if let capturedError {
          reader.cancelReading()
          writer.cancelWriting()
          try? fileManager.removeItem(at: tempUrl)
          completion(.failure(capturedError))
          return
        }

        if reader.status == .failed || reader.status == .cancelled {
          writer.cancelWriting()
          try? fileManager.removeItem(at: tempUrl)
          completion(.failure(reader.error ?? NSError(
            domain: "FluxDownMedia",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "HLS reader failed."]
          )))
          return
        }

        writer.finishWriting {
          if writer.status != .completed {
            try? fileManager.removeItem(at: tempUrl)
            completion(.failure(writer.error ?? NSError(
              domain: "FluxDownMedia",
              code: 8,
              userInfo: [NSLocalizedDescriptionKey: "MP4 writer failed."]
            )))
            return
          }

          do {
            try fileManager.moveItem(at: tempUrl, to: outputUrl)
            let attributes = try fileManager.attributesOfItem(atPath: outputUrl.path)
            let outputBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            completion(.success(outputBytes))
          } catch {
            completion(.failure(error))
          }
        }
      }
    } catch {
      try? fileManager.removeItem(at: tempUrl)
      completion(.failure(error))
    }
  }

  private func temporaryMediaUrl(for outputUrl: URL, fileType: AVFileType) -> URL {
    let fileExtension = fileType == .m4v ? "m4v" : "mp4"
    return outputUrl
      .deletingLastPathComponent()
      .appendingPathComponent(".\(outputUrl.lastPathComponent).tmp.\(fileExtension)")
  }
}

private func describeNSError(_ error: NSError?) -> String {
  guard let error else {
    return "Unknown export failure."
  }

  let reason = error.localizedFailureReason ?? ""
  if reason.isEmpty {
    return error.localizedDescription
  }
  return "\(error.localizedDescription) (\(reason))"
}
