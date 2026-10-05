import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

void main() => runApp(MaterialApp(
      title: 'GPS LocationSelf',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const Home(),
    ));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Database? db;
  final map = MapController();
  StreamSubscription<Position>? sub;
  Timer? ticker;
  final List<LatLng> pts = [];
  LatLng? cur, last;
  double meters = 0, acc = 0, spd = 0, alt = 0, elapsed = 0;
  int count = 0, nextKm = 1;
  DateTime? t0;
  bool tracking = false, saver = false;
  MbTilesTileProvider? mb;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    db = await openDatabase(p.join(await getDatabasesPath(), 'track.db'),
        version: 1,
        onCreate: (d, _) => d.execute(
            'CREATE TABLE points(id INTEGER PRIMARY KEY AUTOINCREMENT, latitude REAL, longitude REAL, altitude REAL, speed REAL, timestamp INTEGER)'));
    final rows = await db!.query('points', orderBy: 'id');
    for (final r in rows) {
      pts.add(LatLng(r['latitude'] as double, r['longitude'] as double));
    }
    for (var i = 1; i < pts.length; i++) {
      meters += _hav(pts[i - 1], pts[i]);
    }
    count = pts.length;
    nextKm = (meters / 1000).floor() + 1;
    if (pts.isNotEmpty) cur = pts.last;
    elapsed = (await SharedPreferences.getInstance()).getDouble('el') ?? 0;
    final f = File(p.join((await getApplicationDocumentsDirectory()).path, 'offline.mbtiles'));
    if (await f.exists()) mb = MbTilesTileProvider.fromPath(path: f.path);
    if (mounted) setState(() {});
  }

  double _hav(LatLng a, LatLng b) {
    double rad(double x) => x * pi / 180;
    final dLat = rad(b.latitude - a.latitude), dLng = rad(b.longitude - a.longitude);
    final h = pow(sin(dLat / 2), 2) + cos(rad(a.latitude)) * cos(rad(b.latitude)) * pow(sin(dLng / 2), 2);
    return 2 * 6371000.0 * asin(sqrt(h));
  }

  double _total() => elapsed + (t0 == null ? 0 : DateTime.now().difference(t0!).inSeconds);

  void _msg(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _start() async {
    if (!await Geolocator.isLocationServiceEnabled()) return _msg('Aktifkan GPS di pengaturan HP');
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return _msg('Izin lokasi ditolak. Aktifkan di Pengaturan > Aplikasi.');
    }
    await Permission.notification.request();
    final s = AndroidSettings(
      accuracy: saver ? LocationAccuracy.medium : LocationAccuracy.best,
      distanceFilter: saver ? 15 : 5,
      intervalDuration: Duration(seconds: saver ? 10 : 3),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: 'GPS LocationSelf aktif',
        notificationText: 'Merekam lokasi di latar belakang',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
    last = null;
    sub = Geolocator.getPositionStream(locationSettings: s).listen(_onPos);
    t0 = DateTime.now();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    setState(() => tracking = true);
  }

  Future<void> _stop() async {
    await sub?.cancel();
    sub = null;
    ticker?.cancel();
    elapsed = _total();
    t0 = null;
    (await SharedPreferences.getInstance()).setDouble('el', elapsed);
    setState(() => tracking = false);
    _msg('Selesai: ${(meters / 1000).toStringAsFixed(2)} km');
  }

  Future<void> _onPos(Position q) async {
    final c = LatLng(q.latitude, q.longitude);
    setState(() {
      acc = q.accuracy;
      cur = c;
    });
    if (q.accuracy > 20) return; // filter akurasi
    if (last != null) {
      final d = _hav(last!, c);
      if (d < 5 || d > 300) return;
      meters += d;
      if (meters / 1000 >= nextKm) {
        HapticFeedback.heavyImpact();
        _msg('🎯 Kamu sudah menempuh $nextKm km!');
        nextKm++;
      }
    }
    last = c;
    pts.add(c);
    await db!.insert('points', {
      'latitude': q.latitude,
      'longitude': q.longitude,
      'altitude': q.altitude,
      'speed': q.speed,
      'timestamp': q.timestamp.millisecondsSinceEpoch,
    });
    setState(() {
      spd = q.speed * 3.6;
      alt = q.altitude;
      count = pts.length;
    });
    map.move(c, map.camera.zoom);
  }

  Future<void> _reset() async {
    if (tracking) await _stop();
    await db!.delete('points');
    (await SharedPreferences.getInstance()).setDouble('el', 0);
    setState(() {
      pts.clear();
      meters = 0;
      elapsed = 0;
      count = 0;
      nextKm = 1;
      last = null;
    });
  }

  Future<void> _export(bool gpx) async {
    final r = await db!.query('points', orderBy: 'id');
    if (r.isEmpty) return _msg('Belum ada data');
    String iso(Object? t) => DateTime.fromMillisecondsSinceEpoch(t as int, isUtc: true).toIso8601String();
    final s = gpx
        ? '<?xml version="1.0"?>\n<gpx version="1.1" creator="GPS LocationSelf" xmlns="http://www.topografix.com/GPX/1/1"><trk><name>LocationSelf</name><trkseg>\n' +
            r.map((x) => '<trkpt lat="${x['latitude']}" lon="${x['longitude']}"><ele>${x['altitude']}</ele><time>${iso(x['timestamp'])}</time></trkpt>').join('\n') +
            '\n</trkseg></trk></gpx>'
        : jsonEncode({
            'type': 'Feature',
            'properties': {'name': 'LocationSelf', 'km': meters / 1000},
            'geometry': {
              'type': 'LineString',
              'coordinates': r.map((x) => [x['longitude'], x['latitude'], x['altitude']]).toList()
            }
          });
    final f = File(p.join((await getTemporaryDirectory()).path, gpx ? 'trek.gpx' : 'trek.geojson'));
    await f.writeAsString(s);
    await Share.shareXFiles([XFile(f.path)]);
  }

  Future<void> _pickMb() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final src = r?.files.single.path;
    if (src == null) return;
    _msg('Menyalin peta, mohon tunggu...');
    final dst = p.join((await getApplicationDocumentsDirectory()).path, 'offline.mbtiles');
    mb?.dispose();
    await File(src).copy(dst);
    setState(() => mb = MbTilesTileProvider.fromPath(path: dst));
    _msg('Peta offline aktif');
  }

  @override
  void dispose() {
    sub?.cancel();
    ticker?.cancel();
    mb?.dispose();
    super.dispose();
  }

  Widget _s(String v, String l) => Expanded(
          child: Column(children: [
        Text(v, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(l, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ]));

  @override
  Widget build(BuildContext context) {
    final t = _total().toInt();
    String two(int n) => n.toString().padLeft(2, '0');
    final dur = '${two(t ~/ 3600)}:${two(t % 3600 ~/ 60)}:${two(t % 60)}';
    return Scaffold(
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            FlutterMap(
              mapController: map,
              options: MapOptions(initialCenter: cur ?? const LatLng(-6.2, 106.816), initialZoom: 16),
              children: [
                TileLayer(
                  key: ValueKey(mb != null),
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.locationself.gps_locationself',
                  tileProvider: mb ?? NetworkTileProvider(),
                ),
                PolylineLayer(polylines: [Polyline(points: pts, strokeWidth: 5, color: Colors.blue)]),
                if (cur != null)
                  MarkerLayer(markers: [
                    Marker(
                      point: cur!,
                      width: 22,
                      height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                            color: Colors.blue, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                      ),
                    )
                  ]),
              ],
            ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              right: 8,
              child: Chip(label: Text('± ${acc.round()} m  ${mb != null ? "🗺 offline" : "🌐 online"}')),
            ),
          ]),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black26)],
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: SingleChildScrollView(
                child: Column(children: [
                  Row(children: [_s((meters / 1000).toStringAsFixed(2), 'Km'), _s(dur, 'Durasi'), _s(spd.toStringAsFixed(1), 'Km/jam')]),
                  const SizedBox(height: 8),
                  Row(children: [
                    _s('${alt.round()}', 'Altitude (m)'),
                    _s('$count', 'Titik di DB'),
                    _s(t > 0 ? (meters / 1000 / (t / 3600)).toStringAsFixed(1) : '0.0', 'Rata² km/jam'),
                  ]),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Mode hemat baterai'),
                    value: saver,
                    onChanged: tracking ? null : (v) => setState(() => saver = v),
                  ),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(
                      onPressed: tracking ? _stop : _start,
                      style: FilledButton.styleFrom(backgroundColor: tracking ? Colors.red : null),
                      icon: Icon(tracking ? Icons.stop : Icons.play_arrow),
                      label: Text(tracking ? 'Berhenti' : 'Mulai Lacak'),
                    ),
                    OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.delete_outline), label: const Text('Reset')),
                    OutlinedButton.icon(onPressed: () => _export(true), icon: const Icon(Icons.download), label: const Text('GPX')),
                    OutlinedButton.icon(onPressed: () => _export(false), icon: const Icon(Icons.download), label: const Text('GeoJSON')),
                    OutlinedButton.icon(onPressed: _pickMb, icon: const Icon(Icons.map), label: const Text('Peta .mbtiles')),
                    OutlinedButton.icon(
                        onPressed: () => Permission.ignoreBatteryOptimizations.request(),
                        icon: const Icon(Icons.battery_saver),
                        label: const Text('Izinkan di Baterai')),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
