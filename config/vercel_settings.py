import os

from django.core.exceptions import ImproperlyConfigured
from dotenv import load_dotenv

load_dotenv()


SECRET_KEY = os.getenv("SECRET_KEY", "").strip()
if not SECRET_KEY:
    raise ImproperlyConfigured("Set SECRET_KEY in the Vercel project environment.")

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
if not DATABASE_URL.startswith(("postgres://", "postgresql://")):
    raise ImproperlyConfigured(
        "Set DATABASE_URL to the existing durable PostgreSQL database; "
        "SQLite is not supported for the Vercel API deployment."
    )

from .settings import *  # noqa: E402,F403

SECRET_KEY = os.environ["SECRET_KEY"]
DEBUG = False
ROOT_URLCONF = "config.urls"

configured_hosts = {
    host.strip()
    for host in os.getenv("ALLOWED_HOSTS", "").split(",")
    if host.strip()
}
vercel_url = os.getenv("VERCEL_URL", "").strip()
if vercel_url:
    configured_hosts.add(vercel_url)
if not configured_hosts:
    raise ImproperlyConfigured(
        "Set ALLOWED_HOSTS to the mobile API's Vercel domain."
    )
ALLOWED_HOSTS = sorted(configured_hosts)

CSRF_TRUSTED_ORIGINS = [
    origin.strip().rstrip("/")
    for origin in os.getenv("CSRF_TRUSTED_ORIGINS", "").split(",")
    if origin.strip()
]

SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_SSL_REDIRECT = True

MIDDLEWARE = [
    "config.middleware.ApiOnlyMiddleware",
    *[
        middleware
        for middleware in MIDDLEWARE
        if middleware != "budget.middleware.AutoEmailMiddleware"
    ],
]
