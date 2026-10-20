package com.example.handbean_probe

import android.content.Context
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.filled.List
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import org.json.JSONArray
import org.json.JSONObject

// ── GpuView ──────────────────────────────────────────────────────────────
//
// Fragment-shader-driven GPU surface backed by GLSurfaceView + GLES 3.0.
// Mirrors the iOS Mob.GpuView (MTKView + Metal) — same component API on
// the BEAM side; the shader source is GLSL ES 3.0 instead of MSL.
//
// The host owns the vertex shader (a passthrough that emits a full-screen
// quad with a varying v_uv in (0..1)). The user supplies a fragment
// shader that declares:
//
//   #version 300 es
//   precision highp float;
//   in vec2 v_uv;
//   out vec4 frag_color;
//   layout(std140) uniform Uniforms { ... };
//
// Uniforms arrive as a positional list packed by BEAM in the order the
// user wrote them. We std140-pack into a UBO at GL_BIND_BUFFER_BASE
// index 0, which the shader reads as a Uniforms block.

@Composable
internal fun MobGpuView(node: MobNode, modifier: Modifier) {
    val width = floatProp(node.props, "width") ?: 0f
    val height = floatProp(node.props, "height") ?: 0f

    val shaderSrc: String = when (val raw = node.props["shader"]) {
        is String -> raw
        is JSONObject -> raw.optString("android", "")
        is Map<*, *> -> (raw["android"] as? String) ?: ""
        else -> ""
    }

    val uniformBytes: ByteArray = packGpuUniforms(node.props["uniforms"])

    val sized = if (width > 0f && height > 0f) {
        modifier.size(width.dp, height.dp)
    } else {
        modifier
    }

    // Surface the GL renderer's compile-error state to Compose so we can
    // overlay it on the failed view (parity with iOS MobGpuView). The
    // renderer runs on the GLSurfaceView's GL thread; the callback bounces
    // back to the main thread via mutableStateOf to keep Compose happy.
    val compileError = remember { mutableStateOf<String?>(null) }

    Box(modifier = sized) {
        AndroidView(
            factory = { ctx ->
                MobGpuSurfaceView(ctx) { err ->
                    ctx.mainExecutor.execute { compileError.value = err }
                }.also { v ->
                    v.applyShader(shaderSrc)
                    v.applyUniforms(uniformBytes)
                }
            },
            update = { view ->
                view.applyShader(shaderSrc)
                view.applyUniforms(uniformBytes)
            }
        )
        compileError.value?.let { err ->
            // Translucent red overlay matches the iOS MobGpuView contract:
            // a broken shader stays visible (not invisible) and the error
            // text is right on top of the offending view.
            Text(
                text = err,
                modifier = Modifier
                    .fillMaxSize()
                    .background(androidx.compose.ui.graphics.Color(0xC0FF0000))
                    .padding(8.dp),
                color = androidx.compose.ui.graphics.Color.White,
                fontSize = 12.sp
            )
        }
    }
}

private fun packGpuUniforms(raw: Any?): ByteArray {
    val list: List<Any?> = when (raw) {
        is JSONArray -> (0 until raw.length()).map { raw.get(it) }
        is List<*> -> raw
        else -> return ByteArray(0)
    }

    // std140-ish packing — matches the iOS-side Swift packer:
    //   number (Double/Long/Int) -> 4 bytes at 4-byte align
    //   JSONArray/List of 2      -> 8 bytes (float2) at 8-byte align
    //   JSONArray/List of 4      -> 16 bytes (float4) at 16-byte align
    //   float3 not supported in v1.
    //
    // The shader-side std140 Uniforms block reads members in the same
    // order. User is responsible for declaring matching positions.
    val sink = java.io.ByteArrayOutputStream()

    fun alignTo(n: Int) {
        val pad = (n - sink.size() % n) % n
        repeat(pad) { sink.write(0) }
    }

    fun writeF32(f: Float) {
        val bb = ByteBuffer.allocate(4).order(ByteOrder.nativeOrder())
        bb.putFloat(f)
        sink.write(bb.array())
    }

    fun writeI32(i: Int) {
        val bb = ByteBuffer.allocate(4).order(ByteOrder.nativeOrder())
        bb.putInt(i)
        sink.write(bb.array())
    }

    for (v in list) {
        when (v) {
            is Long -> {
                alignTo(4)
                writeI32(v.toInt())
            }
            is Int -> {
                alignTo(4)
                writeI32(v)
            }
            is Number -> {
                alignTo(4)
                writeF32(v.toFloat())
            }
            is JSONArray -> {
                val n = v.length()
                if (n == 2) {
                    alignTo(8)
                    writeF32(v.getDouble(0).toFloat())
                    writeF32(v.getDouble(1).toFloat())
                } else if (n == 4) {
                    alignTo(16)
                    for (i in 0 until 4) writeF32(v.getDouble(i).toFloat())
                }
            }
            is List<*> -> {
                val n = v.size
                if (n == 2) {
                    alignTo(8)
                    for (i in 0 until 2) writeF32((v[i] as Number).toFloat())
                } else if (n == 4) {
                    alignTo(16)
                    for (i in 0 until 4) writeF32((v[i] as Number).toFloat())
                }
            }
        }
    }
    return sink.toByteArray()
}

private class MobGpuSurfaceView(
    context: android.content.Context,
    onCompileError: (String?) -> Unit = {}
) : GLSurfaceView(context) {
    private val renderer = MobGpuRenderer(onCompileError)

    init {
        setEGLContextClientVersion(3)
        setRenderer(renderer)
        renderMode = RENDERMODE_CONTINUOUSLY
    }

    fun applyShader(source: String) {
        queueEvent { renderer.recompile(source) }
        requestRender()
    }

    fun applyUniforms(bytes: ByteArray) {
        queueEvent { renderer.uniformBytes = bytes }
        requestRender()
    }
}

private class MobGpuRenderer(private val onCompileError: (String?) -> Unit) :
    GLSurfaceView.Renderer {
    @Volatile
    var uniformBytes: ByteArray = ByteArray(0)

    private var program = 0
    private var ubo = 0
    private var vbo = 0
    private var vao = 0
    private var pendingSource: String? = null
    private var currentHash: Int = 0
    private var compileError: String? = null
    private var viewportW = 1
    private var viewportH = 1

    private fun setCompileError(err: String?) {
        if (err == compileError) return
        compileError = err
        onCompileError(err)
    }

    private val passthroughVertex = """
        #version 300 es
        in vec2 a_pos;
        out vec2 v_uv;
        void main() {
            gl_Position = vec4(a_pos, 0.0, 1.0);
            v_uv = a_pos * 0.5 + 0.5;
        }
    """.trimIndent()

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Full-screen quad as a triangle strip in NDC.
        val verts = floatArrayOf(
            -1f, -1f,
             1f, -1f,
            -1f,  1f,
             1f,  1f
        )
        val bb = ByteBuffer.allocateDirect(verts.size * 4).order(ByteOrder.nativeOrder())
        val fb = bb.asFloatBuffer()
        fb.put(verts).position(0)

        val vbos = IntArray(1); GLES30.glGenBuffers(1, vbos, 0); vbo = vbos[0]
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, verts.size * 4, fb, GLES30.GL_STATIC_DRAW)

        val vaos = IntArray(1); GLES30.glGenVertexArrays(1, vaos, 0); vao = vaos[0]
        GLES30.glBindVertexArray(vao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 0, 0)

        val ubos = IntArray(1); GLES30.glGenBuffers(1, ubos, 0); ubo = ubos[0]
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        viewportW = width; viewportH = height
        GLES30.glViewport(0, 0, width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        pendingSource?.let {
            compileNow(it)
            pendingSource = null
        }

        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        if (program == 0) return

        GLES30.glUseProgram(program)

        // Upload uniforms as UBO contents bound at binding point 0.
        if (uniformBytes.isNotEmpty()) {
            GLES30.glBindBuffer(GLES30.GL_UNIFORM_BUFFER, ubo)
            val bb = ByteBuffer.wrap(uniformBytes)
            GLES30.glBufferData(GLES30.GL_UNIFORM_BUFFER, uniformBytes.size, bb, GLES30.GL_DYNAMIC_DRAW)
            GLES30.glBindBufferBase(GLES30.GL_UNIFORM_BUFFER, 0, ubo)
        }

        GLES30.glBindVertexArray(vao)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
    }

    fun recompile(source: String) {
        val hash = source.hashCode()
        if (hash == currentHash && program != 0) return
        currentHash = hash
        pendingSource = source
    }

    private fun compileNow(source: String) {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, passthroughVertex) ?: return
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, source) ?: run {
            GLES30.glDeleteShader(vs)
            return
        }

        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glBindAttribLocation(prog, 0, "a_pos")
        GLES30.glLinkProgram(prog)
        val status = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            setCompileError("link: " + GLES30.glGetProgramInfoLog(prog))
            GLES30.glDeleteProgram(prog)
            GLES30.glDeleteShader(vs); GLES30.glDeleteShader(fs)
            program = 0
            return
        }

        // Bind the shader's `Uniforms` block to binding point 0.
        val blockIdx = GLES30.glGetUniformBlockIndex(prog, "Uniforms")
        if (blockIdx != GLES30.GL_INVALID_INDEX) {
            GLES30.glUniformBlockBinding(prog, blockIdx, 0)
        }

        if (program != 0) GLES30.glDeleteProgram(program)
        program = prog
        setCompileError(null)
        GLES30.glDeleteShader(vs); GLES30.glDeleteShader(fs)
    }

    private fun compileShader(type: Int, source: String): Int? {
        val s = GLES30.glCreateShader(type)
        GLES30.glShaderSource(s, source)
        GLES30.glCompileShader(s)
        val status = IntArray(1)
        GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            setCompileError(GLES30.glGetShaderInfoLog(s))
            GLES30.glDeleteShader(s)
            return null
        }
        return s
    }
}
