//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

@testable import SignalServiceKit

import XCTest

final class DeleteForMeOutgoingSyncMessageManagerTest: XCTestCase {
    private var mockSyncMessageSender: MockSyncMessageSender!
    private var mockRecipientDatabaseTable: MockRecipientDatabaseTable!
    private var mockThreadStore: MockThreadStore!

    private var outgoingSyncMessageManager: DeleteForMeOutgoingSyncMessageManagerImpl!

    override func setUp() {
        mockSyncMessageSender = MockSyncMessageSender()
        mockRecipientDatabaseTable = MockRecipientDatabaseTable()
        mockThreadStore = MockThreadStore()

        outgoingSyncMessageManager = DeleteForMeOutgoingSyncMessageManagerImpl(
            deleteForMeSyncMessageSettingsStore: MockDeleteForMeSyncMessageSettingsStore(),
            recipientDatabaseTable: mockRecipientDatabaseTable,
            syncMessageSender: mockSyncMessageSender,
            threadStore: mockThreadStore
        )
    }

    func testBatchedInteractionDeletes() {
        let thread = TSContactThread(contactAddress: .isolatedRandomForTesting())
        let messagesToDelete = (0..<1501).map { _ -> TSOutgoingMessage in
            return TSOutgoingMessage(uniqueId: .uniqueId(), thread: thread)
        }

        var expectedInteractionBatches: [Int] = [500, 500, 500, 1]
        mockSyncMessageSender.sendSyncMessageMock = { contents in
            guard let expectedBatchSize = expectedInteractionBatches.popFirst() else {
                XCTFail("Unexpected batch!")
                return
            }

            XCTAssertEqual(contents.messageDeletes.count, 1)
            XCTAssertEqual(contents.messageDeletes.first!.addressableMessages.count, expectedBatchSize)
        }

        MockDB().write { tx in
            outgoingSyncMessageManager.send(
                deletedMessages: messagesToDelete,
                thread: thread,
                localIdentifiers: .forUnitTests,
                tx: tx
            )
        }

        XCTAssertTrue(expectedInteractionBatches.isEmpty)
    }

    func testBatchedAttachmentDeletes() {
        let thread = TSContactThread(contactAddress: .isolatedRandomForTesting())

        let attachmentsToDelete = (0..<1501).map { _ -> DeleteForMeSyncMessage.Outgoing.AttachmentIdentifier in
            return .init(clientUuid: UUID(), encryptedDigest: nil, plaintextHash: nil)
        }

        var expectedAttachmentBatches: [Int] = [500, 500, 500, 1]
        mockSyncMessageSender.sendSyncMessageMock = { contents in
            guard let expectedBatchSize = expectedAttachmentBatches.popFirst() else {
                XCTFail("Unexpected batch!")
                return
            }

            XCTAssertEqual(contents.attachmentDeletes!.count, expectedBatchSize)
        }

        MockDB().write { tx in
            outgoingSyncMessageManager.send(
                deletedAttachmentIdentifiers: Dictionary(
                    [
                        (TSOutgoingMessage(uniqueId: .uniqueId(), thread: thread), Array(attachmentsToDelete.prefix(200))),
                        (TSOutgoingMessage(uniqueId: .uniqueId(), thread: thread), Array(attachmentsToDelete.dropFirst(200))),
                    ],
                    uniquingKeysWith: { lhs, rhs in
                        XCTFail("Colliding keys!")
                        return lhs
                    }
                ),
                thread: thread,
                localIdentifiers: .forUnitTests,
                tx: tx
            )
        }

        XCTAssertTrue(expectedAttachmentBatches.isEmpty)
    }

    func testBatchedThreadDeletes() {
        let threadsToDelete = (0..<301).map { _ -> TSContactThread in
            return TSContactThread(contactAddress: .isolatedRandomForTesting())
        }

        var expectedThreadBatches: [Int] = [100, 100, 100, 1]
        mockSyncMessageSender.sendSyncMessageMock = { contents in
            guard let expectedBatchSize = expectedThreadBatches.popFirst() else {
                XCTFail("Unexpected batch!")
                return
            }

            XCTAssertEqual(contents.localOnlyConversationDelete.count, expectedBatchSize)
        }

        MockDB().write { tx in
            /// These should all be local-only deletes, since we're not populating
            /// the contexts with any messages deletes (since we're not actually
            /// deleting any messages from the threads in this test).
            let deletionContexts: [DeleteForMeSyncMessage.Outgoing.ThreadDeletionContext] = threadsToDelete.map { thread in
                outgoingSyncMessageManager.makeThreadDeletionContext(
                    thread: thread,
                    isFullDelete: true,
                    localIdentifiers: .forUnitTests,
                    tx: tx
                )!
            }

            outgoingSyncMessageManager.send(
                threadDeletionContexts: deletionContexts,
                tx: tx
            )
        }

        XCTAssertTrue(expectedThreadBatches.isEmpty)
    }
}

private extension String {
    static func uniqueId() -> String {
        return UUID().uuidString
    }
}

// MARK: - Mocks

private final class MockDeleteForMeSyncMessageSettingsStore: DeleteForMeSyncMessageSettingsStore {
    func isSendingEnabled(tx: any DBReadTransaction) -> Bool {
        return true
    }

    func enableSending(tx: any DBWriteTransaction) {
        owsFail("Not implemented!")
    }
}

private final class MockSyncMessageSender: DeleteForMeOutgoingSyncMessageManagerImpl.Shims.SyncMessageSender {
    var sendSyncMessageMock: ((
        _ contents: DeleteForMeOutgoingSyncMessage.Contents
    ) -> Void)!
    func sendSyncMessage(contents: DeleteForMeOutgoingSyncMessage.Contents, localThread: TSContactThread, tx: any DBWriteTransaction) {
        sendSyncMessageMock(contents)
    }
}
