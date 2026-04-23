# Android Quick Settings Overlay Tile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Android Quick Settings tile that toggles the byvo floating ball, uses the app icon, and fails with a toast instead of opening permission settings when required permissions are missing.

**Architecture:** Keep tile behavior fully native on Android. Add a focused `FloatingBallController` to own preference writes, overlay start/stop, accessibility checks, and tile refreshes; then register a `TileService` that delegates to the controller. Flutter keeps using the shared `show_floating_ball` preference so app-side recovery remains intact.

**Tech Stack:** Android `TileService`, Kotlin, Android `SharedPreferences`, existing `flutter_overlay_window` service registration, Flutter widget tests

---

## File Structure

- Modify: `android/app/src/main/AndroidManifest.xml`
  - Register the new tile service and required permission/intent filter.
- Create: `android/app/src/main/kotlin/cn/wleo/byvo/FloatingBallController.kt`
  - Centralize floating-ball state persistence, permission checks, overlay service start/stop, and tile refresh.
- Create: `android/app/src/main/kotlin/cn/wleo/byvo/FloatingBallTileService.kt`
  - Render and handle the Quick Settings tile by delegating to `FloatingBallController`.
- Modify: `android/app/src/main/kotlin/cn/wleo/byvo/MainActivity.kt`
  - Reuse controller-owned state refresh if needed after app launch/resume paths.
- Modify: `packages/byvo_insert_text/android/src/main/kotlin/cn/wleo/byvo/insert_text/ByvoInsertTextPlugin.kt`
  - Extract or expose accessibility-status helper so native tile/controller uses the same rule as Flutter.
- Modify: `android/app/src/main/res/values/strings.xml`
  - Add tile label and failure toasts.
- Modify: `test/floating_ball_accessibility_retry_test.dart`
  - Keep Flutter regression coverage for shared `show_floating_ball` persistence.

## Task 1: Add Native Floating Ball Controller

**Files:**
- Create: `android/app/src/main/kotlin/cn/wleo/byvo/FloatingBallController.kt`
- Modify: `packages/byvo_insert_text/android/src/main/kotlin/cn/wleo/byvo/insert_text/ByvoInsertTextPlugin.kt`
- Modify: `android/app/src/main/res/values/strings.xml`

- [ ] **Step 1: Write the failing controller-oriented test or verification hook**

If the project can host Android unit tests without extra build work, create:

```kotlin
// android/app/src/test/kotlin/cn/wleo/byvo/FloatingBallControllerTest.kt
@Test
fun enable_returns_accessibility_error_when_service_disabled() {
    val result = controller.enable()
    assertThat(result).isEqualTo(FloatingBallController.Result.AccessibilityDenied)
}
```

If Android unit-test setup is too heavy for this repo, instead create the controller with a narrow, enum-based API so behavior can be verified from integration paths later:

```kotlin
enum class ToggleResult {
    ENABLED,
    DISABLED,
    ACCESSIBILITY_DENIED,
    OVERLAY_PERMISSION_DENIED,
    START_FAILED,
}
```

- [ ] **Step 2: Run the focused test or compile check to verify the red state**

Run one of:

```bash
./gradlew testDebugUnitTest
```

Expected: FAIL because `FloatingBallController` does not exist yet.

Or, if no Android unit test was added:

```bash
flutter test test/floating_ball_accessibility_retry_test.dart
```

Expected: PASS baseline only; note there is no native controller yet.

- [ ] **Step 3: Implement minimal controller**

Create `FloatingBallController.kt` with a focused API like:

```kotlin
package cn.wleo.byvo

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.service.quicksettings.TileService
import android.view.accessibility.AccessibilityManager

class FloatingBallController(
    private val context: Context,
) {
    fun desiredEnabled(): Boolean = prefs().getBoolean(KEY_SHOW_FLOATING_BALL, false)

    fun setDesiredEnabled(value: Boolean) {
        prefs().edit().putBoolean(KEY_SHOW_FLOATING_BALL, value).apply()
        requestTileRefresh()
    }

    fun enable(): ToggleResult {
        if (!isAccessibilityEnabled()) {
            setDesiredEnabled(false)
            return ToggleResult.ACCESSIBILITY_DENIED
        }
        if (!Settings.canDrawOverlays(context)) {
            setDesiredEnabled(false)
            return ToggleResult.OVERLAY_PERMISSION_DENIED
        }
        return try {
            context.startService(Intent().setClassName(context, OVERLAY_SERVICE_NAME))
            setDesiredEnabled(true)
            ToggleResult.ENABLED
        } catch (_: Throwable) {
            setDesiredEnabled(false)
            ToggleResult.START_FAILED
        }
    }

    fun disable(): ToggleResult {
        runCatching {
            context.stopService(Intent().setClassName(context, OVERLAY_SERVICE_NAME))
        }
        setDesiredEnabled(false)
        return ToggleResult.DISABLED
    }

    fun tileActive(): Boolean = desiredEnabled()

    private fun isAccessibilityEnabled(): Boolean {
        val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            ?: return false
        val target = ComponentName(context, ByvoAccessibilityService::class.java).flattenToString()
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return manager.isEnabled && enabled.split(':').any { it.equals(target, ignoreCase = true) }
    }

    private fun requestTileRefresh() {
        TileService.requestListeningState(
            context,
            ComponentName(context, FloatingBallTileService::class.java),
        )
    }
}
```

Also add matching strings in `strings.xml`:

```xml
<string name="quick_settings_tile_label">悬浮球</string>
<string name="quick_settings_overlay_permission_denied">悬浮窗权限未开启，无法打开悬浮球</string>
<string name="quick_settings_accessibility_denied">无障碍未开启，无法打开悬浮球</string>
<string name="quick_settings_enable_failed">开启悬浮球失败</string>
```

- [ ] **Step 4: Refactor plugin helper so accessibility logic is shared**

Extract the plugin’s accessibility check into a public helper or duplicate only if extraction is too invasive. Preferred shape:

```kotlin
object AccessibilityStatus {
    fun isByvoAccessibilityEnabled(context: Context): Boolean { ... }
}
```

Then use the helper in both:

```kotlin
result.success(AccessibilityStatus.isByvoAccessibilityEnabled(ctx))
```

and:

```kotlin
if (!AccessibilityStatus.isByvoAccessibilityEnabled(context)) { ... }
```

- [ ] **Step 5: Run the focused native verification**

Run:

```bash
./gradlew testDebugUnitTest
```

Expected: PASS if native unit tests were added.

If not, run:

```bash
flutter test test/floating_ball_accessibility_retry_test.dart
```

Expected: PASS; no Flutter regression introduced by the new shared helper.

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/kotlin/cn/wleo/byvo/FloatingBallController.kt \
  packages/byvo_insert_text/android/src/main/kotlin/cn/wleo/byvo/insert_text/ByvoInsertTextPlugin.kt \
  android/app/src/main/res/values/strings.xml
git commit -m "Add native floating ball controller"
```

## Task 2: Register and Implement the Quick Settings Tile

**Files:**
- Create: `android/app/src/main/kotlin/cn/wleo/byvo/FloatingBallTileService.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Write the failing service registration expectation**

Add a manifest-level checklist in the task branch and verify missing registration:

```xml
<service
    android:name=".FloatingBallTileService"
    android:exported="true"
    android:icon="@mipmap/ic_launcher"
    android:label="@string/quick_settings_tile_label"
    android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
    <intent-filter>
        <action android:name="android.service.quicksettings.action.QS_TILE" />
    </intent-filter>
</service>
```

- [ ] **Step 2: Run a compile check before implementation**

Run:

```bash
./gradlew assembleDebug
```

Expected: FAIL once `AndroidManifest.xml` references `FloatingBallTileService` before the class exists.

- [ ] **Step 3: Implement the tile service**

Create `FloatingBallTileService.kt`:

```kotlin
package cn.wleo.byvo

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast

class FloatingBallTileService : TileService() {
    private val controller by lazy { FloatingBallController(applicationContext) }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()
        when (if (controller.tileActive()) controller.disable() else controller.enable()) {
            ToggleResult.ENABLED,
            ToggleResult.DISABLED -> updateTile()
            ToggleResult.ACCESSIBILITY_DENIED -> {
                Toast.makeText(this, R.string.quick_settings_accessibility_denied, Toast.LENGTH_SHORT).show()
                updateTile()
            }
            ToggleResult.OVERLAY_PERMISSION_DENIED -> {
                Toast.makeText(this, R.string.quick_settings_overlay_permission_denied, Toast.LENGTH_SHORT).show()
                updateTile()
            }
            ToggleResult.START_FAILED -> {
                Toast.makeText(this, R.string.quick_settings_enable_failed, Toast.LENGTH_SHORT).show()
                updateTile()
            }
        }
    }

    private fun updateTile() {
        qsTile?.apply {
            label = getString(R.string.quick_settings_tile_label)
            state = if (controller.tileActive()) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            updateTile()
        }
    }
}
```

- [ ] **Step 4: Register the tile service in the manifest**

Update `AndroidManifest.xml` under `<application>`:

```xml
<service
    android:name=".FloatingBallTileService"
    android:exported="true"
    android:icon="@mipmap/ic_launcher"
    android:label="@string/quick_settings_tile_label"
    android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
    <intent-filter>
        <action android:name="android.service.quicksettings.action.QS_TILE" />
    </intent-filter>
</service>
```

- [ ] **Step 5: Run build verification**

Run:

```bash
./gradlew assembleDebug
```

Expected: BUILD SUCCESSFUL

- [ ] **Step 6: Commit**

```bash
git add android/app/src/main/kotlin/cn/wleo/byvo/FloatingBallTileService.kt \
  android/app/src/main/AndroidManifest.xml
git commit -m "Add quick settings tile for floating ball"
```

## Task 3: Keep Flutter Recovery and Shared Preference Behavior Correct

**Files:**
- Modify: `test/floating_ball_accessibility_retry_test.dart`
- Modify: `lib/main.dart` only if Flutter recovery needs a small adjustment after native tile writes the same key

- [ ] **Step 1: Write or extend the failing Flutter regression test**

Use the existing test file and add a case that simulates the native tile having written `show_floating_ball = true` before app startup:

```dart
testWidgets(
  'app restores floating ball UI when native tile enabled persisted state',
  (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'show_floating_ball': true,
    });

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(find.text('悬浮球已开启'), findsOneWidget);
  },
);
```

- [ ] **Step 2: Run the focused Flutter test to verify red/green state**

Run:

```bash
flutter test test/floating_ball_accessibility_retry_test.dart
```

Expected:
- If current logic already satisfies the case, keep the test and treat it as regression coverage.
- If it fails, fix only the minimal Flutter state-sync path.

- [ ] **Step 3: Make the minimal Flutter adjustment if needed**

If the new test fails, keep the change small, for example:

```dart
Future<void> _loadShowFloatingBall() async {
  final prefs = await SharedPreferences.getInstance();
  final show = prefs.getBool(_keyShowFloatingBall) ?? false;
  if (!mounted) return;
  setState(() => _showFloatingBall = show);
  ...
}
```

Do not redesign the Flutter toggle flow here unless the regression proves it is necessary.

- [ ] **Step 4: Run the focused Flutter test again**

Run:

```bash
flutter test test/floating_ball_accessibility_retry_test.dart
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/floating_ball_accessibility_retry_test.dart lib/main.dart
git commit -m "Cover native tile and Flutter recovery state sync"
```

## Task 4: Final Verification

**Files:**
- No new files required

- [ ] **Step 1: Run Android build verification**

Run:

```bash
./gradlew assembleDebug
```

Expected: BUILD SUCCESSFUL

- [ ] **Step 2: Run Flutter regression suite**

Run:

```bash
flutter test test/floating_ball_accessibility_retry_test.dart test/widget_test.dart
```

Expected: All tests passed

- [ ] **Step 3: Manual QA on Android device/emulator**

Verify:

```text
1. Add the “悬浮球” tile to Quick Settings.
2. Tap when both permissions are granted -> tile turns active, overlay appears.
3. Tap again -> tile turns inactive, overlay closes.
4. Revoke overlay permission -> tap tile -> toast shows failure, tile stays inactive.
5. Disable accessibility -> tap tile -> toast shows failure, tile stays inactive.
6. Enable tile, fully kill app, reopen app -> Flutter UI still shows “悬浮球已开启”.
```

- [ ] **Step 4: Commit any final verification-only adjustments**

```bash
git add -A
git commit -m "Polish quick settings overlay tile behavior"
```

## Plan Self-Review

- Spec coverage checked:
  - Tile icon/label: Task 2
  - Direct toggle from control center: Tasks 1-2
  - Permission failure with toast only: Tasks 1-2
  - Shared `show_floating_ball` state: Tasks 1 and 3
  - Flutter recovery compatibility: Task 3
  - Final verification: Task 4
- Placeholder scan checked:
  - No `TODO`/`TBD`
  - Every changed file is named explicitly
  - Commands are concrete
- Type consistency checked:
  - `FloatingBallController`, `FloatingBallTileService`, `ToggleResult`, and `show_floating_ball` are named consistently across tasks
