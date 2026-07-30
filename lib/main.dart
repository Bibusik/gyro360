import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';

// Источник наклона для режима Rod Remote. Ротатору всё равно, откуда пришёл
// угол: физический WT901 шлёт его сам по своему BLE-каналу, телефон - командой
// PITCH=. Поэтому все настройки (мёртвая зона, скорости, ось, реверс, ноль)
// у обоих общие, меняется только источник.
enum RemoteSource { wt901, off, phone }

void main() {
  runApp(const Gyro360App());
}

class Gyro360App extends StatelessWidget {
  const Gyro360App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GYRO360',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF607D8B)),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const MainScreen(),
    );
  }
}

// Адрес прошивки держим здесь, а не в коробке. Во-первых, в новой схеме образ
// качает телефон, а коробка в интернет не ходит вовсе - хранить адрес загрузки
// в устройстве, которое ничего не загружает, незачем. Во-вторых, коробка
// раздавала бы его в статусе любому подключившемуся клиенту, и ссылка с
// токеном уходила бы в эфир при каждом подключении.
const String kFirmwareUrl =
    'https://gyro360.lv/serz/ota.php?t=68619143c894573a1e9a922992d8df794067c1682b24fb2f2b13f4a92693b99d';

// ─── BLE GATT Manager (Nordic UART Service) ───────────────────────────────────
class BtManager {
  static final BtManager _instance = BtManager._();
  factory BtManager() => _instance;
  BtManager._();

  static final Guid _serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _rxCharUuid  = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // телефон -> ESP32
  static final Guid _txCharUuid  = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // ESP32 -> телефон
  static final Guid _otaCharUuid = Guid('6E400004-B5A3-F393-E0A9-E50E24DCCA9E'); // телефон -> ESP32 (бинарь прошивки)

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar; // write
  BluetoothCharacteristic? _txChar; // notify
  BluetoothCharacteristic? _otaChar; // write without response
  final _dataController = StreamController<String>.broadcast();
  String _buffer = '';
  StreamSubscription? _connSub;
  StreamSubscription? _notifySub;
  bool _connected = false;

  Stream<String> get dataStream => _dataController.stream;
  bool get isConnected => _connected;

  Future<void> connect(BluetoothDevice device) async {
    await disconnect();
    _device = device;
    await device.connect(autoConnect: false, mtu: 247);
    _connected = true;
    // Подписываемся ПОСЛЕ успешного подключения, иначе поток сразу
    // отдаёт текущее (disconnected) состояние и обрывает связь мгновенно.
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connected = false;
        _dataController.add('__DISCONNECTED__');
      }
    });
    final services = await device.discoverServices();
    final svc = services.firstWhere((s) => s.uuid == _serviceUuid);
    for (final c in svc.characteristics) {
      if (c.uuid == _rxCharUuid) _rxChar = c;
      if (c.uuid == _txCharUuid) _txChar = c;
      if (c.uuid == _otaCharUuid) _otaChar = c;
    }
    if (_txChar != null) {
      await _txChar!.setNotifyValue(true);
      _notifySub = _txChar!.onValueReceived.listen((data) {
        _buffer += String.fromCharCodes(data);
        while (_buffer.contains('\n')) {
          final idx = _buffer.indexOf('\n');
          final line = _buffer.substring(0, idx).trim();
          _buffer = _buffer.substring(idx + 1);
          if (line.isNotEmpty) _dataController.add(line);
        }
      });
    }
  }

  void setHighPriority(bool high) {} // no-op for BLE

  Future<void> send(String msg) async {
    if (_rxChar == null || !_connected) return;
    // withoutResponse:true раньше — если пакет терялся (например при слабом
    // сигнале), UI всё равно показывал переключённое состояние, хотя прошивка
    // команду не получала (именно так тумблер WT901 "выключался" только в
    // приложении, а на роторе оставался включён). Команды тут все разовые
    // (не непрерывный поток), так что ждать подтверждение не в тягость.
    // await обязателен: send() раньше не ждал завершения записи, и несколько
    // send() подряд без паузы (SSID/PASS/URL/UPDATE у кнопки Update) могли
    // оборвать более длинную запись (URL с токеном, >100 символов) следующей -
    // именно так терялась часть токена ("...ota.php?t;" вместо "...?t=<токен>;").
    try {
      await _rxChar!.write(Uint8List.fromList('$msg\n'.codeUnits), withoutResponse: false);
    } catch (_) {}
  }

  // Прошивка коробки старше этой сборки такой характеристики не отдаёт —
  // по её отсутствию и понимаем, что обновляться по BLE ещё нечем.
  bool get canUpdateOverBle => _otaChar != null && _connected;

  // Размер куска берём от согласованного MTU: три служебных байта уходит на
  // заголовок ATT. Android соглашается на запрошенные 247, iOS решает сам и
  // обычно даёт 185 - на iPhone кусок просто получится меньше.
  int get otaChunkSize {
    final mtu = _device?.mtuNow ?? 23;
    final n = mtu - 3;
    return n < 20 ? 20 : (n > 244 ? 244 : n);
  }

  Future<void> sendOtaChunk(List<int> data) async {
    final ch = _otaChar;
    if (ch == null || !_connected) throw Exception('OTA channel not available');
    await ch.write(data, withoutResponse: true);
  }

  Future<void> disconnect() async {
    _notifySub?.cancel();
    _connSub?.cancel();
    try { await _device?.disconnect(); } catch (_) {}
    _device = null;
    _rxChar = null;
    _txChar = null;
    _otaChar = null;
    _connected = false;
    _buffer = '';
  }
}

// ─── App State ───────────────────────────────────────────────────────────────
class AppState extends ChangeNotifier {
  double motorDeg = 0;
  double reduction = 0;
  int maxSpeedRpm = 0;
  int minSpeedRpm = 0;
  int searchAngle = 0;
  String mode = '';
  bool hold = false;
  bool gyroReverse = false;
  bool gyro6axis = false;
  int filterPercent = 0;
  bool keepSearchPos = false;
  bool reverseWire = false;
  bool reverseWifi = false;
  String pedalMac = '';
  int searchMsec = 0;
  List<String> chFunctions = ['OFF', 'OFF', 'OFF', 'OFF'];
  static const chOptions = ['OFF', 'LEFT', 'RIGHT', 'SEARCH', 'GYRO', 'HOLD'];
  int liftUp = 0;
  int liftDown = 0;
  bool liftAxisRoll = true;
  int activeChannel = -1;
  String ssid = '';
  String pass = '';
  String url = '';
  // Прогресс OTA (строки вида "OTA: ...", которые ротатор шлёт через
  // bleSendLine во время обновления) - раньше просто терялись в parseData()
  // (нет "=", ни один case не совпадает), и в приложении вообще не было
  // видно, идёт ли прошивка и чем она закончилась - как и в вебе до этого.
  String otaMsg = '';
  // Контрольная сумма прошивки, которая сейчас работает в коробке
  // (ESP.getSketchMD5 на её стороне). По ней страница обновления понимает,
  // отличается ли образ на сервере от уже установленного.
  String fwMd5 = '';

  // WT901 настройки (хранятся на ротаторе)
  bool wt901Enabled = false;
  double wt901DeadZone = 15.0;
  int wt901Speed = 30;
  String wt901Mac = '';
  bool wt901Speed2Enabled = false;
  double wt901Speed2Angle = 45.0;
  int wt901Speed2 = 60;
  int wt901Axis = 1; // 0=Roll, 1=Pitch, 2=Yaw
  bool wt901RollReverse = false;
  bool wt901PitchReverse = false;
  bool wt901YawReverse = false;
  // Центр (ноль) оси, который хранит сама прошивка - её же кнопка ZERO его и
  // задаёт. Нужен приложению только чтобы правильно показать, попал ли
  // текущий наклон телефона в мёртвую зону.
  double wt901PitchZero = 0;
  // Источник наклона на коробке: телефон или физический датчик. Коробка его
  // не сохраняет (живёт только пока телефон подключён), но присылает в
  // статусе - чтобы переключатель в приложении показывал реальное положение
  // дел, а не то, что мы думаем.
  bool wt901SrcPhone = false;
  // Гасить ли встроенный гироскоп на время слежения за Yaw. Живёт в прошивке
  // (и во флеше коробки), поэтому работает и без приложения - с веб-страницы.
  bool yawAutoGyro = false;
  // Алгоритм самого датчика по ЕГО ответу: -1 не отвечал, 0 = 9 осей, 1 = 6 осей.
  int wt901SensorAxis = -1;

  void reset() {
    motorDeg = 0; reduction = 0; maxSpeedRpm = 0; minSpeedRpm = 0;
    searchAngle = 15; mode = ''; hold = false;
    gyroReverse = false; gyro6axis = false; filterPercent = 0;
    keepSearchPos = false; reverseWire = false; reverseWifi = false; searchMsec = 0;
    chFunctions = ['OFF', 'OFF', 'OFF', 'OFF'];
    liftUp = 0; liftDown = 0; liftAxisRoll = true;
    activeChannel = -1; ssid = ''; pass = ''; url = '';
    wt901Enabled = false; wt901DeadZone = 15.0; wt901Speed = 30; wt901Mac = '';
    wt901Speed2Enabled = false; wt901Speed2Angle = 45.0; wt901Speed2 = 60;
    wt901Axis = 1; wt901RollReverse = false; wt901PitchReverse = false; wt901YawReverse = false;
    notifyListeners();
  }

  // Ротатор присылает номер функции канала как есть - он приходит из его
  // флеша (prefs) и нигде на той стороне не ограничивается диапазоном.
  // Раньше тут было chOptions[int.parse(v)] с проверкой только на то, что
  // строка вообще парсится в число: любое значение вне 0..5 (одна испорченная
  // запись в NVS, прошивка другой версии) роняло RangeError прямо внутри
  // обработчика BLE-потока, а вместе с ним и обновление всех остальных
  // данных в приложении. Молча игнорируем некорректный номер.
  void _setChFunction(int idx, String v) {
    final i = int.tryParse(v);
    if (i == null || i < 0 || i >= chOptions.length) return;
    chFunctions[idx] = chOptions[i];
  }

  void parseData(String data) {
    final parts = data.split(';');
    for (final part in parts) {
      // Режем по ПЕРВОМУ '=', а не по всем. split('=') разваливал значение на
      // куски и брал только первый: ссылка вида
      // ".../ota.php?t=<токен>" превращалась в ".../ota.php?t" - токен
      // отрезало вторым знаком равенства. Приложение показывало обрезанный
      // адрес, а нажатие Update отправляло его обратно в коробку поверх
      // правильного - сервер отвечал 404. То же ждало любой пароль с '='.
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final k = part.substring(0, eq).trim();
      final v = part.substring(eq + 1).trim();
      switch (k) {
        case 'MOTOR': motorDeg = double.tryParse(v) ?? motorDeg;
        case 'REDUCTION': reduction = double.tryParse(v) ?? reduction;
        case 'MAX_SPEED': maxSpeedRpm = int.tryParse(v) ?? maxSpeedRpm;
        case 'MIN_SPEED': minSpeedRpm = int.tryParse(v) ?? minSpeedRpm;
        case 'ANGLE': searchAngle = int.tryParse(v) ?? searchAngle;
        case 'MODE': mode = v;
        case 'HOLD': hold = v == '1';
        case 'GYRO_REV': gyroReverse = v == '1';
        case 'GYRO_6': gyro6axis = v == '1';
        case 'FILTER': filterPercent = int.tryParse(v) ?? filterPercent;
        case 'SAVE_POS': keepSearchPos = v == '1';
        case 'PEDAL_WIRE_REV': reverseWire = v == '1';
        case 'PEDAL_WIFI_REV': reverseWifi = v == '1';
        case 'PEDAL_MAC': pedalMac = v;
        case 'SEARCH_MSEC': searchMsec = int.tryParse(v) ?? searchMsec;
        case 'CH_1': _setChFunction(0, v);
        case 'CH_2': _setChFunction(1, v);
        case 'CH_3': _setChFunction(2, v);
        case 'CH_4': _setChFunction(3, v);
        case 'LIFT_FUNC': gyro6axis = v == '1';
        case 'LIFT_AXIS': liftAxisRoll = v == '1';
        case 'LIFT_UP': liftUp = int.tryParse(v) ?? liftUp;
        case 'LIFT_DOWN': liftDown = int.tryParse(v) ?? liftDown;
        case 'CH_1_ON': activeChannel = 0; Future.delayed(const Duration(milliseconds: 500), () { activeChannel = -1; notifyListeners(); });
        case 'CH_2_ON': activeChannel = 1; Future.delayed(const Duration(milliseconds: 500), () { activeChannel = -1; notifyListeners(); });
        case 'CH_3_ON': activeChannel = 2; Future.delayed(const Duration(milliseconds: 500), () { activeChannel = -1; notifyListeners(); });
        case 'CH_4_ON': activeChannel = 3; Future.delayed(const Duration(milliseconds: 500), () { activeChannel = -1; notifyListeners(); });
        case 'SSID': ssid = v;
        case 'PASS': pass = v;
        case 'URL': url = v;
        case 'FW_MD5': fwMd5 = v;
        case 'WT901_ENABLED': wt901Enabled = v == '1';
        case 'WT901_DEAD': wt901DeadZone = double.tryParse(v) ?? wt901DeadZone;
        case 'WT901_SPEED': wt901Speed = int.tryParse(v) ?? wt901Speed;
        case 'WT901_MAC': wt901Mac = v;
        case 'WT901_SPEED2_EN': wt901Speed2Enabled = v == '1';
        case 'WT901_SPEED2_ANGLE': wt901Speed2Angle = double.tryParse(v) ?? wt901Speed2Angle;
        case 'WT901_SPEED2': wt901Speed2 = int.tryParse(v) ?? wt901Speed2;
        case 'WT901_AXIS': wt901Axis = int.tryParse(v) ?? wt901Axis;
        case 'WT901_ROLL_REV': wt901RollReverse = v == '1';
        case 'WT901_PITCH_REV': wt901PitchReverse = v == '1';
        case 'WT901_YAW_REV': wt901YawReverse = v == '1';
        case 'WT901_PITCH_ZERO': wt901PitchZero = double.tryParse(v) ?? wt901PitchZero;
        case 'WT901_SRC': wt901SrcPhone = v == '1';
        case 'YAW_AUTO_GYRO': yawAutoGyro = v == '1';
        case 'WT901_SENSOR_AXIS': wt901SensorAxis = int.tryParse(v) ?? wt901SensorAxis;
      }
    }
    notifyListeners();
  }
}

// ─── Main Screen ─────────────────────────────────────────────────────────────
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _bt = BtManager();

  final _state = AppState();
  int _pageIndex = 0;
  StreamSubscription? _sub;


  @override
  void initState() {
    super.initState();
    _sub = _bt.dataStream.listen((data) {
      if (data == '__DISCONNECTED__') {
        if (!mounted) return;
        setState(() => _state.reset());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connect lost'), duration: Duration(seconds: 2), backgroundColor: Colors.red),
        );
        return;
      }
      setState(() {
        final trimmed = data.trim();
        if (trimmed == 'CH_1_ON') { _state.activeChannel = 0; Future.delayed(const Duration(milliseconds: 500), () { if (mounted) setState(() => _state.activeChannel = -1); }); return; }
        if (trimmed == 'CH_2_ON') { _state.activeChannel = 1; Future.delayed(const Duration(milliseconds: 500), () { if (mounted) setState(() => _state.activeChannel = -1); }); return; }
        if (trimmed == 'CH_3_ON') { _state.activeChannel = 2; Future.delayed(const Duration(milliseconds: 500), () { if (mounted) setState(() => _state.activeChannel = -1); }); return; }
        if (trimmed == 'CH_4_ON') { _state.activeChannel = 3; Future.delayed(const Duration(milliseconds: 500), () { if (mounted) setState(() => _state.activeChannel = -1); }); return; }
        if (trimmed.startsWith('OTA:')) { _state.otaMsg = trimmed; return; }
        // Ответами на передачу прошивки занимается страница обновления, у неё
        // своя подписка. Сюда они попадать не должны: подтверждение приходит
        // каждые пару килобайт, и перерисовывать из-за них весь экран сотни
        // раз подряд ни к чему.
        if (trimmed.startsWith('BOTA_')) return;
        _state.parseData(data);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _connect() async {
    await [Permission.bluetoothConnect, Permission.bluetoothScan, Permission.location].request();
    if (!mounted) return;
    final selected = await showDialog<BluetoothDevice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ScanDialog(filterName: 'GYRO360'),
    );
    if (selected == null || !mounted) return;
    // Android: connect() сразу после stopScan() часто валится с status=133
    // (радио ещё занято/не освободилось — в т.ч. из-за периодического скана
    // маяка на самом роторе). Делаем несколько попыток с нарастающей паузой.
    await FlutterBluePlus.stopScan();
    Object? lastError;
    for (int attempt = 1; attempt <= 4; attempt++) {
      await Future.delayed(Duration(milliseconds: 400 * attempt));
      if (!mounted) return;
      try {
        await _bt.connect(selected);
        await Future.delayed(const Duration(milliseconds: 500));
        _bt.send('READ_ALL');
        setState(() {});
        // Повторный запрос: изредка первый READ_ALL проскакивает раньше, чем
        // BLE-подписка на уведомления полностью готова на стороне ротатора,
        // и часть полей (например WT901 Enable/2nd speed) не долетает —
        // из-за этого страница WT901 выглядела так, будто нужен ручной Refresh.
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (_bt.isConnected) _bt.send('READ_ALL');
        });
        return;
      } catch (e) {
        lastError = e;
        await _bt.disconnect();
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Connection failed: $lastError')));
  }

  void _disconnect() async {
    await _bt.disconnect();
    // Возвращаемся на Home: остальные страницы без подключения закрыты, и
    // остаться на закрытой было бы тупиком - уйти с неё уже нечем.
    setState(() => _pageIndex = 0);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _MainPage(state: _state, bt: _bt),
      _MotorPage(state: _state, bt: _bt),
      _GyroPage(state: _state, bt: _bt),
      _PedalPage(state: _state, bt: _bt),
      _RFPage(state: _state, bt: _bt),
      _RemotePage(state: _state, bt: _bt),
      _FirmwarePage(state: _state, bt: _bt),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF969696),
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              isConnected: _bt.isConnected,
              onConnect: _connect,
              onDisconnect: _disconnect,
              onRefresh: () { if (_bt.isConnected) _bt.send('READ_ALL'); },
              pageIndex: _pageIndex,
              onPageChanged: (i) => setState(() => _pageIndex = i),
            ),
            Expanded(child: IndexedStack(index: _pageIndex, children: pages)),
          ],
        ),
      ),
    );
  }
}

// ─── Scan Dialog (BLE devices) ────────────────────────────────────────────
class _ScanDialog extends StatefulWidget {
  final String filterName;
  const _ScanDialog({required this.filterName});
  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  final Map<String, ScanResult> _results = {};
  bool _scanning = true;
  StreamSubscription<List<ScanResult>>? _sub;

  @override
  void initState() { super.initState(); _startScan(); }

  void _startScan() {
    setState(() { _scanning = true; _results.clear(); });
    _sub?.cancel();
    FlutterBluePlus.stopScan();
    _sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName == widget.filterName) {
          setState(() => _results[r.device.remoteId.str] = r);
        }
      }
    });
    FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) setState(() => _scanning = scanning);
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
  }

  @override
  void dispose() {
    _sub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  int _rssiBars(int? rssi) {
    if (rssi == null) return 1;
    if (rssi >= -60) return 5;
    if (rssi >= -70) return 4;
    if (rssi >= -80) return 3;
    if (rssi >= -90) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final list = _results.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return AlertDialog(
      title: Row(children: [
        Text('${widget.filterName} nearby'),
        const Spacer(),
        if (_scanning)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _startScan, padding: EdgeInsets.zero),
      ]),
      content: SizedBox(
        width: double.maxFinite, height: 320,
        child: list.isEmpty
            ? Center(child: Text(_scanning ? 'Scanning...' : 'No devices found'))
            : ListView.builder(
          itemCount: list.length,
          itemBuilder: (ctx, i) {
            final r = list[i];
            return ListTile(
              leading: const Icon(Icons.bluetooth, color: Color(0xFF546E7A)),
              title: Text(r.device.platformName.isNotEmpty ? r.device.platformName : r.device.remoteId.str, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(r.device.remoteId.str, style: const TextStyle(fontSize: 12)),
              trailing: _SignalBars(_rssiBars(r.rssi)),
              onTap: () { FlutterBluePlus.stopScan(); Navigator.pop(ctx, r.device); },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () { _sub?.cancel(); FlutterBluePlus.stopScan(); Navigator.pop(context); },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}


class _TopBar extends StatelessWidget {
  final bool isConnected;
  final VoidCallback onConnect, onDisconnect, onRefresh;
  final int pageIndex;
  final ValueChanged<int> onPageChanged;

  const _TopBar({
    required this.isConnected, required this.onConnect,
    required this.onDisconnect, required this.onRefresh,
    required this.pageIndex, required this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF546E7A),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        children: [
          Row(children: [
            const Icon(Icons.bluetooth, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: isConnected ? null : onConnect,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF546E7A), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), minimumSize: Size.zero),
              child: const Text('Connect'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: isConnected ? onDisconnect : null,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF546E7A), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), minimumSize: Size.zero),
              child: const Text('Disconnect'),
            ),
            const SizedBox(width: 8),
            Text(isConnected ? 'Connected!' : 'Disconnected',
                style: TextStyle(color: isConnected ? Colors.greenAccent : Colors.white70, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavBtn(icon: Icons.home,                    index: 0, current: pageIndex, onTap: onPageChanged),
              _NavBtn(icon: Icons.settings_input_component, index: 1, current: pageIndex, onTap: onPageChanged, enabled: isConnected),
              _NavBtn(icon: Icons.explore,                 index: 2, current: pageIndex, onTap: onPageChanged, enabled: isConnected),
              _NavBtn(icon: Icons.directions_walk,         index: 3, current: pageIndex, onTap: onPageChanged, enabled: isConnected),
              _NavBtn(icon: Icons.radio,                   index: 4, current: pageIndex, onTap: onPageChanged, enabled: isConnected),
              _NavBtn(icon: Icons.sensors,                 index: 5, current: pageIndex, onTap: onPageChanged, enabled: isConnected),
              _NavBtn(icon: Icons.system_update,           index: 6, current: pageIndex, onTap: onPageChanged, enabled: isConnected),
            ],
          ),
          const SizedBox(height: 4),
          Row(children: [
            Text(isConnected ? 'Completed' : '', style: const TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton(
              onPressed: onRefresh,
              style: TextButton.styleFrom(backgroundColor: Colors.white24, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), minimumSize: Size.zero),
              child: const Text('Refresh'),
            ),
          ]),
        ],
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final int index, current;
  final ValueChanged<int> onTap;
  // Пока ротатор не подключён, все страницы кроме Home закрыты: на них нет ни
  // одного показания, а любой переключатель отправил бы команду в пустоту и
  // остался бы в положении, которого на роторе нет. Раньше их можно было
  // открыть и накрутить настройки, которые никуда не уходили.
  final bool enabled;
  const _NavBtn({required this.icon, required this.index, required this.current,
                 required this.onTap, this.enabled = true});
  @override
  Widget build(BuildContext context) {
    final active = index == current;
    return GestureDetector(
      onTap: enabled ? () => onTap(index) : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.35,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: active ? Colors.white : Colors.white24, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: active ? const Color(0xFF546E7A) : Colors.white, size: 22),
        ),
      ),
    );
  }
}

// ─── Page helpers ─────────────────────────────────────────────────────────────
Widget _pageTitle(String title) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
);

// Единый вид ВСЕХ переключателей: подпись слева, сам переключатель прижат к
// правому краю и одного размера везде. Раньше часть шла через _row(), где
// контрол занимал колонку по центру строки и выглядел крупнее - на одном
// экране соседствовали два разных вида.
Widget _switchRow(String label, bool value, void Function(bool)? onChanged,
                  {double hPad = 16}) =>
    Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: SizedBox(
        height: 34,
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Transform.scale(
            scale: 0.75,
            child: Switch(value: value, onChanged: onChanged),
          ),
        ]),
      ),
    );

Widget _row(String label, Widget control) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  child: Row(children: [
    Expanded(flex: 2, child: Text(label, style: const TextStyle(fontSize: 16))),
    Expanded(flex: 3, child: control),
  ]),
);

// ─── Arrow Button ─────────────────────────────────────────────────────────────
class _ArrowBtn extends StatefulWidget {
  final String label;
  final VoidCallback onPress;
  final VoidCallback onRelease;
  const _ArrowBtn({required this.label, required this.onPress, required this.onRelease});
  @override
  State<_ArrowBtn> createState() => _ArrowBtnState();
}

class _ArrowBtnState extends State<_ArrowBtn> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) {
        if (_pressed) return;
        _pressed = true; setState(() {});
        widget.onPress();
      },
      onTapUp: (_) {
        if (!_pressed) return;
        _pressed = false; setState(() {});
        widget.onRelease();
      },
      onTapCancel: () {
        if (!_pressed) return;
        _pressed = false; setState(() {});
        widget.onRelease();
      },
      child: Container(
        width: 110, height: 60, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _pressed ? Colors.blue : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _pressed ? Colors.blue.shade700 : Colors.grey.shade400),
        ),
        child: Text(widget.label, style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: _pressed ? Colors.white : Colors.black)),
      ),
    );
  }
}

// ─── Main Page ────────────────────────────────────────────────────────────────
class _MainPage extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _MainPage({required this.state, required this.bt});
  @override State<_MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<_MainPage> {
  late double _angle;

  @override
  void initState() {
    super.initState();
    _angle = widget.state.searchAngle.toDouble().clamp(15.0, 360.0);
    widget.state.addListener(_onStateChange);
  }

  void _onStateChange() { setState(() { _angle = widget.state.searchAngle.toDouble().clamp(15.0, 360.0); }); }

  @override
  void dispose() { widget.state.removeListener(_onStateChange); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    _angle = _angle.clamp(15.0, 360.0);
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Main page'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.info_outline),
            label: const Text('Instruction'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: () => showDialog(context: context, builder: (ctx) => AlertDialog(
              title: const Text('GYRO360 Manual'),
              content: DefaultTabController(length: 3, child: SizedBox(width: double.maxFinite, height: 400, child: Column(children: [
                const TabBar(labelColor: Color(0xFF546E7A), unselectedLabelColor: Colors.grey, tabs: [Tab(text: 'EN'), Tab(text: 'RU'), Tab(text: 'LV')]),
                const SizedBox(height: 8),
                Expanded(child: TabBarView(children: [
                  SingleChildScrollView(child: const Text("SEARCH - toggle search mode. Hold 3s: set angle.\n\nHOLD - lock motor position.\n  3s: start WiFi web.\n  6s: pedal pairing.\n  1s (in web/pairing): stop.\n\nGYRO - toggle gyro mode (short press).\n  Hold 3-6s: blink preview, release in this window to toggle auto-switch.\n  Hold 6-9s: blink preview, release in this window to toggle WT901 beacon.\n  Hold past 9s: LED solid on - releasing now changes nothing.\n  At power-on 3s: gyro calibration.\n\nLEFT/RIGHT - rotate motor. Both: search mode.\n\nLEDs:\nSEARCH: on=search, breathing=angle setup\nHOLD: on=hold, slow breath=web, medium=pairing\nGYRO: on=gyro mode, 1 pulse=currently ON (auto-switch at 3-6s, WT901 at 6-9s), 2 pulses=currently OFF, solid after 9s=nothing will change\nPOWER: on=BLE connected, blink=disconnected", style: TextStyle(fontSize: 14, height: 1.5))),
                  SingleChildScrollView(child: const Text("SEARCH - rezim poiska. Uderzhanie 3s: nastrojka ugla.\n\nHOLD - uderzhanie pozicii motora.\n  3s: zapusk veb-interfeisa.\n  6s: sopryazhenie pedali.\n  1s (v veb/sopryazhenii): vyhod.\n\nGYRO - rezim giroskopa (korotkoe nazhatie).\n  Uderzhanie 3-6s: migaet-podskazka, otpusti v etom okne - pereklyuchit avtopodjom.\n  Uderzhanie 6-9s: migaet-podskazka, otpusti v etom okne - pereklyuchit majak WT901.\n  Uderzhanie posle 9s: svetodiod gorit rovno - otpuskanie uzhe nichego ne menyaet.\n  Pri vklyuchenii 3s: kalibrovka giroskopa.\n\nLEVO/PRAVO - vrashchenie motora. Obe: rezhim poiska.\n\nIndikaciya:\nSEARCH: gorit=poisk, dyshit=nastrojka ugla\nHOLD: gorit=uderzhanie, medl.=veb, sred.=sopryazhenie\nGYRO: gorit=rezim giroskopa, 1 impuls=seichas VKLYUCHENO (avtopodjom na 3-6s, WT901 na 6-9s), 2 impulsa=seichas VYKLYUCHENO, rovno posle 9s=nichego ne izmenitsya\nPOWER: gorit=BLE podklyuchen, migaet=net svyazi", style: TextStyle(fontSize: 14, height: 1.5))),
                  SingleChildScrollView(child: const Text("SEARCH - meklesanas rezims. Turet 3s: lenkja iestatishana.\n\nHOLD - motora pozicijas fiksacija.\n  3s: timekla saskarne.\n  6s: pedala parvienoshana.\n  1s (timekli/parvienoshana): iziet.\n\nGYRO - ziroskopa rezims (isa piespiede).\n  Turet 3-6s: mirgo-nordit, atlaid shaja loga - parslegs auto-pacelshanu.\n  Turet 6-9s: mirgo-nordit, atlaid shaja loga - parslegs WT901 majaku.\n  Turet pec 9s: LED deg nepartraukti - atlaishana vairs neko nemaina.\n  Iesledzot 3s: ziroskopa kalibreshana.\n\nPA KREISI/PA LABI - motora rotacija. Abi: mekleshana.\n\nIndikacija:\nSEARCH: deg=mekleshana, elpo=lenkja iestatishana\nHOLD: deg=fiksacija, leni=timeklis, videji=parvienoshana\nGYRO: deg=ziroskopa rezims, 1 impulss=pasreiz IESLEGTS (auto-pacelshana 3-6s, WT901 6-9s), 2 impulsi=pasreiz IZSLEGTS, deg nepartraukti pec 9s=nekas nemainisies\nPOWER: deg=BLE savienots, mirgo=nav savienojuma", style: TextStyle(fontSize: 14, height: 1.5))),
                ])),
              ]))),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
            )),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          Text('${_angle.toInt()}°', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          Slider(value: _angle, min: 15, max: 360, divisions: 69, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
              onChanged: (v) => setState(() => _angle = v),
              onChangeEnd: (v) { s.searchAngle = v.toInt(); bt.send('ANGLE=${v.toInt()};'); }),
          const Text('Search angle'),
        ]),
      ),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _modeBtn('Search', s.mode == 'SEARCH', Colors.blue.shade200, () => bt.send(s.mode == 'SEARCH' ? 'OFF' : 'SEARCH')),
      ]),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _ArrowBtn(label: '◄', onPress: () => bt.send('LEFT'), onRelease: () => bt.send('STOP')),
        const SizedBox(width: 8),
        _modeBtn('Gyro', s.mode == 'GYRO', Colors.green, () => bt.send(s.mode == 'GYRO' ? 'OFF' : 'GYRO')),
        const SizedBox(width: 8),
        _ArrowBtn(label: '►', onPress: () => bt.send('RIGHT'), onRelease: () => bt.send('STOP')),
      ]),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _modeBtn('Hold', s.hold, Colors.orange, () => bt.send(s.hold ? 'HOLD=0;' : 'HOLD=1;')),
      ]),
      const SizedBox(height: 16),
    ]));
  }

  Widget _modeBtn(String label, bool active, Color color, VoidCallback onTap) {
    return SizedBox(width: 110, height: 60, child: ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
          backgroundColor: active ? color : Colors.grey.shade300, foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), elevation: active ? 4 : 1),
      child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
    ));
  }
}

// ─── Motor Page ───────────────────────────────────────────────────────────────
class _MotorPage extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _MotorPage({required this.state, required this.bt});
  @override State<_MotorPage> createState() => _MotorPageState();
}

class _MotorPageState extends State<_MotorPage> {
  static const _stepAngles = [0.9, 1.8, 3.6, 7.5, 15.0];

  late double _motorDeg;
  late double _reductVal;
  late double _maxSpeedVal;
  late double _minSpeedVal;

  double _nearestStep(double v) {
    if (_stepAngles.contains(v)) return v;
    return _stepAngles.reduce((a, b) => (v - a).abs() <= (v - b).abs() ? a : b);
  }

  @override
  void initState() {
    super.initState();
    _motorDeg    = _nearestStep(widget.state.motorDeg == 0 ? 1.8 : widget.state.motorDeg);
    _reductVal   = widget.state.reduction.clamp(1.0, 10.0);
    _maxSpeedVal = widget.state.maxSpeedRpm.toDouble().clamp(1.0, 25.0);
    _minSpeedVal = widget.state.minSpeedRpm.toDouble().clamp(1.0, 25.0);
    widget.state.addListener(_onStateChange);
  }

  void _onStateChange() {
    setState(() {
      final s = widget.state;
      if (s.motorDeg != 0)    _motorDeg    = _nearestStep(s.motorDeg);
      if (s.reduction != 0)   _reductVal   = s.reduction.clamp(1.0, 10.0);
      if (s.maxSpeedRpm != 0) _maxSpeedVal = s.maxSpeedRpm.toDouble().clamp(1.0, 25.0);
      if (s.minSpeedRpm != 0) _minSpeedVal = s.minSpeedRpm.toDouble().clamp(1.0, 25.0);
    });
  }

  @override
  void dispose() { widget.state.removeListener(_onStateChange); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Motor page'),
      _row('Motor step (°):', Container(
        decoration: BoxDecoration(color: Colors.yellow, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.grey.shade400)),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: DropdownButtonHideUnderline(child: DropdownButton<double>(
          value: _motorDeg, dropdownColor: Colors.yellow, isExpanded: true,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black),
          items: _stepAngles.map((a) => DropdownMenuItem(value: a, child: Text('${a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2)}°'))).toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() => _motorDeg = v);
            s.motorDeg = v;
            bt.send('MOTOR=$v;');
          },
        )),
      )),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Reduction:', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text(_reductVal.toStringAsFixed(1), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _reductVal, min: 1, max: 10, divisions: 90, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _reductVal = v),
          onChangeEnd: (v) { s.reduction = v; bt.send('REDUCTION=${v.toStringAsFixed(1)};'); }),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Max speed (rpm):', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('${_maxSpeedVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _maxSpeedVal, min: 1, max: 25, divisions: 24, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _maxSpeedVal = v),
          onChangeEnd: (v) { s.maxSpeedRpm = v.round(); bt.send('MAX_SPEED=${v.round()};'); }),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Min speed (rpm):', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('${_minSpeedVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _minSpeedVal, min: 1, max: 25, divisions: 24, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _minSpeedVal = v),
          onChangeEnd: (v) { s.minSpeedRpm = v.round(); bt.send('MIN_SPEED=${v.round()};'); }),
      ])),
      const SizedBox(height: 16),
      Center(child: ElevatedButton(
        onPressed: () {
          setState(() { _motorDeg = 1.8; _reductVal = 3.0; _maxSpeedVal = 25; _minSpeedVal = 10; });
          s.motorDeg = 1.8; s.reduction = 3.0; s.maxSpeedRpm = 25; s.minSpeedRpm = 10;
          bt.send('MOTOR=1.8;'); bt.send('REDUCTION=3.0;');
          bt.send('MAX_SPEED=25;'); bt.send('MIN_SPEED=10;');
        },
        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black),
        child: const Text('Default settings'),
      )),
    ]));
  }
}

// ─── Lift Threshold ───────────────────────────────────────────────────────────
class _LiftThresholdRow extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _LiftThresholdRow({required this.state, required this.bt});
  @override State<_LiftThresholdRow> createState() => _LiftThresholdRowState();
}

class _LiftThresholdRowState extends State<_LiftThresholdRow> {
  late double _upVal, _downVal;

  @override
  void initState() {
    super.initState();
    _upVal   = widget.state.liftUp.toDouble().clamp(0.0, 90.0);
    _downVal = widget.state.liftDown.toDouble().clamp(0.0, 90.0);
    widget.state.addListener(_onStateChange);
  }

  void _onStateChange() {
    setState(() {
      _upVal   = widget.state.liftUp.toDouble().clamp(0.0, 90.0);
      _downVal = widget.state.liftDown.toDouble().clamp(0.0, 90.0);
    });
  }

  @override
  void dispose() { widget.state.removeListener(_onStateChange); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    return Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Lift up (°):', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('${_upVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _upVal, min: 0, max: 90, divisions: 90, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _upVal = v),
          onChangeEnd: (v) { s.liftUp = v.round(); bt.send('LIFT_UP=${v.round()};'); }),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Lift down (°):', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('${_downVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _downVal, min: 0, max: 90, divisions: 90, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _downVal = v),
          onChangeEnd: (v) { s.liftDown = v.round(); bt.send('LIFT_DOWN=${v.round()};'); }),
      ])),
    ]);
  }
}

// ─── Gyro Page ────────────────────────────────────────────────────────────────
class _GyroPage extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _GyroPage({required this.state, required this.bt});
  @override State<_GyroPage> createState() => _GyroPageState();
}

class _GyroPageState extends State<_GyroPage> {
  late double _filterVal;

  @override
  void initState() {
    super.initState();
    _filterVal = widget.state.filterPercent.toDouble().clamp(0.0, 100.0);
    widget.state.addListener(_onStateChange);
  }

  void _onStateChange() { setState(() { _filterVal = widget.state.filterPercent.toDouble().clamp(0.0, 100.0); }); }

  @override
  void dispose() { widget.state.removeListener(_onStateChange); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Gyro page'),
      _switchRow('Reverse gyro:', s.gyroReverse, (v) { setState(() => s.gyroReverse = v); bt.send('GYRO_REV=${v ? 1 : 0};'); }),
      _LiftThresholdRow(state: s, bt: bt),
      _row('Lift axis:', Container(
        decoration: BoxDecoration(color: Colors.yellow, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.grey.shade400)),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: DropdownButtonHideUnderline(child: DropdownButton<bool>(
          value: s.liftAxisRoll, dropdownColor: Colors.yellow,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black),
          items: const [DropdownMenuItem(value: true, child: Text('Roll')), DropdownMenuItem(value: false, child: Text('Pitch'))],
          onChanged: (v) { if (v == null) return; setState(() => s.liftAxisRoll = v); bt.send('LIFT_AXIS=${v ? 1 : 0};'); },
        )),
      )),
      _switchRow('Auto switch:', s.gyro6axis, (v) { setState(() => s.gyro6axis = v); bt.send('LIFT_FUNC=${v ? 1 : 0};'); }),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(children: [
        const Expanded(flex: 2, child: Text('Gyro calib:', style: TextStyle(fontSize: 16))),
        ElevatedButton(onPressed: () => showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text('Gyro calibration'), content: const Text("1. Power OFF\n2. Hold GYRO button\n3. Power ON\n4. Release after 1 flash (3s)\n5. Saves and restarts"), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))])), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black), child: const Text('Instruction')),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Filter (%):', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('${_filterVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _filterVal, min: 0, max: 100, divisions: 100, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _filterVal = v),
          onChangeEnd: (v) { s.filterPercent = v.round(); bt.send('FILTER=${v.round()};'); }),
      ])),
    ]));
  }
}

// ─── Pedal Page ───────────────────────────────────────────────────────────────
class _PedalPage extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _PedalPage({required this.state, required this.bt});
  @override State<_PedalPage> createState() => _PedalPageState();
}

class _PedalPageState extends State<_PedalPage> {
  late double _msecVal;
  @override
  void initState() {
    super.initState();
    _msecVal = widget.state.searchMsec.toDouble().clamp(0.0, 5000.0);
    widget.state.addListener(_onStateChange);
  }

  void _onStateChange() { setState(() { _msecVal = widget.state.searchMsec.toDouble().clamp(0.0, 5000.0); }); }

  @override
  void dispose() { widget.state.removeListener(_onStateChange); super.dispose(); }

  Future<void> _confirmUnpairPedal() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair wireless pedal?'),
        content: const Text('The rotator will forget the paired pedal. No wireless pedal will work until you pair one again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Agree')),
        ],
      ),
    );
    if (confirmed == true) widget.bt.send('PEDAL_UNPAIR=1;');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Pedal page'),
      _switchRow('Keep search pos:', s.keepSearchPos, (v) { setState(() => s.keepSearchPos = v); bt.send('SAVE_POS=${v ? 1 : 0};'); }),
      _switchRow('Reverse Wire Pedal:', s.reverseWire, (v) { setState(() => s.reverseWire = v); bt.send('PEDAL_WIRE_REV=${v ? 1 : 0};'); }),
      _switchRow('Reverse WiFi Pedal:', s.reverseWifi, (v) { setState(() => s.reverseWifi = v); bt.send('PEDAL_WIFI_REV=${v ? 1 : 0};'); }),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
        Row(children: [
          const Text('Search ON msec:', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text('${_msecVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        Slider(value: _msecVal, min: 0, max: 5000, divisions: 100, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
          onChanged: (v) => setState(() => _msecVal = v),
          onChangeEnd: (v) { s.searchMsec = v.round(); bt.send('SEARCH_MSEC=${v.round()};'); }),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(children: [
        const Expanded(flex: 2, child: Text('Pair pedal:', style: TextStyle(fontSize: 16))),
        ElevatedButton(onPressed: () => bt.send('PAIR=1;'), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black), child: const Text('Start')),
        const SizedBox(width: 8),
        ElevatedButton(onPressed: () => bt.send('PAIR=0;'), style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black), child: const Text('Stop')),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
        Expanded(child: Text(
          s.pedalMac.isNotEmpty ? 'Paired: ${s.pedalMac}' : 'No wireless pedal paired - pedal will not work until paired',
          style: TextStyle(
            fontSize: 13,
            fontWeight: s.pedalMac.isNotEmpty ? FontWeight.bold : FontWeight.normal,
            color: s.pedalMac.isNotEmpty ? Colors.green.shade800 : Colors.grey.shade600,
          ),
        )),
        if (s.pedalMac.isNotEmpty)
          TextButton(onPressed: _confirmUnpairPedal, child: const Text('Unpair', style: TextStyle(color: Colors.red))),
      ])),
    ]));
  }
}

// ─── RF Page ──────────────────────────────────────────────────────────────────
class _RFPage extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _RFPage({required this.state, required this.bt});
  @override State<_RFPage> createState() => _RFPageState();
}

class _RFPageState extends State<_RFPage> {
  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    const opts = AppState.chOptions;
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('RF page'),
      for (int i = 0; i < 4; i++)
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(children: [
          Expanded(flex: 2, child: Text('Channel ${i + 1}:', style: const TextStyle(fontSize: 16))),
          Expanded(flex: 3, child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: s.activeChannel == i ? Colors.orange : Colors.lightBlueAccent,
              borderRadius: BorderRadius.circular(8),
              boxShadow: s.activeChannel == i ? [BoxShadow(color: Colors.orange.withOpacity(0.6), blurRadius: 8)] : [],
            ),
            child: DropdownButtonHideUnderline(child: DropdownButton<String>(
              value: s.chFunctions[i], isExpanded: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              items: opts.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
              onChanged: (v) { if (v == null) return; setState(() => s.chFunctions[i] = v); bt.send('CH_${i + 1}=${opts.indexOf(v)};'); },
            )),
          )),
        ])),
    ]));
  }
}

// ─── BLE Remote Page ──────────────────────────────────────────────────────────

// ─── Remote Page ──────────────────────────────────────────────────────────────
class _SignalBars extends StatelessWidget {
  final int bars;
  const _SignalBars(this.bars);
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(5, (i) {
        final active = i < bars;
        return Container(
          width: 4, height: 4.0 + i * 3.0,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF546E7A) : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }
}

class _RemotePage extends StatefulWidget {
  final AppState state;
  final BtManager bt;
  const _RemotePage({required this.state, required this.bt});
  @override State<_RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<_RemotePage> {
  late double _deadVal, _speedVal, _speed2AngleVal, _speed2Val;
  // Тянут ли сейчас какой-нибудь слайдер - см. _onStateChange.
  bool _draggingSlider = false;

  // Скан BLE-устройств поблизости для привязки WT901 - только на Android.
  // На iOS flutter_blue_plus не может получить настоящий MAC-адрес -
  // CoreBluetooth подставляет вместо него случайный UUID (per-app
  // CBPeripheral.identifier), поэтому сканирование на iPhone принципиально
  // не может работать - см. build(), там скан скрыт для iOS. Привязка MAC
  // на iPhone возможна только через веб-страницу ротора (ручной ввод байт).
  final Map<String, ScanResult> _scanResults = {};
  bool _scanning = false;
  // Раскрыт ли блок привязки датчика - см. кнопку "Pair / change sensor".
  bool _showPairing = false;
  // Момент начала текущего поиска - по нему отбрасываем результаты прошлого.
  DateTime _scanStartedAt = DateTime.now();
  StreamSubscription<List<ScanResult>>? _scanSub;
  String? _connectedMac;   // MAC выбранного устройства
  String? _connectedName;

  // ── Телефон как источник наклона ──────────────────────────────────────
  // Прошивку менять не нужно: команда PITCH=<угол>; уже есть и кладёт
  // значение туда же, куда пишет настоящий WT901.
  RemoteSource _source = RemoteSource.off;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  Timer? _phoneSendTimer;
  double _phonePitch = 0;      // итоговый наклон телефона, градусы
  double _phoneAccelAngle = 0; // угол только по акселерометру (шумный, но без дрейфа)
  bool _phoneFiltInit = false;
  int _phoneTilt = 0;          // ось ТЕЛЕФОНА: 0 = Pitch, 1 = Roll, 2 = Yaw
  // Ось WT901 запоминается отдельно от телефонной: у источников она разная
  // (например, на пульте Roll, а на телефоне Yaw), и при переключении между
  // ними каждый должен вернуться к своей. На коробке ось одна, поэтому
  // помнить, что где было, приходится приложению. null = ещё не знаем, каким
  // был выбор для WT901 (возьмём то, что придёт от коробки).
  int? _wt901Axis;

  // Обе оси храним на телефоне, чтобы выбор пережил и перезапуск приложения.
  // На коробке ось всего одна, так что она такое разделение хранить не может.
  static const _kPrefPhoneTilt = 'phoneTilt';
  static const _kPrefWt901Axis = 'wt901AxisForRemote';
  static const _kPrefLockRot   = 'lockRotation';
  static const _kPrefKeepAwake = 'keepAwake';
  static const _kPrefUseCompass = 'useCompassForYaw';
  static const _kPrefRevPitch  = 'phoneRevPitch';
  static const _kPrefRevRoll   = 'phoneRevRoll';

  // Управление наклоном телефона конфликтует с его же системными функциями:
  // наклон вбок вызывает автоповорот экрана (интерфейс переворачивается прямо
  // во время работы), а погасший экран останавливает поток данных с датчиков.
  // Поэтому обе штуки можно отключить прямо отсюда.
  bool _lockRotation = true;
  bool _keepAwake = true;

  void _applyScreenPrefs() {
    SystemChrome.setPreferredOrientations(_lockRotation
        ? [DeviceOrientation.portraitUp]
        : DeviceOrientation.values);
    WakelockPlus.toggle(enable: _keepAwake);
  }

  Future<void> _loadAxisPrefs() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _phoneTilt = p.getInt(_kPrefPhoneTilt) ?? _phoneTilt;
      _wt901Axis = p.getInt(_kPrefWt901Axis);
      _lockRotation = p.getBool(_kPrefLockRot) ?? _lockRotation;
      _keepAwake = p.getBool(_kPrefKeepAwake) ?? _keepAwake;
      _useCompass = p.getBool(_kPrefUseCompass) ?? _useCompass;
      _phoneRevPitch = p.getBool(_kPrefRevPitch) ?? _phoneRevPitch;
      _phoneRevRoll  = p.getBool(_kPrefRevRoll)  ?? _phoneRevRoll;
    });
    _applyScreenPrefs();
  }

  Future<void> _saveAxisPrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kPrefPhoneTilt, _phoneTilt);
    await p.setBool(_kPrefLockRot, _lockRotation);
    await p.setBool(_kPrefKeepAwake, _keepAwake);
    await p.setBool(_kPrefUseCompass, _useCompass);
    await p.setBool(_kPrefRevPitch, _phoneRevPitch);
    await p.setBool(_kPrefRevRoll,  _phoneRevRoll);
    final a = _wt901Axis;
    if (a != null) await p.setInt(_kPrefWt901Axis, a);
  }
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  // Свой канал к системным датчикам - см. android/.../MainActivity.kt и
  // ios/Runner/MotionChannel.swift. Даёт то, чего sensors_plus не отдаёт.
  static const _motionChannel = EventChannel('gyro360/motion');
  StreamSubscription? _motionSub;
  int? _lastGyroUs;
  // Последний вектор силы тяжести (из акселерометра). Нужен для Yaw: чтобы
  // поворот считался вокруг ВЕРТИКАЛИ МИРА, а не вокруг оси телефона -
  // тогда неважно, как держат телефон (плашмя, стоймя, под углом).
  double _gx = 0, _gy = 0, _gz = 0;
  double _phoneYaw = 0;        // накопленный поворот, градусы

  // Смещение нуля гироскопа: лежащий неподвижно телефон всё равно показывает
  // ненулевую скорость вращения. На Android система отдаёт уже
  // скомпенсированный TYPE_GYROSCOPE, а на iOS sensors_plus берёт СЫРОЙ
  // startGyroUpdates - смещение приходит как есть. Для Pitch/Roll его держит
  // акселерометр, а Yaw опереться не на что, и смещение интегрируется без
  // конца: пара градусов в секунду - это уже пара оборотов за минуту. Поэтому
  // оцениваем его сами и вычитаем (стандартный приём zero-rate update).
  double _gyroBiasX = 0, _gyroBiasY = 0, _gyroBiasZ = 0;
  // Прошлая абсолютная ориентация - от неё считается изменение поворота.
  final List<double> _qMotion = [0, 0, 0, 0];   // [w, x, y, z]
  bool _haveAttitude = false;
  // Тот же поворот, но по ориентации с магнитометром: эталон без дрейфа, к
  // которому подтягивается _phoneYaw. Отсчёт общий - оба начинаются с нуля.
  final List<double> _qCompass = [0, 0, 0, 0];
  bool _haveCompass = false;
  double _compassYaw = 0;
  // Опорная ориентация для наклона: от неё считается Pitch/Roll. null =
  // системной ориентации нет, работает запасной расчёт по гравитации.
  List<double>? _qTiltRef;
  // Реверс для наклона с телефона - СВОЙ для каждой оси и свой, отдельный от
  // реверса WT901: у коробки он один на ось 1, а телефон шлёт туда и Pitch, и
  // Roll. Применяем его сами, чтобы не трогать настройку физического пульта.
  bool _phoneRevPitch = false, _phoneRevRoll = false;
  bool get _phoneRev => _phoneTilt == 0 ? _phoneRevPitch : _phoneRevRoll;
  // Подтягивать ли накопленный дрейф Yaw к системной ориентации (она слита с
  // магнитометром). По умолчанию ВЫКЛЮЧЕНО: ротатор - это металл с мотором,
  // поле рядом с ним искажено, и на практике чистый гироскоп ведёт себя
  // заметно предсказуемее. Дрейф лечится повторным выбором Yaw.
  bool _useCompass = false;
  double _gyroStillSec = 0;

  // Постоянная времени слияния, секунды: за столько акселерометр вытягивает
  // угол обратно, если гироскоп ушёл. Задана именно ВО ВРЕМЕНИ, а не долей на
  // отсчёт - иначе частота опроса датчиков молча меняла бы поведение фильтра
  // (доля 0.10 на отсчёт при 5 Гц и при 50 Гц - это совершенно разная
  // инерция). Значение подобрано на слух ещё при 5 Гц и сохранено как есть.
  static const _phoneTauSec = 1.8;

  // Ноль НЕ считаем в приложении: этим занимается сама прошивка по кнопке
  // "ZERO CURRENT AXIS" (она запоминает текущий угол как центр и хранит его
  // во флеше). Телефон ведёт себя ровно как настоящий WT901 - шлёт сырой
  // угол, а центровку делает коробка. Значение центра приходит обратно в
  // WT901_PITCH_ZERO и нужно нам только для показа мёртвой зоны на экране.
  // Отдельное, СИЛЬНОЕ сглаживание только для цифры на экране: глазу нужна
  // спокойная цифра, а управлению - быстрая реакция. Поэтому на коробку идёт
  // _phonePitch (слияние гиро+акселерометра), а показывается вот это.
  double _phoneShown = 0;
  // Для наклона вычитаем ноль, который держит прошивка (кнопка ZERO) - тогда
  // видно ровно то, что видит она, и подсветка мёртвой зоны совпадает.
  // Для Yaw вычитать его НЕЛЬЗЯ: это калибровка наклона, к повороту
  // отношения не имеет, и раньше из-за этого цифра выглядела бессмысленной.
  // Yaw и так отсчитывается от нуля с момента выбора режима.
  // При счёте от опорного положения ноль уже наш собственный - вычитать ещё и
  // прошивочный нельзя, цифра уехала бы на его величину.
  double get _phoneShownOut =>
      (_phoneTilt == 2 || _qTiltRef != null)
          ? _phoneShown
          : _phoneShown - widget.state.wt901PitchZero;

  // Нажатие пользователя: шлём команды на коробку и сразу применяем локально.
  // Пока команды в пути, ответы коробки об СТАРОМ состоянии игнорируем - иначе
  // они перебивали свежий выбор, и переключатель срабатывал лишь со второго
  // раза (коробка отвечает статусом после первой из двух команд, где режим
  // ещё выключен).
  DateTime? _srcChangedAt;

  void _setSource(RemoteSource src) {
    _srcChangedAt = DateTime.now();
    // Источник сообщаем коробке ЯВНО: режимы взаимоисключающие, иначе
    // физический датчик и телефон пишут в одни переменные угла и мотор
    // дёргается. Коробка этот выбор не сохраняет - он живёт, пока телефон
    // подключён, и сбрасывается на WT901 при разрыве связи.
    widget.bt.send('WT901_SRC=${src == RemoteSource.phone ? 1 : 0};');
    final on = src != RemoteSource.off;
    widget.state.wt901Enabled = on;
    widget.state.wt901SrcPhone = src == RemoteSource.phone;
    widget.bt.send('WT901_ENABLED=${on ? 1 : 0};');
    _applySourceLocal(src, sendCommands: true);
  }

  // Применяет источник ТОЛЬКО локально (датчики, подписки), ничего не отправляя.
  // Нужно и для нажатия, и когда коробка сама сменила режим - например,
  // сбросила источник на WT901 при разрыве связи с телефоном.
  // sendCommands=true только при нажатии пользователя. Когда режим сменила
  // сама коробка, команды слать НЕЛЬЗЯ - получилось бы эхо ей же в ответ.
  void _applySourceLocal(RemoteSource src, {bool sendCommands = false}) {
    setState(() => _source = src);
    _accelSub?.cancel(); _accelSub = null;
    _gyroSub?.cancel(); _gyroSub = null;
    _motionSub?.cancel(); _motionSub = null;
    _phoneSendTimer?.cancel(); _phoneSendTimer = null;
    _haveAttitude = false;   // между сеансами разницу поворотов не считаем
    // Опору наклона задаём заново при первом же отсчёте ориентации: положение
    // телефона при входе в режим и есть его ноль (см. _feedAttitude).
    _qTiltRef = null;
    _haveCompass = false;
    // Эталон ведём от текущего угла, а не от нуля: иначе при пересоздании
    // подписки появилось бы расхождение на весь накопленный поворот, и
    // поправка потащила бы мотор его выбирать.
    _compassYaw = _phoneYaw;
    _phoneFiltInit = false;
    _lastGyroUs = null;

    final on = src != RemoteSource.off;
    if (!on) { _stopScan(); _connectedMac = null; _connectedName = null; return; }

    if (src == RemoteSource.wt901) {
      // Возвращаем ось, которая была выбрана именно для пульта: телефон,
      // пока был активен, перебил её на коробке своей (см. _applyPhoneAxis).
      final axis = _wt901Axis;
      if (sendCommands && axis != null) {
        widget.state.wt901Axis = axis;
        widget.bt.send('WT901_AXIS=$axis;');
      }
      return;
    }

    if (src == RemoteSource.phone) {
      // Если для WT901 ось ещё не запоминали, берём текущую с коробки - её
      // мы сейчас перебьём своей, и вернуть будет уже неоткуда.
      _wt901Axis ??= widget.state.wt901Axis;
      if (sendCommands) _applyPhoneAxis();

      // Наклон считаем по вектору силы тяжести (акселерометр), а не
      // гироскопом - тот копит дрейф. atan2 даёт диапазон ±90°.
      // Сырые показания заметно дрожат, поэтому сглаживаем экспоненциальным
      // фильтром: коэффициент подобран так, чтобы убрать дрожь, но не
      // добавить ощутимой задержки на реальный наклон.
      // Слияние акселерометра и гироскопа - то же, что делает BNO085 в режиме
      // GAME_ROTATION_VECTOR (он тоже работает без магнитометра). Гироскоп
      // даёт быструю и гладкую реакцию на движение, акселерометр не даёт
      // ошибке накапливаться. Простое сглаживание одного акселерометра, что
      // стояло раньше, убирало дрожь только ценой заметного запаздывания.
      // 20мс вместо стандартных 200мс. При 5 Гц половина посылок на коробку
      // просто повторяла предыдущее значение, а между отсчётами угол шагал
      // рывками по целому десятку градусов, если телефон вели быстро.
      // Перерисовывать экран 50 раз в секунду не нужно - показания и отправка
      // идут по таймеру ниже, а здесь только считаем.
      // Датчики берём своим каналом (android MainActivity.kt / iOS
      // MotionChannel.swift): системе доступно то, чего sensors_plus не отдаёт -
      // очищенная от ускорения руки гравитация, а на iOS ещё и гироскоп с
      // вычтенным смещением нуля. Если канал по какой-то причине не отвечает,
      // откатываемся на сырые датчики: хуже, но работает.
      // Флагом канал решает, поднимать ли магнитометр: на iOS рамка ориентации
      // выбирается один раз при подписке, две сразу система не отдаёт. Поэтому
      // при переключении подписка пересоздаётся (см. переключатель компаса).
      _motionSub =
          _motionChannel.receiveBroadcastStream(_useCompass).listen((ev) {
        final v = (ev as List).cast<double>();
        _feedGravity(v[0], v[1], v[2]);
        // Кватернионы приходят не всегда - датчика ориентации может не быть.
        // Тогда поворот считает _feedGyro, как раньше.
        if (v.length >= 10) _feedAttitude(v[6], v[7], v[8], v[9]);
        if (v.length >= 14) _feedCompass(v[10], v[11], v[12], v[13]);
        _feedGyro(v[3], v[4], v[5]);
      }, onError: (_) {
        if (_motionSub == null) return;   // подписку уже сняли - это не сбой
        _motionSub?.cancel();
        _motionSub = null;
        _startRawSensors();
      });

      // Шлём каждые 100мс: на коробке данные устаревают через 400мс
      // (WT901_TIMEOUT), запас четырёхкратный.
      _phoneSendTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        // Экранное значение тянем к настоящему отдельно и заметно медленнее:
        // управлению нужна скорость, а глазу - спокойная цифра.
        setState(() {
          final target = _phoneTilt == 2 ? _phoneYaw : _phonePitch;
          _phoneShown += 0.12 * (target - _phoneShown);
        });
        if (_source != RemoteSource.phone) return;
        if (_phoneTilt == 2) {
          widget.bt.send('YAW=${_phoneYaw.toStringAsFixed(1)};');
        } else {
          // Прошивка вычтет из присланного свой ноль (калибровка ZERO, общая с
          // WT901). Когда мы считаем от собственной опоры, этот ноль надо
          // компенсировать заранее - иначе он вычтется вторым и центр уедет.
          // Так прошивку менять не пришлось и калибровка физического пульта
          // осталась нетронутой.
          // Реверс телефона применяем сами, а реверс коробки компенсируем: она
          // считает raw = присланное - ноль, и при своём реверсе меняет знак.
          // Чтобы на выходе получилось ровно наше значение, шлём с учётом обоих.
          final d = _phoneRev ? -_phonePitch : _phonePitch;
          final out = _qTiltRef != null
              ? widget.state.wt901PitchZero +
                  (widget.state.wt901PitchReverse ? -d : d)
              : _phonePitch;
          widget.bt.send('PITCH=${out.toStringAsFixed(1)};');
        }
      });
    }
  }

  // Запасной путь: сырые датчики через sensors_plus. Тут акселерометр меряет
  // гравитацию вместе с ускорением руки, а на iOS у гироскопа не вычтено
  // смещение нуля - обе беды лечит математика ниже, но хуже, чем это делает
  // сама система.
  void _startRawSensors() {
    _accelSub = accelerometerEventStream(
            samplingPeriod: SensorInterval.gameInterval)
        .listen((e) => _feedGravity(e.x, e.y, e.z));
    _gyroSub = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen((g) => _feedGyro(g.x, g.y, g.z));
  }

  // Направление "вниз" - от него считается наклон.
  void _feedGravity(double x, double y, double z) {
    // Вперёд-назад берём по оси Y, вбок - по X; в обоих случаях делим на
    // длину оставшихся двух осей, чтобы угол не зависел от того, как
    // сильно телефон повёрнут по другой оси.
    _gx = x; _gy = y; _gz = z;
    _phoneAccelAngle = _phoneTilt == 0
        ? atan2(y, sqrt(x * x + z * z)) * 180 / pi
        : atan2(-x, sqrt(y * y + z * z)) * 180 / pi;
    if (!_phoneFiltInit) {
      _phonePitch = _phoneAccelAngle;
      _phoneShown = _phoneAccelAngle;
      _phoneFiltInit = true;
    }
  }

  // Тот же вид, что и у остальных переключателей, но без внешних отступов -
  // этот блок и так лежит внутри контейнера со своим полем.
  Widget _miniSwitch(String label, bool value, void Function(bool) onChanged) =>
      _switchRow(label, value, onChanged, hPad: 0);

  static double _wrap180(double deg) {
    if (deg > 180) return deg - 360;
    if (deg < -180) return deg + 360;
    return deg;
  }

  // Поворот вокруг вертикали МИРА между двумя ориентациями, градусы.
  //
  // Берём именно ИЗМЕНЕНИЕ, а не готовый азимут: азимут вырождается, когда
  // телефон держат вертикально (та же беда, что и "gimbal lock"), а разница
  // поворотов считается одинаково хорошо в любом положении. Заодно сохраняется
  // прежний смысл: Yaw отсчитывается от момента выбора оси, а не от севера.
  static double _yawDelta(List<double> prev, double w, double x, double y, double z) {
    // Δq = q_текущий ⊗ q_прошлый⁻¹ - поворот, случившийся в системе координат
    // МИРА. У единичного кватерниона обратный равен сопряжённому.
    final dw = w * prev[0] + x * prev[1] + y * prev[2] + z * prev[3];
    var dz = -w * prev[3] - x * prev[2] + y * prev[1] + z * prev[0];
    // Кватернионы q и -q описывают один поворот; без этого при смене знака
    // получался бы скачок на пол-оборота.
    if (dw < 0) dz = -dz;
    // За 20мс поворот заведомо мал, поэтому угол = удвоенная векторная часть.
    // Мировая ось Z смотрит вверх на обеих платформах, так что z-компонента -
    // это ровно поворот вокруг вертикали.
    final dYaw = 2 * dz * 180 / pi;
    return dYaw.abs() < 45 ? dYaw : 0;   // больше - сбой потока, пропускаем
  }

  // Наклон как ПОВОРОТ ОТ ОПОРНОГО ПОЛОЖЕНИЯ, а не угол к горизонту.
  //
  // Угол к горизонту (atan2 по гравитации) живёт только в пределах ±90° и
  // вырождается у краёв: у почти вертикального телефона знаменатель уходит к
  // нулю, дрожание даёт скачки, и уже к 70° управлять нечем. Кнопка ZERO там
  // не спасает - она сдвигает начало отсчёта, а не убирает вырождение.
  //
  // Здесь берём поворот, случившийся с момента опоры (Δq = q_тек ⊗ q_опор⁻¹),
  // и проецируем его на ту мировую ось, вокруг которой этот наклон вращает.
  // Ось берём из опорной ориентации: для Pitch это то, куда смотрела ось X
  // телефона, для Roll - ось Y. Опорное положение может быть любым, хоть
  // вертикальным, поэтому вырождения в рабочей точке нет.
  //
  // Возвращает градусы; 0 = телефон в опорном положении.
  double _tiltFromRef(int tilt) {
    final r = _qTiltRef;
    if (r == null) return 0;
    final rw = r[0], rx = r[1], ry = r[2], rz = r[3];
    final w = _qMotion[0], x = _qMotion[1], y = _qMotion[2], z = _qMotion[3];

    // Δq = q_тек ⊗ q_опор⁻¹ (обратный = сопряжённый у единичного).
    var dw = w * rw + x * rx + y * ry + z * rz;
    var dx = -w * rx + x * rw - y * rz + z * ry;
    var dy = -w * ry + x * rz + y * rw - z * rx;
    var dz = -w * rz - x * ry + y * rx + z * rw;
    if (dw < 0) { dw = -dw; dx = -dx; dy = -dy; dz = -dz; }  // q и -q - один поворот

    // Вектор поворота: направление - ось, длина - угол в радианах. В отличие
    // от "удвоенной векторной части" это верно и на больших углах.
    final vLen = sqrt(dx * dx + dy * dy + dz * dz);
    if (vLen < 1e-9) return 0;
    final ang = 2 * atan2(vLen, dw);
    // z-компонента не нужна: обе наши оси горизонтальны, поворот вокруг
    // вертикали к наклону отношения не имеет (это Yaw).
    final kx = dx / vLen * ang, ky = dy / vLen * ang;

    // Оси, вокруг которых считаем наклон, обязаны быть ГОРИЗОНТАЛЬНЫМИ.
    // Брать оси самого телефона нельзя: у вертикально поднятого телефона его
    // ось Y смотрит вверх, и вращение вокруг неё - это поворот вокруг
    // вертикали, а не наклон. Именно поэтому Roll в таком хвате отзывался на
    // разворот телефона и не отзывался на наклон.
    //
    // Строим горизонтальную пару от опорного положения: за ось Pitch берём
    // горизонтальную часть оси X телефона (она идёт поперёк корпуса и остаётся
    // почти горизонтальной и когда телефон лежит, и когда стоит), а ось Roll -
    // перпендикуляр к ней в той же горизонтальной плоскости.
    double px = 1 - 2 * (ry * ry + rz * rz);   // ось X телефона в мире
    double py = 2 * (rx * ry + rw * rz);
    // z-компоненту просто отбрасываем - остаётся горизонтальная проекция.
    double pLen = sqrt(px * px + py * py);
    if (pLen < 0.2) {
      // Ось X встала почти вертикально (телефон повёрнут набок) - берём вместо
      // неё ось Y, иначе направление вырождается.
      px = 2 * (rx * ry - rw * rz);
      py = 1 - 2 * (rx * rx + rz * rz);
      pLen = sqrt(px * px + py * py);
      if (pLen < 1e-6) return 0;
    }
    px /= pLen; py /= pLen;

    // Pitch - вокруг найденной оси, Roll - вокруг перпендикуляра к ней
    // (поворот на 90° в горизонтальной плоскости: (x,y) -> (-y,x)).
    final ax = tilt == 0 ? px : -py;
    final ay = tilt == 0 ? py : px;
    return (kx * ax + ky * ay) * 180 / pi;
  }

  // Запомнить текущее положение как опорное (кнопка ZERO в режиме телефона,
  // смена оси, вход в режим).
  void _captureTiltRef() {
    _qTiltRef = _haveAttitude ? List<double>.from(_qMotion) : null;
    _phonePitch = 0;
    _phoneShown = 0;
  }

  // ОСНОВНОЙ источник поворота: ориентация, посчитанная системой БЕЗ
  // магнитометра (Android TYPE_GAME_ROTATION_VECTOR, iOS - рамка без
  // коррекции). Интегрировать гироскоп самим нельзя: мы видим его 50 раз в
  // секунду, а при встряске телефон за один шаг успевает провернуться на
  // несколько градусов, и вращения вокруг разных осей ещё и не складываются
  // линейно. Ошибка набегала сразу и оставалась навсегда - опоры-то нет.
  // Система интегрирует на своей частоте и такой ошибки не даёт.
  void _feedAttitude(double w, double x, double y, double z) {
    if (_haveAttitude) {
      _phoneYaw = _wrap180(_phoneYaw + _yawDelta(_qMotion, w, x, y, z));
    }
    _qMotion[0] = w; _qMotion[1] = x; _qMotion[2] = y; _qMotion[3] = z;
    _haveAttitude = true;
    // Первая же ориентация после входа в режим становится опорой для наклона:
    // с какого положения начали, то и ноль.
    _qTiltRef ??= [w, x, y, z];
  }

  // Эталон для медленной поправки: та же ориентация, но слитая с магнитометром.
  // Она не уползает, поэтому годится как опора. Напрямую источником поворота
  // её брать нельзя: магнитометр время от времени перекалибровывается, и
  // ориентация скачком уезжает на несколько градусов - такой скачок ушёл бы
  // прямо в мотор.
  void _feedCompass(double w, double x, double y, double z) {
    if (_haveCompass) {
      _compassYaw = _wrap180(_compassYaw + _yawDelta(_qCompass, w, x, y, z));
    }
    _qCompass[0] = w; _qCompass[1] = x; _qCompass[2] = y; _qCompass[3] = z;
    _haveCompass = true;
  }

  void _feedGyro(double rawX, double rawY, double rawZ) {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final prev = _lastGyroUs;
    _lastGyroUs = nowUs;
    if (prev == null || !_phoneFiltInit || !mounted) return;
    final dt = (nowUs - prev) / 1e6;
    if (dt <= 0 || dt > 0.5) return;   // пропуск/зависание - не интегрируем

    // Оценка смещения нуля. Когда телефон почти неподвижен, всё, что
    // показывает гироскоп - это и есть смещение, так что подтягиваем к нему
    // оценку. Через свой канал смещение уже снято (Android отдаёт
    // калиброванный гироскоп, iOS - CMDeviceMotion), и оценка просто стоит
    // около нуля; нужна она для запасного пути на сырых датчиках.
    final bx = rawX - _gyroBiasX, by = rawY - _gyroBiasY, bz = rawZ - _gyroBiasZ;
    if (sqrt(bx * bx + by * by + bz * bz) < 0.06) {   // < ~3.4 °/с
      // Скорости подстройки во времени, а не на отсчёт: первую секунду
      // неподвижности сходимся быстро, дальше - с постоянной 10с. Медленную
      // подстройку иначе съедал бы НАМЕРЕННЫЙ медленный поворот.
      final k = (dt / (_gyroStillSec < 1.0 ? 0.3 : 10.0)).clamp(0.0, 1.0);
      _gyroBiasX += k * (rawX - _gyroBiasX);
      _gyroBiasY += k * (rawY - _gyroBiasY);
      _gyroBiasZ += k * (rawZ - _gyroBiasZ);
      _gyroStillSec += dt;
    }
    final gX = rawX - _gyroBiasX, gY = rawY - _gyroBiasY, gZ = rawZ - _gyroBiasZ;

    if (_phoneTilt == 2) {
      final gLen = sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
      if (gLen < 1) return;
      // Проекция вектора вращения на направление силы тяжести даёт скорость
      // поворота вокруг вертикали мира, независимо от того, как держат телефон.
      final rateRaw = (gX * _gx + gY * _gy + gZ * _gz) / gLen; // рад/с

      // Запасной путь - только если система ориентацию не даёт (нет датчика
      // или канал не отвечает). Своё интегрирование заметно грубее: см.
      // _feedAttitude, где сказано, почему.
      if (!_haveAttitude) {
        // Опоры у поворота нет, остаток смещения копится, поэтому совсем
        // медленное вращение считаем стоянием: повод повернуть антенну - это
        // осознанное движение, а не 0.5°/с.
        final rate = rateRaw.abs() < 0.01 ? 0.0 : rateRaw;   // ~0.6 °/с
        _phoneYaw += rate * 180 / pi * dt;
      }

      // Накопленный дрейф убираем компасом - но только пока телефон
      // практически неподвижен и очень медленно. Причина: ориентация с
      // магнитометром время от времени скачком перекалибровывается, и если
      // тянуться к ней быстро, скачок уедет прямо в мотор. Пока телефон ведут,
      // поправка не нужна и только мешала бы - там расхождение между датчиками
      // по времени как раз максимально.
      if (_useCompass && _haveCompass && rateRaw.abs() < 0.02) {  // ~1 °/с
        final err = _wrap180(_compassYaw - _phoneYaw);
        final maxStep = 0.3 * dt;   // не быстрее 0.3 °/с
        _phoneYaw += err.clamp(-maxStep, maxStep);
      }

      _phoneYaw = _wrap180(_phoneYaw);
      return;
    }
    // Есть системная ориентация - считаем наклон от опорного положения: он не
    // вырождается ни у какого хвата (см. _tiltFromRef). Фильтр гиро+акселерометр
    // ниже нужен только запасному пути, тут сглаживать нечего.
    if (_qTiltRef != null) {
      _phonePitch = _tiltFromRef(_phoneTilt);
      return;
    }

    // Запасной путь - угол к горизонту по гравитации. Знак ПЛЮС: проверено по
    // матрице поворота, при повороте телефона на угол θ вокруг оси X гравитация
    // в его системе становится (0, g·sinθ, g·cosθ), то есть atan2(y, ...) даёт
    // ровно +θ - и гироскоп по X меряет ту же +dθ/dt. То же для Y/roll. Раньше
    // тут стоял минус: гироскоп тянул угол в обратную сторону, акселерометр его
    // перетягивал назад, и это выглядело как сильный дрейф.
    final rateDeg = (_phoneTilt == 0 ? gX : gY) * 180 / pi;
    final byGyro = _phonePitch + rateDeg * dt;
    // Через свой канал сюда приходит ЧИСТАЯ гравитация, её длина всегда 9.8 и
    // доверие полное. Проверка нужна для запасного пути: там акселерометр
    // меряет гравитацию плюс ускорение руки, и на время рывка (длина вектора
    // уехала) опираться можно только на гироскоп.
    final aLen = sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    final trust = (1 - (aLen - 9.81).abs() / 2.0).clamp(0.0, 1.0);
    final w = (1 - _phoneTauSec / (_phoneTauSec + dt)) * trust;
    _phonePitch = (1 - w) * byGyro + w * _phoneAccelAngle;
  }

  @override
  void initState() {
    super.initState();
    _deadVal = widget.state.wt901DeadZone.clamp(0.0, 45.0);
    _speedVal = widget.state.wt901Speed.toDouble().clamp(1.0, 15.0);
    _speed2AngleVal = widget.state.wt901Speed2Angle.clamp(0.0, 90.0);
    _speed2Val = widget.state.wt901Speed2.toDouble().clamp(1.0, 25.0);
    _syncConnectedFromState();
    widget.state.addListener(_onStateChange);
    _loadAxisPrefs();   // запомненные оси для каждого источника
    // Скан больше не стартует при входе на страницу: блок привязки свёрнут,
    // и запускать радио, которое нужно управлению, ради скрытого списка незачем.
    // Скан начинается при раскрытии блока (см. кнопку "Pair / change sensor").
  }

  // Статус "подключено" раньше жил только в локальной переменной сессии
  // (заполнялась лишь когда сами выбрали устройство из скана в этом же
  // запуске приложения) — при перезапуске приложения/переходе между
  // вкладками он сбрасывался, хотя ротатор реально помнит MAC и продолжает
  // работать с WT901. Теперь синхронизируем с реальным состоянием ротатора.
  void _syncConnectedFromState() {
    final mac = widget.state.wt901Mac;
    if (mac.isEmpty) {
      _connectedMac = null;
      _connectedName = null;
      return;
    }
    if (_connectedMac != mac) {
      _connectedMac = mac;
      // Имя у привязанного пульта всегда одно и то же - показываем его, а сам
      // MAC и так виден в строке ниже.
      _connectedName = _remoteDisplayName;
    }
  }

  void _onStateChange() {
    // Пока слайдер тянут пальцем, его значение принадлежит пользователю.
    // Прилетевший статус несёт ЕЩЁ СТАРОЕ значение (ротатор узнает о новом
    // только когда палец отпустят - см. onChangeEnd), и без этой проверки он
    // отбрасывал бегунок назад прямо посреди движения.
    if (!_draggingSlider) {
      _deadVal = widget.state.wt901DeadZone.clamp(0.0, 45.0);
      _speedVal = widget.state.wt901Speed.toDouble().clamp(1.0, 15.0);
      _speed2AngleVal = widget.state.wt901Speed2Angle.clamp(0.0, 90.0);
      _speed2Val = widget.state.wt901Speed2.toDouble().clamp(1.0, 25.0);
    }
    _syncConnectedFromState();
    // Ротатор мог сам выключить WT901 (физической кнопкой) - тогда возвращаем
    // переключатель в "Выкл" и глушим отправку с телефона. Обратно в WT901 не
    // переводим автоматически: какой именно источник нужен, знает только
    // пользователь, а угадывать тут - значит неожиданно двинуть мотор.
    // Положение переключателя ВЫВОДИМ из реального состояния коробки, а не
    // держим отдельно: иначе при запуске приложения показывалось "Off", хотя
    // WT901 работал, а коробка сама могла сменить режим (сброс источника при
    // разрыве связи), и переключатель об этом не знал.
    // Исключение - короткое окно после нажатия: там наши команды ещё в пути,
    // и статус описывает прежнее состояние.
    final justChanged = _srcChangedAt != null &&
        DateTime.now().difference(_srcChangedAt!).inMilliseconds < 1500;
    if (!justChanged) {
      final derived = !widget.state.wt901Enabled
          ? RemoteSource.off
          : (widget.state.wt901SrcPhone ? RemoteSource.phone : RemoteSource.wt901);
      if (derived != _source) _applySourceLocal(derived);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    _accelSub?.cancel();
    _gyroSub?.cancel();
    _motionSub?.cancel();
    _phoneSendTimer?.cancel();
    // Возвращаем экран в обычный режим - иначе блокировка поворота и запрет
    // гаснуть остались бы висеть на всём приложении после ухода с этой страницы
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    WakelockPlus.disable();
    super.dispose();
  }

  // Привязываем ТОЛЬКО подготовленные датчики - те, что настроены утилитой
  // wit_tool (папка Eksperement 2\wit_tool). Она даёт датчику имя вида
  // WTG + адрес без двоеточий, например WTGD2614A030C1E, и заодно ставит 6
  // осей. Заводской WT901BLE67 в список не попадает намеренно: имя тут работает
  // как отметка "датчик настроен под ротатор", а не просто как подпись.
  //
  // Адрес в имени - не украшение, а единственный способ узнать его на iPhone:
  // iOS не отдаёт приложению настоящий MAC (подменяет случайным UUID, своим для
  // каждого приложения), а имя отдаёт как есть. Поэтому привязка теперь
  // работает на обеих платформах одинаково, и ручной ввод шести байт на iPhone
  // больше не нужен.
  // В интерфейсе показываем своё имя: заводское ничего не говорит владельцу.
  static const _remoteDisplayName = 'Gyro360 remote';

  static final _macInName = RegExp(r'^WTG([0-9A-F]{12})$', caseSensitive: false);

  /// Имя берём ИЗ РЕКЛАМНОГО ПАКЕТА, а не из device.platformName.
  ///
  /// iOS кэширует имя устройства с прошлых встреч и продолжает отдавать
  /// старое - после переименования датчика айфон ещё долго называет его
  /// прежним WT901BLE67, и по нему привязка не находится вовсе. Реклама же
  /// приходит свежая в каждом пакете. На Android разницы нет.
  static String _advName(ScanResult r) {
    final adv = r.advertisementData.advName.trim();
    return adv.isNotEmpty ? adv : r.device.platformName.trim();
  }

  static bool _isRemote(String name) => _macInName.hasMatch(name.trim());

  /// Достаёт настоящий MAC из имени: WTGD2614A030C1E -> D2:61:4A:03:0C:1E.
  /// Возвращает null, если имя не нашего формата.
  static String? _macFromName(String name) {
    final m = _macInName.firstMatch(name.trim());
    if (m == null) return null;
    final hex = m.group(1)!.toUpperCase();
    return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
  }

  void _startScan() {
    // Отсекаем всё, что увидено ДО начала этого поиска: библиотека отдаёт
    // накопленный список, и записи прошлого скана прилетают сразу при открытии.
    // Выглядело так, будто пульт уже в эфире, хотя он ещё даже не включён -
    // привязаться к такому "устройству" нельзя, а список врёт.
    _scanStartedAt = DateTime.now();
    setState(() { _scanning = true; _scanResults.clear(); });
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.timeStamp.isBefore(_scanStartedAt)) continue;
        if (_isRemote(_advName(r))) {
          setState(() => _scanResults[r.device.remoteId.str] = r);
        }
      }
    });
    FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) setState(() => _scanning = scanning);
    });
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
  }

  void _stopScan() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    setState(() => _scanning = false);
  }

  void _selectDevice(ScanResult r) {
    // Адрес берём ИЗ ИМЕНИ, а не из remoteId: на Android они совпадают, а на
    // iPhone remoteId - это случайный UUID, подставленный системой, и ротатор
    // по нему датчик не найдёт. Имя же одинаково на обеих платформах.
    final mac = _macFromName(_advName(r));
    if (mac == null) return;   // в список такие и не попадают, но пусть
    _stopScan();
    setState(() {
      _connectedMac  = mac;
      _connectedName = _remoteDisplayName;
    });
    widget.bt.send('WT901_MAC=$mac;');
  }

  void _disconnectDevice() {
    setState(() { _connectedMac = null; _connectedName = null; });
    widget.bt.send('WT901_MAC=;');
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair WT901?'),
        content: const Text('The rotator will forget the saved MAC address. You will need to pair it again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Agree')),
        ],
      ),
    );
    if (confirmed == true) _disconnectDevice();
  }

  int _rssiBars(int? rssi) {
    if (rssi == null) return 1;
    if (rssi >= -60) return 5;
    if (rssi >= -70) return 4;
    if (rssi >= -80) return 3;
    if (rssi >= -90) return 2;
    return 1;
  }

  // Выбор, какой наклон САМОГО ТЕЛЕФОНА считать управляющим (см. комментарий
  // в build() у блока Axis). На коробку в обоих случаях уходит одна и та же
  // команда PITCH= - меняется только то, как мы считаем угол из акселерометра.
  // Ось на коробке зависит от того, какой наклон телефона выбран:
  //  Pitch/Roll -> ось 1: прошивка читает wt901Pitch, а его заполняет PITCH=
  //                (подписи осей WT901 исторически перевёрнуты относительно
  //                номеров, поэтому ставим номер явно, а не по названию)
  //  Yaw        -> ось 2: включается штатное слежение за поворотом, данные
  //                берутся из wt901Yaw, который заполняет YAW=
  void _applyPhoneAxis() {
    final axis = _phoneTilt == 2 ? 2 : 1;
    widget.state.wt901Axis = axis;
    widget.bt.send('WT901_AXIS=$axis;');
  }

  Widget _phoneTiltChip(String label, int tiltVal) {
    final selected = _phoneTilt == tiltVal;
    return ElevatedButton(
      onPressed: () {
        setState(() {
          _phoneTilt = tiltVal;
          _phoneFiltInit = false;
          _phoneYaw = 0;          // новый отсчёт поворота
          _compassYaw = 0;        // эталон компаса ведём от той же точки
          _captureTiltRef();      // и наклон - от нынешнего положения телефона
          _applyPhoneAxis();
        });
        _saveAxisPrefs();
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: selected ? Colors.orange : Colors.grey.shade300,
        foregroundColor: selected ? Colors.white : Colors.black,
      ),
      child: Text(label),
    );
  }

  Widget _axisChip(String label, int axisVal) {
    final s = widget.state;
    final bt = widget.bt;
    final selected = s.wt901Axis == axisVal;
    return ElevatedButton(
      onPressed: () {
        // Запоминаем выбор именно для WT901: у телефона своя ось (_phoneTilt),
        // и при переключении источников каждый должен вернуться к своей.
        _wt901Axis = axisVal;
        _saveAxisPrefs();
        setState(() => s.wt901Axis = axisVal);
        bt.send('WT901_AXIS=$axisVal;');
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: selected ? Colors.orange : Colors.grey.shade300,
        foregroundColor: selected ? Colors.white : Colors.black,
      ),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final bt = widget.bt;
    final enabled = s.wt901Enabled;

    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Gyro360 remote'),

      // Источник управления: физический пульт WT901 / выключено / телефон.
      // Все настройки ниже (мёртвая зона, обе скорости, ось, реверс, ноль)
      // общие - ротатору всё равно, кто прислал угол: WT901 по своему BLE
      // или телефон командой PITCH=. Поэтому источник выбирается тут, а
      // настраивается всё одним и тем же набором полей.
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          const Text('Control source', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<RemoteSource>(
            segments: const [
              // Подпись 'Gyro360' вместо 'WT901': заводское имя датчика владельцу
              // ничего не говорит. Полное 'Gyro360 remote' в кнопку из трёх
              // сегментов не помещается - оно вынесено в заголовок страницы.
              ButtonSegment(value: RemoteSource.wt901,
                  label: Text('Gyro360\nremote', textAlign: TextAlign.center),
                  icon: Icon(Icons.settings_remote)),
              ButtonSegment(value: RemoteSource.off,   label: Text('Off'),   icon: Icon(Icons.power_settings_new)),
              ButtonSegment(value: RemoteSource.phone, label: Text('Phone'), icon: Icon(Icons.smartphone)),
            ],
            selected: {_source},
            onSelectionChanged: (sel) => _setSource(sel.first),
            showSelectedIcon: false,
            // В оранжевом стиле, как остальные активные элементы приложения
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((st) =>
                  st.contains(WidgetState.selected) ? Colors.orange : Colors.grey.shade300),
              foregroundColor: WidgetStateProperty.resolveWith((st) =>
                  st.contains(WidgetState.selected) ? Colors.white : Colors.black),
            ),
          ),
          if (_source == RemoteSource.phone) ...[
            const Divider(),
            // Поворот вокруг вертикали не на что опереть, кроме магнитометра -
            // без него остаток смещения гироскопа копится и Yaw уползает. Но
            // рядом с ротатором железа и мотор, поле там искажено, поэтому
            // компас должно быть можно выключить и вернуться к гироскопу.
            _miniSwitch('Compass correction for Yaw', _useCompass, (v) {
              setState(() {
                _useCompass = v;
                // Начинаем эталон от текущего угла, иначе накопленное за
                // время выключения расхождение поехало бы выбираться
                // поправкой.
                _compassYaw = _phoneYaw;
                _haveCompass = false;
              });
              _saveAxisPrefs();
              // Пересоздаём подписку: набор датчиков зависит от флага.
              if (_source == RemoteSource.phone) {
                _applySourceLocal(RemoteSource.phone);
              }
            }),
            // Наклон телефона мешает его же системным функциям: вбок - ловится
            // автоповорот и интерфейс переворачивается прямо во время работы,
            // а погасший экран останавливает поток с датчиков.
            _miniSwitch('Lock screen rotation', _lockRotation, (v) {
              setState(() => _lockRotation = v);
              _applyScreenPrefs();
              _saveAxisPrefs();
            }),
            _miniSwitch('Keep screen on', _keepAwake, (v) {
              setState(() => _keepAwake = v);
              _applyScreenPrefs();
              _saveAxisPrefs();
            }),
          ],
        ]),
      ),

      // Всё остальное — неактивно если выключено
      AnimatedOpacity(
        opacity: enabled ? 1.0 : 0.35,
        duration: const Duration(milliseconds: 300),
        child: IgnorePointer(
          ignoring: !enabled,
          child: Column(children: [

            // Выбор оси датчика (Roll/Pitch/Yaw, взаимоисключающе) + реверс
            // для каждой оси (активен только когда эта ось выбрана). Roll и
            // Pitch работают как джойстик с мёртвой зоной и скоростью (ниже),
            // Yaw — как слежение за компасом (BNO085), скорость там считается
            // ротатором автоматически, поэтому блок Settings под ним гасится.
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                const Text('Axis', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                // В режиме телефона выбор осей WT901 не подходит: их подписи
                // намеренно перевёрнуты под ориентацию физического пульта, а
                // телефон держат иначе. Вместо этого даём выбрать, КАКОЙ
                // наклон самого телефона считать управляющим; ось на коробке
                // подставляется автоматически (см. _applyPhoneAxis).
                // Порядок кнопок тот же, что у WT901 (Roll/Pitch/Yaw), хотя
                // значения за ними другие - чтобы при смене источника кнопки
                // не прыгали местами.
                if (_source == RemoteSource.phone)
                  Row(children: [
                    Expanded(child: _phoneTiltChip('Roll', 1)),
                    const SizedBox(width: 8),
                    Expanded(child: _phoneTiltChip('Pitch', 0)),
                    const SizedBox(width: 8),
                    Expanded(child: _phoneTiltChip('Yaw', 2)),
                  ])
                else
                Row(children: [
                  Expanded(child: _axisChip('Roll', 1)),
                  const SizedBox(width: 8),
                  Expanded(child: _axisChip('Pitch', 0)),
                  const SizedBox(width: 8),
                  Expanded(child: _axisChip('Yaw', 2)),
                ]),
                const SizedBox(height: 8),
                if (s.wt901Axis != 2)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      // В режиме телефона ноль - это ОПОРНОЕ ПОЛОЖЕНИЕ, от
                      // которого считается наклон, и живёт оно в приложении.
                      // Команду на коробку слать нельзя: её ноль общий с WT901,
                      // и мы бы затёрли калибровку физического пульта.
                      onPressed: () {
                        if (_source == RemoteSource.phone && _haveAttitude) {
                          setState(_captureTiltRef);
                        } else {
                          bt.send('WT901_ZERO=1;');
                        }
                      },
                      icon: const Icon(Icons.adjust),
                      label: const Text('ZERO CURRENT AXIS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                // Показания живут здесь, под кнопкой нуля, а не в блоке выбора
                // источника: смотрят на них, когда уже выбрана ось и задан
                // ноль, а наверху они только отодвигали всё остальное вниз.
                if (_source == RemoteSource.phone) ...[
                  const SizedBox(height: 8),
                  Text(_phoneTilt == 2 ? 'rotation since Yaw selected' : 'tilt from center',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                  // Целые градусы: десятые всё равно дрожат и читать их неудобно
                  Text('${_phoneShownOut.round()}°',
                      style: TextStyle(
                        fontSize: 48, fontWeight: FontWeight.bold,
                        color: _phoneTilt == 2
                            ? Colors.orange
                            : (_phoneShownOut.abs() < s.wt901DeadZone ? Colors.grey : Colors.orange),
                      )),
                  if (_phoneTilt != 2)
                    Text(
                      _phoneShownOut.abs() < s.wt901DeadZone
                          ? 'in dead zone — motor stopped'
                          : 'outside dead zone — motor runs',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    )
                  else
                    Text(
                      _useCompass
                          ? 'Works in OFF mode only.'
                          : 'Works in OFF mode only. Gyro-only — re-select Yaw to reset.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                ],
                const SizedBox(height: 8),
                // Показываем реверс ТОЛЬКО для выбранной оси: три строки, из
                // которых две всегда неактивны, зря растягивали страницу.
                // У телефона своя ось и свой реверс (наклон в любом случае
                // уходит командой PITCH=, то есть на коробке всегда ось 1 -
                // осевые переключатели WT901 к нему неприменимы).
                if (_source == RemoteSource.phone && _phoneTilt == 0)
                  _switchRow('Reverse Pitch', _phoneRevPitch, (v) {
                      setState(() => _phoneRevPitch = v);
                      _saveAxisPrefs();
                    }, hPad: 0)
                else if (_source == RemoteSource.phone && _phoneTilt == 1)
                  _switchRow('Reverse Roll', _phoneRevRoll, (v) {
                      setState(() => _phoneRevRoll = v);
                      _saveAxisPrefs();
                    }, hPad: 0)
                else if (s.wt901Axis == 1)
                  _switchRow('Reverse Roll', s.wt901PitchReverse,
                      (v) { setState(() => s.wt901PitchReverse = v); bt.send('WT901_PITCH_REV=${v ? 1 : 0};'); }, hPad: 0)
                else if (s.wt901Axis == 0)
                  _switchRow('Reverse Pitch', s.wt901RollReverse,
                      (v) { setState(() => s.wt901RollReverse = v); bt.send('WT901_ROLL_REV=${v ? 1 : 0};'); }, hPad: 0)
                else
                  _switchRow('Reverse Yaw', s.wt901YawReverse,
                      (v) { setState(() => s.wt901YawReverse = v); bt.send('WT901_YAW_REV=${v ? 1 : 0};'); }, hPad: 0),
                // Слежение за Yaw работает ТОЛЬКО в режиме OFF - при включённом
                // встроенном гироскопе оно молча ничего не делает. Этот режим
                // гасит гироскоп на время работы Yaw и возвращает обратно.
                // Настройка живёт в прошивке, поэтому касается и WT901, и
                // телефона, и видна на веб-странице.
                if (s.wt901Axis == 2)
                  _miniSwitch('Auto-off built-in gyro for Yaw', s.yawAutoGyro, (v) {
                    setState(() => s.yawAutoGyro = v);
                    bt.send('YAW_AUTO_GYRO=${v ? 1 : 0};');
                  }),
                // Алгоритм САМОГО ДАТЧИКА: 9 осей - курс считается с
                // магнитометром и не уползает, но зависит от железа рядом;
                // 6 осей - чистое интегрирование, железу безразлично, зато
                // медленно дрейфует. Команду датчику шлёт коробка: подключена
                // к нему она, второго подключения он не примет.
                //
                // Показываем не то, что просили, а что ответил сам датчик:
                // -1 значит он ещё не отозвался (например, не подключён).
                if (_source == RemoteSource.wt901 && s.wt901SensorAxis >= 0)
                  _miniSwitch('Sensor: 9-axis (magnetometer)',
                      s.wt901SensorAxis == 0, (v) {
                    bt.send('WT901_SENSOR_AXIS=${v ? 0 : 1};');
                  }),
              ]),
            ),


            // Настройки
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                if (s.wt901Axis == 2)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Yaw follows heading automatically — speed below is not used',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontStyle: FontStyle.italic)),
                  ),
                const SizedBox(height: 8),
                AnimatedOpacity(
                  opacity: s.wt901Axis == 2 ? 0.35 : 1.0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: s.wt901Axis == 2,
                    child: Column(children: [
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('Dead zone (°):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_deadVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _deadVal, min: 0, max: 45, divisions: 45, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() { _draggingSlider = true; _deadVal = v; }),
                    onChangeEnd: (v) { _draggingSlider = false; s.wt901DeadZone = v; bt.send('WT901_DEAD=${v.toStringAsFixed(1)};'); }),
                ])),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('Speed (rpm):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_speedVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _speedVal, min: 1, max: 15, divisions: 14, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() { _draggingSlider = true; _speedVal = v; }),
                    onChangeEnd: (v) { _draggingSlider = false; s.wt901Speed = v.round(); bt.send('WT901_SPEED=${v.round()};'); }),
                ])),
                _switchRow('2nd speed:', s.wt901Speed2Enabled, (v) {
                  setState(() => s.wt901Speed2Enabled = v);
                  bt.send('WT901_SPEED2_EN=${v ? 1 : 0};');
                }),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('2nd speed angle (°):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_speed2AngleVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _speed2AngleVal, min: 0, max: 90, divisions: 90, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() { _draggingSlider = true; _speed2AngleVal = v; }),
                    onChangeEnd: (v) { _draggingSlider = false; s.wt901Speed2Angle = v; bt.send('WT901_SPEED2_ANGLE=${v.toStringAsFixed(1)};'); }),
                ])),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('2nd speed (rpm):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_speed2Val.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _speed2Val, min: 1, max: 25, divisions: 24, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() { _draggingSlider = true; _speed2Val = v; }),
                    onChangeEnd: (v) { _draggingSlider = false; s.wt901Speed2 = v.round(); bt.send('WT901_SPEED2=${v.round()};'); }),
                ])),
                    ]),
                  ),
                ),
              ]),
            ),

            // Блок подключения WT901 - в режиме "Телефон" не нужен вовсе:
            // источник наклона тогда сам телефон, привязывать нечего.
            if (_source != RemoteSource.phone)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _connectedMac != null ? Colors.green : Colors.grey.shade400,
                  width: 2,
                ),
              ),
              child: Column(children: [
                Row(children: [
                  Icon(Icons.sensors, color: _connectedMac != null ? Colors.green : Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    _connectedMac != null ? 'Paired: $_connectedName' : 'Remote: not paired',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _connectedMac != null ? Colors.green.shade800 : Colors.grey.shade700,
                    ),
                  )),
                  if (_connectedMac != null)
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.red, size: 20),
                      onPressed: _confirmDisconnect,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ]),
                // Привязка нужна редко - раз настроил и забыл, - а список
                // занимал полэкрана постоянно. Прячем его под кнопку; строка
                // с уже привязанным датчиком остаётся видна всегда.
                SizedBox(
                  height: 30,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _showPairing = !_showPairing);
                      // Скан запускаем в момент раскрытия, а не при входе на
                      // страницу: он занимает радио, которое нужно управлению.
                      if (_showPairing) _startScan();
                      if (!_showPairing) _stopScan();
                    },
                    icon: Icon(_showPairing ? Icons.expand_less : Icons.expand_more, size: 20),
                    label: Text(_showPairing ? 'Hide' : 'Pair / change sensor',
                        style: const TextStyle(fontSize: 13)),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                  ),
                ),

                // Список найденных устройств (скан со стороны телефона). На
                // iOS CoreBluetooth не отдаёт настоящий MAC-адрес стороннему
                // приложению (per-app случайный UUID вместо него), поэтому
                // сканирование на iPhone принципиально невозможно - вместо
                // списка показываем поле ручного ввода (тот же MAC, отправка
                // идёт обычной BLE-записью, сканирование тут не нужно).
                if (_showPairing) ...[
                  Row(children: [
                    const Expanded(child: Text('Nearby devices:', style: TextStyle(fontWeight: FontWeight.bold))),
                    if (_scanning)
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: _startScan,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ]),
                  const SizedBox(height: 4),
                  if (_scanResults.isEmpty && !_scanning)
                    Text('Press refresh to scan', style: TextStyle(color: Colors.grey.shade600, fontSize: 13))
                  else
                    ..._scanResults.values.map((r) {
                      // Сравниваем по адресу ИЗ ИМЕНИ: remoteId на iPhone -
                      // случайный UUID, и с сохранённым MAC он не совпадёт.
                      final isSelected = _macFromName(_advName(r)) == _connectedMac;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.sensors, color: isSelected ? Colors.green : const Color(0xFF546E7A)),
                        title: Text(_remoteDisplayName,
                            style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                        // Адрес не показываем: он и так внутри имени, а на
                        // экране от него никакой пользы - выбирать всё равно
                        // по названию.
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          _SignalBars(_rssiBars(r.rssi)),
                          const SizedBox(width: 8),
                          if (isSelected)
                            const Icon(Icons.check_circle, color: Colors.green, size: 20)
                          else
                            ElevatedButton(
                              onPressed: () => _selectDevice(r),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey.shade300,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                              ),
                              child: const Text('Select', style: TextStyle(fontSize: 12)),
                            ),
                        ]),
                      );
                    }),
                ],
              ]),
            ),

          ]),
        ),
      ),
    ]));
  }
}

// ─── Firmware Page ────────────────────────────────────────────────────────────
class _FirmwarePage extends StatefulWidget {
  final AppState state; final BtManager bt;
  const _FirmwarePage({required this.state, required this.bt});
  @override State<_FirmwarePage> createState() => _FirmwarePageState();
}

class _FirmwarePageState extends State<_FirmwarePage> {
  bool _busy = false;
  double _progress = 0;   // 0..1, ею же живёт шкала
  String _status = '';    // строка состояния, по-английски

  void _say(String s, {double? p}) {
    if (!mounted) return;
    setState(() { _status = s; if (p != null) _progress = p; });
  }

  // Текст исключения из http содержит полный адрес запроса - вместе с
  // токеном. Показывать его нельзя: один раз он уже оказался на экране во
  // всю ширину. Наружу отдаём только суть, подробности незачем.
  String _downloadError(Object e) {
    final s = e.toString();
    if (s.contains('Failed host lookup') || s.contains('SocketException')) {
      return 'No internet connection';
    }
    if (s.contains('TimeoutException')) return 'Server did not respond';
    if (s.contains('HandshakeException') || s.contains('CertificateException')) {
      return 'Secure connection failed';
    }
    return 'Download failed';
  }

  // Прошивку скачивает сам телефон и отдаёт её коробке по BLE. Раньше коробка
  // лезла в интернет сама, для чего ей нужна была точка доступа и ~40-45 КБ
  // единым куском под рукопожатие TLS - на нехватке этой памяти обновление
  // регулярно и срывалось. Теперь TLS остаётся на телефоне.
  Future<void> _update() async {
    if (_busy) return;
    const url = kFirmwareUrl;
    if (!widget.bt.canUpdateOverBle) {
      _say('This rotator firmware has no Bluetooth update channel');
      return;
    }
    setState(() { _busy = true; _progress = 0; _status = 'Downloading firmware...'; });
    try {
      Uint8List image;
      try {
        final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
        if (resp.statusCode != 200) { _say('Download failed: HTTP ${resp.statusCode}', p: 0); return; }
        image = resp.bodyBytes;
      } catch (e) {
        _say(_downloadError(e), p: 0); return;
      }
      if (image.length < 4096) { _say('Downloaded file is not a firmware image', p: 0); return; }

      // Сверяем скачанное с тем, что уже стоит в коробке: она сообщает
      // контрольную сумму работающего образа (ESP.getSketchMD5). Совпало -
      // передавать полтора мегабайта незачем.
      final digest = md5.convert(image).toString();
      if (widget.state.fwMd5.isNotEmpty && widget.state.fwMd5.toLowerCase() == digest.toLowerCase()) {
        _say('Firmware is already up to date', p: 1);
        return;
      }

      await _upload(image, digest);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Передача идёт с окном подтверждений: коробка отвечает BOTA_ACK каждые
  // пару килобайт, и убегать вперёд дальше окна нельзя. Без этого телефон
  // засыпал бы её пакетами быстрее, чем она успевает писать во флеш (запись
  // на границе сектора блокирует на десятки миллисекунд), и куски терялись бы
  // молча - запись без подтверждения ничего не сообщает отправителю.
  Future<void> _upload(Uint8List image, String digest) async {
    int acked = 0;
    int window = 4096;
    String? error;
    bool done = false;
    final ready = Completer<void>();

    final sub = widget.bt.dataStream.listen((line) {
      final s = line.trim();
      if (s.startsWith('BOTA_READY=')) {
        window = int.tryParse(s.substring(11)) ?? window;
        if (!ready.isCompleted) ready.complete();
      } else if (s.startsWith('BOTA_ACK=')) {
        acked = int.tryParse(s.substring(9)) ?? acked;
      } else if (s == 'BOTA_DONE') {
        done = true;
      } else if (s.startsWith('BOTA_ERR=')) {
        error ??= s.substring(9);
      } else if (s == '__DISCONNECTED__') {
        error ??= 'connection lost';
      }
    });

    try {
      _say('Preparing rotator...', p: 0);
      await widget.bt.send('BOTA_BEGIN=${image.length},$digest');
      try {
        await ready.future.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        _say(error ?? 'Rotator did not respond', p: 0);
        return;
      }
      if (error != null) { _say(error!, p: 0); return; }

      final chunk = widget.bt.otaChunkSize;
      int sent = 0;
      int shownPct = -1;
      int lastAcked = 0;
      var lastMove = DateTime.now();

      while (sent < image.length) {
        if (error != null) { _say(error!); return; }
        if (sent - acked >= window) {          // упёрлись в окно, ждём подтверждения
          if (acked != lastAcked) { lastAcked = acked; lastMove = DateTime.now(); }
          if (DateTime.now().difference(lastMove) > const Duration(seconds: 20)) {
            _say('Transfer stalled'); return;
          }
          await Future.delayed(const Duration(milliseconds: 4));
          continue;
        }
        lastAcked = acked; lastMove = DateTime.now();
        final end = (sent + chunk > image.length) ? image.length : sent + chunk;
        try {
          await widget.bt.sendOtaChunk(image.sublist(sent, end));
        } catch (_) {
          _say('Send failed'); return;
        }
        sent = end;
        // Проценты считаем по подтверждённому, а не по отправленному: шкала
        // должна показывать записанное во флеш, иначе она добежала бы до
        // конца заметно раньше самой прошивки.
        final pct = acked * 100 ~/ image.length;
        if (pct != shownPct) {
          shownPct = pct;
          _say('Uploading to rotator... $pct%', p: acked / image.length);
        }
      }

      await widget.bt.send('BOTA_END');
      _say('Finishing...', p: 1);
      // Коробка досчитывает контрольную сумму и переключает загрузочный слот.
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!done && error == null && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // Порядок проверок важен: сразу за подтверждением коробка уходит в
      // перезагрузку, и связь рвётся - обрыв тут означает успех, а не сбой.
      if (done) {
        _say('Update complete. Rotator is rebooting.', p: 1);
      } else {
        _say(error ?? 'No confirmation from rotator', p: 1);
      }
    } finally {
      await sub.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Firmware page'),
      const SizedBox(height: 32),
      ElevatedButton(
        onPressed: _busy ? null : _update,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12)),
        child: const Text('Update', style: TextStyle(fontSize: 16)),
      ),
      const SizedBox(height: 20),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(_status.isEmpty ? 'Ready' : _status,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.black87)),
      ),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _progress, minHeight: 14,
              backgroundColor: Colors.grey.shade300,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF546E7A)),
            ),
          ),
          const SizedBox(height: 6),
          Text('${(_progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 13, color: Colors.black54)),
        ]),
      ),
      const SizedBox(height: 20),
    ]));
  }
}
