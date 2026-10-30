from django.http import JsonResponse


class NativeCsrfOriginMiddleware:
    """Allow token-bearing native API writes through Django's HTTPS origin check."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if (
            request.path.startswith("/api/")
            and request.method in {"POST", "PUT", "PATCH", "DELETE"}
            and request.headers.get("X-CSRFToken")
            and not request.headers.get("Origin")
            and not request.headers.get("Referer")
        ):
            request.META["HTTP_ORIGIN"] = (
                f"{request.scheme}://{request.get_host()}"
            )
        return self.get_response(request)


class ApiOnlyMiddleware:
    """Keep the standalone mobile deployment limited to JSON API routes."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if not (
            request.path.startswith("/api/v1/")
            or request.path.startswith("/api/categories/")
        ):
            return JsonResponse({"error": "Not found."}, status=404)
        return self.get_response(request)
