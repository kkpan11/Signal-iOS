//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

public extension GroupsV2Impl {

    // MARK: - Restore Groups

    // A list of all groups we've learned of from the storage service.
    //
    // Values are irrelevant (bools).
    private static let allStorageServiceGroupIds = SDSKeyValueStore(collection: "GroupsV2Impl.groupsFromStorageService_All")

    // A list of the groups we need to try to restore. Values are serialized GroupV2Records.
    private static let storageServiceGroupsToRestore = SDSKeyValueStore(collection: "GroupsV2Impl.groupsFromStorageService_EnqueuedRecordForRestore")

    // A deprecated list of the groups we need to restore. Values are master keys.
    private static let legacyStorageServiceGroupsToRestore = SDSKeyValueStore(collection: "GroupsV2Impl.groupsFromStorageService_EnqueuedForRestore")

    // A list of the groups we failed to restore.
    //
    // Values are irrelevant (bools).
    private static let failedStorageServiceGroupIds = SDSKeyValueStore(collection: "GroupsV2Impl.groupsFromStorageService_Failed")

    private static let restoreGroupsOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "GroupsV2-Restore"
        return queue
    }()

    static func isGroupKnownToStorageService(groupModel: TSGroupModelV2, transaction: SDSAnyReadTransaction) -> Bool {
        do {
            let masterKeyData = try groupModel.masterKey().serialize().asData
            let key = restoreGroupKey(forMasterKeyData: masterKeyData)
            return allStorageServiceGroupIds.hasValue(forKey: key, transaction: transaction)
        } catch {
            owsFailDebug("Error: \(error)")
            return false
        }
    }

    static func enqueuedGroupRecordForRestore(
        masterKeyData: Data,
        transaction: SDSAnyReadTransaction
    ) -> StorageServiceProtoGroupV2Record? {
        let key = restoreGroupKey(forMasterKeyData: masterKeyData)
        guard let recordData = storageServiceGroupsToRestore.getData(key, transaction: transaction) else {
            return nil
        }
        return try? .init(serializedData: recordData)
    }

    static func enqueueGroupRestore(
        groupRecord: StorageServiceProtoGroupV2Record,
        account: AuthedAccount,
        transaction: SDSAnyWriteTransaction
    ) {

        guard GroupMasterKey.isValid(groupRecord.masterKey) else {
            owsFailDebug("Invalid master key.")
            return
        }

        let key = restoreGroupKey(forMasterKeyData: groupRecord.masterKey)

        if !allStorageServiceGroupIds.hasValue(forKey: key, transaction: transaction) {
            allStorageServiceGroupIds.setBool(true, key: key, transaction: transaction)
        }

        guard !failedStorageServiceGroupIds.hasValue(forKey: key, transaction: transaction) else {
            // Past restore attempts failed in an unrecoverable way.
            return
        }

        guard let serializedData = try? groupRecord.serializedData() else {
            owsFailDebug("Can't restore group with unserializable record")
            return
        }

        // Clear any legacy restore info.
        legacyStorageServiceGroupsToRestore.removeValue(forKey: key, transaction: transaction)

        // Store the record for restoration.
        storageServiceGroupsToRestore.setData(serializedData, key: key, transaction: transaction)

        transaction.addAsyncCompletionOffMain {
            self.enqueueRestoreGroupPass(account: account)
        }
    }

    private static func restoreGroupKey(forMasterKeyData masterKeyData: Data) -> String {
        return masterKeyData.hexadecimalString
    }

    private static func canProcessGroupRestore(account: AuthedAccount) -> Bool {
        // CurrentAppContext().isMainAppAndActive should
        // only be called on the main thread.
        guard
            CurrentAppContext().isMainApp,
            CurrentAppContext().isAppForegroundAndActive()
        else {
            return false
        }
        guard reachabilityManager.isReachable else {
            return false
        }
        switch account.info {
        case .explicit:
            break
        case .implicit:
            guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
                return false
            }
        }
        return true
    }

    static func enqueueRestoreGroupPass(account: AuthedAccount) {
        guard canProcessGroupRestore(account: account) else {
            return
        }
        let operation = RestoreGroupOperation(account: account)
        GroupsV2Impl.restoreGroupsOperationQueue.addOperation(operation)
    }

    fileprivate enum RestoreGroupOutcome: CustomStringConvertible {
        case success
        case unretryableFailure
        case retryableFailure
        case emptyQueue
        case cantProcess

        // MARK: - CustomStringConvertible

        public var description: String {
            switch self {
            case .success:
                return "success"
            case .unretryableFailure:
                return "unretryableFailure"
            case .retryableFailure:
                return "retryableFailure"
            case .emptyQueue:
                return "emptyQueue"
            case .cantProcess:
                return "cantProcess"
            }
        }
    }

    private static func anyEnqueuedGroupRecord(transaction: SDSAnyReadTransaction) -> StorageServiceProtoGroupV2Record? {
        guard let serializedData = storageServiceGroupsToRestore.anyDataValue(transaction: transaction) else {
            return nil
        }
        return try? .init(serializedData: serializedData)
    }

    // Every invocation of this method should remove (up to) one group from the queue.
    //
    // This method should only be called on restoreGroupsOperationQueue.
    private static func tryToRestoreNextGroup(account: AuthedAccount) -> Promise<RestoreGroupOutcome> {
        guard canProcessGroupRestore(account: account) else {
            return Promise.value(.cantProcess)
        }
        return Promise<RestoreGroupOutcome> { future in
            DispatchQueue.global().async {
                let (masterKeyData, groupRecord) = self.databaseStorage.read { transaction -> (Data?, StorageServiceProtoGroupV2Record?) in
                    if let groupRecord = self.anyEnqueuedGroupRecord(transaction: transaction) {
                        return (groupRecord.masterKey, groupRecord)
                    } else {
                        // Make sure we don't have any legacy master key only enqueued groups
                        return (legacyStorageServiceGroupsToRestore.anyDataValue(transaction: transaction), nil)
                    }
                }

                guard let masterKeyData = masterKeyData else {
                    return future.resolve(.emptyQueue)
                }
                let key = self.restoreGroupKey(forMasterKeyData: masterKeyData)

                // If we have an unrecoverable failure, remove the key
                // from the store so that we stop retrying until the
                // next time that storage service prods us to try.
                let markAsFailed = {
                    databaseStorage.write { transaction in
                        self.storageServiceGroupsToRestore.removeValue(forKey: key, transaction: transaction)
                        self.legacyStorageServiceGroupsToRestore.removeValue(forKey: key, transaction: transaction)
                        self.failedStorageServiceGroupIds.setBool(true, key: key, transaction: transaction)
                    }
                }
                let markAsComplete = {
                    databaseStorage.write { transaction in
                        // Now that the thread exists, re-apply the pending group record from storage service.
                        if var groupRecord {
                            // First apply any migrations
                            if StorageServiceUnknownFieldMigrator.shouldInterceptRemoteManifestBeforeMerging(tx: transaction) {
                                groupRecord = StorageServiceUnknownFieldMigrator.interceptRemoteManifestBeforeMerging(
                                    record: groupRecord,
                                    tx: transaction
                                )
                            }

                            let recordUpdater = StorageServiceGroupV2RecordUpdater(
                                authedAccount: account,
                                blockingManager: blockingManager,
                                groupsV2: groupsV2,
                                profileManager: profileManager
                            )
                            _ = recordUpdater.mergeRecord(groupRecord, transaction: transaction)
                        }

                        self.storageServiceGroupsToRestore.removeValue(forKey: key, transaction: transaction)
                        self.legacyStorageServiceGroupsToRestore.removeValue(forKey: key, transaction: transaction)
                    }
                }

                let groupContextInfo: GroupV2ContextInfo
                do {
                    groupContextInfo = try GroupV2ContextInfo.deriveFrom(masterKeyData: masterKeyData)
                } catch {
                    owsFailDebug("Error: \(error)")
                    markAsFailed()
                    return future.resolve(.unretryableFailure)
                }

                let isGroupInDatabase = self.databaseStorage.read { transaction in
                    TSGroupThread.fetch(groupId: groupContextInfo.groupId, transaction: transaction) != nil
                }
                guard !isGroupInDatabase else {
                    // No work to be done, group already in database.
                    markAsComplete()
                    return future.resolve(.success)
                }

                // This will try to update the group using incremental "changes" but
                // failover to using a "snapshot".
                let groupUpdateMode = GroupUpdateMode.upToCurrentRevisionAfterMessageProcessWithThrottling
                Promise.wrapAsync {
                    try await self.groupV2Updates.tryToRefreshV2GroupThread(
                        groupId: groupContextInfo.groupId,
                        spamReportingMetadata: .learnedByLocallyInitatedRefresh,
                        groupSecretParams: groupContextInfo.groupSecretParams,
                        groupUpdateMode: groupUpdateMode
                    )
                }.done { _ in
                    markAsComplete()
                    future.resolve(.success)
                }.catch { error in
                    if error.isNetworkFailureOrTimeout {
                        Logger.warn("Error: \(error)")
                        return future.resolve(.retryableFailure)
                    } else {
                        switch error {
                        case GroupsV2Error.localUserNotInGroup:
                            Logger.warn("Error: \(error)")
                        default:
                            owsFailDebug("Error: \(error)")
                        }
                        markAsFailed()
                        return future.resolve(.unretryableFailure)
                    }
                }
            }
        }
    }

    // MARK: -

    private class RestoreGroupOperation: OWSOperation {

        private let account: AuthedAccount

        init(account: AuthedAccount) {
            self.account = account
            super.init()
        }

        public override func run() {
            firstly { [account] in
                GroupsV2Impl.tryToRestoreNextGroup(account: account)
            }.done(on: DispatchQueue.global()) { [account] outcome in
                switch outcome {
                case .success, .unretryableFailure:
                    // Continue draining queue.
                    GroupsV2Impl.enqueueRestoreGroupPass(account: account)
                case .retryableFailure:
                    // Pause processing for now.
                    // Presumably network failures are preventing restores.
                    break
                case .emptyQueue, .cantProcess:
                    // Stop processing.
                    break
                }
                self.reportSuccess()
            }.catch(on: DispatchQueue.global()) { (error) in
                // tryToRestoreNextGroup() should never fail.
                owsFailDebug("Group restore failed: \(error)")
                self.reportError(SSKUnretryableError.restoreGroupFailed)
            }
        }

        public override func didFail(error: Error) {
            Logger.error("failed with error: \(error)")
        }
    }
}
