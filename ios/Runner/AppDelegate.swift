import Flutter
import UIKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var runtimeChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BiliBeatRuntime") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "bilibeat/runtime", binaryMessenger: registrar.messenger())
    runtimeChannel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "resources" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // fcntl/fstat do not open additional descriptors, so this still works
      // when EMFILE prevents both file access and DNS socket creation.
      var limits = rlimit()
      guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
        result(FlutterError(code: "getrlimit", message: String(errno), details: nil))
        return
      }
      let scanLimit = Int(min(limits.rlim_cur, 4096))
      var files = 0
      var sockets = 0
      var other = 0
      var filePaths: [String: Int] = [:]
      var unresolvedFiles = 0
      let home = NSHomeDirectory()
      var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
      for descriptor in 0..<scanLimit {
        let fd = Int32(descriptor)
        if fcntl(fd, F_GETFD) == -1 { continue }
        var info = stat()
        if fstat(fd, &info) == 0 {
          switch info.st_mode & mode_t(S_IFMT) {
          case mode_t(S_IFSOCK): sockets += 1
          case mode_t(S_IFREG), mode_t(S_IFDIR):
            files += 1
            // F_GETPATH identifies an already-open descriptor without opening
            // another file. Counts alone cannot locate the leaking owner.
            let pathResult = pathBuffer.withUnsafeMutableBufferPointer {
              fcntl(fd, F_GETPATH, $0.baseAddress!)
            }
            if pathResult == 0 {
              let path = pathBuffer.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
              }
              let label = path.hasPrefix(home + "/")
                ? "$APP" + String(path.dropFirst(home.count)) : path
              filePaths[label, default: 0] += 1
            } else {
              unresolvedFiles += 1
            }
          default: other += 1
          }
        } else {
          other += 1
        }
      }
      // Distinguish resource exhaustion from protected-data/sandbox denial.
      let probe = open(Bundle.main.bundlePath, O_RDONLY)
      let probeError = probe < 0 ? errno : 0
      if probe >= 0 { close(probe) }
      result([
        "openFDs": files + sockets + other,
        "files": files, "sockets": sockets, "other": other,
        "topFiles": filePaths.sorted {
          $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(12).map { ["path": $0.key, "count": $0.value] as [String: Any] },
        "unresolvedFiles": unresolvedFiles,
        "softLimit": NSNumber(value: limits.rlim_cur), "scanned": scanLimit,
        "bundleOpenErrno": probeError,
        "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
      ])
    }
  }
}
