package dev.aarav.s1toolkit

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import io.grpc.CallOptions
import io.grpc.ClientCall
import io.grpc.ManagedChannel
import io.grpc.Metadata
import io.grpc.MethodDescriptor
import io.grpc.Status
import io.grpc.okhttp.OkHttpChannelBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Independent, clean-room client for the MoveOS head-unit root diagnostics
 * daemon (TCP port 50005). Written from scratch against the observed wire
 * protocol -- the daemon is weakly typed, so no generated .proto stub is
 * needed, just a request with a single `command` string field and a reply
 * with a `status` int plus a `message` string.
 *
 * No authentication, no ADB, no pairing. Plain IPv6 (usually link-local)
 * over whatever Wi-Fi network both devices currently share.
 */
class ScooterClient(private val host: String, private val port: Int = 50005) {

    private var channel: ManagedChannel? = null

    private object RawBytesMarshaller : MethodDescriptor.Marshaller<ByteArray> {
        override fun stream(value: ByteArray): InputStream = ByteArrayInputStream(value)
        override fun parse(stream: InputStream): ByteArray = stream.readBytes()
    }

    private val executeCommand: MethodDescriptor<ByteArray, ByteArray> =
        MethodDescriptor.newBuilder<ByteArray, ByteArray>()
            .setType(MethodDescriptor.MethodType.UNARY)
            .setFullMethodName(
                MethodDescriptor.generateFullMethodName("wifican.WifiCanRpc", "ExecuteADBCommand"))
            .setRequestMarshaller(RawBytesMarshaller)
            .setResponseMarshaller(RawBytesMarshaller)
            .build()

    suspend fun connect(waitSeconds: Long = 8L) = withContext(Dispatchers.IO) {
        channel?.shutdownNow()
        val target = normalizeHost(host)
        val ch = OkHttpChannelBuilder.forAddress(target, port)
            .usePlaintext()
            .maxInboundMessageSize(64 * 1024 * 1024)
            .build()
        channel = ch
        val (status, _) = exec("id -u", waitSeconds)
        if (!isOk(status)) throw IllegalStateException("No usable reply from $target:$port")
    }

    fun close() {
        try { channel?.shutdownNow() } catch (_: Exception) { }
        channel = null
    }

    /** Runs a raw command string. Daemon splits on whitespace -- use [shell] for anything with quotes/spaces. */
    suspend fun exec(command: String, timeoutSeconds: Long = 30L): Pair<Int, String> =
        unaryCall(buildCommandPayload(command), timeoutSeconds)

    /** Base64-wraps the command so it survives the daemon's naive whitespace split intact. */
    suspend fun shell(command: String, timeoutSeconds: Long = 30L): Pair<Int, String> {
        val b64 = Base64.encodeToString(command.toByteArray(StandardCharsets.UTF_8), Base64.NO_WRAP)
        return exec("sh -c echo\${IFS}$b64|base64\${IFS}-d|sh", timeoutSeconds)
    }

    suspend fun openIntent(action: String, timeoutSeconds: Long = 30L): Pair<Int, String> =
        exec("am start -a $action", timeoutSeconds)

    suspend fun openComponent(component: String, timeoutSeconds: Long = 30L): Pair<Int, String> =
        exec("am start -n $component", timeoutSeconds)

    suspend fun sendKeyEvent(code: Int, timeoutSeconds: Long = 15L): Pair<Int, String> =
        exec("input keyevent $code", timeoutSeconds)

    suspend fun takeScreenshot(): Bitmap = withContext(Dispatchers.IO) {
        val tmp = "/data/local/tmp/_s1toolkit_shot.png"
        val (status, out) = exec("screencap -p $tmp", 60L)
        if (!isOk(status)) throw IllegalStateException("screencap failed: $out")
        val (pullStatus, encoded) = shell("base64 $tmp", 90L)
        if (!isOk(pullStatus)) throw IllegalStateException("read-back failed: $encoded")
        exec("rm -f $tmp", 15L)
        val bytes = Base64.decode(encoded.trim(), Base64.DEFAULT)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            ?: throw IllegalStateException("could not decode screenshot")
    }

    private fun isOk(status: Int) = status == 0 || status == 1

    private fun normalizeHost(raw: String): String {
        var h = raw.trim().removePrefix("[").substringBefore("]")
        if (h.startsWith("fe80", ignoreCase = true) && "%" !in h) {
            throw IllegalArgumentException(
                "Link-local address needs a zone id, e.g. fe80::1%wlan0")
        }
        return h
    }

    private suspend fun unaryCall(payload: ByteArray, timeoutSeconds: Long): Pair<Int, String> =
        withContext(Dispatchers.IO) {
            val ch = channel ?: throw IllegalStateException("not connected")
            val call: ClientCall<ByteArray, ByteArray> = ch.newCall(
                executeCommand, CallOptions.DEFAULT.withDeadlineAfter(timeoutSeconds, TimeUnit.SECONDS))

            val reply = suspendCancellableCoroutine<ByteArray> { cont ->
                call.start(object : ClientCall.Listener<ByteArray>() {
                    override fun onMessage(message: ByteArray) {
                        if (cont.isActive) cont.resume(message)
                    }
                    override fun onClose(status: Status, trailers: Metadata) {
                        if (!status.isOk && cont.isActive) {
                            cont.resumeWithException(status.asRuntimeException())
                        }
                    }
                }, Metadata())
                call.request(1)
                call.sendMessage(payload)
                call.halfClose()
            }
            decodeReply(reply)
        }

    // ---- hand-rolled protobuf wire format: one string field in, one int + one string field out ----

    private fun buildCommandPayload(text: String): ByteArray {
        val raw = text.toByteArray(StandardCharsets.UTF_8)
        val out = java.io.ByteArrayOutputStream()
        out.write(varint((1 shl 3) or 2))
        out.write(varint(raw.size))
        out.write(raw)
        return out.toByteArray()
    }

    private fun decodeReply(buf: ByteArray): Pair<Int, String> {
        var status = 0
        var message = ""
        var i = 0
        while (i < buf.size) {
            val (key, next1) = readVarint(buf, i)
            i = next1
            val fieldNo = key ushr 3
            val wireType = key and 0b111
            when (wireType) {
                0 -> {
                    val (v, next2) = readVarint(buf, i)
                    i = next2
                    if (fieldNo == 1) status = v
                }
                2 -> {
                    val (len, next2) = readVarint(buf, i)
                    i = next2
                    val slice = buf.copyOfRange(i, (i + len).coerceAtMost(buf.size))
                    i += len
                    if (fieldNo == 2) message = String(slice, StandardCharsets.UTF_8)
                }
                else -> return Pair(status, message) // unknown wire type, stop safely
            }
        }
        return Pair(status, message)
    }

    private fun varint(n: Int): ByteArray {
        var value = n
        val out = mutableListOf<Byte>()
        while (true) {
            val b = value and 0x7F
            value = value ushr 7
            out.add((if (value != 0) b or 0x80 else b).toByte())
            if (value == 0) return out.toByteArray()
        }
    }

    private fun readVarint(buf: ByteArray, start: Int): Pair<Int, Int> {
        var i = start
        var value = 0
        var shift = 0
        while (i < buf.size) {
            val b = buf[i].toInt() and 0xFF
            i++
            value = value or ((b and 0x7F) shl shift)
            if (b and 0x80 == 0) return Pair(value, i)
            shift += 7
        }
        return Pair(value, i)
    }
}
