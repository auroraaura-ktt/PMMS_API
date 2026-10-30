import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const PmmsApp());

const ink = Color(0xFF1F2937);
const navy = Color(0xFF17324D);
const teal = Color(0xFF0F766E);
const canvas = Color(0xFFF4F7FA);

class Api {
  Api() {
    client.withCredentials = true;
  }
  final BrowserClient client = BrowserClient();
  String? csrfToken;
  Uri uri(String path) => Uri.base.resolve(path);

  Future<Map<String, dynamic>> get(String path) async {
    final response = await client.get(uri(path), headers: {'Accept': 'application/json'});
    return _decode(response);
  }

  Future<Map<String, dynamic>> post(String path, Map<String, String> fields) async {
    if (csrfToken == null) {
      final seed = await client.get(uri('/api/v1/csrf/'));
      _decode(seed);
      csrfToken = (jsonDecode(seed.body) as Map<String, dynamic>)['csrfToken'] as String?;
    }
    final response = await client.post(uri(path),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
          if (csrfToken != null) 'X-CSRFToken': csrfToken!,
        },
        body: fields);
    final decoded = _decode(response);
    if (path == '/api/v1/auth/login/' || path == '/api/v1/auth/register/') {
      final refreshed = await client.get(uri('/api/v1/csrf/'));
      final csrf = _decode(refreshed);
      csrfToken = csrf['csrfToken'] as String?;
    }
    return decoded;
  }

  Map<String, dynamic> _decode(http.Response response) {
    final decoded = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (decoded is Map<String, dynamic> && response.statusCode < 400) return decoded;
    final detail = decoded is Map ? (decoded['errors'] ?? decoded['error'] ?? decoded['detail']) : null;
    throw ApiException(response.statusCode, detail?.toString() ?? 'Request failed (${response.statusCode}).');
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class PmmsApp extends StatefulWidget {
  const PmmsApp({super.key});
  @override
  State<PmmsApp> createState() => _PmmsAppState();
}

class _PmmsAppState extends State<PmmsApp> {
  final api = Api();
  Map<String, dynamic>? user;
  bool checking = true;
  @override
  void initState() {
    super.initState();
    api.get('/api/v1/auth/me/').then((value) {
      if (mounted) setState(() { user = value; checking = false; });
    }).catchError((_) {
      if (mounted) setState(() { checking = false; });
    });
  }

  void signedIn(Map<String, dynamic> value) => setState(() { user = value['user'] as Map<String, dynamic>?; });
  void signedOut() => setState(() { user = null; });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: "PMMS by K's",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: canvas,
          colorScheme: ColorScheme.fromSeed(seedColor: teal, primary: navy),
          appBarTheme: const AppBarTheme(backgroundColor: navy, foregroundColor: Colors.white),
          inputDecorationTheme: InputDecorationTheme(
            filled: true, fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        home: checking
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : user == null
                ? LoginScreen(api: api, onLogin: signedIn)
                : DashboardScreen(api: api, user: user!, onLogout: signedOut),
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, required this.onLogin});
  final Api api;
  final ValueChanged<Map<String, dynamic>> onLogin;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController();
  final password = TextEditingController();
  final email = TextEditingController();
  final confirm = TextEditingController();
  bool registering = false, busy = false;
  String? error;

  Future<void> submit() async {
    setState(() { busy = true; error = null; });
    try {
      final result = await widget.api.post(registering ? '/api/v1/auth/register/' : '/api/v1/auth/login/',
          registering
              ? {'username': username.text, 'email': email.text, 'password1': password.text, 'password2': confirm.text}
              : {'username': username.text, 'password': password.text});
      widget.onLogin(result);
    } catch (e) { setState(() { error = e.toString(); }); }
    if (mounted) setState(() { busy = false; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: Card(
          margin: const EdgeInsets.all(24), child: Padding(padding: const EdgeInsets.all(32), child: Column(
            mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Image.asset('assets/pmms-logo.jpg', height: 88, errorBuilder: (_, __, ___) => const Icon(Icons.account_balance_wallet, size: 64, color: teal)),
              const SizedBox(height: 16), Text(registering ? 'Create your account' : 'Welcome back', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: navy, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TextField(controller: username, decoration: const InputDecoration(labelText: 'Username')),
              if (registering) ...[const SizedBox(height: 12), TextField(controller: email, decoration: const InputDecoration(labelText: 'Email'))],
              const SizedBox(height: 12), TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
              if (registering) ...[const SizedBox(height: 12), TextField(controller: confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password'))],
              if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
              const SizedBox(height: 20), FilledButton(onPressed: busy ? null : submit, child: Text(busy ? 'Please wait…' : registering ? 'Create account' : 'Sign in')),
              TextButton(onPressed: () => setState(() { registering = !registering; error = null; }), child: Text(registering ? 'Already registered? Sign in' : 'Create an account')),
            ],
          )),
        ))),
      );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.api, required this.user, required this.onLogout});
  final Api api;
  final Map<String, dynamic> user;
  final VoidCallback onLogout;
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<Map<String, dynamic>> future;
  List<Map<String, dynamic>> balances = [];
  @override
  void initState() { super.initState(); future = widget.api.get('/api/v1/dashboard/'); }
  void reload() => setState(() { future = widget.api.get('/api/v1/dashboard/'); });

  Future<void> logout() async {
    try { await widget.api.post('/api/v1/auth/logout/', {}); } finally { widget.onLogout(); }
  }

  Future<void> createMonth() async {
    final values = await showDialog<Map<String, String>>(context: context, builder: (_) => CreateMonthDialog(balances: balances));
    if (values == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {'action': 'create_budget', ...values});
      reload();
    } catch (e) { _message(e.toString()); }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("PMMS by K's"), actions: [
      PopupMenuButton<String>(onSelected: (value) {
        if (value == 'logout') logout();
        if (value == 'password') Navigator.push(context, MaterialPageRoute(builder: (_) => PasswordScreen(api: widget.api)));
        if (value == 'admin') Navigator.push(context, MaterialPageRoute(builder: (_) => AdminScreen(api: widget.api)));
      }, itemBuilder: (_) => [
        const PopupMenuItem(value: 'password', child: Text('Change password')),
        if (widget.user['isStaff'] == true) const PopupMenuItem(value: 'admin', child: Text('Admin tools')),
        const PopupMenuItem(value: 'logout', child: Text('Sign out')),
      ]),
    ]),
    floatingActionButton: FloatingActionButton.extended(onPressed: createMonth, icon: const Icon(Icons.add), label: const Text('Main Balance')),
    body: FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return ErrorPanel(message: snapshot.error.toString(), onRetry: reload);
      final data = snapshot.data!;
      final months = (data['months'] as List? ?? []).cast<Map<String, dynamic>>();
      balances = (data['balances'] as List? ?? []).cast<Map<String, dynamic>>();
      return RefreshIndicator(onRefresh: () async => reload(), child: ListView(padding: const EdgeInsets.all(20), children: [
        Text('Hello, ${data['user']?['name'] ?? widget.user['username']}', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: navy, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6), Text('Your monthly money overview', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.blueGrey)),
        const SizedBox(height: 20), Wrap(spacing: 12, runSpacing: 12, children: [
          SummaryTile(label: 'Main Balances', value: '${months.length}', icon: Icons.account_balance_wallet_outlined),
          SummaryTile(label: 'Wallet groups', value: '${balances.length}', icon: Icons.wallet_outlined),
        ]),
        const SizedBox(height: 20), Text('Main Balances', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        if (months.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('No monthly balances yet. Create one to get started.'))),
        ...months.map((month) => MonthCard(month: month, api: widget.api, onChanged: reload)),
        const SizedBox(height: 80),
      ]));
    }),
  );
}

class MonthCard extends StatelessWidget {
  const MonthCard({super.key, required this.month, required this.api, required this.onChanged});
  final Map<String, dynamic> month;
  final Api api;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    final report = (month['report'] as Map?)?.cast<String, dynamic>() ?? {};
    return Card(child: InkWell(borderRadius: BorderRadius.circular(16), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MonthScreen(id: month['id'] as int, api: api))).then((_) => onChanged()),
      child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(month['name']?.toString() ?? 'Main Balance', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))), const Icon(Icons.chevron_right)]),
        const SizedBox(height: 10), Text('${month['monthLabel']}  ·  ${month['balance'] ?? 'Wallet'}'),
        const SizedBox(height: 14), Wrap(spacing: 22, runSpacing: 8, children: [
          Metric(label: 'Available', value: _money(report['remaining_balance'] ?? month['totalMoney'])),
          Metric(label: 'Spent', value: _money(report['combined_actual_spent'])),
          Metric(label: 'Total', value: _money(month['totalMoney'])),
        ]),
      ])),
    ));
  }
}

class MonthScreen extends StatefulWidget {
  const MonthScreen({super.key, required this.id, required this.api});
  final int id;
  final Api api;
  @override
  State<MonthScreen> createState() => _MonthScreenState();
}

class _MonthScreenState extends State<MonthScreen> {
  late Future<Map<String, dynamic>> future;
  @override
  void initState() { super.initState(); future = widget.api.get('/api/v1/main-balances/${widget.id}/'); }
  void reload() => setState(() { future = widget.api.get('/api/v1/main-balances/${widget.id}/'); });
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Main Balance')), body: FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
    if (snapshot.hasError) return ErrorPanel(message: snapshot.error.toString(), onRetry: reload);
    final data = snapshot.data!;
    final report = (data['report'] as Map).cast<String, dynamic>();
    final subs = (data['subBalances'] as List).cast<Map<String, dynamic>>();
    final categories = (data['categories'] as List).cast<Map<String, dynamic>>();
    final expenses = (data['expenses'] as List).cast<Map<String, dynamic>>();
    return RefreshIndicator(onRefresh: () async => reload(), child: ListView(padding: const EdgeInsets.all(18), children: [
      Text(data['name'].toString(), style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: navy, fontWeight: FontWeight.bold)),
      Text(data['monthLabel'].toString()),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [
        FilledButton.tonalIcon(onPressed: () => _addExpense(data, categories), icon: const Icon(Icons.add_card), label: const Text('Record expense')),
        OutlinedButton.icon(onPressed: () => _addCategoryBudget(data['id'] as int), icon: const Icon(Icons.category_outlined), label: const Text('Add custom category')),
        OutlinedButton.icon(onPressed: () => _sendReport(data['id'] as int), icon: const Icon(Icons.email_outlined), label: const Text('Email report')),
        OutlinedButton.icon(onPressed: () => _addSubBalance(data), icon: const Icon(Icons.savings_outlined), label: const Text('Add Sub Balance')),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        SummaryTile(label: 'Main Balance', value: _money(report['total_money']), icon: Icons.account_balance),
        SummaryTile(label: 'Main remaining', value: _money(report['remaining_balance']), icon: Icons.savings_outlined),
        SummaryTile(label: 'Spent total', value: _money(report['combined_actual_spent']), icon: Icons.payments_outlined),
      ]),
      SectionTitle('Sub Balances'),
      if (subs.isEmpty) const Text('No Sub Balances'),
      ...subs.map((sub) => ListTile(tileColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), title: Text(sub['name'].toString()), subtitle: Text('Opening amount ${_money(sub['balance_amount'])}'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SubScreen(id: sub['id'] as int, api: widget.api))).then((_) => reload()))),
      SectionTitle('Budget categories'),
      ...categories.where((c) => c['sub_balance_id'] == null).map((c) => ListTile(title: Text(c['name'].toString()), trailing: TextButton(onPressed: () => _updateCategory(c), child: Text('${_money(c['estimated_amount'])} MMK')))),
      SectionTitle('Recent expenses'),
      if (expenses.isEmpty) const Text('No recorded expenses'),
      ...expenses.take(30).map((e) => ListTile(title: Text(e['category__name']?.toString() ?? 'Expense'), subtitle: Text('${e['expense_date']} · ${e['note'] ?? ''}'), trailing: Text('${_money(e['amount'])} MMK'))),
      SectionTitle('Monthly report'),
      ...(report['period_reports'] as List).map((p) => ListTile(title: Text(p['category_name'].toString()), subtitle: Text(p['status'].toString()), trailing: Text('${_money(p['actual_amount'])} / ${_money(p['budget_amount'])}'))),
    ]));
  }));

  Future<void> _addExpense(Map<String, dynamic> month, List<Map<String, dynamic>> allCategories) async {
    final fields = await showDialog<Map<String, String>>(context: context, builder: (_) => ExpenseDialog(
      monthId: widget.id,
      year: month['year'] as int,
      month: month['month'] as int,
      categories: allCategories.where((c) => c['sub_balance_id'] == null).toList(),
    ));
    if (fields == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {'action': 'add_expense', 'expense_type': 'main', ...fields});
      reload();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _addCategoryBudget(int monthId) async {
    final fields = await showDialog<Map<String, String>>(context: context, builder: (_) => const CategoryBudgetDialog());
    if (fields == null) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {'action': 'save_custom_category_budget', 'budget_month': '$monthId', ...fields});
      reload();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _updateCategory(Map<String, dynamic> category) async {
    final amount = TextEditingController(text: category['estimated_amount'].toString());
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text('Update ${category['name']} budget'),
      content: TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Estimated amount (MMK)')),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))],
    ));
    if (accepted != true) return;
    try {
      await widget.api.post('/api/v1/dashboard/actions/', {'action': 'update_category_budget', 'category_id': '${category['id']}', 'estimated_amount': amount.text});
      reload();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _sendReport(int monthId) async {
    try {
      await widget.api.post('/api/v1/main-balances/$monthId/report/actions/', {'action': 'email'});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report email request processed.')));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }

  Future<void> _addSubBalance(Map<String, dynamic> month) async {
    final values = await showDialog<Map<String, String>>(context: context, builder: (_) => SubBalanceDialog(year: month['year'] as int, month: month['month'] as int));
    if (values == null) return;
    try {
      await widget.api.post('/api/v1/main-balances/${widget.id}/actions/', {'action': 'create_sub_balance', ...values});
      reload();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
  }
}

class SubScreen extends StatefulWidget {
  const SubScreen({super.key, required this.id, required this.api});
  final int id;
  final Api api;
  @override
  State<SubScreen> createState() => _SubScreenState();
}

class _SubScreenState extends State<SubScreen> {
  late Future<Map<String, dynamic>> future;
  @override
  void initState() { super.initState(); future = widget.api.get('/api/v1/sub-balances/${widget.id}/'); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Sub Balance')), body: FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) {
    if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
    if (snapshot.hasError) return ErrorPanel(message: snapshot.error.toString(), onRetry: () => setState(() { future = widget.api.get('/api/v1/sub-balances/${widget.id}/'); }));
    final data = snapshot.data!;
    final categories = (data['categories'] as List).cast<Map<String, dynamic>>();
    final expenses = (data['expenses'] as List).cast<Map<String, dynamic>>();
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text(data['name'].toString(), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: navy)),
      Text(data['monthLabel'].toString()),
      const SizedBox(height: 16), Wrap(spacing: 12, runSpacing: 12, children: [
        SummaryTile(label: 'Allocated', value: _money(data['allocatedAmount']), icon: Icons.account_balance_wallet_outlined),
        SummaryTile(label: 'Spent', value: _money(data['totalActualSpent']), icon: Icons.payments_outlined),
        SummaryTile(label: 'Remaining', value: _money(data['remainingBalance']), icon: Icons.savings_outlined),
      ]),
      SectionTitle('Categories'),
      ...categories.map((item) => ListTile(title: Text(item['name'].toString()), trailing: Text('${_money(item['estimated_amount'])} MMK'))),
      SectionTitle('Transactions'),
      ...expenses.map((item) => ListTile(title: Text(item['category__name'].toString()), subtitle: Text('${item['expense_date']} · ${item['note'] ?? ''}'), trailing: Text('${_money(item['amount'])} MMK'))),
    ]);
  }));
}

class CreateMonthDialog extends StatefulWidget {
  const CreateMonthDialog({super.key, required this.balances});
  final List<Map<String, dynamic>> balances;
  @override
  State<CreateMonthDialog> createState() => _CreateMonthDialogState();
}

class _CreateMonthDialogState extends State<CreateMonthDialog> {
  final name = TextEditingController();
  final amount = TextEditingController();
  final year = TextEditingController(text: DateTime.now().year.toString());
  final month = TextEditingController(text: DateTime.now().month.toString());
  String? selectedBalance;
  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Create Main Balance'), content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
    TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
    DropdownButtonFormField<String>(initialValue: selectedBalance ?? (widget.balances.isEmpty ? null : widget.balances.first['id'].toString()), decoration: const InputDecoration(labelText: 'Wallet group'), items: widget.balances.map((b) => DropdownMenuItem(value: b['id'].toString(), child: Text(b['name'].toString()))).toList(), onChanged: (value) => setState(() { selectedBalance = value; })),
    TextField(controller: year, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Year')),
    TextField(controller: month, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Month (1–12)')),
    TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Total money (MMK)')),
  ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, {'name': name.text, 'balance': selectedBalance ?? (widget.balances.isEmpty ? '' : widget.balances.first['id'].toString()), 'year': year.text, 'month': month.text, 'total_money': amount.text}), child: const Text('Create'))]);
}

class ExpenseDialog extends StatefulWidget {
  const ExpenseDialog({super.key, required this.monthId, required this.year, required this.month, required this.categories});
  final int monthId, year, month;
  final List<Map<String, dynamic>> categories;
  @override
  State<ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<ExpenseDialog> {
  final amount = TextEditingController(), note = TextEditingController();
  late DateTime date = DateTime(widget.year, widget.month, 1);
  String? categoryId;
  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Record expense'), content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
    DropdownButtonFormField<String>(initialValue: categoryId, decoration: const InputDecoration(labelText: 'Category'), items: widget.categories.map((c) => DropdownMenuItem(value: c['id'].toString(), child: Text(c['name'].toString()))).toList(), onChanged: (v) => setState(() { categoryId = v; })),
    TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (MMK)')),
    TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
    TextButton.icon(onPressed: () async { final picked = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(widget.year, widget.month, 1), lastDate: DateTime(widget.year, widget.month + 1, 0)); if (picked != null) setState(() { date = picked; }); }, icon: const Icon(Icons.calendar_month), label: Text('${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}')),
  ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () { if (categoryId == null) return; Navigator.pop(context, {'budget_month': '${widget.monthId}', 'category': categoryId!, 'expense_date': '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}', 'amount': amount.text, 'note': note.text}); }, child: const Text('Save'))]);
}

class CategoryBudgetDialog extends StatefulWidget {
  const CategoryBudgetDialog({super.key});
  @override
  State<CategoryBudgetDialog> createState() => _CategoryBudgetDialogState();
}

class SubBalanceDialog extends StatefulWidget {
  const SubBalanceDialog({super.key, required this.year, required this.month});
  final int year, month;
  @override
  State<SubBalanceDialog> createState() => _SubBalanceDialogState();
}

class _SubBalanceDialogState extends State<SubBalanceDialog> {
  final name = TextEditingController(), amount = TextEditingController(text: '0');
  late DateTime date = DateTime(widget.year, widget.month, 1);
  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Create Sub Balance'), content: Column(mainAxisSize: MainAxisSize.min, children: [
    TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
    TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Opening amount (MMK)')),
    TextButton.icon(onPressed: () async { final picked = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(widget.year, widget.month, 1), lastDate: DateTime(widget.year, widget.month + 1, 0)); if (picked != null) setState(() { date = picked; }); }, icon: const Icon(Icons.calendar_month), label: Text('${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}')),
  ]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, {'name': name.text, 'balance_amount': amount.text, 'balance_date': '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'}), child: const Text('Create'))]);
}

class PasswordScreen extends StatefulWidget {
  const PasswordScreen({super.key, required this.api});
  final Api api;
  @override
  State<PasswordScreen> createState() => _PasswordScreenState();
}

class _PasswordScreenState extends State<PasswordScreen> {
  final old = TextEditingController(), next = TextEditingController(), confirm = TextEditingController();
  String? message;
  bool busy = false;
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Change password')), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: Card(margin: const EdgeInsets.all(20), child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
    TextField(controller: old, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
    const SizedBox(height: 12), TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
    const SizedBox(height: 12), TextField(controller: confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm new password')),
    if (message != null) Padding(padding: const EdgeInsets.all(12), child: Text(message!)),
    const SizedBox(height: 12), FilledButton(onPressed: busy ? null : () async {
      setState(() { busy = true; message = null; });
      try { await widget.api.post('/api/v1/profile/password/', {'old_password': old.text, 'new_password1': next.text, 'new_password2': confirm.text}); setState(() { message = 'Password changed.'; }); }
      catch (e) { setState(() { message = e.toString(); }); }
      setState(() { busy = false; });
    }, child: Text(busy ? 'Saving…' : 'Update password')),
  ])))));
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.api});
  final Api api;
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<Map<String, dynamic>> dashboard;
  late Future<Map<String, dynamic>> users;
  @override
  void initState() { super.initState(); _load(); }
  void _load() { dashboard = widget.api.get('/api/v1/admin/dashboard/'); users = widget.api.get('/api/v1/admin/users/'); }
  void reload() => setState(_load);
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Admin tools')), body: RefreshIndicator(onRefresh: () async => reload(), child: ListView(padding: const EdgeInsets.all(18), children: [
    FutureBuilder<Map<String, dynamic>>(future: dashboard, builder: (context, s) {
      if (s.connectionState == ConnectionState.waiting) return const LinearProgressIndicator();
      if (s.hasError) return ErrorPanel(message: s.error.toString(), onRetry: reload);
      final d = s.data!;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        SummaryTile(label: 'Users', value: '${d['total_users']}', icon: Icons.people_outline),
        SummaryTile(label: 'Main Balances', value: '${d['total_months']}', icon: Icons.account_balance_wallet_outlined),
        SummaryTile(label: 'Expenses', value: '${d['total_expenses']}', icon: Icons.receipt_long_outlined),
        SummaryTile(label: 'Allocated', value: _money(d['total_allocated']), icon: Icons.payments_outlined),
        SummaryTile(label: 'Spent', value: _money(d['total_spent']), icon: Icons.shopping_cart_outlined),
        SummaryTile(label: 'Remaining', value: _money(d['total_remaining']), icon: Icons.savings_outlined),
      ]);
    }),
    const SectionTitle('User accounts'),
    FutureBuilder<Map<String, dynamic>>(future: users, builder: (context, s) {
      if (s.connectionState == ConnectionState.waiting) return const LinearProgressIndicator();
      if (s.hasError) return ErrorPanel(message: s.error.toString(), onRetry: reload);
      final rows = (s.data!['users'] as List).cast<Map<String, dynamic>>();
      return Column(children: rows.map((u) => Card(child: ListTile(title: Text(u['name'].toString()), subtitle: Text('${u['email']} · ${u['username'] ?? 'No login'} · ${u['active'] == true ? 'Active' : 'Disabled'}'), trailing: PopupMenuButton<String>(onSelected: (action) async {
        if (action == 'delete_user' && !await _confirmDelete(context, u['name'].toString())) return;
        Map<String, String> fields = {'action': action, 'user_id': '${u['id']}'};
        if (action == 'reset_password') {
          fields['user'] = '${u['id']}';
          final pw = await _passwordDialog(context);
          if (pw == null) return;
          fields.addAll(pw);
        }
        try { await widget.api.post('/api/v1/admin/users/actions/', fields); reload(); }
        catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); }
      }, itemBuilder: (_) => [
        if (u['username'] != null) PopupMenuItem(value: 'toggle_active', child: Text(u['active'] == true ? 'Disable account' : 'Activate account')),
        if (u['username'] != null) const PopupMenuItem(value: 'reset_password', child: Text('Reset password')),
        const PopupMenuItem(value: 'delete_user', child: Text('Delete user')),
      ])))).toList());
    }),
  ])));

  Future<bool> _confirmDelete(BuildContext context, String name) async => await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('Delete user?'), content: Text('Delete $name and all associated data?'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete'))])) ?? false;

  Future<Map<String, String>?> _passwordDialog(BuildContext context) async {
    final first = TextEditingController(), second = TextEditingController();
    return showDialog<Map<String, String>>(context: context, builder: (context) => AlertDialog(title: const Text('Reset password'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: first, obscureText: true, decoration: const InputDecoration(labelText: 'New password')), TextField(controller: second, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password'))]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, {'password1': first.text, 'password2': second.text}), child: const Text('Reset'))]));
  }
}

class _CategoryBudgetDialogState extends State<CategoryBudgetDialog> {
  final name = TextEditingController(), amount = TextEditingController();
  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Add custom category'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: name, decoration: const InputDecoration(labelText: 'Category name')), TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Budget amount (MMK)'))]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, {'new_category_name': name.text, 'estimated_amount': amount.text}), child: const Text('Add'))]);
}

class SummaryTile extends StatelessWidget {
  const SummaryTile({super.key, required this.label, required this.value, required this.icon});
  final String label, value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => SizedBox(width: 220, child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [Icon(icon, color: teal), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.blueGrey)), const SizedBox(height: 5), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, color: ink))]))]))));
}

class Metric extends StatelessWidget {
  const Metric({super.key, required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.blueGrey, fontSize: 12)), Text(value, style: const TextStyle(fontWeight: FontWeight.w600, color: ink))]);
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 8), child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: navy)));
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.cloud_off, size: 44, color: Colors.blueGrey), const SizedBox(height: 12), Text(message, textAlign: TextAlign.center), const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Try again'))])));
}

String _money(dynamic value) {
  if (value == null) return '0';
  final number = num.tryParse(value.toString()) ?? 0;
  final raw = number.abs().round().toString();
  final grouped = raw.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${number < 0 ? '-' : ''}$grouped';
}
