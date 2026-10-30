# Deploy the PMMS Mobile API to Vercel

The Django API is part of the existing project; it is not an independent
`api/` source folder. Deploy this repository as a **new Vercel project** with
the repository root as its Root Directory. The root `pyproject.toml` identifies
the WSGI entrypoint. The Vercel-only settings serve the existing `/api/`
routes, while returning JSON 404s for website pages. The existing website's
project and default Django settings are unchanged.

## Required Vercel project settings

Add these environment variables to the **new API project**, for the Production
environment (and Preview if previews will be used):

| Variable | Value |
|---|---|
| `DJANGO_SETTINGS_MODULE` | `config.vercel_settings` |
| `SECRET_KEY` | A new, randomly generated Django secret. Do not commit it or put it in Flutter. |
| `DATABASE_URL` | The existing website's durable PostgreSQL connection URL. This must be the same database, not a new database or SQLite file. |
| `ALLOWED_HOSTS` | The API's exact production hostname, such as `pmms-mobile-api.vercel.app`; comma-separate any custom domains. |
| `CSRF_TRUSTED_ORIGINS` | Only needed for browser-based clients; comma-separated full `https://` origins that actually call the API. Leave empty for native Android only. |

`DATABASE_SSL_REQUIRE=True` is already the Django default. Configure SMTP
variables (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`,
and optionally `SMTP_FROM_NAME`) only if API report-email actions should send
mail from this deployment. Never commit production values.

`config.vercel_settings` fails startup unless a secret key, explicit host, and
PostgreSQL URL are configured. It does not use or copy the repository's local
SQLite database. Before setting `DATABASE_URL`, verify it is the same database
used by the existing website. No production connection string is included in
this repository.

The mobile API deployment disables the request-triggered automated email
scheduler, so creating a second Vercel deployment does not create a second
scheduler against the shared records. The existing website retains its current
scheduler.

Native Flutter writes include Django's CSRF token header but do not send a
browser `Origin` or `Referer`. The API-only deployment handles that native
request shape by supplying the request's own HTTPS origin only when a write
includes the CSRF header and has neither browser header. Django still validates
the CSRF cookie/header token; any supplied browser origin is checked normally.
This does not enable CORS.

## Vercel project setup

1. Connect the existing Git repository and create a **new project**. Do not
   change or replace the existing website Vercel project.
2. Set **Root Directory** to the repository root (the directory containing
   `manage.py`, `requirements.txt`, and `pyproject.toml`).
3. Use the Django framework preset/automatic detection. Do not add a separate
   build command or output directory. Vercel detects `manage.py`, installs
   `requirements.txt`, uses `config.wsgi:application`, and collects Django
   static files when `STATIC_ROOT` is configured.
4. Add and verify the required environment variables above before deploying.
   The environment variable `DJANGO_SETTINGS_MODULE` makes Vercel load the
   API-only settings profile.
5. Deploy to a preview first. Verify the API with HTTPS requests before
   promoting a production deployment or configuring Flutter.

The repository root is required because the API imports the existing `budget`
app, Django project settings, forms, templates, services, and migrations.
`.vercelignore` omits Flutter projects, the local SQLite database, local
scripts, and other non-runtime assets from the deployment bundle.

## Safe pre-deployment checks

Run these checks locally before connecting the project. Set the values in a
local shell or an untracked `.env`; do not commit real secrets:

```powershell
$env:DJANGO_SETTINGS_MODULE = "config.vercel_settings"
$bytes = New-Object byte[] 64
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$env:SECRET_KEY = [Convert]::ToBase64String($bytes)
$rng.Dispose()
$env:DATABASE_URL = "postgresql://db-host.example:5432/pmms"
$env:ALLOWED_HOSTS = "localhost,testserver"
python manage.py check
python manage.py check --deploy
```

The example database URL is illustrative and must not be used. `check --deploy`
may additionally report security items such as HTTPS/HSTS settings that must be
reviewed against the actual Vercel domain and deployment policy. Do not run
migrations against production merely to test deployment. The existing database
must already have the required PMMS migrations applied.

After Vercel provides a preview URL, test at least:

- `GET /api/v1/csrf/` returns HTTP 200 and JSON with `csrfToken`.
- `GET /api/v1/auth/me/` without a session returns HTTP 401 JSON.
- `GET /` returns JSON 404 (website routes are not exposed by this API project).
- With a dedicated test account, exercise login, authenticated reads/writes,
  logout, CSRF rejection, and cross-user ownership checks.

Do not use production account credentials or make financial writes in a live
production test. A successful local check does not prove that the Vercel
environment variables, DNS, production database connectivity, or deployed
HTTP endpoints are correct.

## Flutter

Only after the API preview passes the HTTP and authenticated tests, build
Flutter with the verified HTTPS origin:

```powershell
flutter build apk --release --dart-define=PMMS_API_BASE_URL=https://YOUR-VERIFIED-API-DOMAIN
```

The Vercel URL has not yet been created or verified. Do not substitute a
guessed URL in a release APK.
