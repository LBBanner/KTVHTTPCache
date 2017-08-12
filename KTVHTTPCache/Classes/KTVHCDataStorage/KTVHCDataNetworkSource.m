//
//  KTVHCDataNetworkSource.m
//  KTVHTTPCache
//
//  Created by Single on 2017/8/11.
//  Copyright © 2017年 Single. All rights reserved.
//

#import "KTVHCDataNetworkSource.h"
#import "KTVHCDataDownload.h"
#import "KTVHCPathTools.h"
#import "KTVHCDataUnitPool.h"

@interface KTVHCDataNetworkSource () <KTVHCDataDownloadDelegate>


#pragma mark - Protocol

@property (nonatomic, copy) NSString * filePath;

@property (nonatomic, assign) NSInteger offset;
@property (nonatomic, assign) NSInteger size;

@property (nonatomic, assign) BOOL didFinishRead;


#pragma mark - Setter

@property (nonatomic, copy) NSString * URLString;

@property (nonatomic, strong) NSDictionary * requestHeaderFields;
@property (nonatomic, strong) NSDictionary * responseHeaderFields;

@property (nonatomic, strong) NSError * error;
@property (nonatomic, assign) BOOL errorCanceled;

@property (nonatomic, assign) BOOL didFinishPrepare;
@property (nonatomic, assign) BOOL didFinishDownload;

@property (nonatomic, assign) NSInteger totalContentLength;


#pragma mark - Download

@property (nonatomic, strong) KTVHCDataUnitItem * unitItem;

@property (nonatomic, strong) NSFileHandle * readingHandle;
@property (nonatomic, strong) NSFileHandle * writingHandle;

@property (nonatomic, strong) NSCondition * condition;
@property (nonatomic, assign) NSInteger downloadSize;
@property (nonatomic, assign) NSInteger downloadReadOffset;

@end

@implementation KTVHCDataNetworkSource

+ (instancetype)sourceWithURLString:(NSString *)URLString headerFields:(NSDictionary *)headerFields offset:(NSInteger)offset size:(NSInteger)size
{
    return [[self alloc] initWithURLString:URLString
                              headerFields:headerFields
                                    offset:offset
                                      size:size];
}

- (instancetype)initWithURLString:(NSString *)URLString
                     headerFields:(NSDictionary *)headerFields
                           offset:(NSInteger)offset
                             size:(NSInteger)size
{
    if (self = [super init])
    {
        self.URLString = URLString;
        self.requestHeaderFields = headerFields;
        
        self.filePath = [KTVHCPathTools pathWithURLString:self.URLString offset:self.offset];
        self.offset = offset;
        self.size = size;
        
        self.condition = [[NSCondition alloc] init];
        self.writingHandle = [NSFileHandle fileHandleForWritingAtPath:self.filePath];
        self.readingHandle = [NSFileHandle fileHandleForReadingAtPath:self.filePath];
    }
    return self;
}

- (void)prepareAndStart
{
    NSURL * URL = [NSURL URLWithString:self.URLString];
    NSMutableURLRequest * request = [NSMutableURLRequest requestWithURL:URL];
    
    if (self.size == KTVHCDataNetworkSourceSizeMaxVaule) {
        [request setValue:[NSString stringWithFormat:@"bytes=%ld-", self.offset] forHTTPHeaderField:@"Range"];
    } else {
        [request setValue:[NSString stringWithFormat:@"bytes=%ld-%ld", self.offset, self.offset + self.size - 1] forHTTPHeaderField:@"Range"];
    }
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    
    [[KTVHCDataDownload download] downloadWithRequest:request delegate:self];
}

- (NSData *)syncReadDataOfLength:(NSInteger)length
{
    [self.condition lock];
    while (!self.didFinishDownload && ((self.downloadSize - self.downloadReadOffset) < length))
    {
        [self.condition wait];
    }
    if (self.didFinishDownload && self.downloadReadOffset >= self.downloadSize)
    {
        [self callbackForFinishRead];
        [self.condition unlock];
        return nil;
    }
    NSData * data = [self.readingHandle readDataOfLength:length];
    self.downloadReadOffset += length;
    if (self.downloadReadOffset >= self.size)
    {
        [self callbackForFinishRead];
    }
    [self.condition unlock];
    return data;
}


#pragma mark - Callback

- (void)callbackForFinishRead
{
    [self.readingHandle closeFile];
    self.readingHandle = nil;
    
    self.didFinishRead = YES;
    if ([self.networkSourceDelegate respondsToSelector:@selector(networkSourceDidFinishRead:)]) {
        [self.networkSourceDelegate networkSourceDidFinishRead:self];
    }
}


#pragma mark - KTVHCDataDownloadDelegate

- (void)download:(KTVHCDataDownload *)download didCompleteWithError:(NSError *)error
{
    [self.condition lock];
    if (error)
    {
        self.error = error;
        if (self.error.code == NSURLErrorCancelled && !self.errorCanceled) {
            if ([self.networkSourceDelegate respondsToSelector:@selector(networkSourceDidCanceled:)]) {
                [self.networkSourceDelegate networkSourceDidCanceled:self];
            }
        } else {
            if ([self.networkSourceDelegate respondsToSelector:@selector(networkSource:didFailure:)]) {
                [self.networkSourceDelegate networkSource:self didFailure:error];
            }
        }
    }
    
    [self.writingHandle closeFile];
    self.writingHandle = nil;
    
    if (self.downloadSize >= self.size)
    {
        self.didFinishDownload = YES;
        if ([self.networkSourceDelegate respondsToSelector:@selector(networkSourceDidFinishDownload:)]) {
            [self.networkSourceDelegate networkSourceDidFinishDownload:self];
        }
    }
    [self.condition signal];
    [self.condition unlock];
}

- (BOOL)download:(KTVHCDataDownload *)download didReceiveResponse:(NSHTTPURLResponse *)response
{
    [[KTVHCDataUnitPool unitPool] unit:self.URLString updateResponseHeaderFields:response.allHeaderFields];
    
    NSString * contentRange = [response.allHeaderFields objectForKey:@"Content-Range"];
    NSRange range = [contentRange rangeOfString:@"/"];
    if (contentRange.length > 0 && range.location != NSNotFound)
    {
        self.unitItem = [KTVHCDataUnitItem unitItemWithOffset:self.offset filePath:self.filePath];
        [[KTVHCDataUnitPool unitPool] unit:self.URLString insertUnitItem:self.unitItem];
        
        self.totalContentLength = [contentRange substringFromIndex:range.location + range.length].integerValue;
        self.responseHeaderFields = response.allHeaderFields;
        self.didFinishPrepare = YES;
        if ([self.networkSourceDelegate respondsToSelector:@selector(networkSourceDidFinishPrepare:)]) {
            [self.networkSourceDelegate networkSourceDidFinishPrepare:self];
        }
        return YES;
    }
    self.errorCanceled = YES;
    return NO;
}

- (void)download:(KTVHCDataDownload *)download didReceiveData:(NSData *)data
{
    [self.condition lock];
    [self.writingHandle writeData:data];
    self.downloadSize += data.length;
    self.unitItem.size = self.downloadSize;
    [self.condition signal];
    [self.condition unlock];
}


@end