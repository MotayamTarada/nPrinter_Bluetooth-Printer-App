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
import java.io.InputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
  private val channelName = "com.example.nprinter_bluetooth_only/bluetooth_scan"
  private val pdfIntentChannelName = "com.example.nprinter_bluetooth_only/pdf_intent"
  private val printerStatusChannelName = "com.example.nprinter_bluetooth_only/printer_status"
  private val gainschaColorChannelName = "com.example.nprinter_bluetooth_only/gainscha_b380_color"
  private val sppUuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
  private val handler = Handler(Looper.getMainLooper())
  private var scanReceiver: BroadcastReceiver? = null
  private var pairingReceiver: BroadcastReceiver? = null
  private var pendingResult: MethodChannel.Result? = null
  private val discoveredDevices = linkedMapOf<String, String>()
  private var timeoutRunnable: Runnable? = null
  private var pdfIntentChannel: MethodChannel? = null
  private var pendingPdfIntent: Map<String, String>? = null
  private var openedWithPdfIntent: Boolean = false

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    pdfIntentChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pdfIntentChannelName).also {
      channel ->
      channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
          "hasPendingPdf" -> {
            result.success(pendingPdfIntent != null)
          }
          "wasOpenedWithPdfIntent" -> {
            result.success(openedWithPdfIntent)
          }
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
          "androidSdkInt" -> {
            result.success(Build.VERSION.SDK_INT)
          }
          "discover" -> {
            val timeoutMs = (call.argument<Int>("timeoutMs") ?: 10_000).coerceIn(3_000, 20_000)
            val includeBonded = call.argument<Boolean>("includeBonded") ?: true
            startDiscovery(timeoutMs.toLong(), includeBonded, result)
          }
          "pairDevice" -> {
            val macAddress = call.argument<String>("mac").orEmpty()
            val pin = call.argument<String>("pin").orEmpty()
            Thread {
              val payload = pairDevice(macAddress, pin)
              handler.post { result.success(payload) }
            }.start()
          }
          else -> result.notImplemented()
        }
      }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, printerStatusChannelName)
      .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
          "checkEscPosStatus" -> {
            val macAddress = call.argument<String>("mac").orEmpty()
            Thread {
              val payload = checkEscPosStatus(macAddress)
              handler.post { result.success(payload) }
            }.start()
          }
          else -> result.notImplemented()
        }
      }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, gainschaColorChannelName)
      .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
        when (call.method) {
          "printMonochromeLayer" -> {
            // Official Gainscha B380 Android SDK is not bundled in this repository yet.
            // Keep returning false so Flutter can fallback safely to black printing.
            result.success(false)
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

  override fun onDestroy() {
    unregisterPairingReceiver(pairingReceiver)
    scanReceiver?.let {
      try {
        unregisterReceiver(it)
      } catch (_: IllegalArgumentException) {
      }
    }
    scanReceiver = null
    timeoutRunnable?.let(handler::removeCallbacks)
    timeoutRunnable = null
    super.onDestroy()
  }

  private fun handleIncomingPdfIntent(intent: Intent?, notifyFlutter: Boolean) {
    val payload = pdfPayloadFromIntent(intent) ?: return
    pendingPdfIntent = payload
    openedWithPdfIntent = true
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

  private fun startDiscovery(
    timeoutMs: Long,
    includeBonded: Boolean,
    result: MethodChannel.Result,
  ) {
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
    if (includeBonded) {
      collectBondedDevices(adapter)
    }

    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) {
        when (intent?.action) {
          BluetoothDevice.ACTION_FOUND -> {
            val device = deviceFromIntent(intent)
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
      registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
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

  private fun hasRequiredConnectPermission(): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) ==
        PackageManager.PERMISSION_GRANTED
    } else {
      true
    }
  }

  private fun pairDevice(macAddress: String, pin: String): Map<String, Any> {
    val normalizedMac = macAddress.trim()
    if (normalizedMac.isEmpty()) {
      return mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "invalid_mac",
      )
    }

    val adapter = BluetoothAdapter.getDefaultAdapter()
      ?: return mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "adapter_unavailable",
      )

    if (!adapter.isEnabled) {
      return mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "bluetooth_disabled",
      )
    }

    if (!hasRequiredConnectPermission()) {
      return mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "permission_missing",
      )
    }

    return try {
      val device = adapter.getRemoteDevice(normalizedMac)
      if (device.bondState == BluetoothDevice.BOND_BONDED) {
        mapOf(
          "success" to true,
          "alreadyBonded" to true,
          "started" to true,
          "state" to "bonded",
        )
      } else {
        if (adapter.isDiscovering) {
          adapter.cancelDiscovery()
        }

        val effectivePin = pin.trim().ifEmpty { "0000" }
        val receiver = registerPairingReceiver(normalizedMac, effectivePin)
        try {
          val pinApplied = applyPairingPinIfPossible(device, effectivePin)
          val started = device.createBond()
          val finalState = waitForBondState(device, timeoutMs = 25_000)
          mapOf(
            "success" to (finalState == BluetoothDevice.BOND_BONDED),
            "alreadyBonded" to false,
            "started" to started,
            "pinApplied" to pinApplied,
            "state" to when (finalState) {
              BluetoothDevice.BOND_BONDED -> "bonded"
              BluetoothDevice.BOND_BONDING -> "bonding"
              else -> "none"
            },
          )
        } finally {
          unregisterPairingReceiver(receiver)
        }
      }
    } catch (_: SecurityException) {
      mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "permission_missing",
      )
    } catch (_: IllegalArgumentException) {
      mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "invalid_mac",
      )
    } catch (_: Exception) {
      mapOf(
        "success" to false,
        "alreadyBonded" to false,
        "started" to false,
        "state" to "pairing_failed",
      )
    }
  }

  private fun applyPairingPinIfPossible(device: BluetoothDevice, pin: String): Boolean {
    val normalizedPin = pin.trim()
    if (normalizedPin.isEmpty()) {
      return false
    }

    return try {
      val setPinMethod = device.javaClass.getMethod("setPin", ByteArray::class.java)
      setPinMethod.invoke(device, normalizedPin.toByteArray(Charsets.UTF_8))
      runCatching {
        val confirmMethod = device.javaClass.getMethod("setPairingConfirmation", Boolean::class.javaPrimitiveType)
        confirmMethod.invoke(device, true)
      }
      true
    } catch (_: Exception) {
      false
    }
  }

  private fun registerPairingReceiver(macAddress: String, pin: String): BroadcastReceiver? {
    val normalizedMac = macAddress.trim().uppercase()
    val normalizedPin = pin.trim()
    if (normalizedMac.isEmpty() || normalizedPin.isEmpty()) {
      return null
    }

    unregisterPairingReceiver(pairingReceiver)

    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != BluetoothDevice.ACTION_PAIRING_REQUEST) {
          return
        }

        val device = deviceFromIntent(intent) ?: return
        val deviceMac = device.address?.trim()?.uppercase().orEmpty()
        if (deviceMac != normalizedMac) {
          return
        }

        if (applyPairingPinIfPossible(device, normalizedPin)) {
          runCatching { abortBroadcast() }
        }
      }
    }

    val filter = IntentFilter(BluetoothDevice.ACTION_PAIRING_REQUEST).apply {
      priority = IntentFilter.SYSTEM_HIGH_PRIORITY
    }

    return try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
      } else {
        @Suppress("DEPRECATION")
        registerReceiver(receiver, filter)
      }
      pairingReceiver = receiver
      receiver
    } catch (_: Exception) {
      null
    }
  }

  private fun unregisterPairingReceiver(receiver: BroadcastReceiver?) {
    val target = receiver ?: return
    try {
      unregisterReceiver(target)
    } catch (_: IllegalArgumentException) {
    }
    if (pairingReceiver === target) {
      pairingReceiver = null
    }
  }

  private fun waitForBondState(device: BluetoothDevice, timeoutMs: Long): Int {
    val deadline = System.currentTimeMillis() + timeoutMs
    var latest = device.bondState
    while (System.currentTimeMillis() < deadline) {
      latest = device.bondState
      if (latest == BluetoothDevice.BOND_BONDED || latest == BluetoothDevice.BOND_NONE) {
        return latest
      }
      try {
        Thread.sleep(250)
      } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        return latest
      }
    }
    return latest
  }

  private fun checkEscPosStatus(macAddress: String): Map<String, Any> {
    val normalizedMac = macAddress.trim()
    if (normalizedMac.isEmpty()) {
      return printerStatusPayload(
        checked = false,
        supported = false,
        canPrint = false,
        issues = listOf("invalid_mac"),
      )
    }

    val adapter = BluetoothAdapter.getDefaultAdapter()
      ?: return printerStatusPayload(
        checked = false,
        supported = false,
        canPrint = false,
        issues = listOf("adapter_unavailable"),
      )

    if (!adapter.isEnabled) {
      return printerStatusPayload(
        checked = false,
        supported = false,
        canPrint = false,
        issues = listOf("bluetooth_disabled"),
      )
    }

    if (!hasRequiredConnectPermission()) {
      return printerStatusPayload(
        checked = false,
        supported = false,
        canPrint = false,
        issues = listOf("permission_missing"),
      )
    }

    val socket = try {
      val device = adapter.getRemoteDevice(normalizedMac)
      if (adapter.isDiscovering) {
        adapter.cancelDiscovery()
      }
      device.createRfcommSocketToServiceRecord(sppUuid)
    } catch (_: Exception) {
      return printerStatusPayload(
        checked = false,
        supported = false,
        canPrint = false,
        issues = listOf("connect_failed"),
      )
    }

    return try {
      socket.connect()
      val input = socket.inputStream
      val output = socket.outputStream
      val responses = linkedMapOf<Int, Int>()

      for (request in listOf(1, 2, 3, 4)) {
        drainInput(input)
        output.write(byteArrayOf(0x10.toByte(), 0x04.toByte(), request.toByte()))
        output.flush()
        val response = readStatusByte(input, timeoutMs = 300)
        if (response != null) {
          responses[request] = response
        }
      }

      if (responses.isEmpty()) {
        printerStatusPayload(
          checked = false,
          supported = false,
          canPrint = true,
        )
      } else {
        val issues = mutableListOf<String>()
        val warnings = mutableListOf<String>()

        responses[1]?.let { printerStatus ->
          if ((printerStatus and 0x08) != 0) {
            issues.add("offline")
          }
        }

        responses[2]?.let { offlineStatus ->
          if ((offlineStatus and 0x04) != 0) {
            issues.add("cover_open")
          }
          if ((offlineStatus and 0x20) != 0) {
            issues.add("paper_stop")
          }
          if ((offlineStatus and 0x40) != 0) {
            issues.add("error")
          }
        }

        responses[3]?.let { errorStatus ->
          if ((errorStatus and 0x04) != 0) {
            issues.add("cutter_error")
          }
          if ((errorStatus and 0x08) != 0) {
            issues.add("unrecoverable_error")
          }
          if ((errorStatus and 0x20) != 0) {
            issues.add("auto_recoverable_error")
          }
        }

        responses[4]?.let { paperStatus ->
          if ((paperStatus and 0x60) != 0) {
            issues.add("paper_end")
          } else if ((paperStatus and 0x0C) != 0) {
            warnings.add("paper_near_end")
          }
        }

        printerStatusPayload(
          checked = true,
          supported = true,
          canPrint = issues.isEmpty(),
          issues = issues.distinct(),
          warnings = warnings.distinct(),
          raw = responses.mapKeys { it.key.toString() },
        )
      }
    } catch (_: Exception) {
      printerStatusPayload(
        checked = false,
        supported = false,
        canPrint = false,
        issues = listOf("connect_failed"),
      )
    } finally {
      try {
        socket.close()
      } catch (_: Exception) {
      }
    }
  }

  private fun printerStatusPayload(
    checked: Boolean,
    supported: Boolean,
    canPrint: Boolean,
    issues: List<String> = emptyList(),
    warnings: List<String> = emptyList(),
    raw: Map<String, Int> = emptyMap(),
  ): Map<String, Any> {
    return mapOf(
      "checked" to checked,
      "supported" to supported,
      "canPrint" to canPrint,
      "issues" to issues,
      "warnings" to warnings,
      "raw" to raw,
    )
  }

  private fun drainInput(input: InputStream) {
    try {
      while (input.available() > 0) {
        input.read()
      }
    } catch (_: Exception) {
    }
  }

  private fun readStatusByte(input: InputStream, timeoutMs: Long): Int? {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
      try {
        if (input.available() > 0) {
          return input.read() and 0xFF
        }
      } catch (_: Exception) {
        return null
      }

      try {
        Thread.sleep(20)
      } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        return null
      }
    }
    return null
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

  private fun deviceFromIntent(intent: Intent): BluetoothDevice? {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
      @Suppress("DEPRECATION")
      intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
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
