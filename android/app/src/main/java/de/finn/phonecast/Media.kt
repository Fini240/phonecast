package de.finn.phonecast

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Bundle
import android.util.Log
import android.view.Surface

/** Hardware H.264 encoder fed by a Surface (the virtual display draws straight into it). */
class VideoEncoder(
    val width: Int,
    val height: Int,
    bitrate: Int,
    fps: Int,
    private val sink: StreamServer,
) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    val surface: Surface
    @Volatile private var alive = true
    private val thread: Thread

    init {
        val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 3)
            // keep sending frames when the screen is static so the Mac never stalls
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            // ask the encoder to hand out each frame as soon as it is done
            setInteger(MediaFormat.KEY_LATENCY, 1)
            setInteger("vendor.qti-ext-enc-low-latency.enable", 1) // Qualcomm (Fold7)
            setInteger(MediaFormat.KEY_OPERATING_RATE, fps * 2)
        }
        codec.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
        thread = Thread({ drain() }, "pc-encode").also { it.start() }
    }

    fun requestKeyFrame() {
        try {
            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (_: Exception) {}
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        while (alive) {
            val idx = try {
                codec.dequeueOutputBuffer(info, 50_000)
            } catch (e: Exception) {
                break
            }
            if (idx < 0) continue
            try {
                val buf = codec.getOutputBuffer(idx)
                if (buf != null && info.size > 0) {
                    val bytes = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.get(bytes)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        sink.onConfig(bytes)
                    } else {
                        sink.onFrame(bytes, info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0)
                    }
                }
                codec.releaseOutputBuffer(idx, false)
            } catch (e: Exception) {
                if (alive) Log.w("PhoneCast", "encoder output error", e)
                break
            }
        }
    }

    fun release() {
        alive = false
        try { thread.join(300) } catch (_: Exception) {}
        try { codec.stop() } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}
        try { surface.release() } catch (_: Exception) {}
    }
}

/** Captures what apps are playing (games, media) - not the microphone. */
class AudioCapture(projection: MediaProjection, private val sink: StreamServer) {
    private val record: AudioRecord
    @Volatile private var alive = true
    private val thread: Thread

    init {
        val cfg = AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val fmt = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(48_000)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val min = AudioRecord.getMinBufferSize(48_000, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        record = buildRecord(cfg, fmt, maxOf(min, 48_000 * 4 / 10))
        thread = Thread({ loop() }, "pc-audio").also { it.start() }
    }

    @SuppressLint("MissingPermission") // checked by the caller
    private fun buildRecord(cfg: AudioPlaybackCaptureConfiguration, fmt: AudioFormat, size: Int) =
        AudioRecord.Builder()
            .setAudioFormat(fmt)
            .setBufferSizeInBytes(size)
            .setAudioPlaybackCaptureConfig(cfg)
            .build()

    private fun loop() {
        try {
            record.startRecording()
            val buf = ByteArray(1920) // 10 ms
            while (alive) {
                val n = record.read(buf, 0, buf.size)
                if (n > 0) sink.onAudio(buf.copyOf(n))
                else if (n < 0) break
            }
        } catch (e: Exception) {
            Log.w("PhoneCast", "audio capture stopped", e)
        }
    }

    fun release() {
        alive = false
        try { record.stop() } catch (_: Exception) {}
        try { thread.join(300) } catch (_: Exception) {}
        try { record.release() } catch (_: Exception) {}
    }
}
