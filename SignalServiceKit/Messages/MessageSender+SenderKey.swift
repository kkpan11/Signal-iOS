//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient

extension MessageSender {
    private static var maxSenderKeyEnvelopeSize: UInt64 { 256 * 1024 }

    struct Recipient {
        let serviceId: ServiceId
        let devices: [UInt32]
        var protocolAddresses: [ProtocolAddress] {
            return devices.map { ProtocolAddress(serviceId, deviceId: $0) }
        }

        init(serviceId: ServiceId, transaction tx: SDSAnyReadTransaction) {
            self.serviceId = serviceId
            self.devices = {
                let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable
                return recipientDatabaseTable.fetchRecipient(serviceId: serviceId, transaction: tx.asV2Read)?.deviceIds ?? []
            }()
        }
    }

    private enum SenderKeyError: Error, IsRetryableProvider, UserErrorDescriptionProvider {
        case invalidAuthHeader
        case invalidRecipient
        case deviceUpdate
        case staleDevices
        case oversizeMessage
        case recipientSKDMFailed(Error)

        var isRetryableProvider: Bool { true }

        var asSSKError: NSError {
            let result: Error
            switch self {
            case let .recipientSKDMFailed(underlyingError):
                result = underlyingError
            case .invalidAuthHeader, .invalidRecipient, .oversizeMessage:
                // For all of these error types, there's a chance that a fanout send may be successful. This
                // error is retryable, but indicates that the next send attempt should restrict itself to fanout
                // send only.
                result = SenderKeyUnavailableError(customLocalizedDescription: localizedDescription)
            case .deviceUpdate, .staleDevices:
                result = SenderKeyEphemeralError(customLocalizedDescription: localizedDescription)
            }
            return (result as NSError)
        }

        var localizedDescription: String {
            // Since this is a retryable error, so it's unlikely to be surfaced to the user. I think the only situation
            // where it would is it happens to be the last error hit before we run out of resend attempts. In that case,
            // we should just show a generic error just to be safe.
            // TODO: This probably isn't the only error like this. Should we have a fallback generic string
            // for all retryable errors without a description that exhaust retry attempts?
            switch self {
            case .recipientSKDMFailed(let error):
                return error.localizedDescription
            default:
                return OWSLocalizedString("ERROR_DESCRIPTION_CLIENT_SENDING_FAILURE",
                                         comment: "Generic notice when message failed to send.")
            }
        }
    }

    class SenderKeyStatus {
        enum ParticipantState {
            case SenderKeyReady
            case NeedsSKDM
            case FanoutOnly
        }
        var participants: [ServiceId: ParticipantState]
        init(numberOfParticipants: Int) {
            self.participants = Dictionary(minimumCapacity: numberOfParticipants)
        }

        convenience init(fanoutOnlyParticipants: [ServiceId]) {
            self.init(numberOfParticipants: fanoutOnlyParticipants.count)
            fanoutOnlyParticipants.forEach { self.participants[$0] = .FanoutOnly }
        }

        var fanoutParticipants: [ServiceId] {
            Array(participants.lazy.filter { $0.value == .FanoutOnly }.map { $0.key })
        }

        var allSenderKeyParticipants: [ServiceId] {
            Array(participants.lazy.filter { $0.value != .FanoutOnly }.map { $0.key })
        }

        var participantsNeedingSKDM: [ServiceId] {
            Array(participants.lazy.filter { $0.value == .NeedsSKDM }.map { $0.key })
        }

        var readyParticipants: [ServiceId] {
            Array(participants.lazy.filter { $0.value == .SenderKeyReady }.map { $0.key })
        }
    }

    /// Filters the list of participants for a thread that support SenderKey
    func senderKeyStatus(
        for thread: TSThread,
        intendedRecipients: [ServiceId],
        udAccessMap: [ServiceId: OWSUDSendingAccess]
    ) -> SenderKeyStatus {
        guard thread.usesSenderKey else {
            return .init(fanoutOnlyParticipants: intendedRecipients)
        }

        return databaseStorage.read { readTx in
            let isCurrentKeyValid = senderKeyStore.isKeyValid(for: thread, readTx: readTx)
            let recipientsWithoutSenderKey = senderKeyStore.recipientsInNeedOfSenderKey(
                for: thread,
                serviceIds: intendedRecipients,
                readTx: readTx
            )

            let senderKeyStatus = SenderKeyStatus(numberOfParticipants: intendedRecipients.count)
            let threadRecipients = thread.recipientAddresses(with: readTx).compactMap { $0.serviceId }
            intendedRecipients.forEach { candidate in
                // Sender key requires that you're a full member of the group and you support UD
                guard
                    threadRecipients.contains(candidate),
                    [.enabled, .unrestricted].contains(udAccessMap[candidate]?.udAccess.udAccessMode)
                else {
                    senderKeyStatus.participants[candidate] = .FanoutOnly
                    return
                }

                guard !SignalServiceAddress(candidate).isLocalAddress else {
                    senderKeyStatus.participants[candidate] = .FanoutOnly
                    owsFailBeta("Callers must not provide UD access for the local ACI.")
                    return
                }

                // If all registrationIds aren't valid, we should fallback to fanout
                // This should be removed once we've sorted out why there are invalid
                // registrationIds
                let registrationIdStatus = Self.registrationIdStatus(for: candidate, transaction: readTx)
                switch registrationIdStatus {
                case .valid:
                    // All good, keep going.
                    break
                case .invalid:
                    // Don't bother with SKDM, fall back to fanout.
                    senderKeyStatus.participants[candidate] = .FanoutOnly
                    return
                case .noSession:
                    // This recipient has no session; thats ok, just fall back to SKDM.
                    senderKeyStatus.participants[candidate] = .NeedsSKDM
                    return
                }

                // The recipient is good to go for sender key! Though, they need an SKDM
                // if they don't have a current valid sender key.
                if recipientsWithoutSenderKey.contains(candidate) || !isCurrentKeyValid {
                    senderKeyStatus.participants[candidate] = .NeedsSKDM
                } else {
                    senderKeyStatus.participants[candidate] = .SenderKeyReady
                }
            }
            return senderKeyStatus
        }
    }

    func sendSenderKeyMessage(
        message: TSOutgoingMessage,
        plaintextContent: Data,
        payloadId: Int64?,
        thread: TSThread,
        status: SenderKeyStatus,
        udAccessMap: [ServiceId: OWSUDSendingAccess],
        senderCertificate: SenderCertificate,
        localIdentifiers: LocalIdentifiers,
        sendErrorBlock: @escaping (ServiceId, NSError) -> Void
    ) async throws {

        // Because of the way message send errors are combined by the caller, we
        // need to ensure that if *any* send fails, the entire method fails. The
        // error this method throws doesn't really matter and isn't consulted.
        let didHitAnyFailure = AtomicBool(false, lock: .sharedGlobal)
        let wrappedSendErrorBlock = { (serviceId: ServiceId, error: Error) -> Void in
            Logger.info("Sender key send failed for \(serviceId): \(error)")
            _ = didHitAnyFailure.tryToSetFlag()

            if let senderKeyError = error as? SenderKeyError {
                sendErrorBlock(serviceId, senderKeyError.asSSKError)
            } else {
                sendErrorBlock(serviceId, (error as NSError))
            }
        }

        let senderKeyRecipients: [ServiceId]
        // If none of our recipients need an SKDM let's just skip the database write.
        if status.participantsNeedingSKDM.count > 0 {
            senderKeyRecipients = await sendSenderKeyDistributionMessages(
                recipients: status.allSenderKeyParticipants,
                thread: thread,
                originalMessage: message,
                udAccessMap: udAccessMap,
                localIdentifiers: localIdentifiers,
                sendErrorBlock: wrappedSendErrorBlock
            )
        } else {
            senderKeyRecipients = status.readyParticipants
        }

        if senderKeyRecipients.isEmpty {
            // Something went wrong with the SKDMs. Exit early.
            owsAssertDebug(didHitAnyFailure.get())
        } else {
            do {
                Logger.info("Sending sender key message with timestamp \(message.timestamp) to \(senderKeyRecipients)")

                let sendResult = try await self.sendSenderKeyRequest(
                    message: message,
                    plaintext: plaintextContent,
                    thread: thread,
                    serviceIds: senderKeyRecipients,
                    udAccessMap: udAccessMap,
                    senderCertificate: senderCertificate
                )

                Logger.info("Sender key message with timestamp \(message.timestamp) sent! Recipients: \(sendResult.successServiceIds). Unregistered: \(sendResult.unregisteredServiceIds)")

                return await self.databaseStorage.awaitableWrite { tx in
                    sendResult.unregisteredServiceIds.forEach { serviceId in
                        self.markAsUnregistered(serviceId: serviceId, message: message, thread: thread, transaction: tx)

                        let error = MessageSenderNoSuchSignalRecipientError()
                        wrappedSendErrorBlock(serviceId, error)
                    }

                    sendResult.success.forEach { recipient in
                        message.update(
                            withSentRecipient: ServiceIdObjC.wrapValue(recipient.serviceId),
                            wasSentByUD: true,
                            transaction: tx
                        )

                        // If we're sending a story, we generally get a 200, even if the account
                        // doesn't exist. Therefore, don't use this to mark accounts as registered.
                        if !message.isStorySend {
                            let recipientFetcher = DependenciesBridge.shared.recipientFetcher
                            let recipient = recipientFetcher.fetchOrCreate(serviceId: recipient.serviceId, tx: tx.asV2Write)
                            let recipientManager = DependenciesBridge.shared.recipientManager
                            recipientManager.markAsRegisteredAndSave(recipient, shouldUpdateStorageService: true, tx: tx.asV2Write)
                        }

                        self.profileManager.didSendOrReceiveMessage(
                            serviceId: recipient.serviceId,
                            localIdentifiers: localIdentifiers,
                            tx: tx.asV2Write
                        )

                        guard let payloadId = payloadId, let recipientAci = recipient.serviceId as? Aci else { return }
                        recipient.devices.forEach { deviceId in
                            let messageSendLog = SSKEnvironment.shared.messageSendLogRef
                            messageSendLog.recordPendingDelivery(
                                payloadId: payloadId,
                                recipientAci: recipientAci,
                                recipientDeviceId: deviceId,
                                message: message,
                                tx: tx
                            )
                        }
                    }
                }
            } catch {
                // If the sender key message failed to send, fail each recipient that we hoped to send it to.
                Logger.error("Sender key send failed: \(error)")
                senderKeyRecipients.forEach { wrappedSendErrorBlock($0, error) }
            }
        }
        if didHitAnyFailure.get() {
            // MessageSender just uses this error as a sentinel to consult the per-recipient errors. The
            // actual error doesn't matter.
            throw OWSGenericError("Failed to send to at least one SenderKey participant")
        }
    }

    // Given a list of recipients, ensures that all recipients have been sent an
    // SKDM. If an intended recipient does not have an SKDM, it sends one. If we
    // fail to send an SKDM, invokes the per-recipient error block.
    //
    // Returns the list of all recipients ready for the SenderKeyMessage.
    private func sendSenderKeyDistributionMessages(
        recipients: [ServiceId],
        thread: TSThread,
        originalMessage: TSOutgoingMessage,
        udAccessMap: [ServiceId: OWSUDSendingAccess],
        localIdentifiers: LocalIdentifiers,
        sendErrorBlock: @escaping (ServiceId, Error) -> Void
    ) async -> [ServiceId] {
        do {
            var recipientsNotNeedingSKDM: Set<ServiceId> = Set()
            let skdmSends = try await databaseStorage.awaitableWrite { writeTx -> [(OWSMessageSend, SealedSenderParameters?)] in
                // Here we fetch all of the recipients that need an SKDM
                // We then construct an OWSMessageSend for each recipient that needs an SKDM.

                // Even though we earlier checked key expiration/who needs an SKDM, we must
                // check again since it may no longer be valid. e.g. The key expired since
                // we last checked. Now *all* recipients need the current SKDM, not just
                // the ones that needed it when we last checked.
                self.senderKeyStore.expireSendingKeyIfNecessary(for: thread, writeTx: writeTx)

                let recipientsNeedingSKDM = self.senderKeyStore.recipientsInNeedOfSenderKey(
                    for: thread,
                    serviceIds: recipients,
                    readTx: writeTx
                )
                recipientsNotNeedingSKDM = Set(recipients).subtracting(recipientsNeedingSKDM)

                guard !recipientsNeedingSKDM.isEmpty else { return [] }
                guard let skdmBytes = self.senderKeyStore.skdmBytesForThread(
                    thread,
                    localAci: localIdentifiers.aci,
                    localDeviceId: DependenciesBridge.shared.tsAccountManager.storedDeviceId(tx: writeTx.asV2Read),
                    tx: writeTx
                ) else {
                    throw OWSAssertionError("Couldn't build SKDM")
                }

                return recipientsNeedingSKDM.compactMap { (serviceId) -> (OWSMessageSend, SealedSenderParameters?)? in
                    Logger.info("Sending SKDM to \(serviceId) for thread \(thread.uniqueId)")

                    let contactThread = TSContactThread.getOrCreateThread(
                        withContactAddress: SignalServiceAddress(serviceId),
                        transaction: writeTx
                    )
                    let skdmMessage = OWSOutgoingSenderKeyDistributionMessage(
                        thread: contactThread,
                        senderKeyDistributionMessageBytes: skdmBytes,
                        transaction: writeTx
                    )
                    skdmMessage.configureAsSentOnBehalfOf(originalMessage, in: thread)

                    guard let serializedMessage = self.buildAndRecordMessage(skdmMessage, in: contactThread, tx: writeTx) else {
                        sendErrorBlock(serviceId, SenderKeyError.recipientSKDMFailed(OWSAssertionError("Couldn't build message.")))
                        return nil
                    }

                    let messageSend = OWSMessageSend(
                        message: skdmMessage,
                        plaintextContent: serializedMessage.plaintextData,
                        plaintextPayloadId: serializedMessage.payloadId,
                        thread: contactThread,
                        serviceId: serviceId,
                        localIdentifiers: localIdentifiers
                    )

                    let sealedSenderParameters = udAccessMap[serviceId].map {
                        SealedSenderParameters(message: skdmMessage, udSendingAccess: $0)
                    }

                    return (messageSend, sealedSenderParameters)
                }
            }

            struct DistributedSenderKey {
                var serviceId: ServiceId
                var timestamp: UInt64
            }

            let distributedSenderKeys = await withThrowingTaskGroup(
                of: DistributedSenderKey.self,
                returning: [DistributedSenderKey].self
            ) { taskGroup in
                // For each recipient who needs an SKDM, we call performMessageSend:
                // - If it succeeds, great! Propagate along the successful OWSMessageSend.
                // - Otherwise, invoke the sendErrorBlock and rethrow.
                for (messageSend, sealedSenderParameters) in skdmSends {
                    taskGroup.addTask {
                        do {
                            try await self.performMessageSend(messageSend, sealedSenderParameters: sealedSenderParameters)
                            return DistributedSenderKey(serviceId: messageSend.serviceId, timestamp: messageSend.message.timestamp)
                        } catch {
                            if error is MessageSenderNoSuchSignalRecipientError {
                                await self.databaseStorage.awaitableWrite { transaction in
                                    self.markAsUnregistered(
                                        serviceId: messageSend.serviceId,
                                        message: originalMessage,
                                        thread: thread,
                                        transaction: transaction
                                    )
                                }
                            }
                            // Note that we still rethrow. It's just easier to access the address
                            // while we still have the messageSend in scope.
                            let wrappedError = SenderKeyError.recipientSKDMFailed(error)
                            sendErrorBlock(messageSend.serviceId, wrappedError)
                            throw wrappedError
                        }
                    }
                }
                var results = [DistributedSenderKey]()
                while let result = await taskGroup.nextResult() {
                    switch result {
                    case .success(let result):
                        results.append(result)
                    case .failure:
                        continue
                    }
                }
                return results
            }

            // This is a hot path, so we do a bit of a dance here to prepare all of the successful send
            // info before opening the write transaction. We need the recipient address and the SKDM
            // timestamp.

            if distributedSenderKeys.count > 0 {
                try await self.databaseStorage.awaitableWrite { writeTx in
                    try distributedSenderKeys.forEach {
                        try self.senderKeyStore.recordSenderKeySent(
                            for: thread,
                            to: ServiceIdObjC.wrapValue($0.serviceId),
                            timestamp: $0.timestamp,
                            writeTx: writeTx
                        )
                    }
                }
            }

            // We want to return all recipients that are now ready for sender key
            return Array(recipientsNotNeedingSKDM) + distributedSenderKeys.map { $0.serviceId }
        } catch {
            // If we hit *any* error that we haven't handled, we should fail the send
            // for everyone.
            let wrappedError = SenderKeyError.recipientSKDMFailed(error)
            recipients.forEach { sendErrorBlock($0, wrappedError) }
            return []
        }
    }

    fileprivate struct SenderKeySendResult {
        let success: [Recipient]
        let unregistered: [Recipient]

        var successServiceIds: [ServiceId] { success.map { $0.serviceId } }
        var unregisteredServiceIds: [ServiceId] { unregistered.map { $0.serviceId } }
    }

    /// Encrypts and sends the message using SenderKey.
    ///
    /// If the successful, the message was sent to all values in `serviceIds`
    /// *except* those returned as unregistered in the result.
    fileprivate func sendSenderKeyRequest(
        message: TSOutgoingMessage,
        plaintext: Data,
        thread: TSThread,
        serviceIds: [ServiceId],
        udAccessMap: [ServiceId: OWSUDSendingAccess],
        senderCertificate: SenderCertificate
    ) async throws -> SenderKeySendResult {
        let recipients: [Recipient]
        let ciphertext: Data
        (recipients, ciphertext) = try await self.databaseStorage.awaitableWrite { tx in
            let recipients = serviceIds.map { Recipient(serviceId: $0, transaction: tx) }
            let ciphertext = try self.senderKeyMessageBody(
                plaintext: plaintext,
                message: message,
                thread: thread,
                recipients: recipients,
                senderCertificate: senderCertificate,
                transaction: tx
            )
            return (recipients, ciphertext)
        }
        return try await self._sendSenderKeyRequest(
            encryptedMessageBody: ciphertext,
            timestamp: message.timestamp,
            isOnline: message.isOnline,
            isUrgent: message.isUrgent,
            isStory: message.isStorySend,
            thread: thread,
            recipients: recipients,
            udAccessMap: udAccessMap,
            remainingAttempts: 3
        )
    }

    // TODO: This is a similar pattern to RequestMaker. An opportunity to reduce duplication.
    fileprivate func _sendSenderKeyRequest(
        encryptedMessageBody: Data,
        timestamp: UInt64,
        isOnline: Bool,
        isUrgent: Bool,
        isStory: Bool,
        thread: TSThread,
        recipients: [Recipient],
        udAccessMap: [ServiceId: OWSUDSendingAccess],
        remainingAttempts: UInt
    ) async throws -> SenderKeySendResult {
        do {
            let httpResponse = try await self.performSenderKeySend(
                ciphertext: encryptedMessageBody,
                timestamp: timestamp,
                isOnline: isOnline,
                isUrgent: isUrgent,
                isStory: isStory,
                thread: thread,
                recipients: recipients,
                udAccessMap: udAccessMap
            )

            guard httpResponse.responseStatusCode == 200 else { throw
                OWSAssertionError("Unhandled error")
            }

            let response = try Self.decodeSuccessResponse(data: httpResponse.responseBodyData)
            let unregisteredServiceIds = Set(response.unregisteredServiceIds.map { $0.wrappedValue })
            let successful = recipients.filter { !unregisteredServiceIds.contains($0.serviceId) }
            let unregistered = recipients.filter { unregisteredServiceIds.contains($0.serviceId) }
            return SenderKeySendResult(success: successful, unregistered: unregistered)
        } catch {
            let retryIfPossible = { () async throws -> SenderKeySendResult in
                if remainingAttempts > 0 {
                    return try await self._sendSenderKeyRequest(
                        encryptedMessageBody: encryptedMessageBody,
                        timestamp: timestamp,
                        isOnline: isOnline,
                        isUrgent: isUrgent,
                        isStory: isStory,
                        thread: thread,
                        recipients: recipients,
                        udAccessMap: udAccessMap,
                        remainingAttempts: remainingAttempts-1
                    )
                } else {
                    throw error
                }
            }

            if error.isNetworkFailureOrTimeout {
                return try await retryIfPossible()
            } else if let httpError = error as? OWSHTTPError {
                let statusCode = httpError.httpStatusCode ?? 0
                let responseData = httpError.httpResponseData
                switch statusCode {
                case 401:
                    owsFailDebug("Invalid composite authorization header for sender key send request. Falling back to fanout")
                    throw SenderKeyError.invalidAuthHeader
                case 404:
                    Logger.warn("One of the recipients could not match an account. We don't know which. Falling back to fanout.")
                    throw SenderKeyError.invalidRecipient
                case 409:
                    // Incorrect device set. We should add/remove devices and try again.
                    let responseBody = try Self.decode409Response(data: responseData)
                    await self.databaseStorage.awaitableWrite { tx in
                        for account in responseBody {
                            self.updateDevices(
                                serviceId: account.serviceId,
                                devicesToAdd: account.devices.missingDevices,
                                devicesToRemove: account.devices.extraDevices,
                                transaction: tx
                            )
                        }
                    }
                    throw SenderKeyError.deviceUpdate

                case 410:
                    // Server reports stale devices. We should reset our session and try again.
                    let responseBody = try Self.decode410Response(data: responseData)
                    await self.databaseStorage.awaitableWrite { tx in
                        for account in responseBody {
                            self.handleStaleDevices(account.devices.staleDevices, for: account.serviceId, tx: tx.asV2Write)
                        }
                    }
                    throw SenderKeyError.staleDevices
                case 428:
                    guard let body = responseData, let expiry = error.httpRetryAfterDate else {
                        throw OWSAssertionError("Invalid spam response body")
                    }
                    try await withCheckedThrowingContinuation { continuation in
                        self.spamChallengeResolver.handleServerChallengeBody(body, retryAfter: expiry) { didSucceed in
                            if didSucceed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: SpamChallengeRequiredError())
                            }
                        }
                    }
                    return try await retryIfPossible()
                default:
                    // Unhandled response code.
                    throw error
                }
            } else {
                owsFailDebug("Unexpected error \(error)")
                throw error
            }
        }
    }

    private func senderKeyMessageBody(
        plaintext: Data,
        message: TSOutgoingMessage,
        thread: TSThread,
        recipients: [Recipient],
        senderCertificate: SenderCertificate,
        transaction writeTx: SDSAnyWriteTransaction
    ) throws -> Data {
        let groupIdForSending: Data
        if let groupThread = thread as? TSGroupThread {
            // multiRecipient messages really need to have the USMC groupId actually match the target thread. Otherwise
            // this breaks sender key recovery. So we'll always use the thread's groupId here, but we'll verify that
            // we're not trying to send any messages with a special envelope groupId.
            // These are only ever set on resend request/response messages, which are only sent through a 1:1 session,
            // but we should be made aware if that ever changes.
            owsAssertDebug(message.envelopeGroupIdWithTransaction(writeTx) == groupThread.groupId)

            groupIdForSending = groupThread.groupId
        } else {
            // If we're not a group thread, we don't have a groupId.
            // TODO: Eventually LibSignalClient could allow passing `nil` in this case
            groupIdForSending = Data()
        }

        let identityManager = DependenciesBridge.shared.identityManager
        let signalProtocolStoreManager = DependenciesBridge.shared.signalProtocolStoreManager
        let protocolAddresses = recipients.flatMap { $0.protocolAddresses }
        let secretCipher = try SMKSecretSessionCipher(
            sessionStore: signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore,
            preKeyStore: signalProtocolStoreManager.signalProtocolStore(for: .aci).preKeyStore,
            signedPreKeyStore: signalProtocolStoreManager.signalProtocolStore(for: .aci).signedPreKeyStore,
            kyberPreKeyStore: signalProtocolStoreManager.signalProtocolStore(for: .aci).kyberPreKeyStore,
            identityStore: identityManager.libSignalStore(for: .aci, tx: writeTx.asV2Write),
            senderKeyStore: Self.senderKeyStore)

        let distributionId = senderKeyStore.distributionIdForSendingToThread(thread, writeTx: writeTx)
        let ciphertext = try secretCipher.groupEncryptMessage(
            recipients: protocolAddresses,
            paddedPlaintext: plaintext.paddedMessageBody,
            senderCertificate: senderCertificate,
            groupId: groupIdForSending,
            distributionId: distributionId,
            contentHint: message.contentHint.signalClientHint,
            protocolContext: writeTx)

        guard ciphertext.count <= Self.maxSenderKeyEnvelopeSize else {
            Logger.error("serializedMessage: \(ciphertext.count) > \(Self.maxSenderKeyEnvelopeSize)")
            throw SenderKeyError.oversizeMessage
        }
        return ciphertext
    }

    private func performSenderKeySend(
        ciphertext: Data,
        timestamp: UInt64,
        isOnline: Bool,
        isUrgent: Bool,
        isStory: Bool,
        thread: TSThread,
        recipients: [Recipient],
        udAccessMap: [ServiceId: OWSUDSendingAccess]
    ) async throws -> HTTPResponse {

        // Sender key messages use an access key composed of every recipient's individual access key.
        let allAccessKeys = recipients.compactMap {
            udAccessMap[$0.serviceId]?.udAccess.senderKeyUDAccessKey
        }
        guard recipients.count == allAccessKeys.count else {
            throw OWSAssertionError("Incomplete access key set")
        }
        guard let firstKey = allAccessKeys.first else {
            throw OWSAssertionError("Must provide at least one address")
        }
        let remainingKeys = allAccessKeys.dropFirst()
        let compositeKey = remainingKeys.reduce(firstKey, ^)

        let request = OWSRequestFactory.submitMultiRecipientMessageRequest(
            ciphertext: ciphertext,
            compositeUDAccessKey: compositeKey,
            timestamp: timestamp,
            isOnline: isOnline,
            isUrgent: isUrgent,
            isStory: isStory
        )

        return try await networkManager.makePromise(request: request, canUseWebSocket: true).awaitable()
    }
}

extension MessageSender {

    struct SuccessPayload: Decodable {
        let unregisteredServiceIds: [ServiceIdString]

        enum CodingKeys: String, CodingKey {
            case unregisteredServiceIds = "uuids404"
        }
    }

    typealias ResponseBody409 = [Account409]
    struct Account409: Decodable {
        @ServiceIdString var serviceId: ServiceId
        let devices: DeviceSet

        enum CodingKeys: String, CodingKey {
            case serviceId = "uuid"
            case devices
        }

        struct DeviceSet: Decodable {
            let missingDevices: [UInt32]
            let extraDevices: [UInt32]
        }
    }

    typealias ResponseBody410 = [Account410]
    struct Account410: Decodable {
        @ServiceIdString var serviceId: ServiceId
        let devices: DeviceSet

        enum CodingKeys: String, CodingKey {
            case serviceId = "uuid"
            case devices
        }

        struct DeviceSet: Decodable {
            let staleDevices: [UInt32]
        }
    }

    static func decodeSuccessResponse(data: Data?) throws -> SuccessPayload {
        guard let data = data else {
            throw OWSAssertionError("No data provided")
        }
        return try JSONDecoder().decode(SuccessPayload.self, from: data)
    }

    static func decode409Response(data: Data?) throws -> ResponseBody409 {
        guard let data = data else {
            throw OWSAssertionError("No data provided")
        }
        return try JSONDecoder().decode(ResponseBody409.self, from: data)
    }

    static func decode410Response(data: Data?) throws -> ResponseBody410 {
        guard let data = data else {
            throw OWSAssertionError("No data provided")
        }
        return try JSONDecoder().decode(ResponseBody410.self, from: data)
    }
}

fileprivate extension MessageSender {

    enum RegistrationIdStatus {
        /// The address has a session with a valid registration id
        case valid
        /// LibSignalClient expects registrationIds to fit in 15 bits for multiRecipientEncrypt,
        /// but there are some reports of clients having larger registrationIds. Unclear why.
        case invalid
        /// There is no session for this address. Unclear why this would happen; but in this case
        /// the address should receive an SKDM.
        case noSession
    }

    /// We shouldn't send a SenderKey message to addresses with a session record with
    /// an invalid registrationId.
    /// We should send an SKDM to addresses with no session record at all.
    ///
    /// For now, let's perform a check to filter out invalid registrationIds. An
    /// investigation into cleaning up these invalid registrationIds is ongoing.
    ///
    /// Also check for missing sessions (shouldn't happen if we've gotten this far, since
    /// SenderKeyStore already said this address has previous Sender Key sends). We should
    /// investigate how this ever happened, but for now fall back to sending another SKDM.
    static func registrationIdStatus(for serviceId: ServiceId, transaction tx: SDSAnyReadTransaction) -> RegistrationIdStatus {
        let candidateDevices = MessageSender.Recipient(serviceId: serviceId, transaction: tx).devices
        let sessionStore = DependenciesBridge.shared.signalProtocolStoreManager.signalProtocolStore(for: .aci).sessionStore
        for deviceId in candidateDevices {
            do {
                guard
                    let sessionRecord = try sessionStore.loadSession(
                        for: serviceId,
                        deviceId: deviceId,
                        tx: tx.asV2Read
                    ),
                    sessionRecord.hasCurrentState
                else { return .noSession }
                let registrationId = try sessionRecord.remoteRegistrationId()
                let isValidRegistrationId = (registrationId & 0x3fff == registrationId)
                owsAssertDebug(isValidRegistrationId)
                if !isValidRegistrationId {
                    return .invalid
                }
            } catch {
                // An error is never thrown on nil result; only if there's something
                // on disk but parsing fails.
                owsFailDebug("Failed to fetch registrationId for \(serviceId): \(error)")
                return .invalid
            }
        }
        return .valid
    }
}
