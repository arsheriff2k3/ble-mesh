/// Durable [MessageStore] backed by the local filesystem.
///
/// Kept out of `package:ble_mesh/ble_mesh.dart` on purpose: it imports
/// `dart:io`, and the core library has to stay compilable on web so an online
/// transport can run where BLE cannot.
library;

export 'src/chat/file_message_store.dart' show FileMessageStore;
export 'src/chat/message_store.dart'
    show MessageStoreFullException, MessageStoreVersionException;
