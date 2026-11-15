package com.carriez.flutter_hbb

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ControlPanelHost(
    private val activity: Activity,
    messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler, DisplayManager.DisplayListener {

    companion object {
        const val CHANNEL = "is2l/panel"
        private const val CAPTURE_DISPLAY_NAME = "RustDeskVD"
        private const val MAX_RESHOW_ATTEMPTS = 5
        private const val RESHOW_DELAY_MS = 500L
    }

    private val logTag = "ControlPanelHost"
    private val channel = MethodChannel(messenger, CHANNEL)
    private val displayManager =
        activity.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
    private val handler = Handler(Looper.getMainLooper())
    private var presentation: ControlPanelPresentation? = null
    private var wanted = false
    private var started = false
    private var disposed = false
    private var reshowAttempts = 0
    private var lastState: Map<String, Any?> = emptyMap()
    private val reshow = Runnable { refresh() }

    init {
        channel.setMethodCallHandler(this)
        try {
            displayManager?.registerDisplayListener(this, handler)
        } catch (e: Exception) {
            Log.e(logTag, "registerDisplayListener failed", e)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> {
                stateOf(call.arguments)?.let { lastState = it }
                wanted = true
                reshowAttempts = 0
                refresh()
                result.success(presentation != null)
            }
            "hide" -> {
                wanted = false
                dismiss()
                result.success(true)
            }
            "update" -> {
                stateOf(call.arguments)?.let {
                    lastState = it
                    presentation?.update(it)
                }
                result.success(presentation != null)
            }
            "displays" -> {
                result.success(describeDisplays())
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    fun onActivityStart() {
        started = true
        reshowAttempts = 0
        refresh()
    }

    fun onActivityStop() {
        started = false
        dismiss()
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        wanted = false
        handler.removeCallbacks(reshow)
        try {
            displayManager?.unregisterDisplayListener(this)
        } catch (e: Exception) {
            Log.e(logTag, "unregisterDisplayListener failed", e)
        }
        dismiss()
        channel.setMethodCallHandler(null)
    }

    override fun onDisplayAdded(displayId: Int) {
        reshowAttempts = 0
        refresh()
    }

    override fun onDisplayRemoved(displayId: Int) {
        reshowAttempts = 0
        refresh()
    }

    override fun onDisplayChanged(displayId: Int) {
        refresh()
    }

    private fun stateOf(arguments: Any?): Map<String, Any?>? {
        val map = arguments as? Map<*, *> ?: return null
        val out = HashMap<String, Any?>()
        for ((k, v) in map) {
            if (k is String) out[k] = v
        }
        return out
    }

    private fun currentDisplayId(): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                activity.display?.displayId ?: Display.DEFAULT_DISPLAY
            } else {
                @Suppress("DEPRECATION")
                activity.windowManager.defaultDisplay.displayId
            }
        } catch (e: Exception) {
            Display.DEFAULT_DISPLAY
        }
    }

    private fun isUsable(display: Display, own: Int): Boolean {
        return display.displayId != own &&
            display.isValid &&
            display.name != CAPTURE_DISPLAY_NAME &&
            display.state != Display.STATE_OFF
    }

    private fun findDisplay(): Display? {
        val dm = displayManager ?: return null
        return try {
            val own = currentDisplayId()
            dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
                .firstOrNull { isUsable(it, own) }
                ?: dm.displays.firstOrNull { isUsable(it, own) }
        } catch (e: Exception) {
            Log.e(logTag, "findDisplay failed", e)
            null
        }
    }

    private fun describeDisplays(): List<Map<String, Any?>> {
        val dm = displayManager ?: return emptyList()
        return try {
            val own = currentDisplayId()
            val shown = presentation?.display?.displayId
            dm.displays.map {
                mapOf(
                    "id" to it.displayId,
                    "name" to it.name,
                    "flags" to it.flags,
                    "state" to it.state,
                    "valid" to it.isValid,
                    "current" to (it.displayId == own),
                    "presentation" to ((it.flags and Display.FLAG_PRESENTATION) != 0),
                    "panel" to (it.displayId == shown)
                )
            }
        } catch (e: Exception) {
            Log.e(logTag, "describeDisplays failed", e)
            emptyList()
        }
    }

    private fun refresh() {
        handler.removeCallbacks(reshow)
        if (disposed || !wanted || !started || activity.isFinishing || activity.isDestroyed) {
            dismiss()
            return
        }
        val target = findDisplay()
        if (target == null) {
            dismiss()
            return
        }
        val current = presentation
        if (current != null && current.isShowing &&
            current.display.displayId == target.displayId) {
            return
        }
        dismiss()
        try {
            val created = ControlPanelPresentation(activity, target, lastState) { id, args ->
                sendAction(id, args)
            }
            created.setOnDismissListener {
                if (presentation === created) {
                    presentation = null
                    if (wanted && started && !disposed &&
                        reshowAttempts < MAX_RESHOW_ATTEMPTS) {
                        reshowAttempts++
                        handler.postDelayed(reshow, RESHOW_DELAY_MS)
                    }
                }
            }
            created.show()
            presentation = created
        } catch (e: Exception) {
            Log.e(logTag, "Failed to show the control panel on display ${target.displayId}", e)
            presentation = null
        }
    }

    private fun dismiss() {
        val current = presentation ?: return
        presentation = null
        try {
            current.dismiss()
        } catch (e: Exception) {
            Log.e(logTag, "Failed to dismiss the control panel", e)
        }
    }

    private fun sendAction(id: String, args: Map<String, Any?>) {
        if (disposed) return
        val payload = HashMap<String, Any?>(args)
        payload["id"] = id
        handler.post {
            if (disposed) return@post
            try {
                channel.invokeMethod("action", payload)
            } catch (e: Exception) {
                Log.e(logTag, "Failed to send action $id", e)
            }
        }
    }
}
