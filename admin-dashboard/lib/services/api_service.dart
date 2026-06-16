import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/user.dart';
import '../models/location_point.dart';

class ApiService {
  // Production: served via nginx, so /api resolves to the same origin.
  // Local dev: flutter run --dart-define=API_URL=http://localhost:4000/api
  static const String baseUrl = String.fromEnvironment('API_URL', defaultValue: '/api');

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

  static Future<List<LocationPoint>> getLocationHistory(String token, int userId, {String? date}) async {
    final queryDate = date ?? DateTime.now().toIso8601String().split('T')[0];
    final uri = buildUri('/locations/history/$userId?date=$queryDate');
    print('ApiService.getLocationHistory calling $uri');
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer ' + token},
    );
    print('ApiService.getLocationHistory status=${response.statusCode} body=${response.body}');

    final body = response.body.isNotEmpty
        ? jsonDecode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to load location history');
    }

    final history = (body['history'] as List?) ?? <dynamic>[];
    print('ApiService.getLocationHistory parsed history count=${history.length}');
    return history
        .map((item) => LocationPoint.fromJson(item))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getUsersStatus(String token) async {
    final uri = buildUri('/users/status');
    print('ApiService.getUsersStatus calling $uri');
    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer ' + token},
    );
    print('ApiService.getUsersStatus status=${response.statusCode} body=${response.body}');
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to load user statuses');
    }
    final users = (body['users'] as List?) ?? <dynamic>[];
    return users.map((u) => u as Map<String, dynamic>).toList();
  }

  static Future<List<Map<String, dynamic>>> getAttendance(String token, {String? date}) async {
    final queryDate = date ?? DateTime.now().toIso8601String().split('T')[0];
    final uri = buildUri('/admin/attendance?date=$queryDate');
    print('ApiService.getAttendance calling $uri');
    final response = await http.get(uri, headers: {'Authorization': 'Bearer ' + token});
    print('ApiService.getAttendance status=${response.statusCode} body=${response.body}');
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to load attendance');
    }
    final attendance = (body['attendance'] as List?) ?? <dynamic>[];
    return attendance.map((a) => a as Map<String, dynamic>).toList();
  }

  static Future<Map<String, dynamic>> getDistance(String token, int userId, String date) async {
    final uri = buildUri('/locations/stats/distance?user_id=$userId&date=$date');
    print('ApiService.getDistance calling $uri');
    final response = await http.get(uri, headers: {'Authorization': 'Bearer ' + token});
    final body = response.body.isNotEmpty ? jsonDecode(response.body) as Map<String, dynamic> : <String, dynamic>{};
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(body['error'] ?? 'Failed to get distance');
    }
    return body;
  }

  static Future<void> sendFcmToken(String token, String fcmToken) async {
    final uri = buildUri('/users/fcm-token');
    await http.post(
      uri,
      headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
      body: jsonEncode({'fcm_token': fcmToken}),
    );
  }

  static Future<void> sendNotification(String token, int userId, String message) async {
    final uri = buildUri('/users/notify');
    await http.post(
      uri,
      headers: {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
      body: jsonEncode({'user_id': userId, 'message': message}),
    );
  }
}
