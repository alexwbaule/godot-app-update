@tool
extends RefCounted
## Project settings of the App Update addon (Project → Project Settings → App Update).
## The runtime reads them with the same defaults, so a game that never opened the editor with the
## plugin enabled still works.

const REQUIRED_PRIORITY := "app_update/android/required_priority"
const REQUIRED_STALENESS_DAYS := "app_update/android/required_staleness_days"
const IOS_BUNDLE_ID := "app_update/ios/bundle_id"
const IOS_APP_STORE_ID := "app_update/ios/app_store_id"
const IOS_COUNTRIES := "app_update/ios/countries"
const IOS_REQUIRED_WHEN := "app_update/ios/required_when"
const CHECK_ON_START := "app_update/general/check_on_start"

## [name, default, type, hint, hint_string]
const ALL := [
	[CHECK_ON_START, false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	[REQUIRED_PRIORITY, 4, TYPE_INT, PROPERTY_HINT_RANGE, "0,6"],
	[REQUIRED_STALENESS_DAYS, -1, TYPE_INT, PROPERTY_HINT_RANGE, "-1,365,1,or_greater"],
	[IOS_BUNDLE_ID, "", TYPE_STRING, PROPERTY_HINT_PLACEHOLDER_TEXT, "com.example.mygame"],
	[IOS_APP_STORE_ID, "", TYPE_STRING, PROPERTY_HINT_PLACEHOLDER_TEXT, "1234567890"],
	[IOS_COUNTRIES, "", TYPE_STRING, PROPERTY_HINT_PLACEHOLDER_TEXT, "br,us"],
	[IOS_REQUIRED_WHEN, "minor", TYPE_STRING, PROPERTY_HINT_ENUM, "major,minor,patch,never"],
]


static func register() -> void:
	for entry in ALL:
		var name: String = entry[0]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, entry[1])
		ProjectSettings.set_initial_value(name, entry[1])
		ProjectSettings.set_as_basic(name, true)
		ProjectSettings.add_property_info({
			"name": name, "type": entry[2], "hint": entry[3], "hint_string": entry[4],
		})


static func get_value(name: String) -> Variant:
	for entry in ALL:
		if entry[0] == name:
			return ProjectSettings.get_setting(name, entry[1])
	return ProjectSettings.get_setting(name)
