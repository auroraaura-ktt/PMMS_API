"""URL routes for the budget app."""

from django.urls import path

from budget import views
from budget import api

app_name = "budget"

urlpatterns = [
    path("api/v1/csrf/", api.csrf, name="api_csrf"),
    path("api/v1/auth/login/", api.login_api, name="api_login"),
    path("api/v1/auth/register/", api.register_api, name="api_register"),
    path("api/v1/auth/logout/", api.logout_api, name="api_logout"),
    path("api/v1/auth/me/", api.me, name="api_me"),
    path("api/v1/profile/password/", api.password_action, name="api_password_action"),
    path("api/v1/admin/dashboard/", api.admin_dashboard, name="api_admin_dashboard"),
    path("api/v1/admin/users/", api.admin_users, name="api_admin_users"),
    path("api/v1/admin/users/actions/", api.admin_users_action, name="api_admin_users_action"),
    path("api/v1/dashboard/", api.dashboard, name="api_dashboard"),
    path("api/v1/dashboard/actions/", api.dashboard_action, name="api_dashboard_action"),
    path("api/v1/main-balances/<int:month_id>/", api.month_detail, name="api_month_detail"),
    path("api/v1/main-balances/<int:month_id>/actions/", api.main_balance_action, name="api_main_balance_action"),
    path("api/v1/main-balances/<int:month_id>/report/", api.report, name="api_report"),
    path("api/v1/main-balances/<int:month_id>/report/actions/", api.report_action, name="api_report_action"),
    path("api/v1/sub-balances/<int:sub_balance_id>/", api.sub_balance_detail, name="api_sub_balance_detail"),
    path("api/v1/sub-balances/<int:sub_balance_id>/actions/", api.sub_balance_action, name="api_sub_balance_action"),
    path("", views.home, name="home"),
    path("dashboard/", views.dashboard, name="dashboard"),
    path("reports/", views.reports, name="reports"),
    path(
        "main-balances/<int:month_id>/",
        views.main_balance_detail,
        name="main_balance_detail",
    ),
    path(
        "main-balances/<int:month_id>/edit/",
        views.edit_main_balance,
        name="edit_main_balance",
    ),
    path(
        "main-balances/<int:month_id>/delete/",
        views.delete_main_balance,
        name="delete_main_balance",
    ),
    path(
        "main-balances/<int:month_id>/sub-balances/add/",
        views.create_sub_balance,
        name="create_sub_balance",
    ),
    path(
        "sub-balances/<int:sub_balance_id>/",
        views.sub_balance_detail,
        name="sub_balance_detail",
    ),
    path(
        "sub-balances/<int:sub_balance_id>/edit/",
        views.edit_sub_balance,
        name="edit_sub_balance",
    ),
    path(
        "sub-balances/<int:sub_balance_id>/delete/",
        views.delete_sub_balance,
        name="delete_sub_balance",
    ),
    path(
        "sub-balances/<int:sub_balance_id>/finish/",
        views.finish_sub_balance,
        name="finish_sub_balance",
    ),
    path("register/", views.register_view, name="register"),
    path("login/", views.login_view, name="login"),
    path("admin-login/", views.admin_login_view, name="admin_login"),
    path("admin-dashboard/", views.admin_dashboard, name="admin_dashboard"),
    path("admin-users/", views.admin_users, name="admin_users"),
    path("change-password/", views.change_password_view, name="change_password"),
    path("logout/", views.logout_view, name="logout"),
    path(
        "api/categories/<int:month_id>/",
        views.categories_for_month,
        name="categories_for_month",
    ),
]
