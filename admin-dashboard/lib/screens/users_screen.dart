import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/api_service.dart';

class UsersScreen extends StatefulWidget {
  final String token;
  UsersScreen({required this.token});

  @override
  _UsersScreenState createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<UserModel> users = [];
  bool loading = true;
  String? error;

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      users = await ApiService.getUsers(widget.token);
    } catch (err) {
      error = 'Unable to load users';
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _createUser() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    if (name.isEmpty || email.isEmpty || password.isEmpty) return;

    await ApiService.createUser(widget.token, name, email, password);
    _nameController.clear();
    _emailController.clear();
    _passwordController.clear();
    _loadUsers();
  }

  void _showEditDialog(UserModel user) {
    final editName = TextEditingController(text: user.name);
    final editEmail = TextEditingController(text: user.email);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Edit Salesperson'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: editName, decoration: InputDecoration(labelText: 'Name')),
              TextField(controller: editEmail, decoration: InputDecoration(labelText: 'Email')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                await ApiService.updateUser(widget.token, user.id, editName.text.trim(), editEmail.text.trim());
                Navigator.of(context).pop();
                _loadUsers();
              },
              child: Text('Save'),
            )
          ],
        );
      },
    );
  }

  Widget _buildUserRow(UserModel user) {
    return ListTile(
      title: Text(user.name),
      subtitle: Text(user.email),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.edit),
            onPressed: () => _showEditDialog(user),
          ),
          IconButton(
            icon: Icon(Icons.delete),
            onPressed: () async {
              await ApiService.deleteUser(widget.token, user.id);
              _loadUsers();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;
        final formSection = Card(
          elevation: 2,
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Create Salesperson', style: Theme.of(context).textTheme.titleLarge),
                SizedBox(height: 16),
                TextField(controller: _nameController, decoration: InputDecoration(labelText: 'Name')),
                SizedBox(height: 12),
                TextField(controller: _emailController, decoration: InputDecoration(labelText: 'Email')),
                SizedBox(height: 12),
                TextField(controller: _passwordController, decoration: InputDecoration(labelText: 'Password'), obscureText: true),
                SizedBox(height: 16),
                ElevatedButton(onPressed: _createUser, child: Text('Create User')),
              ],
            ),
          ),
        );

        final listSection = Expanded(
          child: Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: loading
                  ? Center(child: CircularProgressIndicator())
                  : error != null
                      ? Center(child: Text(error!, style: TextStyle(color: Colors.red)))
                      : ListView.builder(
                          itemCount: users.length,
                          itemBuilder: (_, index) => _buildUserRow(users[index]),
                        ),
            ),
          ),
        );

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(flex: 1, child: formSection),
                    SizedBox(width: 24),
                    Flexible(flex: 2, child: listSection),
                  ],
                )
              : Column(
                  children: [
                    formSection,
                    listSection,
                  ],
                ),
        );
      },
    );
  }
}
