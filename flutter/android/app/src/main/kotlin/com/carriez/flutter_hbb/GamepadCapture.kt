package com.carriez.flutter_hbb

import android.content.Context
import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.roundToInt

class GamepadCapture(context: Context) : InputManager.InputDeviceListener,
    MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "is2l/gamepad"
        const val MAX_PADS = 4

        const val BTN_A = 1 shl 0
        const val BTN_B = 1 shl 1
        const val BTN_X = 1 shl 2
        const val BTN_Y = 1 shl 3
        const val BTN_L1 = 1 shl 4
        const val BTN_R1 = 1 shl 5
        const val BTN_SELECT = 1 shl 6
        const val BTN_START = 1 shl 7
        const val BTN_MODE = 1 shl 8
        const val BTN_L3 = 1 shl 9
        const val BTN_R3 = 1 shl 10
        const val BTN_DPAD_UP = 1 shl 11
        const val BTN_DPAD_DOWN = 1 shl 12
        const val BTN_DPAD_LEFT = 1 shl 13
        const val BTN_DPAD_RIGHT = 1 shl 14
    }

    private class Pad(val deviceId: Int, val index: Int) {
        var name = ""
        var vendorId = 0
        var productId = 0
        var keyButtons = 0
        var hatButtons = 0
        var lx = 0
        var ly = 0
        var rx = 0
        var ry = 0
        var ltAxis = 0
        var rtAxis = 0
        var ltKey = false
        var rtKey = false
        var rightStickX = MotionEvent.AXIS_Z
        var rightStickY = MotionEvent.AXIS_RZ
        val rawKeys = LinkedHashSet<Int>()
        val rawAxes = LinkedHashMap<String, Double>()
        var dirty = false
        var lastSent: List<Int>? = null

        val buttons: Int get() = keyButtons or hatButtons
        val lt: Int get() = if (ltKey) 255 else ltAxis
        val rt: Int get() = if (rtKey) 255 else rtAxis

        fun signature(): List<Int> = listOf(buttons, lx, ly, rx, ry, lt, rt, rawKeys.size)

        fun clear() {
            keyButtons = 0
            hatButtons = 0
            lx = 0
            ly = 0
            rx = 0
            ry = 0
            ltAxis = 0
            rtAxis = 0
            ltKey = false
            rtKey = false
            rawKeys.clear()
            rawAxes.clear()
        }
    }

    private val logTag = "GamepadCapture"
    private val inputManager =
        context.applicationContext.getSystemService(Context.INPUT_SERVICE) as InputManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var capture = false
    private var listening = false
    private val slots = arrayOfNulls<Pad>(MAX_PADS)
    private val pads = HashMap<Int, Pad>()
    private var frameScheduled = false
    private val frameCallback = Choreographer.FrameCallback {
        frameScheduled = false
        for (pad in slots) {
            if (pad != null && pad.dirty) {
                flush(pad)
            }
        }
    }

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    fun detach() {
        setCapture(false)
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setCapture" -> {
                setCapture(call.arguments as? Boolean ?: false)
                result.success(capture)
            }
            "devices" -> {
                result.success(listDevices())
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    fun onKeyEvent(event: KeyEvent): Boolean {
        if (!capture) return false
        if (!isPadSource(event.source)) return false
        val keyCode = event.keyCode
        val bit = buttonBit(keyCode)
        val isTrigger =
            keyCode == KeyEvent.KEYCODE_BUTTON_L2 || keyCode == KeyEvent.KEYCODE_BUTTON_R2
        if (bit == 0 && !isTrigger) return false
        val device = event.device ?: return false
        if (isNavigationKey(keyCode) &&
            device.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC) {
            return false
        }
        val pad = padFor(device) ?: return false
        if ((event.flags and KeyEvent.FLAG_FALLBACK) != 0) return true
        val down = when (event.action) {
            KeyEvent.ACTION_DOWN -> true
            KeyEvent.ACTION_UP -> false
            else -> return true
        }
        if (down && event.repeatCount > 0) return true
        if (down) pad.rawKeys.add(keyCode) else pad.rawKeys.remove(keyCode)
        when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_L2 -> pad.ltKey = down
            KeyEvent.KEYCODE_BUTTON_R2 -> pad.rtKey = down
            else -> pad.keyButtons =
                if (down) pad.keyButtons or bit else pad.keyButtons and bit.inv()
        }
        flush(pad)
        return true
    }

    fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (!capture) return false
        if ((event.source and InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK) {
            return false
        }
        if (event.action != MotionEvent.ACTION_MOVE) return false
        val device = event.device ?: return false
        val pad = padFor(device) ?: return false
        val source = event.source

        pad.lx = stick(event, device, MotionEvent.AXIS_X, source)
        pad.ly = stick(event, device, MotionEvent.AXIS_Y, source)
        pad.rx = stick(event, device, pad.rightStickX, source)
        pad.ry = stick(event, device, pad.rightStickY, source)
        pad.ltAxis = maxOf(
            trigger(event, device, MotionEvent.AXIS_LTRIGGER, source),
            trigger(event, device, MotionEvent.AXIS_BRAKE, source)
        )
        pad.rtAxis = maxOf(
            trigger(event, device, MotionEvent.AXIS_RTRIGGER, source),
            trigger(event, device, MotionEvent.AXIS_GAS, source)
        )

        val hatX = centered(event, device, MotionEvent.AXIS_HAT_X, source)
        val hatY = centered(event, device, MotionEvent.AXIS_HAT_Y, source)
        var hat = 0
        if (hatX < -0.5f) hat = hat or BTN_DPAD_LEFT
        if (hatX > 0.5f) hat = hat or BTN_DPAD_RIGHT
        if (hatY < -0.5f) hat = hat or BTN_DPAD_UP
        if (hatY > 0.5f) hat = hat or BTN_DPAD_DOWN
        val hatChanged = hat != pad.hatButtons
        pad.hatButtons = hat

        pad.rawAxes.clear()
        for (range in device.motionRanges) {
            if ((range.source and InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK) {
                continue
            }
            pad.rawAxes[MotionEvent.axisToString(range.axis)] =
                event.getAxisValue(range.axis).toDouble()
        }

        if (hatChanged) {
            flush(pad)
        } else {
            pad.dirty = true
            scheduleFrame()
        }
        return true
    }

    override fun onInputDeviceAdded(deviceId: Int) {
        if (!capture) return
        val device = InputDevice.getDevice(deviceId) ?: return
        if (isController(device)) {
            padFor(device)
        }
    }

    override fun onInputDeviceRemoved(deviceId: Int) {
        val pad = pads[deviceId] ?: return
        release(pad)
    }

    override fun onInputDeviceChanged(deviceId: Int) {
        val pad = pads[deviceId] ?: return
        val device = InputDevice.getDevice(deviceId)
        if (device == null) {
            release(pad)
            return
        }
        describe(pad, device)
    }

    private fun setCapture(on: Boolean) {
        if (capture == on) return
        capture = on
        if (on) {
            if (!listening) {
                inputManager.registerInputDeviceListener(this, mainHandler)
                listening = true
            }
            for (id in InputDevice.getDeviceIds()) {
                val device = InputDevice.getDevice(id) ?: continue
                if (isController(device)) {
                    padFor(device)
                }
            }
        } else {
            if (listening) {
                inputManager.unregisterInputDeviceListener(this)
                listening = false
            }
            if (frameScheduled) {
                Choreographer.getInstance().removeFrameCallback(frameCallback)
                frameScheduled = false
            }
            for (pad in slots.filterNotNull()) {
                release(pad)
            }
        }
    }

    private fun listDevices(): List<Map<String, Any>> {
        val list = ArrayList<Map<String, Any>>()
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            val pad = pads[id]
            if (pad == null && !isController(device)) continue
            list.add(
                mapOf(
                    "deviceId" to id,
                    "index" to (pad?.index ?: -1),
                    "name" to (device.name ?: ""),
                    "vendorId" to device.vendorId,
                    "productId" to device.productId
                )
            )
        }
        return list
    }

    private fun isPadSource(source: Int): Boolean {
        return (source and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
                (source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK
    }

    private fun isController(device: InputDevice): Boolean {
        if (device.isVirtual) return false
        if (!isPadSource(device.sources)) return false
        return device.hasKeys(KeyEvent.KEYCODE_BUTTON_A)[0]
    }

    private fun isNavigationKey(keyCode: Int): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_DPAD_CENTER,
            KeyEvent.KEYCODE_BACK -> true
            else -> false
        }
    }

    private fun buttonBit(keyCode: Int): Int {
        return when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> BTN_A
            KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_BACK -> BTN_B
            KeyEvent.KEYCODE_BUTTON_X -> BTN_X
            KeyEvent.KEYCODE_BUTTON_Y -> BTN_Y
            KeyEvent.KEYCODE_BUTTON_L1 -> BTN_L1
            KeyEvent.KEYCODE_BUTTON_R1 -> BTN_R1
            KeyEvent.KEYCODE_BUTTON_SELECT -> BTN_SELECT
            KeyEvent.KEYCODE_BUTTON_START -> BTN_START
            KeyEvent.KEYCODE_BUTTON_MODE -> BTN_MODE
            KeyEvent.KEYCODE_BUTTON_THUMBL -> BTN_L3
            KeyEvent.KEYCODE_BUTTON_THUMBR -> BTN_R3
            KeyEvent.KEYCODE_DPAD_UP -> BTN_DPAD_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> BTN_DPAD_DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> BTN_DPAD_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> BTN_DPAD_RIGHT
            else -> 0
        }
    }

    private fun padFor(device: InputDevice): Pad? {
        pads[device.id]?.let { return it }
        val index = slots.indexOfFirst { it == null }
        if (index < 0) return null
        val pad = Pad(device.id, index)
        describe(pad, device)
        slots[index] = pad
        pads[device.id] = pad
        Log.d(logTag, "controller $index attached: ${pad.name}")
        flush(pad)
        return pad
    }

    private fun describe(pad: Pad, device: InputDevice) {
        pad.name = device.name ?: ""
        pad.vendorId = device.vendorId
        pad.productId = device.productId
        val hasZ = hasAxis(device, MotionEvent.AXIS_Z) && hasAxis(device, MotionEvent.AXIS_RZ)
        val hasR = hasAxis(device, MotionEvent.AXIS_RX) && hasAxis(device, MotionEvent.AXIS_RY)
        if (!hasZ && hasR) {
            pad.rightStickX = MotionEvent.AXIS_RX
            pad.rightStickY = MotionEvent.AXIS_RY
        } else {
            pad.rightStickX = MotionEvent.AXIS_Z
            pad.rightStickY = MotionEvent.AXIS_RZ
        }
    }

    private fun hasAxis(device: InputDevice, axis: Int): Boolean {
        return device.getMotionRange(axis, InputDevice.SOURCE_JOYSTICK) != null
    }

    private fun release(pad: Pad) {
        pads.remove(pad.deviceId)
        if (slots[pad.index] === pad) {
            slots[pad.index] = null
        }
        pad.clear()
        pad.dirty = false
        Log.d(logTag, "controller ${pad.index} detached: ${pad.name}")
        send(pad, false)
    }

    private fun centered(event: MotionEvent, device: InputDevice, axis: Int, source: Int): Float {
        val range = device.getMotionRange(axis, source) ?: return 0f
        val value = event.getAxisValue(axis)
        return if (abs(value) <= range.flat) 0f else value
    }

    private fun stick(event: MotionEvent, device: InputDevice, axis: Int, source: Int): Int {
        val range = device.getMotionRange(axis, source) ?: return 0
        val value = event.getAxisValue(axis)
        if (abs(value) <= range.flat) return 0
        val limit = maxOf(abs(range.min), abs(range.max))
        if (limit <= 0f) return 0
        return (value / limit * 32767f).roundToInt().coerceIn(-32768, 32767)
    }

    private fun trigger(event: MotionEvent, device: InputDevice, axis: Int, source: Int): Int {
        val range = device.getMotionRange(axis, source) ?: return 0
        val span = range.max - range.min
        if (span <= 0f) return 0
        val value = event.getAxisValue(axis) - range.min
        if (value <= range.flat) return 0
        return (value / span * 255f).roundToInt().coerceIn(0, 255)
    }

    private fun scheduleFrame() {
        if (frameScheduled) return
        frameScheduled = true
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }

    private fun flush(pad: Pad) {
        pad.dirty = false
        val signature = pad.signature()
        if (signature == pad.lastSent) return
        pad.lastSent = signature
        send(pad, true)
    }

    private fun send(pad: Pad, connected: Boolean) {
        val state = mapOf(
            "index" to pad.index,
            "connected" to connected,
            "buttons" to pad.buttons,
            "lx" to pad.lx,
            "ly" to pad.ly,
            "rx" to pad.rx,
            "ry" to pad.ry,
            "lt" to pad.lt,
            "rt" to pad.rt,
            "name" to pad.name,
            "raw" to mapOf(
                "deviceId" to pad.deviceId,
                "vendorId" to pad.vendorId,
                "productId" to pad.productId,
                "keys" to pad.rawKeys.toList(),
                "axes" to HashMap(pad.rawAxes)
            )
        )
        channel?.invokeMethod("state", state)
    }
}
