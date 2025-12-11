import 'dart:convert';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkTheme') ?? false;
    setState(() {
      _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    });
  }

  void _toggleTheme() async {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light
          ? ThemeMode.dark
          : ThemeMode.light;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkTheme', _themeMode == ThemeMode.dark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Vue Cast',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6AA3FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1220),
        cardTheme: const CardThemeData(
          color: Color(0x1AFFFFFF),
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(20)),
          ),
        ),
      ),
      home: WeatherPage(
        onToggleTheme: _toggleTheme,
        isDark: _themeMode == ThemeMode.dark,
      ),
    );
  }
}

class WeatherPage extends StatefulWidget {
  final VoidCallback onToggleTheme;
  final bool isDark;

  const WeatherPage({
    super.key,
    required this.onToggleTheme,
    required this.isDark,
  });

  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  List<Map<String, dynamic>> _mainForecast = [];
  List<Map<String, dynamic>> _dailyForecast = [];
  String _locationName = '';
  String _description = '';
  String? _iconCode;
  double? _tempC;
  double? _lat;
  double? _lon;
  int? _humidity;
  double? _wind;
  DateTime? _updatedAt;

  bool _isLoading = true;
  String? _error;

  // OpenWeather token
  final String apiKey = "ffb1e1f3e82292eb14f68515a6e9b7d6";

  List<Map<String, dynamic>> _extraLocations = [];

  Map<String, dynamic>? _mainLocationCache;

  final PageController _pageController = PageController();
  int _currentPageIndex = 0;
  bool _showPageIndicator = false; // 是否顯示頁面指示點
  Timer? _indicatorHideTimer; // 延遲隱藏使用的計時器

  @override
  void initState() {
    super.initState();
    _loadLocations();
    _getWeather();
  }

  @override
  void dispose() {
    _indicatorHideTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  // ================= Storage: 儲存 / 載入地點 =================

  Future<void> _saveLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final locations = _extraLocations.map((loc) {
      final copy = Map<String, dynamic>.from(loc);
      if (copy['updatedAt'] is DateTime) {
        copy['updatedAt'] = (copy['updatedAt'] as DateTime).toIso8601String();
      }
      return copy;
    }).toList();
    prefs.setString('extra_locations', jsonEncode(locations));
  }

  Future<void> _loadLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString('extra_locations');
    if (str != null && str.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(str);
        setState(() {
          _extraLocations = decoded.map<Map<String, dynamic>>((loc) {
            final map = Map<String, dynamic>.from(loc);
            if (map['updatedAt'] != null && map['updatedAt'] is String) {
              map['updatedAt'] = DateTime.tryParse(map['updatedAt']);
            }
            return map;
          }).toList();
        });
      } catch (_) {
        // ignore
      }
    }
  }

  // ================== 主地點天氣（定位） ==================

  Future<void> _getWeather() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _error = "定位服務未啟用";
          _isLoading = false;
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _error = "定位權限被拒絕";
            _isLoading = false;
          });
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _error = "定位權限被永久拒絕（請到系統設定開啟）";
          _isLoading = false;
        });
        return;
      }

      Position position;
      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        // fallback: 台北 101
        position = Position(
          latitude: 25.0330,
          longitude: 121.5654,
          timestamp: DateTime.now(),
          accuracy: 1.0,
          altitude: 0.0,
          heading: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
          altitudeAccuracy: 0.0,
          headingAccuracy: 0.0,
        );
      }

      final lat = position.latitude;
      final lon = position.longitude;

      String areaName = '';
      try {
        final placemarks = await placemarkFromCoordinates(lat, lon);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          areaName =
              "${p.locality ?? ''}${p.subLocality != null && p.subLocality!.isNotEmpty ? p.subLocality : ''}"
                  .replaceAll(RegExp(r'\s+'), '');
        }
      } catch (_) {
        areaName = '';
      }

      final url =
          "https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_tw";
      final response = await http.get(Uri.parse(url));

      if (response.statusCode != 200) {
        setState(() {
          _error = "無法取得天氣：HTTP ${response.statusCode}";
          _isLoading = false;
        });
        return;
      }

      final data = jsonDecode(response.body);
      final description = data["weather"][0]["description"] as String? ?? '';
      final iconCode = data["weather"][0]["icon"] as String?;
      final temp = (data["main"]["temp"] as num?)?.toDouble();
      final humidity = (data["main"]["humidity"] as num?)?.toInt();
      final wind = (data["wind"]?["speed"] as num?)?.toDouble();
      final owName = (data["name"] as String?) ?? '';
      final country = (data["sys"]?["country"] as String?) ?? '';
      if (areaName.isEmpty) {
        areaName = owName.isNotEmpty
            ? "$owName${country.isNotEmpty ? ", $country" : ""}"
            : "目前位置";
      }

      // forecast (3hr step, 保留完整 list 並另外算出 5 天預測)
      final forecastUrl =
          "https://api.openweathermap.org/data/2.5/forecast?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_tw";
      final forecastResp = await http.get(Uri.parse(forecastUrl));
      List<Map<String, dynamic>> forecastList = [];
      List<Map<String, dynamic>> dailyList = [];
      if (forecastResp.statusCode == 200) {
        final forecastData = jsonDecode(forecastResp.body);
        final List<dynamic> list = forecastData['list'] ?? [];
        for (final f in list) {
          if (f is! Map<String, dynamic>) continue;
          forecastList.add({
            'dt_txt': f['dt_txt'],
            'temp': (f['main']?['temp'] as num?)?.toDouble(),
            'icon': f['weather']?[0]?['icon'],
          });
        }
        dailyList = _buildDailyForecastFromRaw(list);
      }

      setState(() {
        _lat = lat;
        _lon = lon;
        _locationName = areaName;
        _description = description;
        _iconCode = iconCode;
        _tempC = temp;
        _humidity = humidity;
        _wind = wind;
        _updatedAt = DateTime.now();
        _mainForecast = forecastList;
        _dailyForecast = dailyList;
        _isLoading = false;

        _mainLocationCache = {
          'locationName': _locationName,
          'description': _description,
          'iconCode': _iconCode,
          'tempC': _tempC,
          'lat': _lat,
          'lon': _lon,
          'humidity': _humidity,
          'wind': _wind,
          'updatedAt': _updatedAt,
          'forecast': forecastList,
          'forecast_daily': dailyList,
        };
      });
    } catch (e) {
      setState(() {
        _error = "發生錯誤：$e";
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _buildDailyForecastFromRaw(List<dynamic> list) {
    final Map<String, Map<String, dynamic>> byDate = {};

    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      final dtTxt = raw['dt_txt'] as String?;
      if (dtTxt == null) continue;
      final parts = dtTxt.split(' ');
      if (parts.length < 2) continue;
      final dateStr = parts[0];
      final temp = (raw['main']?['temp'] as num?)?.toDouble();
      if (temp == null) continue;
      final icon = raw['weather']?[0]?['icon'] as String?;

      final existing = byDate[dateStr];
      if (existing == null) {
        byDate[dateStr] = {
          'date': dateStr,
          'min': temp,
          'max': temp,
          'icon': icon,
          'iconDt': dtTxt,
        };
      } else {
        final double oldMin = existing['min'] as double;
        final double oldMax = existing['max'] as double;
        existing['min'] = math.min(oldMin, temp);
        existing['max'] = math.max(oldMax, temp);

        if (icon != null) {
          final oldIconDt = existing['iconDt'] as String?;
          if (oldIconDt == null || dtTxt.contains('12:00:00')) {
            existing['icon'] = icon;
            existing['iconDt'] = dtTxt;
          }
        }
      }
    }

    final dates = byDate.keys.toList()..sort();
    final List<Map<String, dynamic>> result = [];
    for (final d in dates) {
      final day = byDate[d]!;
      result.add({
        'date': day['date'],
        'min': day['min'],
        'max': day['max'],
        'icon': day['icon'],
      });
      if (result.length >= 5) break;
    }
    return result;
  }

  // ================== 新增其他地點（保留你的功能） ==================

  Future<void> _addLocation() async {
    final TextEditingController controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新增地點'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: '輸入地點名稱'),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                final locationName = controller.text.trim();
                if (locationName.isEmpty) return;
                Navigator.of(context).pop();
                await _fetchAndAddLocation(locationName);
              },
              child: const Text('新增'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _fetchAndAddLocation(String locationName) async {
    try {
      final locations = await locationFromAddress(locationName);
      if (locations.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('找不到該地點')));
        return;
      }
      final loc = locations.first;
      final lat = loc.latitude;
      final lon = loc.longitude;

      final url =
          "https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_tw";
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('無法取得天氣：HTTP ${response.statusCode}')),
        );
        return;
      }
      final data = jsonDecode(response.body);
      final description = data["weather"][0]["description"] as String? ?? '';
      final iconCode = data["weather"][0]["icon"] as String?;
      final temp = (data["main"]["temp"] as num?)?.toDouble();
      final humidity = (data["main"]["humidity"] as num?)?.toInt();
      final wind = (data["wind"]?["speed"] as num?)?.toDouble();
      final owName = (data["name"] as String?) ?? '';
      final country = (data["sys"]?["country"] as String?) ?? '';
      final displayName = owName.isNotEmpty
          ? "$owName${country.isNotEmpty ? ", $country" : ""}"
          : locationName;

      final forecastUrl =
          "https://api.openweathermap.org/data/2.5/forecast?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_tw";
      final forecastResp = await http.get(Uri.parse(forecastUrl));
      List<Map<String, dynamic>> forecastList = [];
      List<Map<String, dynamic>> dailyList = [];
      if (forecastResp.statusCode == 200) {
        final forecastData = jsonDecode(forecastResp.body);
        final List<dynamic> list = forecastData['list'] ?? [];
        for (final f in list) {
          if (f is! Map<String, dynamic>) continue;
          forecastList.add({
            'dt_txt': f['dt_txt'],
            'temp': (f['main']?['temp'] as num?)?.toDouble(),
            'icon': f['weather']?[0]?['icon'],
          });
        }
        dailyList = _buildDailyForecastFromRaw(list);
      }

      setState(() {
        _extraLocations.add({
          'locationName': displayName,
          'description': description,
          'iconCode': iconCode,
          'tempC': temp,
          'lat': lat,
          'lon': lon,
          'humidity': humidity,
          'wind': wind,
          'updatedAt': DateTime.now(),
          'forecast': forecastList,
          'forecast_daily': dailyList,
        });
        _saveLocations();
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('發生錯誤：$e')));
    }
  }

  Future<void> _refreshExtraLocations() async {
    if (_extraLocations.isEmpty) return;

    final List<Map<String, dynamic>> updated = [];

    for (final loc in _extraLocations) {
      final lat = (loc['lat'] as num?)?.toDouble();
      final lon = (loc['lon'] as num?)?.toDouble();
      final displayName = loc['locationName'] as String? ?? '未知地點';

      if (lat == null || lon == null) {
        // 沒經緯度就保留舊資料
        updated.add(loc);
        continue;
      }

      try {
        // 重新抓目前天氣
        final url =
            "https://api.openweathermap.org/data/2.5/weather?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_tw";
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) {
          // 失敗就保留舊資料
          updated.add(loc);
          continue;
        }

        final data = jsonDecode(response.body);
        final description = data["weather"][0]["description"] as String? ?? '';
        final iconCode = data["weather"][0]["icon"] as String?;
        final temp = (data["main"]["temp"] as num?)?.toDouble();
        final humidity = (data["main"]["humidity"] as num?)?.toInt();
        final wind = (data["wind"]?["speed"] as num?)?.toDouble();
        final owName = (data["name"] as String?) ?? '';
        final country = (data["sys"]?["country"] as String?) ?? '';
        final name = owName.isNotEmpty
            ? "$owName${country.isNotEmpty ? ", $country" : ""}"
            : displayName;

        // 重新抓 3hr 預報 + 5 天預報
        final forecastUrl =
            "https://api.openweathermap.org/data/2.5/forecast?lat=$lat&lon=$lon&appid=$apiKey&units=metric&lang=zh_tw";
        final forecastResp = await http.get(Uri.parse(forecastUrl));

        List<Map<String, dynamic>> forecastList = [];
        List<Map<String, dynamic>> dailyList = [];

        if (forecastResp.statusCode == 200) {
          final forecastData = jsonDecode(forecastResp.body);
          final List<dynamic> list = forecastData['list'] ?? [];
          for (final f in list) {
            if (f is! Map<String, dynamic>) continue;
            forecastList.add({
              'dt_txt': f['dt_txt'],
              'temp': (f['main']?['temp'] as num?)?.toDouble(),
              'icon': f['weather']?[0]?['icon'],
            });
          }
          dailyList = _buildDailyForecastFromRaw(list);
        }

        updated.add({
          'locationName': name,
          'description': description,
          'iconCode': iconCode,
          'tempC': temp,
          'lat': lat,
          'lon': lon,
          'humidity': humidity,
          'wind': wind,
          'updatedAt': DateTime.now(),
          'forecast': forecastList,
          'forecast_daily': dailyList,
        });
      } catch (_) {
        // 發生錯誤就保留舊資料
        updated.add(loc);
      }
    }

    setState(() {
      _extraLocations = updated;
    });
    _saveLocations();
  }

  // 把某個儲存地點套用到主畫面
  void _applyLocationData(Map<String, dynamic> loc) {
    setState(() {
      _locationName = loc['locationName'] as String? ?? _locationName;
      _description = loc['description'] as String? ?? _description;
      _iconCode = loc['iconCode'] as String?;
      _tempC = (loc['tempC'] as num?)?.toDouble();
      _lat = (loc['lat'] as num?)?.toDouble();
      _lon = (loc['lon'] as num?)?.toDouble();
      _humidity = (loc['humidity'] as num?)?.toInt();
      _wind = (loc['wind'] as num?)?.toDouble();
      _updatedAt = (loc['updatedAt'] is DateTime)
          ? loc['updatedAt'] as DateTime
          : DateTime.now();
      final forecast = loc['forecast'];
      if (forecast is List) {
        _mainForecast = forecast
            .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
            .toList();
      } else {
        _mainForecast = [];
      }

      final forecastDaily = loc['forecast_daily'];
      if (forecastDaily is List) {
        _dailyForecast = forecastDaily
            .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e))
            .toList();
      } else {
        _dailyForecast = _buildDailyForecastFromRaw(
          List<dynamic>.from(_mainForecast),
        );
      }
    });
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentPageIndex = index;
    });
    if (index == 0) {
      if (_mainLocationCache != null) {
        _applyLocationData(_mainLocationCache!);
      }
    } else {
      if (index - 1 < _extraLocations.length) {
        _applyLocationData(_extraLocations[index - 1]);
      }
    }
  }

  void _triggerPageIndicator() {
    // 每次有滑動，就先取消舊的 timer
    _indicatorHideTimer?.cancel();

    if (!_showPageIndicator) {
      setState(() {
        _showPageIndicator = true;
      });
    }

    // 停止一段時間沒動就自動隱藏
    _indicatorHideTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() {
        _showPageIndicator = false;
      });
    });
  }

  // ================== UI ==================

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          _buildBackground(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  _buildTopBar(scheme),
                  const SizedBox(height: 24),
                  Expanded(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        // 只處理 PageView 本身的滑動
                        if (notification.metrics is PageMetrics) {
                          if (notification is ScrollStartNotification ||
                              notification is ScrollUpdateNotification) {
                            _triggerPageIndicator(); // 有滑動就顯示／重置隱藏計時
                          }
                        }
                        return false; // 不攔截其他通知
                      },
                      child: PageView.builder(
                        controller: _pageController,
                        onPageChanged: _onPageChanged,
                        itemCount: 1 + _extraLocations.length,
                        itemBuilder: (context, index) {
                          return Center(child: _buildHeroArea());
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          // 底部的 details 箭頭按鈕
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildDetailsButton(),
              ),
            ),
          ),
          if (_isLoading || _error != null) _buildStateOverlay(scheme),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    final bool isDark = widget.isDark;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFF121212), Color(0xFF2A2A2A)]
              : const [Color(0xFFF7F0E6), Color(0xFFF0E4D6)], // Quite Light
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
    );
  }

  Widget _buildTopBar(ColorScheme scheme) {
    final name = _locationName.isEmpty ? "目前位置" : _locationName;
    final updateText = (_updatedAt != null)
        ? "${_updatedAt!.hour.toString().padLeft(2, '0')}:${_updatedAt!.minute.toString().padLeft(2, '0')}"
        : "--:--";

    final bool isDark = widget.isDark;
    final Color primaryText = isDark ? Colors.white : Colors.black;
    final Color secondaryText = isDark ? Colors.white70 : Colors.black54;
    final Color iconColor = isDark ? Colors.white : Colors.black87;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: primaryText,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                "Updated $updateText",
                style: TextStyle(fontSize: 11, color: secondaryText),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () async {
            await _getWeather(); // 更新目前位置
            await _refreshExtraLocations(); // 順便更新所有已儲存地點
          },
          tooltip: '重新整理',
          icon: Icon(Icons.refresh, color: iconColor),
        ),
        IconButton(
          onPressed: _addLocation,
          tooltip: '新增地點',
          icon: Icon(Icons.add_location_alt, color: iconColor),
        ),
        IconButton(
          onPressed: widget.onToggleTheme,
          tooltip: '切換主題',
          icon: Icon(
            isDark ? Icons.light_mode : Icons.dark_mode,
            color: iconColor,
          ),
        ),
      ],
    );
  }

  Widget _buildHeroArea() {
    final tempStr = _tempC != null ? _tempC!.toStringAsFixed(0) : "--";
    final desc = _description.isNotEmpty
        ? _description.toUpperCase()
        : "LOADING";

    final bool isDark = widget.isDark;
    final Color mainColor = isDark ? Colors.white : Colors.black;
    final Color secondary = isDark ? Colors.white70 : Colors.black54;

    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        const SizedBox(height: 64),
        Transform.scale(scale: 1.15, child: _buildWeatherIcon()),
        const SizedBox(height: 24),
        Text(
          tempStr,
          style: TextStyle(
            fontSize: 160,
            fontWeight: FontWeight.w900,
            letterSpacing: -10,
            color: mainColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          desc,
          style: TextStyle(fontSize: 18, letterSpacing: 4, color: secondary),
        ),
        const SizedBox(height: 24),
        _buildPageIndicator(),
      ],
    );
  }

  Widget _buildDetailsButton() {
    final bool isDark = widget.isDark;
    final Color iconColor = isDark ? Colors.white : Colors.black87;

    return IconButton(
      onPressed: _showDetailsBottomSheet,
      icon: Icon(Icons.keyboard_arrow_up, color: iconColor, size: 28),
    );
  }

  Widget _buildPageIndicator() {
    final int total = 1 + _extraLocations.length;

    // 只有一頁時就完全不顯示
    if (total <= 1) {
      return const SizedBox.shrink();
    }

    final bool isDark = widget.isDark;
    final Color activeColor = isDark ? Colors.white : Colors.black87;
    final Color inactiveColor = isDark ? Colors.white24 : Colors.black26;

    return AnimatedOpacity(
      opacity: _showPageIndicator ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(total, (index) {
          final bool isActive = index == _currentPageIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: isActive ? 8 : 6,
            height: isActive ? 8 : 6,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? activeColor : inactiveColor,
            ),
          );
        }),
      ),
    );
  }

  // 根據 OpenWeather 的 icon code 選擇不同的圖示樣式
  Widget _buildWeatherIcon() {
    final code = _iconCode ?? '';
    if (code.startsWith('01')) {
      // 晴天
      return _buildSunIcon();
    } else if (code.startsWith('02')) {
      // 少雲 / 晴時多雲
      return _buildSunCloudIcon();
    } else if (code.startsWith('09') ||
        code.startsWith('10') ||
        code.startsWith('11')) {
      // 各種雨 / 雷雨
      return _buildRainIcon();
    } else if (code.startsWith('13')) {
      // 下雪
      return _buildSnowIcon();
    } else if (code.startsWith('50')) {
      // 霧、薄霧
      return _buildFogIcon();
    } else {
      // 03/04 先用雲圖示
      return _buildCloudIcon();
    }
  }

  Widget _buildSunIcon() {
    final bool isDark = widget.isDark;
    return SizedBox(
      width: 180,
      height: 110,
      child: Center(
        child: Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: isDark
                  ? const [Color(0xFFFFF9C4), Color(0xFFFFD54F)]
                  : const [Color(0xFFFFF176), Color(0xFFFFC107)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 20,
                offset: const Offset(0, 8),
                color: Colors.black.withOpacity(0.35),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSunCloudIcon() {
    final bool isDark = widget.isDark;
    return SizedBox(
      width: 180,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 太陽
          Positioned(
            top: 0,
            left: 30,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: isDark
                      ? const [Color(0xFFFFF9C4), Color(0xFFFFD54F)]
                      : const [Color(0xFFFFF176), Color(0xFFFFC107)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                    color: Colors.black.withOpacity(0.3),
                  ),
                ],
              ),
            ),
          ),
          // 雲遮住部分太陽
          Positioned(top: 28, left: 0, right: 0, child: _buildCloudIcon()),
        ],
      ),
    );
  }

  Widget _buildFogIcon() {
    final bool isDark = widget.isDark;
    final Color lineColor = isDark
        ? Colors.white.withOpacity(0.35)
        : Colors.black.withOpacity(0.25);

    return SizedBox(
      width: 180,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: 10, left: 15, right: 15, child: _buildCloudIcon()),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Container(
                  height: 3,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: lineColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRainIcon() {
    final bool isDark = widget.isDark;
    final Color dropColor = isDark
        ? const Color(0xFF81D4FA)
        : const Color(0xFF0288D1);

    return SizedBox(
      width: 180,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 雲
          Positioned(top: 0, left: 0, right: 0, child: _buildCloudIcon()),
          // 雨滴，多一點密度
          Positioned(top: 70, left: 25, child: _rainDrop(10, 3, dropColor)),
          Positioned(top: 68, left: 55, child: _rainDrop(14, 3, dropColor)),
          Positioned(top: 72, left: 85, child: _rainDrop(12, 3, dropColor)),
          Positioned(top: 69, left: 115, child: _rainDrop(15, 3, dropColor)),
          Positioned(top: 73, left: 145, child: _rainDrop(11, 3, dropColor)),
          Positioned(
            top: 78,
            left: 40,
            child: _rainDrop(9, 3, dropColor.withOpacity(0.8)),
          ),
          Positioned(
            top: 80,
            left: 100,
            child: _rainDrop(13, 3, dropColor.withOpacity(0.9)),
          ),
        ],
      ),
    );
  }

  Widget _rainDrop(double height, double width, Color color) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(width),
      ),
    );
  }

  Widget _buildSnowIcon() {
    final bool isDark = widget.isDark;
    final Color flakeColor = isDark
        ? Colors.white.withOpacity(0.9)
        : Colors.black.withOpacity(0.75);

    return SizedBox(
      width: 180,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 雲
          Positioned(top: 0, left: 0, right: 0, child: _buildCloudIcon()),
          // 雪花，比雨少一點
          Positioned(top: 76, left: 40, child: _snowFlake(flakeColor, 10)),
          Positioned(top: 82, left: 80, child: _snowFlake(flakeColor, 12)),
          Positioned(top: 78, left: 120, child: _snowFlake(flakeColor, 10)),
        ],
      ),
    );
  }

  Widget _snowFlake(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.2),
      ),
      child: Center(
        child: Container(
          width: size * 0.3,
          height: size * 0.3,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
      ),
    );
  }

  Widget _buildCloudIcon() {
    final bool isDark = widget.isDark;
    return SizedBox(
      width: 180,
      height: 110,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 40,
            left: 10,
            right: 10,
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.15)
                    : const Color(0xFF4C4C4C),
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                    color: isDark
                        ? Colors.black.withOpacity(0.6)
                        : Colors.black38,
                  ),
                ],
              ),
            ),
          ),
          Positioned(top: 10, left: 15, child: _cloudCircle(56, isDark)),
          Positioned(top: 0, left: 56, child: _cloudCircle(70, isDark)),
          Positioned(top: 16, right: 20, child: _cloudCircle(52, isDark)),
          Positioned(top: 32, right: -4, child: _cloudCircle(32, isDark)),
          Positioned(top: 32, left: -8, child: _cloudCircle(30, isDark)),
        ],
      ),
    );
  }

  Widget _cloudCircle(double size, bool isDark) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: isDark
              ? const [Color(0xFFE0E0E0), Color(0xFFBDBDBD)]
              : const [Color(0xFF555555), Color(0xFF888888)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 6),
            color: isDark ? Colors.black.withOpacity(0.7) : Colors.black26,
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineBar() {
    if (_mainForecast.isEmpty) {
      return const SizedBox.shrink();
    }

    final temps = _mainForecast
        .map((e) => e['temp'] as double?)
        .whereType<double>()
        .toList();
    final double? minT = temps.isEmpty
        ? null
        : temps.reduce((a, b) => math.min(a, b));
    final double? maxT = temps.isEmpty
        ? null
        : temps.reduce((a, b) => math.max(a, b));

    final int itemCount = _mainForecast.length > 8 ? 8 : _mainForecast.length;

    final bool isDark = widget.isDark;
    final Color primary = isDark ? Colors.white : Colors.black;
    final Color secondary = isDark ? Colors.white70 : Colors.black54;
    final Color chipBg = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.04);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TODAY',
          style: TextStyle(fontSize: 12, letterSpacing: 3, color: secondary),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          decoration: BoxDecoration(
            color: chipBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            children: [
              Text('NOW', style: TextStyle(fontSize: 12, color: secondary)),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    itemCount: itemCount,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (_, index) {
                      final f = _mainForecast[index];
                      String time = '';
                      if (f['dt_txt'] != null) {
                        final parts = (f['dt_txt'] as String).split(' ');
                        if (parts.length == 2) {
                          time = parts[1].substring(0, 5); // HH:MM
                        }
                      }
                      final temp = (f['temp'] is double)
                          ? f['temp'] as double
                          : null;
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            time,
                            style: TextStyle(fontSize: 11, color: secondary),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: secondary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            temp != null ? "${temp.toStringAsFixed(0)}°" : "--",
                            style: TextStyle(fontSize: 11, color: primary),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (minT != null && maxT != null) ...[
                const SizedBox(width: 12),
                Text(
                  "H/L ${maxT.toStringAsFixed(0)}° / ${minT.toStringAsFixed(0)}°",
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsSheetContent(
    ColorScheme scheme,
    ScrollController scrollController,
  ) {
    final bool isDark = widget.isDark;
    final Color sheetColor = isDark
        ? const Color(0xFF202020)
        : const Color(0xFFF7F0E6);
    final Color handleColor = isDark ? Colors.white38 : Colors.black26;
    final Color titleColor = isDark ? Colors.white70 : Colors.black54;

    return Container(
      decoration: BoxDecoration(
        color: sheetColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: const [
          BoxShadow(
            blurRadius: 20,
            offset: Offset(0, -10),
            color: Colors.black45,
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: handleColor,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
              children: [
                _buildTimelineBar(),
                const SizedBox(height: 12),
                _buildDetailGrid(),
                const SizedBox(height: 20),
                _buildDailyForecastSection(),
                if (_extraLocations.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'SAVED LOCATIONS',
                    style: TextStyle(
                      fontSize: 14,
                      letterSpacing: 2,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._extraLocations
                      .map((loc) => _buildSavedLocationTile(loc))
                      .toList(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDetailsBottomSheet() {
    if (_isLoading || _error != null) return;

    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return _buildDetailsSheetContent(
              theme.colorScheme,
              scrollController,
            );
          },
        );
      },
    );
  }

  Widget _buildDailyForecastSection() {
    if (_dailyForecast.isEmpty) {
      return const SizedBox.shrink();
    }

    final bool isDark = widget.isDark;
    final Color secondary = isDark ? Colors.white70 : Colors.black54;
    final Color primary = isDark ? Colors.white : Colors.black87;
    final Color rowBg = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.03);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '5-DAY FORECAST',
          style: TextStyle(fontSize: 14, letterSpacing: 2, color: secondary),
        ),
        const SizedBox(height: 8),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _dailyForecast.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final day = _dailyForecast[index];
            final dateStr = day['date'] as String? ?? '';
            DateTime? dt;
            try {
              dt = DateTime.tryParse(dateStr);
            } catch (_) {
              dt = null;
            }
            String label = dateStr;
            if (dt != null) {
              const weekNames = [
                'MON',
                'TUE',
                'WED',
                'THU',
                'FRI',
                'SAT',
                'SUN',
              ];
              final w = weekNames[dt.weekday - 1];
              label = "$w ${dt.month}/${dt.day}";
            }

            final double? minT = (day['min'] is num)
                ? (day['min'] as num).toDouble()
                : null;
            final double? maxT = (day['max'] is num)
                ? (day['max'] as num).toDouble()
                : null;
            final iconCode = day['icon'] as String?;

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: rowBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 12, color: secondary),
                    ),
                  ),
                  if (iconCode != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Image.network(
                        "https://openweathermap.org/img/wn/$iconCode@2x.png",
                        width: 32,
                        height: 32,
                      ),
                    ),
                  Text(
                    (maxT != null && minT != null)
                        ? "${maxT.toStringAsFixed(0)}° / ${minT.toStringAsFixed(0)}°"
                        : "-- / --",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: primary,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildDetailGrid() {
    final items = <Map<String, String>>[];
    if (_humidity != null) {
      items.add({'label': '濕度', 'value': '${_humidity!}%'});
    }
    if (_wind != null) {
      items.add({'label': '風速', 'value': '${_wind!.toStringAsFixed(1)} m/s'});
    }

    final bool isDark = widget.isDark;
    final Color primary = isDark ? Colors.white : Colors.black87;
    final Color secondary = isDark ? Colors.white70 : Colors.black54;
    final Color cardBg = isDark
        ? Colors.white.withOpacity(0.05)
        : Colors.black.withOpacity(0.03);

    if (items.isEmpty) {
      return Text('暫無詳細資訊', style: TextStyle(fontSize: 13, color: secondary));
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 10,
        childAspectRatio: 2.0,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                item['label']!,
                style: TextStyle(fontSize: 12, color: secondary),
              ),
              const SizedBox(height: 4),
              Text(
                item['value']!,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSavedLocationTile(Map<String, dynamic> loc) {
    final name = loc['locationName'] as String? ?? '未知地點';
    final temp = (loc['tempC'] as num?)?.toDouble();
    final desc = loc['description'] as String? ?? '';
    final updatedAt = loc['updatedAt'];
    String updateText = '';
    if (updatedAt is DateTime) {
      updateText =
          "${updatedAt.hour.toString().padLeft(2, '0')}:${updatedAt.minute.toString().padLeft(2, '0')}";
    }
    final bool isDark = widget.isDark;
    final Color secondary = isDark ? Colors.white70 : Colors.black54;

    return Dismissible(
      key: ValueKey(name + (loc['lat']?.toString() ?? '')),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Colors.redAccent,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        setState(() {
          _extraLocations.remove(loc);
        });
        _saveLocations();
      },
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: () => _applyLocationData(loc),
        leading: loc['iconCode'] != null
            ? Image.network(
                "https://openweathermap.org/img/wn/${loc['iconCode']}@2x.png",
                width: 40,
                height: 40,
              )
            : const Icon(Icons.location_on_outlined),
        title: Text(
          name,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          desc,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              temp != null ? "${temp.toStringAsFixed(1)}°C" : "--",
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (updateText.isNotEmpty)
              Text(
                updateText,
                style: TextStyle(fontSize: 11, color: secondary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateOverlay(ColorScheme scheme) {
    final bool isDark = widget.isDark;
    final Color overlayColor = isDark
        ? Colors.black.withOpacity(0.6)
        : Colors.white.withOpacity(0.6);
    final Color textColor = isDark ? Colors.white : Colors.black87;

    if (_isLoading) {
      return Container(
        color: overlayColor,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Container(
        color: overlayColor,
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                color: Colors.redAccent,
                size: 40,
              ),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: textColor),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _getWeather,
                icon: const Icon(Icons.refresh),
                label: const Text('重試'),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
