package com.example.handbean_probe

internal object MobAlerts {
    fun show(title: String, message: String, buttonsJson: String) {
        val activity = MobBridge.activity() ?: return
        val buttons = MobAlertCodec.parseButtons(buttonsJson)
        activity.runOnUiThread {
            val builder = android.app.AlertDialog.Builder(activity)
            if (title.isNotEmpty()) builder.setTitle(title)
            if (message.isNotEmpty()) builder.setMessage(message)
            val positives = buttons.filter { it["style"] != "cancel" }
            val cancels   = buttons.filter { it["style"] == "cancel" }
            positives.firstOrNull()?.let { btn ->
                val action = btn["action"] ?: "dismiss"
                builder.setPositiveButton(btn["label"]) { _, _ -> MobBridge.nativeDeliverAlertAction(action) }
            }
            positives.getOrNull(1)?.let { btn ->
                val action = btn["action"] ?: "dismiss"
                builder.setNeutralButton(btn["label"]) { _, _ -> MobBridge.nativeDeliverAlertAction(action) }
            }
            cancels.firstOrNull()?.let { btn ->
                val action = btn["action"] ?: "dismiss"
                builder.setNegativeButton(btn["label"]) { _, _ -> MobBridge.nativeDeliverAlertAction(action) }
            }
            builder.setOnCancelListener { MobBridge.nativeDeliverAlertAction("dismiss") }
            builder.show()
        }
    }

    fun showActionSheet(title: String, buttonsJson: String) {
        val activity = MobBridge.activity() ?: return
        val buttons = MobAlertCodec.parseButtons(buttonsJson)
        val nonCancel = buttons.filter { it["style"] != "cancel" }
        val cancel    = buttons.firstOrNull { it["style"] == "cancel" }
        val labels    = nonCancel.map { it["label"] ?: "" }.toTypedArray()
        activity.runOnUiThread {
            val builder = android.app.AlertDialog.Builder(activity)
            if (title.isNotEmpty()) builder.setTitle(title)
            builder.setItems(labels) { _, which ->
                val action = nonCancel[which]["action"] ?: "dismiss"
                MobBridge.nativeDeliverAlertAction(action)
            }
            cancel?.let { btn ->
                val action = btn["action"] ?: "dismiss"
                builder.setNegativeButton(btn["label"]) { _, _ -> MobBridge.nativeDeliverAlertAction(action) }
            }
            builder.setOnCancelListener { MobBridge.nativeDeliverAlertAction("dismiss") }
            builder.show()
        }
    }

    fun showToast(message: String, duration: String) {
        val activity = MobBridge.activity() ?: return
        activity.runOnUiThread {
            val dur = if (duration == "long") android.widget.Toast.LENGTH_LONG
                      else android.widget.Toast.LENGTH_SHORT
            android.widget.Toast.makeText(activity, message, dur).show()
        }
    }
}
