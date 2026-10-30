import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pmms_flutter/main.dart';

void main() {
  test(
    'native API requests retain and rotate Django session cookies',
    () async {
      final requests = <http.Request>[];
      final api = Api(
        client: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/v1/csrf/':
              return http.Response(
                '{"csrfToken":"csrf-before"}',
                200,
                headers: {
                  'content-type': 'application/json',
                  'set-cookie': 'csrftoken=csrf-before; Path=/; SameSite=Lax',
                },
              );
            case '/api/v1/auth/login/':
              return http.Response(
                '{"ok":true}',
                200,
                headers: {
                  'content-type': 'application/json',
                  'set-cookie': 'csrftoken=csrf-after; Path=/; SameSite=Lax, sessionid=session-value; HttpOnly; Path=/; SameSite=Lax',
                },
              );
            case '/api/v1/dashboard/':
              return http.Response(
                '{"months":[],"balances":[]}',
                200,
                headers: {'content-type': 'application/json'},
              );
            default:
              return http.Response('Unexpected request', 500);
          }
        }),
      );

      await api.post('/api/v1/auth/login/', {
        'username': 'tester',
        'password': 'safe-password',
      });
      await api.get('/api/v1/dashboard/');

      final loginRequest = requests.firstWhere(
        (request) => request.url.path == '/api/v1/auth/login/',
      );
      String headerValue(http.Request request, String name) => request
          .headers
          .entries
          .firstWhere(
            (entry) => entry.key.toLowerCase() == name,
            orElse: () => const MapEntry('', ''),
          )
          .value;
      expect(
        headerValue(loginRequest, 'cookie'),
        contains('csrftoken=csrf-before'),
      );
      expect(headerValue(loginRequest, 'x-csrftoken'), 'csrf-before');
      final dashboardRequest = requests.firstWhere(
        (request) => request.url.path == '/api/v1/dashboard/',
      );
      expect(
        headerValue(dashboardRequest, 'cookie'),
        contains('sessionid=session-value'),
      );
      expect(
        headerValue(dashboardRequest, 'cookie'),
        contains('csrftoken=csrf-after'),
      );
    },
  );

  test(
    'non-JSON API responses report the HTTP status without exposing HTML',
    () async {
      final api = Api(
        client: MockClient(
          (_) async => http.Response('<html>Vercel not found</html>', 404),
        ),
      );

      await expectLater(
        api.get('/api/v1/dashboard/'),
        throwsA(
          isA<ApiException>()
              .having((error) => error.status, 'status', 404)
              .having(
                (error) => error.message,
                'message',
                contains('does not provide this PMMS API route'),
              ),
        ),
      );
    },
  );

  testWidgets(
    'public home is available while the startup session check is pending',
    (tester) async {
      final pendingSessionCheck = Completer<http.Response>();
      final api = Api(
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/auth/me/') {
            return pendingSessionCheck.future;
          }
          return http.Response('Unexpected request', 500);
        }),
      );

      await tester.pumpWidget(PmmsApp(api: api));
      await tester.pump();

      expect(find.text('Pocket Money Management System'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      pendingSessionCheck.complete(
        http.Response(
          '{"error":"Authentication required."}',
          401,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pocket Money Management System'), findsOneWidget);
    },
  );

  testWidgets(
    'a late signed-out session check cannot undo a successful login',
    (tester) async {
      final pendingSessionCheck = Completer<http.Response>();
      final api = Api(
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/api/v1/auth/me/':
              return pendingSessionCheck.future;
            case '/api/v1/csrf/':
              return http.Response(
                '{"csrfToken":"csrf-before-login"}',
                200,
                headers: {'content-type': 'application/json'},
              );
            case '/api/v1/auth/login/':
              return http.Response(
                '{"ok":true,"user":{"username":"tester","isStaff":false}}',
                200,
                headers: {'content-type': 'application/json'},
              );
            case '/api/v1/dashboard/':
              return http.Response(
                '{"user":{"username":"tester","name":"Test User"},"balances":[],"months":[]}',
                200,
                headers: {'content-type': 'application/json'},
              );
            default:
              return http.Response('Unexpected request', 500);
          }
        }),
      );

      await tester.pumpWidget(PmmsApp(api: api));
      await tester.pump();
      await tester.tap(find.text('Login').first);
      await tester.pump();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'tester');
      await tester.enterText(fields.at(1), 'safe-password');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Dashboard · Setup'), findsOneWidget);
      pendingSessionCheck.complete(
        http.Response(
          '{"error":"Authentication required."}',
          401,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dashboard · Setup'), findsOneWidget);
    },
  );

  testWidgets(
    'successful login opens dashboard without a post-login CSRF or duplicate session request',
    (tester) async {
      final requests = <http.Request>[];
      final api = Api(
        client: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/v1/auth/me/':
              return http.Response(
                '{"error":"Authentication required."}',
                401,
                headers: {'content-type': 'application/json'},
              );
            case '/api/v1/csrf/':
              return http.Response(
                '{"csrfToken":"csrf-before-login"}',
                200,
                headers: {'content-type': 'application/json'},
              );
            case '/api/v1/auth/login/':
              return http.Response(
                '{"ok":true,"user":{"username":"tester","isStaff":false}}',
                200,
                headers: {'content-type': 'application/json'},
              );
            case '/api/v1/dashboard/':
              return http.Response(
                '{"user":{"username":"tester","name":"Test User"},"balances":[],"months":[]}',
                200,
                headers: {'content-type': 'application/json'},
              );
            default:
              return http.Response('Unexpected request', 500);
          }
        }),
      );

      await tester.pumpWidget(PmmsApp(api: api));
      await tester.pump();
      await tester.tap(find.text('Login').first);
      await tester.pump();
      expect(find.text('Welcome back'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'tester');
      await tester.enterText(fields.at(1), 'safe-password');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Dashboard · Setup'), findsOneWidget);
      expect(
        requests.where((request) => request.url.path == '/api/v1/csrf/').length,
        1,
        reason:
            'Only the pre-login token request is needed; the next write can '
            'fetch the rotated token when required.',
      );
      expect(requests.map((request) => request.url.path), [
        '/api/v1/auth/me/',
        '/api/v1/csrf/',
        '/api/v1/auth/login/',
        '/api/v1/dashboard/',
      ]);
      expect(
        requests
            .where((request) => request.url.path == '/api/v1/auth/me/')
            .length,
        1,
        reason: 'Login should reuse its successful authentication response instead of rechecking the session.',
      );
    },
  );
}
