package com.carriez.flutter_hbb

import android.app.Activity
import android.app.Presentation
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.hypot
import kotlin.math.max

class ControlPanelPresentation(
    private val activity: Activity,
    display: Display,
    initialState: Map<String, Any?>,
    private val onAction: (String, Map<String, Any?>) -> Unit
) : Presentation(activity, display) {

    private val colorBackground = Color.rgb(0x12, 0x14, 0x18)
    private val colorSurface = Color.rgb(0x25, 0x29, 0x31)
    private val colorActive = Color.rgb(0x00, 0x71, 0xFF)
    private val colorDanger = Color.rgb(0xC6, 0x28, 0x28)
    private val colorText = Color.WHITE
    private val colorMuted = Color.rgb(0xA0, 0xA8, 0xB4)
    private val disconnectLabel = "Disconnect"
    private val disconnectConfirmLabel = "Tap again"
    private val disconnectConfirmMs = 3000L

    private val handler = Handler(Looper.getMainLooper())
    private var state: Map<String, Any?> = initialState
    private var disconnectArmed = false
    private val disarmDisconnect = Runnable { setDisconnectArmed(false) }

    private var peerView: TextView? = null
    private var statsView: TextView? = null
    private var disconnectButton: Button? = null
    private var keyboardButton: Button? = null
    private var viewStyleButton: Button? = null
    private var fpsView: TextView? = null
    private var qualityView: TextView? = null
    private var codecButton: Button? = null
    private var gamepadButton: Button? = null
    private var profileView: TextView? = null
    private var profilePrevButton: Button? = null
    private var profileNextButton: Button? = null
    private var mappingButton: Button? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setCancelable(false)
        window?.addFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
        window?.setBackgroundDrawable(GradientDrawable().apply { setColor(colorBackground) })
        setContentView(buildContent())
        render()
    }

    override fun onStop() {
        handler.removeCallbacks(disarmDisconnect)
        super.onStop()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        return activity.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        if ((ev.source and InputDevice.SOURCE_CLASS_JOYSTICK) != 0) {
            return activity.dispatchGenericMotionEvent(ev)
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    fun update(newState: Map<String, Any?>) {
        state = newState
        render()
    }

    private fun dp(value: Float): Int {
        return (value * context.resources.displayMetrics.density + 0.5f).toInt()
    }

    private fun text(key: String): String {
        return state[key]?.toString() ?: ""
    }

    private fun flag(key: String): Boolean {
        return state[key] == true
    }

    private fun send(id: String, args: Map<String, Any?> = emptyMap()) {
        onAction(id, args)
    }

    private fun roundedBackground(color: Int): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(8f).toFloat()
        }
    }

    private fun makeLabel(sizeSp: Float, color: Int): TextView {
        return TextView(context).apply {
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
    }

    private fun makeButton(label: String, onClick: () -> Unit): Button {
        return Button(context).apply {
            text = label
            setAllCaps(false)
            setTextColor(colorText)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            minHeight = dp(52f)
            minimumHeight = dp(52f)
            minWidth = 0
            minimumWidth = 0
            setPadding(dp(4f), 0, dp(4f), 0)
            background = roundedBackground(colorSurface)
            stateListAnimator = null
            setOnClickListener { onClick() }
        }
    }

    private fun makeRow(vararg views: View): LinearLayout {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        for (view in views) {
            val params = LinearLayout.LayoutParams(0, dp(52f), 1f)
            params.setMargins(dp(3f), dp(3f), dp(3f), dp(3f))
            row.addView(view, params)
        }
        return row
    }

    private fun buildContent(): View {
        val metrics = context.resources.displayMetrics
        val wide = metrics.widthPixels > metrics.heightPixels * 3 / 2

        val peer = makeLabel(18f, colorText).apply { gravity = Gravity.START or Gravity.CENTER_VERTICAL }
        val stats = makeLabel(14f, colorMuted).apply { gravity = Gravity.END or Gravity.CENTER_VERTICAL }
        peerView = peer
        statsView = stats
        val header = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(6f), dp(2f), dp(6f), dp(2f))
            addView(peer, LinearLayout.LayoutParams(0, dp(36f), 1f))
            addView(stats, LinearLayout.LayoutParams(0, dp(36f), 1f))
        }

        val disconnect = makeButton(disconnectLabel) { onDisconnectTapped() }
        disconnect.background = roundedBackground(colorDanger)
        disconnectButton = disconnect
        val keyboard = makeButton("Keyboard") { send("toggle_keyboard") }
        keyboardButton = keyboard
        val viewStyle = makeButton("Fit") { send("toggle_fullscreen") }
        viewStyleButton = viewStyle
        val sessionRowA = makeRow(
            disconnect,
            keyboard,
            makeButton("Esc") { send("send_esc") }
        )
        val sessionRowB = makeRow(
            makeButton("Ctrl+Alt+Del") { send("send_ctrl_alt_del") },
            makeButton("Alt+Tab") { send("send_alt_tab") },
            viewStyle
        )

        val fps = makeLabel(14f, colorText)
        fpsView = fps
        val quality = makeLabel(14f, colorText)
        qualityView = quality
        val codec = makeButton("Codec") { send("codec_next") }
        codecButton = codec
        val fpsRow = makeRow(
            makeButton("FPS -") { send("fps_down") },
            fps,
            makeButton("FPS +") { send("fps_up") }
        )
        val qualityRow = makeRow(
            makeButton("Quality -") { send("quality_down") },
            quality,
            makeButton("Quality +") { send("quality_up") }
        )
        val codecRow = makeRow(codec)

        val gamepad = makeButton("Controller") { send("toggle_gamepad") }
        gamepadButton = gamepad
        val mapping = makeButton("Open mapping") { send("open_mapping") }
        mappingButton = mapping
        val profile = makeLabel(14f, colorText)
        profileView = profile
        val profilePrev = makeButton("<") { send("profile_prev") }
        val profileNext = makeButton(">") { send("profile_next") }
        profilePrevButton = profilePrev
        profileNextButton = profileNext
        val gamepadRow = makeRow(gamepad, mapping)
        val profileRow = makeRow(profilePrev, profile, profileNext)
        (profile.layoutParams as? LinearLayout.LayoutParams)?.weight = 2f

        val controls = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(header)
            addView(sessionRowA)
            addView(sessionRowB)
            addView(fpsRow)
            addView(qualityRow)
            addView(codecRow)
            addView(gamepadRow)
            addView(profileRow)
        }
        val scroll = ScrollView(context).apply {
            isFillViewport = false
            addView(
                controls,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
        }

        val pad = TouchPadView(context) { id, args -> send(id, args) }
        pad.background = roundedBackground(colorSurface)

        val root = LinearLayout(context).apply {
            orientation = if (wide) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
            setBackgroundColor(colorBackground)
            setPadding(dp(6f), dp(6f), dp(6f), dp(6f))
        }
        val padParams: LinearLayout.LayoutParams
        if (wide) {
            root.addView(scroll, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            padParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f)
        } else {
            root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 3f))
            padParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 2f)
        }
        padParams.setMargins(dp(3f), dp(3f), dp(3f), dp(3f))
        root.addView(pad, padParams)
        return root
    }

    private fun onDisconnectTapped() {
        if (disconnectArmed) {
            setDisconnectArmed(false)
            send("disconnect")
        } else {
            setDisconnectArmed(true)
            handler.postDelayed(disarmDisconnect, disconnectConfirmMs)
        }
    }

    private fun setDisconnectArmed(armed: Boolean) {
        handler.removeCallbacks(disarmDisconnect)
        disconnectArmed = armed
        disconnectButton?.text = if (armed) disconnectConfirmLabel else disconnectLabel
    }

    private fun setEnabled(view: View?, enabled: Boolean) {
        view?.isEnabled = enabled
        view?.alpha = if (enabled) 1f else 0.4f
    }

    private fun setActive(button: Button?, active: Boolean) {
        button?.background = roundedBackground(if (active) colorActive else colorSurface)
    }

    private fun render() {
        peerView?.text = text("peer")
        val stats = ArrayList<String>()
        if (text("fps").isNotEmpty()) stats.add("${text("fps")} fps")
        if (text("codec").isNotEmpty()) stats.add(text("codec"))
        if (text("delay").isNotEmpty()) stats.add("${text("delay")} ms")
        statsView?.text = stats.joinToString("  ")

        setActive(keyboardButton, flag("keyboard"))
        viewStyleButton?.text = if (text("view_style") == "original") "Fit" else "1:1"

        val targetFps = text("target_fps")
        fpsView?.text = if (targetFps.isEmpty()) "FPS" else "$targetFps fps"
        val quality = text("quality")
        qualityView?.text = if (quality.isEmpty()) "Quality" else quality
        val codecPref = text("codec_pref")
        codecButton?.text = if (codecPref.isEmpty()) "Codec" else "Codec: $codecPref"

        val gamepadAvailable = flag("gamepad_available")
        val gamepadOn = flag("gamepad")
        gamepadButton?.text = if (gamepadOn) "Controller: on" else "Controller: off"
        setActive(gamepadButton, gamepadOn)
        setEnabled(gamepadButton, gamepadAvailable)
        setEnabled(mappingButton, flag("mapping_available"))
        setEnabled(profilePrevButton, gamepadAvailable)
        setEnabled(profileNextButton, gamepadAvailable)
        val profile = text("profile")
        profileView?.text = if (profile.isEmpty()) "No profile" else profile
    }

    private class TouchPadView(
        context: Context,
        private val onAction: (String, Map<String, Any?>) -> Unit
    ) : View(context) {
        private val density = resources.displayMetrics.density
        private val slop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
        private val tapTimeoutMs = 350L
        private val hint = "Touch pad"
        private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(0x70, 0x78, 0x84)
            textAlign = Paint.Align.CENTER
            textSize = 16f * resources.displayMetrics.scaledDensity
        }
        private var lastX = 0f
        private var lastY = 0f
        private var travelX = 0f
        private var travelY = 0f
        private var downTime = 0L
        private var moved = false
        private var maxPointers = 0

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            canvas.drawText(hint, width / 2f, height / 2f, hintPaint)
        }

        private fun setCentroid(event: MotionEvent, skipIndex: Int) {
            var sumX = 0f
            var sumY = 0f
            var count = 0
            for (i in 0 until event.pointerCount) {
                if (i == skipIndex) continue
                sumX += event.getX(i)
                sumY += event.getY(i)
                count++
            }
            if (count > 0) {
                lastX = sumX / count
                lastY = sumY / count
            }
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    parent?.requestDisallowInterceptTouchEvent(true)
                    maxPointers = 1
                    moved = false
                    travelX = 0f
                    travelY = 0f
                    downTime = event.eventTime
                    setCentroid(event, -1)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    maxPointers = max(maxPointers, event.pointerCount)
                    setCentroid(event, -1)
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    setCentroid(event, event.actionIndex)
                }
                MotionEvent.ACTION_MOVE -> {
                    val prevX = lastX
                    val prevY = lastY
                    setCentroid(event, -1)
                    val dx = lastX - prevX
                    val dy = lastY - prevY
                    if (!moved) {
                        travelX += dx
                        travelY += dy
                        if (hypot(travelX, travelY) > slop) moved = true
                    } else if (event.pointerCount >= 2) {
                        onAction(
                            "mouse_scroll",
                            mapOf("dx" to (dx / density).toDouble(), "dy" to (dy / density).toDouble())
                        )
                    } else if (maxPointers == 1) {
                        onAction(
                            "mouse_move",
                            mapOf("dx" to (dx / density).toDouble(), "dy" to (dy / density).toDouble())
                        )
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved && event.eventTime - downTime < tapTimeoutMs) {
                        onAction(
                            "mouse_click",
                            mapOf("button" to if (maxPointers >= 2) "right" else "left")
                        )
                    }
                }
            }
            return true
        }
    }
}
