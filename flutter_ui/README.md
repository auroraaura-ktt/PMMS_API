# PMMS Flutter Web UI

This client uses the Django session API under `/api/v1/`. The supplied local
preview server serves Flutter and proxies Django API and static requests through
one origin, so existing session and CSRF cookies work without CORS or cookie
setting changes. Do not put database credentials or Django secrets here.

Run locally in three PowerShell terminals. From the Django project root, start:

```powershell
python manage.py runserver 127.0.0.1:8001
```

Then build Flutter Web:

```powershell
cd flutter_ui
flutter pub get
flutter build web
```

In a third terminal, from `flutter_ui`, start the same-origin preview:

```powershell
python dev_server.py
```

Open http://127.0.0.1:8080. For deployment, serve the Flutter build at the same
origin as the Django API through the existing host or reverse proxy. The Django
server on port 8001 uses the project's current environment and database.
