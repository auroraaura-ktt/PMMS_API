# PMMS Flutter

Flutter client for the Pocket Money Management System. The web client talks to the Django session API at `/api/v1/` and expects to be served from the same origin as Django so session and CSRF cookies work.

## Run for web

From the Django project root, start the backend:

```powershell
python manage.py runserver 127.0.0.1:8001
```

Then, open a second PowerShell window at the repository root and change into
the Flutter app directory before running Flutter commands:

```powershell
Set-Location .\flutter\flutter_application_1
flutter pub get
flutter run -d chrome --dart-define=PMMS_API_BASE_URL=https://pmms-api-w6at.vercel.app/
```

`flutter run` starts the web app in Chrome. To create static web files instead,
run `flutter build web --dart-define=PMMS_API_BASE_URL=https://pmms-api-w6at.vercel.app/`
from the same Flutter app directory; output is written to `build\web`.

For local same-origin API proxying, use `flutter_ui/dev_server.py` as described in `flutter_ui/README.md`, or configure your deployment server to serve the web build and proxy `/api/` to Django.

Native Android builds default to the PMMS API at
`https://pmms-api-w6at.vercel.app/`. To override it for another environment,
pass the Django API origin at build time:

```powershell
$env:JAVA_HOME = 'C:\Path\To\jdk-17-or-newer'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
flutter doctor --android-licenses
flutter build apk --dart-define=PMMS_API_BASE_URL=https://pmms-api-w6at.vercel.app/
```

Accept the Android SDK license prompts only if you agree to their terms.
After a successful build, the APK is a file at
`build\app\outputs\flutter-apk\app-release.apk`, not a PowerShell command.

`JAVA_PATH` alone is not used by Gradle; set `JAVA_HOME` to the JDK directory.
The Gradle wrapper uses the smaller official binary distribution. If the
download still fails, allow outbound HTTPS to `downloads.gradle.org` and
`github.com`/`release-assets.githubusercontent.com`, then rerun the build.

For an Android emulator using Django on the development computer, use
`http://10.0.2.2:8001/` as the origin, or use the host address reachable from
your physical device. The native app cannot infer the Django server from its
local `Uri.base`. Use HTTPS for deployed APIs. The web build continues using
its same-origin API by default.
