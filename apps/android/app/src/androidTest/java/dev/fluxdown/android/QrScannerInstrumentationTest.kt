package dev.fluxdown.android

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QrScannerInstrumentationTest {
    @Test
    fun mlKitRecognizesHttpDownloadQrEntity() {
        val expected = "https://example.test/assets/demo.bin"
        val bitmap = qrBitmap(expected)
        val scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
        val latch = CountDownLatch(1)
        var actual: String? = null
        var failure: Exception? = null

        scanner.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { barcodes ->
                actual = barcodes.firstOrNull()?.rawValue ?: barcodes.firstOrNull()?.displayValue
                latch.countDown()
            }
            .addOnFailureListener {
                failure = it
                latch.countDown()
            }

        assertTrue("ML Kit 扫码应在限定时间内返回", latch.await(10, TimeUnit.SECONDS))
        scanner.close()
        bitmap.recycle()
        assertTrue("ML Kit 扫码失败: ${failure?.message}", failure == null)
        assertEquals(expected, actual)
    }

    private fun qrBitmap(value: String): Bitmap {
        val matrix = MultiFormatWriter().encode(value, BarcodeFormat.QR_CODE, 640, 640)
        val bitmap = Bitmap.createBitmap(matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
        for (x in 0 until matrix.width) {
            for (y in 0 until matrix.height) {
                bitmap.setPixel(x, y, if (matrix[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
            }
        }
        return bitmap
    }
}
