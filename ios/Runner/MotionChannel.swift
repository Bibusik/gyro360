import CoreMotion
import Flutter

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

    // 50 Гц - ровно столько же, сколько Dart просит у sensors_plus на Android,
    // чтобы поведение на двух платформах совпадало.
    motion.deviceMotionUpdateInterval = 1.0 / 50.0

    // Магнитометр помогает системе точнее оценить смещение гироскопа, поэтому
    // просим рамку с коррекцией. Но именно "произвольную", а не магнитный
    // север: приложение считает только ИЗМЕНЕНИЕ поворота, а рядом с ротатором
    // достаточно железа, чтобы север уехал.
    let available = CMMotionManager.availableAttitudeReferenceFrames()
    let frame: CMAttitudeReferenceFrame =
      available.contains(.xArbitraryCorrectedZVertical)
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
      // Знаки и единицы приводим к соглашению Android - ровно так же, как это
      // делает сам sensors_plus (инвертирует оси и переводит g в м/с²).
      // Тогда на обеих платформах работает одна и та же математика в Dart.
      let payload: [Double] = [
        -g.x * 9.80665, -g.y * 9.80665, -g.z * 9.80665,
        r.x, r.y, r.z,
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
