//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/BaseModel.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_CLOSED_ENUM(NSUInteger, OWSVerificationState) {
    /// The user hasn't taken an explicit action on this identity key. It's
    /// trusted after `defaultUntrustedInterval`.
    OWSVerificationStateDefault = 0,

    /// The user has explicitly verified this identity key. It's trusted.
    OWSVerificationStateVerified = 1,

    /// The user has explicitly verified a previous identity key. This one will
    /// never be trusted based on elapsed time. The user must mark it as
    /// "verified" or "default acknowledged" to trust it.
    OWSVerificationStateNoLongerVerified = 2,

    /// The user hasn't verified this identity key, but they've explicitly
    /// chosen not to, so we don't need to check `defaultUntrustedInterval`.
    OWSVerificationStateDefaultAcknowledged = 3,
};

@class DBWriteTransaction;
@class SSKProtoVerified;
@class SignalServiceAddress;

NSString *OWSVerificationStateToString(OWSVerificationState verificationState);
SSKProtoVerified *_Nullable BuildVerifiedProtoWithAddress(SignalServiceAddress *destinationAddress,
    NSData *identityKey,
    OWSVerificationState verificationState,
    NSUInteger paddingBytesLength);

@interface OWSRecipientIdentity : BaseModel

@property (nonatomic, readonly) NSString *accountId;
@property (nonatomic, readonly) NSData *identityKey;
@property (nonatomic, readonly) NSDate *createdAt;
@property (nonatomic, readonly) BOOL isFirstKnownKey;

#pragma mark - Verification State

@property (atomic, readonly) OWSVerificationState verificationState;

- (void)updateWithVerificationState:(OWSVerificationState)verificationState
                        transaction:(DBWriteTransaction *)transaction;

@property (atomic, readonly) BOOL wasIdentityVerified;

#pragma mark - Initializers

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithUniqueId:(NSString *)uniqueId NS_UNAVAILABLE;
- (instancetype)initWithGrdbId:(int64_t)grdbId uniqueId:(NSString *)uniqueId NS_UNAVAILABLE;

- (instancetype)initWithRecipientUniqueId:(NSString *)accountId
                              identityKey:(NSData *)identityKey
                          isFirstKnownKey:(BOOL)isFirstKnownKey
                                createdAt:(NSDate *)createdAt
                        verificationState:(OWSVerificationState)verificationState NS_DESIGNATED_INITIALIZER;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
                       accountId:(NSString *)accountId
                       createdAt:(NSDate *)createdAt
                     identityKey:(NSData *)identityKey
                 isFirstKnownKey:(BOOL)isFirstKnownKey
               verificationState:(OWSVerificationState)verificationState
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:accountId:createdAt:identityKey:isFirstKnownKey:verificationState:));

// clang-format on

// --- CODE GENERATION MARKER

#pragma mark - debug

+ (void)printAllIdentities;

@end

NS_ASSUME_NONNULL_END
