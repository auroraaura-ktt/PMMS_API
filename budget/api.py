"""Session authenticated JSON adapter for the Flutter web client.

The adapter deliberately delegates writes to the existing Django views/forms.
It introduces no new financial rules and relies on Django's session, CSRF,
login, ownership, and staff checks.
"""

from dataclasses import asdict, is_dataclass
from datetime import timedelta
from decimal import Decimal
from functools import wraps

from django.contrib.auth import login, logout
from django.contrib.messages import get_messages
from django.contrib.messages.constants import WARNING
from django.contrib.auth.forms import AuthenticationForm
from django.core.serializers.json import DjangoJSONEncoder
from django.http import JsonResponse
from django.middleware.csrf import get_token
from django.utils import timezone
from django.views.decorators.csrf import ensure_csrf_cookie
from django.views.decorators.http import require_GET, require_POST

from budget import views
from budget.forms import UserRegistrationForm
from budget.models import BudgetCategory, BudgetMonth, DailyExpense, PocketUser, ReportEmailLog, SubBalance
from budget.services.report_service import generate_monthly_report


def api_login_required(view):
    @wraps(view)
    def wrapped(request, *args, **kwargs):
        if not request.user.is_authenticated:
            return _json({"error": "Authentication required."}, 401)
        return view(request, *args, **kwargs)
    return wrapped


class _Encoder(DjangoJSONEncoder):
    def default(self, value):
        if isinstance(value, Decimal):
            return str(value)
        if is_dataclass(value):
            return asdict(value)
        return super().default(value)


def _json(data, status=200):
    if is_dataclass(data):
        data = asdict(data)
    return JsonResponse(data, status=status, encoder=_Encoder)


def _api_errors(response):
    """Extract errors from a bound form on an existing rendered view."""
    context = getattr(response, "context_data", None) or {}
    errors = {}
    for key, value in context.items():
        if hasattr(value, "errors"):
            form_errors = {name: [str(item) for item in items]
                           for name, items in value.errors.items()}
            if form_errors:
                errors[key] = form_errors
    return errors


def _finish_existing_view(request, response):
    if response.status_code in (301, 302, 303, 307, 308):
        warnings = [str(message) for message in get_messages(request) if message.level >= WARNING]
        if warnings:
            return _json({"ok": False, "error": " ".join(warnings)}, 400)
        return _json({"ok": True, "next": response["Location"]})
    if response.status_code >= 400:
        errors = _api_errors(response)
        return _json({"ok": False, "errors": errors} if errors else {
            "ok": False, "error": response.reason_phrase or "Request failed."
        }, response.status_code)
    errors = _api_errors(response)
    if errors:
        return _json({"ok": False, "errors": errors}, 400)
    return _json({"ok": False, "error": "The submitted data did not pass validation."}, 400)


@ensure_csrf_cookie
@require_GET
def csrf(request):
    return _json({"csrfToken": get_token(request)})


@require_POST
def login_api(request):
    form = AuthenticationForm(request, data=request.POST)
    if not form.is_valid():
        return _json({"ok": False, "errors": form.errors.get_json_data()}, 400)
    user = form.get_user()
    login(request, user)
    return _json({"ok": True, "user": {"username": user.get_username(), "isStaff": user.is_staff}})


@require_POST
def register_api(request):
    form = UserRegistrationForm(request.POST)
    if not form.is_valid():
        return _json({"ok": False, "errors": form.errors.get_json_data()}, 400)
    user = form.save()
    login(request, user)
    return _json({"ok": True, "user": {"username": user.get_username(), "isStaff": user.is_staff}}, 201)


@require_POST
def logout_api(request):
    logout(request)
    return _json({"ok": True})


@api_login_required
@require_GET
def me(request):
    pocket = getattr(request.user, "pocket_user_profile", None)
    return _json({"username": request.user.get_username(), "isStaff": request.user.is_staff,
                  "name": pocket.name if pocket else request.user.get_username()})


@api_login_required
@require_GET
def dashboard(request):
    pocket = views._current_pocket_user(request)
    months = BudgetMonth.objects.filter(user=pocket).select_related("balance")
    rows = []
    for month in months:
        report = generate_monthly_report(month.id, include_transactions=False)
        rows.append({"id": month.id, "name": month.name or month.month_label,
                     "year": month.year, "month": month.month,
                     "monthLabel": month.month_label, "totalMoney": month.total_money,
                     "balance": month.balance.name if month.balance else None,
                     "report": report})
    balances = list(pocket.balances.values("id", "name"))
    return _json({"user": {"username": request.user.get_username(), "name": pocket.name},
                  "balances": balances, "months": rows})


@api_login_required
@require_GET
def month_detail(request, month_id):
    pocket = views._current_pocket_user(request)
    month = BudgetMonth.objects.filter(id=month_id, user=pocket).first()
    if not month:
        return _json({"error": "Main Balance not found."}, 404)
    report = generate_monthly_report(month.id)
    categories = list(BudgetCategory.objects.filter(budget_month=month).values(
        "id", "name", "estimated_amount", "period_index", "sub_balance_id"))
    expenses = list(DailyExpense.objects.filter(budget_month=month).select_related(
        "category", "sub_balance").values("id", "expense_date", "amount", "note",
        "category_id", "sub_balance_id", "category__name", "sub_balance__name"))
    subs = list(SubBalance.objects.filter(budget_month=month).values(
        "id", "name", "balance_amount", "balance_date", "estimated_amount"))
    return _json({"id": month.id, "name": month.name or month.month_label,
                  "monthLabel": month.month_label, "year": month.year,
                  "month": month.month, "totalMoney": month.total_money,
                  "report": report, "categories": categories,
                  "expenses": expenses, "subBalances": subs})


@api_login_required
@require_GET
def sub_balance_detail(request, sub_balance_id):
    pocket = views._current_pocket_user(request)
    sub = SubBalance.objects.filter(id=sub_balance_id, budget_month__user=pocket).first()
    if not sub:
        return _json({"error": "Sub Balance not found."}, 404)
    created_local = timezone.localtime(sub.created_at)
    report_due_date = created_local.date() + timedelta(days=15)
    return _json({"id": sub.id, "name": sub.name,
                  "monthId": sub.budget_month_id, "monthLabel": sub.budget_month.month_label,
                  "balanceAmount": sub.balance_amount, "balanceDate": sub.balance_date,
                  "createdAt": created_local.date(), "reportDueDate": report_due_date,
                  "today": timezone.localdate(),
                  "scheduledSent": ReportEmailLog.objects.filter(
                      budget_month=sub.budget_month, report_type=f"sb15_{sub.id}"
                  ).exists(),
                  "finishSent": ReportEmailLog.objects.filter(
                      budget_month=sub.budget_month, report_type=f"sbfn_{sub.id}"
                  ).exists(),
                  "allocatedAmount": sub.allocated_amount,
                  "totalActualSpent": sub.total_actual_spent,
                  "remainingBalance": sub.remaining_balance,
                  "categories": [{"id": category.id, "name": category.name,
                                  "estimated_amount": category.estimated_amount,
                                  "actual_amount": sum(abs(expense.amount) for expense in category.expenses.filter(
                                      sub_balance=sub, budget_month_id=sub.budget_month_id
                                  ))}
                                 for category in sub.categories.all()],
                  "expenses": list(sub.expenses.select_related("category").values(
                      "id", "expense_date", "amount", "note", "category_id", "category__name"))})


@api_login_required
@require_GET
def report(request, month_id):
    pocket = views._current_pocket_user(request)
    if not BudgetMonth.objects.filter(id=month_id, user=pocket).exists():
        return _json({"error": "Main Balance not found."}, 404)
    return _json(generate_monthly_report(month_id))


@api_login_required
@require_POST
def dashboard_action(request):
    """Run a dashboard form action through the established validation path."""
    response = views.dashboard(request)
    return _finish_existing_view(request, response)


@api_login_required
@require_POST
def main_balance_action(request, month_id):
    action = request.POST.get("action")
    if action == "edit":
        response = views.edit_main_balance(request, month_id)
    elif action == "delete":
        response = views.delete_main_balance(request, month_id)
    elif action == "create_sub_balance":
        response = views.create_sub_balance(request, month_id)
    else:
        return _json({"error": "Unsupported Main Balance action."}, 400)
    return _finish_existing_view(request, response)


@api_login_required
@require_POST
def sub_balance_action(request, sub_balance_id):
    action = request.POST.get("action")
    if action == "edit":
        response = views.edit_sub_balance(request, sub_balance_id)
    elif action == "delete":
        response = views.delete_sub_balance(request, sub_balance_id)
    elif action == "finish":
        response = views.finish_sub_balance(request, sub_balance_id)
    else:
        # Category and transaction workflows are implemented in this existing view.
        response = views.sub_balance_detail(request, sub_balance_id)
    return _finish_existing_view(request, response)


@api_login_required
@require_POST
def report_action(request, month_id):
    pocket = views._current_pocket_user(request)
    if not BudgetMonth.objects.filter(id=month_id, user=pocket).exists():
        return _json({"error": "Main Balance not found."}, 404)
    # Report email behavior and report generation remain in the existing view.
    request.POST = request.POST.copy()
    request.POST["budget_month"] = str(month_id)
    response = views.reports(request)
    return _finish_existing_view(request, response)


@api_login_required
@require_POST
def password_action(request):
    return _finish_existing_view(request, views.change_password_view(request))


@api_login_required
@require_GET
def admin_dashboard(request):
    if not request.user.is_staff:
        return _json({"error": "Administrator access required."}, 403)
    context = views._admin_dashboard_context()
    return _json({key: context[key] for key in (
        "total_users", "total_balances", "total_months", "total_categories",
        "total_expenses", "total_emails", "total_allocated", "total_direct_spent",
        "total_sub_balance_spent", "total_spent", "total_remaining",
    )} | {
        "recentUsers": [{"name": item.name, "email": item.email} for item in context["recent_users"]],
        "recentMonths": [{"name": item.name or item.month_label, "owner": item.user.name,
                          "monthLabel": item.month_label, "totalMoney": item.total_money}
                         for item in context["recent_months"]],
        "recentExpenses": [{"owner": item.budget_month.user.name,
                    "monthLabel": item.budget_month.month_label,
                    "date": item.expense_date,
                    "balance": item.sub_balance.name if item.sub_balance else "Main Balance direct",
                    "category": item.category.name, "amount": item.amount}
                   for item in context["recent_expenses"]],
        "recentEmails": [{"owner": item.budget_month.user.name,
                          "monthLabel": item.budget_month.month_label,
                          "reportType": item.get_report_type_display(), "sentAt": item.sent_at}
                         for item in context["recent_emails"]],
    })


@api_login_required
@require_GET
def admin_users(request):
    if not request.user.is_staff:
        return _json({"error": "Administrator access required."}, 403)
    context = views._admin_users_context()
    users = []
    for item in context["users"]:
        auth = item.auth_user
        users.append({"id": item.id, "name": item.name, "email": item.email,
                      "username": auth.username if auth else None,
                      "active": auth.is_active if auth else None,
                      "isStaff": auth.is_staff if auth else False,
                      "createdAt": item.created_at,
                      "balanceCount": item.num_balances, "monthCount": item.num_months})
    return _json({"users": users})


@api_login_required
@require_POST
def admin_users_action(request):
    if not request.user.is_staff:
        return _json({"error": "Administrator access required."}, 403)
    return _finish_existing_view(request, views.admin_users(request))
