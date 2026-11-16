# Flutter wrapper & engine entrypoints
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# App host plugins, activities, and home-screen AppWidget providers
-keep class app.shuyu.reader.** { *; }

# Background audio service & media button receiver
-keep class com.ryanheise.audioservice.** { *; }
-keep class androidx.media.** { *; }

-dontwarn java.lang.invoke.StringConcatFactory
