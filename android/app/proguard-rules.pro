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

# CI run #87 (2026-11-17, "Prepare Release") failed at :app:minifyReleaseWithR8:
# "Missing classes detected while running R8", naming Play Core classes. The full
# step log was not retrievable, so the complete missing list is unknown; the three
# package trees below cover every Play Core reference verified in the shipped
# Flutter engine jar (flutter.jar, Flutter 3.41.5: PlayStoreDeferredComponentManager
# references splitinstall.* + tasks.*, FlutterPlayStoreSplitApplication extends
# splitcompat.SplitCompatApplication). Those engine classes are unused in the
# current app configuration: WenkuApplication extends plain android.app.Application,
# no deferred components are configured, no DeferredComponentManager is injected,
# and updates go through AppUpdatePlugin (FileProvider + PackageManager). These
# references are therefore safe to silence; do NOT add a Play Core dependency for
# them, and do NOT widen this to a blanket -dontwarn. If the next CI run reports
# further missing classes outside these packages, they need their own check.
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.tasks.**
