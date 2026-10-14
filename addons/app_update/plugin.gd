@tool
extends EditorPlugin
## Editor side of the App Update addon: registers the `AppUpdate` autoload, the project settings
## under `app_update/…` and the Android export plugin (AAR + Play In-App Updates dependency).

const AUTOLOAD_NAME := "AppUpdate"
const AUTOLOAD_PATH := "res://addons/app_update/app_update.gd"
const Settings := preload("res://addons/app_update/settings.gd")

var _export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	Settings.register()
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


class AndroidExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "GodotAppUpdate"
	## Must match the `implementation` dependency in android/plugin/build.gradle.kts.
	const ANDROID_DEPENDENCIES := ["com.google.android.play:app-update:2.1.0"]

	func _get_name() -> String:
		return PLUGIN_NAME

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		if debug:
			return PackedStringArray(["app_update/bin/debug/%s-debug.aar" % PLUGIN_NAME])
		return PackedStringArray(["app_update/bin/release/%s-release.aar" % PLUGIN_NAME])

	func _get_android_dependencies(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(ANDROID_DEPENDENCIES)
