import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() {
  runApp(AdminDashboardApp());
}

class AdminDashboardApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Admin Dashboard',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: LoginScreen(),
    );
  }
}
