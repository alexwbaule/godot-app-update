# App Update for Godot 4

**Tell players a new version of your game exists, and get it installed.**

- **Android:** [Google Play In-App Updates](https://developer.android.com/guide/playcore/in-app-updates):
  Play's own full-screen "update now" screen (**immediate**) or a background download that installs
  when you say so (**flexible**).
- **iOS:** checks the version published in the App Store and opens the store page. (iOS has no
  in-app update API; your game shows its own dialog.)
- **One GDScript API** for both (`AppUpdate` autoload), with a built-in policy that decides whether an
  update is **optional** or **required**.
- **Testable without Play:** a fake mode (Play's `FakeAppUpdateManager`) drives every step of the
  flow on any device or emulator.

[Leia em português](README.pt-BR.md)

<img src="docs/demo-android.png" width="300" alt="Demo project running on Android in fake mode">

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Optional or required? The policy](#optional-or-required-the-policy)
- [API reference](#api-reference)
- [Setting the update priority on Google Play](#setting-the-update-priority-on-google-play)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Building the Android plugin](#building-the-android-plugin)
- [How it works](#how-it-works)
- [License](#license)

## Requirements

| | |
|---|---|
| Godot | 4.2 or newer (Android plugin v2 format). Developed and tested with **4.7.2**. |
| Android | **Gradle build** export (`gradle_build/use_gradle_build = true`), minSdk 24. The game must be installed **from Google Play** for real updates to show up. |
| iOS | The app must be live in the App Store; set its bundle id in the project settings. |

## Installation

1. Copy `addons/app_update` into your project's `addons/` folder (or download the zip from
   [Releases](../../releases)).
2. **Project → Project Settings → Plugins:** enable **App Update**. This adds the `AppUpdate`
   autoload and the settings under **App Update**.
3. **Android:** in the Android export preset, turn on **Gradle Build → Use Gradle Build** (install the
   Android build template if asked: **Project → Install Android Build Template**). The addon adds its
   AAR and the Play dependency (`com.google.android.play:app-update`) to the export by itself.
4. **iOS:** set **App Update → iOS → Bundle Id** (same as the iOS export preset) and, optionally,
   **App Store Id** and **Countries** (see [settings](#project-settings)).

## Quick start

```gdscript
func _ready() -> void:
    AppUpdate.update_checked.connect(_on_update_checked)
    AppUpdate.update_downloaded.connect(_on_update_downloaded)
    AppUpdate.check_for_update()


func _on_update_checked(result: Dictionary) -> void:
    if result.error != "":
        return  # offline, not installed from Play, unsupported platform… just keep playing
    match result.kind:
        AppUpdate.UpdateKind.REQUIRED:
            if result.platform == "ios":
                show_update_dialog(true)        # your UI; its button calls AppUpdate.open_store()
            else:
                AppUpdate.start_recommended_update()   # Play's full-screen update
        AppUpdate.UpdateKind.OPTIONAL:
            if result.platform == "ios":
                show_update_dialog(false)       # "A new version is available" + "Later"
            else:
                AppUpdate.start_recommended_update()   # Play asks, then downloads in the background


func _on_update_downloaded() -> void:
    # Flexible update ready. Install now (the app restarts) or wait for a good moment,
    # e.g. back on the main menu.
    AppUpdate.complete_update()
```

Prefer `await`? It works too — every answer arrives after the call returns:

```gdscript
AppUpdate.check_for_update()
var result: Dictionary = await AppUpdate.update_checked
```

Want a check on every start without writing code? Turn on **App Update → General → Check On Start**
and just listen to `update_checked`.

## Optional or required? The policy

Every result carries `kind`: `NONE`, `OPTIONAL` or `REQUIRED`. It is computed from the store data
and the project settings, so **you decide per release, not per build**.

### Android

Play gives each release an **update priority** (0–5) and tells how many days the update has been
available (**staleness**). An update is `REQUIRED` when:

- its priority ≥ **Required Priority** (default **4**), or
- **Required Staleness Days** is ≥ 0 and the update has been out for at least that many days;

…and Play allows the immediate flow for it. Anything else that is available is `OPTIONAL`.
An immediate update the player left half-way (`in_progress`) is always `REQUIRED`, as Play asks.

### iOS

The App Store only gives the version string, so the rule uses how much it changed compared with your
`application/config/version`:

| Required When | 1.6.5 → 1.6.6 | 1.6.5 → 1.7.0 | 1.6.5 → 2.0.0 |
|---|---|---|---|
| `major` | optional | optional | **required** |
| `minor` (default) | optional | **required** | **required** |
| `patch` | **required** | **required** | **required** |
| `never` | optional | optional | optional |

Versions are compared number by number (`1.10.0` > `1.9.3`); anything after the digits of a part
(`1.7.0-beta`) is ignored.

> **Tip:** use the same idea on Android: give releases that bump the minor version priority 5 and
> patch releases a lower one. Then both stores behave the same way.

### Project settings

| Setting | Default | What it does |
|---|---|---|
| `app_update/general/check_on_start` | `false` | Calls `check_for_update()` when the game starts. |
| `app_update/android/required_priority` | `4` | Priority from which an update is required. `0` = never by priority. |
| `app_update/android/required_staleness_days` | `-1` | Days after which an available update becomes required. `-1` = off. |
| `app_update/ios/bundle_id` | — | Bundle id used for the App Store lookup. **Required on iOS.** |
| `app_update/ios/app_store_id` | — | Numeric App Store id; only used to open the store when the lookup failed. |
| `app_update/ios/countries` | `us` | Comma-separated storefronts tried in order (`br,us`). The lookup only finds apps sold in that country. |
| `app_update/ios/required_when` | `minor` | `major`, `minor`, `patch` or `never` (table above). |

## API reference

### `AppUpdate` methods

| Method | Platforms | Description |
|---|---|---|
| `check_for_update()` | all | Asks the store. Answer: `update_checked(result)`. Ignored while a check is running. |
| `start_recommended_update() -> bool` | Android, iOS | What the last check recommends: Android **immediate** when required, **flexible** when optional (falls back to the other type if Play does not allow it); iOS opens the store. |
| `start_immediate_update() -> bool` | Android | Play's full-screen update. The app restarts once installed. |
| `start_flexible_update() -> bool` | Android | Play's confirmation dialog, then a background download. |
| `complete_update()` | Android | Installs a downloaded flexible update and restarts the app. |
| `open_store() -> bool` | Android, iOS | Opens the game's store page. |
| `is_supported() -> bool` | all | `true` on Android with the plugin exported, and on iOS with a bundle id. |
| `check_app_store()` | all | The iOS check, on any platform (useful to test from the editor). |
| `android_plugin() -> Object` | Android | The raw `GodotAppUpdate` singleton (fake mode, see [Testing](#testing)). |
| `compare_versions(a, b) -> int` | static | `-1`, `0` or `1`. |
| `version_change(from, to) -> String` | static | `"major"`, `"minor"`, `"patch"` or `"none"`. |
| `last_result: Dictionary` | all | The last `update_checked` result. |

`start_*` return `false` when there is nothing to start (no check yet, no update, type not allowed).
A Play `AppUpdateInfo` can only start one flow, so **check again** before starting another one.

### Signals

| Signal | Description |
|---|---|
| `update_checked(result: Dictionary)` | Answer of `check_for_update()` / `check_app_store()`. Always emitted after the call returns. |
| `update_flow_finished(type: String, result: String)` | Android: Play's update screen closed. `type`: `flexible`/`immediate`; `result`: `ok`, `canceled`, `failed`. |
| `download_progress(bytes_downloaded: int, total_bytes: int)` | Android flexible: download progress. |
| `update_downloaded()` | Android flexible: ready to install → `complete_update()`. Also emitted by a check when a previous download is waiting. |
| `install_failed(error_code: int)` | Android flexible: download/install failed (Play's `InstallErrorCode`). |
| `install_state_changed(state: Dictionary)` | Android: every raw install state (`status`, `status_name`, `bytes_downloaded`, `total_bytes_to_download`, `error_code`, `package_name`). |

All signals arrive on the main thread.

### Result dictionary

| Key | Type | Description |
|---|---|---|
| `platform` | String | `android`, `ios` or the OS name. |
| `supported` | bool | `false` when this platform/build cannot check. |
| `available` | bool | A newer version is in the store. |
| `kind` | int | `AppUpdate.UpdateKind`: `NONE`, `OPTIONAL`, `REQUIRED`. |
| `current_version` | String | `application/config/version`. |
| `store_version` | String | iOS: version in the App Store. |
| `available_version_code` / `current_version_code` | int | Android: versionCode offered by Play / running. |
| `update_priority` | int | Android: 0–5. |
| `staleness_days` | int | Android: days since Play has had the update; `-1` = unknown. |
| `immediate_allowed` / `flexible_allowed` | bool | Android: flows Play allows for this update. |
| `install_status` | String | Android: `pending`, `downloading`, `downloaded`, `installing`, `installed`, `failed`, `canceled`… |
| `store_url` | String | iOS: the game's App Store page. |
| `error` / `error_code` | String / int | Empty / `0` when the check worked. |
| `raw` | Dictionary | What the store answered, untouched. |

### Android plugin (`GodotAppUpdate` singleton)

Used by the autoload; call it directly only for things the autoload does not wrap.

| Method | Description |
|---|---|
| `check_update()` | → `update_info_received(info)` / `update_info_failed(code, message)` |
| `start_update(type: int) -> bool` | `0` flexible, `1` immediate → `update_flow_finished(type, result)` |
| `complete_update()` | Installs a downloaded flexible update. |
| `get_current_version_code() -> int` | versionCode of the running app. |
| `open_store_page() -> bool` | Play Store page of the app. |
| `set_fake_mode(enabled: bool)`, `is_fake_mode() -> bool` | Switch to Play's `FakeAppUpdateManager`. |
| `fake_*` | See [Testing](#testing). |

The plugin also follows Play's lifecycle rules by itself: when the app comes back to the foreground
it **resumes an interrupted immediate update** and reports a flexible update that **finished
downloading in the background**.

## Setting the update priority on Google Play

The Play Console has **no field** for it: the priority is set when the release is created through the
[Google Play Developer API](https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks)
(`inAppUpdatePriority` in the track release, 0–5). It cannot be changed once the release is rolled
out.

```json
{ "releases": [{ "versionCodes": ["54"], "status": "completed", "inAppUpdatePriority": 5 }] }
```

Tools such as [fastlane supply](https://docs.fastlane.tools/actions/upload_to_play_store/)
(`in_app_update_priority`) or the Gradle Play Publisher (`updatePriority`) set it too. Without a
priority (0) only **Required Staleness Days** can make an Android update required.

## Testing

### Fake mode — any device, no Play

Play's `FakeAppUpdateManager` simulates everything locally. Nothing appears on screen (there is no Play
UI); you play the role of the user and of Play:

```gdscript
var p := AppUpdate.android_plugin()
p.set_fake_mode(true)
p.fake_set_update_available(55, -1)    # versionCode 55; -1 = both flows allowed (0 flexible, 1 immediate)
p.fake_set_update_priority(5)
p.fake_set_staleness_days(3)
AppUpdate.check_for_update()           # → REQUIRED
# after start_flexible_update():
p.fake_user_accepts_update()           # → update_flow_finished("flexible", "ok")
p.fake_download_starts(1000)           # → install_state_changed(downloading)
p.fake_download_completes()            # → update_downloaded
AppUpdate.complete_update()            # → installing
p.fake_install_completes()             # → installed
```

Other controls: `fake_set_update_not_available()`, `fake_user_rejects_update()`,
`fake_set_bytes_downloaded(n)` (reported with the next state change), `fake_download_fails()`,
`fake_user_cancels_download()`, `fake_install_fails()`, `fake_is_immediate_flow_visible()`,
`fake_is_confirmation_dialog_visible()`. `set_fake_mode(false)` goes back to Play.

The **demo project** in this repository has a button for each of them (screenshot above).

### Real updates

1. Upload version **N** to a testing track (internal testing is the fastest) and install it **from
   the Play Store** on the test phone.
2. Upload **N + 1** (with the priority you want) to the same track.
3. Open the Play Store app once (its cache decides when the update is "seen"), then open the game.

[Internal app sharing](https://support.google.com/googleplay/android-developer/answer/9844679) also
works: install N from one link, then open the N + 1 link but **don't** press update.

### iOS

`AppUpdate.check_app_store()` runs on any platform. In the editor, set the bundle id of a live app and
set `application/config/version` lower than the store's to see `OPTIONAL` / `REQUIRED`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Android always answers `NONE` | The app was not installed by Play (adb, APK file), the Play account has no access to the newer version (testing tracks), or the Play Store cache has not seen it yet — open the Play Store app. |
| `update_info_failed` code `-10` | `ERROR_APP_NOT_OWNED`: not installed from Play. |
| `update_info_failed` code `-100` / `no activity` | The check ran before the Android activity existed. Call it from `_ready()` or later. |
| `start_*` returns `false` | No check yet, the update type is not allowed (see `immediate_allowed` / `flexible_allowed`), or the result was already used to start a flow — check again. |
| iOS: `app not found in the App Store` | Wrong bundle id, the app is not live yet, or it is not sold in the storefronts of **Countries**. |
| iOS shows the update hours late | Apple caches the lookup API; a new version may take a few hours to show up. |
| Export: "Android build template not installed" | **Project → Install Android Build Template** and enable **Use Gradle Build**. |

## Building the Android plugin

The repository ships the built AARs in `addons/app_update/bin/`. To rebuild them (Android SDK
required):

```bash
cd android_plugin
./gradlew copyToAddon        # builds debug + release and copies them into addons/app_update/bin
```

Versions live in `android_plugin/plugin/build.gradle.kts` (`godotVersion`, `playAppUpdateVersion`).
If you change the Play library version, update `ANDROID_DEPENDENCIES` in
`addons/app_update/plugin.gd` too.

## How it works

```
your game ──► AppUpdate (autoload, GDScript)
                 ├─ Android ─► GodotAppUpdate (Kotlin plugin) ─► Play In-App Updates (AppUpdateManager)
                 └─ iOS ─────► HTTPRequest ─► itunes.apple.com/lookup ─► OS.shell_open(store page)
```

- `addons/app_update/plugin.gd` — editor plugin: autoload, project settings, Android export
  (AAR + `com.google.android.play:app-update` dependency).
- `addons/app_update/app_update.gd` — the `AppUpdate` autoload: unified API, policy, iOS lookup.
- `android_plugin/` — Gradle project of the Kotlin plugin.
- `demo/` — demo scene (this repository is also the demo Godot project).

## License

[MIT](LICENSE) © Alex W Baulé
