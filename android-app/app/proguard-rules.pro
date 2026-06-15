# GPS Tracker ProGuard Rules for multi-device compatibility

# Keep LocationRequest API (used for Motorola and other devices)
-keep class com.google.android.gms.location.** { *; }
-keep interface com.google.android.gms.location.** { *; }
-dontwarn com.google.android.gms.location.**

# Keep Location Services
-keep class android.location.** { *; }
-dontwarn android.location.**

# Keep app code
-keep class com.example.gps_tracker.** { *; }
-keep class com.example.gps_tracker.TrackingService { *; }
-keep class com.example.gps_tracker.MainActivity { *; }
-keep class com.example.gps_tracker.LoginActivity { *; }
-keep class com.example.gps_tracker.DeviceCompat { *; }
-keep class com.example.gps_tracker.NetworkDiagnostics { *; }

# Keep Room Database
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *
-keepclassmembers class * extends androidx.room.RoomDatabase {
  public static ** getInstance(...);
}

# Keep Kotlin
-keep class kotlin.** { *; }
-keep interface kotlin.** { *; }

# Keep OkHttp
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-dontwarn okhttp3.**

# Keep Gson
-keep class com.google.gson.** { *; }
-keep interface com.google.gson.** { *; }
-dontwarn com.google.gson.**

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep inner classes of services
-keepclasseswithmembers class * {
    *** *LocationCallback(...);
}

# General configuration
-verbose
-dontwarn java.lang.invoke.*
-dontwarn com.sun.activation.**
-dontwarn javax.activation.**
