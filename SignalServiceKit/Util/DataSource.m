//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "DataSource.h"
#import "OWSError.h"
#import "OWSFileSystem.h"
#import <SignalServiceKit/NSString+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark -

@interface DataSourceValue ()

@property (nonatomic) NSData *data;
@property (nonatomic) NSString *fileExtension;
@property (atomic) BOOL isConsumed;

// These properties is lazily-populated.
@property (nonatomic, nullable) NSURL *cachedFileUrl;
@property (nonatomic, nullable) ImageMetadata *cachedImageMetadata;

@end

#pragma mark -

@implementation DataSourceValue

- (void)dealloc
{
    NSURL *_Nullable fileUrl = self.cachedFileUrl;
    if (fileUrl != nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            ^{ [OWSFileSystem deleteFileIfExists:fileUrl.path]; });
    }
}

- (instancetype)initWithData:(NSData *)data fileExtension:(NSString *)fileExtension
{
    self = [super init];
    if (!self) {
        return self;
    }
    _data = data;
    _fileExtension = fileExtension;
    _isConsumed = NO;

    // Ensure that value is backed by file on disk.
    __weak DataSourceValue *weakValue = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ [weakValue dataUrl]; });

    return self;
}

+ (_Nullable id<DataSource>)dataSourceWithData:(NSData *)data fileExtension:(NSString *)fileExtension
{
    OWSAssertDebug(data);

    if (!data) {
        OWSFailDebug(@"data was unexpectedly nil");
        return nil;
    }

    return [[self alloc] initWithData:data fileExtension:fileExtension];
}

+ (_Nullable id<DataSource>)dataSourceWithData:(NSData *)data utiType:(NSString *)utiType
{
    NSString *fileExtension = [MimeTypeUtil fileExtensionForUtiType:utiType];
    return [[self alloc] initWithData:data fileExtension:fileExtension];
}

+ (_Nullable id<DataSource>)dataSourceWithData:(NSData *)data mimeType:(NSString *)mimeType
{
    NSString *fileExtension = [MimeTypeUtil fileExtensionForMimeType:mimeType];
    if (fileExtension) {
        return [[self alloc] initWithData:data fileExtension:fileExtension];
    } else {
        return nil;
    }
}

+ (id<DataSource>)dataSourceWithOversizeText:(NSString *)text
{
    NSData *data = [text.filterStringForDisplay dataUsingEncoding:NSUTF8StringEncoding];
    return [[self alloc] initWithData:data fileExtension:MimeTypeUtil.oversizeTextAttachmentFileExtension];
}

+ (id<DataSource>)emptyDataSource
{
    return [[self alloc] initWithData:[NSData new] fileExtension:@"bin"];
}

#pragma mark - DataSource

@synthesize sourceFilename = _sourceFilename;

- (void)setSourceFilename:(nullable NSString *)sourceFilename
{
    OWSAssertDebug(!self.isConsumed);
    _sourceFilename = sourceFilename.filterFilename;
}

- (nullable NSURL *)dataUrl
{
    OWSAssertDebug(self.data);
    OWSAssertDebug(!self.isConsumed);

    @synchronized(self) {
        if (!self.cachedFileUrl) {
            NSURL *fileUrl = [OWSFileSystem temporaryFileUrlWithFileExtension:self.fileExtension
                                                 isAvailableWhileDeviceLocked:YES];
            if ([self writeToUrl:fileUrl error:nil]) {
                self.cachedFileUrl = fileUrl;
            } else {
                OWSFailDebug(@"Could not write data to disk.");
            }
        }

        return self.cachedFileUrl;
    }
}

- (NSUInteger)dataLength
{
    OWSAssertDebug(self.data);
    OWSAssertDebug(!self.isConsumed);
    return self.data.length;
}

- (BOOL)writeToUrl:(NSURL *)dstUrl error:(NSError **)outError
{
    OWSAssertDebug(self.data);
    OWSAssertDebug(!self.isConsumed);
    NSError *error = nil;
    if (![self.data writeToURL:dstUrl options:NSDataWritingAtomic error:&error]) {
        OWSFailDebug(@"Could not write data to disk: %@", error);
        if (outError != NULL) {
            *outError = error;
        }
        return NO;
    }
    return YES;
}

- (BOOL)moveToUrlAndConsume:(NSURL *)dstUrl error:(NSError **)outError
{
    OWSAssertDebug(!self.isConsumed);

    @synchronized(self) {
        OWSAssertDebug(!NSThread.isMainThread);
        // This method is meant to be fast. If _cachedFileUrl is nil,
        // we'll still lazily generate it and this method will work,
        // but it will be slower than expected.
        OWSAssertDebug(self->_cachedFileUrl != nil);

        NSURL *_Nullable srcUrl = self.dataUrl;
        if (srcUrl == nil) {
            if (outError != NULL) {
                *outError = OWSErrorMakeAssertionError(@"Missing data URL.");
            }
            return NO;
        }
        self->_cachedFileUrl = nil;
        self.isConsumed = YES;
        NSError *error = nil;
        if (![OWSFileSystem moveFileFrom:srcUrl to:dstUrl error:&error]) {
            OWSFailDebug(@"Could not write data with error: %@", error);
            if (outError != NULL) {
                *outError = error;
            }
            return NO;
        }
        return YES;
    }
}

- (BOOL)consumeAndDeleteWithError:(NSError **)outError
{
    OWSAssertDebug(!self.isConsumed);

    self.isConsumed = YES;

    if (!self.cachedFileUrl) {
        // Nothing to delete.
        return YES;
    }

    return [OWSFileSystem deleteFileIfExistsWithUrl:self.cachedFileUrl error:outError];
}

- (BOOL)isValidImage
{
    OWSAssertDebug(!self.isConsumed);
    return [self.data ows_isValidImage];
}

- (BOOL)isValidVideo
{
    OWSAssertDebug(!self.isConsumed);
    if (![MimeTypeUtil isSupportedVideoFile:self.dataUrl.path]) {
        return NO;
    }
    OWSFailDebug(@"Are we calling this anywhere? It seems quite inefficient.");
    return [OWSMediaUtils isValidVideoWithPath:self.dataUrl.path];
}

- (nullable NSString *)mimeType
{
    OWSAssertDebug(!self.isConsumed);
    if (self.fileExtension == nil) {
        OWSFailDebug(@"failure: fileExtension was unexpectedly nil");
        return nil;
    }

    return [MimeTypeUtil mimeTypeForFileExtension:self.fileExtension];
}

- (BOOL)hasStickerLikeProperties
{
    OWSAssertDebug(!self.isConsumed);
    ImageMetadata *metadata = [self imageMetadata];
    return [NSData ows_hasStickerLikePropertiesWithMetadata:metadata];
}

- (ImageMetadata *)imageMetadata
{
    OWSAssertDebug(!self.isConsumed);

    @synchronized(self) {
        if (self.cachedImageMetadata != nil) {
            return self.cachedImageMetadata;
        }
        ImageMetadata *imageMetadata = [self.data imageMetadataWithPath:nil mimeType:self.mimeType ignoreFileSize:YES];
        self.cachedImageMetadata = imageMetadata;
        return imageMetadata;
    }
}

@end

#pragma mark -

@interface DataSourcePath ()

@property (nonatomic) NSURL *fileUrl;
@property (nonatomic, readonly) BOOL shouldDeleteOnDeallocation;
@property (atomic) BOOL isConsumed;

// These properties is lazily-populated.
@property (nonatomic) NSData *cachedData;
@property (nonatomic, nullable) ImageMetadata *cachedImageMetadata;

@end

#pragma mark -

@implementation DataSourcePath

- (void)dealloc
{
    if (self.shouldDeleteOnDeallocation && !self.isConsumed) {
        NSURL *fileUrl = self.fileUrl;
        if (!fileUrl) {
            OWSFailDebug(@"fileUrl was unexpectedly nil");
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error;
            BOOL success = [[NSFileManager defaultManager] removeItemAtURL:fileUrl error:&error];
            if (!success || error) {
                OWSCFailDebug(@"DataSourcePath could not delete file: %@, %@", fileUrl, error);
            }
        });
    }
}

- (nullable instancetype)initWithFileUrl:(NSURL *)fileUrl
              shouldDeleteOnDeallocation:(BOOL)shouldDeleteOnDeallocation
                                   error:(NSError **)error
{
    if (!fileUrl || ![fileUrl isFileURL]) {
        NSString *errorMsg = [NSString stringWithFormat:@"unexpected fileUrl: %@", fileUrl];
        *error = OWSErrorMakeAssertionError(errorMsg);
        return nil;
    }

    self = [super init];
    if (!self) {
        return self;
    }

    _fileUrl = fileUrl;
    _shouldDeleteOnDeallocation = shouldDeleteOnDeallocation;
    _isConsumed = NO;

    return self;
}

+ (_Nullable id<DataSource>)dataSourceWithURL:(NSURL *)fileUrl
                   shouldDeleteOnDeallocation:(BOOL)shouldDeleteOnDeallocation
                                        error:(NSError **)error
{
    return [[self alloc] initWithFileUrl:fileUrl shouldDeleteOnDeallocation:shouldDeleteOnDeallocation error:error];
}

+ (_Nullable id<DataSource>)dataSourceWithFilePath:(NSString *)filePath
                        shouldDeleteOnDeallocation:(BOOL)shouldDeleteOnDeallocation
                                             error:(NSError **)error
{
    OWSAssertDebug(filePath);

    if (!filePath) {
        NSString *errorMsg = [NSString stringWithFormat:@"unexpected filePath: %@", filePath];
        *error = OWSErrorMakeAssertionError(errorMsg);
        return nil;
    }

    NSURL *fileUrl = [NSURL fileURLWithPath:filePath];
    return [[self alloc] initWithFileUrl:fileUrl shouldDeleteOnDeallocation:shouldDeleteOnDeallocation error:error];
}

+ (_Nullable id<DataSource>)dataSourceWritingTempFileData:(NSData *)data
                                            fileExtension:(NSString *)fileExtension
                                                    error:(NSError **)error
{
    NSURL *fileUrl = [OWSFileSystem temporaryFileUrlWithFileExtension:fileExtension isAvailableWhileDeviceLocked:YES];
    [data writeToURL:fileUrl options:NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:error];
    if (*error != nil) {
        return nil;
    }
    return [[self alloc] initWithFileUrl:fileUrl shouldDeleteOnDeallocation:YES error:error];
}

+ (_Nullable id<DataSource>)dataSourceWritingSyncMessageData:(NSData *)data error:(NSError **)error
{
    return [self dataSourceWritingTempFileData:data fileExtension:MimeTypeUtil.syncMessageFileExtension error:error];
}

#pragma mark - DataSource

@synthesize sourceFilename = _sourceFilename;

- (void)setSourceFilename:(nullable NSString *)sourceFilename
{
    OWSAssertDebug(!self.isConsumed);
    _sourceFilename = sourceFilename.filterFilename;
}

- (NSData *)data
{
    OWSAssertDebug(!self.isConsumed);
    OWSAssertDebug(self.fileUrl);

    @synchronized(self) {
        if (!self.cachedData) {
            self.cachedData = [NSData dataWithContentsOfFile:self.fileUrl.path];
        }
        if (!self.cachedData) {
            OWSFailDebug(@"Could not read data from disk.");
            self.cachedData = [NSData new];
        }
        return self.cachedData;
    }
}

- (NSUInteger)dataLength
{
    OWSAssertDebug(!self.isConsumed);
    OWSAssertDebug(self.fileUrl);

    NSNumber *fileSizeValue;
    NSError *error;
    [self.fileUrl getResourceValue:&fileSizeValue forKey:NSURLFileSizeKey error:&error];
    if (error != nil) {
        OWSFailDebug(@"Could not read data length from disk with error: %@", error);
        return 0;
    }

    return fileSizeValue.unsignedIntegerValue;
}

- (nullable NSURL *)dataUrl
{
    OWSAssertDebug(!self.isConsumed);
    return self.fileUrl;
}

- (BOOL)isValidImage
{
    OWSAssertDebug(!self.isConsumed);
    return [NSData ows_isValidImageAtUrl:self.fileUrl mimeType:self.mimeType];
}

- (BOOL)isValidVideo
{
    OWSAssertDebug(!self.isConsumed);
    if (self.mimeType != nil) {
        if (![MimeTypeUtil isSupportedVideoMimeType:self.mimeType]) {
            return NO;
        }
    } else if (![MimeTypeUtil isSupportedVideoFile:self.dataUrl.path]) {
        return NO;
    }
    return [OWSMediaUtils isValidVideoWithPath:self.dataUrl.path];
}

- (BOOL)hasStickerLikeProperties
{
    OWSAssertDebug(!self.isConsumed);
    ImageMetadata *metadata = [self imageMetadata];
    return [NSData ows_hasStickerLikePropertiesWithMetadata:metadata];
}

- (ImageMetadata *)imageMetadata
{
    OWSAssertDebug(!self.isConsumed);

    @synchronized(self) {
        if (self.cachedImageMetadata != nil) {
            return self.cachedImageMetadata;
        }
        ImageMetadata *imageMetadata = [NSData imageMetadataWithPath:self.dataUrl.path
                                                            mimeType:self.mimeType
                                                      ignoreFileSize:YES];
        self.cachedImageMetadata = imageMetadata;
        return imageMetadata;
    }
}

- (BOOL)writeToUrl:(NSURL *)dstUrl error:(NSError **)outError
{
    OWSAssertDebug(!self.isConsumed);
    OWSAssertDebug(self.fileUrl);
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:self.fileUrl toURL:dstUrl error:&error]) {
        OWSFailDebug(@"Could not write data with error: %@", error);
        if (outError != NULL) {
            *outError = error;
        }
        return NO;
    }
    return YES;
}

- (BOOL)moveToUrlAndConsume:(NSURL *)dstUrl error:(NSError **)outError
{
    OWSAssertDebug(!self.isConsumed);
    OWSAssertDebug(self.fileUrl);

    self.isConsumed = YES;

    NSError *error = nil;
    BOOL success = NO;
    if ([[NSFileManager defaultManager] isWritableFileAtPath:self.fileUrl.path]) {
        success = [OWSFileSystem moveFileFrom:self.fileUrl to:dstUrl error:&error];
    } else {
        OWSLogError(@"File was not writeable. Copying instead of moving.");
        success = [NSFileManager.defaultManager copyItemAtURL:self.fileUrl toURL:dstUrl error:&error];
    }
    if (!success) {
        if (outError != NULL) {
            *outError = error;
        }
        OWSFailDebug(@"Could not write data with error: %@", error);
    }
    return success;
}

- (BOOL)consumeAndDeleteWithError:(NSError **)outError
{
    OWSAssertDebug(!self.isConsumed);

    self.isConsumed = YES;

    return [OWSFileSystem deleteFileIfExistsWithUrl:self.fileUrl error:outError];
}

- (nullable NSString *)mimeType
{
    OWSAssertDebug(!self.isConsumed);
    NSString *_Nullable fileExtension = self.fileUrl.pathExtension;
    if (fileExtension.length == 0) {
        return nil;
    }
    return [MimeTypeUtil mimeTypeForFileExtension:fileExtension];
}

@end

NS_ASSUME_NONNULL_END
