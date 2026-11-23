package dev.jose.tabdisplay

import android.app.Activity
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.provider.Settings
import android.view.Display
import dev.jose.tabdisplay.net.CodecSupport
import dev.jose.tabdisplay.video.VideoDecoder
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Datos del panel y de los decodificadores que la tablet reporta en HELLO. */
data class DeviceInfo(
    val deviceName: String,
    val widthPx: Int,
    val heightPx: Int,
    val densityDpi: Int,
    val refreshRates: List<Int>,
    val codecs: List<CodecSupport>,
) {
    companion object {
        private val MIMES = listOf(MediaFormat.MIMETYPE_VIDEO_AVC, MediaFormat.MIMETYPE_VIDEO_HEVC)

        fun collect(activity: Activity): DeviceInfo {
            // Tamaño físico completo del panel, en horizontal (ancho ≥ alto).
            val bounds = activity.windowManager.maximumWindowMetrics.bounds
            val width = max(bounds.width(), bounds.height())
            val height = min(bounds.width(), bounds.height())

            val metrics = activity.resources.displayMetrics
            val dpi = if (metrics.xdpi > 0) metrics.xdpi.roundToInt() else metrics.densityDpi

            val display: Display? = activity.display
            val refreshRates = display?.supportedModes
                ?.filter { max(it.physicalWidth, it.physicalHeight) == width }
                ?.map { it.refreshRate.roundToInt() }
                ?.distinct()
                ?.sorted()
                ?.takeIf { it.isNotEmpty() }
                ?: listOf(60)

            val name = Settings.Global.getString(activity.contentResolver, Settings.Global.DEVICE_NAME)
                ?.takeIf { it.isNotBlank() } ?: Build.MODEL

            return DeviceInfo(name, width, height, dpi, refreshRates, codecSupport(width, height))
        }

        private fun codecSupport(width: Int, height: Int): List<CodecSupport> = MIMES.mapNotNull { mime ->
            val info = VideoDecoder.findDecoder(mime) ?: return@mapNotNull null
            val caps = info.getCapabilitiesForType(mime)
            val video = caps.videoCapabilities
            CodecSupport(
                mime = mime,
                lowLatency = caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency),
                max60 = video?.areSizeAndRateSupported(width, height, 60.0) == true,
                max120 = video?.areSizeAndRateSupported(width, height, 120.0) == true,
            )
        }
    }
}
