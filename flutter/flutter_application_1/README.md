# PMMS Flutter

Flutter client for the Pocket Money Management System. The web client talks to the Django session API at `/api/v1/` and expects to be served from the same origin as Django so session and CSRF cookies work.

## Run for web

From the Django project root, start the backend:

```powershell
python manage.py runserver 127.0.0.1:8001
```

Then, from this directory:

```powershell
flutter pub get
flutter build web
```

For local same-origin API proxying, use `flutter_ui/dev_server.py` as described in `flutter_ui/README.md`, or configure your deployment server to serve the web build and proxy `/api/` to Django.

For a native Android build, pass the reachable Django API origin at build time:

```powershell
flutter build apk --dart-define=PMMS_API_BASE_URL=https://your-api-host.example
```

For an Android emulator using Django on the development computer, use
`http://10.0.2.2:8001/` as the origin, or use the host address reachable from
your physical device. The native app cannot infer the Django server from its
local `Uri.base`. Use HTTPS for deployed APIs. The web build continues using
its same-origin API by default.
