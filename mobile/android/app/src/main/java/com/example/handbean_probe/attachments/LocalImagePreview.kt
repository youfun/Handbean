package com.example.handbean_probe.attachments

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import android.graphics.Bitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp

@Composable
fun LocalImagePreview(
    src: String?,
    maxEdge: Int,
    contentDescription: String?,
    fallback: String,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
    uploadOnly: Boolean = false,
) {
    val bitmap by produceState<Bitmap?>(null, src, maxEdge, uploadOnly) {
        value = null
        value = withContext(Dispatchers.IO) {
            LocalImageDecoder.decode(src, maxEdge, uploadOnly)
        }
    }
    val label = contentDescription ?: fallback
    val loaded = bitmap
    if (loaded != null) {
        Image(
            bitmap = loaded.asImageBitmap(),
            contentDescription = label,
            contentScale = contentScale,
            modifier = modifier,
        )
    } else {
        Box(
            modifier = modifier
                .background(Color(0xFFF4F3F0))
                .semantics { this.contentDescription = label },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = fallback,
                fontSize = 10.sp,
                color = Color(0xFF6B6560),
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}
