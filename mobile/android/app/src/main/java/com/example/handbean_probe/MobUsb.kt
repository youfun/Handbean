package com.example.handbean_probe

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import androidx.compose.foundation.layout.size
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONArray
import org.json.JSONObject

internal object MobUsb {
    // ── Mob.Peripheral.VendorUsb ─────────────────────────────────────────────
    //
    // Android USB host. Talks to USB devices over bulk endpoints — surfaced to
    // Elixir via Mob.Peripheral.VendorUsb. iOS NIF returns :unsupported (iOS has
    // no public USB-host API).
    //
    // State lives in this object (singleton). Sessions are integer handles
    // returned from open(); reused only after process restart.

    private const val ACTION_USB_PERMISSION = "com.example.handbean_probe.USB_PERMISSION"

    private data class UsbSession(
        val pid: Long,
        val device: UsbDevice,
        val connection: UsbDeviceConnection,
        val iface: UsbInterface,
        val epIn: UsbEndpoint?,
        val epOut: UsbEndpoint?,
        val running: AtomicBoolean = AtomicBoolean(true),
        @Volatile var readThread: Thread? = null,
        @Volatile var readChunkBytes: Int = 4096
    )

    private val usbSessions = ConcurrentHashMap<Int, UsbSession>()
    private val usbNextSession = AtomicInteger(1)
    private val usbPendingPermission =
        ConcurrentHashMap<String, MutableList<Long>>()
    private var usbReceiverRegistered = false

    fun vendor_usb_list_devices(pid: Long, filterJson: String) {
        try {
            val ctx = MobBridge.activity() ?: return
            val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return

            val filter = try { JSONObject(filterJson) } catch (e: Exception) { JSONObject() }
            val wantVid = if (filter.has("vendor_id") && !filter.isNull("vendor_id")) {
                val v = filter.optInt("vendor_id", -1); if (v >= 0) v else null
            } else null
            val wantPid = if (filter.has("product_id") && !filter.isNull("product_id")) {
                val v = filter.optInt("product_id", -1); if (v >= 0) v else null
            } else null

            val arr = JSONArray()
            for (dev in mgr.deviceList.values) {
                if (wantVid != null && dev.vendorId != wantVid) continue
                if (wantPid != null && dev.productId != wantPid) continue
                arr.put(usbDeviceJson(dev))
            }
            MobBridge.nativeDeliverVendorUsbDevices(pid, arr.toString())
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_list_devices failed: ${e.message}", e)
            MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "exception")
        }
    }

    fun vendor_usb_request_permission(pid: Long, ref: String) {
        try {
            val ctx = MobBridge.activity() ?: return
            val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
            val dev = mgr.deviceList[ref]
            if (dev == null) {
                // Device gone before we could prompt — emit a denied event so the
                // caller's state machine doesn't stall.
                MobBridge.nativeDeliverVendorUsbPermission(pid, false, """{"ref":"$ref"}""")
                return
            }

            if (mgr.hasPermission(dev)) {
                MobBridge.nativeDeliverVendorUsbPermission(pid, true, usbDeviceJson(dev).toString())
                return
            }

            usbPendingPermission.compute(ref) { _, existing ->
                (existing ?: mutableListOf()).also { it.add(pid) }
            }

            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE else 0
            val intent = PendingIntent.getBroadcast(
                ctx, 0, Intent(ACTION_USB_PERMISSION).setPackage(ctx.packageName), flags
            )
            mgr.requestPermission(dev, intent)
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_request_permission failed: ${e.message}", e)
            MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "exception")
        }
    }

    fun vendor_usb_open(pid: Long, optsJson: String) {
        try {
            val ctx = MobBridge.activity() ?: return
            val mgr = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return

            val opts = try { JSONObject(optsJson) } catch (e: Exception) {
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "bad_opts"); return
            }
            val ref = opts.optString("ref")
            val ifaceIdx = opts.optInt("interface", 0)
            val wantEpIn = if (opts.has("endpoint_in") && !opts.isNull("endpoint_in"))
                opts.getInt("endpoint_in") else null
            val wantEpOut = if (opts.has("endpoint_out") && !opts.isNull("endpoint_out"))
                opts.getInt("endpoint_out") else null

            val dev = mgr.deviceList[ref] ?: run {
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "device_gone"); return
            }
            if (!mgr.hasPermission(dev)) {
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "no_permission"); return
            }
            if (ifaceIdx < 0 || ifaceIdx >= dev.interfaceCount) {
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "bad_interface"); return
            }

            val conn = mgr.openDevice(dev) ?: run {
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "open_failed"); return
            }
            val iface = dev.getInterface(ifaceIdx)
            if (!conn.claimInterface(iface, true)) {
                conn.close()
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "interface_busy"); return
            }

            // Endpoint resolution: explicit user choice wins; otherwise pick the
            // first bulk IN/OUT we find on the interface.
            var epIn: UsbEndpoint? = null
            var epOut: UsbEndpoint? = null
            for (i in 0 until iface.endpointCount) {
                val ep = iface.getEndpoint(i)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (ep.direction == UsbConstants.USB_DIR_IN) {
                    if (wantEpIn == null || wantEpIn == ep.address) epIn = epIn ?: ep
                } else {
                    if (wantEpOut == null || wantEpOut == ep.address) epOut = epOut ?: ep
                }
            }
            if (epIn == null && epOut == null) {
                conn.releaseInterface(iface); conn.close()
                MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "no_bulk_endpoints"); return
            }

            val sessionId = usbNextSession.getAndIncrement()
            val session = UsbSession(pid, dev, conn, iface, epIn, epOut)
            usbSessions[sessionId] = session
            MobBridge.nativeDeliverVendorUsbOpened(pid, sessionId, usbDeviceJson(dev).toString())
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_open failed: ${e.message}", e)
            MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "exception")
        }
    }

    fun vendor_usb_bulk_write(pid: Long, sessionId: Int, bytes: ByteArray, timeoutMs: Int) {
        try {
            val s = usbSessions[sessionId] ?: run {
                MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "error", "no_session"); return
            }
            val ep = s.epOut ?: run {
                MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "error", "no_out_endpoint"); return
            }

            // Run write off the caller thread — bulkTransfer can block for up to
            // timeoutMs and we don't want to block whatever Kotlin queue the NIF
            // call landed on. The NIF is already marked DIRTY_JOB_IO_BOUND.
            Thread {
                val written = try {
                    s.connection.bulkTransfer(ep, bytes, bytes.size, timeoutMs)
                } catch (e: Exception) {
                    MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "error", "write_failed"); return@Thread
                }
                if (written < 0) {
                    MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "error", "write_timeout")
                } else {
                    MobBridge.nativeDeliverVendorUsbWriteComplete(pid, sessionId, written)
                }
            }.apply { name = "MobUsbWrite-$sessionId" }.start()
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_bulk_write failed: ${e.message}", e)
            MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "exception")
        }
    }

    fun vendor_usb_start_reading(pid: Long, sessionId: Int, chunkBytes: Int) {
        try {
            val s = usbSessions[sessionId] ?: run {
                MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "error", "no_session"); return
            }
            val ep = s.epIn ?: run {
                MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "error", "no_in_endpoint"); return
            }
            if (s.readThread != null) return  // idempotent

            s.readChunkBytes = chunkBytes.coerceAtLeast(64)
            s.running.set(true)

            s.readThread = Thread {
                val maxPacket = ep.maxPacketSize
                val buf = ByteArray(maxOf(s.readChunkBytes, maxPacket))
                while (s.running.get()) {
                    val n = try {
                        s.connection.bulkTransfer(ep, buf, buf.size, 100)
                    } catch (e: Exception) {
                        if (s.running.get()) {
                            MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "disconnected", "io_error")
                        }
                        break
                    }
                    if (n > 0) {
                        val out = if (n == buf.size) buf else buf.copyOf(n)
                        MobBridge.nativeDeliverVendorUsbData(pid, sessionId, out, n)
                    }
                    // n < 0 is a 100ms timeout — normal, just loop.
                }
            }.apply { name = "MobUsbRead-$sessionId"; isDaemon = true }
            s.readThread?.start()
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_start_reading failed: ${e.message}", e)
            MobBridge.nativeDeliverVendorUsbEvent(pid, -1, "error", "exception")
        }
    }

    fun vendor_usb_stop_reading(sessionId: Int) {
        try {
            val s = usbSessions[sessionId] ?: return
            s.running.set(false)
            s.readThread?.interrupt()
            s.readThread = null
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_stop_reading failed: ${e.message}", e)
        }
    }

    fun vendor_usb_close(sessionId: Int) {
        try {
            val s = usbSessions.remove(sessionId) ?: return
            val pid = s.pid
            s.running.set(false)
            try { s.readThread?.interrupt() } catch (_: Exception) {}
            try { s.connection.releaseInterface(s.iface) } catch (_: Exception) {}
            try { s.connection.close() } catch (_: Exception) {}
            MobBridge.nativeDeliverVendorUsbEvent(pid, sessionId, "closed", "ok")
        } catch (e: Exception) {
            android.util.Log.w("MobBridge", "vendor_usb_close failed: ${e.message}", e)
        }
    }

    // Helper: build the public `device` JSON shape used everywhere.
    private fun usbDeviceJson(dev: UsbDevice): JSONObject {
        return JSONObject().apply {
            put("vendor_id",    dev.vendorId)
            put("product_id",   dev.productId)
            put("manufacturer", dev.manufacturerName ?: JSONObject.NULL)
            put("product",      dev.productName      ?: JSONObject.NULL)
            put("serial",
                try { dev.serialNumber ?: JSONObject.NULL } catch (e: SecurityException) { JSONObject.NULL })
            put("ref",          dev.deviceName)
        }
    }

    // BroadcastReceiver for permission grants + hot-unplug. Registered once
    // from MobBridge.init via ensureUsbReceiver.
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val dev: UsbDevice? = if (Build.VERSION.SDK_INT >= 33)
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    else
                        @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    val ref = dev?.deviceName ?: return
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val waiters = usbPendingPermission.remove(ref) ?: return
                    val json = usbDeviceJson(dev).toString()
                    for (pid in waiters) {
                        MobBridge.nativeDeliverVendorUsbPermission(pid, granted, json)
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val dev: UsbDevice? = if (Build.VERSION.SDK_INT >= 33)
                        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    else
                        @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    val ref = dev?.deviceName ?: return
                    // Tear down any sessions on the now-departed device. Iterate
                    // a snapshot so close() can mutate the underlying map.
                    for ((sessionId, s) in usbSessions.toMap()) {
                        if (s.device.deviceName == ref) {
                            s.running.set(false)
                            try { s.readThread?.interrupt() } catch (_: Exception) {}
                            try { s.connection.releaseInterface(s.iface) } catch (_: Exception) {}
                            try { s.connection.close() } catch (_: Exception) {}
                            usbSessions.remove(sessionId)
                            MobBridge.nativeDeliverVendorUsbEvent(s.pid, sessionId, "disconnected", "detached")
                        }
                    }
                }
            }
        }
    }

    fun ensureUsbReceiver(ctx: Context) {
        if (usbReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(usbReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(usbReceiver, filter)
        }
        usbReceiverRegistered = true
    }
}
