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
      for descriptor in 0..<scanLimit {
        let fd = Int32(descriptor)
        if fcntl(fd, F_GETFD) == -1 { continue }
        var info = stat()
        if fstat(fd, &info) == 0 {
          switch info.st_mode & mode_t(S_IFMT) {
          case mode_t(S_IFSOCK): sockets += 1
          case mode_t(S_IFREG), mode_t(S_IFDIR): files += 1
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
        "softLimit": NSNumber(value: limits.rlim_cur), "scanned": scanLimit,
        "bundleOpenErrno": probeError,
        "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
      ])
    }
  }
}
