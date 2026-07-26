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

    // Ориентация как кватернион [w, x, y, z], два источника.
    //
    // Основной - TYPE_GAME_ROTATION_VECTOR: слияние акселерометра с гироскопом
    // БЕЗ магнитометра. Считать поворот самим интегрированием гироскопа нельзя:
    // мы опрашиваем его 50 раз в секунду, а при встряске телефон за один шаг
    // успевает провернуться на несколько градусов, да и вращения вокруг разных
    // осей не складываются линейно - ошибка набегает сразу и остаётся навсегда.
    // Система интегрирует на своей частоте и такой ошибки не даёт.
    private val quatMotion = FloatArray(4)
    private var haveMotion = false

    // Второй - TYPE_ROTATION_VECTOR, тот же расчёт, но с магнитометром. Он не
    // уползает и потому годится как эталон, к которому Dart медленно
    // подтягивает угол. Поднимаем его только если поправка включена.
    private val quatCompass = FloatArray(4)
    private var haveCompass = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val useCompass = arguments as? Boolean ?: false
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
        // Оба необязательны: если их нет, Dart вернётся к интегрированию.
        sensors.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)?.let {
            sensors.registerListener(this, it, SAMPLING_US)
        }
        if (useCompass) {
            sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let {
                sensors.registerListener(this, it, SAMPLING_US)
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sensors.unregisterListener(this)
        sink = null
        haveGravity = false
        haveMotion = false
        haveCompass = false
    }

    override fun onSensorChanged(e: SensorEvent) {
        when (e.sensor.type) {
            Sensor.TYPE_GRAVITY, Sensor.TYPE_ACCELEROMETER -> {
                gravity[0] = e.values[0]
                gravity[1] = e.values[1]
                gravity[2] = e.values[2]
                haveGravity = true
            }
            Sensor.TYPE_GAME_ROTATION_VECTOR -> {
                SensorManager.getQuaternionFromVector(quatMotion, e.values)
                haveMotion = true
            }
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getQuaternionFromVector(quatCompass, e.values)
                haveCompass = true
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
                // Кватернионы дописываем в конец, чтобы посылка без них
                // осталась читаемой: Dart смотрит на длину списка. Порядок
                // фиксирован - сначала основной, потом эталон компаса, так что
                // второй без первого не отправляем.
                if (haveMotion) {
                    for (i in 0..3) out.add(quatMotion[i].toDouble())
                    if (haveCompass) {
                        for (i in 0..3) out.add(quatCompass[i].toDouble())
                    }
                }
                sink?.success(out)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
