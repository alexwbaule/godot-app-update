extends Node
## AppUpdate (autoload): finds out whether a newer version of the game is in the store and helps the
## player install it.
##
## - **Android:** Google Play In-App Updates through the `GodotAppUpdate` Android plugin. Play shows
##   its own UI: a full-screen "update now" (IMMEDIATE) or a background download (FLEXIBLE) that
##   ends with [method complete_update].
## - **iOS:** asks the App Store (iTunes lookup API) for the published version, compares it with
##   `application/config/version` and opens the store page with [method open_store]. iOS has no
##   in-app update API, so the game shows its own dialog.
## - **Other platforms:** [method check_for_update] answers `supported = false`.
##
## Typical use:
## [codeblock]
## func _ready() -> void:
##     AppUpdate.update_checked.connect(_on_update_checked)
##     AppUpdate.update_downloaded.connect(func(): AppUpdate.complete_update())
##     AppUpdate.check_for_update()
##
## func _on_update_checked(result: Dictionary) -> void:
##     match result.kind:
##         AppUpdate.UpdateKind.REQUIRED:
##             AppUpdate.start_recommended_update()   # Android: Play full screen; iOS: your dialog + open_store()
##         AppUpdate.UpdateKind.OPTIONAL:
##             AppUpdate.start_recommended_update()   # Android: background download
## [/codeblock]
##
## Whether an update is OPTIONAL or REQUIRED comes from the store data and the project settings
## under `app_update/…` (see README): Play's update priority / staleness on Android, and how much the
## version number changed on iOS.

## Answer of [method check_for_update]. See [method _empty_result] for the keys.
signal update_checked(result: Dictionary)
## FLEXIBLE download progress (Android).
signal download_progress(bytes_downloaded: int, total_bytes: int)
## FLEXIBLE update downloaded: call [method complete_update] (now or when convenient) to install.
signal update_downloaded
## FLEXIBLE download or install failed (Android). [param error_code]: Play's InstallErrorCode.
signal install_failed(error_code: int)
## Every install state change from Play (Android), for games that want the raw data.
signal install_state_changed(state: Dictionary)
## The Play update screen closed (Android). [param type]: "flexible" / "immediate".
## [param result]: "ok" (accepted), "canceled" (user declined or left), "failed".
signal update_flow_finished(type: String, result: String)

enum UpdateKind {
	## No update (or it could not be checked: see `error`).
	NONE,
	## A newer version exists; the player may skip it.
	OPTIONAL,
	## A newer version exists and the game should not continue without it.
	REQUIRED,
}

const Settings := preload("res://addons/app_update/settings.gd")
const ANDROID_SINGLETON := "GodotAppUpdate"
const LOOKUP_URL := "https://itunes.apple.com/lookup?bundleId=%s&country=%s&_=%d"
## Play's AppUpdateType values.
const TYPE_FLEXIBLE := 0
const TYPE_IMMEDIATE := 1
const INSTALL_STATUS_DOWNLOADING := 2
const INSTALL_STATUS_DOWNLOADED := 11
const INSTALL_STATUS_FAILED := 5

## Last answer of [method check_for_update] (empty before the first one).
var last_result: Dictionary = {}

var _android: Object = null
var _http: HTTPRequest = null
var _checking := false
var _ios_countries: PackedStringArray = []
var _ios_result: Dictionary = {}


func _ready() -> void:
	if Engine.has_singleton(ANDROID_SINGLETON):
		_android = Engine.get_singleton(ANDROID_SINGLETON)
		# Play answers on Android's UI thread: deferred, so the game always gets the signals on the
		# main thread.
		_android.update_info_received.connect(_on_android_info, CONNECT_DEFERRED)
		_android.update_info_failed.connect(_on_android_info_failed, CONNECT_DEFERRED)
		_android.install_state_changed.connect(_on_android_install_state, CONNECT_DEFERRED)
		_android.update_flow_finished.connect(_on_android_flow_finished, CONNECT_DEFERRED)
	if Settings.get_value(Settings.CHECK_ON_START):
		check_for_update.call_deferred()


## True on Android with the plugin in the export and on iOS with `app_update/ios/bundle_id` set.
func is_supported() -> bool:
	if _android != null:
		return true
	return OS.get_name() == "iOS" and _ios_bundle_id() != ""


## Asks the store whether a newer version exists. Answer: [signal update_checked]. Calls made while
## a check is running are ignored (the running one answers).
func check_for_update() -> void:
	if _checking:
		return
	if _android != null:
		_checking = true
		_android.check_update()
	elif OS.get_name() == "iOS":
		check_app_store()
	else:
		var result := _empty_result()
		result.error = "unsupported platform"
		_finish(result)


## iOS check, callable on any platform (handy to test the App Store answer from the editor or a
## desktop build). Uses `app_update/ios/bundle_id` and `app_update/ios/countries`.
func check_app_store() -> void:
	if _checking:
		return
	var result := _empty_result()
	result.platform = "ios"
	result.supported = true
	if _ios_bundle_id() == "":
		result.supported = false
		result.error = "app_update/ios/bundle_id is empty"
		_finish(result)
		return
	_checking = true
	_ios_result = result
	_ios_countries = _ios_country_list()
	_lookup_next_country()


## Starts what the last check recommends. Android: IMMEDIATE when REQUIRED, FLEXIBLE when OPTIONAL
## (falling back to the other type when Play does not allow it). iOS: opens the store page.
## Returns false when there is nothing to start.
func start_recommended_update() -> bool:
	if last_result.is_empty() or not last_result.available:
		return false
	if last_result.platform == "ios":
		return open_store()
	if last_result.kind == UpdateKind.REQUIRED:
		return start_immediate_update() or start_flexible_update()
	return start_flexible_update() or start_immediate_update()


## Android: Play's full-screen update; the app restarts when it is installed.
func start_immediate_update() -> bool:
	return _android != null and _android.start_update(TYPE_IMMEDIATE)


## Android: Play's confirmation dialog, then a background download ([signal download_progress],
## [signal update_downloaded]).
func start_flexible_update() -> bool:
	return _android != null and _android.start_update(TYPE_FLEXIBLE)


## Android FLEXIBLE: installs the downloaded update and restarts the app.
func complete_update() -> void:
	if _android != null:
		_android.complete_update()


## Opens the game's page in the store (Play Store or App Store). Returns false if there is no URL.
func open_store() -> bool:
	if _android != null:
		return _android.open_store_page()
	var url: String = last_result.get("store_url", "")
	if url == "":
		url = _ios_fallback_url()
	if url == "":
		return false
	return OS.shell_open(url) == OK


## The Android plugin singleton (null elsewhere). Gives access to the `fake_*` testing methods; see
## the README section "Testing".
func android_plugin() -> Object:
	return _android


## Compares two version strings by their numbers ("1.10.0" > "1.9.3"). Returns -1, 0 or 1.
static func compare_versions(a: String, b: String) -> int:
	var pa := _version_numbers(a)
	var pb := _version_numbers(b)
	for i in maxi(pa.size(), pb.size()):
		var x: int = pa[i] if i < pa.size() else 0
		var y: int = pb[i] if i < pb.size() else 0
		if x != y:
			return -1 if x < y else 1
	return 0


## First number that differs between [param from] and [param to]: "major", "minor", "patch" or
## "none" (also "patch" for any difference after the third number).
static func version_change(from: String, to: String) -> String:
	var pa := _version_numbers(from)
	var pb := _version_numbers(to)
	var names := ["major", "minor", "patch"]
	for i in maxi(pa.size(), pb.size()):
		var x: int = pa[i] if i < pa.size() else 0
		var y: int = pb[i] if i < pb.size() else 0
		if x != y:
			return names[mini(i, 2)]
	return "none"


# ── Android ─────────────────────────────────────────────────────────────────────────────────────


func _on_android_info(info: Dictionary) -> void:
	var result := _empty_result()
	result.platform = "android"
	result.supported = true
	result.available = bool(info.get("available", false))
	result.available_version_code = int(info.get("available_version_code", -1))
	result.current_version_code = int(info.get("current_version_code", -1))
	result.update_priority = int(info.get("update_priority", 0))
	result.staleness_days = int(info.get("staleness_days", -1))
	result.immediate_allowed = bool(info.get("immediate_allowed", false))
	result.flexible_allowed = bool(info.get("flexible_allowed", false))
	result.install_status = str(info.get("install_status_name", ""))
	result.raw = info
	result.kind = _android_kind(result, str(info.get("update_availability_name", "")))
	_checking = false
	_finish(result)
	if int(info.get("install_status", 0)) == INSTALL_STATUS_DOWNLOADED:
		update_downloaded.emit()


func _android_kind(result: Dictionary, availability: String) -> UpdateKind:
	if not result.available:
		return UpdateKind.NONE
	# An IMMEDIATE update the player left half-way: Play wants it resumed.
	if availability == "in_progress":
		return UpdateKind.REQUIRED
	var required := false
	var min_priority: int = Settings.get_value(Settings.REQUIRED_PRIORITY)
	if min_priority > 0 and result.update_priority >= min_priority:
		required = true
	var max_days: int = Settings.get_value(Settings.REQUIRED_STALENESS_DAYS)
	if max_days >= 0 and result.staleness_days >= max_days:
		required = true
	if required and result.immediate_allowed:
		return UpdateKind.REQUIRED
	if result.flexible_allowed or result.immediate_allowed:
		return UpdateKind.OPTIONAL
	return UpdateKind.NONE


func _on_android_info_failed(code: int, message: String) -> void:
	var result := _empty_result()
	result.platform = "android"
	result.supported = true
	result.error_code = code
	result.error = message
	_checking = false
	_finish(result)


func _on_android_install_state(state: Dictionary) -> void:
	install_state_changed.emit(state)
	match int(state.get("status", 0)):
		INSTALL_STATUS_DOWNLOADING:
			download_progress.emit(int(state.get("bytes_downloaded", 0)), int(state.get("total_bytes_to_download", 0)))
		INSTALL_STATUS_DOWNLOADED:
			update_downloaded.emit()
		INSTALL_STATUS_FAILED:
			install_failed.emit(int(state.get("error_code", 0)))


func _on_android_flow_finished(type: String, result: String) -> void:
	update_flow_finished.emit(type, result)


# ── iOS (App Store lookup) ──────────────────────────────────────────────────────────────────────


func _lookup_next_country() -> void:
	if _ios_countries.is_empty():
		var result := _ios_result
		if result.error == "":
			result.error = "app not found in the App Store"
		_checking = false
		_finish(result)
		return
	var country: String = _ios_countries[0]
	_ios_countries.remove_at(0)
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = 10.0
		add_child(_http)
		_http.request_completed.connect(_on_lookup_completed)
	var url := LOOKUP_URL % [_ios_bundle_id().uri_encode(), country.uri_encode(), Time.get_unix_time_from_system()]
	var err := _http.request(url)
	if err != OK:
		_ios_result.error = "HTTPRequest error %d" % err
		_ios_result.error_code = err
		_lookup_next_country()


func _on_lookup_completed(status: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var result := _ios_result
	if status != HTTPRequest.RESULT_SUCCESS or code != 200:
		result.error = "App Store lookup failed (result %d, HTTP %d)" % [status, code]
		result.error_code = code if status == HTTPRequest.RESULT_SUCCESS else status
		_lookup_next_country()
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary) or int(data.get("resultCount", 0)) < 1:
		_lookup_next_country()
		return
	var app: Dictionary = data.results[0]
	result.raw = app
	result.error = ""
	result.error_code = 0
	result.store_version = str(app.get("version", ""))
	result.store_url = str(app.get("trackViewUrl", ""))
	result.available = result.store_version != "" and compare_versions(result.store_version, result.current_version) > 0
	result.kind = _ios_kind(result) if result.available else UpdateKind.NONE
	_checking = false
	_finish(result)


func _ios_kind(result: Dictionary) -> UpdateKind:
	var when: String = Settings.get_value(Settings.IOS_REQUIRED_WHEN)
	var change := version_change(result.current_version, result.store_version)
	var levels := ["major", "minor", "patch"]
	if when in levels and change in levels and levels.find(change) <= levels.find(when):
		return UpdateKind.REQUIRED
	return UpdateKind.OPTIONAL


func _ios_bundle_id() -> String:
	return str(Settings.get_value(Settings.IOS_BUNDLE_ID)).strip_edges()


func _ios_country_list() -> PackedStringArray:
	var list := PackedStringArray()
	for c in str(Settings.get_value(Settings.IOS_COUNTRIES)).split(",", false):
		if c.strip_edges() != "":
			list.append(c.strip_edges().to_lower())
	if list.is_empty():
		list.append("us")
	return list


func _ios_fallback_url() -> String:
	var id := str(Settings.get_value(Settings.IOS_APP_STORE_ID)).strip_edges()
	return "https://apps.apple.com/app/id%s" % id if id != "" else ""


# ── Common ──────────────────────────────────────────────────────────────────────────────────────


## Keys of every [signal update_checked] result.
func _empty_result() -> Dictionary:
	return {
		## "android", "ios" or the OS name.
		"platform": OS.get_name().to_lower(),
		## False when this platform/build cannot check (no plugin, no bundle id…).
		"supported": false,
		## A newer version is in the store.
		"available": false,
		## UpdateKind: NONE, OPTIONAL or REQUIRED.
		"kind": UpdateKind.NONE,
		## `application/config/version` of the running game.
		"current_version": str(ProjectSettings.get_setting("application/config/version", "")),
		## iOS: version in the App Store.
		"store_version": "",
		## Android: versionCode Play offers, and the one running.
		"available_version_code": -1,
		"current_version_code": -1,
		## Android: priority set on the release (0–5) and days since Play has had the update (-1 = unknown).
		"update_priority": 0,
		"staleness_days": -1,
		## Android: which Play flows are allowed for this update.
		"immediate_allowed": false,
		"flexible_allowed": false,
		## Android: Play's install status name ("pending", "downloaded"…).
		"install_status": "",
		## iOS: App Store page of the game.
		"store_url": "",
		## Empty when the check worked.
		"error": "",
		"error_code": 0,
		## What the store answered, as is.
		"raw": {},
	}


func _finish(result: Dictionary) -> void:
	last_result = result
	# Always deferred: the answer arrives after check_for_update() returns on every platform, so
	# `await AppUpdate.update_checked` right after the call works too.
	update_checked.emit.call_deferred(result)


static func _version_numbers(v: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	for part in v.strip_edges().split("."):
		var digits := ""
		for ch in part:
			if ch >= "0" and ch <= "9":
				digits += ch
			else:
				break
		out.append(int(digits) if digits != "" else 0)
	return out
