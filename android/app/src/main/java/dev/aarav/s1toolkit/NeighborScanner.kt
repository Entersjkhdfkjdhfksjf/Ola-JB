package dev.aarav.s1toolkit

import android.content.Context
import android.net.ConnectivityManager
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Inet6Address
import java.net.NetworkInterface

/**
 * Finds the scooter's link-local IPv6 address without a laptop: pings the
 * all-nodes multicast address so every IPv6 host on the current Wi-Fi
 * answers, reads back the now-populated kernel neighbor table, and hands
 * back candidates for the caller to try connecting to.
 *
 * This shells out to the system `ping`/`ping6` and `ip` binaries rather
 * than opening a raw socket ourselves. Android's own ping binaries carry
 * the capability needed to send ICMP from an unprivileged app (no root
 * required -- this is the same reason `adb shell ping` works for a normal
 * user), so there's nothing to gain from reimplementing NDP by hand here.
 *
 * Not guaranteed on every device: some OEM skins restrict shelling out to
 * `ip`. If scanning comes back empty, the manual address field in the UI
 * still works exactly as before.
 */
object NeighborScanner {

    data class Candidate(val address: String, val iface: String)

    fun wifiInterfaceName(context: Context): String? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return null
        return cm.getLinkProperties(network)?.interfaceName
    }

    /** Pings ff02::1 on [iface] so every IPv6 neighbor answers and populates the kernel's cache. */
    private fun pingMulticast(iface: String) {
        val attempts = listOf(
            listOf("ping6", "-c", "1", "-W", "2", "ff02::1%$iface"),
            listOf("ping", "-6", "-c", "1", "-W", "2", "ff02::1%$iface"),
        )
        for (cmd in attempts) {
            try {
                val p = ProcessBuilder(cmd).redirectErrorStream(true).start()
                p.waitFor()
                return
            } catch (_: Exception) {
                // this binary/flag combo isn't present on this device -- try the next one
            }
        }
    }

    /** Reads the kernel's IPv6 neighbor table for [iface] via the `ip` tool. */
    private fun readNeighbors(iface: String): List<String> {
        val found = mutableListOf<String>()
        try {
            val p = ProcessBuilder("ip", "-6", "neigh", "show", "dev", iface)
                .redirectErrorStream(true).start()
            BufferedReader(InputStreamReader(p.inputStream)).useLines { lines ->
                lines.forEach { line ->
                    val addr = line.trim().substringBefore(' ')
                    if (addr.startsWith("fe80:")) found.add(addr)
                }
            }
            p.waitFor()
        } catch (_: Exception) {
            // `ip` isn't usable here -- caller falls back to manual entry
        }
        return found.distinct()
    }

    private fun ownLinkLocalAddresses(iface: String): Set<String> {
        return try {
            NetworkInterface.getByName(iface)?.inetAddresses?.asSequence()
                ?.filterIsInstance<Inet6Address>()
                ?.filter { it.isLinkLocalAddress }
                ?.map { it.hostAddress?.substringBefore('%') ?: "" }
                ?.toSet() ?: emptySet()
        } catch (_: Exception) {
            emptySet()
        }
    }

    /** Pings, reads the neighbor table, and excludes our own address. */
    fun findCandidates(context: Context): List<Candidate> {
        val iface = wifiInterfaceName(context) ?: return emptyList()
        pingMulticast(iface)
        Thread.sleep(600) // give replies a moment to land before reading the cache
        val own = ownLinkLocalAddresses(iface)
        return readNeighbors(iface)
            .filterNot { it in own }
            .map { Candidate(address = "$it%$iface", iface = iface) }
    }
}
