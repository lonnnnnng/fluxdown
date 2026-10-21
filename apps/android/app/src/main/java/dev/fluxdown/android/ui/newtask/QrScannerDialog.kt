package dev.fluxdown.android.ui.newtask
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.core.content.ContextCompat
import dev.fluxdown.android.data.*
import kotlinx.coroutines.launch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun QrScannerDialog(
    onDismiss: () -> Unit,
    onResult: (String) -> Unit,
) {
    val context = LocalContext.current
    val language = LocalLanguage.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasPermission by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var error by remember { mutableStateOf<String?>(null) }
    val handled = remember { AtomicBoolean(false) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasPermission = granted
        if (!granted) error = trIn(language, Str.CameraPermissionNeeded)
    }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (!hasPermission) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxSize(0.86f).padding(16.dp),
            shape = RoundedCornerShape(18.dp),
            color = Color.Black,
        ) {
            if (!hasPermission) {
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text(tr(Str.CameraUnavailable), color = Color.White, fontSize = 18.sp)
                    Spacer(Modifier.height(8.dp))
                    Text(error ?: tr(Str.CameraPermissionRetry), color = FluxPalette.borderAlt2, fontSize = 13.sp)
                    Spacer(Modifier.height(18.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(onClick = onDismiss) { Text(tr(Str.Cancel)) }
                        Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) { Text(tr(Str.Reauthorize)) }
                    }
                }
            } else {
                Box(Modifier.fillMaxSize()) {
                    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { previewView },
                    )
                    androidx.compose.runtime.DisposableEffect(previewView, lifecycleOwner) {
                        val executor = Executors.newSingleThreadExecutor()
                        val mainExecutor = ContextCompat.getMainExecutor(context)
                        val disposed = AtomicBoolean(false)
                        val scanner = BarcodeScanning.getClient(
                            BarcodeScannerOptions.Builder()
                                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                                .build(),
                        )
                        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
                        val listener = Runnable {
                            runCatching {
                                val provider = cameraProviderFuture.get()
                                // 作者: long
                                // 用户快速关闭扫码弹框时，异步 provider 回调仍可能晚到；在绑定生命周期前再次检查，
                                // 防止已经释放的分析器被重新绑定到相机。
                                if (disposed.get()) return@runCatching
                                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                                val analysis = ImageAnalysis.Builder()
                                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                    .build()
                                    analysis.setAnalyzer(executor) { imageProxy ->
                                        val mediaImage = imageProxy.image
                                    if (mediaImage == null || handled.get() || disposed.get()) {
                                            imageProxy.close()
                                            return@setAnalyzer
                                        }
                                        // 作者: long
                                        // 每次只接收第一个有效链接并立即停止回调，避免同一二维码连续创建多个下载任务。
                                        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                                    scanner.process(image)
                                        .addOnSuccessListener { barcodes ->
                                            if (handled.get() || disposed.get()) return@addOnSuccessListener
                                            val value = firstValidatedQrDownloadSource(
                                                barcodes.map { it.rawValue to it.displayValue },
                                            ) { candidate ->
                                                ProtocolDetector.detect(candidate)
                                            }
                                            // 作者: long
                                            // ML Kit 可能识别出普通文本；只有 Rust 返回明确协议时才回填，避免 null 被误判为可下载链接。
                                            if (value != null) {
                                                if (!handled.compareAndSet(false, true)) return@addOnSuccessListener
                                                mainExecutor.execute { onResult(value) }
                                            } else if (barcodes.any { (it.rawValue ?: it.displayValue)?.trim()?.let { value -> value.isNotEmpty() && value.length <= 8192 } == true }) {
                                                mainExecutor.execute { error = trIn(language, Str.QrNotALink) }
                                            }
                                        }
                                        .addOnFailureListener { mainExecutor.execute { error = trIn(language, Str.QrScanFailed) } }
                                        .addOnCompleteListener { imageProxy.close() }
                                }
                                provider.unbindAll()
                                provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                            }.onFailure { mainExecutor.execute { error = trIn(language, Str.CameraStartFailed, it.message ?: trIn(language, Str.UnknownError)) } }
                        }
                        cameraProviderFuture.addListener(listener, ContextCompat.getMainExecutor(context))
                        onDispose {
                            disposed.set(true)
                            if (cameraProviderFuture.isDone) runCatching { cameraProviderFuture.get().unbindAll() }
                            scanner.close()
                            executor.shutdown()
                        }
                    }
                    Column(
                        Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(tr(Str.QrScanHint), color = Color.White, fontSize = 13.sp)
                        Spacer(Modifier.height(10.dp))
                        OutlinedButton(onClick = onDismiss) { Text(tr(Str.Cancel)) }
                    }
                }
            }
        }
    }
}
