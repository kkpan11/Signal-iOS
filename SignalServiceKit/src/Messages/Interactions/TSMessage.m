//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "TSMessage.h"
#import "AppContext.h"
#import "MIMETypeUtil.h"
#import "OWSContact.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "OWSDisappearingMessagesJob.h"
#import "TSAttachment.h"
#import "TSAttachmentStream.h"
#import "TSQuotedMessage.h"
#import "TSThread.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/NSString+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger OWSMessageSchemaVersion = 4;

#pragma mark -

@interface TSMessage ()

@property (nonatomic, nullable) NSString *body;
@property (nonatomic, nullable) MessageBodyRanges *bodyRanges;

@property (nonatomic) uint32_t expiresInSeconds;
@property (nonatomic) uint64_t expireStartedAt;

/**
 * The version of the model class's schema last used to serialize this model. Use this to manage data migrations during
 * object de/serialization.
 *
 * e.g.
 *
 *    - (id)initWithCoder:(NSCoder *)coder
 *    {
 *      self = [super initWithCoder:coder];
 *      if (!self) { return self; }
 *      if (_schemaVersion < 2) {
 *        _newName = [coder decodeObjectForKey:@"oldName"]
 *      }
 *      ...
 *      _schemaVersion = 2;
 *    }
 */
@property (nonatomic, readonly) NSUInteger schemaVersion;

@property (nonatomic, nullable) TSQuotedMessage *quotedMessage;
@property (nonatomic, nullable) OWSContact *contactShare;
@property (nonatomic, nullable) OWSLinkPreview *linkPreview;
@property (nonatomic, nullable) MessageSticker *messageSticker;

@property (nonatomic) BOOL isViewOnceMessage;
@property (nonatomic) BOOL isViewOnceComplete;
@property (nonatomic) BOOL wasRemotelyDeleted;

@property (nonatomic, nullable) NSString *storyReactionEmoji;

// This property is only intended to be used by GRDB queries.
@property (nonatomic, readonly) BOOL storedShouldStartExpireTimer;

@end

#pragma mark -

@implementation TSMessage

- (instancetype)initMessageWithBuilder:(TSMessageBuilder *)messageBuilder
{
    self = [super initInteractionWithTimestamp:messageBuilder.timestamp thread:messageBuilder.thread];
    if (!self) {
        return self;
    }

    _schemaVersion = OWSMessageSchemaVersion;

    if (messageBuilder.messageBody.length > 0) {
        _body = messageBuilder.messageBody;
        _bodyRanges = messageBuilder.bodyRanges;
    } else if (messageBuilder.messageBody != nil) {
        OWSFailDebug(@"Empty message body.");
    }
    _attachmentIds = messageBuilder.attachmentIds;
    _editState = messageBuilder.editState;
    _expiresInSeconds = messageBuilder.expiresInSeconds;
    _expireStartedAt = messageBuilder.expireStartedAt;
    [self updateExpiresAt];
    _quotedMessage = messageBuilder.quotedMessage;
    _contactShare = messageBuilder.contactShare;
    _linkPreview = messageBuilder.linkPreview;
    _messageSticker = messageBuilder.messageSticker;
    _isViewOnceMessage = messageBuilder.isViewOnceMessage;
    _isViewOnceComplete = NO;
    _storyTimestamp = messageBuilder.storyTimestamp;
    _storyAuthorUuidString = messageBuilder.storyAuthorAddress.uuidString;
    _storyReactionEmoji = messageBuilder.storyReactionEmoji;
    _isGroupStoryReply = messageBuilder.isGroupStoryReply;
    _giftBadge = messageBuilder.giftBadge;

#ifdef DEBUG
    [self verifyPerConversationExpiration];
#endif

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
                       editState:(TSEditState)editState
                 expireStartedAt:(uint64_t)expireStartedAt
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
                       giftBadge:(nullable OWSGiftBadge *)giftBadge
               isGroupStoryReply:(BOOL)isGroupStoryReply
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
           storyAuthorUuidString:(nullable NSString *)storyAuthorUuidString
              storyReactionEmoji:(nullable NSString *)storyReactionEmoji
                  storyTimestamp:(nullable NSNumber *)storyTimestamp
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId
               receivedAtTimestamp:receivedAtTimestamp
                            sortId:sortId
                         timestamp:timestamp
                    uniqueThreadId:uniqueThreadId];

    if (!self) {
        return self;
    }

    _attachmentIds = attachmentIds;
    _body = body;
    _bodyRanges = bodyRanges;
    _contactShare = contactShare;
    _editState = editState;
    _expireStartedAt = expireStartedAt;
    _expiresAt = expiresAt;
    _expiresInSeconds = expiresInSeconds;
    _giftBadge = giftBadge;
    _isGroupStoryReply = isGroupStoryReply;
    _isViewOnceComplete = isViewOnceComplete;
    _isViewOnceMessage = isViewOnceMessage;
    _linkPreview = linkPreview;
    _messageSticker = messageSticker;
    _quotedMessage = quotedMessage;
    _storedShouldStartExpireTimer = storedShouldStartExpireTimer;
    _storyAuthorUuidString = storyAuthorUuidString;
    _storyReactionEmoji = storyReactionEmoji;
    _storyTimestamp = storyTimestamp;
    _wasRemotelyDeleted = wasRemotelyDeleted;

    [self sdsFinalizeMessage];

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (void)sdsFinalizeMessage
{
#ifdef DEBUG
    [self verifyPerConversationExpiration];
#endif

    [self updateExpiresAt];
}

- (void)verifyPerConversationExpiration
{
    if (_expireStartedAt > 0 || _expiresAt > 0) {
        // It only makes sense to set expireStartedAt and expiresAt for messages
        // with per-conversation expiration, e.g. expiresInSeconds > 0.
        // If either expireStartedAt and expiresAt are set, both should be set.
        //        OWSAssertDebug(_expiresInSeconds > 0);
        //        OWSAssertDebug(_expireStartedAt > 0);
        //        OWSAssertDebug(_expiresAt > 0);
    }
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    if (_schemaVersion < 2) {
        // renamed _attachments to _attachmentIds
        if (!_attachmentIds) {
            _attachmentIds = [coder decodeObjectForKey:@"attachments"];
        }
    }

    if (_schemaVersion < 3) {
        _expiresInSeconds = 0;
        _expireStartedAt = 0;
        _expiresAt = 0;
    }

    if (_schemaVersion < 4) {
        // Wipe out the body field on these legacy attachment messages.
        //
        // Explanation: Historically, a message sent from iOS could be an attachment XOR a text message,
        // but now we support sending an attachment+caption as a single message.
        //
        // Other clients have supported sending attachment+caption in a single message for a long time.
        // So the way we used to handle receiving them was to make it look like they'd sent two messages:
        // first the attachment+caption (we'd ignore this caption when rendering), followed by a separate
        // message with just the caption (which we'd render as a simple independent text message), for
        // which we'd offset the timestamp by a little bit to get the desired ordering.
        //
        // Now that we can properly render an attachment+caption message together, these legacy "dummy" text
        // messages are not only unnecessary, but worse, would be rendered redundantly. For safety, rather
        // than building the logic to try to find and delete the redundant "dummy" text messages which users
        // have been seeing and interacting with, we delete the body field from the attachment message,
        // which iOS users have never seen directly.
        if (_attachmentIds.count > 0) {
            _body = nil;
        }
    }

    if (!_attachmentIds) {
        _attachmentIds = @[];
    }

    _schemaVersion = OWSMessageSchemaVersion;

    // Upgrades legacy messages.
    //
    // TODO: We can eventually remove this migration since
    //       per-message expiration was never released to
    //       production.
    NSNumber *_Nullable perMessageExpirationDurationSeconds =
        [coder decodeObjectForKey:@"perMessageExpirationDurationSeconds"];
    if (perMessageExpirationDurationSeconds.unsignedIntegerValue > 0) {
        _isViewOnceMessage = YES;
    }
    NSNumber *_Nullable perMessageExpirationHasExpired = [coder decodeObjectForKey:@"perMessageExpirationHasExpired"];
    if (perMessageExpirationHasExpired.boolValue > 0) {
        _isViewOnceComplete = YES;
    }

    return self;
}

- (void)setExpireStartedAt:(uint64_t)expireStartedAt
{
    if (_expireStartedAt != 0 && _expireStartedAt < expireStartedAt) {
        OWSLogDebug(@"ignoring later startedAt time");
        return;
    }

    uint64_t now = [NSDate ows_millisecondTimeStamp];
    if (expireStartedAt > now) {
        OWSLogWarn(@"using `now` instead of future time");
    }

    _expireStartedAt = MIN(now, expireStartedAt);

    [self updateExpiresAt];
}

// This method will be called after every insert and update, so it needs
// to be cheap.
- (BOOL)shouldStartExpireTimer
{
    if (self.hasPerConversationExpirationStarted) {
        // Expiration already started.
        return YES;
    }

    return self.hasPerConversationExpiration;
}

- (void)updateExpiresAt
{
    if (self.hasPerConversationExpirationStarted) {
        _expiresAt = _expireStartedAt + _expiresInSeconds * 1000;
    } else {
        _expiresAt = 0;
    }
}

#pragma mark - Story Context

- (nullable AciObjC *)storyAuthorAci
{
    return [[AciObjC alloc] initWithAciString:self.storyAuthorUuidString];
}

- (nullable SignalServiceAddress *)storyAuthorAddress
{
    AciObjC *storyAuthorAci = self.storyAuthorAci;
    if (storyAuthorAci == nil) {
        return nil;
    }
    return [[SignalServiceAddress alloc] initWithServiceIdObjC:storyAuthorAci];
}

- (BOOL)isStoryReply
{
    return self.storyAuthorUuidString != nil && self.storyTimestamp != nil;
}

#pragma mark - Attachments

- (BOOL)hasAttachments
{
    return self.attachmentIds ? (self.attachmentIds.count > 0) : NO;
}

- (NSArray<NSString *> *)allAttachmentIds
{
    NSMutableArray<NSString *> *result = [NSMutableArray new];
    if (self.attachmentIds.count > 0) {
        [result addObjectsFromArray:self.attachmentIds];
    }

    if (self.quotedMessage.thumbnailAttachmentId) {
        [result addObject:self.quotedMessage.thumbnailAttachmentId];
    }

    if (self.contactShare.avatarAttachmentId) {
        [result addObject:self.contactShare.avatarAttachmentId];
    }

    if (self.linkPreview.imageAttachmentId) {
        [result addObject:self.linkPreview.imageAttachmentId];
    }

    if (self.messageSticker.attachmentId) {
        [result addObject:self.messageSticker.attachmentId];
    }

    // Use a set to de-duplicate the result.
    return [NSSet setWithArray:result].allObjects;
}

- (NSArray<TSAttachment *> *)bodyAttachmentsWithTransaction:(GRDBReadTransaction *)transaction
{
    // Note: attachmentIds vs. allAttachmentIds
    return [AttachmentFinder attachmentsWithAttachmentIds:self.attachmentIds transaction:transaction];
}

- (NSArray<TSAttachment *> *)allAttachmentsWithTransaction:(GRDBReadTransaction *)transaction
{
    // Note: attachmentIds vs. allAttachmentIds
    return [AttachmentFinder attachmentsWithAttachmentIds:self.allAttachmentIds transaction:transaction];
}

- (NSArray<TSAttachment *> *)bodyAttachmentsWithTransaction:(GRDBReadTransaction *)transaction
                                                contentType:(NSString *)contentType
{
    return [AttachmentFinder attachmentsWithAttachmentIds:self.attachmentIds
                                      matchingContentType:contentType
                                              transaction:transaction];
}

- (NSArray<TSAttachment *> *)bodyAttachmentsWithTransaction:(GRDBReadTransaction *)transaction
                                          exceptContentType:(NSString *)contentType
{
    return [AttachmentFinder attachmentsWithAttachmentIds:self.attachmentIds
                                      ignoringContentType:contentType
                                              transaction:transaction];
}

- (void)removeAttachment:(TSAttachment *)attachment transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug([self.attachmentIds containsObject:attachment.uniqueId]);
    [attachment anyRemoveWithTransaction:transaction];

    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) {
                                        NSMutableArray<NSString *> *attachmentIds = [message.attachmentIds mutableCopy];
                                        [attachmentIds removeObject:attachment.uniqueId];
                                        message.attachmentIds = [attachmentIds copy];
                                    }];
}

- (NSString *)debugDescription
{
    if ([self hasAttachments] && self.body.length > 0) {
        NSString *attachmentId = self.attachmentIds[0];
        return [NSString
            stringWithFormat:@"Media Message with attachmentId: %@ and caption: '%@'", attachmentId, self.body];
    } else if ([self hasAttachments]) {
        NSString *attachmentId = self.attachmentIds[0];
        return [NSString stringWithFormat:@"Media Message with attachmentId: %@", attachmentId];
    } else {
        return [NSString stringWithFormat:@"%@ with body: %@ has mentions: %@",
                         [self class],
                         self.body,
                         self.bodyRanges.hasMentions ? @"YES" : @"NO"];
    }
}

- (nullable TSAttachment *)oversizeTextAttachmentWithTransaction:(GRDBReadTransaction *)transaction
{
    return [self bodyAttachmentsWithTransaction:transaction contentType:OWSMimeTypeOversizeTextMessage].firstObject;
}

- (BOOL)hasMediaAttachmentsWithTransaction:(GRDBReadTransaction *)transaction
{
    return [AttachmentFinder existsAttachmentsWithAttachmentIds:self.attachmentIds
                                            ignoringContentType:OWSMimeTypeOversizeTextMessage
                                                    transaction:transaction];
}

- (NSArray<TSAttachment *> *)mediaAttachmentsWithTransaction:(GRDBReadTransaction *)transaction
{
    return [self bodyAttachmentsWithTransaction:transaction exceptContentType:OWSMimeTypeOversizeTextMessage];
}

- (nullable NSString *)oversizeTextWithTransaction:(GRDBReadTransaction *)transaction
{
    TSAttachment *_Nullable attachment = [self oversizeTextAttachmentWithTransaction:transaction];
    if (!attachment) {
        return nil;
    }

    if (![attachment isKindOfClass:TSAttachmentStream.class]) {
        return nil;
    }

    TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;

    NSData *_Nullable data = [NSData dataWithContentsOfFile:attachmentStream.originalFilePath];
    if (!data) {
        //        OWSFailDebug(@"Can't load oversize text data.");
        return nil;
    }
    NSString *_Nullable text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        OWSFailDebug(@"Can't parse oversize text data.");
        return nil;
    }
    return text;
}

- (nullable NSString *)rawBodyWithTransaction:(GRDBReadTransaction *)transaction
{
    NSString *_Nullable oversizeText = [self oversizeTextWithTransaction:transaction];
    if (oversizeText) {
        return oversizeText;
    }

    if (self.body.length > 0) {
        return self.body;
    }

    return nil;
}

- (void)anyWillInsertWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyWillInsertWithTransaction:transaction];

    // StickerManager does reference counting of "known" sticker packs.
    if (self.messageSticker != nil) {
        BOOL willInsert = (self.uniqueId.length < 1
            || nil == [TSMessage anyFetchWithUniqueId:self.uniqueId transaction:transaction]);

        if (willInsert) {
            [StickerManager addKnownStickerInfo:self.messageSticker.info transaction:transaction];
        }
    }

    [self insertMentionsInDatabaseWithTx:transaction];

    [self updateStoredShouldStartExpireTimer];

#ifdef DEBUG
    [self verifyPerConversationExpiration];
#endif
}

- (void)anyDidInsertWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyDidInsertWithTransaction:transaction];

    [self ensurePerConversationExpirationWithTransaction:transaction];

    [self touchStoryMessageIfNecessaryWithReplyCountIncrement:ReplyCountIncrementNewReplyAdded transaction:transaction];
}

- (void)anyWillUpdateWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyWillUpdateWithTransaction:transaction];

    [self updateStoredShouldStartExpireTimer];

#ifdef DEBUG
    [self verifyPerConversationExpiration];
#endif
}

- (void)anyDidUpdateWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyDidUpdateWithTransaction:transaction];

    [self ensurePerConversationExpirationWithTransaction:transaction];

    [self touchStoryMessageIfNecessaryWithReplyCountIncrement:ReplyCountIncrementNoIncrement transaction:transaction];
}

- (void)ensurePerConversationExpirationWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    if (self.hasPerConversationExpirationStarted) {
        // Expiration already started.
        return;
    }
    if (![self shouldStartExpireTimer]) {
        return;
    }
    uint64_t nowMs = [NSDate ows_millisecondTimeStamp];
    [[OWSDisappearingMessagesJob shared] startAnyExpirationForMessage:self
                                                  expirationStartedAt:nowMs
                                                          transaction:transaction];
}

- (void)updateStoredShouldStartExpireTimer
{
    _storedShouldStartExpireTimer = [self shouldStartExpireTimer];
}

- (void)anyWillRemoveWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    // Ensure any associated edits are deleted before removing the interaction
    [self removeEditsWithTransaction:transaction];

    [super anyWillRemoveWithTransaction:transaction];

    // StickerManager does reference counting of "known" sticker packs.
    if (self.messageSticker != nil) {
        BOOL willDelete = (self.uniqueId.length > 0
            && nil != [TSMessage anyFetchWithUniqueId:self.uniqueId transaction:transaction]);

        // StickerManager does reference counting of "known" sticker packs.
        if (willDelete) {
            [StickerManager removeKnownStickerInfo:self.messageSticker.info transaction:transaction];
        }
    }
}

- (void)anyDidRemoveWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyDidRemoveWithTransaction:transaction];

    if ([self hasAttachments]) {
        [MediaGalleryManager recordTimestampForRemovedMessage:self transaction:transaction];
    }

    [self removeAllAttachmentsWithTransaction:transaction];

    [self removeAllReactionsWithTransaction:transaction];

    [self removeAllMentionsWithTransaction:transaction];

    [self touchStoryMessageIfNecessaryWithReplyCountIncrement:ReplyCountIncrementReplyDeleted transaction:transaction];
}

- (void)removeAllAttachmentsWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    for (NSString *attachmentId in self.allAttachmentIds) {
        // We need to fetch each attachment, since [TSAttachment removeWithTransaction:] does important work.
        TSAttachment *_Nullable attachment = [TSAttachment anyFetchWithUniqueId:attachmentId transaction:transaction];
        if (!attachment) {
            if (self.shouldBeSaved) {
                OWSFailDebugUnlessRunningTests(@"couldn't load interaction's attachment for deletion.");
            } else {
                OWSLogWarn(@"couldn't load interaction's attachment for deletion.");
            }
            continue;
        }
        [attachment anyRemoveWithTransaction:transaction];
    };
}

- (void)removeAllMentionsWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [MentionFinder deleteAllMentionsFor:self transaction:transaction.unwrapGrdbWrite];
}

- (BOOL)hasPerConversationExpiration
{
    return self.expiresInSeconds > 0;
}

- (BOOL)hasPerConversationExpirationStarted
{
    return _expireStartedAt > 0 && _expiresInSeconds > 0;
}

- (BOOL)shouldUseReceiptDateForSorting
{
    return YES;
}

- (nullable NSString *)body
{
    return _body.filterStringForDisplay;
}

- (nullable TSAttachment *)fetchQuotedMessageThumbnailWithTransaction:(SDSAnyReadTransaction *)transaction
{
    TSAttachment *_Nullable attachment = [self.quotedMessage fetchThumbnailWithTransaction:transaction];

    // We should clone the attachment if it's been downloaded but our quotedMessage doesn't have its own copy.
    BOOL needsClone = [attachment isKindOfClass:[TSAttachmentStream class]] && !self.quotedMessage.isThumbnailOwned;
    TSAttachment * (^saveUpdatedThumbnail)(SDSAnyWriteTransaction *) = ^TSAttachment *(SDSAnyWriteTransaction *writeTx)
    {
        __block TSAttachment *_Nullable localAttachment = nil;
        [self anyUpdateMessageWithTransaction:writeTx
                                        block:^(TSMessage *message) {
                                            localAttachment = [message.quotedMessage
                                                createThumbnailIfNecessaryWithTransaction:writeTx];
                                        }];
        return localAttachment;
    };

    // If we happen to be handed a write transaction, we can perform the clone synchronously
    // Otherwise, just hand the caller what we have. We'll clone it async.
    if (needsClone && [transaction isKindOfClass:[SDSAnyWriteTransaction class]]) {
        attachment = saveUpdatedThumbnail((SDSAnyWriteTransaction *)transaction);
    } else if (needsClone) {
        DatabaseStorageAsyncWrite(
            self.databaseStorage, ^(SDSAnyWriteTransaction *writeTx) { saveUpdatedThumbnail(writeTx); });
    }
    return attachment;
}

- (void)setQuotedMessageThumbnailAttachmentStream:(TSAttachmentStream *)attachmentStream
                                      transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug([attachmentStream isKindOfClass:[TSAttachmentStream class]]);
    OWSAssertDebug(self.quotedMessage);
    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) {
                                        [message.quotedMessage setThumbnailAttachmentStream:attachmentStream];
                                    }];
}

#pragma mark - Update With... Methods

- (void)updateWithExpireStartedAt:(uint64_t)expireStartedAt transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(expireStartedAt > 0);
    OWSAssertDebug(self.expiresInSeconds > 0);

    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) { [message setExpireStartedAt:expireStartedAt]; }];
}

- (void)updateWithLinkPreview:(OWSLinkPreview *)linkPreview transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(linkPreview);
    OWSAssertDebug(transaction);

    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) { [message setLinkPreview:linkPreview]; }];
}

- (void)updateWithMessageSticker:(MessageSticker *)messageSticker transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(messageSticker);
    OWSAssertDebug(transaction);

    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) { message.messageSticker = messageSticker; }];
}

#ifdef TESTABLE_BUILD

// This method is for testing purposes only.
- (void)updateWithMessageBody:(nullable NSString *)messageBody transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    [self anyUpdateMessageWithTransaction:transaction block:^(TSMessage *message) { message.body = messageBody; }];
}

#endif

#pragma mark - Renderable Content

- (BOOL)hasRenderableContent
{
    // Story replies currently only support a subset of message features, so may not
    // be renderable in some circumstances where a normal message would be.
    if (self.isStoryReply) {
        return [self hasRenderableStoryReplyContent];
    }

    // We DO NOT consider a message with just a linkPreview
    // or quotedMessage to be renderable.
    return (self.body.length > 0 || self.attachmentIds.count > 0 || self.contactShare != nil
        || self.messageSticker != nil || self.giftBadge != nil);
}

- (BOOL)hasRenderableStoryReplyContent
{
    return self.body.length > 0 || self.storyReactionEmoji.isSingleEmoji;
}

#pragma mark - View Once

- (void)updateWithViewOnceCompleteAndRemoveRenderableContentWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);
    OWSAssertDebug(self.isViewOnceMessage);
    OWSAssertDebug(!self.isViewOnceComplete);

    [self removeAllRenderableContentWithTransaction:transaction
                                 messageUpdateBlock:^(TSMessage *message) { message.isViewOnceComplete = YES; }];
}

#pragma mark - Remote Delete

- (void)updateWithRemotelyDeletedAndRemoveRenderableContentWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);
    OWSAssertDebug(!self.wasRemotelyDeleted);

    [self removeAllReactionsWithTransaction:transaction];

    [self removeAllRenderableContentWithTransaction:transaction
                                 messageUpdateBlock:^(TSMessage *message) { message.wasRemotelyDeleted = YES; }];
}

#pragma mark - Remove Renderable Content

- (void)removeAllRenderableContentWithTransaction:(SDSAnyWriteTransaction *)transaction
                               messageUpdateBlock:(void (^)(TSMessage *message))messageUpdateBlock
{
    // We call removeAllAttachmentsWithTransaction() before
    // anyUpdateWithTransaction, because anyUpdateWithTransaction's
    // block can be called twice, once on this instance and once
    // on the copy from the database.  We only want to remove
    // attachments once.
    [self anyReloadWithTransaction:transaction ignoreMissing:YES];
    [self removeAllAttachmentsWithTransaction:transaction];
    [self removeAllMentionsWithTransaction:transaction];
    [MessageSendLogObjC deleteAllPayloadsForInteraction:self tx:transaction];

    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) {
                                        // Remove renderable content.
                                        message.body = nil;
                                        message.bodyRanges = nil;
                                        message.contactShare = nil;
                                        message.quotedMessage = nil;
                                        message.linkPreview = nil;
                                        message.messageSticker = nil;
                                        message.attachmentIds = @[];
                                        message.storyReactionEmoji = nil;
                                        OWSAssertDebug(!message.hasRenderableContent);

                                        messageUpdateBlock(message);
                                    }];
}

- (void)removeRenderableContentWithTransaction:(SDSAnyWriteTransaction *)transaction
                          shouldRemoveBodyText:(BOOL)shouldRemoveBodyText
                   shouldRemoveBodyAttachments:(BOOL)shouldRemoveBodyAttachments
                       shouldRemoveLinkPreview:(BOOL)shouldRemoveLinkPreview
                       shouldRemoveQuotedReply:(BOOL)shouldRemoveQuotedReply
                      shouldRemoveContactShare:(BOOL)shouldRemoveContactShare
{
    OWSAssertDebug(shouldRemoveBodyText || shouldRemoveBodyAttachments || shouldRemoveLinkPreview
        || shouldRemoveQuotedReply || shouldRemoveContactShare);

    // We call removeAllAttachmentsWithTransaction() before
    // anyUpdateWithTransaction, because anyUpdateWithTransaction's
    // block can be called twice, once on this instance and once
    // on the copy from the database.  We only want to remove
    // attachments once.
    [self anyReloadWithTransaction:transaction ignoreMissing:YES];
    if (shouldRemoveBodyText) {
        [self removeAllMentionsWithTransaction:transaction];
    }

    // Remove relevant attachments.
    //
    // We need to keep this method closely aligned with allAttachmentIds.
    // We use unknownAttachmentIds to detect any unknown attachment types.
    NSMutableSet<NSString *> *unknownAttachmentIds = [NSMutableSet setWithArray:self.allAttachmentIds];

    // "Body attachments" includes body media, stickers, audio & generic attachments.
    // It can also contain the "oversize text" attachment, which we special-case below.
    NSMutableSet<NSString *> *bodyAttachmentIds = [NSMutableSet setWithArray:self.attachmentIds];
    NSMutableSet<NSString *> *removedBodyAttachmentIds = [NSMutableSet new];
    if (self.messageSticker.attachmentId != nil) {
        [bodyAttachmentIds addObject:self.messageSticker.attachmentId];
    }
    [unknownAttachmentIds minusSet:bodyAttachmentIds];
    for (NSString *attachmentId in bodyAttachmentIds) {
        BOOL wasRemoved = [self removeAttachmentWithId:attachmentId
                                           filterBlock:^(TSAttachment *attachment) {
                                               // We can only discriminate oversize text attachments at the
                                               // last minute by consulting the attachment model.
                                               if (attachment.isOversizeText) {
                                                   OWSLogVerbose(@"Removing oversize text attachment.");
                                                   return shouldRemoveBodyText;
                                               } else {
                                                   OWSLogVerbose(@"Removing body attachment.");
                                                   return shouldRemoveBodyAttachments;
                                               }
                                           }
                                           transaction:transaction];
        if (wasRemoved) {
            [removedBodyAttachmentIds addObject:attachmentId];
        }
    }

    NSString *_Nullable linkPreviewAttachmentId = self.linkPreview.imageAttachmentId;
    if (linkPreviewAttachmentId != nil) {
        [unknownAttachmentIds removeObject:linkPreviewAttachmentId];
        if (shouldRemoveLinkPreview) {
            OWSLogVerbose(@"Removing link preview attachment.");
            [self removeAttachmentWithId:linkPreviewAttachmentId transaction:transaction];
        }
    }

    NSString *_Nullable contactShareAttachmentId = self.contactShare.avatarAttachmentId;
    if (contactShareAttachmentId != nil) {
        [unknownAttachmentIds removeObject:contactShareAttachmentId];
        if (shouldRemoveContactShare) {
            OWSLogVerbose(@"Removing contact share attachment.");
            [self removeAttachmentWithId:contactShareAttachmentId transaction:transaction];
        }
    }

    if (self.quotedMessage.thumbnailAttachmentId) {
        [unknownAttachmentIds removeObject:self.quotedMessage.thumbnailAttachmentId];
    }
    if (shouldRemoveQuotedReply && self.quotedMessage.thumbnailAttachmentId) {
        OWSLogVerbose(@"Removing quoted reply attachment.");
        [self removeAttachmentWithId:self.quotedMessage.thumbnailAttachmentId transaction:transaction];
    }

    // Err on the side of cleaning up unknown attachments.
    OWSAssertDebug(unknownAttachmentIds.count == 0);
    for (NSString *attachmentId in unknownAttachmentIds) {
        OWSLogWarn(@"Removing unknown attachment.");
        [self removeAttachmentWithId:attachmentId transaction:transaction];
    }

    [self anyUpdateMessageWithTransaction:transaction
                                    block:^(TSMessage *message) {
                                        // Remove renderable content.
                                        if (shouldRemoveBodyText) {
                                            message.body = nil;
                                            message.bodyRanges = nil;
                                        }
                                        if (shouldRemoveContactShare) {
                                            message.contactShare = nil;
                                        }
                                        if (shouldRemoveQuotedReply) {
                                            message.quotedMessage = nil;
                                        }
                                        if (shouldRemoveLinkPreview) {
                                            message.linkPreview = nil;
                                        }
                                        if (shouldRemoveBodyAttachments) {
                                            message.messageSticker = nil;
                                        }
                                        NSMutableArray<NSString *> *newAttachmentIds = [NSMutableArray new];
                                        if (message.attachmentIds != nil) {
                                            [newAttachmentIds addObjectsFromArray:message.attachmentIds];
                                        }
                                        for (NSString *attachmentId in removedBodyAttachmentIds) {
                                            [newAttachmentIds removeObject:attachmentId];
                                        }
                                        message.attachmentIds = [newAttachmentIds copy];
                                    }];
}

- (BOOL)removeAttachmentWithId:(NSString *)attachmentId transaction:(SDSAnyWriteTransaction *)transaction
{
    return [self removeAttachmentWithId:attachmentId
                            filterBlock:^(TSAttachment *attachment) { return YES; }
                            transaction:transaction];
}

- (BOOL)removeAttachmentWithId:(NSString *)attachmentId
                   filterBlock:(BOOL (^)(TSAttachment *attachment))filterBlock
                   transaction:(SDSAnyWriteTransaction *)transaction
{
    if (attachmentId.length < 1) {
        OWSFailDebug(@"Invalid attachmentId.");
        return NO;
    }
    // We need to fetch each attachment, since [TSAttachment removeWithTransaction:] does important work.
    TSAttachment *_Nullable attachment = [TSAttachment anyFetchWithUniqueId:attachmentId transaction:transaction];
    if (!attachment) {
        if (self.shouldBeSaved) {
            OWSFailDebugUnlessRunningTests(@"couldn't load interaction's attachment for deletion.");
        } else {
            OWSLogWarn(@"couldn't load interaction's attachment for deletion.");
        }
        return NO;
    }
    if (!filterBlock(attachment)) {
        return NO;
    }
    [attachment anyRemoveWithTransaction:transaction];
    return YES;
}

#pragma mark - Partial Delete

- (void)removeBodyTextWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [self removeRenderableContentWithTransaction:transaction
                            shouldRemoveBodyText:YES
                     shouldRemoveBodyAttachments:NO
                         shouldRemoveLinkPreview:YES
                         shouldRemoveQuotedReply:NO
                        shouldRemoveContactShare:NO];
}

- (void)removeMediaAndShareAttachmentsWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [self removeRenderableContentWithTransaction:transaction
                            shouldRemoveBodyText:NO
                     shouldRemoveBodyAttachments:YES
                         shouldRemoveLinkPreview:NO
                         shouldRemoveQuotedReply:NO
                        shouldRemoveContactShare:YES];
}

@end

NS_ASSUME_NONNULL_END
