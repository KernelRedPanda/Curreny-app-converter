import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

// ===== Optional Firebase Push =====
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// ========== BRAND / THEME ==========
const _brandColor = Colors.teal;
final _brandScheme = ColorScheme.fromSeed(seedColor: _brandColor);

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

// ========== CURRENCY HELPER ==========
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
  static List<String> get allCodes => _codes.keys.toList()..sort();
}

// ========== MODELS ==========
class WatchItem {
  final String base;
  final String quote;
  final double target;

  WatchItem({required this.base, required this.quote, this.target = -1});

  Map<String, dynamic> toJson() =>
      {'base': base, 'quote': quote, 'target': target};

  factory WatchItem.fromJson(Map<String, dynamic> j) => WatchItem(
        base: j['base'] ?? 'USD',
        quote: j['quote'] ?? 'EUR',
        target: (j['target'] as num?)?.toDouble() ?? -1,
      );
}

// ========== STATE MANAGEMENT ==========
class AppState extends ChangeNotifier {
  bool _showBanner = true;
  DateTime? _lastUpdated;
  bool _isTrulyOffline = false;
  String _defaultBase = 'USD';

  bool get showBanner => _showBanner;
  DateTime? get lastUpdated => _lastUpdated;
  bool get isTrulyOffline => _isTrulyOffline;
  String get defaultBase => _defaultBase;

  Future<void> loadSettings() async {
    final store = StorageService();
    _showBanner = await store.getShowBanner();
    _lastUpdated = await store.lastUpdated();
    _defaultBase = await store.getDefaultBase();
    notifyListeners();
  }

  void setShowBanner(bool value) {
    _showBanner = value;
    StorageService().setShowBanner(value);
    notifyListeners();
  }

  void updateLastUpdated(DateTime? ts) {
    _lastUpdated = ts;
    notifyListeners();
  }

  void setOffline(bool value) {
    _isTrulyOffline = value;
    notifyListeners();
  }

  void setDefaultBase(String base) {
    _defaultBase = base;
    StorageService().setDefaultBase(base);
    notifyListeners();
  }
}

// ========== SERVICES ==========
class ExchangeRateService {
  static const _xHost = 'https://api.exchangerate.host';
  static const _frank = 'https://api.frankfurter.app';
  static const _erapi = 'https://open.er-api.com/v6';
  static const _timeout = Duration(seconds: 10);

  Future<T> _tryProviders<T>(List<Future<T> Function()> attempts) async {
    late Object lastErr;
    for (final a in attempts) {
      try {
        return await a();
      } catch (e) {
        lastErr = e;
        debugPrint('Provider failed: $e');
      }
    }
    throw lastErr;
  }

  Future<Map<String, double>> latest({String base = 'USD'}) async {
    base = base.toUpperCase();
    return _tryProviders<Map<String, double>>([
      () async {
        final uri = Uri.parse('$_xHost/latest?base=$base');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'xhost returned ${res.statusCode}';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response format';
        
        final rates = body['rates'];
        if (rates is! Map) throw 'Missing rates data';
        
        return rates.map((k, v) => MapEntry(
          k.toString(),
          (v as num?)?.toDouble() ?? 0.0,
        ));
      },
      () async {
        final uri = Uri.parse('$_frank/latest?from=$base');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'frank returned ${res.statusCode}';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response format';
        
        final rates = body['rates'];
        if (rates is! Map) throw 'Missing rates data';
        
        return rates.map((k, v) => MapEntry(
          k.toString(),
          (v as num?)?.toDouble() ?? 0.0,
        ));
      },
      () async {
        final uri = Uri.parse('$_erapi/latest/$base');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'erapi returned ${res.statusCode}';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response format';
        if (body['result'] != 'success') throw 'API returned error';
        
        final rates = body['rates'];
        if (rates is! Map) throw 'Missing rates data';
        
        return rates.map((k, v) => MapEntry(
          k.toString(),
          (v as num?)?.toDouble() ?? 0.0,
        ));
      },
    ]);
  }

  Future<double> convert(String from, String to, double amount) async {
    final f = from.toUpperCase(), t = to.toUpperCase();
    return _tryProviders<double>([
      () async {
        final uri = Uri.parse('$_xHost/convert?from=$f&to=$t&amount=$amount');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'xhost convert failed';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response';
        
        final result = body['result'];
        if (result == null) throw 'Missing result';
        
        return (result as num).toDouble();
      },
      () async {
        final uri = Uri.parse('$_frank/latest?amount=$amount&from=$f&to=$t');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'frank convert failed';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response';
        
        final rates = body['rates'];
        if (rates is! Map) throw 'Missing rates';
        
        final v = rates[t];
        if (v == null) throw 'Missing target rate';
        
        return (v as num).toDouble();
      },
      () async {
        final latestMap = await latest(base: f);
        final v = latestMap[t];
        if (v == null) throw 'Missing rate for $t';
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
      () async {
        final uri = Uri.parse(
            '$_xHost/timeseries?base=$b&symbols=$q&start_date=$s&end_date=$e');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'xhost timeseries failed';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response';
        
        final rates = body['rates'];
        if (rates is! Map) throw 'Missing rates data';
        
        final out = <DateTime, double>{};
        for (final entry in rates.entries) {
          final dayMap = entry.value;
          if (dayMap is! Map) continue;
          
          final v = dayMap[q];
          if (v != null) {
            out[DateTime.parse(entry.key)] = (v as num).toDouble();
          }
        }
        return Map.fromEntries(
            out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      },
      () async {
        final uri = Uri.parse('$_frank/$s..$e?from=$b&to=$q');
        final res = await http.get(uri).timeout(_timeout);
        if (res.statusCode != 200) throw 'frank timeseries failed';
        
        final body = jsonDecode(res.body);
        if (body is! Map<String, dynamic>) throw 'Invalid response';
        
        final rates = body['rates'];
        if (rates is! Map) throw 'Missing rates data';
        
        final out = <DateTime, double>{};
        for (final entry in rates.entries) {
          final dayMap = entry.value;
          if (dayMap is! Map) continue;
          
          final v = dayMap[q];
          if (v != null) {
            out[DateTime.parse(entry.key)] = (v as num).toDouble();
          }
        }
        return Map.fromEntries(
            out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
      },
    ]);
  }
}

class StorageService {
  static const _ratesKey = 'cached_rates_v1';
  static const _watchKey = 'watchlist_v1';
  static const _defBaseKey = 'default_base';
  static const _bannerKey = 'show_offline_banner';
  static const _cacheMaxAge = Duration(hours: 24);

  Future<void> cacheRates(String base, Map<String, double> rates) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode({
      'base': base,
      'timestamp': DateTime.now().toIso8601String(),
      'rates': rates
    });
    await prefs.setString(_ratesKey, payload);
  }

  Future<Map<String, dynamic>?> readCachedRates({bool checkExpiry = true}) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_ratesKey);
    if (raw == null) return null;
    
    final cached = jsonDecode(raw) as Map<String, dynamic>;
    
    if (checkExpiry) {
      final timestamp = DateTime.tryParse(cached['timestamp'] as String? ?? '');
      if (timestamp == null) return null;
      
      final age = DateTime.now().difference(timestamp);
      if (age > _cacheMaxAge) {
        debugPrint('Cache expired (age: ${age.inHours}h)');
        return null;
      }
    }
    
    return cached;
  }

  Future<DateTime?> lastUpdated() async {
    final c = await readCachedRates(checkExpiry: false);
    return c == null
        ? null
        : DateTime.tryParse(c['timestamp'] as String? ?? '');
  }

  Future<List<WatchItem>> readWatchlist() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_watchKey);
    if (raw == null) return [];
    
    try {
      final List data = jsonDecode(raw) as List;
      return data.map((e) => WatchItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('Error reading watchlist: $e');
      return [];
    }
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
      final token = await m.getToken();
      debugPrint('✓ Firebase initialized successfully');
      debugPrint('FCM Token: $token');
      
      FirebaseMessaging.onMessage.listen((message) {
        debugPrint('Received message: ${message.notification?.title}');
      });
    } catch (e) {
      debugPrint('⚠ Firebase not configured: $e');
    }
  }
}

// ========== CHART WIDGET ==========
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
  bool shouldRepaint(covariant _LineChartPainter old) {
    if (old.points.length != points.length) return true;
    if (old.color != color) return true;
    
    for (int i = 0; i < points.length; i++) {
      if (old.points[i] != points[i]) return true;
    }
    
    return false;
  }
}

// ========== STATUS BANNER ==========
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        if (!state.showBanner) return const SizedBox.shrink();
        
        final ts = state.lastUpdated;
        final lastStr = ts == null
            ? '—'
            : DateFormat('yyyy-MM-dd HH:mm').format(ts.toLocal());
        
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          color: state.isTrulyOffline
              ? Colors.orange.shade200
              : Colors.amber.shade100,
          child: Text(
            state.isTrulyOffline
                ? 'Offline mode • last updated: $lastStr'
                : 'Using cached/live data • last updated: $lastStr',
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }
}

// ========== APP ==========
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(MessagingService.init());
  runApp(const SmartCurrencyApp());
}

class SmartCurrencyApp extends StatelessWidget {
  const SmartCurrencyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..loadSettings(),
      child: MaterialApp(
        title: 'Smart Currency Companion',
        theme: ThemeData(colorScheme: _brandScheme, useMaterial3: true),
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _idx = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const ConvertPage(),
      const WatchlistPage(),
      const ChartsPage(),
      const SettingsPage(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Currency Companion'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: AppLogo(size: 32),
          )
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
                    child: Text(
                      'Smart Currency Companion',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutPage()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy & Data Sources'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PrivacyPage()),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const StatusBanner(),
          Expanded(child: pages[_idx]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.swap_horiz), label: 'Convert'),
          NavigationDestination(icon: Icon(Icons.star_border), label: 'Watchlist'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Charts'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

// ========== CONVERT PAGE ==========
class ConvertPage extends StatefulWidget {
  const ConvertPage({super.key});

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
  String? _amountError;
  bool _isLoading = false;
  bool _isRefreshing = false;
  
  Map<String, double> _lastRates = {};
  String _lastBase = 'USD';

  @override
  void initState() {
    super.initState();
    _amountCtl = TextEditingController(text: '1');
    _fromCtl = TextEditingController(text: 'USD');
    _toCtl = TextEditingController(text: 'PKR');
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      _fromCtl.text = appState.defaultBase;
      _fetchLatest(appState.defaultBase);
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
    setState(() {
      _isRefreshing = true;
      _status = 'Fetching live rates...';
    });
    
    try {
      final data = await _svc.latest(base: base);
      _lastRates = data;
      _lastBase = base;
      await _store.cacheRates(base, _lastRates);
      
      final ts = await _store.lastUpdated();
      if (mounted) {
        context.read<AppState>().updateLastUpdated(ts);
        context.read<AppState>().setOffline(false);
        setState(() {
          _status = 'Live rates updated';
          _isRefreshing = false;
        });
      }
    } catch (e) {
      debugPrint('Live fetch failed: $e');
      final cached = await _store.readCachedRates(checkExpiry: false);
      
      if (cached != null && mounted) {
        final rates = cached['rates'];
        if (rates is Map) {
          _lastRates = rates.map((k, v) => MapEntry(
            k.toString(),
            (v as num?)?.toDouble() ?? 0.0,
          ));
        }
        _lastBase = (cached['base'] as String?) ?? 'USD';
        final ts = DateTime.tryParse(cached['timestamp'] as String? ?? '');
        
        context.read<AppState>().updateLastUpdated(ts);
        context.read<AppState>().setOffline(false);
        
        setState(() {
          _status = 'Using cached data from ${ts?.toLocal() ?? 'unknown'}';
          _isRefreshing = false;
        });
      } else if (mounted) {
        context.read<AppState>().setOffline(true);
        setState(() {
          _status = 'No internet and no cache available';
          _isRefreshing = false;
        });
      }
    }
  }

  bool _validateCodes() {
    final f = _fromCtl.text.trim().toUpperCase();
    final t = _toCtl.text.trim().toUpperCase();
    
    if (!CurrencyHelper.isValid(f) || !CurrencyHelper.isValid(t)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Use valid ISO codes (e.g., USD, PKR, EUR, AED)'),
        ),
      );
      return false;
    }
    return true;
  }

  Future<void> _convert() async {
    if (!_validateCodes()) return;
    
    final f = _fromCtl.text.trim().toUpperCase();
    final t = _toCtl.text.trim().toUpperCase();
    final amt = double.tryParse(_amountCtl.text.trim());
    
    if (amt == null || amt <= 0) {
      setState(() {
        _result = '';
        _amountError = 'Enter a valid amount';
      });
      return;
    }
    
    setState(() {
      _isLoading = true;
      _result = '';
      _amountError = null;
    });

    try {
      // Try cached first if suitable
      if (f == _lastBase && _lastRates.isNotEmpty) {
        final rate = _lastRates[t];
        if (rate != null) {
          setState(() {
            _result = '$amt $f ≈ ${(amt * rate).toStringAsFixed(2)} $t (cached)';
            _isLoading = false;
            _status = 'Done';
          });
          return;
        }
      }

      // Cross-rate via USD
      if (_lastBase == 'USD' && _lastRates.isNotEmpty) {
        final usdToTo = _lastRates[t];
        final usdToFrom = _lastRates[f];
        if (usdToTo != null && usdToFrom != null && usdToFrom != 0) {
          final cross = usdToTo / usdToFrom;
          setState(() {
            _result = '$amt $f ≈ ${(amt * cross).toStringAsFixed(2)} $t (cross)';
            _isLoading = false;
            _status = 'Done';
          });
          return;
        }
      }

      // Live conversion
      setState(() => _status = 'Converting...');
      final res = await _svc.convert(f, t, amt);
      setState(() {
        _result = '$amt $f = ${res.toStringAsFixed(2)} $t';
        _status = 'Done';
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Conversion failed: $e');
      setState(() {
        _result = 'Conversion failed. Try refreshing rates.';
        _status = 'Error';
        _isLoading = false;
      });
    }
  }

  void _swap() {
    final temp = _fromCtl.text;
    _fromCtl.text = _toCtl.text;
    _toCtl.text = temp;
  }

  Future<void> _copy() async {
    if (_result.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _result));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Result copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inputDecoration = InputDecoration(
      border: const OutlineInputBorder(),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      errorText: _amountError,
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
