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
      final response = await ApiService.login(
          _identifierController.text.trim(), _passwordController.text.trim());
      if (response.containsKey('token')) {
        final user = response['user'];
        if (user is Map<String, dynamic> && user['role'] != 'admin') {
          setState(() {
            _error = 'Admin access required. Please login with an admin account.';
          });
          return;
        }

        AuthState.token = response['token'];
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardScreen(token: response['token']),
          ),
        );
      } else {
        setState(() {
          final statusCode = response['statusCode'];
          final backendBody = response['body'];
          final errorMessage = response['error'] ?? 'Unable to login';
          _error = statusCode != null
              ? '$errorMessage (status: $statusCode)'
              : errorMessage;
          if (backendBody != null &&
              backendBody is Map<String, dynamic> &&
              backendBody.isNotEmpty) {
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
      backgroundColor: const Color(0xFFF0F4F8),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 32.0, vertical: 40.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.location_on,
                          size: 48, color: Colors.blue),
                      const SizedBox(height: 12),
                      Text(
                        'GPS Tracker Admin',
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _identifierController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: 'Email or Username',
                          prefixIcon: const Icon(Icons.person_outline),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 24),
                      if (_error != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            border: Border.all(color: Colors.red.shade200),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(color: Colors.red.shade800),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2),
                                )
                              : const Text('Login',
                                  style: TextStyle(fontSize: 16)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
