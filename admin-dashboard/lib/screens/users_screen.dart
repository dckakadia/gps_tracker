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
  bool _showCreatePassword = false;
  String _selectedRole = 'salesperson';

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  final List<String> roles = ['admin', 'manager', 'viewer', 'salesperson'];

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

    try {
      await ApiService.createUser(widget.token, name, email, password, _selectedRole);
      _nameController.clear();
      _emailController.clear();
      _passwordController.clear();
      setState(() => _selectedRole = 'salesperson');
      _loadUsers();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('User created successfully')));
    } catch (err) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error creating user'), backgroundColor: Colors.red));
    }
  }

  void _showEditDialog(UserModel user) {
    final editName = TextEditingController(text: user.name);
    final editEmail = TextEditingController(text: user.email);
    final editPassword = TextEditingController();
    String selectedRole = user.role;
    bool showPassword = false;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Edit User: ${user.name}'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: editName,
                      decoration: InputDecoration(labelText: 'Name'),
                    ),
                    SizedBox(height: 12),
                    TextField(
                      controller: editEmail,
                      decoration: InputDecoration(labelText: 'Email'),
                    ),
                    SizedBox(height: 12),
                    TextField(
                      controller: editPassword,
                      decoration: InputDecoration(
                        labelText: 'New password (leave blank to keep current)',
                        hintText: 'Leave blank to keep current password',
                        suffixIcon: IconButton(
                          icon: Icon(showPassword ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => showPassword = !showPassword),
                        ),
                      ),
                      obscureText: !showPassword,
                    ),
                    SizedBox(height: 16),
                    Text('User Role', style: TextStyle(fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: DropdownButton<String>(
                        value: selectedRole,
                        isExpanded: true,
                        underline: SizedBox(),
                        items: roles.map((role) {
                          return DropdownMenuItem(
                            value: role,
                            child: Text(role.toUpperCase()),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => selectedRole = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    try {
                      await ApiService.updateUser(
                        widget.token,
                        user.id,
                        editName.text.trim(),
                        editEmail.text.trim(),
                        editPassword.text.trim().isEmpty ? null : editPassword.text.trim(),
                        selectedRole,
                      );
                      Navigator.of(context).pop();
                      _loadUsers();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('User updated successfully')));
                    } catch (err) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error updating user'), backgroundColor: Colors.red));
                    }
                  },
                  child: Text('Save'),
                )
              ],
            );
          },
        );
      },
    );
  }

  void _showDeleteDialog(UserModel user) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete User'),
          content: Text('Are you sure you want to delete ${user.name}? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  await ApiService.deleteUser(widget.token, user.id);
                  Navigator.of(context).pop();
                  _loadUsers();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('User deleted successfully')));
                } catch (err) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting user'), backgroundColor: Colors.red));
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: Text('Delete', style: TextStyle(color: Colors.white)),
            )
          ],
        );
      },
    );
  }

  Widget _buildUserRow(UserModel user) {
    Color roleColor = Colors.blue;
    if (user.role == 'admin') roleColor = Colors.red;
    if (user.role == 'manager') roleColor = Colors.orange;
    if (user.role == 'viewer') roleColor = Colors.purple;

    return Card(
      elevation: 1,
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(user.name, style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(user.email),
        leading: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: roleColor, borderRadius: BorderRadius.circular(4)),
          child: Text(
            user.role.toUpperCase(),
            style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'View User',
              child: IconButton(
                icon: Icon(Icons.visibility, color: Colors.blue),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: Text('User Details'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('ID: ${user.id}'),
                            SizedBox(height: 8),
                            Text('Name: ${user.name}'),
                            SizedBox(height: 8),
                            Text('Email: ${user.email}'),
                            SizedBox(height: 8),
                            Text('Role: ${user.role.toUpperCase()}'),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text('Close'),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
            Tooltip(
              message: 'Edit User',
              child: IconButton(
                icon: Icon(Icons.edit, color: Colors.orange),
                onPressed: () => _showEditDialog(user),
              ),
            ),
            Tooltip(
              message: 'Delete User',
              child: IconButton(
                icon: Icon(Icons.delete, color: Colors.red),
                onPressed: () => _showDeleteDialog(user),
              ),
            ),
          ],
        ),
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
                Text('Create New User', style: Theme.of(context).textTheme.titleLarge),
                SizedBox(height: 16),
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: _emailController,
                  decoration: InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_showCreatePassword ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _showCreatePassword = !_showCreatePassword),
                    ),
                  ),
                  obscureText: !_showCreatePassword,
                ),
                SizedBox(height: 12),
                Text('User Role', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: DropdownButton<String>(
                    value: _selectedRole,
                    isExpanded: true,
                    underline: SizedBox(),
                    items: roles.map((role) {
                      return DropdownMenuItem(
                        value: role,
                        child: Text(role.toUpperCase()),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedRole = value);
                      }
                    },
                  ),
                ),
                SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _createUser,
                  style: ElevatedButton.styleFrom(padding: EdgeInsets.symmetric(vertical: 12)),
                  child: Text('Create User'),
                ),
              ],
            ),
          ),
        );

        final listSection = Expanded(
          child: Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Users Management', style: Theme.of(context).textTheme.titleLarge),
                  SizedBox(height: 16),
                  Expanded(
                    child: loading
                        ? Center(child: CircularProgressIndicator())
                        : error != null
                            ? Center(child: Text(error!, style: TextStyle(color: Colors.red)))
                            : users.isEmpty
                                ? Center(child: Text('No users found'))
                                : ListView.builder(
                                    itemCount: users.length,
                                    itemBuilder: (_, index) => _buildUserRow(users[index]),
                                  ),
                  ),
                ],
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

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
