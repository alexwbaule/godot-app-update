package io.github.alexwbaule.godotappupdate

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.google.android.play.core.appupdate.AppUpdateInfo
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.appupdate.testing.FakeAppUpdateManager
import com.google.android.play.core.install.InstallState
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.ActivityResult
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallErrorCode
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import com.google.android.gms.tasks.Task
import org.godotengine.godot.Dictionary
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot

/**
 * Google Play In-App Updates for Godot 4 (Android plugin v2).
 *
 * Every call is asynchronous: the result comes back as a signal. The GDScript side
 * (`addons/app_update/app_update.gd`, autoload `AppUpdate`) wraps this singleton and adds the
 * update policy and the iOS App Store check; games normally use that and never call this directly.
 *
 * Flow:
 *  1. [check_update] → `update_info_received(info)` or `update_info_failed(code, message)`.
 *  2. [start_update] (FLEXIBLE or IMMEDIATE) with the info of the last check.
 *     → `update_flow_finished(type, result)` when the Play dialog closes.
 *  3. FLEXIBLE only: `install_state_changed(state)` reports the download; when the status is
 *     DOWNLOADED, call [complete_update] to install and restart the app.
 *
 * Testing without Play: [set_fake_mode] swaps in Play's FakeAppUpdateManager and the `fake_*`
 * methods drive it (update available, user accepts, download progress…).
 */
@Suppress("FunctionName", "unused")
class GodotAppUpdate(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val TAG = "GodotAppUpdate"
        private const val REQUEST_CODE = 0x41_55 // "AU"

        private const val RESULT_NAME_OK = "ok"
        private const val RESULT_NAME_CANCELED = "canceled"
        private const val RESULT_NAME_FAILED = "failed"

        fun availabilityName(value: Int): String = when (value) {
            UpdateAvailability.UPDATE_NOT_AVAILABLE -> "not_available"
            UpdateAvailability.UPDATE_AVAILABLE -> "available"
            UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS -> "in_progress"
            else -> "unknown"
        }

        fun installStatusName(value: Int): String = when (value) {
            InstallStatus.PENDING -> "pending"
            InstallStatus.DOWNLOADING -> "downloading"
            InstallStatus.DOWNLOADED -> "downloaded"
            InstallStatus.INSTALLING -> "installing"
            InstallStatus.INSTALLED -> "installed"
            InstallStatus.FAILED -> "failed"
            InstallStatus.CANCELED -> "canceled"
            InstallStatus.REQUIRES_UI_INTENT -> "requires_ui_intent"
            else -> "unknown"
        }

        fun typeName(type: Int): String = when (type) {
            AppUpdateType.FLEXIBLE -> "flexible"
            AppUpdateType.IMMEDIATE -> "immediate"
            else -> "unknown"
        }
    }

    private var manager: AppUpdateManager? = null
    private var fake: FakeAppUpdateManager? = null
    private var lastInfo: AppUpdateInfo? = null
    private var listenerRegistered = false

    /** Type of the flow started with [start_update] while it is still on screen (-1 = none). */
    private var flowType = -1
    /** True after an IMMEDIATE flow was started: Play asks us to resume it when the app comes back. */
    private var immediateRequested = false

    private val installListener = InstallStateUpdatedListener { state -> emitInstallState(state) }

    override fun getPluginName(): String = BuildConfig.GODOT_PLUGIN_NAME

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("update_info_received", Dictionary::class.java),
        SignalInfo("update_info_failed", Int::class.javaObjectType, String::class.java),
        SignalInfo("install_state_changed", Dictionary::class.java),
        SignalInfo("update_flow_finished", String::class.java, String::class.java),
    )

    // ── Godot API ────────────────────────────────────────────────────────────────────────────

    /** Asks Play whether an update exists. Answer: `update_info_received` / `update_info_failed`. */
    @UsedByGodot
    fun check_update() {
        val mgr = manager() ?: run {
            emitSignal("update_info_failed", -100, "no activity")
            return
        }
        runCatching { mgr.appUpdateInfo }
            .onSuccess { task -> handleInfoTask(task) }
            .onFailure { error -> emitSignal("update_info_failed", errorCode(error), error.toString()) }
    }

    /**
     * Starts the Play update UI. [type]: 0 = FLEXIBLE, 1 = IMMEDIATE (same values as Play's
     * AppUpdateType). Uses the info of the last [check_update]; returns false when there is no
     * update to start, the type is not allowed, or the flow could not be opened.
     * When it returns true, `update_flow_finished(type_name, result)` follows.
     */
    @UsedByGodot
    fun start_update(type: Int): Boolean {
        val mgr = manager() ?: return false
        val info = lastInfo ?: return false
        val act = activity ?: return false
        val availability = info.updateAvailability()
        if (availability != UpdateAvailability.UPDATE_AVAILABLE &&
            availability != UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
        ) {
            return false
        }
        val options = AppUpdateOptions.newBuilder(type).build()
        if (!info.isUpdateTypeAllowed(options)) {
            return false
        }
        if (type == AppUpdateType.FLEXIBLE) {
            registerListener(mgr)
        }
        return try {
            val started = mgr.startUpdateFlowForResult(info, act, options, REQUEST_CODE)
            if (started) {
                flowType = type
                if (type == AppUpdateType.IMMEDIATE) {
                    immediateRequested = true
                }
                // The info can only start one flow; force a new check for the next one.
                lastInfo = null
            }
            started
        } catch (error: Exception) {
            Log.e(TAG, "start_update failed", error)
            false
        }
    }

    /** FLEXIBLE: installs the downloaded update and restarts the app. */
    @UsedByGodot
    fun complete_update() {
        manager()?.completeUpdate()
    }

    /** Version code of the running app (what Play compares with `available_version_code`). */
    @UsedByGodot
    fun get_current_version_code(): Long {
        val act = activity ?: return -1
        return try {
            val info = if (Build.VERSION.SDK_INT >= 33) {
                act.packageManager.getPackageInfo(act.packageName, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                act.packageManager.getPackageInfo(act.packageName, 0)
            }
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        } catch (error: Exception) {
            -1
        }
    }

    /**
     * Opens the app's Play Store page (fallback when the in-app flow is not possible, e.g. the app
     * was not installed by Play). Returns false if no store app could open it.
     */
    @UsedByGodot
    fun open_store_page(): Boolean {
        val act = activity ?: return false
        val pkg = act.packageName
        val uris = listOf("market://details?id=$pkg", "https://play.google.com/store/apps/details?id=$pkg")
        for (uri in uris) {
            try {
                val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(uri))
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                act.startActivity(intent)
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    // ── Fake mode (testing without Play) ─────────────────────────────────────────────────────

    /**
     * true: use Play's FakeAppUpdateManager (no network, no Play account needed). Start it with
     * [fake_set_update_available] and drive it with the other `fake_*` methods. false: back to Play.
     */
    @UsedByGodot
    fun set_fake_mode(enabled: Boolean) {
        val current = manager
        if (current != null && listenerRegistered) {
            current.unregisterListener(installListener)
            listenerRegistered = false
        }
        lastInfo = null
        flowType = -1
        immediateRequested = false
        val act = activity
        if (enabled && act != null) {
            val f = FakeAppUpdateManager(act)
            fake = f
            manager = f
        } else {
            fake = null
            manager = null
        }
    }

    @UsedByGodot
    fun is_fake_mode(): Boolean = fake != null

    /** [allowed_type]: -1 = both, 0 = only FLEXIBLE, 1 = only IMMEDIATE. */
    @UsedByGodot
    fun fake_set_update_available(version_code: Int, allowed_type: Int) {
        val f = fake ?: return
        if (allowed_type < 0) f.setUpdateAvailable(version_code) else f.setUpdateAvailable(version_code, allowed_type)
    }

    @UsedByGodot
    fun fake_set_update_not_available() {
        fake?.setUpdateNotAvailable()
    }

    @UsedByGodot
    fun fake_set_update_priority(priority: Int) {
        fake?.setUpdatePriority(priority)
    }

    /** [days] < 0 clears it (Play reports "unknown"). */
    @UsedByGodot
    fun fake_set_staleness_days(days: Int) {
        fake?.setClientVersionStalenessDays(if (days < 0) null else days)
    }

    @UsedByGodot
    fun fake_user_accepts_update() {
        val f = fake ?: return
        f.userAcceptsUpdate()
        finishFlow(Activity.RESULT_OK)
    }

    @UsedByGodot
    fun fake_user_rejects_update() {
        val f = fake ?: return
        f.userRejectsUpdate()
        finishFlow(Activity.RESULT_CANCELED)
    }

    @UsedByGodot
    fun fake_download_starts(total_bytes: Int) {
        val f = fake ?: return
        f.setTotalBytesToDownload(total_bytes.toLong())
        f.downloadStarts()
    }

    @UsedByGodot
    fun fake_set_bytes_downloaded(bytes: Int) {
        fake?.setBytesDownloaded(bytes.toLong())
    }

    @UsedByGodot
    fun fake_download_completes() {
        fake?.downloadCompletes()
    }

    @UsedByGodot
    fun fake_download_fails() {
        fake?.downloadFails()
    }

    @UsedByGodot
    fun fake_user_cancels_download() {
        fake?.userCancelsDownload()
    }

    @UsedByGodot
    fun fake_install_completes() {
        fake?.installCompletes()
    }

    @UsedByGodot
    fun fake_install_fails() {
        fake?.installFails()
    }

    /** IMMEDIATE flows have no Play UI in fake mode; this tells whether one would be on screen. */
    @UsedByGodot
    fun fake_is_immediate_flow_visible(): Boolean = fake?.isImmediateFlowVisible ?: false

    /** FLEXIBLE: whether the Play confirmation dialog would be on screen. */
    @UsedByGodot
    fun fake_is_confirmation_dialog_visible(): Boolean = fake?.isConfirmationDialogVisible ?: false

    // ── Activity lifecycle ───────────────────────────────────────────────────────────────────

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CODE) {
            finishFlow(resultCode)
        }
    }

    override fun onMainResume() {
        val mgr = manager ?: return
        // Play's guidance: an IMMEDIATE update that was interrupted (app sent to background) must be
        // resumed when the app comes back; a FLEXIBLE update that finished downloading while the app
        // was away must be reported so the game can offer to install it.
        runCatching { mgr.appUpdateInfo }.getOrNull()?.addOnSuccessListener { info ->
            if (immediateRequested &&
                info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
            ) {
                val act = activity ?: return@addOnSuccessListener
                try {
                    mgr.startUpdateFlowForResult(
                        info, act, AppUpdateOptions.newBuilder(AppUpdateType.IMMEDIATE).build(), REQUEST_CODE
                    )
                    flowType = AppUpdateType.IMMEDIATE
                } catch (error: Exception) {
                    Log.e(TAG, "resume of immediate update failed", error)
                }
            } else if (info.installStatus() == InstallStatus.DOWNLOADED) {
                emitSignal("install_state_changed", installStateDict(
                    InstallStatus.DOWNLOADED, info.bytesDownloaded(), info.totalBytesToDownload(),
                    InstallErrorCode.NO_ERROR, info.packageName()
                ))
            }
        }
    }

    override fun onMainDestroy() {
        if (listenerRegistered) {
            manager?.unregisterListener(installListener)
            listenerRegistered = false
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────────────────────

    private fun manager(): AppUpdateManager? {
        manager?.let { return it }
        val act = activity ?: return null
        return AppUpdateManagerFactory.create(act).also { manager = it }
    }

    private fun registerListener(mgr: AppUpdateManager) {
        if (!listenerRegistered) {
            mgr.registerListener(installListener)
            listenerRegistered = true
        }
    }

    private fun handleInfoTask(task: Task<AppUpdateInfo>) {
        task.addOnSuccessListener { info ->
            lastInfo = info
            emitSignal("update_info_received", infoDict(info))
        }.addOnFailureListener { error ->
            lastInfo = null
            emitSignal("update_info_failed", errorCode(error), error.toString())
        }
    }

    private fun finishFlow(resultCode: Int) {
        val type = flowType
        flowType = -1
        val result = when (resultCode) {
            Activity.RESULT_OK -> RESULT_NAME_OK
            Activity.RESULT_CANCELED -> RESULT_NAME_CANCELED
            ActivityResult.RESULT_IN_APP_UPDATE_FAILED -> RESULT_NAME_FAILED
            else -> RESULT_NAME_FAILED
        }
        if (type == AppUpdateType.IMMEDIATE && result != RESULT_NAME_OK) {
            // The user left the IMMEDIATE flow: don't force it again on resume; the game decides.
            immediateRequested = false
        }
        emitSignal("update_flow_finished", typeName(type), result)
    }

    private fun emitInstallState(state: InstallState) {
        emitSignal("install_state_changed", installStateDict(
            state.installStatus(), state.bytesDownloaded(), state.totalBytesToDownload(),
            state.installErrorCode(), state.packageName()
        ))
    }

    private fun installStateDict(status: Int, downloaded: Long, total: Long, error: Int, pkg: String): Dictionary {
        val dict = Dictionary()
        dict["status"] = status
        dict["status_name"] = installStatusName(status)
        dict["bytes_downloaded"] = downloaded
        dict["total_bytes_to_download"] = total
        dict["error_code"] = error
        dict["package_name"] = pkg
        return dict
    }

    private fun infoDict(info: AppUpdateInfo): Dictionary {
        val availability = info.updateAvailability()
        val dict = Dictionary()
        dict["update_availability"] = availability
        dict["update_availability_name"] = availabilityName(availability)
        dict["available"] = availability == UpdateAvailability.UPDATE_AVAILABLE ||
            availability == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
        dict["available_version_code"] = info.availableVersionCode()
        dict["current_version_code"] = get_current_version_code()
        dict["update_priority"] = info.updatePriority()
        dict["staleness_days"] = info.clientVersionStalenessDays() ?: -1
        dict["immediate_allowed"] = info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE)
        dict["flexible_allowed"] = info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)
        dict["install_status"] = info.installStatus()
        dict["install_status_name"] = installStatusName(info.installStatus())
        dict["bytes_downloaded"] = info.bytesDownloaded()
        dict["total_bytes_to_download"] = info.totalBytesToDownload()
        dict["package_name"] = info.packageName()
        dict["fake"] = fake != null
        return dict
    }

    /** Play's InstallException carries an error code; anything else is reported as -100. */
    private fun errorCode(error: Throwable): Int =
        (error as? com.google.android.play.core.install.InstallException)?.errorCode ?: -100
}
