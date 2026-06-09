# Admin Dashboard

This Flutter module is the admin dashboard for the self-hosted tracking system.

## Setup

1. Install Flutter SDK.
2. Run `flutter pub get` in `admin-dashboard`.
3. Set `ApiService.baseUrl` in `lib/services/api_service.dart` to your backend URL.
4. Launch with `flutter run -d chrome` or `flutter run` for mobile.

## Notes

- The dashboard logs in an admin and calls backend admin endpoints.
- A live map polls the latest salesperson coordinates every 12 seconds.
- To enable web, run `flutter config --enable-web` if needed.
