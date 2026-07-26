package com.example.gyro360

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, MotionStreamHandler.CHANNEL)
            .setStreamHandler(MotionStreamHandler(this))
    }
}

/**
 * Отдаёт в Dart гравитацию и скорость вращения одним потоком.
 *
 * Зачем свой канал, а не sensors_plus: тот даёт только TYPE_ACCELEROMETER, а
 * он меряет гравитацию ВМЕСТЕ с ускорением руки - от рывка "наклон" уезжал,
 * хотя телефон не наклоняли. У Android для этого есть отдельный TYPE_GRAVITY:
 * система сама вычитает собственное ускорение, сливая акселерометр с
 * гироскопом. Это тот же приём, что и CMDeviceMotion на iOS (см.
 * ios/Runner/MotionChannel.swift), поэтому и формат посылки одинаковый -
 * математика в Dart на обеих платформах общая.
 *
 * Гироскоп берём обычный: TYPE_GYROSCOPE на Android уже идёт с вычтенным
 * смещением нуля, в отличие от сырого гироскопа iOS.
 */
class MotionStreamHandler(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    companion object {
        const val CHANNEL = "gyro360/motion"

        // 50 Гц - столько же, сколько просит iOS-канал.
        private const val SAMPLING_US = 20_000
    }

    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null
    private val gravity = FloatArray(3)
    private var haveGravity = false

    // Абсолютная ориентация как кватернион [w, x, y, z]. От гироскопа она
    // отличается принципиально: TYPE_ROTATION_VECTOR слит с магнитометром, то
    // есть у поворота вокруг вертикали есть опора и он НЕ уползает. Гироскоп
    // такой опоры не имеет, и любой остаток смещения нуля копится без конца.
    private val quaternion = FloatArray(4)
    private var haveQuaternion = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        // TYPE_GRAVITY есть не на всех устройствах; там, где его нет,
        // откатываемся на сырой акселерометр - это ровно то, что было раньше.
        val gravitySensor = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val gyro = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        if (gravitySensor == null || gyro == null) {
            events?.error("UNAVAILABLE", "Motion sensors are not available on this device", null)
            return
        }
        sensors.registerListener(this, gravitySensor, SAMPLING_US)
        sensors.registerListener(this, gyro, SAMPLING_US)
        // Необязательный: если его нет, Dart сам вернётся к интегрированию.
        sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let {
            sensors.registerListener(this, it, SAMPLING_US)
        }
    }

    override fun onCancel(arguments: Any?) {
        sensors.unregisterListener(this)
        sink = null
        haveGravity = false
        haveQuaternion = false
    }

    override fun onSensorChanged(e: SensorEvent) {
        when (e.sensor.type) {
            Sensor.TYPE_GRAVITY, Sensor.TYPE_ACCELEROMETER -> {
                gravity[0] = e.values[0]
                gravity[1] = e.values[1]
                gravity[2] = e.values[2]
                haveGravity = true
            }
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getQuaternionFromVector(quaternion, e.values)
                haveQuaternion = true
            }
            Sensor.TYPE_GYROSCOPE -> {
                // Посылку формирует гироскоп: именно он задаёт шаг интегрирования
                // в Dart, а гравитация нужна только как последнее известное
                // направление "вниз".
                if (!haveGravity) return
                val out = mutableListOf(
                    gravity[0].toDouble(), gravity[1].toDouble(), gravity[2].toDouble(),
                    e.values[0].toDouble(), e.values[1].toDouble(), e.values[2].toDouble()
                )
                // Кватернион дописываем в конец, чтобы посылка без него осталась
                // читаемой: Dart смотрит на длину списка.
                if (haveQuaternion) {
                    out.add(quaternion[0].toDouble())
                    out.add(quaternion[1].toDouble())
                    out.add(quaternion[2].toDouble())
                    out.add(quaternion[3].toDouble())
                }
                sink?.success(out)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
