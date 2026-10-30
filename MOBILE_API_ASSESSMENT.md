# PMMS Shared API Assessment

## Scope and outcome

This assessment covers the existing Django API, its use by the Flutter client,
database and deployment configuration present in this checkout, and the
repository's tracked-file risks. No application code, database, deployment, or
Flutter configuration was changed. The pre-existing modification to
`flutter/flutter_application_1/lib/main.dart` was preserved.

**Conclusion:** PMMS already has a session-authenticated JSON API under
`/api/v1/`, and the Android Flutter client already uses it. Its endpoint
coverage is sufficient for the features visible in the client. A duplicate
mobile API implementation is not indicated. A separately deployed copy of the
Django project could reuse the API, but deployment is not ready to verify:
there is no Vercel project configuration or deployment URL in this checkout,
and the production database configuration cannot be established from the
tracked files. Deploying a second instance against the same database also
requires addressing the scheduled-email middleware described below.

## API inventory

The API is registered by `config/urls.py` including `budget/urls.py`. All
`/api/v1/` write endpoints accept POST form data, use Django session
authentication, and rely on Django CSRF middleware. They return JSON rather
than REST-style resources and use action fields where noted.

| Route | Method | Authentication / permissions | Request and response | Flutter classification |
|---|---|---|---|---|
| `/api/v1/csrf/` | GET | Public; sets a CSRF cookie | No parameters; returns `csrfToken` | Ready; client fetches before POST |
| `/api/v1/auth/login/` | POST | Public; CSRF required | `username`, `password`; returns `ok` and user `username`/`isStaff` | Ready |
| `/api/v1/auth/register/` | POST | Public; CSRF required | Existing registration form fields; returns `ok` and user summary on success | Ready; registration is in the client |
| `/api/v1/auth/logout/` | POST | No login required; CSRF required | No required fields; returns `ok` | Ready |
| `/api/v1/auth/me/` | GET | Login required | Returns `username`, `isStaff`, `name` | Ready |
| `/api/v1/profile/password/` | POST | Login required; CSRF required | Django password-change form fields; JSON validation/success result | Ready |
| `/api/v1/dashboard/` | GET | Login required; owner-scoped | Returns `user`, owned `balances`, `months`, and each month's report summary | Ready |
| `/api/v1/dashboard/actions/` | POST | Login required; CSRF required; existing dashboard forms scope objects to the signed-in user | `action` selects existing balance, month, category, budget, or transaction workflows; returns JSON success/error | Ready; main Flutter mutation route |
| `/api/v1/main-balances/<month_id>/` | GET | Login required; month must belong to signed-in user | Returns month summary, report, categories, expenses, and sub-balances | Ready |
| `/api/v1/main-balances/<month_id>/actions/` | POST | Login required; ownership enforced by existing views | `action=edit`, `delete`, or `create_sub_balance`, plus existing form fields | Ready |
| `/api/v1/main-balances/<month_id>/report/` | GET | Login required; month must belong to signed-in user | Existing monthly-report JSON | Ready |
| `/api/v1/main-balances/<month_id>/report/actions/` | POST | Login required; CSRF required; month ownership checked | `action=email`; report generation and mail delivery use the existing report view/service | Ready for Flutter's report-email action |
| `/api/v1/sub-balances/<sub_balance_id>/` | GET | Login required; sub-balance must belong to signed-in user | Returns parent month, allocation, actual/remaining totals, categories, expenses, and report schedule state | Ready |
| `/api/v1/sub-balances/<sub_balance_id>/actions/` | POST | Login required; CSRF required; existing view scopes the parent and child records | Existing sub-balance edit/delete/finish and category/transaction form actions | Ready |
| `/api/v1/admin/dashboard/` | GET | Authenticated staff only | Existing admin summary and recent record/email summaries | Ready for admin UI |
| `/api/v1/admin/users/` | GET | Authenticated staff only | Returns `users` with profile/account and count summaries | Ready for admin UI |
| `/api/v1/admin/users/actions/` | POST | Authenticated staff only; CSRF required | Existing admin actions, including account management, delegated to the web view | Ready for admin UI |
| `/api/categories/<month_id>/` | GET | Login required; month query is owner-scoped | Returns `categories` and `sub_balances`; an unowned/nonexistent month returns empty arrays | Not referenced by Flutter; legacy JSON endpoint |

The API does not expose separate REST `PUT`, `PATCH`, or `DELETE` routes.
Mutations are POST action/form workflows. This matches the current Flutter
client, but another client must follow that contract rather than assume generic
CRUD verbs. Invalid forms are converted to JSON errors; unsupported main- or
sub-balance actions return a client error.

### Existing business behavior and permissions

- API writes delegate to existing Django views and forms; financial validation
  and report calculations are not duplicated in the API adapter.
- Dashboard and detail queries use the authenticated user's `PocketUser`
  profile. Month and sub-balance detail routes explicitly filter by that owner.
- Admin routes separately require `is_staff`.
- Django session and CSRF middleware remain active. No bearer-token system or
  DRF installation was found.
- No request throttling configuration was found. Public login and registration
  therefore need appropriate deployment-level protection or an explicit
  throttling implementation before exposure to abuse.
- No CORS middleware/configuration was found. Native Android requests do not
  use browser CORS; Flutter Web must remain same-origin or have narrowly scoped
  CORS configured before cross-origin use.

## Flutter compatibility

The Android client currently calls the `/api/v1/` routes listed above. It
fetches a CSRF token before form POSTs, handles JSON errors and unauthorized
responses, and applies 20-second request timeouts. The production API origin is
already configurable via `--dart-define=PMMS_API_BASE_URL=...`; the client does
not need a new endpoint contract to use a separately hosted origin.

On Android, the client stores session cookies through a platform channel. The
Android implementation encrypts the stored value with AES-GCM and an
Android-Keystore key. Flutter Web uses credentialed browser requests and
therefore remains subject to same-origin/CORS and cookie policy rules.

The tested client source has one pre-existing worktree change in
`flutter/flutter_application_1/lib/main.dart`; it was not modified here.

## Local test and deployment evidence

| Check | Result |
|---|---|
| `python manage.py check` | Passed; no system-check issues |
| `python manage.py test budget.test_api --verbosity 2` | Passed; 7 API tests |
| `python manage.py test --verbosity 1` | Passed; 121 Django tests |
| API test coverage observed | CSRF seed, login/session dashboard, anonymous 401, foreign-owner month 404, sub-balance response, CSRF rejection, valid and invalid dashboard writes, and staff-only admin behavior |
| Flutter `flutter test` / `flutter analyze` | Not run: Flutter executable is unavailable in this environment |
| Live HTTP tests against a deployment | Not run: no deployed API URL is discoverable in the checkout |

These are local Django test-client/test-suite results, not evidence that any
remote Vercel deployment is working. There is no `vercel.json` or other Vercel
project configuration in the repository tree, and no existing production API
URL was found in the inspected source/docs. Consequently no live status codes,
login behavior, or JSON payloads can be asserted for a deployed endpoint.

## Database and separate-deployment risk

The local configuration uses SQLite when `DATABASE_URL` is absent. On Vercel,
the settings copy a bundled SQLite database into `/tmp`; that filesystem is
ephemeral and is not a shared, durable source of truth. A separate service
using that fallback would not satisfy the single-database requirement.

For a separate deployment, the new Vercel project must be configured with the
same approved production database connection used by the existing backend. No
production database URL or Vercel environment values were read or verified,
and no database migrations or production writes were performed.

There is an additional behavior to resolve before deploying a second Django
instance against the same database: `AutoEmailMiddleware` runs scheduled
report jobs on incoming requests. Its cache is process-local, so two Vercel
deployments may both attempt scheduled work. Database report logs provide
deduplication, but do not prove that simultaneous requests cannot send
duplicate mail. A mobile deployment should not enable a second scheduler
without an explicit shared-lock/single-scheduler decision.

The settings also default `DEBUG` to true and use an insecure fallback
`SECRET_KEY`. Production safety depends on deployment environment overrides;
those overrides cannot be inspected here. A new deployment must explicitly
set production-safe values and an approved database connection. The existing
`.env.example` does not document `DATABASE_URL`.

## Recommended deployment layout

Do not copy the Django app, models, financial logic, or database into a second
implementation. The lowest-duplication option is a new Vercel project that
deploys the existing Django source from the repository root, leaving the
existing website project and its settings untouched. Give the new Vercel
project its own environment configuration, connect it to the same approved
database, and ensure only one deployment runs scheduled email processing.
After the new URL is live and its API is verified, pass that URL to the
existing Flutter `PMMS_API_BASE_URL` build define.

No separate mobile-specific source folder is justified by the current API
surface. A subdirectory-root deployment would need a verified packaging/import
strategy for the shared Django project; copying backend code into such a folder
would create drift and is not recommended. No deployment URL can be supplied
until the new project has actually been created and verified.

## Git, generated files, and sensitive-file inspection

- The only pre-existing worktree change is
  `flutter/flutter_application_1/lib/main.dart`; it remains untouched.
- `.gitignore` currently ignores only `.env`.
- Tracked generated content includes 59 `__pycache__`/`.pyc` entries and 203
  files under `flutter/.git.backup/`.
- The Git tree tracks a 262,672,383-byte `flutter/.git.backup/objects/pack/...`
  file, a 196,608-byte `db.sqlite3`, and
  `Users & Admin Passwords.docx`. Their contents were not inspected or
  reproduced. The latter filename indicates a credential-bearing document;
  treat it as sensitive.
- The repository has one commit, so these items are present in its current
  history, not just untracked build output. Adding ignore rules alone would
  not remove them from Git history.
- No APKs or Flutter `build/` files are currently tracked.
- No files were removed, untracked, committed, or pushed. Do not push this
  repository as-is for the mobile API. Rotate any credentials that may have
  been exposed by the tracked document; history cleanup requires separate
  approval because it rewrites repository history.

## Phase decision

The shared API implementation is present and passes the local Django test
suite; no API endpoint changes are currently justified. Deployment, release
APK configuration, and website regression checks against production remain
unverified. They were not attempted because the live API/Vercel project and
the approved shared production database configuration are unavailable here,
and deploying a second scheduler without a single-runner policy risks
production email behavior.

## Vercel deployment preparation (follow-up)

The repository now includes a Vercel WSGI entrypoint in `pyproject.toml`, an
API-only settings profile in `config/vercel_settings.py`, and deployment
instructions in `VERCEL_DEPLOYMENT.md`. The profile requires a strong
`SECRET_KEY`, an explicit `ALLOWED_HOSTS`, and a durable PostgreSQL
`DATABASE_URL`; it refuses the previous Vercel temporary-SQLite fallback. It
also prevents the mobile deployment from running website views and the
request-triggered email scheduler. The website's default settings remain
unchanged apart from the static collection directory needed for Vercel builds.

The native Flutter client sends the CSRF token header but does not send a
browser `Origin`/`Referer`. A Vercel-only middleware supplies the request's
own HTTPS origin for token-bearing API writes only when both browser headers
are absent. HTTPS tests confirm missing/invalid tokens and foreign origins are
still rejected.

Local checks with temporary, non-production environment values passed:
Vercel-profile `manage.py check`, API route smoke tests, static collection,
and all seven existing API tests. `manage.py check --deploy` reported that HSTS
is not enabled; decide HSTS only after verifying that all deployment domains
are permanently HTTPS and under project control. No Vercel CLI, linked project,
production environment variables, production database URL, or live HTTP
endpoint was available here, so no successful Vercel deployment is claimed.
