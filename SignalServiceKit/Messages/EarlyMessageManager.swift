//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public class EarlyMessageManager {
    private struct MessageIdentifier: Hashable {
        let timestamp: UInt64
        let author: Aci

        var key: String {
            return "\(author.serviceIdUppercaseString).\(timestamp)"
        }
    }

    private struct EarlyEnvelope: Codable {
        let envelope: SSKProtoEnvelope
        // This is optional for historical purposes, but no early envelopes should
        // be missing this value.
        let plainTextData: Data?
        let wasReceivedByUD: Bool
        let serverDeliveryTimestamp: UInt64
    }

    private enum EarlyReceipt: Codable, Hashable {
        private enum CodingKeys: String, CodingKey {
            case type, sender, deviceId, timestamp
        }
        private enum EncodedType: String, Codable {
            case outgoingMessageRead
            case outgoingMessageDelivered
            case outgoingMessageViewed
            case messageReadOnLinkedDevice
            case messageViewedOnLinkedDevice
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            let type = try container.decode(EncodedType.self, forKey: .type)
            let sender = try container.decodeIfPresent(SignalServiceAddress.self, forKey: .sender)
            let rawDeviceId = try container.decodeIfPresent(UInt32.self, forKey: .deviceId)
            let timestamp = try container.decode(UInt64.self, forKey: .timestamp)

            switch type {
            case .outgoingMessageRead:
                guard let sender = sender else {
                    throw OWSAssertionError("Missing sender")
                }
                let deviceId = rawDeviceId ?? {
                    // TODO: Remove this shim before ship. Just use existing OWSAssertionError
                    // DeviceId is only used to drop MSL entries, so a placeholder value of zero is fine.
                    owsFailDebug("Invalid deviceId")
                    return 0
                }()
                self = .outgoingMessageRead(sender: sender, deviceId: deviceId, timestamp: timestamp)
            case .outgoingMessageDelivered:
                guard let sender = sender else {
                    throw OWSAssertionError("Missing sender")
                }
                let deviceId = rawDeviceId ?? {
                    // TODO: Remove this shim before ship. Just use existing OWSAssertionError
                    // DeviceId is only used to drop MSL entries, so a placeholder value of zero is fine.
                    owsFailDebug("Invalid deviceId")
                    return 0
                }()
                self = .outgoingMessageDelivered(sender: sender, deviceId: deviceId, timestamp: timestamp)
            case .outgoingMessageViewed:
                guard let sender = sender else {
                    throw OWSAssertionError("Missing sender")
                }
                let deviceId = rawDeviceId ?? {
                    // TODO: Remove this shim before ship. Just use existing OWSAssertionError
                    // DeviceId is only used to drop MSL entries, so a placeholder value of zero is fine.
                    owsFailDebug("Invalid deviceId")
                    return 0
                }()
                self = .outgoingMessageViewed(sender: sender, deviceId: deviceId, timestamp: timestamp)
            case .messageReadOnLinkedDevice:
                self = .messageReadOnLinkedDevice(timestamp: timestamp)
            case .messageViewedOnLinkedDevice:
                self = .messageViewedOnLinkedDevice(timestamp: timestamp)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)

            switch self {
            case .outgoingMessageRead(let sender, let deviceId, let timestamp):
                try container.encode(encodedType, forKey: .type)
                try container.encode(sender, forKey: .sender)
                try container.encode(deviceId, forKey: .deviceId)
                try container.encode(timestamp, forKey: .timestamp)
            case .outgoingMessageDelivered(let sender, let deviceId, let timestamp):
                try container.encode(encodedType, forKey: .type)
                try container.encode(sender, forKey: .sender)
                try container.encode(deviceId, forKey: .deviceId)
                try container.encode(timestamp, forKey: .timestamp)
            case .outgoingMessageViewed(let sender, let deviceId, let timestamp):
                try container.encode(encodedType, forKey: .type)
                try container.encode(sender, forKey: .sender)
                try container.encode(deviceId, forKey: .deviceId)
                try container.encode(timestamp, forKey: .timestamp)
            case .messageReadOnLinkedDevice(let timestamp):
                try container.encode(encodedType, forKey: .type)
                try container.encode(timestamp, forKey: .timestamp)
            case .messageViewedOnLinkedDevice(let timestamp):
                try container.encode(encodedType, forKey: .type)
                try container.encode(timestamp, forKey: .timestamp)
            }
        }

        private var encodedType: EncodedType {
            switch self {
            case .outgoingMessageRead:
                return .outgoingMessageRead
            case .outgoingMessageDelivered:
                return .outgoingMessageDelivered
            case .outgoingMessageViewed:
                return .outgoingMessageViewed
            case .messageReadOnLinkedDevice:
                return .messageReadOnLinkedDevice
            case .messageViewedOnLinkedDevice:
                return .messageViewedOnLinkedDevice
            }
        }

        case outgoingMessageRead(sender: SignalServiceAddress, deviceId: UInt32, timestamp: UInt64)
        case outgoingMessageDelivered(sender: SignalServiceAddress, deviceId: UInt32, timestamp: UInt64)
        case outgoingMessageViewed(sender: SignalServiceAddress, deviceId: UInt32, timestamp: UInt64)
        case messageReadOnLinkedDevice(timestamp: UInt64)
        case messageViewedOnLinkedDevice(timestamp: UInt64)

        var timestamp: UInt64 {
            switch self {
            case .outgoingMessageRead(_, _, let timestamp):
                return timestamp
            case .outgoingMessageDelivered(_, _, let timestamp):
                return timestamp
            case .outgoingMessageViewed(_, _, let timestamp):
                return timestamp
            case .messageReadOnLinkedDevice(let timestamp):
                return timestamp
            case .messageViewedOnLinkedDevice(let timestamp):
                return timestamp
            }
        }

        // PNP0 TODO: This should be an Aci for read/viewed receipts.
        init(receiptType: SSKProtoReceiptMessageType, sender: ServiceId, senderDeviceId: DeviceId, timestamp: UInt64) {
            switch receiptType {
            case .delivery: self = .outgoingMessageDelivered(sender: SignalServiceAddress(sender), deviceId: senderDeviceId.uint32Value, timestamp: timestamp)
            case .read: self = .outgoingMessageRead(sender: SignalServiceAddress(sender), deviceId: senderDeviceId.uint32Value, timestamp: timestamp)
            case .viewed: self = .outgoingMessageViewed(sender: SignalServiceAddress(sender), deviceId: senderDeviceId.uint32Value, timestamp: timestamp)
            }
        }
    }

    private static let maxEarlyEnvelopeSize: Int = 1024
    private static let maxQueuedPerMessage: Int = 128

    private var pendingEnvelopeStore = KeyValueStore(collection: "EarlyEnvelopesStore")
    private var pendingReceiptStore =  KeyValueStore(collection: "EarlyReceiptsStore")
    private var metadataStore =  KeyValueStore(collection: "EarlyMessageManager.metadata")

    public init(appReadiness: AppReadiness) {
        SwiftSingletons.register(self)

        appReadiness.runNowOrWhenAppDidBecomeReadyAsync {
            self.cleanupStaleMessages()
        }
    }

    public func recordEarlyEnvelope(
        _ envelope: SSKProtoEnvelope,
        plainTextData: Data,
        wasReceivedByUD: Bool,
        serverDeliveryTimestamp: UInt64,
        associatedMessageTimestamp: UInt64,
        associatedMessageAuthor: Aci?,
        transaction: DBWriteTransaction
    ) {
        guard plainTextData.count <= Self.maxEarlyEnvelopeSize else {
            return owsFailDebug("unexpectedly tried to record an excessively large early envelope")
        }

        guard let associatedMessageAuthor else {
            return owsFailDebug("unexpectedly missing associatedMessageAuthor for early envelope \(OWSMessageDecrypter.description(for: envelope))")
        }

        let identifier = MessageIdentifier(
            timestamp: associatedMessageTimestamp,
            author: associatedMessageAuthor
        )

        Logger.info("Recording early envelope \(OWSMessageDecrypter.description(for: envelope)) for message \(identifier)")

        var envelopes: [EarlyEnvelope]
        do {
            envelopes = try pendingEnvelopeStore.getCodableValue(forKey: identifier.key, transaction: transaction) ?? []
        } catch {
            owsFailDebug("Failed to decode existing early envelopes for message \(identifier) with error \(error)")
            envelopes = []
        }

        while envelopes.count >= Self.maxQueuedPerMessage, let droppedEarlyEnvelope = envelopes.first {
            envelopes.remove(at: 0)
            owsFailDebug("Dropping early envelope \(OWSMessageDecrypter.description(for: droppedEarlyEnvelope.envelope)) for message \(identifier) due to excessive early envelopes.")
        }

        envelopes.append(EarlyEnvelope(
            envelope: envelope,
            plainTextData: plainTextData,
            wasReceivedByUD: wasReceivedByUD,
            serverDeliveryTimestamp: serverDeliveryTimestamp
        ))

        do {
            try pendingEnvelopeStore.setCodable(envelopes, key: identifier.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to persist early envelope \(OWSMessageDecrypter.description(for: envelope)) for message \(identifier) with error \(error)")
        }
    }

    public func recordEarlyReceiptForOutgoingMessage(
        type: SSKProtoReceiptMessageType,
        senderServiceId: ServiceId,
        senderDeviceId: DeviceId,
        timestamp: UInt64,
        associatedMessageTimestamp: UInt64,
        tx: DBWriteTransaction
    ) {
        guard let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci else {
            return owsFailDebug("missing local address")
        }

        let identifier = MessageIdentifier(timestamp: associatedMessageTimestamp, author: localAci)

        Logger.info("Recording early \(type) receipt for outgoing message \(identifier)")

        recordEarlyReceipt(
            .init(
                receiptType: type,
                sender: senderServiceId,
                senderDeviceId: senderDeviceId,
                timestamp: timestamp
            ),
            identifier: identifier,
            transaction: tx
        )
    }

    public func recordEarlyReadReceiptFromLinkedDevice(
        timestamp: UInt64,
        associatedMessageTimestamp: UInt64,
        associatedMessageAuthor: AciObjC?,
        transaction: DBWriteTransaction
    ) {
        guard let associatedMessageAuthor else {
            return owsFailDebug("unexpectedly missing associatedMessageAuthor for early read receipt with timestamp \(timestamp)")
        }

        let identifier = MessageIdentifier(
            timestamp: associatedMessageTimestamp,
            author: associatedMessageAuthor.wrappedAciValue
        )

        Logger.info("Recording early read receipt from linked device for message \(identifier)")

        recordEarlyReceipt(
            .messageReadOnLinkedDevice(timestamp: timestamp),
            identifier: identifier,
            transaction: transaction
        )
    }

    public func recordEarlyViewedReceiptFromLinkedDevice(
        timestamp: UInt64,
        associatedMessageTimestamp: UInt64,
        associatedMessageAuthor: AciObjC?,
        transaction: DBWriteTransaction
    ) {
        guard let associatedMessageAuthor else {
            return owsFailDebug("unexpectedly missing associatedMessageAuthor for early viewed receipt with timestamp \(timestamp)")
        }

        let identifier = MessageIdentifier(
            timestamp: associatedMessageTimestamp,
            author: associatedMessageAuthor.wrappedAciValue
        )

        Logger.info("Recording early viewed receipt from linked device for message \(identifier)")

        recordEarlyReceipt(
            .messageViewedOnLinkedDevice(timestamp: timestamp),
            identifier: identifier,
            transaction: transaction
        )
    }

    private func recordEarlyReceipt(
        _ earlyReceipt: EarlyReceipt,
        identifier: MessageIdentifier,
        transaction: DBWriteTransaction
    ) {
        var receipts: [EarlyReceipt]
        do {
            receipts = try pendingReceiptStore.getCodableValue(forKey: identifier.key, transaction: transaction) ?? []
        } catch {
            owsFailDebug("Failed to decode existing early receipts for message \(identifier) with error \(error)")
            receipts = []
        }

        guard !Set(receipts).contains(earlyReceipt) else {
            Logger.warn("Ignoring duplicate early receipt \(earlyReceipt) for message \(identifier)")
            return
        }

        while receipts.count >= Self.maxQueuedPerMessage, let droppedEarlyReceipt = receipts.first {
            receipts.remove(at: 0)
            owsFailDebug("Dropping early receipt \(droppedEarlyReceipt) for message \(identifier) due to excessive early receipts.")
        }

        receipts.append(earlyReceipt)

        do {
            try pendingReceiptStore.setCodable(receipts, key: identifier.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to persist early receipt for message \(identifier) with error \(error)")
        }
    }

    public func applyPendingMessages(for message: TSMessage, localIdentifiers: LocalIdentifiers, transaction: DBWriteTransaction) {
        let identifier: MessageIdentifier
        if let message = message as? TSOutgoingMessage {
            identifier = MessageIdentifier(timestamp: message.timestamp, author: localIdentifiers.aci)
        } else if let message = message as? TSIncomingMessage {
            guard let authorAci = Aci.parseFrom(aciString: message.authorUUID) else {
                return owsFailDebug("Attempted to apply pending messages for message missing sender aci with type \(message.interactionType) from \(message.authorAddress)")
            }
            identifier = MessageIdentifier(timestamp: message.timestamp, author: authorAci)
        } else {
            // We only support early envelopes for incoming + outgoing message types, for now.
            return owsFailDebug("attempted to apply pending messages for unsupported message type \(message.interactionType)")
        }

        applyPendingMessages(for: identifier, localIdentifiers: localIdentifiers, tx: transaction) { earlyReceipt in
            switch earlyReceipt {
            case .outgoingMessageRead(let sender, let deviceId, let timestamp):
                Logger.info("Applying early read receipt from \(sender):\(deviceId) for outgoing message \(identifier)")

                guard let message = message as? TSOutgoingMessage else {
                    owsFailDebug("Unexpected message type for early read receipt for outgoing message.")
                    break
                }
                guard let deviceId = DeviceId(validating: deviceId) else {
                    owsFailDebug("Unexpected deviceId for early read receipt for outgoing message.")
                    break
                }
                message.update(
                    withReadRecipient: sender,
                    deviceId: deviceId,
                    readTimestamp: timestamp,
                    tx: transaction
                )
            case .outgoingMessageViewed(let sender, let deviceId, let timestamp):
                Logger.info("Applying early viewed receipt from \(sender):\(deviceId) for outgoing message \(identifier)")

                guard let message = message as? TSOutgoingMessage else {
                    owsFailDebug("Unexpected message type for early read receipt for outgoing message.")
                    break
                }
                guard let deviceId = DeviceId(validating: deviceId) else {
                    owsFailDebug("Unexpected deviceId for early viewed receipt for outgoing message.")
                    break
                }
                message.update(
                    withViewedRecipient: sender,
                    deviceId: deviceId,
                    viewedTimestamp: timestamp,
                    tx: transaction
                )
            case .outgoingMessageDelivered(let sender, let deviceId, let timestamp):
                Logger.info("Applying early delivery receipt from \(sender):\(deviceId) for outgoing message \(identifier)")

                guard let message = message as? TSOutgoingMessage else {
                    owsFailDebug("Unexpected message type for early delivery receipt for outgoing message.")
                    break
                }
                guard let deviceId = DeviceId(validating: deviceId) else {
                    owsFailDebug("Unexpected deviceId for early delivery receipt for outgoing message.")
                    break
                }
                message.update(
                    withDeliveredRecipient: sender,
                    deviceId: deviceId,
                    deliveryTimestamp: timestamp,
                    context: PassthroughDeliveryReceiptContext(),
                    tx: transaction
                )
            case .messageReadOnLinkedDevice(let timestamp):
                Logger.info("Applying early read receipt from linked device for message \(identifier)")

                SSKEnvironment.shared.receiptManagerRef.markMessageAsReadOnLinkedDevice(
                    message,
                    readTimestamp: timestamp,
                    tx: transaction
                )
            case .messageViewedOnLinkedDevice(let timestamp):
                Logger.info("Applying early viewed receipt from linked device for message \(identifier)")

                SSKEnvironment.shared.receiptManagerRef.markMessageAsViewedOnLinkedDevice(
                    message,
                    viewedTimestamp: timestamp,
                    tx: transaction
                )
            }
        }
    }

    public func applyPendingMessages(for storyMessage: StoryMessage, transaction: DBWriteTransaction) {
        guard !storyMessage.authorAddress.isSystemStoryAddress else {
            // Don't process read receipts for system stories.
            Logger.info("Not processing viewed receipt for system story")
            return
        }
        guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction) else {
            owsFailDebug("Can't process messages when not registered.")
            return
        }
        let identifier = MessageIdentifier(timestamp: storyMessage.timestamp, author: storyMessage.authorAci)
        applyPendingMessages(for: identifier, localIdentifiers: localIdentifiers, tx: transaction) { earlyReceipt in
            switch earlyReceipt {
            case .outgoingMessageRead(let sender, let deviceId, _):
                owsFailDebug("Unexpectedly received early read receipt from \(sender):\(deviceId) for StoryMessage \(identifier)")
            case .outgoingMessageViewed(let sender, let deviceId, let timestamp):
                Logger.info("Applying early viewed receipt from \(sender):\(deviceId) for StoryMessage \(identifier)")

                guard storyMessage.direction == .outgoing else {
                    owsFailDebug("Unexpected message type for early viewed receipt for StoryMessage.")
                    break
                }
                guard let senderAci = sender.aci else {
                    // You can't send viewed receipts from your Pni.
                    break
                }

                storyMessage.markAsViewed(at: timestamp, by: senderAci, transaction: transaction)
            case .outgoingMessageDelivered(let sender, let deviceId, _):
                Logger.info("Applying early delivery receipt from \(sender):\(deviceId) for StoryMessage \(identifier)")

                guard storyMessage.direction == .outgoing else {
                    owsFailDebug("Unexpected message type for early delivery receipt for outgoing message.")
                    break
                }

                // TODO: Mark Delivered
            case .messageReadOnLinkedDevice(let timestamp):
                Logger.info("Applying early read receipt from linked device for StoryMessage \(identifier)")

                storyMessage.markAsRead(at: timestamp, circumstance: .onLinkedDevice, transaction: transaction)
            case .messageViewedOnLinkedDevice(let timestamp):
                Logger.info("Applying early viewed receipt from linked device for StoryMessage \(identifier)")

                storyMessage.markAsViewed(at: timestamp, circumstance: .onLinkedDevice, transaction: transaction)
            }
        }
    }

    private func applyPendingMessages(
        for identifier: MessageIdentifier,
        localIdentifiers: LocalIdentifiers,
        tx transaction: DBWriteTransaction,
        earlyReceiptProcessor: (EarlyReceipt) -> Void
    ) {
        let earlyReceipts: [EarlyReceipt]?
        do {
            earlyReceipts = try pendingReceiptStore.getCodableValue(forKey: identifier.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to decode early receipts for message \(identifier) with error \(error)")
            earlyReceipts = nil
        }

        pendingReceiptStore.removeValue(forKey: identifier.key, transaction: transaction)

        // Apply any early receipts for this message
        earlyReceipts?.forEach { earlyReceiptProcessor($0) }

        let earlyEnvelopes: [EarlyEnvelope]?
        do {
            earlyEnvelopes = try pendingEnvelopeStore.getCodableValue(forKey: identifier.key, transaction: transaction)
        } catch {
            owsFailDebug("Failed to decode early envelopes for \(identifier) with error \(error)")
            earlyEnvelopes = nil
        }

        pendingEnvelopeStore.removeValue(forKey: identifier.key, transaction: transaction)

        // Re-process any early envelopes associated with this message
        for earlyEnvelope in earlyEnvelopes ?? [] {
            Logger.info("Reprocessing early envelope \(OWSMessageDecrypter.description(for: earlyEnvelope.envelope)) for \(identifier)")

            guard let plaintextData = earlyEnvelope.plainTextData else {
                Logger.warn("Dropping early envelope without plaintextData.")
                continue
            }

            SSKEnvironment.shared.messageReceiverRef.processEnvelope(
                earlyEnvelope.envelope,
                plaintextData: plaintextData,
                wasReceivedByUD: earlyEnvelope.wasReceivedByUD,
                serverDeliveryTimestamp: earlyEnvelope.serverDeliveryTimestamp,
                shouldDiscardVisibleMessages: false,
                localIdentifiers: localIdentifiers,
                tx: transaction
            )
        }
    }

    private func cleanupStaleMessages() {
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
            let oldestTimestampToKeep = Date.ows_millisecondTimestamp() - UInt64.weekInMs

            let allEnvelopeKeys = self.pendingEnvelopeStore.allKeys(transaction: transaction)
            let staleEnvelopeKeys = allEnvelopeKeys.filter {
                guard let timestampString = $0.split(separator: ".")[safe: 1],
                      let timestamp = UInt64(timestampString),
                      timestamp < oldestTimestampToKeep else {
                    return false
                }
                return true
            }
            self.pendingEnvelopeStore.removeValues(forKeys: staleEnvelopeKeys, transaction: transaction)

            let allReceiptKeys = self.pendingReceiptStore.allKeys(transaction: transaction)
            let staleReceiptKeys = allReceiptKeys.filter {
                guard let timestampString = $0.split(separator: ".")[safe: 1],
                      let timestamp = UInt64(timestampString),
                      timestamp < oldestTimestampToKeep else {
                    return false
                }
                return true
            }
            self.pendingReceiptStore.removeValues(forKeys: staleReceiptKeys, transaction: transaction)

            let remainingReceiptKeys = Set(allReceiptKeys).subtracting(staleReceiptKeys)
            self.trimEarlyReceiptsIfNecessary(remainingReceiptKeys: remainingReceiptKeys,
                                                     transaction: transaction)
        }
    }

    private func trimEarlyReceiptsIfNecessary(
        remainingReceiptKeys: Set<String>,
        transaction: DBWriteTransaction
    ) {
        guard CurrentAppContext().isMainApp,
              !CurrentAppContext().isRunningTests else {
                  return
              }

        let trimmedReceiptsKey = "trimmedReceiptsKey"
        let hasTrimmedReceipts = self.metadataStore.getBool(
            trimmedReceiptsKey,
            defaultValue: false,
            transaction: transaction)
        guard !hasTrimmedReceipts else { return }
        self.metadataStore.setBool(true, key: trimmedReceiptsKey, transaction: transaction)

        var removedTotal: Int = 0
        for receiptKey in remainingReceiptKeys {
            autoreleasepool {
                do {
                    let receipts: [EarlyReceipt] = try self.pendingReceiptStore.getCodableValue(forKey: receiptKey,
                                                                                                transaction: transaction) ?? []
                    var deduplicatedReceipts = OrderedSet(receipts).orderedMembers
                    if deduplicatedReceipts.count != receipts.count {
                        Logger.info("De-duplicated early receipts for message \(receiptKey): \(receipts.count) - \(receipts.count - deduplicatedReceipts.count) -> \(deduplicatedReceipts.count)")
                    }

                    if deduplicatedReceipts.count > Self.maxQueuedPerMessage {
                        let countBeforeTrimming = deduplicatedReceipts.count
                        deduplicatedReceipts = Array(deduplicatedReceipts.suffix(Self.maxQueuedPerMessage))
                        Logger.info("Trimmed early receipts for message \(receiptKey): \(countBeforeTrimming) - \(countBeforeTrimming - deduplicatedReceipts.count) -> \(deduplicatedReceipts.count)")
                    }

                    guard !receipts.isEmpty,
                          receipts.count != deduplicatedReceipts.count else {
                        return
                    }
                    try pendingReceiptStore.setCodable(deduplicatedReceipts,
                                                       key: receiptKey,
                                                       transaction: transaction)
                    owsAssertDebug(receipts.count > deduplicatedReceipts.count)
                    removedTotal += receipts.count - deduplicatedReceipts.count
                } catch {
                    owsFailDebug("Failed to decode early receipts: \(error)")
                    self.pendingReceiptStore.removeValue(forKey: receiptKey, transaction: transaction)
                }
            }
        }
        if removedTotal > 0 {
            Logger.info("Removed early receipts (total): \(removedTotal)")
        }
    }
}

// MARK: -

extension SSKProtoReceiptMessageType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .delivery:
            return "delivery"
        case .read:
            return "read"
        case .viewed:
            return "viewed"
        @unknown default:
            owsFailDebug("unexpected SSKProtoReceiptMessageType: \(self.rawValue)")
            return "Unknown"
        }
    }
}
