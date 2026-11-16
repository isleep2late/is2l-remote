package com.carriez.flutter_hbb

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger

class PadFeedService : Service() {
    companion object {
        const val ACTION = "com.isleep2late.remote.PAD_FEED"
        const val SENDER_PACKAGE = "com.controllerlog.gcbridge"
        const val MSG_PAD_STATE = 1
        const val MSG_PAD_GONE = 2
        const val AXIS_COUNT = 6
    }

    private var trustedUid = -1
    private var live = false

    private val handler = Handler(Looper.getMainLooper()) { msg ->
        handle(msg)
        true
    }
    private val messenger = Messenger(handler)

    override fun onBind(intent: Intent?): IBinder? {
        return messenger.binder
    }

    override fun onUnbind(intent: Intent?): Boolean {
        gone()
        return false
    }

    override fun onDestroy() {
        gone()
        super.onDestroy()
    }

    private fun handle(msg: Message) {
        if (!trusted(msg.sendingUid)) return
        when (msg.what) {
            MSG_PAD_STATE -> {
                val data = msg.peekData() ?: return
                if (data.getInt("v", 0) < 1) return
                val axes = data.getIntArray("axes") ?: return
                if (axes.size < AXIS_COUNT) return
                live = true
                GamepadCapture.externalPad(
                    data.getInt("buttons", 0),
                    axes.copyOf(AXIS_COUNT),
                    data.getString("name") ?: ""
                )
            }
            MSG_PAD_GONE -> gone()
        }
    }

    private fun gone() {
        if (!live) return
        live = false
        GamepadCapture.externalPadGone()
    }

    private fun trusted(uid: Int): Boolean {
        if (uid < 0) return false
        if (uid == trustedUid) return true
        val names = try {
            packageManager.getPackagesForUid(uid)
        } catch (e: Exception) {
            null
        }
        if (names != null && names.contains(SENDER_PACKAGE)) {
            trustedUid = uid
            return true
        }
        return false
    }
}
