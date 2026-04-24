package com.example.nprinter_bluetooth_only

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
  private val channelName = "com.example.nprinter_bluetooth_only/bluetooth_scan"
  private val pdfIntentChannelName = "com.example.nprinter_bluetooth_only/pdf_intent"
  private val handler = Handler(Looper.getMainLooper())
  private var scanReceiver: BroadcastReceiver? = null
  private var pendingResult: MethodChannel.Result? = null
  private val discoveredDevices = linkedMapOf<String, String>()
  private var timeoutRunnable: Runnable? = null
  private var pdfIntentChannel: MethodChannel? = null
  private var pendingPdfIntent: Map<String, String>? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    pdfIntentChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pdfIntentChannelName).also {
      channel ->
      channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
          "consumeInitialPdf" -> {
            val payload = pendingPdfIntent
            pendingPdfIntent = null
            result.success(payload)
          }
          "clearPendingPdf" -> {
            pendingPdfIntent = null
            result.success(null)
          }
          else -> result.notImplemented()
        }
      }
    }
    handleIncomingPdfIntent(intent, notifyFlutter = false)

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
          "discover" -> {
            val timeoutMs = (call.argument<Int>("timeoutMs") ?: 10_000).coerceIn(3_000, 20_000)
            startDiscovery(timeoutMs.toLong(), result)
          }
          else -> result.notImplemented()
        }
      }
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    handleIncomingPdfIntent(intent, notifyFlutter = true)
  }

  private fun handleIncomingPdfIntent(intent: Intent?, notifyFlutter: Boolean) {
    val payload = pdfPayloadFromIntent(intent) ?: return
    pendingPdfIntent = payload
    if (notifyFlutter) {
      pdfIntentChannel?.invokeMethod("pdfOpened", payload)
    }
  }

  private fun pdfPayloadFromIntent(intent: Intent?): Map<String, String>? {
    if (intent == null) {
      return null
    }

    val uri = when (intent.action) {
      Intent.ACTION_VIEW -> intent.data
      Intent.ACTION_SEND -> streamUriFromIntent(intent)
      Intent.ACTION_SEND_MULTIPLE -> streamUrisFromIntent(intent).firstOrNull()
      else -> null
    } ?: return null

    val displayName = displayNameForUri(uri)
    val mimeType = intent.type ?: runCatching { contentResolver.getType(uri) }.getOrNull()
    if (!looksLikePdf(uri, displayName, mimeType)) {
      return null
    }

    val pdfPath = materializePdfUri(uri, displayName) ?: return null
    val pdfName = safePdfFileName(displayName ?: File(pdfPath).name)

    return mapOf(
      "path" to pdfPath,
      "name" to pdfName,
    )
  }

  private fun streamUriFromIntent(intent: Intent): Uri? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
    } else {
      @Suppress("DEPRECATION")
      intent.getParcelableExtra(Intent.EXTRA_STREAM)
    }
  }

  private fun streamUrisFromIntent(intent: Intent): List<Uri> {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
    } else {
      @Suppress("DEPRECATION")
      intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
    }
  }

  private fun looksLikePdf(uri: Uri, displayName: String?, mimeType: String?): Boolean {
    val normalizedMimeType = mimeType?.trim()?.lowercase().orEmpty()
    if (normalizedMimeType == "application/pdf") {
      return true
    }

    val uriText = uri.toString().lowercase()
    val normalizedDisplayName = displayName?.trim()?.lowercase().orEmpty()
    return uriText.endsWith(".pdf") || normalizedDisplayName.endsWith(".pdf")
  }

  private fun materializePdfUri(uri: Uri, displayName: String?): String? {
    if (uri.scheme == "file") {
      return uri.path
    }

    return try {
      val incomingDir = File(cacheDir, "incoming_pdfs").apply { mkdirs() }
      val targetFile = File(
        incomingDir,
        "${System.currentTimeMillis()}_${safePdfFileName(displayName)}",
      )

      contentResolver.openInputStream(uri)?.use { input ->
        FileOutputStream(targetFile).use { output ->
          input.copyTo(output)
        }
      } ?: return null

      targetFile.absolutePath
    } catch (_: Exception) {
      null
    }
  }

  private fun displayNameForUri(uri: Uri): String? {
    if (uri.scheme == "file") {
      return uri.lastPathSegment
    }

    return try {
      contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        cursor ->
        if (cursor.moveToFirst()) {
          val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
          if (nameIndex >= 0) cursor.getString(nameIndex) else null
        } else {
          null
        }
      }
    } catch (_: Exception) {
      null
    }
  }

  private fun safePdfFileName(candidate: String?): String {
    val fallback = "opened_pdf_${System.currentTimeMillis()}.pdf"
    val trimmed = candidate?.trim()?.takeIf { it.isNotEmpty() } ?: fallback
    val withExtension = if (trimmed.endsWith(".pdf", ignoreCase = true)) {
      trimmed
    } else {
      "$trimmed.pdf"
    }
    return withExtension.replace(Regex("""[\\/:*?"<>|]"""), "_")
  }

  private fun startDiscovery(timeoutMs: Long, result: MethodChannel.Result) {
    if (pendingResult != null) {
      result.error("busy", "Bluetooth discovery is already running.", null)
      return
    }

    val adapter = BluetoothAdapter.getDefaultAdapter()
    if (adapter == null) {
      result.error("unavailable", "Bluetooth adapter is not available.", null)
      return
    }

    if (!adapter.isEnabled) {
      result.error("disabled", "Bluetooth is turned off.", null)
      return
    }

    if (!hasRequiredDiscoveryPermissions()) {
      result.error("permission", "Bluetooth scan permissions are missing.", null)
      return
    }

    pendingResult = result
    discoveredDevices.clear()
    collectBondedDevices(adapter)

    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) {
        when (intent?.action) {
          BluetoothDevice.ACTION_FOUND -> {
            val device: BluetoothDevice? =
              intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            addDiscoveredDevice(device)
          }
          BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> finishDiscovery()
        }
      }
    }

    scanReceiver = receiver
    val filter = IntentFilter().apply {
      addAction(BluetoothDevice.ACTION_FOUND)
      addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      registerReceiver(receiver, filter)
    }

    if (adapter.isDiscovering) {
      adapter.cancelDiscovery()
    }

    val started = adapter.startDiscovery()
    if (!started) {
      finishDiscovery(errorCode = "start_failed", errorMessage = "Failed to start Bluetooth discovery.")
      return
    }

    timeoutRunnable = Runnable { finishDiscovery() }.also {
      handler.postDelayed(it, timeoutMs)
    }
  }

  private fun hasRequiredDiscoveryPermissions(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      val hasScan = ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) ==
        PackageManager.PERMISSION_GRANTED
      val hasConnect = ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
        PackageManager.PERMISSION_GRANTED
      hasScan && hasConnect
    } else {
      val hasFineLocation = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED
      val hasCoarseLocation = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED
      hasFineLocation || hasCoarseLocation
    }
  }

  private fun collectBondedDevices(adapter: BluetoothAdapter) {
    val bondedDevices = adapter.bondedDevices ?: return
    for (device in bondedDevices) {
      addDiscoveredDevice(device)
    }
  }

  private fun addDiscoveredDevice(device: BluetoothDevice?) {
    if (device == null) {
      return
    }

    val macAddress = device.address ?: return
    val currentName = discoveredDevices[macAddress]
    val newName = device.name?.trim().orEmpty()

    discoveredDevices[macAddress] = when {
      newName.isNotEmpty() -> newName
      currentName != null -> currentName
      else -> ""
    }
  }

  private fun finishDiscovery(errorCode: String? = null, errorMessage: String? = null) {
    val adapter = BluetoothAdapter.getDefaultAdapter()
    if (adapter?.isDiscovering == true) {
      adapter.cancelDiscovery()
    }

    timeoutRunnable?.let(handler::removeCallbacks)
    timeoutRunnable = null

    scanReceiver?.let {
      try {
        unregisterReceiver(it)
      } catch (_: IllegalArgumentException) {
      }
    }
    scanReceiver = null

    val result = pendingResult ?: return
    pendingResult = null

    if (errorCode != null) {
      result.error(errorCode, errorMessage, null)
      return
    }

    val payload = discoveredDevices.entries.map { entry ->
      mapOf(
        "name" to entry.value,
        "macAdress" to entry.key,
      )
    }
    result.success(payload)
  }
}
