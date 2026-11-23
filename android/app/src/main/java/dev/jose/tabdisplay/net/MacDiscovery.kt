package dev.jose.tabdisplay.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.Executors

/**
 * Descubre la Mac por Bonjour/NSD (`_tabdisplay._tcp`) para el modo Wi-Fi.
 * Mantiene la última dirección resuelta; StreamClient la consulta al reintentar.
 */
class MacDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()
    private val resolved = LinkedHashMap<String, InetSocketAddress>()
    private var listener: NsdManager.DiscoveryListener? = null
    private val infoCallbacks = HashMap<String, NsdManager.ServiceInfoCallback>()
    private var resolving = false
    private val pendingResolve = ArrayDeque<NsdServiceInfo>()

    /** Última Mac resuelta (o null). */
    val latest: InetSocketAddress?
        @Synchronized get() = resolved.values.lastOrNull()

    @Synchronized
    fun start() {
        if (listener != null) return
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "NSD: buscando $serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) = resolve(serviceInfo)

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                synchronized(this@MacDiscovery) {
                    resolved.remove(serviceInfo.serviceName)
                    infoCallbacks.remove(serviceInfo.serviceName)?.let { unregisterInfoCallback(it) }
                }
                Log.i(TAG, "NSD: perdida ${serviceInfo.serviceName}")
            }

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "NSD: no se pudo iniciar la búsqueda ($errorCode)")
                synchronized(this@MacDiscovery) { listener = null }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        listener = discoveryListener
        nsd.discoverServices(Protocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    @Synchronized
    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        infoCallbacks.values.forEach { unregisterInfoCallback(it) }
        infoCallbacks.clear()
        resolved.clear()
        pendingResolve.clear()
        resolving = false
    }

    private fun resolve(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resolveWithCallback(info)
        } else {
            resolveLegacy(info)
        }
    }

    // API 34+: callback que además avisa si la Mac cambia de IP.
    private fun resolveWithCallback(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        synchronized(this) {
            if (infoCallbacks.containsKey(info.serviceName)) return
        }
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                Log.w(TAG, "NSD: falló resolver ${info.serviceName} ($errorCode)")
                synchronized(this@MacDiscovery) { infoCallbacks.remove(info.serviceName) }
            }

            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                val address = pickAddress(serviceInfo.hostAddresses) ?: return
                store(serviceInfo.serviceName, InetSocketAddress(address, serviceInfo.port))
            }

            override fun onServiceLost() {
                synchronized(this@MacDiscovery) { resolved.remove(info.serviceName) }
            }

            override fun onServiceInfoCallbackUnregistered() {}
        }
        synchronized(this) { infoCallbacks[info.serviceName] = callback }
        nsd.registerServiceInfoCallback(info, executor, callback)
    }

    // API 31–33: resolveService solo admite una resolución a la vez.
    @Suppress("DEPRECATION")
    private fun resolveLegacy(info: NsdServiceInfo) {
        synchronized(this) {
            if (resolving) {
                pendingResolve.addLast(info)
                return
            }
            resolving = true
        }
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD: falló resolver ${serviceInfo.serviceName} ($errorCode)")
                next()
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val host = serviceInfo.host
                if (host != null) store(serviceInfo.serviceName, InetSocketAddress(host, serviceInfo.port))
                next()
            }

            private fun next() {
                val nextInfo = synchronized(this@MacDiscovery) {
                    resolving = false
                    pendingResolve.removeFirstOrNull()
                }
                if (nextInfo != null) resolveLegacy(nextInfo)
            }
        })
    }

    private fun unregisterInfoCallback(callback: NsdManager.ServiceInfoCallback) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            runCatching { nsd.unregisterServiceInfoCallback(callback) }
        }
    }

    private fun store(name: String, address: InetSocketAddress) {
        synchronized(this) {
            resolved.remove(name)
            resolved[name] = address
        }
        Log.i(TAG, "NSD: $name en $address")
    }

    // Preferimos IPv4: evita direcciones IPv6 link-local que requieren scope.
    private fun pickAddress(addresses: List<InetAddress>): InetAddress? =
        addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()

    private companion object {
        const val TAG = "TabDisplay"
    }
}
