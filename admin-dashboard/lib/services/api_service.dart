import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/location_point.dart';

class ApiService {
  static const String baseUrl = 'http://localhost:4000/api';
  // For production, change to: 'http://192.168.2.101:4000/api'

  static Future<Map<String, dynamic>> login(String identifier, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': identifier, 'password': password}),
      );

      final Map<String, dynamic> body = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : {};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return body;
      }

      return {
        'error': body['error'] ?? 'Server error',
        'statusCode': response.statusCode,
        'body': body,
      };
    } catch (err) {
      return {
        'error': 'Network error: ${err.toString()}',
      };
    }
  }

  static Future<List<UserModel>> getUsers(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/admin/users'),
      headers: {'Authorization': 'Bearer ' + token},
    );
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to load users');
    }
    return (body['users'] as List).map((item) => UserModel.fromJson(item)).toList();
  }

  static Future<Map<String, dynamic>> createUser(String token, String name, String email, String password, [String role = 'salesperson']) async {
    final response = await http.post(
      Uri.parse('$baseUrl/admin/users'),
      headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'email': email, 'password': password, 'role': role}),
    );
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to create user');
    }
    return body;
  }

  static Future<Map<String, dynamic>> updateUser(String token, int id, String name, String email, [String? password, String? role]) async {
    final bodyMap = {'name': name, 'email': email};
    if (password != null && password.isNotEmpty) {
      bodyMap['password'] = password;
    }
    if (role != null) {
      bodyMap['role'] = role;
    }

    final response = await http.put(
      Uri.parse('$baseUrl/admin/users/$id'),
      headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
      body: jsonEncode(bodyMap),
    );
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to update user');
    }
    return body;
  }

  static Future<Map<String, dynamic>> deleteUser(String token, int id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/admin/users/$id'),
      headers: {'Authorization': 'Bearer ' + token},
    );
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : {};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to delete user');
    }
    return body;
  }

  static Future<List<LocationPoint>> getLatestLocations(String token) async {
    final response = await http.get(
      Uri.parse('$baseUrl/locations/latest'),
      headers: {'Authorization': 'Bearer ' + token},
    );
    final body = jsonDecode(response.body);
    return (body['locations'] as List).map((item) => LocationPoint.fromJson(item)).toList();
  }
}
