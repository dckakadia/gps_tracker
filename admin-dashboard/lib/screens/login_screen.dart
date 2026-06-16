import 'dart:convert';

import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'dashboard_screen.dart';
import '../auth_state.dart';

class LoginScreen extends StatefulWidget {
  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await ApiService.login(_identifierController.text.trim(), _passwordController.text.trim());
      if (response.containsKey('token')) {
        final user = response['user'];
        if (user is Map<String, dynamic> && user['role'] != 'admin') {
          setState(() {
            _error = 'Admin access required. Please login with an admin account.';
          });
          return;
        }

        AuthState.token = response['token'];
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => DashboardScreen(token: response['token']),
        ));
      } else {
        setState(() {
          final statusCode = response['statusCode'];
          final backendBody = response['body'];
          final errorMessage = response['error'] ?? 'Unable to login';
          _error = statusCode != null
              ? '$errorMessage (status: $statusCode)'
              : errorMessage;
          if (backendBody != null && backendBody is Map<String, dynamic> && backendBody.isNotEmpty) {
            _error = '$_error\nResponse: ${jsonEncode(backendBody)}';
          }
        });
      }
    } catch (err) {
      setState(() {
        _error = 'Unexpected error: ${err.toString()}';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Admin Login')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _identifierController,
              decoration: InputDecoration(labelText: 'Email or User ID'),
            ),
            SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            SizedBox(height: 24),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: Colors.red)),
              SizedBox(height: 12),
            ],
            ElevatedButton(
              onPressed: _loading ? null : _login,
              child: _loading ? CircularProgressIndicator(color: Colors.white) : Text('Login'),
            ),
          ],
        ),
      ),
    );
  }
}
