package com.example.handbean_probe

import android.animation.ValueAnimator
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.round

private const val STARTUP_HOP_MILLIS = 1_500
private const val STARTUP_PALETTE_CYCLE_MILLIS = STARTUP_HOP_MILLIS * 12

private val STARTUP_SURFACE = Color(0xFFFAF9F7)
private val STARTUP_OUTLINE = Color(0xFF263B25)
private val STARTUP_HIGHLIGHT = Color(0xFFF1EFB5)
private val STARTUP_CHEEK = Color(0xFFDB9968)
private val STARTUP_SHADOW = Color(0xFF9C9590)

// NativeUI.bean_colors/0, rotated so the startup sequence begins with the
// familiar purple bean. This is presentation data only; it is not Agent state.
private val STARTUP_BEAN_COLORS = listOf(
    Color(0xFFC75DAE),
    Color(0xFF8B79D8),
    Color(0xFF6C9ADD),
    Color(0xFF3EBD79),
    Color(0xFF89C351),
    Color(0xFFC78049),
    Color(0xFFAF6C59),
    Color(0xFFE4BD3F),
    Color(0xFFED9438),
    Color(0xFFE66C55),
    Color(0xFFDC5362),
    Color(0xFFD878A1),
)

@Composable
internal fun HandbeanStartup(visible: Boolean) {
    AnimatedVisibility(
        visible = visible,
        enter = EnterTransition.None,
        exit = fadeOut(animationSpec = tween(durationMillis = 220)),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(STARTUP_SURFACE),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                val cycleProgress = startupCycleProgress()
                StartupBean(cycleProgress)
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        text = stringResource(R.string.starting_handbean),
                        color = Color(0xFF1A1815),
                        fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    StartupDots(cycleProgress)
                }
            }
        }
    }
}

@Composable
private fun StartupBean(cycleProgress: Float) {
    val cycle = floor(cycleProgress).toInt() % STARTUP_BEAN_COLORS.size
    val phase = cycleProgress - floor(cycleProgress)
    val from = STARTUP_BEAN_COLORS[cycle]
    val to = STARTUP_BEAN_COLORS[(cycle + 1) % STARTUP_BEAN_COLORS.size]
    val beanColor = lerp(from, to, colorProgress(phase))
    val motion = startupMotion(phase)
    val paths = remember { StartupBeanPaths() }
    val paint = remember { Paint().apply { isAntiAlias = false } }

    Canvas(modifier = Modifier.size(width = 120.dp, height = 130.dp)) {
        // Draw every logical sprite pixel as the same whole number of physical
        // pixels. Turning antialiasing off is not enough when the scale itself
        // is fractional: adjacent blocks can otherwise rasterize at different
        // widths on common 2.625x-density displays.
        val pixelScale = floor(min(size.width / 24f, size.height / 26f)).coerceAtLeast(1f)
        val originX = round((size.width - 24f * pixelScale) / 2f)
        val originY = round((size.height - 26f * pixelScale) / 2f)
        val outline = lerp(STARTUP_OUTLINE, beanColor, 0.45f)
        val highlight = lerp(STARTUP_HIGHLIGHT, beanColor, 0.65f)
        val shade = lerp(STARTUP_OUTLINE, beanColor, 0.75f)

        drawIntoCanvas { canvas ->
            fun draw(path: Path, color: Color, x: Float = 0f, y: Float = 0f) {
                canvas.save()
                canvas.translate(x, y)
                paint.color = color
                canvas.drawPath(path, paint)
                canvas.restore()
            }

            canvas.save()
            canvas.translate(originX, originY)
            canvas.scale(pixelScale, pixelScale)

            draw(
                when (motion.shadowInset) {
                    3 -> paths.shadowPeak
                    1 -> paths.shadowMid
                    else -> paths.shadowFull
                },
                STARTUP_SHADOW.copy(alpha = motion.shadowAlpha),
            )

            canvas.save()
            canvas.translate(0f, motion.characterY)

            draw(paths.legLeft, outline, y = motion.legLeftY)
            draw(paths.legRight, outline, y = motion.legRightY)

            draw(paths.armLeftStem, outline, y = motion.armY)
            draw(paths.armLeftHand, beanColor, y = motion.armY)
            draw(paths.armRightStem, outline, y = motion.armY)
            draw(paths.armRightHand, beanColor, y = motion.armY)

            draw(paths.leafOutline, outline, x = motion.leafX)
            draw(paths.leafFill, beanColor, x = motion.leafX)
            draw(paths.leafHighlight, highlight, x = motion.leafX)

            draw(paths.bodyOutline, outline)
            draw(paths.bodyFill, beanColor)
            draw(paths.bodyHighlight, highlight)
            draw(paths.bodyShade, shade)
            draw(paths.eyes, STARTUP_OUTLINE)
            draw(paths.cheeks, STARTUP_CHEEK)

            canvas.restore()
            canvas.restore()
        }
    }
}

@Composable
private fun StartupDots(progress: Float) {
    val phase = progress - floor(progress)
    val colorIndex = floor(progress).toInt() % STARTUP_BEAN_COLORS.size
    val beanColor = lerp(
        STARTUP_BEAN_COLORS[colorIndex],
        STARTUP_BEAN_COLORS[(colorIndex + 1) % STARTUP_BEAN_COLORS.size],
        colorProgress(phase),
    )

    Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        repeat(3) { index ->
            Box(
                Modifier
                    .size(6.dp)
                    .background(beanColor.copy(alpha = dotAlpha(index, phase))),
            )
        }
    }
}

@Composable
private fun startupCycleProgress(): Float {
    if (!ValueAnimator.areAnimatorsEnabled()) return 0f

    val transition = rememberInfiniteTransition(label = "Handbean startup")
    val progress by transition.animateFloat(
        initialValue = 0f,
        targetValue = STARTUP_BEAN_COLORS.size.toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = STARTUP_PALETTE_CYCLE_MILLIS,
                easing = LinearEasing,
            ),
            repeatMode = RepeatMode.Restart,
        ),
        label = "Startup hop and palette",
    )
    return progress
}

private fun colorProgress(phase: Float): Float {
    val linear = ((phase - 0.16f) / 0.40f).coerceIn(0f, 1f)
    return linear * linear * (3f - 2f * linear)
}

private fun dotAlpha(index: Int, phase: Float): Float {
    val shifted = (phase - index * 0.08f + 1f) % 1f
    return if (shifted < 0.18f) 1f else 0.25f
}

private data class StartupMotion(
    val characterY: Float = 0f,
    val armY: Float = 0f,
    val leafX: Float = 0f,
    val legLeftY: Float = 0f,
    val legRightY: Float = 0f,
    val shadowInset: Int = 0,
    val shadowAlpha: Float = 0.22f,
)

private fun startupMotion(phase: Float): StartupMotion = when {
    phase < 0.10f -> StartupMotion()
    phase < 0.18f -> StartupMotion(
        characterY = 1f,
        legLeftY = -1f,
        legRightY = -1f,
    )
    phase < 0.26f -> StartupMotion(
        characterY = -1f,
        armY = -1f,
        leafX = 1f,
        shadowInset = 1,
        shadowAlpha = 0.16f,
    )
    phase < 0.40f -> StartupMotion(
        characterY = -2f,
        armY = -2f,
        leafX = if (phase < 0.33f) 1f else -1f,
        shadowInset = 3,
        shadowAlpha = 0.10f,
    )
    phase < 0.48f -> StartupMotion(
        characterY = -1f,
        armY = -1f,
        leafX = -1f,
        shadowInset = 1,
        shadowAlpha = 0.16f,
    )
    phase < 0.56f -> StartupMotion(
        characterY = 1f,
        legLeftY = -1f,
        legRightY = -1f,
    )
    else -> StartupMotion()
}

private class StartupBeanPaths {
    val shadowFull = rectPath(6f, 24f, 18f, 25f)
    val shadowMid = rectPath(7f, 24f, 17f, 25f)
    val shadowPeak = rectPath(9f, 24f, 15f, 25f)
    val legLeft = polygonPath(8f, 21f, 10f, 21f, 10f, 24f, 7f, 24f, 7f, 23f, 8f, 23f)
    val legRight = polygonPath(15f, 21f, 17f, 21f, 17f, 23f, 18f, 23f, 18f, 24f, 15f, 24f)
    val armLeftStem = rectPath(4f, 16f, 5f, 20f)
    val armLeftHand = rectPath(3f, 19f, 5f, 21f)
    val armRightStem = rectPath(19f, 16f, 20f, 20f)
    val armRightHand = rectPath(19f, 19f, 21f, 21f)
    val leafOutline = Path().apply {
        addRect(Rect(11f, 5f, 12f, 8f))
        addRect(Rect(11f, 3f, 12f, 6f))
        addPath(
            polygonPath(
                12f, 2f, 16f, 2f, 16f, 3f, 17f, 3f, 17f, 4f,
                16f, 4f, 16f, 5f, 12f, 5f, 12f, 4f, 11f, 4f, 11f, 3f, 12f, 3f,
            ),
        )
    }
    val leafFill = rectPath(12f, 3f, 16f, 4f)
    val leafHighlight = rectPath(13f, 2f, 15f, 3f)
    val bodyOutline = polygonPath(
        9f, 8f, 15f, 8f, 15f, 9f, 17f, 9f, 17f, 10f, 18f, 10f,
        18f, 11f, 19f, 11f, 19f, 21f, 18f, 21f, 18f, 22f, 17f, 22f,
        17f, 23f, 7f, 23f, 7f, 22f, 6f, 22f, 6f, 21f, 5f, 21f,
        5f, 11f, 6f, 11f, 6f, 10f, 7f, 10f, 7f, 9f, 9f, 9f,
    )
    val bodyFill = polygonPath(
        9f, 9f, 15f, 9f, 15f, 10f, 17f, 10f, 17f, 11f, 18f, 11f,
        18f, 21f, 17f, 21f, 17f, 22f, 7f, 22f, 7f, 21f, 6f, 21f,
        6f, 11f, 7f, 11f, 7f, 10f, 9f, 10f,
    )
    val bodyHighlight = polygonPath(
        9f, 9f, 15f, 9f, 15f, 10f, 14f, 10f, 14f, 11f, 12f, 11f,
        12f, 12f, 8f, 12f, 8f, 13f, 7f, 13f, 7f, 11f, 8f, 11f,
        8f, 10f, 9f, 10f,
    )
    val bodyShade = polygonPath(
        17f, 17f, 18f, 17f, 18f, 21f, 17f, 21f, 17f, 22f, 7f, 22f,
        7f, 21f, 15f, 21f, 15f, 20f, 16f, 20f, 16f, 19f, 17f, 19f,
    )
    val eyes = Path().apply {
        addRect(Rect(8f, 14f, 10f, 16f))
        addRect(Rect(14f, 14f, 16f, 16f))
    }
    val cheeks = Path().apply {
        addRect(Rect(7f, 17f, 8f, 18f))
        addRect(Rect(16f, 17f, 17f, 18f))
    }
}

private fun rectPath(left: Float, top: Float, right: Float, bottom: Float) =
    Path().apply { addRect(Rect(left, top, right, bottom)) }

private fun polygonPath(vararg coordinates: Float) = Path().apply {
    require(coordinates.size >= 6 && coordinates.size % 2 == 0)
    moveTo(coordinates[0], coordinates[1])
    var index = 2
    while (index < coordinates.size) {
        lineTo(coordinates[index], coordinates[index + 1])
        index += 2
    }
    close()
}
