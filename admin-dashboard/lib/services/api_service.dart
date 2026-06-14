import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/location_point.dart';

class ApiService {
  static const String baseUrl = 'http://116.74.77.22:8095/api';
  // The server is exposed on port 8095 for the Flutter web/dashboard deployment.

  static Uri buildUri(String path) => Uri.parse('$baseUrl$path');

  static Future<Map<String, dynamic>> login(String identifier, String password) async {
    final uri = buildUri('/auth/login');
    print('ApiService.login calling $uri');
    try {
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': identifier, 'password': password}),
      );

      print('ApiService.login status=${response.statusCode} body=${response.body}');
      final Map<String, dynamic> body = response.body.isNotEmpty
          ? jsonDecode(response.body) as Map<String, dynamic>
          : <String, dynamic>{};

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return body;
      }

      return <String, dynamic>{
        'error': body['error'] ?? 'Server error',
        'statusCode': response.statusCode,
        'body': body,
      };
    } catch (err, stackTrace) {
      print('ApiService.login exception: $err');
      print(stackTrace);
      return <String, dynamic>{
        'error': 'Network error: ${err.toString()}',
      };
    }
  }

  static Future<List<UserModel>> getUsers(String token) async {
    final uri = buildUri('/admin/users');
    print('ApiService.getUsers calling $uri');
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer ' + token},
    );
    print('ApiService.getUsers status=${response.statusCode} body=${response.body}');
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to load users');
    }
    return (body['users'] as List).map((item) => UserModel.fromJson(item)).toList();
  }

  static Future<Map<String, dynamic>> createUser(String token, String name, String email, String password, [String role = 'salesperson']) async {
    final uri = buildUri('/admin/users');
    print('ApiService.createUser calling $uri');
    final response = await http.post(
      uri,
      headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'email': email, 'password': password, 'role': role}),
    );
    print('ApiService.createUser status=${response.statusCode} body=${response.body}');
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
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

    final uri = buildUri('/admin/users/$id');
    print('ApiService.updateUser calling $uri');
    final response = await http.put(
      uri,
      headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
      body: jsonEncode(bodyMap),
    );
    print('ApiService.updateUser status=${response.statusCode} body=${response.body}');
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to update user');
    }
    return body;
  }

  static Future<Map<String, dynamic>> deleteUser(String token, int id) async {
    final uri = buildUri('/admin/users/$id');
    print('ApiService.deleteUser calling $uri');
    final response = await http.delete(
      uri,
      headers: {'Authorization': 'Bearer ' + token},
    );
    print('ApiService.deleteUser status=${response.statusCode} body=${response.body}');
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to delete user');
    }
    return body;
  }

  static Future<List<LocationPoint>> getLatestLocations(String token, {bool includeStale = false}) async {
    final uri = buildUri('/locations/latest${includeStale ? '?include_stale=true' : ''}');
    print('ApiService.getLatestLocations calling $uri');
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer ' + token},
    );
    print('ApiService.getLatestLocations status=${response.statusCode} body=${response.body}');

    final body = response.body.isNotEmpty
        ? jsonDecode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to load live locations');
    }

    final locations = (body['locations'] as List?) ?? <dynamic>[];
    print('ApiService.getLatestLocations parsed locations count=${locations.length} includeStale=$includeStale');
    return locations
        .map((item) => LocationPoint.fromJson(item))
        .toList();
  }
}
