import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart'; // Clipboard

// ===== Optional Firebase Push (safe if not configured) =====
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// ---------- Brand / Theme ----------
const _brandColor = Colors.teal;
final _brandScheme = ColorScheme.fromSeed(seedColor: _brandColor);

// Simple “logo” (no assets needed)
class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 56});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_brandColor, _brandColor.withOpacity(.6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(blurRadius: 12, color: _brandColor.withOpacity(.25))
        ],
      ),
      child: const Icon(Icons.currency_exchange, color: Colors.white, size: 34),
    );
  }
}

// ====== SIMPLE LOCAL CURRENCY CODES ======
class CurrencyHelper {
  static final Map<String, String> _codes = {
    "USD": "US Dollar",
    "EUR": "Euro",
    "GBP": "British Pound",
    "JPY": "Japanese Yen",
    "CNY": "Chinese Yuan",
    "AUD": "Australian Dollar",
    "CAD": "Canadian Dollar",
    "CHF": "Swiss Franc",
    "PKR": "Pakistani Rupee",
    "INR": "Indian Rupee",
    "SAR": "Saudi Riyal",
    "AED": "UAE Dirham",
    "TRY": "Turkish Lira",
    "BDT": "Bangladeshi Taka",
    "LKR": "Sri Lankan Rupee",
    "ZAR": "South African Rand",
    "NZD": "New Zealand Dollar",
    "SEK": "Swedish Krona",
    "NOK": "Norwegian Krone",
    "DKK": "Danish Krone",
    "HKD": "Hong Kong Dollar",
    "SGD": "Singapore Dollar",
  };
  static bool isValid(String code) => _codes.containsKey(code.toUpperCase());
  static String nameOf(String code) =>
      _codes[code.toUpperCase()] ?? code.toUpperCase();
}

// ====== MODELS ======
class WatchItem {
  final String base;
  final String quote;
  final double target; // -1 no target
  WatchItem({required this.base, required this.quote, this.target = -1});
  Map<String, dynamic> toJson() =>
      {'base': base, 'quote': quote, 'target': target};
  factory WatchItem.fromJson(Map<String, dynamic> j) => WatchItem(
        base: j['base'],
        quote: j['quote'],
        target: (j['target'] as num?)?.toDouble() ?? -1,
      );
}

// ====== SERVICES with MULTI-PROVIDER FALLBACK ======
class ExchangeRateService {
  static const _xHost = 'https://api.exchangerate.host';
  static const _frank = 'https://api.frankfurter.app';
  static const _erapi = 'https://open.er-api.com/v6';

  Future<T> _tryProviders<T>(List<Future<T> Function()> attempts) async {
    late Object lastErr;
    for (final a in attempts) {
      try {
        return await a();
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr;
  }

  Future<Map<String, double>> latest({String base = 'USD'}) async {
    base = base.toUpperCase();
    return _tryProviders<Map<String, double>>([
      () async {
        final uri = Uri.parse('$_xHost/latest?base=$base');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'xhost latest failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final Map<String, dynamic> rates = body['rates'];
        return rates.map((k, v) => MapEntry(k, (v as num).toDouble()));
      },
      () async {
        final uri = Uri.parse('$_frank/latest?from=$base');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'frank latest failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final Map<String, dynamic> rates =
            (body['rates'] as Map).cast<String, dynamic>();
        return rates.map((k, v) => MapEntry(k, (v as num).toDouble()));
      },
      () async {
        final uri = Uri.parse('$_erapi/latest/$base');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'erapi latest failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['result'] != 'success') throw 'erapi not success';
        final Map<String, dynamic> rates =
            (body['rates'] as Map).cast<String, dynamic>();
        return rates.map((k, v) => MapEntry(k, (v as num).toDouble()));
      },
    ]);
  }

  Future<double> convert(String from, String to, double amount) async {
    final f = from.toUpperCase(), t = to.toUpperCase();
    return _tryProviders<double>([
      () async {
        final uri = Uri.parse('$_xHost/convert?from=$f&to=$t&amount=$amount');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'xhost convert failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        return (body['result'] as num).toDouble();
      },
      () async {
        final uri = Uri.parse('$_frank/latest?amount=$amount&from=$f&to=$t');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'frank convert failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final Map<String, dynamic> rates =
            (body['rates'] as Map).cast<String, dynamic>();
        final v = rates[t];
        if (v == null) throw 'frank missing rate';
        return (v as num).toDouble();
      },
      () async {
        // Use our own latest() as a cross-rate fallback
        final latestMap = await latest(base: f);
        final v = latestMap[t];
        if (v == null) throw 'provider missing rate';
        return amount * v;
      }
    ]);
  }

  Future<Map<DateTime, double>> timeseries({
    required String base,
    required String quote,
    required DateTime start,
    required DateTime end,
  }) async {
    final b = base.toUpperCase(), q = quote.toUpperCase();
    final s = DateFormat('yyyy-MM-dd').format(start);
    final e = DateFormat('yyyy-MM-dd').format(end);

    return _tryProviders<Map<DateTime, double>>([
      // exchangerate.host
      () async {
        final uri = Uri.parse(
            '$_xHost/timeseries?base=$b&symbols=$q&start_date=$s&end_date=$e');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'xhost timeseries failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final Map<String, dynamic> rates =
            (body['rates'] as Map).cast<String, dynamic>();
        final out = <DateTime, double>{};
        for (final entry in rates.entries) {
          final dayMap =
              (entry.value as Map).cast<String, dynamic>(); // safe cast
          final v = (dayMap[q] as num).toDouble();
          out[DateTime.parse(entry.key)] = v;
        }
        return Map.fromEntries(
            out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      },
      // frankfurter
      () async {
        final uri = Uri.parse('$_frank/$s..$e?from=$b&to=$q');
        final res = await http.get(uri);
        if (res.statusCode != 200) throw 'frank timeseries failed';
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final Map<String, dynamic> rates =
            (body['rates'] as Map).cast<String, dynamic>();
        final out = <DateTime, double>{};
        for (final entry in rates.entries) {
          final dayMap =
              (entry.value as Map).cast<String, dynamic>(); // safe cast
          final v = (dayMap[q] as num).toDouble();
          out[DateTime.parse(entry.key)] = v;
        }
        return Map.fromEntries(
            out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      },
      // coarse fallback (daily latest)
      () async {
        final out = <DateTime, double>{};
        var d = DateTime(start.year, start.month, start.day);
        while (!d.isAfter(end)) {
          final r = await latest(base: b);
          final v = r[q];
          if (v != null) out[d] = v;
          d = d.add(const Duration(days: 1));
        }
        return out;
      }
    ]);
  }
}

class StorageService {
  static const _ratesKey = 'cached_rates_v1';
  static const _watchKey = 'watchlist_v1';
  static const _defBaseKey = 'default_base';
  static const _bannerKey = 'show_offline_banner';

  Future<void> cacheRates(String base, Map<String, double> rates) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'base': base,
      'timestamp': DateTime.now().toIso8601String(),
      'rates': rates
    });
    await prefs.setString(_ratesKey, payload);
  }

  Future<Map<String, dynamic>?> readCachedRates() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_ratesKey);
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<DateTime?> lastUpdated() async {
    final c = await readCachedRates();
    return c == null
        ? null
        : DateTime.tryParse(c['timestamp'] as String? ?? '');
  }

  Future<List<WatchItem>> readWatchlist() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_watchKey);
    if (raw == null) return [];
    final List data = jsonDecode(raw) as List;
    return data.map((e) => WatchItem.fromJson(e)).toList();
  }

  Future<void> saveWatchlist(List<WatchItem> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _watchKey, jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  Future<String> getDefaultBase() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_defBaseKey) ?? 'USD';
  }

  Future<void> setDefaultBase(String code) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_defBaseKey, code.toUpperCase());
  }

  Future<bool> getShowBanner() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_bannerKey) ?? true;
  }

  Future<void> setShowBanner(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_bannerKey, v);
  }
}

class MessagingService {
  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      final m = FirebaseMessaging.instance;
      await m.requestPermission(alert: true, badge: true, sound: true);
      await m.getToken();
      FirebaseMessaging.onMessage.listen((_) {});
    } catch (_) {
      // ignore if not configured
    }
  }
}

// ====== SIMPLE CHART WIDGET ======
class RateChart extends StatelessWidget {
  final List<double> points;
  final List<String> labels;
  const RateChart({super.key, required this.points, required this.labels});
  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: CustomPaint(
          painter: _LineChartPainter(points: points, color: _brandColor),
          child: Container(
            width: double.infinity,
            height: 240,
            alignment: Alignment.bottomCenter,
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              labels.isNotEmpty ? '${labels.first} → ${labels.last}' : '',
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
            ),
          ),
        ),
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<double> points;
  final Color color;
  _LineChartPainter({required this.points, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = color.withOpacity(.06);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      bg,
    );
    if (points.isEmpty) return;
    final minV = points.reduce((a, b) => a < b ? a : b);
    final maxV = points.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : maxV - minV;
    final path = Path();
    final line = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < points.length; i++) {
      final x = size.width * (i / (points.length - 1));
      final y = size.height * (1 - ((points[i] - minV) / range));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.points != points || old.color != color;
}

// ====== APP ======
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(MessagingService.init());
  runApp(const SmartCurrencyApp());
}

class SmartCurrencyApp extends StatefulWidget {
  const SmartCurrencyApp({super.key});
  @override
  State<SmartCurrencyApp> createState() => _SmartCurrencyAppState();
}

class _SmartCurrencyAppState extends State<SmartCurrencyApp> {
  bool _showBanner = true;
  DateTime? _lastUpdated;
  bool _isTrulyOffline = false;

  void setBanner(bool v) => setState(() => _showBanner = v);
  void updateLastUpdated(DateTime? ts) => setState(() => _lastUpdated = ts);
  void setOffline(bool v) => setState(() => _isTrulyOffline = v);

  @override
  void initState() {
    super.initState();
    final store = StorageService();
    store.getShowBanner().then((v) => setState(() => _showBanner = v));
    store.lastUpdated().then((ts) => setState(() => _lastUpdated = ts));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Currency Companion',
      theme: ThemeData(colorScheme: _brandScheme, useMaterial3: true),
      home: HomeScreen(
        showBanner: _showBanner,
        onShowBannerChanged: setBanner,
        lastUpdated: _lastUpdated,
        onLastUpdatedChanged: updateLastUpdated,
        onOfflineChanged: setOffline,
        isTrulyOffline: _isTrulyOffline,
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final bool showBanner;
  final DateTime? lastUpdated;
  final bool isTrulyOffline;
  final ValueChanged<bool> onShowBannerChanged;
  final ValueChanged<DateTime?> onLastUpdatedChanged;
  final ValueChanged<bool> onOfflineChanged;
  const HomeScreen({
    super.key,
    required this.showBanner,
    required this.onShowBannerChanged,
    required this.lastUpdated,
    required this.onLastUpdatedChanged,
    required this.onOfflineChanged,
    required this.isTrulyOffline,
  });
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _idx = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [
      ConvertPage(
        onOfflineChanged: widget.onOfflineChanged,
        onLastUpdatedChanged: widget.onLastUpdatedChanged,
      ),
      const WatchlistPage(),
      const ChartsPage(),
      SettingsPage(onShowBannerChanged: widget.onShowBannerChanged),
    ];
    final ts = widget.lastUpdated;
    final lastStr =
        ts == null ? '—' : DateFormat('yyyy-MM-dd HH:mm').format(ts.toLocal());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Currency Companion'),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 12), child: AppLogo(size: 32))
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_brandColor, _brandColor.withOpacity(.7)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AppLogo(size: 56),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Smart Currency Companion',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AboutPage())),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy & Data Sources'),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PrivacyPage())),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (widget.showBanner)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: (widget.isTrulyOffline
                  ? Colors.orange.shade200
                  : Colors.amber.shade100),
              child: Text(
                widget.isTrulyOffline
                    ? 'Offline mode • last updated: $lastStr'
                    : 'Using cached/live data • last updated: $lastStr',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(child: pages[_idx]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'Convert'),
          NavigationDestination(
              icon: Icon(Icons.star_border), label: 'Watchlist'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Charts'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ====== Convert Page ======
class ConvertPage extends StatefulWidget {
  final ValueChanged<bool> onOfflineChanged;
  final ValueChanged<DateTime?> onLastUpdatedChanged;
  const ConvertPage(
      {super.key,
      required this.onOfflineChanged,
      required this.onLastUpdatedChanged});
  @override
  State<ConvertPage> createState() => _ConvertPageState();
}

class _ConvertPageState extends State<ConvertPage> {
  final _svc = ExchangeRateService();
  final _store = StorageService();
  late final TextEditingController _amountCtl;
  late final TextEditingController _fromCtl;
  late final TextEditingController _toCtl;

  String _status = 'Ready';
  String _result = '';
  Map<String, double> _lastRates = {};
  String _lastBase = 'USD';

  @override
  void initState() {
    super.initState();
    _amountCtl = TextEditingController(text: '1');
    _fromCtl = TextEditingController(text: 'USD');
    _toCtl = TextEditingController(text: 'PKR');
    SharedPreferences.getInstance().then((p) {
      final def = p.getString('default_base') ?? 'USD';
      _fromCtl.text = def;
      _fetchLatest(def);
    });
  }

  @override
  void dispose() {
    _amountCtl.dispose();
    _fromCtl.dispose();
    _toCtl.dispose();
    super.dispose();
  }

  Future<void> _fetchLatest(String base) async {
    try {
      setState(() => _status = 'Fetching live rates...');
      final data = await _svc.latest(base: base);
      _lastRates = data;
      _lastBase = base;
      await _store.cacheRates(base, _lastRates);
      widget.onLastUpdatedChanged(await _store.lastUpdated());
      setState(() => _status = 'Live rates updated');
      widget.onOfflineChanged(false);
    } catch (_) {
      final cached = await _store.readCachedRates();
      if (cached != null) {
        final Map<String, dynamic> r =
            (cached['rates'] as Map).cast<String, dynamic>();
        _lastRates = r.map((k, v) => MapEntry(k, (v as num).toDouble()));
        _lastBase = (cached['base'] as String?) ?? 'USD';
        final ts = DateTime.tryParse(cached['timestamp'] as String? ?? '');
        setState(() => _status =
            'Service unavailable • cached from ${ts?.toLocal() ?? 'unknown'}');
        widget.onLastUpdatedChanged(ts);
        widget.onOfflineChanged(false); // provider issue ≠ offline
      } else {
        setState(
            () => _status = 'No internet/providers and no cache available');
        widget.onOfflineChanged(true);
      }
    }
  }

  bool _validateCodes(BuildContext ctx) {
    final f = _fromCtl.text.trim().toUpperCase();
    final t = _toCtl.text.trim().toUpperCase();
    if (!CurrencyHelper.isValid(f) || !CurrencyHelper.isValid(t)) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
            content: Text('Use valid ISO codes (e.g., USD, PKR, EUR, AED)')),
      );
      return false;
    }
    return true;
  }

  Future<void> _convert() async {
    if (!_validateCodes(context)) return;
    final f = _fromCtl.text.trim().toUpperCase();
    final t = _toCtl.text.trim().toUpperCase();
    final amt = double.tryParse(_amountCtl.text.trim()) ?? 0;
    if (amt <= 0) {
      setState(() => _result = 'Enter a valid amount');
      return;
    }

    // Use cached if suitable
    if (f == _lastBase && _lastRates.isNotEmpty) {
      final rate = _lastRates[t];
      if (rate != null) {
        setState(() => _result =
            '$amt $f ≈ ${(amt * rate).toStringAsFixed(2)} $t (cached/live)');
        return;
      }
    }
    // Cross via USD if available
    if (_lastBase == 'USD' && _lastRates.isNotEmpty) {
      final usdToTo = _lastRates[t], usdToFrom = _lastRates[f];
      if (usdToTo != null && usdToFrom != null) {
        final cross = usdToTo / usdToFrom;
        setState(() => _result =
            '$amt $f ≈ ${(amt * cross).toStringAsFixed(2)} $t (cross cached)');
        return;
      }
    }

    try {
      setState(() => _status = 'Converting...');
      final res = await _svc.convert(f, t, amt);
      setState(() {
        _result = '$amt $f = ${res.toStringAsFixed(2)} $t';
        _status = 'Done';
      });
    } catch (_) {
      setState(() {
        _result = 'Conversion failed (no providers & no cache).';
        _status = 'Error';
      });
    }
  }

  void _swap() {
    final f = _fromCtl.text;
    _fromCtl.text = _toCtl.text;
    _toCtl.text = f;
  }

  Future<void> _copy() async {
    if (_result.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _result));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Result copied')));
  }

  @override
  Widget build(BuildContext context) {
    const input = InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                decoration: input.copyWith(labelText: 'Amount'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                controller: _amountCtl,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: TextField(
                    decoration: input.copyWith(labelText: 'From (e.g., USD)'),
                    controller: _fromCtl)),
            const SizedBox(width: 12),
            Expanded(
                child: TextField(
                    decoration: input.copyWith(labelText: 'To (e.g., PKR)'),
                    controller: _toCtl)),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Swap',
              child: Ink(
                decoration: const ShapeDecoration(
                    shape: CircleBorder(), color: Color(0x14000000)),
                child: IconButton(
                    onPressed: _swap, icon: const Icon(Icons.swap_vert)),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.icon(
                onPressed: _convert,
                icon: const Icon(Icons.calculate),
                label: const Text('Convert')),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _fetchLatest(_fromCtl.text.trim().toUpperCase()),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
            const Spacer(),
            Text(_status, style: const TextStyle(fontStyle: FontStyle.italic)),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: SelectableText(_result,
                    style: Theme.of(context).textTheme.titleMedium)),
            IconButton(onPressed: _copy, icon: const Icon(Icons.copy_all)),
          ]),
        ],
      ),
    );
  }
}

// ====== Watchlist Page ======
class WatchlistPage extends StatefulWidget {
  const WatchlistPage({super.key});
  @override
  State<WatchlistPage> createState() => _WatchlistPageState();
}

class _WatchlistPageState extends State<WatchlistPage> {
  final _store = StorageService();
  final _svc = ExchangeRateService();
  List<WatchItem> _items = [];
  late final TextEditingController _baseCtl;
  late final TextEditingController _quoteCtl;
  late final TextEditingController _targetCtl;

  @override
  void initState() {
    super.initState();
    _baseCtl = TextEditingController(text: 'USD');
    _quoteCtl = TextEditingController(text: 'PKR');
    _targetCtl = TextEditingController(text: '');
    _load();
  }

  @override
  void dispose() {
    _baseCtl.dispose();
    _quoteCtl.dispose();
    _targetCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await _store.readWatchlist();
    setState(() => _items = list);
  }

  Future<void> _save() async => _store.saveWatchlist(_items);

  Future<void> _add() async {
    final base = _baseCtl.text.trim().toUpperCase();
    final quote = _quoteCtl.text.trim().toUpperCase();
    final tStr = _targetCtl.text.trim();
    final t = tStr.isEmpty ? -1.0 : (double.tryParse(tStr) ?? -1);
    if (!CurrencyHelper.isValid(base) || !CurrencyHelper.isValid(quote)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Use valid ISO codes')));
      return;
    }
    setState(() => _items.add(WatchItem(base: base, quote: quote, target: t)));
    await _save();
  }

  Future<void> _checkNow() async {
    try {
      final usdRates = await _svc.latest(base: 'USD');
      final hits = <String>[];
      for (final item in _items) {
        if (item.target <= 0) continue;
        double? rate;
        if (item.base == 'USD') {
          rate = usdRates[item.quote];
        } else {
          final baseToUsd = 1 / (usdRates[item.base] ?? double.nan);
          final usdToQuote = usdRates[item.quote] ?? double.nan;
          final r = baseToUsd * usdToQuote;
          rate = (r.isNaN ? null : r);
        }
        if (rate == null || rate.isNaN) continue;
        if (rate >= item.target) {
          hits.add(
              '${item.base}/${item.quote} ≥ ${item.target} (now ${rate.toStringAsFixed(4)})');
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(hits.isEmpty
              ? 'No alerts met.'
              : 'Alerts:\n${hits.join('\n')}')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to check rates')));
    }
  }

  @override
  Widget build(BuildContext context) {
    const input = InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: TextField(
                  decoration: input.copyWith(labelText: 'Base (e.g., USD)'),
                  controller: _baseCtl)),
          const SizedBox(width: 12),
          Expanded(
              child: TextField(
                  decoration: input.copyWith(labelText: 'Quote (e.g., PKR)'),
                  controller: _quoteCtl)),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              decoration: input.copyWith(labelText: 'Target rate (optional)'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              controller: _targetCtl,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
          const SizedBox(width: 12),
          OutlinedButton.icon(
              onPressed: _checkNow,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Check Now')),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            itemCount: _items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final it = _items[i];
              return ListTile(
                leading: const Icon(Icons.star_border),
                title: Text('${it.base}/${it.quote}'),
                subtitle: Text(
                    it.target > 0 ? 'Target: ${it.target}' : 'No alert target'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    setState(() => _items.removeAt(i));
                    await _save();
                  },
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ====== Charts Page ======
class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});
  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage> {
  final _svc = ExchangeRateService();
  late final TextEditingController _baseCtl;
  late final TextEditingController _quoteCtl;

  String _range = '30'; // 7/30/90
  List<double> _points = [];
  List<String> _labels = [];
  String _status = 'Enter pair & Load';

  @override
  void initState() {
    super.initState();
    _baseCtl = TextEditingController(text: 'USD');
    _quoteCtl = TextEditingController(text: 'PKR');
  }

  @override
  void dispose() {
    _baseCtl.dispose();
    _quoteCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final base = _baseCtl.text.trim().toUpperCase();
    final quote = _quoteCtl.text.trim().toUpperCase();
    if (!CurrencyHelper.isValid(base) || !CurrencyHelper.isValid(quote)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Use valid ISO codes for chart pair')));
      return;
    }
    final days = int.parse(_range);
    final end = DateTime.now();
    final start = end.subtract(Duration(days: days));
    setState(() => _status = 'Loading...');
    try {
      final data = await _svc.timeseries(
          base: base, quote: quote, start: start, end: end);
      final pts = <double>[];
      final lbs = <String>[];
      for (final e in data.entries) {
        pts.add(e.value);
        lbs.add(DateFormat('MM/dd').format(e.key));
      }
      setState(() {
        _points = pts;
        _labels = lbs;
        _status = 'Loaded ${pts.length} points';
      });
    } catch (_) {
      setState(() => _status = 'Failed to load timeseries');
    }
  }

  @override
  Widget build(BuildContext context) {
    const input = InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Row(children: [
          Expanded(
              child: TextField(
                  decoration: input.copyWith(labelText: 'Base'),
                  controller: _baseCtl)),
          const SizedBox(width: 12),
          Expanded(
              child: TextField(
                  decoration: input.copyWith(labelText: 'Quote'),
                  controller: _quoteCtl)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          ChoiceChip(
              label: const Text('7d'),
              selected: _range == '7',
              onSelected: (_) => setState(() => _range = '7')),
          const SizedBox(width: 8),
          ChoiceChip(
              label: const Text('30d'),
              selected: _range == '30',
              onSelected: (_) => setState(() => _range = '30')),
          const SizedBox(width: 8),
          ChoiceChip(
              label: const Text('90d'),
              selected: _range == '90',
              onSelected: (_) => setState(() => _range = '90')),
          const SizedBox(width: 12),
          FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.show_chart),
              label: const Text('Load')),
          const SizedBox(width: 12),
          Text(_status),
        ]),
        const SizedBox(height: 16),
        Expanded(
            child: _points.isEmpty
                ? const Center(child: Text('No data'))
                : RateChart(points: _points, labels: _labels)),
      ]),
    );
  }
}

// ====== Settings Page ======
class SettingsPage extends StatefulWidget {
  final ValueChanged<bool> onShowBannerChanged;
  const SettingsPage({super.key, required this.onShowBannerChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _defaultBaseCtl;
  bool _showBanner = true;

  @override
  void initState() {
    super.initState();
    _defaultBaseCtl = TextEditingController(text: 'USD');
    _load();
  }

  @override
  void dispose() {
    _defaultBaseCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = StorageService();
    final base = await s.getDefaultBase();
    final banner = await s.getShowBanner();
    setState(() {
      _defaultBaseCtl.text = base;
      _showBanner = banner;
    });
  }

  Future<void> _save() async {
    final code = _defaultBaseCtl.text.trim().toUpperCase();
    if (!CurrencyHelper.isValid(code)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Use a valid ISO code')));
      return;
    }
    await StorageService().setDefaultBase(code);
    await StorageService().setShowBanner(_showBanner);
    widget.onShowBannerChanged(_showBanner);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  @override
  Widget build(BuildContext context) {
    const input = InputDecoration(
      border: OutlineInputBorder(),
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextField(
              decoration: input.copyWith(labelText: 'Default Base (e.g., USD)'),
              controller: _defaultBaseCtl,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save')),
        ]),
        const SizedBox(height: 12),
        SwitchListTile(
          value: _showBanner,
          onChanged: (v) => setState(() => _showBanner = v),
          title: const Text('Show Status Banner'),
          subtitle: const Text('Display freshness/offline status above pages'),
        ),
        const SizedBox(height: 12),
        const Text('Tip: Use the drawer for About and Privacy pages.'),
      ]),
    );
  }
}

// ====== About & Privacy ======
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Smart Currency Companion',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          SizedBox(height: 12),
          Text('Student: Karim Akber Hussain'),
          Text('Registration No: FA24-BCE-114'),
          Text('Serial No: 43'),
          SizedBox(height: 16),
          Text(
              'Currency conversion with caching, watchlist alerts, and charts. Enhanced UI and multi-provider reliability for web.'),
        ]),
      ),
    );
  }
}

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Data Sources')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(children: const [
          Text('Data Sources', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('• exchangerate.host (primary)'),
          Text('• frankfurter.app (fallback)'),
          Text('• open.er-api.com (fallback)'),
          SizedBox(height: 16),
          Text('Privacy Summary',
              style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text(
              '• No account required; watchlist and cached rates are stored locally on the device.'),
          Text(
              '• If Firebase Cloud Messaging is enabled, a device token may be used to deliver alerts.'),
          SizedBox(height: 16),
          Text('Permissions', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('• Internet: to fetch live exchange rates and notifications.'),
          Text('• Notifications (optional): for rate alerts.'),
        ]),
      ),
    );
  }
}
