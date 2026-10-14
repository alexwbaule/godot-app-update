# Changelog

## 1.0.0 — 2026-10-14

First release.

- Android: Google Play In-App Updates (flexible and immediate) through a Godot 4 Android plugin (v2),
  built against Godot 4.7.2 and `com.google.android.play:app-update` 2.1.0.
- Android: resumes an interrupted immediate update and reports a flexible download finished in the
  background when the app returns to the foreground.
- Android: fake mode with Play's `FakeAppUpdateManager` to test every step without Play.
- iOS: App Store version check (iTunes lookup API) and store page.
- `AppUpdate` autoload: one API for both, OPTIONAL/REQUIRED policy from Play's update priority,
  staleness days and the version change on iOS; project settings under `app_update/…`.
- Demo project with a button for every call.
