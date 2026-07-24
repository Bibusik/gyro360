import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wifi_scan/wifi_scan.dart';

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

// ─── BLE GATT Manager (Nordic UART Service) ───────────────────────────────────
class BtManager {
  static final BtManager _instance = BtManager._();
  factory BtManager() => _instance;
  BtManager._();

  static final Guid _serviceUuid = Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  static final Guid _rxCharUuid  = Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E'); // телефон -> ESP32
  static final Guid _txCharUuid  = Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E'); // ESP32 -> телефон

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar; // write
  BluetoothCharacteristic? _txChar; // notify
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

  Future<void> disconnect() async {
    _notifySub?.cancel();
    _connSub?.cancel();
    try { await _device?.disconnect(); } catch (_) {}
    _device = null;
    _rxChar = null;
    _txChar = null;
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

  void parseData(String data) {
    final parts = data.split(';');
    for (final part in parts) {
      if (!part.contains('=')) continue;
      final kv = part.split('=');
      if (kv.length < 2) continue;
      final k = kv[0].trim();
      final v = kv[1].trim();
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
        case 'SEARCH_MSEC': searchMsec = int.tryParse(v) ?? searchMsec;
        case 'CH_1': if (int.tryParse(v) != null) chFunctions[0] = chOptions[int.parse(v)];
        case 'CH_2': if (int.tryParse(v) != null) chFunctions[1] = chOptions[int.parse(v)];
        case 'CH_3': if (int.tryParse(v) != null) chFunctions[2] = chOptions[int.parse(v)];
        case 'CH_4': if (int.tryParse(v) != null) chFunctions[3] = chOptions[int.parse(v)];
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
    setState(() {});
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
              _NavBtn(icon: Icons.settings_input_component, index: 1, current: pageIndex, onTap: onPageChanged),
              _NavBtn(icon: Icons.explore,                 index: 2, current: pageIndex, onTap: onPageChanged),
              _NavBtn(icon: Icons.directions_walk,         index: 3, current: pageIndex, onTap: onPageChanged),
              _NavBtn(icon: Icons.radio,                   index: 4, current: pageIndex, onTap: onPageChanged),
              _NavBtn(icon: Icons.sensors,                 index: 5, current: pageIndex, onTap: onPageChanged),
              _NavBtn(icon: Icons.system_update,           index: 6, current: pageIndex, onTap: onPageChanged),
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
  const _NavBtn({required this.icon, required this.index, required this.current, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final active = index == current;
    return GestureDetector(
      onTap: () => onTap(index),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: active ? Colors.white : Colors.white24, borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: active ? const Color(0xFF546E7A) : Colors.white, size: 22),
      ),
    );
  }
}

// ─── Page helpers ─────────────────────────────────────────────────────────────
Widget _pageTitle(String title) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 12),
  child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
      _row('Reverse gyro:', Switch(value: s.gyroReverse, onChanged: (v) { setState(() => s.gyroReverse = v); bt.send('GYRO_REV=${v ? 1 : 0};'); })),
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
      _row('Auto switch:', Switch(value: s.gyro6axis, onChanged: (v) { setState(() => s.gyro6axis = v); bt.send('LIFT_FUNC=${v ? 1 : 0};'); })),
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

  @override
  Widget build(BuildContext context) {
    final s = widget.state; final bt = widget.bt;
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Pedal page'),
      _row('Keep search pos:', Switch(value: s.keepSearchPos, onChanged: (v) { setState(() => s.keepSearchPos = v); bt.send('SAVE_POS=${v ? 1 : 0};'); })),
      _row('Reverse Wire Pedal:', Switch(value: s.reverseWire, onChanged: (v) { setState(() => s.reverseWire = v); bt.send('PEDAL_WIRE_REV=${v ? 1 : 0};'); })),
      _row('Reverse WiFi Pedal:', Switch(value: s.reverseWifi, onChanged: (v) { setState(() => s.reverseWifi = v); bt.send('PEDAL_WIFI_REV=${v ? 1 : 0};'); })),
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

  // BLE сканирование для WT901 / маяка Remoute2ble
  final Map<String, ScanResult> _scanResults = {};
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _scanSub;
  String? _connectedMac;   // MAC выбранного устройства
  String? _connectedName;

  // Скан со стороны коробки (BLE-central на ESP32) - работает и на iPhone,
  // где приложение не может получить настоящий MAC датчика (см. WT901_SCAN).
  List<Map<String, dynamic>> _boxScanResults = [];
  bool _boxScanning = false;
  StreamSubscription<String>? _boxScanSub;

  @override
  void initState() {
    super.initState();
    _deadVal = widget.state.wt901DeadZone.clamp(0.0, 45.0);
    _speedVal = widget.state.wt901Speed.toDouble().clamp(1.0, 15.0);
    _speed2AngleVal = widget.state.wt901Speed2Angle.clamp(0.0, 90.0);
    _speed2Val = widget.state.wt901Speed2.toDouble().clamp(1.0, 25.0);
    _syncConnectedFromState();
    widget.state.addListener(_onStateChange);
    _startScan();
    _boxScanSub = widget.bt.dataStream.listen((data) {
      final trimmed = data.trim();
      if (trimmed.startsWith('WT901_FOUND=')) {
        _onBoxScanResult(trimmed.substring('WT901_FOUND='.length));
      }
    });
  }

  void _onBoxScanResult(String json) {
    if (!mounted) return;
    setState(() {
      _boxScanning = false;
      try {
        _boxScanResults = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      } catch (_) {
        _boxScanResults = [];
      }
    });
  }

  void _startBoxScan() {
    setState(() { _boxScanning = true; _boxScanResults = []; });
    widget.bt.send('WT901_SCAN=1;');
    // Скан на роторе блокирующий (~4с) - подстрахуем таймаутом на случай,
    // если BLE-notify с результатом потеряется (слабый сигнал).
    Future.delayed(const Duration(seconds: 7), () {
      if (mounted && _boxScanning) setState(() => _boxScanning = false);
    });
  }

  void _selectBoxDevice(Map<String, dynamic> d) {
    final mac = d['mac'] as String;
    setState(() {
      _connectedMac = mac;
      _connectedName = mac;
      _boxScanResults = [];
    });
    widget.bt.send('WT901_MAC=$mac;');
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
      _connectedName = mac; // пока не пересканировали — показываем сам MAC
    }
  }

  void _onStateChange() {
    _deadVal = widget.state.wt901DeadZone.clamp(0.0, 45.0);
    _speedVal = widget.state.wt901Speed.toDouble().clamp(1.0, 15.0);
    _speed2AngleVal = widget.state.wt901Speed2Angle.clamp(0.0, 90.0);
    _speed2Val = widget.state.wt901Speed2.toDouble().clamp(1.0, 25.0);
    _syncConnectedFromState();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    _scanSub?.cancel();
    _boxScanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  void _startScan() {
    setState(() { _scanning = true; _scanResults.clear(); });
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        // Не показываем сам ротор (GYRO360) — это другое устройство/протокол
        if (r.device.platformName.isNotEmpty && r.device.platformName != 'GYRO360') {
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
    _stopScan();
    setState(() {
      _connectedMac  = r.device.remoteId.str;
      _connectedName = r.device.platformName.isNotEmpty ? r.device.platformName : r.device.remoteId.str;
    });
    // Отправляем MAC на ротатор
    widget.bt.send('WT901_MAC=${r.device.remoteId.str};');
  }

  void _disconnectDevice() {
    setState(() { _connectedMac = null; _connectedName = null; });
    widget.bt.send('WT901_MAC=;');
  }

  int _rssiBars(int? rssi) {
    if (rssi == null) return 1;
    if (rssi >= -60) return 5;
    if (rssi >= -70) return 4;
    if (rssi >= -80) return 3;
    if (rssi >= -90) return 2;
    return 1;
  }

  Widget _axisChip(String label, int axisVal) {
    final s = widget.state;
    final bt = widget.bt;
    final selected = s.wt901Axis == axisVal;
    return ElevatedButton(
      onPressed: () {
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

  Widget _axisReverseRow(String label, int axisVal, bool value, String cmd, void Function(bool) setter) {
    final s = widget.state;
    final bt = widget.bt;
    final active = s.wt901Axis == axisVal;
    return Opacity(
      opacity: active ? 1.0 : 0.4,
      child: IgnorePointer(
        ignoring: !active,
        child: _row(label, Switch(
          value: value,
          onChanged: (v) {
            setState(() => setter(v));
            bt.send('$cmd=${v ? 1 : 0};');
          },
        )),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final bt = widget.bt;
    final enabled = s.wt901Enabled;

    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Rod Remote'),

      // Переключатель — всегда активен
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
        child: _row('Enable remote:', Switch(
          value: enabled,
          onChanged: (v) {
            setState(() => s.wt901Enabled = v);
            bt.send('WT901_ENABLED=${v ? 1 : 0};');
            if (!v) { _stopScan(); _connectedMac = null; _connectedName = null; }
          },
        )),
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
                      onPressed: () => bt.send('WT901_ZERO=1;'),
                      icon: const Icon(Icons.adjust),
                      label: const Text('ZERO CURRENT AXIS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                _axisReverseRow('Reverse Roll', 1, s.wt901PitchReverse, 'WT901_PITCH_REV', (v) => s.wt901PitchReverse = v),
                _axisReverseRow('Reverse Pitch', 0, s.wt901RollReverse, 'WT901_ROLL_REV', (v) => s.wt901RollReverse = v),
                _axisReverseRow('Reverse Yaw', 2, s.wt901YawReverse, 'WT901_YAW_REV', (v) => s.wt901YawReverse = v),
              ]),
            ),

            // Блок подключения WT901
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
                    _connectedMac != null ? 'Rod Remote: $_connectedName' : 'Rod Remote: not selected',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _connectedMac != null ? Colors.green.shade800 : Colors.grey.shade700,
                    ),
                  )),
                  if (_connectedMac != null)
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.red, size: 20),
                      onPressed: _disconnectDevice,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ]),
                const SizedBox(height: 8),

                // Список найденных устройств
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
                    final isSelected = r.device.remoteId.str == _connectedMac;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.sensors, color: isSelected ? Colors.green : const Color(0xFF546E7A)),
                      title: Text(r.device.platformName.isNotEmpty ? r.device.platformName : r.device.remoteId.str,
                          style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                      subtitle: Text(r.device.remoteId.str, style: const TextStyle(fontSize: 11)),
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

                const Divider(),

                // Скан со стороны коробки - не зависит от того, отдаёт ли
                // телефон настоящий MAC (на iPhone обычный скан выше видит
                // только случайный UUID, см. WT901_SCAN на прошивке).
                Row(children: [
                  const Expanded(child: Text('Scan on rotator (iPhone-safe):', style: TextStyle(fontWeight: FontWeight.bold))),
                  if (_boxScanning)
                    const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    IconButton(
                      icon: const Icon(Icons.travel_explore, size: 20),
                      onPressed: _startBoxScan,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ]),
                const SizedBox(height: 4),
                if (_boxScanResults.isEmpty && !_boxScanning)
                  Text('Rotator scans for the sensor itself — works on iPhone too', style: TextStyle(color: Colors.grey.shade600, fontSize: 13))
                else
                  ..._boxScanResults.map((d) {
                    final mac = d['mac'] as String;
                    final rssi = d['rssi'] as int? ?? 0;
                    final isSelected = mac == _connectedMac;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.sensors, color: isSelected ? Colors.green : const Color(0xFF546E7A)),
                      title: Text(mac, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 14)),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        _SignalBars(_rssiBars(rssi)),
                        const SizedBox(width: 8),
                        if (isSelected)
                          const Icon(Icons.check_circle, color: Colors.green, size: 20)
                        else
                          ElevatedButton(
                            onPressed: () => _selectBoxDevice(d),
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
                    onChanged: (v) => setState(() => _deadVal = v),
                    onChangeEnd: (v) { s.wt901DeadZone = v; bt.send('WT901_DEAD=${v.toStringAsFixed(1)};'); }),
                ])),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('Speed (rpm):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_speedVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _speedVal, min: 1, max: 15, divisions: 14, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() => _speedVal = v),
                    onChangeEnd: (v) { s.wt901Speed = v.round(); bt.send('WT901_SPEED=${v.round()};'); }),
                ])),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: _row('2nd speed:', Switch(
                  value: s.wt901Speed2Enabled,
                  onChanged: (v) {
                    setState(() => s.wt901Speed2Enabled = v);
                    bt.send('WT901_SPEED2_EN=${v ? 1 : 0};');
                  },
                ))),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('2nd speed angle (°):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_speed2AngleVal.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _speed2AngleVal, min: 0, max: 90, divisions: 90, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() => _speed2AngleVal = v),
                    onChangeEnd: (v) { s.wt901Speed2Angle = v; bt.send('WT901_SPEED2_ANGLE=${v.toStringAsFixed(1)};'); }),
                ])),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: [
                  Row(children: [
                    const Text('2nd speed (rpm):', style: TextStyle(fontSize: 16)),
                    const Spacer(),
                    Text('${_speed2Val.round()}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ]),
                  Slider(value: _speed2Val, min: 1, max: 25, divisions: 24, activeColor: Colors.orange, allowedInteraction: SliderInteraction.slideThumb,
                    onChanged: (v) => setState(() => _speed2Val = v),
                    onChangeEnd: (v) { s.wt901Speed2 = v.round(); bt.send('WT901_SPEED2=${v.round()};'); }),
                ])),
                    ]),
                  ),
                ),
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
  late TextEditingController _ssid, _pass, _url;
  final _ssidFocus = FocusNode(), _passFocus = FocusNode(), _urlFocus = FocusNode();
  StreamSubscription<List<WiFiAccessPoint>>? _wifiSub;
  List<MapEntry<String, int>> _nets = [];
  bool _scanningWifi = false;

  @override
  void initState() {
    super.initState();
    _ssid = TextEditingController(text: widget.state.ssid);
    _pass = TextEditingController(text: widget.state.pass);
    _url  = TextEditingController(text: widget.state.url);
    // Кнопки Send убраны — поля отправляют значение сами, как только
    // теряют фокус (тап в другое место/скрытие клавиатуры).
    _ssidFocus.addListener(() { if (!_ssidFocus.hasFocus) widget.bt.send('SSID=${_ssid.text};'); });
    _passFocus.addListener(() { if (!_passFocus.hasFocus) widget.bt.send('PASS=${_pass.text};'); });
    _urlFocus.addListener(() { if (!_urlFocus.hasFocus) widget.bt.send('URL=${_url.text};'); });
    widget.state.addListener(_onStateChange);
  }

  // Страница создаётся один раз при старте приложения (IndexedStack держит
  // все страницы смонтированными), а значения SSID/PASS/URL с ротатора
  // приходят позже (после READ_ALL при подключении) — без этого слушателя
  // поля так и оставались пустыми, даже когда на роторе что-то сохранено.
  // Не трогаем поле, если пользователь сейчас его редактирует.
  void _onStateChange() {
    final s = widget.state;
    if (!_ssidFocus.hasFocus && _ssid.text != s.ssid) _ssid.text = s.ssid;
    if (!_passFocus.hasFocus && _pass.text != s.pass) _pass.text = s.pass;
    if (!_urlFocus.hasFocus  && _url.text  != s.url)  _url.text  = s.url;
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    _wifiSub?.cancel();
    _ssidFocus.dispose(); _passFocus.dispose(); _urlFocus.dispose();
    _ssid.dispose(); _pass.dispose(); _url.dispose();
    super.dispose();
  }

  // Сканируем WiFi-сети самим телефоном (как в web — там браузер тоже
  // просто отображает список, доступный устройству, с которого смотрят
  // страницу), а не ротатором: у ротатора и так одна антенна на WiFi+BLE,
  // и WiFi.scanNetworks() на его стороне на 1-3+ секунды блокировал радио,
  // из-за чего активное BLE-соединение с телефоном успевало оборваться.
  Future<void> _scanWifi() async {
    setState(() { _scanningWifi = true; _nets = []; });
    final granted = await [Permission.locationWhenInUse, Permission.nearbyWifiDevices].request();
    if (granted[Permission.locationWhenInUse]?.isGranted != true) {
      if (mounted) setState(() => _scanningWifi = false);
      return;
    }
    final can = await WiFiScan.instance.canStartScan();
    if (can != CanStartScan.yes) {
      if (mounted) setState(() => _scanningWifi = false);
      return;
    }
    await WiFiScan.instance.startScan();
    _wifiSub?.cancel();
    _wifiSub = WiFiScan.instance.onScannedResultsAvailable.listen((results) {
      final nets = <String, int>{};
      for (final r in results) {
        if (r.ssid.isEmpty) continue;
        if (!nets.containsKey(r.ssid) || nets[r.ssid]! < r.level) nets[r.ssid] = r.level;
      }
      final list = nets.entries.map((e) => MapEntry(e.key, e.value)).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (mounted) setState(() { _nets = list; _scanningWifi = false; });
      // Скан одноразовый: подписка на этот стрим иначе продолжает жить и
      // подсовывает список повторно при следующем системном скане (даже
      // не нашем), из-за чего он "всплывал" сам по себе.
      _wifiSub?.cancel();
      _wifiSub = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bt = widget.bt;
    return SingleChildScrollView(child: Column(children: [
      _pageTitle('Firmware page'),
      _fieldRow('AP name:', _ssid, _ssidFocus),
      _fieldRow('Password:', _pass, _passFocus, obscure: true),
      _fieldRow('Server URL:', _url, _urlFocus),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: SizedBox(width: double.infinity, child: ElevatedButton.icon(
          icon: _scanningWifi
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_find),
          label: Text(_scanningWifi ? 'Scanning...' : 'Scan nearby networks'),
          onPressed: _scanningWifi ? null : _scanWifi,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 10)),
        )),
      ),
      if (_nets.isNotEmpty)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(12)),
          child: Column(children: _nets.map((n) => ListTile(
            dense: true,
            leading: const Icon(Icons.wifi, color: Color(0xFF546E7A)),
            title: Text(n.key, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            trailing: Text('${n.value} dBm', style: const TextStyle(fontSize: 12)),
            onTap: () {
              setState(() { _ssid.text = n.key; _nets = []; });
              bt.send('SSID=${n.key};');
            },
          )).toList()),
        ),
      const SizedBox(height: 16),
      ElevatedButton(
        onPressed: () async {
          // Поля SSID/PASS/URL шлют своё значение только по потере фокуса
          // (см. addListener выше) - если нажать Update сразу после ввода,
          // не тапнув по другому полю, последняя правка никогда не уходила
          // на коробку. Явно досылаем текущие значения перед самим Update.
          // await между вызовами обязателен - без него более длинная запись
          // (URL с токеном) обрывалась следующим send() раньше, чем BLE-стек
          // успевал её дописать (send() теперь сам ждёт завершения записи).
          await bt.send('SSID=${_ssid.text};');
          await bt.send('PASS=${_pass.text};');
          await bt.send('URL=${_url.text};');
          await bt.send('UPDATE=1;');
        },
        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey.shade300, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12)),
        child: const Text('Update', style: TextStyle(fontSize: 16)),
      ),
      if (widget.state.otaMsg.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(widget.state.otaMsg.replaceFirst('OTA:', '').trim(),
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: Colors.black54)),
        ),
    ]));
  }

  Widget _fieldRow(String label, TextEditingController ctrl, FocusNode focusNode, {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(flex: 2, child: Text(label, style: const TextStyle(fontSize: 16))),
        Expanded(flex: 3, child: TextField(
          controller: ctrl, obscureText: obscure, focusNode: focusNode,
          onSubmitted: (_) => focusNode.unfocus(),
          decoration: InputDecoration(filled: true, fillColor: Colors.yellow, border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)), contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), isDense: true),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        )),
      ]),
    );
  }
}