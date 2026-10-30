from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("budget", "0013_subbalance_balance_date"),
    ]

    operations = [
        migrations.RemoveConstraint(
            model_name="budgetcategory",
            name="uq_month_category_name",
        ),
        migrations.AddConstraint(
            model_name="budgetcategory",
            constraint=models.UniqueConstraint(
                condition=models.Q(("sub_balance__isnull", True)),
                fields=("budget_month", "name"),
                name="uq_main_balance_category_name",
            ),
        ),
    ]
