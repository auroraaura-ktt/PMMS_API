import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import 'firebase_options.dart';
import 'services/http_client.dart';

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel _pmmsNotificationChannel =
    AndroidNotificationChannel(
      'pmms_notifications',
      'PMMS Notifications',
      description: 'Notifications from Pocket Money Management System',
      importance: Importance.high,
    );

Future<void> _initializeLocalNotifications({
  DidReceiveNotificationResponseCallback? onNotificationResponse,
}) async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const darwinSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );

  const settings = InitializationSettings(
    android: androidSettings,
    iOS: darwinSettings,
    macOS: darwinSettings,
  );

  await _localNotifications.initialize(
    settings: settings,
    onDidReceiveNotificationResponse: onNotificationResponse,
  );

  await _localNotifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(_pmmsNotificationChannel);
}

Future<void> _showPmmsNotification(RemoteMessage message) async {
  final title =
      message.notification?.title ??
      message.data['title']?.toString() ??
      'PMMS';

  final body =
      message.notification?.body ?? message.data['body']?.toString() ?? '';

  if (title.trim().isEmpty && body.trim().isEmpty) return;

  await _localNotifications.show(
    id:
        (message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch) &
        0x7fffffff,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'pmms_notifications',
        'PMMS Notifications',
        channelDescription: 'Notifications from Pocket Money Management System',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: jsonEncode(message.data),
  );
}

final _pmmsThemeMode = ValueNotifier<ThemeMode>(ThemeMode.light);

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(
    ValueListenableBuilder<ThemeMode>(
      valueListenable: _pmmsThemeMode,
      builder: (_, mode, _) => PmmsApp(themeMode: mode),
    ),
  );
}

const ink = Color(0xFF1F2937);
const navy = Color(0xFF092D72);
const teal = Color(0xFF245CFF);
const purple = Color(0xFF8746F7);
const canvas = Color(0xFFF8FBFF);

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = _pmmsThemeMode.value == ThemeMode.dark;
    return IconButton(
      tooltip: isDark ? 'Switch to light theme' : 'Switch to dark theme',
      onPressed: () {
        _pmmsThemeMode.value = isDark ? ThemeMode.light : ThemeMode.dark;
      },
      icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
    );
  }
}

class Api {
  Api({
    http.Client? client,
    SessionCookieStorage? sessionStorage,
    this.persistSession = false,
  }) : client = client ?? createPmmsHttpClient(),
       _sessionStorage = sessionStorage ?? const SessionCookieStorage();

  static const _sessionCookiesKey = 'pmms_session_cookies';

  final http.Client client;
  final SessionCookieStorage _sessionStorage;
  final bool persistSession;
  final Map<String, String> _cookies = {};
  VoidCallback? onUnauthorized;
  String? csrfToken;

  bool get _shouldPersistCookies =>
      persistSession &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> restoreSession() async {
    if (!_shouldPersistCookies) return;
    final savedCookies = await _sessionStorage.read(_sessionCookiesKey);
    if (savedCookies == null) return;

    final decoded = jsonDecode(savedCookies);
    if (decoded is! Map<String, dynamic> ||
        decoded.values.any((value) => value is! String)) {
      throw const FormatException('Saved PMMS sign-in data is invalid.');
    }
    _cookies.addAll(decoded.cast<String, String>());
  }

  Map<String, String> _requestHeaders() {
    final headers = <String, String>{'Accept': 'application/json'};
    if (!kIsWeb && _cookies.isNotEmpty) {
      headers['Cookie'] = _cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
    }
    return headers;
  }

  Future<void> _rememberCookies(http.Response response) async {
    if (kIsWeb) return;
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;

    var changed = false;
    for (final cookie in setCookie.split(RegExp(r',\s*(?=[^;,]+=)'))) {
      final parts = cookie.split(';');
      final pair = parts.first.trim();
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;

      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      final expired =
          value.isEmpty ||
          parts
              .skip(1)
              .any(
                (attribute) => attribute.trim().toLowerCase() == 'max-age=0',
              );
      if (expired) {
        changed = _cookies.remove(name) != null || changed;
      } else if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }

    if (!changed || !_shouldPersistCookies) return;
    if (_cookies.isEmpty) {
      await _sessionStorage.delete(_sessionCookiesKey);
    } else {
      await _sessionStorage.write(_sessionCookiesKey, jsonEncode(_cookies));
    }
  }

  Uri uri(String path) {
    const configuredApiBaseUrl = String.fromEnvironment('PMMS_API_BASE_URL');
    final base = configuredApiBaseUrl.isNotEmpty
        ? Uri.parse(configuredApiBaseUrl)
        : kIsWeb
        ? Uri.base
        : Uri.parse('https://pmms-api-w6at.vercel.app/');
    return base.resolve(path);
  }

  Future<Map<String, dynamic>> get(
    String path, {
    bool notifyUnauthorized = true,
  }) async {
    final timer = Stopwatch()..start();
    final response = await client
        .get(uri(path), headers: _requestHeaders())
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw ApiException(
            0,
            'The server took too long to respond. Try again.',
          ),
        );
    await _rememberCookies(response);
    final parseTimer = Stopwatch()..start();
    try {
      return _decode(response, notifyUnauthorized: notifyUnauthorized);
    } finally {
      _trace(
        'GET',
        path,
        response.statusCode,
        timer.elapsedMilliseconds,
        parseTimer.elapsedMilliseconds,
      );
    }
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, String> fields,
  ) async {
    if (csrfToken == null) {
      final timer = Stopwatch()..start();
      final seed = await client
          .get(uri('/api/v1/csrf/'), headers: _requestHeaders())
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw ApiException(
              0,
              'The server took too long to respond. Try again.',
            ),
          );
      await _rememberCookies(seed);
      final parseTimer = Stopwatch()..start();
      try {
        csrfToken = _decode(seed)['csrfToken'] as String?;
      } finally {
        _trace(
          'GET',
          '/api/v1/csrf/',
          seed.statusCode,
          timer.elapsedMilliseconds,
          parseTimer.elapsedMilliseconds,
        );
      }
    }
    final timer = Stopwatch()..start();
    final response = await client
        .post(
          uri(path),
          headers: {
            ..._requestHeaders(),
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-CSRFToken': csrfToken ?? '',
          },
          body: fields,
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw ApiException(
            0,
            'The server took too long to respond. Try again.',
          ),
        );
    await _rememberCookies(response);
    final parseTimer = Stopwatch()..start();
    late final Map<String, dynamic> decoded;
    try {
      decoded = _decode(response);
    } finally {
      _trace(
        'POST',
        path,
        response.statusCode,
        timer.elapsedMilliseconds,
        parseTimer.elapsedMilliseconds,
      );
    }
    // Django rotates the CSRF token when authentication changes. Do not block
    // the post-login transition on a second request: fetch the new token only
    // when the user next performs a protected write.
    if (path == '/api/v1/auth/login/' ||
        path == '/api/v1/auth/register/' ||
        path == '/api/v1/auth/logout/') {
      csrfToken = null;
    }
    return decoded;
  }

  Map<String, dynamic> _decode(
    http.Response response, {
    bool notifyUnauthorized = true,
  }) {
    dynamic decoded;
    try {
      decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on FormatException {
      final message = response.statusCode == 404
          ? 'The configured server does not provide this PMMS API route (HTTP 404).'
          : 'The server returned an invalid response (HTTP ${response.statusCode}).';
      throw ApiException(response.statusCode, message);
    }
    if (response.statusCode == 401 && notifyUnauthorized) {
      onUnauthorized?.call();
    }
    if (decoded is Map<String, dynamic> && response.statusCode < 400) {
      return decoded;
    }
    final detail = decoded is Map
        ? (decoded['errors'] ?? decoded['error'] ?? decoded['detail'])
        : null;
    throw ApiException(
      response.statusCode,
      _formatError(detail) ?? 'Request failed (${response.statusCode}).',
    );
  }

  void _trace(
    String method,
    String path,
    int status,
    int requestMs,
    int parseMs,
  ) {
    if (!kDebugMode) return;
    final safePath = path.replaceAll(RegExp(r'/\d+(?=/|$)'), '/:id');
    debugPrint(
      'PMMS $method $safePath status=$status request=${requestMs}ms parse=${parseMs}ms',
    );
  }
}

String? _formatError(dynamic value) {
  if (value is String) return value;
  if (value is List) {
    final items = value.map(_formatError).whereType<String>().toList();
    return items.isEmpty ? null : items.join(' ');
  }
  if (value is Map) {
    final messages = <String>[];
    for (final entry in value.entries) {
      final label = entry.key == '__all__' ? '' : '${entry.key}: ';
      final message = _formatError(entry.value);
      if (message != null) messages.add('$label$message');
    }
    return messages.isEmpty ? null : messages.join('\n');
  }
  return null;
}

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class SessionCookieStorage {
  const SessionCookieStorage();

  static const _channel = MethodChannel('pmms/session_storage');

  Future<String?> read(String key) =>
      _channel.invokeMethod<String>('read', {'key': key});

  Future<void> write(String key, String value) =>
      _channel.invokeMethod<void>('write', {'key': key, 'value': value});

  Future<void> delete(String key) =>
      _channel.invokeMethod<void>('delete', {'key': key});
}

typedef PmmsPushRegistrationHandler = Future<void> Function(
  String installationId,
);

class PmmsApp extends StatefulWidget {
  PmmsApp({
    super.key,
    Api? api,
    this.themeMode = ThemeMode.light,
    this.onPushRegistration,
    this.onNotificationOpened,
  }) : api = api ?? Api(persistSession: true);

  final Api api;
  final ThemeMode themeMode;
  final PmmsPushRegistrationHandler? onPushRegistration;
  final ValueChanged<Map<String, dynamic>>? onNotificationOpened;

  @override
  State<PmmsApp> createState() => _PmmsAppState();
}

class _PmmsAppState extends State<PmmsApp> {
  late final Api api = widget.api;
  final navigatorKey = GlobalKey<NavigatorState>();
  Map<String, dynamic>? user;
  bool checking = true;
  bool showLogin = false;
  bool registering = false;
  bool adminLogin = false;
  StreamSubscription<RemoteMessage>? _foregroundMessageSubscription;
  StreamSubscription<RemoteMessage>? _notificationOpenedSubscription;
  StreamSubscription<String>? _messagingRegistrationSubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_setupPushNotifications());
    api.onUnauthorized = _sessionExpired;
    api
        .restoreSession()
        .then((_) => api.get('/api/v1/auth/me/', notifyUnauthorized: false))
        .then((value) {
          if (mounted && checking) {
            setState(() {
              user = value;
              checking = false;
            });
          }
        })
        .catchError((_) {
          if (mounted && checking) {
            setState(() {
              checking = false;
            });
          }
        });
  }

  Future<void> _setupPushNotifications() async {
    if (!{
      TargetPlatform.android,
      TargetPlatform.iOS,
    }.contains(defaultTargetPlatform)) {
      return;
    }

    try {
      if (Firebase.apps.isEmpty) return;

      final messaging = FirebaseMessaging.instance;
      await _initializeLocalNotifications(
        onNotificationResponse: _handleLocalNotificationResponse,
      );

      final permission = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('PMMS notifications permission denied.');
        return;
      }
      if (!mounted) return;

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert: false,
          badge: false,
          sound: false,
        );
      }

      _foregroundMessageSubscription = FirebaseMessaging.onMessage.listen(
        (message) => unawaited(_showForegroundNotification(message)),
        onError: (Object error, StackTrace stackTrace) =>
            _reportNotificationError(error, stackTrace, 'receiving a message'),
      );
      _notificationOpenedSubscription = FirebaseMessaging.onMessageOpenedApp
          .listen(
            (message) => _handleNotificationOpened(message.data),
            onError: (Object error, StackTrace stackTrace) =>
                _reportNotificationError(
                  error,
                  stackTrace,
                  'opening a notification',
                ),
          );
      _messagingRegistrationSubscription = messaging.onRegistered.listen(
        _registerPushInstallation,
        onError: (Object error, StackTrace stackTrace) =>
            _reportNotificationError(
              error,
              stackTrace,
              'registering for push notifications',
            ),
      );

      await messaging.register();
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _handleNotificationOpened(initialMessage.data);
      }
    } catch (error, stackTrace) {
      _reportNotificationError(
        error,
        stackTrace,
        'initializing push notifications',
      );
    }
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    try {
      await _showPmmsNotification(message);
    } catch (error, stackTrace) {
      _reportNotificationError(error, stackTrace, 'showing a notification');
    }
  }

  void _handleLocalNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;

    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Notification payload must be an object.');
      }
      _handleNotificationOpened(decoded);
    } catch (error, stackTrace) {
      _reportNotificationError(
        error,
        stackTrace,
        'reading a notification payload',
      );
    }
  }

  void _handleNotificationOpened(Map<String, dynamic> data) {
    try {
      widget.onNotificationOpened?.call(data);
    } catch (error, stackTrace) {
      _reportNotificationError(
        error,
        stackTrace,
        'handling a notification tap',
      );
    }
  }

  Future<void> _registerPushInstallation(String installationId) async {
    final handler = widget.onPushRegistration;
    if (handler == null) return;

    try {
      await handler(installationId);
    } catch (error, stackTrace) {
      _reportNotificationError(
        error,
        stackTrace,
        'saving the push registration',
      );
    }
  }

  void _reportNotificationError(
    Object error,
    StackTrace stackTrace,
    String operation,
  ) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'PMMS notifications',
        context: ErrorDescription('while $operation'),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_foregroundMessageSubscription?.cancel());
    unawaited(_notificationOpenedSubscription?.cancel());
    unawaited(_messagingRegistrationSubscription?.cancel());
    super.dispose();
  }

  void signedIn(Map<String, dynamic> value) => setState(() {
    user = value['user'] as Map<String, dynamic>?;
    checking = false;
  });
  void signedOut() => setState(() {
    user = null;
  });

  void _sessionExpired() {
    if (!mounted || user == null) return;
    setState(() {
      user = null;
      showLogin = false;
    });
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          onLogin: () => _openLogin(),
          onRegister: () => _openLogin(registering: true),
          onAdminLogin: () => _openLogin(admin: true),
        ),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    title: "PMMS by K's",
    themeMode: widget.themeMode,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: teal, primary: navy),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        foregroundColor: navy,
        surfaceTintColor: Colors.white,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    darkTheme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF101A35),
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        brightness: Brightness.dark,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF172544),
        foregroundColor: Color(0xFFEEF3FF),
      ),
      cardTheme: const CardThemeData(color: Color(0xFF1A2947)),
    ),
    home: checking
        ? showLogin
              ? LoginScreen(
                  api: api,
                  onLogin: signedIn,
                  onCancel: () => setState(() {
                    showLogin = false;
                  }),
                  initiallyRegistering: registering,
                  adminOnly: adminLogin,
                )
              : HomeScreen(
                  onLogin: () => _openLogin(),
                  onRegister: () => _openLogin(registering: true),
                  onAdminLogin: () => _openLogin(admin: true),
                )
        : user == null
        ? showLogin
              ? LoginScreen(
                  api: api,
                  onLogin: signedIn,
                  onCancel: () => setState(() {
                    showLogin = false;
                  }),
                  initiallyRegistering: registering,
                  adminOnly: adminLogin,
                )
              : HomeScreen(
                  onLogin: () => _openLogin(),
                  onRegister: () => _openLogin(registering: true),
                  onAdminLogin: () => _openLogin(admin: true),
                )
        : DashboardScreen(api: api, user: user!, onLogout: signedOut),
  );

  void _openLogin({bool registering = false, bool admin = false}) {
    setState(() {
      showLogin = true;
      this.registering = registering;
      adminLogin = admin;
    });
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.onLogin,
    required this.onRegister,
    required this.onAdminLogin,
  });
  final VoidCallback onLogin;
  final VoidCallback onRegister;
  final VoidCallback onAdminLogin;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF8FBFF), Colors.white, Color(0xFFF5F7FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: Colors.white.withValues(alpha: 0.96),
            title: Image.asset(
              'assets/pmms-logo.jpg',
              height: 52,
              fit: BoxFit.contain,
            ),
            actions: [
              const ThemeToggleButton(),
              TextButton(onPressed: onLogin, child: const Text('Login')),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(
                  onPressed: onRegister,
                  child: const Text('Register'),
                ),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1240),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 36, 24, 48),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 760;
                          final copy = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                'SMARTER SPENDING  ·  BRIGHTER FUTURE',
                                style: TextStyle(
                                  color: teal,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                "PMMS by K's",
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(
                                      color: navy,
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Pocket Money Management System',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(color: navy),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Track your budget, manage daily expenses, and get insightful reports in one place.',
                                style: TextStyle(
                                  color: Color(0xFF385A91),
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 24),
                              Wrap(
                                spacing: 12,
                                runSpacing: 10,
                                children: [
                                  FilledButton.icon(
                                    onPressed: onRegister,
                                    icon: const Icon(Icons.arrow_forward),
                                    label: const Text('Get started'),
                                  ),
                                  OutlinedButton(
                                    onPressed: onLogin,
                                    child: const Text('Sign in'),
                                  ),
                                ],
                              ),
                            ],
                          );
                          final art = ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              Uri.base
                                  .resolve('/static/images/hero-wallet.jpg')
                                  .toString(),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: Color(0xFFEAF1FF),
                                child: Center(
                                  child: Icon(
                                    Icons.account_balance_wallet_outlined,
                                    size: 96,
                                    color: teal,
                                  ),
                                ),
                              ),
                            ),
                          );
                          return compact
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    copy,
                                    const SizedBox(height: 28),
                                    SizedBox(height: 260, child: art),
                                  ],
                                )
                              : Row(
                                  children: [
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          right: 36,
                                        ),
                                        child: copy,
                                      ),
                                    ),
                                    Expanded(
                                      child: AspectRatio(
                                        aspectRatio: 1.35,
                                        child: art,
                                      ),
                                    ),
                                  ],
                                );
                        },
                      ),
                      const SizedBox(height: 38),
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: const [
                          _HomeFeature(
                            icon: Icons.account_balance_wallet_outlined,
                            title: 'Budget planning',
                            text:
                                'Set monthly balances and category estimates.',
                          ),
                          _HomeFeature(
                            icon: Icons.edit_calendar_outlined,
                            title: 'Daily tracking',
                            text: 'Record direct and Sub Balance spending.',
                          ),
                          _HomeFeature(
                            icon: Icons.query_stats_outlined,
                            title: 'Smart reports',
                            text: 'Review backend-calculated totals and comparisons.',
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
                      const Divider(),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              "PMMS by K's · Small steps. Better habits. Bigger goals.",
                              style: TextStyle(color: Color(0xFF385A91)),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: onAdminLogin,
                            icon: const Icon(
                              Icons.admin_panel_settings_outlined,
                            ),
                            label: const Text('Administrator login'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _HomeFeature extends StatelessWidget {
  const _HomeFeature({
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: teal),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: navy,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(text, style: const TextStyle(color: Color(0xFF385A91))),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.api,
    required this.onLogin,
    required this.onCancel,
    this.initiallyRegistering = false,
    this.adminOnly = false,
  });
  final Api api;
  final ValueChanged<Map<String, dynamic>> onLogin;
  final VoidCallback onCancel;
  final bool initiallyRegistering;
  final bool adminOnly;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController();
  final password = TextEditingController();
  final email = TextEditingController();
  final confirm = TextEditingController();
  late bool registering = widget.initiallyRegistering;
  bool busy = false;
  String? error;

  Future<void> submit() async {
    final loginTimer = Stopwatch()..start();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.post(
        registering ? '/api/v1/auth/register/' : '/api/v1/auth/login/',
        registering
            ? {
                'username': username.text,
                'email': email.text,
                'password1': password.text,
                'password2': confirm.text,
              }
            : {'username': username.text, 'password': password.text},
      );
      final authenticatedUser = result['user'] as Map<String, dynamic>? ?? {};
      if (widget.adminOnly && authenticatedUser['isStaff'] != true) {
        await widget.api.post('/api/v1/auth/logout/', {});
        if (mounted) {
          setState(() {
            error = 'This account does not have administrator privileges.';
          });
        }
        return;
      }
      // Authentication has succeeded and Django's login response already
      // identifies the authorized user. Show the dashboard shell immediately;
      // its own FutureBuilder keeps protected data gated by the API response.
      widget.onLogin(result);
      if (kDebugMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          debugPrint(
            'PMMS login-flow authenticated-screen=${loginTimer.elapsedMilliseconds}ms',
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
        });
      }
    }
    if (mounted) {
      setState(() {
        busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text("PMMS by K's"),
      leading: IconButton(
        tooltip: 'Back to home',
        onPressed: widget.onCancel,
        icon: const Icon(Icons.arrow_back),
      ),
      actions: const [ThemeToggleButton()],
    ),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Image.asset(
                          'assets/pmms-logo.jpg',
                          height: 88,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.account_balance_wallet,
                            size: 64,
                            color: teal,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.adminOnly
                              ? 'Administrator Login'
                              : registering
                              ? 'Create your account'
                              : 'Welcome back',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: navy,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: username,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                          ),
                        ),
                        if (registering) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: email,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: password,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                          ),
                        ),
                        if (registering) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: confirm,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                            ),
                          ),
                        ],
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: busy ? null : submit,
                          child: Text(
                            busy
                                ? 'Please wait…'
                                : registering
                                ? 'Create account'
                                : 'Sign in',
                          ),
                        ),
                        TextButton(
                          onPressed: widget.onCancel,
                          child: const Text('Back'),
                        ),
                        if (!widget.adminOnly)
                          TextButton(
                            onPressed: () => setState(() {
                              registering = !registering;
                              error = null;
                            }),
                            child: Text(
                              registering
                                  ? 'Already registered? Sign in'
                                  : 'Create an account',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.api,
    required this.user,
    required this.onLogout,
  });
  final Api api;
  final Map<String, dynamic> user;
  final VoidCallback onLogout;
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<Map<String, dynamic>> future;
  List<Map<String, dynamic>> balances = [];
  List<Map<String, dynamic>> months = [];
  int selectedTab = 0;
  @override
  void initState() {
    super.initState();
    future = widget.api.get('/api/v1/dashboard/');
  }

  void reload() => setState(() {
    future = widget.api.get('/api/v1/dashboard/');
  });

  Future<void> logout() async {
    try {
      await widget.api.post('/api/v1/auth/logout/', {});
      widget.onLogout();
    } catch (e) {
      _message(e.toString());
    }
  }

  Future<void> createMonth() async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => CreateMonthDialog(balances: balances),
    );
    if (values == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {
        'action': 'create_budget',
        ...values,
      });
      reload();
    } catch (e) {
      _message(e.toString());
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Image.asset(
        'assets/pmms-logo.jpg',
        height: 48,
        fit: BoxFit.contain,
      ),
      actions: [
        const ThemeToggleButton(),
        TextButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ReportsScreen(api: widget.api, months: months),
            ),
          ),
          icon: const Icon(Icons.bar_chart),
          label: const Text('Reports'),
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'logout') {
              logout();
            }
            if (value == 'password') {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PasswordScreen(api: widget.api),
                ),
              );
            }
            if (value == 'admin') {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AdminScreen(api: widget.api)),
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Text('Signed in as ${widget.user['username'] ?? ''}'),
            ),
            const PopupMenuItem(
              value: 'password',
              child: Text('Change password'),
            ),
            if (widget.user['isStaff'] == true)
              const PopupMenuItem(value: 'admin', child: Text('Admin tools')),
            const PopupMenuItem(value: 'logout', child: Text('Sign out')),
          ],
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Column(
            children: [
              _dashboardTabs(),
              const LinearProgressIndicator(minHeight: 2),
              Expanded(child: _DashboardLoading(user: widget.user)),
            ],
          );
        }
        if (snapshot.hasError) {
          return Column(
            children: [
              _dashboardTabs(),
              Expanded(
                child: ErrorPanel(
                  message: snapshot.error.toString(),
                  onRetry: reload,
                ),
              ),
            ],
          );
        }
        final data = snapshot.data!;
        months = (data['months'] as List? ?? []).cast<Map<String, dynamic>>();
        balances = (data['balances'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        return Column(
          children: [
            _dashboardTabs(),
            Expanded(child: _tabContent(data)),
          ],
        );
      },
    ),
  );

  Widget _dashboardTabs() => Material(
    color: Colors.white,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(4, (index) {
          const labels = ['Setup', 'Budget', 'Daily Expenses', 'Summary'];
          return InkWell(
            onTap: () => setState(() {
              selectedTab = index;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: selectedTab == index ? teal : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Text(
                '${index + 1}. ${labels[index]}',
                style: TextStyle(
                  color: selectedTab == index ? teal : const Color(0xFF385A91),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }),
      ),
    ),
  );

  Widget _tabContent(Map<String, dynamic> data) {
    switch (selectedTab) {
      case 0:
        return SetupTab(
          api: widget.api,
          data: data,
          onChanged: reload,
          onCreateMonth: createMonth,
        );
      case 1:
        return BudgetTab(api: widget.api, data: data, onChanged: reload);
      case 2:
        return ExpensesTab(api: widget.api, data: data, onChanged: reload);
      default:
        return SummaryTab(data: data);
    }
  }
}

class _DashboardLoading extends StatelessWidget {
  const _DashboardLoading({required this.user});
  final Map<String, dynamic> user;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Hello, ${user['name'] ?? user['username'] ?? ''}',
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(color: navy, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      const Text(
        'Your monthly money overview',
        style: TextStyle(color: Color(0xFF385A91)),
      ),
      const SizedBox(height: 24),
      const Text(
        'Loading your balances…',
        style: TextStyle(color: Color(0xFF385A91)),
      ),
    ],
  );
}

class _FormFieldSpec {
  const _FormFieldSpec(
    this.name,
    this.label, {
    this.initial = '',
    this.required = false,
    this.choices,
  });
  final String name;
  final String label;
  final String initial;
  final bool required;
  final Map<String, String>? choices;
}

class _DataFormDialog extends StatefulWidget {
  const _DataFormDialog({
    required this.title,
    required this.fields,
    this.submitLabel = 'Save',
  });
  final String title;
  final List<_FormFieldSpec> fields;
  final String submitLabel;
  @override
  State<_DataFormDialog> createState() => _DataFormDialogState();
}

class _DataFormDialogState extends State<_DataFormDialog> {
  final formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> controllers = {
    for (final field in widget.fields)
      field.name: TextEditingController(text: field.initial),
  };
  final selections = <String, String?>{};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.fields.map((field) {
              final choices = field.choices;
              if (choices != null) {
                final selected =
                    selections[field.name] ??
                    (choices.containsKey(field.initial) ? field.initial : null);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String>(
                    initialValue: selected,
                    decoration: InputDecoration(labelText: field.label),
                    items: choices.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(
                              entry.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    validator: field.required
                        ? (value) => value == null
                              ? 'Select ${field.label.toLowerCase()}.'
                              : null
                        : null,
                    onChanged: (value) => setState(() {
                      selections[field.name] = value;
                    }),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextFormField(
                  controller: controllers[field.name],
                  keyboardType:
                      field.name.contains('amount') ||
                          field.name == 'year' ||
                          field.name == 'month'
                      ? TextInputType.number
                      : TextInputType.text,
                  decoration: InputDecoration(labelText: field.label),
                  validator:
                      field.required &&
                          field.name != 'amount' &&
                          field.name != 'total_money'
                      ? (value) => value == null || value.trim().isEmpty
                            ? 'Enter ${field.label.toLowerCase()}.'
                            : null
                      : null,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!formKey.currentState!.validate()) return;
          final result = <String, String>{
            for (final field in widget.fields)
              field.name: field.choices == null
                  ? controllers[field.name]!.text.trim()
                  : selections[field.name] ?? field.initial,
          };
          Navigator.pop(context, result);
        },
        child: Text(widget.submitLabel),
      ),
    ],
  );
}

Future<bool> _confirmAction(
  BuildContext context,
  String title,
  String detail,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ) ??
    false;

class _MainBalancePicker extends StatefulWidget {
  const _MainBalancePicker({required this.months});
  final List<Map<String, dynamic>> months;
  @override
  State<_MainBalancePicker> createState() => _MainBalancePickerState();
}

class _MainBalancePickerState extends State<_MainBalancePicker> {
  late int selected = widget.months.first['id'] as int;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Select Main Balance'),
    content: DropdownButtonFormField<int>(
      initialValue: selected,
      decoration: const InputDecoration(labelText: 'Main Balance'),
      items: widget.months
          .map(
            (month) => DropdownMenuItem(
              value: month['id'] as int,
              child: Text('${month['name']} · ${month['monthLabel']}'),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) {
          setState(() {
            selected = value;
          });
        }
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, selected),
        child: const Text('Continue'),
      ),
    ],
  );
}

class SetupTab extends StatelessWidget {
  const SetupTab({
    super.key,
    required this.api,
    required this.data,
    required this.onChanged,
    required this.onCreateMonth,
  });
  final Api api;
  final Map<String, dynamic> data;
  final VoidCallback onChanged;
  final VoidCallback onCreateMonth;

  Future<void> _createBalance(BuildContext context) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _DataFormDialog(
        title: 'Add wallet group',
        fields: [_FormFieldSpec('name', 'Wallet group name', required: true)],
        submitLabel: 'Add',
      ),
    );
    if (!context.mounted || values == null) return;
    try {
      await api.post('/api/v1/dashboard/actions/', {
        'action': 'create_balance',
        ...values,
      });
      onChanged();
    } catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  Future<void> _createSubBalance(
    BuildContext context,
    List<Map<String, dynamic>> months,
  ) async {
    if (months.isEmpty) return;
    final monthId = await showDialog<int>(
      context: context,
      builder: (_) => _MainBalancePicker(months: months),
    );
    if (!context.mounted || monthId == null) return;
    final month = months.firstWhere((item) => item['id'] == monthId);
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => SubBalanceDialog(
        year: month['year'] as int,
        month: month['month'] as int,
      ),
    );
    if (!context.mounted || values == null) return;
    try {
      await api.post('/api/v1/dashboard/actions/', {
        'action': 'create_sub_balance',
        'budget_month': '$monthId',
        ...values,
      });
      onChanged();
    } catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  Future<void> _editMonth(
    BuildContext context,
    Map<String, dynamic> month,
  ) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Edit Main Balance',
        fields: [
          _FormFieldSpec(
            'name',
            'Main Balance name',
            initial: month['name'].toString(),
            required: true,
          ),
          _FormFieldSpec(
            'total_money',
            'Total Main Balance (MMK)',
            initial: month['totalMoney'].toString(),
            required: true,
          ),
        ],
        submitLabel: 'Save changes',
      ),
    );
    if (!context.mounted || values == null) return;
    try {
      await api.post('/api/v1/dashboard/actions/', {
        'action': 'edit_budget_month',
        'budget_month_id': '${month['id']}',
        ...values,
      });
      onChanged();
    } catch (error) {
      if (context.mounted) _showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final months = (data['months'] as List? ?? []).cast<Map<String, dynamic>>();
    final groups = (data['balances'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: () async => onChanged(),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Dashboard · Setup',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(color: navy, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'Manage wallet groups, Main Balances, and named Sub Balances.',
            style: TextStyle(color: Color(0xFF385A91)),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: () => _createBalance(context),
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: const Text('Add wallet group'),
              ),
              FilledButton.icon(
                onPressed: onCreateMonth,
                icon: const Icon(Icons.add),
                label: const Text('Create Main Balance'),
              ),
              OutlinedButton.icon(
                onPressed: months.isEmpty
                    ? null
                    : () => _createSubBalance(context, months),
                icon: const Icon(Icons.savings_outlined),
                label: const Text('Create Sub Balance'),
              ),
            ],
          ),
          const SectionTitle('Wallet Groups'),
          if (groups.isEmpty) const _EmptyMessage('No wallet groups yet.'),
          ...groups.map(
            (group) => Card(
              child: ListTile(
                leading: const Icon(Icons.wallet_outlined, color: teal),
                title: Text(group['name'].toString()),
                subtitle: Text(
                  '${months.where((month) => '${month['balance']}' == group['name']).length} Main Balances',
                ),
                trailing: IconButton(
                  tooltip: 'Delete wallet group',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final yes = await _confirmAction(
                      context,
                      'Delete wallet group?',
                      'Its Main Balances must be deleted first.',
                    );
                    if (!yes || !context.mounted) return;
                    try {
                      await api.post('/api/v1/dashboard/actions/', {
                        'action': 'delete_balance',
                        'balance_id': '${group['id']}',
                      });
                      onChanged();
                    } catch (error) {
                      if (context.mounted) _showError(context, error);
                    }
                  },
                ),
              ),
            ),
          ),
          const SectionTitle('Your Main Balances'),
          if (months.isEmpty)
            const _EmptyMessage(
              'No Main Balances yet. Create one to get started.',
            ),
          ...months.map(
            (month) => Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(
                      month['name'].toString(),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${month['monthLabel']} · ${month['balance'] ?? 'Wallet'} · ${_money(month['totalMoney'])} MMK',
                    ),
                    trailing: IconButton(
                      tooltip: 'Open Main Balance',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              MonthScreen(id: month['id'] as int, api: api),
                        ),
                      ).then((_) => onChanged()),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      children: [
                        TextButton.icon(
                          onPressed: () => _editMonth(context, month),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit'),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final yes = await _confirmAction(
                              context,
                              'Delete Main Balance?',
                              'This also deletes its Sub Balances, categories, transactions, and report history.',
                            );
                            if (!yes || !context.mounted) return;
                            try {
                              await api.post('/api/v1/dashboard/actions/', {
                                'action': 'delete_budget_month',
                                'budget_month_id': '${month['id']}',
                              });
                              onChanged();
                            } catch (error) {
                              if (context.mounted) _showError(context, error);
                            }
                          },
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 48),
        ],
      ),
    );
  }
}

class BudgetTab extends StatefulWidget {
  const BudgetTab({
    super.key,
    required this.api,
    required this.data,
    required this.onChanged,
  });
  final Api api;
  final Map<String, dynamic> data;
  final VoidCallback onChanged;
  @override
  State<BudgetTab> createState() => _BudgetTabState();
}

class _BudgetTabState extends State<BudgetTab> {
  int? monthId;
  Future<Map<String, dynamic>>? detail;

  void _selectMonth(int? id) {
    setState(() {
      monthId = id;
      detail = id == null ? null : widget.api.get('/api/v1/main-balances/$id/');
    });
  }

  Future<void> _periodBudget(
    Map<String, dynamic> month,
    List<Map<String, dynamic>> categories,
  ) async {
    final period = {
      for (final index in [1, 2, 3])
        'period_$index':
            categories
                .where((item) => item['period_index'] == index)
                .map((item) => item['estimated_amount'].toString())
                .firstOrNull ??
            '0',
    };
    final fields = <_FormFieldSpec>[
      for (var index = 1; index <= 3; index++)
        _FormFieldSpec(
          'period_$index',
          'Days ${index == 1
              ? '1-10'
              : index == 2
              ? '11-20'
              : '21-end'} (MMK)',
          initial: period['period_$index']!,
        ),
      for (var index = 1; index <= 5; index++) ...[
        _FormFieldSpec(
          'custom_name_$index',
          'Custom category $index name',
          initial:
              categories
                  .where((item) => item['period_index'] == null && index <= 5)
                  .map((item) => item['name'].toString())
                  .elementAtOrNull(index - 1) ??
              '',
        ),
        _FormFieldSpec(
          'custom_amount_$index',
          'Custom category $index amount (MMK)',
          initial:
              categories
                  .where((item) => item['period_index'] == null)
                  .map((item) => item['estimated_amount'].toString())
                  .elementAtOrNull(index - 1) ??
              '0',
        ),
      ],
    ];
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Set Category Budget Estimates',
        fields: fields,
        submitLabel: 'Save budgets',
      ),
    );
    if (!mounted || values == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {
        'action': 'save_period_budget',
        'budget_month': '${month['id']}',
        ...values,
      });
      widget.onChanged();
    } catch (error) {
      if (mounted) _showError(context, error);
    }
  }

  Future<void> _customBudget(
    Map<String, dynamic> month,
    List<Map<String, dynamic>> categories,
  ) async {
    final options = {
      for (final item in categories.where(
        (item) => item['period_index'] == null,
      ))
        '${item['id']}': item['name'].toString(),
    };
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Manage Custom Expense Category',
        fields: [
          _FormFieldSpec(
            'category',
            'Existing custom category',
            choices: {'': 'Create new category', ...options},
          ),
          const _FormFieldSpec(
            'new_category_name',
            'Or write a new category name',
          ),
          const _FormFieldSpec('estimated_amount', 'Budget amount (MMK)'),
        ],
        submitLabel: 'Save category budget',
      ),
    );
    if (!mounted || values == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {
        'action': 'save_custom_category_budget',
        'budget_month': '${month['id']}',
        ...values,
      });
      widget.onChanged();
    } catch (error) {
      if (mounted) _showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final months = (widget.data['months'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final selectedId =
        monthId ?? (months.isEmpty ? null : months.first['id'] as int);
    final month = months.where((item) => item['id'] == selectedId).firstOrNull;
    if (month != null && detail == null) {
      monthId = selectedId;
      detail = widget.api.get('/api/v1/main-balances/$selectedId/');
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Dashboard · Budget',
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(color: navy, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        if (months.isEmpty)
          const _EmptyMessage(
            'Create a Main Balance first to set category budgets.',
          )
        else
          DropdownButtonFormField<int>(
            initialValue: selectedId,
            decoration: const InputDecoration(labelText: 'Budget Month'),
            items: months
                .map(
                  (item) => DropdownMenuItem(
                    value: item['id'] as int,
                    child: Text('${item['monthLabel']} · ${item['name']}'),
                  ),
                )
                .toList(),
            onChanged: _selectMonth,
          ),
        if (month != null)
          FutureBuilder<Map<String, dynamic>>(
            future: detail,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return ErrorPanel(
                  message: snapshot.error.toString(),
                  onRetry: () => _selectMonth(month['id'] as int),
                );
              }
              final categories = (snapshot.data?['categories'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              final mainCategories = categories
                  .where((item) => item['sub_balance_id'] == null)
                  .toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 18),
                  const Text(
                    'Set budgets for the three reporting periods and up to five custom categories. Django retains the existing total-money behavior.',
                    style: TextStyle(color: Color(0xFF385A91)),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _periodBudget(month, mainCategories),
                        icon: const Icon(Icons.tune),
                        label: const Text('Set period budgets'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _customBudget(month, mainCategories),
                        icon: const Icon(Icons.add),
                        label: const Text('Add or update custom budget'),
                      ),
                    ],
                  ),
                  const SectionTitle('Current Category Budgets'),
                  if (mainCategories.isEmpty)
                    const _EmptyMessage(
                      'No categories available for this Main Balance.',
                    ),
                  ...mainCategories.map(
                    (item) => Card(
                      child: ListTile(
                        title: Text(item['name'].toString()),
                        subtitle: Text(
                          item['period_index'] == null
                              ? 'Custom category'
                              : _periodLabel(item['period_index'] as int),
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            TextButton(
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final values =
                                    await showDialog<Map<String, String>>(
                                      context: context,
                                      builder: (_) => _DataFormDialog(
                                        title: 'Update ${item['name']} budget',
                                        fields: [
                                          _FormFieldSpec(
                                            'estimated_amount',
                                            'Estimated amount (MMK)',
                                            initial: item['estimated_amount']
                                                .toString(),
                                            required: true,
                                          ),
                                        ],
                                      ),
                                    );
                                if (!mounted || values == null) return;
                                try {
                                  await widget.api.post(
                                    '/api/v1/dashboard/actions/',
                                    {
                                      'action': 'update_category_budget',
                                      'category_id': '${item['id']}',
                                      ...values,
                                    },
                                  );
                                  widget.onChanged();
                                } catch (error) {
                                  if (mounted) {
                                    messenger.showSnackBar(
                                      SnackBar(content: Text(error.toString())),
                                    );
                                  }
                                }
                              },
                              child: const Text('Edit'),
                            ),
                            IconButton(
                              tooltip: 'Delete category budget',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final yes = await _confirmAction(
                                  context,
                                  'Delete category budget?',
                                  'A category with expense or report history cannot be deleted.',
                                );
                                if (!yes || !mounted) return;
                                try {
                                  await widget.api.post(
                                    '/api/v1/dashboard/actions/',
                                    {
                                      'action': 'delete_category_budget',
                                      'category_id': '${item['id']}',
                                    },
                                  );
                                  widget.onChanged();
                                } catch (error) {
                                  if (mounted) {
                                    messenger.showSnackBar(
                                      SnackBar(content: Text(error.toString())),
                                    );
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                        leading: Text(
                          _money(item['estimated_amount']),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: navy,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class SummaryTab extends StatelessWidget {
  const SummaryTab({super.key, required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Dashboard · Summary',
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(color: navy, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      const Text(
        'Monthly overview for balances, spending, and remaining cash.',
        style: TextStyle(color: Color(0xFF385A91)),
      ),
      const SizedBox(height: 20),
      ...((data['months'] as List? ?? []).cast<Map<String, dynamic>>()).map((
        month,
      ) {
        final report = (month['report'] as Map).cast<String, dynamic>();
        return Card(
          child: ExpansionTile(
            title: Text('${month['monthLabel']} · ${month['name']}'),
            subtitle: Text(
              'Available ${_money(report['total_money'])} · Spent ${_money(report['combined_actual_spent'])} · Remaining ${_money(report['remaining_balance'])} MMK',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SummaryTile(
                    label: 'Available money',
                    value: _money(report['total_money']),
                    icon: Icons.account_balance_wallet_outlined,
                  ),
                  SummaryTile(
                    label: 'Main Balance direct spending',
                    value: _money(report['direct_actual_spent']),
                    icon: Icons.payments_outlined,
                  ),
                  SummaryTile(
                    label: 'Sub Balance spending',
                    value: _money(report['sub_balance_total_actual_spent']),
                    icon: Icons.savings_outlined,
                  ),
                  SummaryTile(
                    label: 'Combined spending',
                    value: _money(report['combined_actual_spent']),
                    icon: Icons.shopping_cart_outlined,
                  ),
                  SummaryTile(
                    label: 'Remaining Balance',
                    value: _money(report['remaining_balance']),
                    icon: Icons.account_balance_outlined,
                  ),
                  SummaryTile(
                    label: 'Monthly ${report['overall_status']}',
                    value: _money(report['overall_difference']),
                    icon: Icons.query_stats_outlined,
                  ),
                ],
              ),
              const SectionTitle('Category Comparison'),
              ...(report['period_reports'] as List? ?? []).map(
                (row) => ListTile(
                  title: Text(row['category_name'].toString()),
                  subtitle: Text(
                    '${row['status']} · Budget ${_money(row['budget_amount'])} · Actual ${_money(row['actual_amount'])}',
                  ),
                  trailing: Text(_money(row['difference'].toString())),
                ),
              ),
              const SectionTitle('Sub Balance Overview'),
              ...(report['sub_balance_rows'] as List? ?? []).map(
                (row) => ListTile(
                  title: Text(row['name'].toString()),
                  subtitle: Text(
                    'Allocated ${_money(row['balance_amount'])} · Actual ${_money(row['total_actual_spent'])} · Remaining ${_money(row['remaining_balance'])}',
                  ),
                ),
              ),
              if ((report['zero_spend_periods'] as List? ?? []).isNotEmpty)
                Text(
                  'No spending: ${(report['zero_spend_periods'] as List).join(', ')}',
                  style: const TextStyle(color: Color(0xFF9A6700)),
                ),
            ],
          ),
        );
      }),
      if ((data['months'] as List? ?? []).isEmpty)
        const _EmptyMessage(
          'Create a Main Balance to unlock the Summary dashboard.',
        ),
    ],
  );
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFF385A91)),
      ),
    ),
  );
}

String _periodLabel(int index) => switch (index) {
  1 => 'Days 1-10',
  2 => 'Days 11-20',
  _ => 'Days 21-end',
};

void _showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(error.toString())));
}

class ExpensesTab extends StatefulWidget {
  const ExpensesTab({
    super.key,
    required this.api,
    required this.data,
    required this.onChanged,
  });
  final Api api;
  final Map<String, dynamic> data;
  final VoidCallback onChanged;
  @override
  State<ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<ExpensesTab> {
  int? monthId;
  int? subBalanceId;
  bool subMode = false;
  Future<Map<String, dynamic>>? detail;

  List<Map<String, dynamic>> get months =>
      (widget.data['months'] as List? ?? []).cast<Map<String, dynamic>>();

  void _loadMonth(int? id) {
    setState(() {
      monthId = id;
      subBalanceId = null;
      detail = id == null ? null : widget.api.get('/api/v1/main-balances/$id/');
    });
  }

  void _refresh() {
    final id = monthId;
    setState(() {
      detail = id == null ? null : widget.api.get('/api/v1/main-balances/$id/');
    });
    widget.onChanged();
  }

  Future<void> _submitAction(Map<String, String> fields) async {
    try {
      await widget.api.post('/api/v1/dashboard/actions/', fields);
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) _showError(context, error);
    }
  }

  Future<void> _createExpense(
    Map<String, dynamic> month,
    List<Map<String, dynamic>> categories,
    List<Map<String, dynamic>> subs,
  ) async {
    final selectedSub = subs
        .where((item) => item['id'] == subBalanceId)
        .firstOrNull;
    final choices = categories.where(
      (item) => subMode
          ? item['sub_balance_id'] == subBalanceId
          : item['sub_balance_id'] == null,
    );
    final date =
        '${month['year']}-${month['month'].toString().padLeft(2, '0')}-01';
    final fields = <_FormFieldSpec>[
      if (subMode)
        _FormFieldSpec(
          'sub_balance',
          'Sub-Balance',
          required: true,
          choices: {
            for (final item in subs) '${item['id']}': item['name'].toString(),
          },
        ),
      _FormFieldSpec(
        'category',
        'Category',
        required: true,
        choices: {
          for (final item in choices) '${item['id']}': item['name'].toString(),
        },
      ),
      _FormFieldSpec(
        'expense_date',
        'Date (YYYY-MM-DD)',
        initial: date,
        required: true,
      ),
      const _FormFieldSpec('amount', 'Amount (MMK)', required: true),
      const _FormFieldSpec('note', 'Note (optional)'),
    ];
    if (subMode &&
        selectedSub == null &&
        subs.isNotEmpty &&
        subBalanceId == null) {
      setState(() {
        subBalanceId = subs.first['id'] as int;
      });
    }
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: subMode
            ? 'Add Actual Money to a Sub-Balance'
            : 'Add Daily Expense',
        fields: fields,
        submitLabel: subMode ? 'Add actual money' : 'Add expense',
      ),
    );
    if (values == null) return;
    await _submitAction({
      'action': 'add_expense',
      'expense_type': subMode ? 'sub' : 'main',
      'budget_month': '${month['id']}',
      ...values,
    });
  }

  Future<void> _addExtraMoney(
    Map<String, dynamic> month,
    List<Map<String, dynamic>> categories,
  ) async {
    final mainCategories = categories.where(
      (item) => item['sub_balance_id'] == null,
    );
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Add Unexpected Money',
        fields: [
          _FormFieldSpec(
            'category',
            'Existing category (optional)',
            choices: {
              '': 'Choose a category',
              for (final item in mainCategories)
                '${item['id']}': item['name'].toString(),
            },
          ),
          const _FormFieldSpec('new_category_name', 'Or create a new category'),
          _FormFieldSpec(
            'expense_date',
            'Date (YYYY-MM-DD)',
            initial:
                '${month['year']}-${month['month'].toString().padLeft(2, '0')}-01',
            required: true,
          ),
          const _FormFieldSpec('amount', 'Amount (MMK)', required: true),
          const _FormFieldSpec('note', 'Note (optional)'),
        ],
        submitLabel: 'Add extra money',
      ),
    );
    if (values == null) return;
    await _submitAction({
      'action': 'add_extra_money',
      'budget_month': '${month['id']}',
      ...values,
    });
  }

  Future<void> _createExpenseCategory(
    Map<String, dynamic> month,
    List<Map<String, dynamic>> subs,
  ) async {
    final fields = <_FormFieldSpec>[
      if (subMode)
        _FormFieldSpec(
          'sub_balance',
          'Sub-Balance',
          required: true,
          choices: {
            for (final item in subs) '${item['id']}': item['name'].toString(),
          },
        ),
      const _FormFieldSpec('name', 'Category name', required: true),
    ];
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Create a custom category',
        fields: fields,
        submitLabel: 'Create category',
      ),
    );
    if (values == null) return;
    await _submitAction({
      'action': 'create_expense_category',
      'category_type': subMode ? 'sub' : 'main',
      'budget_month': '${month['id']}',
      ...values,
    });
  }

  Future<void> _editExpense(
    Map<String, dynamic> month,
    Map<String, dynamic> expense,
    List<Map<String, dynamic>> categories,
    List<Map<String, dynamic>> subs,
  ) async {
    final expenseSubId = expense['sub_balance_id'];
    final selectedCategories = categories.where(
      (item) => item['sub_balance_id'] == expenseSubId,
    );
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Update Expense',
        fields: [
          _FormFieldSpec(
            'category',
            'Category',
            required: true,
            initial: '${expense['category_id']}',
            choices: {
              for (final item in selectedCategories)
                '${item['id']}': item['name'].toString(),
            },
          ),
          _FormFieldSpec(
            'expense_date',
            'Date (YYYY-MM-DD)',
            initial: expense['expense_date'].toString(),
            required: true,
          ),
          _FormFieldSpec(
            'amount',
            'Amount (MMK)',
            initial: expense['amount'].toString(),
            required: true,
          ),
          _FormFieldSpec(
            'note',
            'Note (optional)',
            initial: expense['note']?.toString() ?? '',
          ),
        ],
        submitLabel: 'Update expense',
      ),
    );
    if (values == null) return;
    await _submitAction({
      'action': 'update_expense',
      'expense_type': expenseSubId == null ? 'main' : 'sub',
      'expense_id': '${expense['id']}',
      'budget_month': '${month['id']}',
      if (expenseSubId != null) 'sub_balance': '$expenseSubId',
      ...values,
    });
  }

  Future<void> _deleteExpense(Map<String, dynamic> expense) async {
    final yes = await _confirmAction(
      context,
      'Delete this expense?',
      'The record will be permanently removed.',
    );
    if (!yes) return;
    await _submitAction({
      'action': 'delete_expense',
      'expense_id': '${expense['id']}',
    });
  }

  Future<void> _finishMonth(Map<String, dynamic> month) async {
    final yes = await _confirmAction(
      context,
      'Finish and email monthly report?',
      'Django will generate the report and send it using the existing email service.',
    );
    if (!yes) return;
    await _submitAction({
      'action': 'finish_month',
      'budget_month_id': '${month['id']}',
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedId =
        monthId ?? (months.isEmpty ? null : months.first['id'] as int);
    final month = months.where((item) => item['id'] == selectedId).firstOrNull;
    if (month != null && detail == null) {
      monthId = selectedId;
      detail = widget.api.get('/api/v1/main-balances/$selectedId/');
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          'Dashboard · Daily Expenses',
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(color: navy, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Main Balance')),
            ButtonSegment(value: true, label: Text('Sub-Balance')),
          ],
          selected: {subMode},
          onSelectionChanged: (value) => setState(() {
            subMode = value.first;
          }),
        ),
        const SizedBox(height: 14),
        if (months.isEmpty)
          const _EmptyMessage(
            'Create a Main Balance before recording expenses.',
          )
        else
          DropdownButtonFormField<int>(
            initialValue: selectedId,
            decoration: const InputDecoration(labelText: 'Budget Month'),
            items: months
                .map(
                  (item) => DropdownMenuItem(
                    value: item['id'] as int,
                    child: Text('${item['monthLabel']} · ${item['name']}'),
                  ),
                )
                .toList(),
            onChanged: _loadMonth,
          ),
        if (month != null)
          FutureBuilder<Map<String, dynamic>>(
            future: detail,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return ErrorPanel(
                  message: snapshot.error.toString(),
                  onRetry: () => _loadMonth(selectedId),
                );
              }
              final payload = snapshot.data!;
              final categories = (payload['categories'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              final subs = (payload['subBalances'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              final expenses = (payload['expenses'] as List? ?? [])
                  .cast<Map<String, dynamic>>()
                  .where(
                    (item) => subMode
                        ? item['sub_balance__name'] != null
                        : item['sub_balance__name'] == null,
                  )
                  .where(
                    (item) =>
                        !subMode ||
                        subBalanceId == null ||
                        item['sub_balance_id'] == subBalanceId,
                  )
                  .toList();
              final report = (payload['report'] as Map).cast<String, dynamic>();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (subMode && subs.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue:
                          subBalanceId != null &&
                              subs.any((item) => item['id'] == subBalanceId)
                          ? subBalanceId
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Filter Sub-Balance records',
                      ),
                      items: [
                        const DropdownMenuItem<int>(
                          value: null,
                          child: Text('All Sub-Balances'),
                        ),
                        ...subs.map(
                          (item) => DropdownMenuItem(
                            value: item['id'] as int,
                            child: Text(item['name'].toString()),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() {
                        subBalanceId = value;
                      }),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: () =>
                            _createExpense(month, categories, subs),
                        icon: const Icon(Icons.add_card),
                        label: Text(
                          subMode ? 'Add Actual Money' : 'Add Daily Expense',
                        ),
                      ),
                      if (!subMode)
                        OutlinedButton.icon(
                          onPressed: () => _addExtraMoney(month, categories),
                          icon: const Icon(Icons.add_circle_outline),
                          label: const Text('Add Unexpected Money'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => _createExpenseCategory(month, subs),
                        icon: const Icon(Icons.category_outlined),
                        label: const Text('Create custom category'),
                      ),
                    ],
                  ),
                  if (subMode && subBalanceId != null) ...[
                    const SectionTitle('Sub-Balance totals'),
                    ...subs
                        .where((item) => item['id'] == subBalanceId)
                        .map(
                          (item) => Card(
                            child: ListTile(
                              title: Text(item['name'].toString()),
                              subtitle: Text(
                                'Opening balance ${_money(item['balance_amount'])} MMK',
                              ),
                            ),
                          ),
                        ),
                  ] else if (!subMode) ...[
                    const SectionTitle('Main Balance totals'),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        SummaryTile(
                          label: 'Total money',
                          value: _money(report['total_money']),
                          icon: Icons.account_balance_wallet_outlined,
                        ),
                        SummaryTile(
                          label: 'Direct actual spending',
                          value: _money(report['direct_actual_spent']),
                          icon: Icons.payments_outlined,
                        ),
                        SummaryTile(
                          label: 'Combined actual spending',
                          value: _money(report['combined_actual_spent']),
                          icon: Icons.shopping_cart_outlined,
                        ),
                        SummaryTile(
                          label: 'Remaining balance',
                          value: _money(report['remaining_balance']),
                          icon: Icons.savings_outlined,
                        ),
                      ],
                    ),
                  ],
                  const SectionTitle('Actual Money'),
                  if (expenses.isEmpty)
                    _EmptyMessage(
                      subMode
                          ? 'No Sub-Balance Actual Money recorded for this Main Balance month yet.'
                          : 'No expenses recorded yet.',
                    ),
                  ...expenses.map(
                    (item) => Card(
                      child: ListTile(
                        title: Text(
                          '${item['category__name']} · ${_money(item['amount'])} MMK',
                        ),
                        subtitle: Text(
                          '${item['expense_date']} · ${subMode ? '${item['sub_balance__name']} · ' : ''}${item['note'] ?? ''}',
                        ),
                        trailing: Wrap(
                          spacing: 0,
                          children: [
                            IconButton(
                              tooltip: 'Edit expense',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () =>
                                  _editExpense(month, item, categories, subs),
                            ),
                            IconButton(
                              tooltip: 'Delete expense',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteExpense(item),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!subMode) ...[
                    const SectionTitle('Budget vs Actual by Category'),
                    ...(report['period_reports'] as List? ?? []).map(
                      (item) => ListTile(
                        title: Text(item['category_name'].toString()),
                        subtitle: Text(
                          '${item['status']} · ${_periodLabel((item['start_day'] ?? 21) <= 10
                              ? 1
                              : (item['start_day'] ?? 21) <= 20
                              ? 2
                              : 3)}',
                        ),
                        trailing: Text(
                          '${_money(item['budget_amount'])} / ${_money(item['actual_amount'])} MMK',
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonalIcon(
                        onPressed: () => _finishMonth(month),
                        icon: const Icon(Icons.mark_email_read_outlined),
                        label: const Text('Finish and Email Monthly Report'),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
      ],
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.api, required this.months});
  final Api api;
  final List<Map<String, dynamic>> months;
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  int? selectedMonthId;
  final Map<int, Map<String, dynamic>> reports = {};
  final Set<int> loadingReports = {};
  final Map<int, Object> reportErrors = {};

  @override
  void initState() {
    super.initState();
    if (widget.months.isNotEmpty) {
      selectedMonthId = widget.months.first['id'] as int;
      _loadReport(selectedMonthId!);
    }
  }

  Future<void> _loadReport(int monthId) async {
    if (reports.containsKey(monthId) || loadingReports.contains(monthId)) {
      return;
    }
    setState(() {
      loadingReports.add(monthId);
      reportErrors.remove(monthId);
    });
    try {
      final report = await widget.api.get(
        '/api/v1/main-balances/$monthId/report/',
      );
      if (mounted) {
        setState(() {
          reports[monthId] = report;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          reportErrors[monthId] = error;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          loadingReports.remove(monthId);
        });
      }
    }
  }

  void _selectMonth(int? monthId) {
    setState(() {
      selectedMonthId = monthId;
    });
    if (monthId != null) _loadReport(monthId);
  }

  @override
  Widget build(BuildContext context) {
    final selected =
        selectedMonthId ??
        (widget.months.isEmpty ? null : widget.months.first['id'] as int);
    final month = widget.months
        .where((item) => item['id'] == selected)
        .firstOrNull;
    final report = selected == null ? null : reports[selected];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: const [ThemeToggleButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Reports',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(color: navy, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Compare Main Balance direct category budgets with actual spending, separately from Sub-Balances.',
            style: TextStyle(color: Color(0xFF385A91)),
          ),
          const SizedBox(height: 18),
          if (widget.months.isEmpty)
            const _EmptyMessage('Create a Main Balance to generate a report.')
          else
            DropdownButtonFormField<int>(
              initialValue: selected,
              decoration: const InputDecoration(labelText: 'Budget Month'),
              items: widget.months
                  .map(
                    (item) => DropdownMenuItem(
                      value: item['id'] as int,
                      child: Text('${item['monthLabel']} · ${item['name']}'),
                    ),
                  )
                  .toList(),
              onChanged: _selectMonth,
            ),
          if (selected != null && loadingReports.contains(selected))
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (selected != null && reportErrors.containsKey(selected))
            ErrorPanel(
              message: reportErrors[selected].toString(),
              onRetry: () {
                setState(() {
                  reportErrors.remove(selected);
                });
                _loadReport(selected);
              },
            ),
          if (report != null && month != null) ...[
            const SectionTitle('Monthly Summary'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SummaryTile(
                  label: 'Total Money (Available)',
                  value: _money(report['total_money']),
                  icon: Icons.account_balance_wallet_outlined,
                ),
                SummaryTile(
                  label: 'Direct Actual Spending',
                  value: _money(report['direct_actual_spent']),
                  icon: Icons.payments_outlined,
                ),
                SummaryTile(
                  label: 'Combined Actual Spending',
                  value: _money(report['combined_actual_spent']),
                  icon: Icons.shopping_cart_outlined,
                ),
                SummaryTile(
                  label: 'Remaining Balance',
                  value: _money(report['remaining_balance']),
                  icon: Icons.savings_outlined,
                ),
                SummaryTile(
                  label: 'Adjusted Available Money',
                  value: _money(report['adjusted_total_money']),
                  icon: Icons.account_balance_outlined,
                ),
                SummaryTile(
                  label: 'Overall ${report['overall_status']}',
                  value: _money(report['overall_difference']),
                  icon: Icons.query_stats_outlined,
                ),
              ],
            ),
            if ((report['zero_spend_periods'] as List? ?? []).isNotEmpty)
              Text(
                'No spend: ${(report['zero_spend_periods'] as List).join(', ')}',
              ),
            const SectionTitle('Category Comparison (Budget vs Actual)'),
            ...((report['period_reports'] as List? ?? []).map(
              (item) => Card(
                child: ListTile(
                  title: Text(item['category_name'].toString()),
                  subtitle: Text(
                    '${item['start_day'] == null ? 'Monthly' : 'Days ${item['start_day']}-${item['end_day']}'} · ${item['status']}',
                  ),
                  trailing: Text(
                    'Budget ${_money(item['budget_amount'])}\nActual ${_money(item['actual_amount'])}',
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            )),
            const SectionTitle('Sub-Balance Actual Spending'),
            ...((report['sub_balance_rows'] as List? ?? []).map(
              (item) => Card(
                child: ExpansionTile(
                  title: Text(item['name'].toString()),
                  subtitle: Text(
                    'Allocated ${_money(item['balance_amount'])} · Actual ${_money(item['total_actual_spent'])} · Remaining ${_money(item['remaining_balance'])}',
                  ),
                  children: [
                    ...(item['categories'] as List? ?? []).map(
                      (category) => ListTile(
                        title: Text(category['name'].toString()),
                        subtitle: Text(
                          'Budget ${_money(category['budget_amount'])} · Actual ${_money(category['actual_amount'])}',
                        ),
                      ),
                    ),
                    ...(item['transactions'] as List? ?? []).map(
                      (transaction) => ListTile(
                        title: Text(transaction['category_name'].toString()),
                        subtitle: Text(
                          '${transaction['date']} · ${transaction['note'] ?? 'No note'}',
                        ),
                        trailing: Text('${_money(transaction['amount'])} MMK'),
                      ),
                    ),
                  ],
                ),
              ),
            )),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () async {
                  try {
                    await widget.api.post(
                      '/api/v1/main-balances/$selected/report/actions/',
                      {'action': 'email'},
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Report email sent.')),
                      );
                    }
                  } catch (error) {
                    if (context.mounted) _showError(context, error);
                  }
                },
                icon: const Icon(Icons.email_outlined),
                label: Text('Send Total Report to ${month['name']}'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class MonthCard extends StatelessWidget {
  const MonthCard({
    super.key,
    required this.month,
    required this.api,
    required this.onChanged,
  });
  final Map<String, dynamic> month;
  final Api api;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    final report = (month['report'] as Map?)?.cast<String, dynamic>() ?? {};
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MonthScreen(id: month['id'] as int, api: api),
          ),
        ).then((_) => onChanged()),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      month['name']?.toString() ?? 'Main Balance',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${month['monthLabel']}  ·  ${month['balance'] ?? 'Wallet'}',
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 22,
                runSpacing: 8,
                children: [
                  Metric(
                    label: 'Available',
                    value: _money(
                      report['remaining_balance'] ?? month['totalMoney'],
                    ),
                  ),
                  Metric(
                    label: 'Spent',
                    value: _money(report['combined_actual_spent']),
                  ),
                  Metric(label: 'Total', value: _money(month['totalMoney'])),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MonthScreen extends StatefulWidget {
  const MonthScreen({super.key, required this.id, required this.api});
  final int id;
  final Api api;
  @override
  State<MonthScreen> createState() => _MonthScreenState();
}

class _MonthScreenState extends State<MonthScreen> {
  late Future<Map<String, dynamic>> future;
  bool submitting = false;
  @override
  void initState() {
    super.initState();
    future = widget.api.get('/api/v1/main-balances/${widget.id}/');
  }

  void reload() => setState(() {
    future = widget.api.get('/api/v1/main-balances/${widget.id}/');
  });

  Future<void> _editMonth(Map<String, dynamic> data) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Edit Main Balance',
        fields: [
          _FormFieldSpec(
            'name',
            'Main Balance name',
            initial: data['name'].toString(),
            required: true,
          ),
          _FormFieldSpec(
            'total_money',
            'Total Main Balance (MMK)',
            initial: data['totalMoney'].toString(),
            required: true,
          ),
        ],
        submitLabel: 'Save changes',
      ),
    );
    if (!mounted || values == null) return;
    await _mainAction({'action': 'edit', ...values});
  }

  Future<void> _mainAction(Map<String, String> fields) async {
    if (submitting) return;
    setState(() {
      submitting = true;
    });
    try {
      await widget.api.post(
        '/api/v1/main-balances/${widget.id}/actions/',
        fields,
      );
      if (mounted) reload();
    } catch (error) {
      if (mounted) _showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          submitting = false;
        });
      }
    }
  }

  Future<void> _deleteMonth() async {
    final yes = await _confirmAction(
      context,
      'Delete Main Balance?',
      'This also deletes its Sub Balances, categories, transactions, and report history. This cannot be undone.',
    );
    if (!mounted || !yes || submitting) return;
    setState(() {
      submitting = true;
    });
    try {
      await widget.api.post('/api/v1/main-balances/${widget.id}/actions/', {
        'action': 'delete',
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) _showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          submitting = false;
        });
      }
    }
  }

  Future<void> _subAction(int id, Map<String, String> fields) async {
    if (submitting) return;
    setState(() {
      submitting = true;
    });
    try {
      await widget.api.post('/api/v1/sub-balances/$id/actions/', fields);
      if (mounted) reload();
    } catch (error) {
      if (mounted) _showError(context, error);
    } finally {
      if (mounted) {
        setState(() {
          submitting = false;
        });
      }
    }
  }

  Future<void> _editSubBalance(Map<String, dynamic> sub) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _DataFormDialog(
        title: 'Edit Sub Balance',
        fields: [
          _FormFieldSpec(
            'name',
            'Sub Balance name',
            initial: sub['name'].toString(),
            required: true,
          ),
          _FormFieldSpec(
            'balance_amount',
            'Opening Balance Amount (MMK)',
            initial: sub['balance_amount'].toString(),
          ),
          _FormFieldSpec(
            'balance_date',
            'Date (YYYY-MM-DD)',
            initial: sub['balance_date'].toString(),
            required: true,
          ),
        ],
      ),
    );
    if (!mounted || values == null) return;
    await _subAction(sub['id'] as int, {'action': 'edit', ...values});
  }

  Future<void> _handleSubAction(String action, Map<String, dynamic> sub) async {
    final id = sub['id'] as int;
    if (action == 'view') {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SubScreen(id: id, api: widget.api),
        ),
      );
      if (mounted) reload();
    } else if (action == 'edit') {
      await _editSubBalance(sub);
    } else if (action == 'delete') {
      final yes = await _confirmAction(
        context,
        'Delete Sub Balance?',
        'Sub Balances with financial or report history cannot be deleted.',
      );
      if (mounted && yes) await _subAction(id, {'action': 'delete'});
    } else if (action == 'finish') {
      final yes = await _confirmAction(
        context,
        'Finish and email this Sub Balance?',
        'Django will generate and send its current report.',
      );
      if (mounted && yes) await _subAction(id, {'action': 'finish'});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Main Balance'),
      actions: const [ThemeToggleButton()],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorPanel(
            message: snapshot.error.toString(),
            onRetry: reload,
          );
        }
        final data = snapshot.data!;
        final report = (data['report'] as Map).cast<String, dynamic>();
        final subs = (data['subBalances'] as List).cast<Map<String, dynamic>>();
        final categories = (data['categories'] as List)
            .cast<Map<String, dynamic>>();
        final expenses = (data['expenses'] as List)
            .cast<Map<String, dynamic>>();
        return RefreshIndicator(
          onRefresh: () async => reload(),
          child: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Text(
                data['name'].toString(),
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(color: navy, fontWeight: FontWeight.bold),
              ),
              Text(data['monthLabel'].toString()),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: submitting ? null : () => _editMonth(data),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit Main Balance'),
                  ),
                  OutlinedButton.icon(
                    onPressed: submitting ? null : _deleteMonth,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete Main Balance'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _addExpense(data, categories),
                    icon: const Icon(Icons.add_card),
                    label: const Text('Record expense'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _addCategoryBudget(data['id'] as int),
                    icon: const Icon(Icons.category_outlined),
                    label: const Text('Add custom category'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _sendReport(data['id'] as int),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('Email report'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _addSubBalance(data),
                    icon: const Icon(Icons.savings_outlined),
                    label: const Text('Add Sub Balance'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SummaryTile(
                    label: 'Main Balance',
                    value: _money(report['total_money']),
                    icon: Icons.account_balance,
                  ),
                  SummaryTile(
                    label: 'Main remaining',
                    value: _money(report['remaining_balance']),
                    icon: Icons.savings_outlined,
                  ),
                  SummaryTile(
                    label: 'Spent total',
                    value: _money(report['combined_actual_spent']),
                    icon: Icons.payments_outlined,
                  ),
                ],
              ),
              SectionTitle('Sub Balances'),
              if (subs.isEmpty) const Text('No Sub Balances'),
              ...subs.map(
                (sub) => Card(
                  child: ListTile(
                    title: Text(sub['name'].toString()),
                    subtitle: Text(
                      'Opening amount ${_money(sub['balance_amount'])} MMK',
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            SubScreen(id: sub['id'] as int, api: widget.api),
                      ),
                    ).then((_) => reload()),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) => _handleSubAction(action, sub),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'view', child: Text('View')),
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                        PopupMenuItem(
                          value: 'finish',
                          child: Text('Finish and email'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SectionTitle('Budget categories'),
              ...categories
                  .where((c) => c['sub_balance_id'] == null)
                  .map(
                    (c) => ListTile(
                      title: Text(c['name'].toString()),
                      trailing: TextButton(
                        onPressed: () => _updateCategory(c),
                        child: Text('${_money(c['estimated_amount'])} MMK'),
                      ),
                    ),
                  ),
              SectionTitle('Recent expenses'),
              if (expenses.isEmpty) const Text('No recorded expenses'),
              ...expenses
                  .where((expense) => expense['sub_balance_id'] == null)
                  .map(
                    (e) => ListTile(
                      title: Text(e['category__name']?.toString() ?? 'Expense'),
                      subtitle: Text(
                        '${e['expense_date']} · ${e['note'] ?? ''}',
                      ),
                      trailing: Text('${_money(e['amount'])} MMK'),
                    ),
                  ),
              SectionTitle('Monthly report'),
              ...(report['period_reports'] as List).map(
                (p) => ListTile(
                  title: Text(p['category_name'].toString()),
                  subtitle: Text(p['status'].toString()),
                  trailing: Text(
                    '${_money(p['actual_amount'])} / ${_money(p['budget_amount'])}',
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Future<void> _addExpense(
    Map<String, dynamic> month,
    List<Map<String, dynamic>> allCategories,
  ) async {
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => ExpenseDialog(
        monthId: widget.id,
        year: month['year'] as int,
        month: month['month'] as int,
        categories: allCategories
            .where((c) => c['sub_balance_id'] == null)
            .toList(),
      ),
    );
    if (fields == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {
        'action': 'add_expense',
        'expense_type': 'main',
        ...fields,
      });
      reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _addCategoryBudget(int monthId) async {
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const CategoryBudgetDialog(),
    );
    if (fields == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {
        'action': 'save_custom_category_budget',
        'budget_month': '$monthId',
        ...fields,
      });
      reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _updateCategory(Map<String, dynamic> category) async {
    final amount = TextEditingController(
      text: category['estimated_amount'].toString(),
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Update ${category['name']} budget'),
        content: TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Estimated amount (MMK)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {
        'action': 'update_category_budget',
        'category_id': '${category['id']}',
        'estimated_amount': amount.text,
      });
      reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _sendReport(int monthId) async {
    try {
      await widget.api.post('/api/v1/main-balances/$monthId/report/actions/', {
        'action': 'email',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report email request processed.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _addSubBalance(Map<String, dynamic> month) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => SubBalanceDialog(
        year: month['year'] as int,
        month: month['month'] as int,
      ),
    );
    if (values == null) return;
    try {
      await widget.api.post('/api/v1/main-balances/${widget.id}/actions/', {
        'action': 'create_sub_balance',
        ...values,
      });
      reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }
}

class SubScreen extends StatefulWidget {
  const SubScreen({super.key, required this.id, required this.api});
  final int id;
  final Api api;
  @override
  State<SubScreen> createState() => _SubScreenState();
}

class _SubScreenState extends State<SubScreen> {
  late Future<Map<String, dynamic>> future;
  bool submitting = false;
  @override
  void initState() {
    super.initState();
    future = widget.api.get('/api/v1/sub-balances/${widget.id}/');
  }

  void reload() => setState(() {
    future = widget.api.get('/api/v1/sub-balances/${widget.id}/');
  });

  Future<bool> _post(Map<String, String> fields) async {
    if (submitting) return false;
    setState(() {
      submitting = true;
    });
    try {
      await widget.api.post(
        '/api/v1/sub-balances/${widget.id}/actions/',
        fields,
      );
      if (mounted) reload();
      return true;
    } catch (error) {
      if (mounted) _showError(context, error);
      return false;
    } finally {
      if (mounted) {
        setState(() {
          submitting = false;
        });
      }
    }
  }

  Future<Map<String, String>?> _form(
    String title,
    List<_FormFieldSpec> fields, {
    String submitLabel = 'Save',
  }) => showDialog<Map<String, String>>(
    context: context,
    builder: (_) =>
        _DataFormDialog(title: title, fields: fields, submitLabel: submitLabel),
  );

  Future<void> _edit(Map<String, dynamic> data) async {
    final values = await _form('Edit Sub Balance', [
      _FormFieldSpec(
        'name',
        'Sub Balance name',
        initial: data['name'].toString(),
        required: true,
      ),
      _FormFieldSpec(
        'balance_amount',
        'Opening Balance Amount (MMK)',
        initial: data['balanceAmount'].toString(),
      ),
      _FormFieldSpec(
        'balance_date',
        'Date (YYYY-MM-DD)',
        initial: data['balanceDate'].toString(),
        required: true,
      ),
    ]);
    if (!mounted || values == null) return;
    await _post({'action': 'edit', ...values});
  }

  Future<void> _delete(Map<String, dynamic> data) async {
    final yes = await _confirmAction(
      context,
      'Delete Sub Balance?',
      'Sub Balances with financial or report history cannot be deleted.',
    );
    if (!mounted || !yes) return;
    if (await _post({'action': 'delete'}) && mounted) Navigator.pop(context);
  }

  Future<void> _addCategory() async {
    final values = await _form('Add Sub Balance category', [
      const _FormFieldSpec('name', 'Category name', required: true),
    ], submitLabel: 'Add category');
    if (!mounted || values == null) return;
    await _post({'action': 'add_category', ...values});
  }

  Future<void> _deleteCategory(Map<String, dynamic> category) async {
    final yes = await _confirmAction(
      context,
      'Delete category?',
      'A category used by an existing transaction cannot be deleted.',
    );
    if (!mounted || !yes) return;
    await _post({
      'action': 'delete_category',
      'category_id': '${category['id']}',
    });
  }

  Future<void> _addTransaction(
    List<Map<String, dynamic>> categories,
    String monthLabel,
  ) async {
    if (categories.isEmpty) {
      _showError(context, 'Create a category before recording spending.');
      return;
    }
    final values = await _form('Add transaction', [
      _FormFieldSpec(
        'category',
        'Category',
        required: true,
        choices: {
          for (final item in categories)
            '${item['id']}': item['name'].toString(),
        },
      ),
      const _FormFieldSpec('expense_date', 'Date (YYYY-MM-DD)', required: true),
      const _FormFieldSpec('amount', 'Amount (MMK)', required: true),
      const _FormFieldSpec('note', 'Note (optional)'),
    ], submitLabel: 'Record spending');
    if (!mounted || values == null) return;
    await _post({'action': 'add_transaction', ...values});
  }

  Future<void> _editTransaction(
    Map<String, dynamic> item,
    List<Map<String, dynamic>> categories,
  ) async {
    final values = await _form('Update transaction', [
      _FormFieldSpec(
        'category',
        'Category',
        required: true,
        initial: '${item['category_id']}',
        choices: {
          for (final category in categories)
            '${category['id']}': category['name'].toString(),
        },
      ),
      _FormFieldSpec(
        'expense_date',
        'Date (YYYY-MM-DD)',
        initial: item['expense_date'].toString(),
        required: true,
      ),
      _FormFieldSpec(
        'amount',
        'Amount (MMK)',
        initial: item['amount'].toString(),
        required: true,
      ),
      _FormFieldSpec(
        'note',
        'Note (optional)',
        initial: item['note']?.toString() ?? '',
      ),
    ], submitLabel: 'Update');
    if (!mounted || values == null) return;
    await _post({
      'action': 'update_transaction',
      'transaction_id': '${item['id']}',
      ...values,
    });
  }

  Future<void> _deleteTransaction(Map<String, dynamic> item) async {
    final yes = await _confirmAction(
      context,
      'Delete transaction?',
      'This transaction will be permanently removed.',
    );
    if (!mounted || !yes) return;
    await _post({
      'action': 'delete_transaction',
      'transaction_id': '${item['id']}',
    });
  }

  Future<void> _finish() async {
    final yes = await _confirmAction(
      context,
      'Finish and email this Sub Balance?',
      'Django will generate and send the current Sub Balance report. Its independent scheduled report remains active.',
    );
    if (!mounted || !yes) return;
    if (await _post({'action': 'finish'}) && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sub Balance report sent.')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Sub Balance'),
      actions: const [ThemeToggleButton()],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return ErrorPanel(
            message: snapshot.error.toString(),
            onRetry: () => setState(() {
              future = widget.api.get('/api/v1/sub-balances/${widget.id}/');
            }),
          );
        }
        final data = snapshot.data!;
        final categories = (data['categories'] as List)
            .cast<Map<String, dynamic>>();
        final expenses = (data['expenses'] as List)
            .cast<Map<String, dynamic>>();
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              data['name'].toString(),
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold, color: navy),
            ),
            Text(data['monthLabel'].toString()),
            Text(
              'Date ${data['balanceDate']} · Created ${data['createdAt']} · 15-day report due ${data['reportDueDate']}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: const Color(0xFF385A91)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _edit(data),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _delete(data),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SummaryTile(
                  label: 'Allocated',
                  value: _money(data['allocatedAmount']),
                  icon: Icons.account_balance_wallet_outlined,
                ),
                SummaryTile(
                  label: 'Spent',
                  value: _money(data['totalActualSpent']),
                  icon: Icons.payments_outlined,
                ),
                SummaryTile(
                  label: 'Remaining',
                  value: _money(data['remainingBalance']),
                  icon: Icons.savings_outlined,
                ),
              ],
            ),
            SectionTitle('Categories'),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _addCategory,
                icon: const Icon(Icons.add),
                label: const Text('Add category'),
              ),
            ),
            if (categories.isEmpty) const _EmptyMessage('No categories yet.'),
            ...categories.map(
              (item) => ListTile(
                title: Text(item['name'].toString()),
                subtitle: Text(
                  'Budget ${_money(item['estimated_amount'])} · Actual ${_money(item['actual_amount'])} MMK',
                ),
                trailing: IconButton(
                  tooltip: 'Delete category',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteCategory(item),
                ),
              ),
            ),
            SectionTitle('Add transaction'),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () =>
                    _addTransaction(categories, data['monthLabel'].toString()),
                icon: const Icon(Icons.add_card),
                label: const Text('Record spending'),
              ),
            ),
            SectionTitle('Transactions'),
            if (expenses.isEmpty) const _EmptyMessage('No transactions yet.'),
            ...expenses.map(
              (item) => Card(
                child: ListTile(
                  title: Text(
                    '${item['category__name']} · ${_money(item['amount'])} MMK',
                  ),
                  subtitle: Text(
                    '${item['expense_date']} · ${item['note'] ?? 'No note'}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'edit') _editTransaction(item, categories);
                      if (action == 'delete') _deleteTransaction(item);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 32),
            Text(
              '15-day report: ${data['scheduledSent'] == true ? 'Sent' : (data['today'].toString().compareTo(data['reportDueDate'].toString()) >= 0 ? 'Due; next scheduler run will send it' : 'Scheduled')}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: const Color(0xFF385A91)),
            ),
            Text(
              'Finish report: ${data['finishSent'] == true ? 'Sent before; you can send it again' : 'Not sent yet'}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: const Color(0xFF385A91)),
            ),
            Text(
              'Finish sends only this Sub Balance. It does not close it or cancel its independent 15-day report.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: const Color(0xFF385A91)),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _finish,
                icon: const Icon(Icons.email_outlined),
                label: const Text('Finish and Email This Sub Balance'),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class CreateMonthDialog extends StatefulWidget {
  const CreateMonthDialog({super.key, required this.balances});
  final List<Map<String, dynamic>> balances;
  @override
  State<CreateMonthDialog> createState() => _CreateMonthDialogState();
}

class _CreateMonthDialogState extends State<CreateMonthDialog> {
  final name = TextEditingController();
  final amount = TextEditingController();
  final year = TextEditingController(text: DateTime.now().year.toString());
  final month = TextEditingController(text: DateTime.now().month.toString());
  String? selectedBalance;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create Main Balance'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            DropdownButtonFormField<String>(
              initialValue:
                  selectedBalance ??
                  (widget.balances.isEmpty
                      ? null
                      : widget.balances.first['id'].toString()),
              decoration: const InputDecoration(labelText: 'Wallet group'),
              items: widget.balances
                  .map(
                    (b) => DropdownMenuItem(
                      value: b['id'].toString(),
                      child: Text(b['name'].toString()),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                selectedBalance = value;
              }),
            ),
            TextField(
              controller: year,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Year'),
            ),
            TextField(
              controller: month,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Month (1–12)'),
            ),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Total money (MMK)'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'name': name.text,
          'balance':
              selectedBalance ??
              (widget.balances.isEmpty
                  ? ''
                  : widget.balances.first['id'].toString()),
          'year': year.text,
          'month': month.text,
          'total_money': amount.text,
        }),
        child: const Text('Create'),
      ),
    ],
  );
}

class ExpenseDialog extends StatefulWidget {
  const ExpenseDialog({
    super.key,
    required this.monthId,
    required this.year,
    required this.month,
    required this.categories,
  });
  final int monthId, year, month;
  final List<Map<String, dynamic>> categories;
  @override
  State<ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<ExpenseDialog> {
  final amount = TextEditingController(), note = TextEditingController();
  late DateTime date = DateTime(widget.year, widget.month, 1);
  String? categoryId;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Record expense'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: categoryId,
            decoration: const InputDecoration(labelText: 'Category'),
            items: widget.categories
                .map(
                  (c) => DropdownMenuItem(
                    value: c['id'].toString(),
                    child: Text(c['name'].toString()),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() {
              categoryId = v;
            }),
          ),
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Amount (MMK)'),
          ),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: 'Note'),
          ),
          TextButton.icon(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: date,
                firstDate: DateTime(widget.year, widget.month, 1),
                lastDate: DateTime(widget.year, widget.month + 1, 0),
              );
              if (picked != null) {
                setState(() {
                  date = picked;
                });
              }
            },
            icon: const Icon(Icons.calendar_month),
            label: Text(
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (categoryId == null) return;
          Navigator.pop(context, {
            'budget_month': '${widget.monthId}',
            'category': categoryId!,
            'expense_date':
                '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
            'amount': amount.text,
            'note': note.text,
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}

class CategoryBudgetDialog extends StatefulWidget {
  const CategoryBudgetDialog({super.key});
  @override
  State<CategoryBudgetDialog> createState() => _CategoryBudgetDialogState();
}

class SubBalanceDialog extends StatefulWidget {
  const SubBalanceDialog({super.key, required this.year, required this.month});
  final int year, month;
  @override
  State<SubBalanceDialog> createState() => _SubBalanceDialogState();
}

class _SubBalanceDialogState extends State<SubBalanceDialog> {
  final name = TextEditingController(),
      amount = TextEditingController(text: '0');
  late DateTime date = DateTime(widget.year, widget.month, 1);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create Sub Balance'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Opening amount (MMK)'),
        ),
        TextButton.icon(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: date,
              firstDate: DateTime(widget.year, widget.month, 1),
              lastDate: DateTime(widget.year, widget.month + 1, 0),
            );
            if (picked != null) {
              setState(() {
                date = picked;
              });
            }
          },
          icon: const Icon(Icons.calendar_month),
          label: Text(
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'name': name.text,
          'balance_amount': amount.text,
          'balance_date':
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        }),
        child: const Text('Create'),
      ),
    ],
  );
}

class PasswordScreen extends StatefulWidget {
  const PasswordScreen({super.key, required this.api});
  final Api api;
  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final old = TextEditingController(),
      next = TextEditingController(),
      confirm = TextEditingController();
  String? message;
  bool busy = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Change password'),
      actions: const [ThemeToggleButton()],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          margin: const EdgeInsets.all(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: old,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Current password',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: next,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                  ),
                ),
                if (message != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(message!),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            message = null;
                          });
                          try {
                            await widget.api.post('/api/v1/profile/password/', {
                              'old_password': old.text,
                              'new_password1': next.text,
                              'new_password2': confirm.text,
                            });
                            setState(() {
                              message = 'Password changed.';
                            });
                          } catch (e) {
                            setState(() {
                              message = e.toString();
                            });
                          }
                          setState(() {
                            busy = false;
                          });
                        },
                  child: Text(busy ? 'Saving…' : 'Update password'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.api});
  final Api api;
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<Map<String, dynamic>> dashboard;
  late Future<Map<String, dynamic>> users;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    dashboard = widget.api.get('/api/v1/admin/dashboard/');
    users = widget.api.get('/api/v1/admin/users/');
  }

  void reload() => setState(_load);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Admin tools'),
      actions: const [ThemeToggleButton()],
    ),
    body: RefreshIndicator(
      onRefresh: () async => reload(),
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          FutureBuilder<Map<String, dynamic>>(
            future: dashboard,
            builder: (context, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              if (s.hasError) {
                return ErrorPanel(message: s.error.toString(), onRetry: reload);
              }
              final d = s.data!;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SummaryTile(
                    label: 'Users',
                    value: '${d['total_users']}',
                    icon: Icons.people_outline,
                  ),
                  SummaryTile(
                    label: 'Wallet groups',
                    value: '${d['total_balances']}',
                    icon: Icons.wallet_outlined,
                  ),
                  SummaryTile(
                    label: 'Main Balances',
                    value: '${d['total_months']}',
                    icon: Icons.account_balance_wallet_outlined,
                  ),
                  SummaryTile(
                    label: 'Categories',
                    value: '${d['total_categories']}',
                    icon: Icons.category_outlined,
                  ),
                  SummaryTile(
                    label: 'Expenses',
                    value: '${d['total_expenses']}',
                    icon: Icons.receipt_long_outlined,
                  ),
                  SummaryTile(
                    label: 'Report emails',
                    value: '${d['total_emails']}',
                    icon: Icons.email_outlined,
                  ),
                  SummaryTile(
                    label: 'Allocated',
                    value: _money(d['total_allocated']),
                    icon: Icons.payments_outlined,
                  ),
                  SummaryTile(
                    label: 'Direct spent',
                    value: _money(d['total_direct_spent']),
                    icon: Icons.payments_outlined,
                  ),
                  SummaryTile(
                    label: 'Sub Balance spent',
                    value: _money(d['total_sub_balance_spent']),
                    icon: Icons.savings_outlined,
                  ),
                  SummaryTile(
                    label: 'Spent',
                    value: _money(d['total_spent']),
                    icon: Icons.shopping_cart_outlined,
                  ),
                  SummaryTile(
                    label: 'Remaining',
                    value: _money(d['total_remaining']),
                    icon: Icons.savings_outlined,
                  ),
                ],
              );
            },
          ),
          const SectionTitle('User accounts'),
          FutureBuilder<Map<String, dynamic>>(
            future: users,
            builder: (context, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              if (s.hasError) {
                return ErrorPanel(message: s.error.toString(), onRetry: reload);
              }
              final rows = (s.data!['users'] as List)
                  .cast<Map<String, dynamic>>();
              return Column(
                children: rows
                    .map(
                      (u) => Card(
                        child: ListTile(
                          title: Text(u['name'].toString()),
                          subtitle: Text(
                            '${u['email']} · ${u['username'] ?? 'No login'} · ${u['isStaff'] == true ? 'Staff · ' : ''}${u['active'] == true ? 'Active' : 'Disabled'} · ${u['balanceCount']} balances · ${u['monthCount']} months',
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              if (action == 'delete_user' &&
                                  !await _confirmDelete(
                                    context,
                                    u['name'].toString(),
                                  )) {
                                return;
                              }
                              Map<String, String> fields = {
                                'action': action,
                                'user_id': '${u['id']}',
                              };
                              if (action == 'reset_password') {
                                fields['user'] = '${u['id']}';
                                if (!context.mounted) return;
                                final pw = await _passwordDialog(context);
                                if (pw == null) return;
                                fields.addAll(pw);
                              }
                              try {
                                await widget.api.post(
                                  '/api/v1/admin/users/actions/',
                                  fields,
                                );
                                reload();
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(e.toString())),
                                  );
                                }
                              }
                            },
                            itemBuilder: (_) => [
                              if (u['username'] != null)
                                PopupMenuItem(
                                  value: 'toggle_active',
                                  child: Text(
                                    u['active'] == true
                                        ? 'Disable account'
                                        : 'Activate account',
                                  ),
                                ),
                              if (u['username'] != null)
                                const PopupMenuItem(
                                  value: 'reset_password',
                                  child: Text('Reset password'),
                                ),
                              const PopupMenuItem(
                                value: 'delete_user',
                                child: Text('Delete user'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SectionTitle('Latest Users'),
          FutureBuilder<Map<String, dynamic>>(
            future: dashboard,
            builder: (context, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              if (s.hasError) {
                return ErrorPanel(message: s.error.toString(), onRetry: reload);
              }
              final rows = (s.data!['recentUsers'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              if (rows.isEmpty) return const _EmptyMessage('No users yet.');
              return Column(
                children: rows
                    .map(
                      (item) => ListTile(
                        title: Text(item['name'].toString()),
                        subtitle: Text(item['email'].toString()),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SectionTitle('Latest Main Balances'),
          FutureBuilder<Map<String, dynamic>>(
            future: dashboard,
            builder: (context, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              if (s.hasError) {
                return ErrorPanel(message: s.error.toString(), onRetry: reload);
              }
              final rows = (s.data!['recentMonths'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              if (rows.isEmpty) {
                return const _EmptyMessage('No Main Balances yet.');
              }
              return Column(
                children: rows
                    .map(
                      (item) => ListTile(
                        title: Text('${item['owner']} · ${item['monthLabel']}'),
                        subtitle: Text(
                          '${item['name']} · ${_money(item['totalMoney'])} MMK',
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SectionTitle('Latest Expenses'),
          FutureBuilder<Map<String, dynamic>>(
            future: dashboard,
            builder: (context, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              if (s.hasError) {
                return ErrorPanel(message: s.error.toString(), onRetry: reload);
              }
              final rows = (s.data!['recentExpenses'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              if (rows.isEmpty) {
                return const _EmptyMessage('No expenses recorded yet.');
              }
              return Column(
                children: rows
                    .map(
                      (item) => Card(
                        child: ListTile(
                          title: Text(
                            '${item['owner']} · ${item['monthLabel']}',
                          ),
                          subtitle: Text(
                            '${item['date']} · ${item['balance']} · ${item['category']}',
                          ),
                          trailing: Text('${_money(item['amount'])} MMK'),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SectionTitle('Latest Report Emails'),
          FutureBuilder<Map<String, dynamic>>(
            future: dashboard,
            builder: (context, s) {
              if (s.connectionState == ConnectionState.waiting) {
                return const LinearProgressIndicator();
              }
              if (s.hasError) {
                return ErrorPanel(message: s.error.toString(), onRetry: reload);
              }
              final rows = (s.data!['recentEmails'] as List? ?? [])
                  .cast<Map<String, dynamic>>();
              if (rows.isEmpty) {
                return const _EmptyMessage('No report emails sent yet.');
              }
              return Column(
                children: rows
                    .map(
                      (item) => ListTile(
                        title: Text('${item['owner']} · ${item['monthLabel']}'),
                        subtitle: Text(
                          '${item['reportType']} · ${item['sentAt']}',
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    ),
  );

  Future<bool> _confirmDelete(BuildContext context, String name) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete user?'),
          content: Text('Delete $name and all associated data?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;

  Future<Map<String, String>?> _passwordDialog(BuildContext context) async {
    final first = TextEditingController(), second = TextEditingController();
    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            TextField(
              controller: second,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'password1': first.text,
              'password2': second.text,
            }),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }
}

class _CategoryBudgetDialogState extends State<CategoryBudgetDialog> {
  final name = TextEditingController(), amount = TextEditingController();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add custom category'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Budget amount (MMK)'),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'new_category_name': name.text,
          'estimated_amount': amount.text,
        }),
        child: const Text('Add'),
      ),
    ],
  );
}

class SummaryTile extends StatelessWidget {
  const SummaryTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label, value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: teal),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Colors.blueGrey)),
                  const SizedBox(height: 5),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: ink,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class Metric extends StatelessWidget {
  const Metric({super.key, required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(color: Colors.blueGrey, fontSize: 12)),
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w600, color: ink),
      ),
    ],
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.bold, color: navy),
    ),
  );
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off, size: 44, color: Colors.blueGrey),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

String _money(dynamic value) {
  if (value == null) return '0';
  final number = num.tryParse(value.toString()) ?? 0;
  final raw = number.abs().round().toString();
  final grouped = raw.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '${number < 0 ? '-' : ''}$grouped';
}
