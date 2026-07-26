import CoreMotion
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Держим обработчик живым: канал ссылается на него слабо.
  private let motionChannel = MotionChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterEventChannel(
      name: MotionChannel.channelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setStreamHandler(motionChannel)
  }
}

/// Отдаёт в Dart слитые данные CoreMotion вместо сырых датчиков.
///
/// Зачем свой канал: sensors_plus на iOS читает startAccelerometerUpdates и
/// startGyroUpdates, то есть СЫРЫЕ датчики. У гироскопа там не вычтено
/// смещение нуля (на Android его снимает система), а акселерометр отдаёт
/// гравитацию вместе с ускорением руки. Из-за первого уползал Yaw, из-за
/// второго рывок рукой сбивал наклон.
///
/// CMDeviceMotion решает обе задачи там, где это делается лучше всего - в
/// самой системе: она непрерывно оценивает смещение гироскопа, в том числе на
/// ходу (оценка "по неподвижности", которую приложение делает само, так не
/// умеет), и раскладывает акселерометр на гравитацию и собственное ускорение.
///
/// Класс живёт здесь, а не в своём файле, намеренно: цель Runner собирает
/// только те файлы, что перечислены в project.pbxproj, и новый .swift рядом с
/// остальными просто не попадёт в сборку.
class MotionChannel: NSObject, FlutterStreamHandler {
  static let channelName = "gyro360/motion"

  private let motion = CMMotionManager()
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "gyro360.motion"
    q.maxConcurrentOperationCount = 1
    return q
  }()

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard motion.isDeviceMotionAvailable else {
      return FlutterError(
        code: "UNAVAILABLE",
        message: "Device motion is not available on this device",
        details: nil)
    }

    // 50 Гц - ровно столько же, сколько Dart просит у датчиков на Android,
    // чтобы поведение на двух платформах совпадало.
    motion.deviceMotionUpdateInterval = 1.0 / 50.0

    // Рамку выбирает переключатель компаса в приложении: с коррекцией по
    // магнитометру поворот не уползает, без неё - не зависит от железа рядом.
    // Одновременно две рамки CMMotionManager не отдаёт, поэтому при
    // переключении Dart переподписывается заново.
    // Магнитный север не берём ни в каком случае: считается только ИЗМЕНЕНИЕ
    // поворота, а рядом с ротатором достаточно железа, чтобы север уехал.
    let useCompass = (arguments as? Bool) ?? false
    let available = CMMotionManager.availableAttitudeReferenceFrames()
    let frame: CMAttitudeReferenceFrame =
      (useCompass && available.contains(.xArbitraryCorrectedZVertical))
      ? .xArbitraryCorrectedZVertical
      : .xArbitraryZVertical

    motion.startDeviceMotionUpdates(using: frame, to: queue) { data, error in
      if let error = error {
        DispatchQueue.main.async {
          events(
            FlutterError(
              code: "UNAVAILABLE",
              message: error.localizedDescription,
              details: nil))
        }
        return
      }
      guard let d = data else { return }

      let g = d.gravity
      let r = d.rotationRate
      let q = d.attitude.quaternion
      // Знаки и единицы приводим к соглашению Android - ровно так же, как это
      // делает сам sensors_plus (инвертирует оси и переводит g в м/с²).
      // Тогда на обеих платформах работает одна и та же математика в Dart.
      // Кватернион идёт последним и в том же порядке [w, x, y, z], что даёт
      // Android SensorManager.getQuaternionFromVector.
      let payload: [Double] = [
        -g.x * 9.80665, -g.y * 9.80665, -g.z * 9.80665,
        r.x, r.y, r.z,
        q.w, q.x, q.y, q.z,
      ]
      // events() обязан вызываться на главном потоке - обновления CoreMotion
      // приходят на фоновую очередь.
      DispatchQueue.main.async { events(payload) }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    motion.stopDeviceMotionUpdates()
    return nil
  }
}
