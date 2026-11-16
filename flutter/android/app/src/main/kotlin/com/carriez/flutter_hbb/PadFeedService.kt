package com.carriez.flutter_hbb

import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import java.security.MessageDigest

class PadFeedService : Service() {
    companion object {
        const val ACTION = "com.isleep2late.remote.PAD_FEED"
        val SENDER_PACKAGES = setOf(
            "com.controllerlog.gcbridge",
            "com.controllerlog.gcbridge.dev"
        )
        val SENDER_CERT_SHA256 = setOf(
            "1e08a903aef9c3a721510b64ec764d01d3d094eb954161b62544ea8f187b5953"
        )
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
        } ?: return false
        if (names.any { SENDER_PACKAGES.contains(it) && pinned(it) }) {
            trustedUid = uid
            return true
        }
        return false
    }

    private fun pinned(name: String): Boolean {
        val signers = try {
            signersOf(name)
        } catch (e: Exception) {
            null
        }
        if (signers == null || signers.isEmpty()) return false
        return signers.all { SENDER_CERT_SHA256.contains(sha256(it)) }
    }

    @Suppress("DEPRECATION")
    private fun signersOf(name: String): Array<Signature>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageManager.getPackageInfo(name, PackageManager.GET_SIGNING_CERTIFICATES)
            return info.signingInfo?.apkContentsSigners
        }
        return packageManager.getPackageInfo(name, PackageManager.GET_SIGNATURES).signatures
    }

    private fun sha256(signature: Signature): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }
}
