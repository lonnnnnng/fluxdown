package dev.fluxdown.android.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.io.Closeable

/**
 * 作者: long
 * S1「仅在 Wi-Fi 下下载」需要区分"当前是否有可用网络"和"这个网络是否计费"。
 * 这里统一用 ConnectivityManager 的默认网络能力判断，避免用已废弃的 NetworkInfo。
 */
internal object NetworkStatus {

    private fun capabilities(context: Context): NetworkCapabilities? {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val network = manager.activeNetwork ?: return null
        return manager.getNetworkCapabilities(network)
    }

    fun isOnline(context: Context): Boolean =
        capabilities(context)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true

    /** 已连上 Wi-Fi 且网络可用。 */
    fun isWifiConnected(context: Context): Boolean {
        val caps = capabilities(context) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    /** 当前网络计费（移动数据、按流量计费的 Wi-Fi 热点）。 */
    fun isMetered(context: Context): Boolean {
        val caps = capabilities(context) ?: return true
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    /**
     * 注册默认网络回调，在"变成 Wi-Fi 可用"时回调一次。
     * 返回的 Closeable 用于在 ViewModel 清理时注销，避免泄漏。
     */
    fun registerWifiWatcher(context: Context, onWifiAvailable: () -> Unit): Closeable {
        val manager = context.getSystemService(ConnectivityManager::class.java)
            ?: return Closeable { }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (isWifiConnected(context)) onWifiAvailable()
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                ) {
                    onWifiAvailable()
                }
            }
        }
        return runCatching {
            manager.registerDefaultNetworkCallback(callback)
            Closeable { runCatching { manager.unregisterNetworkCallback(callback) } }
        }.getOrElse { Closeable { } }
    }
}
