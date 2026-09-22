package dev.blemesh.ble_mesh

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic

/**
 * One physical connection.
 *
 * Deliberately *not* a peer: the same device can hold two links at once (we
 * connected out, they connected in). Collapsing links into peer identities is
 * protocol-layer work in Dart, because only Dart has seen the ANNOUNCE.
 */
class MeshLink(
    val linkId: String,
    val role: BleLinkRole,
    val device: BluetoothDevice,
    val connectedAtMs: Long
) {
    /** Conservative default until MTU negotiation lands: ATT default 23 - 3. */
    var maxFrameSize: Long = DEFAULT_MAX_FRAME_SIZE
    var rssi: Long? = null

    /** Central role only. */
    var gatt: BluetoothGatt? = null
    var characteristic: BluetoothGattCharacteristic? = null

    val address: String get() = device.address

    fun toPigeon(): BleLink =
        BleLink(
            linkId = linkId,
            role = role,
            remoteId = address,
            maxFrameSize = maxFrameSize,
            connectedAtMs = connectedAtMs,
            rssi = rssi
        )

    companion object {
        const val DEFAULT_MAX_FRAME_SIZE = 20L

        fun idFor(
            role: BleLinkRole,
            address: String
        ): String =
            when (role) {
                BleLinkRole.CENTRAL -> "c:$address"
                BleLinkRole.PERIPHERAL -> "p:$address"
            }
    }
}

/** Main-thread-only map of live links. */
class LinkRegistry {
    private val links = LinkedHashMap<String, MeshLink>()

    val size: Int get() = links.size

    fun all(): List<MeshLink> = links.values.toList()

    operator fun get(linkId: String): MeshLink? = links[linkId]

    fun find(
        role: BleLinkRole,
        address: String
    ): MeshLink? = links[MeshLink.idFor(role, address)]

    fun put(link: MeshLink) {
        links[link.linkId] = link
    }

    fun remove(linkId: String): MeshLink? = links.remove(linkId)

    fun clear(): List<MeshLink> {
        val snapshot = all()
        links.clear()
        return snapshot
    }
}
