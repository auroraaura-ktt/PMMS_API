from decimal import Decimal

from django.contrib.auth.models import User
from django.test import Client, TestCase
from django.urls import reverse

from budget.models import Balance, BudgetCategory, BudgetMonth, DailyExpense, PocketUser, SubBalance


class FlutterSessionApiTests(TestCase):
    def setUp(self):
        self.client = Client(enforce_csrf_checks=True)
        self.user = User.objects.create_user(
            username="api-user", email="api@example.com", password="SafePass!284"
        )
        self.pocket = PocketUser.objects.create(
            name="API User", email="api@example.com", auth_user=self.user
        )
        self.balance = Balance.objects.create(user=self.pocket, name="Main Wallet")

    def csrf(self):
        response = self.client.get(reverse("budget:api_csrf"))
        self.assertEqual(response.status_code, 200)
        return response.json()["csrfToken"]

    def login(self):
        token = self.csrf()
        response = self.client.post(
            reverse("budget:api_login"),
            {"username": "api-user", "password": "SafePass!284"},
            HTTP_X_CSRFTOKEN=token,
        )
        self.assertEqual(response.status_code, 200)
        return self.csrf()

    def test_authentication_failure_is_json_401(self):
        response = self.client.get(reverse("budget:api_dashboard"))
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.json()["error"], "Authentication required.")

    def test_login_and_dashboard_use_session_authentication(self):
        self.login()
        response = self.client.get(reverse("budget:api_dashboard"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["user"]["name"], "API User")
        self.assertEqual(response.json()["balances"][0]["name"], "Main Wallet")

    def test_other_users_month_is_not_accessible(self):
        self.login()
        another = PocketUser.objects.create(name="Other", email="other@example.com")
        month = BudgetMonth.objects.create(
            user=another, year=2026, month=8, total_money=Decimal("10000")
        )
        response = self.client.get(
            reverse("budget:api_month_detail", args=[month.id])
        )
        self.assertEqual(response.status_code, 404)

    def test_sub_balance_detail_includes_existing_report_and_transaction_data(self):
        token = self.login()
        month = BudgetMonth.objects.create(
            user=self.pocket, balance=self.balance, year=2026, month=8,
            total_money=Decimal("50000"),
        )
        sub = SubBalance.objects.create(
            budget_month=month, name="Savings", balance_amount=Decimal("10000"),
            balance_date="2026-08-01",
        )
        category = BudgetCategory.objects.create(
            budget_month=month, sub_balance=sub, name="Food", estimated_amount=Decimal("0"),
        )
        expense = DailyExpense.objects.create(
            budget_month=month, sub_balance=sub, category=category,
            expense_date="2026-08-02", amount=Decimal("2500"),
        )
        response = self.client.get(reverse("budget:api_sub_balance_detail", args=[sub.id]))
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["allocatedAmount"], "10000")
        self.assertIn("reportDueDate", payload)
        self.assertIn("scheduledSent", payload)
        self.assertEqual(payload["categories"][0]["actual_amount"], "2500")
        self.assertEqual(payload["expenses"][0]["category_id"], category.id)

    def test_dashboard_mutation_requires_csrf_and_uses_existing_view_validation(self):
        token = self.login()
        data = {
            "action": "create_budget",
            "name": "August 2026",
            "balance": str(self.balance.id),
            "year": "2026",
            "month": "8",
            "total_money": "50000",
        }
        no_csrf = self.client.post(reverse("budget:api_dashboard_action"), data)
        self.assertEqual(no_csrf.status_code, 403)
        response = self.client.post(
            reverse("budget:api_dashboard_action"), data, HTTP_X_CSRFTOKEN=token
        )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])
        self.assertTrue(
            BudgetMonth.objects.filter(user=self.pocket, year=2026, month=8).exists()
        )

    def test_invalid_dashboard_form_is_not_reported_as_success(self):
        token = self.login()
        response = self.client.post(
            reverse("budget:api_dashboard_action"),
            {
                "action": "create_budget",
                "name": "Invalid month",
                "balance": str(self.balance.id),
                "year": "2026",
                "month": "8",
                "total_money": "0",
            },
            HTTP_X_CSRFTOKEN=token,
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(response.json()["ok"])
        self.assertIn("errors", response.json())
        self.assertTrue(response.json()["errors"]["budget_form"]["total_money"])
        self.assertFalse(BudgetMonth.objects.filter(user=self.pocket).exists())

    def test_admin_api_requires_staff_and_returns_existing_dashboard_summary(self):
        self.login()
        forbidden = self.client.get(reverse("budget:api_admin_dashboard"))
        self.assertEqual(forbidden.status_code, 403)

        staff = User.objects.create_user(
            username="staff", email="staff@example.com", password="SafePass!284",
            is_staff=True,
        )
        PocketUser.objects.create(name="Staff", email="staff@example.com", auth_user=staff)
        token = self.csrf()
        response = self.client.post(
            reverse("budget:api_logout"), {}, HTTP_X_CSRFTOKEN=token
        )
        self.assertEqual(response.status_code, 200)
        token = self.csrf()
        login_response = self.client.post(
            reverse("budget:api_login"),
            {"username": "staff", "password": "SafePass!284"},
            HTTP_X_CSRFTOKEN=token,
        )
        self.assertEqual(login_response.status_code, 200)
        response = self.client.get(reverse("budget:api_admin_dashboard"))
        self.assertEqual(response.status_code, 200)
        self.assertIn("total_users", response.json())
        self.assertIn("recentExpenses", response.json())
        users_response = self.client.get(reverse("budget:api_admin_users"))
        self.assertEqual(users_response.status_code, 200)
        self.assertEqual(len(users_response.json()["users"]), 2)
