# Native notification queue checks

Run from the plugin root on macOS with Xcode command-line tools:

```sh
xcrun swiftc darwin/ble_mesh_chat/Sources/ble_mesh_chat/PendingFrameQueue.swift darwin/tests/PendingFrameQueueTests.swift -o /tmp/ble-mesh-native-queue-tests
/tmp/ble-mesh-native-queue-tests
```

Checks backpressure, FIFO ordering with callback re-entry, subscriber-specific
cancellation, and exactly-once completion on shutdown. This exercises the queue
used by the CoreBluetooth peripheral controller without requiring a BLE radio.
It does not simulate CoreBluetooth discovery or background scheduling; those
need physical iOS devices.
