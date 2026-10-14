extends Control
## App Update demo: every addon call has a button, and every signal is written to the log.
##
## On a phone the "real" buttons talk to Google Play: they only find an update when the app was
## installed by Play (internal testing track, for example). The "Fake" section uses Play's
## FakeAppUpdateManager and works on any device.

var _log: RichTextLabel
var _fake_code: SpinBox
var _fake_priority: SpinBox
var _fake_days: SpinBox
var _bytes := 0


func _ready() -> void:
	AppUpdate.update_checked.connect(_on_update_checked)
	AppUpdate.download_progress.connect(func(done: int, total: int): _say("download_progress %d / %d" % [done, total]))
	AppUpdate.update_downloaded.connect(func(): _say("[b]update_downloaded[/b] → press \"Complete update\""))
	AppUpdate.install_failed.connect(func(code: int): _say("[color=red]install_failed %d[/color]" % code))
	AppUpdate.install_state_changed.connect(func(state: Dictionary): _say("install_state_changed %s" % state.status_name))
	AppUpdate.update_flow_finished.connect(func(type: String, result: String): _say("update_flow_finished %s → %s" % [type, result]))
	_build_ui()
	_say("platform %s · supported %s · version %s" % [OS.get_name(), AppUpdate.is_supported(), ProjectSettings.get_setting("application/config/version")])


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_title(box, "App Update")
	_row(box, [
		["Check for update", AppUpdate.check_for_update],
		["Recommended", func(): _say("start_recommended_update → %s" % AppUpdate.start_recommended_update())],
	])
	_row(box, [
		["Flexible", func(): _say("start_flexible_update → %s" % AppUpdate.start_flexible_update())],
		["Immediate", func(): _say("start_immediate_update → %s" % AppUpdate.start_immediate_update())],
		["Complete update", AppUpdate.complete_update],
	])
	_row(box, [
		["Open store", func(): _say("open_store → %s" % AppUpdate.open_store())],
		["App Store lookup", AppUpdate.check_app_store],
	])

	_title(box, "Fake (Android, no Play needed)")
	var fields := HBoxContainer.new()
	box.add_child(fields)
	_fake_code = _spin(fields, "versionCode", 1, 999999, 2)
	_fake_priority = _spin(fields, "priority", 0, 5, 5)
	_fake_days = _spin(fields, "days", -1, 365, 3)
	_row(box, [
		["Fake ON + update", _fake_on],
		["Fake OFF", func(): _plugin_call("set_fake_mode", [false])],
		["No update", func(): _plugin_call("fake_set_update_not_available")],
	])
	_row(box, [
		["User accepts", func(): _plugin_call("fake_user_accepts_update")],
		["User rejects", func(): _plugin_call("fake_user_rejects_update")],
	])
	_row(box, [
		["Download starts", func(): _bytes = 0; _plugin_call("fake_download_starts", [1000])],
		["+250 bytes", func(): _bytes += 250; _plugin_call("fake_set_bytes_downloaded", [_bytes])],
		["Download done", func(): _plugin_call("fake_download_completes")],
	])
	_row(box, [
		["Install done", func(): _plugin_call("fake_install_completes")],
		["Download fails", func(): _plugin_call("fake_download_fails")],
	])

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 18)
	box.add_child(_log)


func _fake_on() -> void:
	if _plugin_call("set_fake_mode", [true]) == null and AppUpdate.android_plugin() == null:
		return
	_plugin_call("fake_set_update_available", [int(_fake_code.value), -1])
	_plugin_call("fake_set_update_priority", [int(_fake_priority.value)])
	_plugin_call("fake_set_staleness_days", [int(_fake_days.value)])
	_say("fake mode on: versionCode %d, priority %d, %d days → press \"Check for update\"" % [_fake_code.value, _fake_priority.value, _fake_days.value])


func _plugin_call(method: String, args: Array = []) -> Variant:
	var plugin := AppUpdate.android_plugin()
	if plugin == null:
		_say("[color=orange]%s: Android plugin not present on %s[/color]" % [method, OS.get_name()])
		return null
	var value: Variant = plugin.callv(method, args)
	_say("%s%s%s" % [method, str(args) if not args.is_empty() else "", " → %s" % value if value != null else ""])
	return value


func _on_update_checked(result: Dictionary) -> void:
	var kind: String = AppUpdate.UpdateKind.keys()[result.kind]
	if result.error != "":
		_say("[color=red]update_checked: error %s (%s)[/color]" % [result.error, result.error_code])
		return
	if result.platform == "ios":
		_say("[b]update_checked[/b] %s · store %s · current %s · %s" % [kind, result.store_version, result.current_version, result.store_url])
	else:
		_say("[b]update_checked[/b] %s · code %d → %d · priority %d · %d days · immediate %s · flexible %s" % [
			kind, result.current_version_code, result.available_version_code, result.update_priority,
			result.staleness_days, result.immediate_allowed, result.flexible_allowed])


func _say(text: String) -> void:
	print_rich(text)
	if _log:
		_log.append_text(text + "\n")


func _title(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 28)
	parent.add_child(label)


func _row(parent: Control, buttons: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	for b in buttons:
		var button := Button.new()
		button.text = b[0]
		button.custom_minimum_size.y = 64
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(b[1])
		row.add_child(button)


func _spin(parent: Control, label: String, lo: int, hi: int, value: int) -> SpinBox:
	var l := Label.new()
	l.text = label
	parent.add_child(l)
	var spin := SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spin)
	return spin
