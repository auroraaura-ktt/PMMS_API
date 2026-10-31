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
This does not enable CORS. If native login gets HTTP 403 while the same
CSRF-token-bearing request with the API's own `Origin` succeeds, check that
`DJANGO_SETTINGS_MODULE=config.vercel_settings` is configured for the API
project's Production environment and redeploy. The default website settings
do not include the native-origin middleware.

## Vercel project setup

1. Connect the existing Git repository and create a **new project**. Do not
   change or replace the existing website Vercel project.
2. Set **Root Directory** to the repository root (the directory containing
   `manage.py`, `requirements.txt`, and `pyproject.toml`). Do not select
   `budget/`, `config/`, or the Flutter directory as the Vercel Root Directory:
   Django and its package metadata are at the repository root.
3. Use the Django framework preset/automatic detection. Do not add a separate
   build command or output directory. Vercel detects `manage.py`, installs
   `requirements.txt`, uses `config.wsgi:application`, and collects Django
   static files when `STATIC_ROOT` is configured.
4. Add and verify the required environment variables above before deploying.
   In the API Vercel project's Production (and Preview, if used) environment,
   set `DJANGO_SETTINGS_MODULE=config.vercel_settings`. This must not be set on
   the website project.
5. Deploy to a preview first. Verify the API with HTTPS requests before
   promoting a production deployment or configuring Flutter.

The repository root is required because the API imports the existing `budget`
app, Django project settings, forms, templates, services, and migrations.
`.vercelignore` omits Flutter projects, the local SQLite database, local
scripts, and other non-runtime assets from the deployment bundle.

Both `requirements.txt` and `[project].dependencies` in `pyproject.toml` list
the runtime packages. The project metadata makes Django available to Vercel's
Python/Django settings-discovery step, which inspects `manage.py`; relying only
on the later function dependency installation can fail with
`DJANGO_SETTINGS_FAILED` / `No module named 'django'`.

If that error persists after committing and redeploying these files, confirm
that the Vercel deployment commit contains both the Django dependency
declarations and that the project's Root Directory is the repository root.
Check the install/build logs for a dependency installation failure before
changing Python code. A Vercel environment variable alone cannot install
Django into the settings-discovery interpreter.

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

The configured API URL supplied for Flutter is
`https://pmms-api-w6at.vercel.app/`. A live unauthenticated smoke check returned
HTTP 200 JSON from `/api/v1/csrf/` and HTTP 401 from `/api/v1/auth/me/`, as
expected. This verifies those public/unauthenticated routes only; it does not
verify login, account permissions, financial writes, or database consistency.
Before relying on the service for production financial data, test those flows
with a dedicated test account and a safe test dataset.

For any additional preview deployment, test at least:

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

Build Flutter with the supplied API origin (or override it for another
environment):

```powershell
flutter build apk --release --dart-define=PMMS_API_BASE_URL=https://pmms-api-w6at.vercel.app/
```

Android builds use this URL by default; `PMMS_API_BASE_URL` overrides it.
Flutter Web continues to use its same-origin base URL unless this define is
provided.
