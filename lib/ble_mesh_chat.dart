/// Dual-role (central + peripheral) BLE byte transport for building offline
/// mesh networks — chat, telemetry, anything that has to work with no
/// internet, no cell network, and no infrastructure.
///
/// The native layer is deliberately a dumb byte pipe: it knows about adapter
/// state, links, frames, and how big a frame may be, and nothing else. Peer
/// identity, routing, fragmentation, and encryption live in Dart so they exist
/// once instead of once per platform.
library;

export 'src/chat/ble_chat_transport.dart' show BleChatTransport;
export 'src/chat/ble_mesh_chat.dart' show BleMeshChat;
export 'src/chat/bridge_policy.dart'
    show BridgeInactiveReason, BridgePolicy, BridgeStatus, NetworkConditions;
export 'src/chat/chat_models.dart'
    show
        ChatIdentity,
        ChatMessage,
        ChatPacket,
        ChatPacketType,
        ChatPeer,
        MessageState,
        MessageStateChange,
        createPacketId,
        packetIdToHex;
export 'src/chat/crypto/group_crypto.dart'
    show ChatGroup, GroupCipher, GroupStore, InMemoryGroupStore;
export 'src/chat/crypto/chat_keys.dart' show ChatKeyPair, ChatPublicKeys;
export 'src/chat/crypto/packet_security.dart'
    show PacketSecurity, VerifiedPacket;
export 'src/chat/crypto/identity_store_base.dart'
    show IdentityStore, loadOrCreateIdentity;
export 'src/chat/crypto/trust_store.dart' show PeerTrust, TrustStore;
export 'src/chat/crypto/message_cipher.dart'
    show
        MessageCipher,
        MessageSecurityException,
        PeerKeyChangedException,
        SealedMessageCipher,
        SealedPayload;
export 'src/chat/chat_transport.dart'
    show
        ChatTransport,
        ChatTransportSendResult,
        ReceivedChatPacket,
        RelayChatTransport;
export 'src/chat/fragmentation.dart'
    show FragmentFormatException, PacketFragmenter, PacketReassembler;
export 'src/chat/inbound_policy.dart'
    show InboundRateLimit, InboundRateLimitedException, UnknownSenderException;
export 'src/chat/message_store.dart'
    show
        DedupeCache,
        InMemoryMessageStore,
        MessageStore,
        MessageStoreFullException,
        MessageStoreVersionException,
        SeenPacketQuotaException;
export 'src/chat/nostr/nostr_event.dart'
    show NostrEvent, NostrEventFormatException, NostrKeyPair;
export 'src/chat/nostr/nostr_socket.dart'
    show NostrSocket, NostrSocketConnector, connectWebSocket;
export 'src/chat/nostr_chat_transport.dart'
    show NostrChatTransport, NostrRelayException;
export 'src/chat/untrusted_text.dart' show UntrustedText;
export 'src/chat/packet_codec.dart'
    show ChatPacketCodec, ChatPacketFormatException;
export 'src/ble_api.g.dart'
    show
        BleAdapterState,
        BleCapabilities,
        BleConfig,
        BleErrorCode,
        BleLink,
        BleLinkRole,
        BlePermissionState;
export 'src/ble_mesh_transport.dart' show BleMeshTransport, BleMeshUuids;
export 'src/models.dart'
    show
        BleBroadcastReport,
        BleFrame,
        BleFrameTooLargeException,
        BleLinkDown,
        BleTransportError,
        BleUnknownLinkException,
        BleUnsupportedPlatformException;
export 'src/platform_api.dart' show BlePlatformApi, PigeonBlePlatformApi;
