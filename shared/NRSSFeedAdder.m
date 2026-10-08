#import "NRSSFeedAdder.h"
#import "NRSSCover.h"
#import "NRSSFeedParser.h"
#import "NRSSFetcher.h"
#import "NRSSShared.h"

@implementation NRSSFeedAdder

+ (NSString *)displayNameFromString:(NSString *)name fallback:(NSString *)fallback {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *separator in @[@" - ", @" | ", @" \u2013 ", @" \u2014 "]) {
        NSArray *parts = [trimmed componentsSeparatedByString:separator];
        if (parts.count == 2 && [[parts objectAtIndex:0] caseInsensitiveCompare:[parts objectAtIndex:1]] == NSOrderedSame)
            trimmed = [parts objectAtIndex:0];
    }
    if (!trimmed.length)
        trimmed = fallback.length ? fallback : @"RSS";
    return trimmed.length > 40 ? [[trimmed substringToIndex:39] stringByAppendingString:@"…"] : trimmed;
}

+ (void)addFeedFromString:(NSString *)input completion:(NRSSAddCompletion)completion {
    [self addFeedFromString:input title:nil completion:completion];
}

+ (void)addFeedFromString:(NSString *)input title:(NSString *)preferredTitle completion:(NRSSAddCompletion)completion {
    NSURL *url = NRSSURLFromUserInput(input);
    if (!url) {
        completion(nil, NRSSLocalized(@"That doesn't look like a web address.", @"Eso no parece una dirección web."));
        return;
    }
    NSDictionary *existing = NRSSFeedWithURL(url.absoluteString);
    if (existing) {
        completion(nil, [self alreadyAddedMessage:existing]);
        return;
    }
    [self loadURL:url source:url.absoluteString title:preferredTitle allowDiscovery:YES completion:completion];
}

+ (void)addFeedsFromStrings:(NSArray *)inputs progress:(void (^)(NSUInteger done, NSUInteger total))progress
                 completion:(void (^)(NSUInteger added, NSArray *failedInputs))completion {
    NSMutableArray *queue = [inputs mutableCopy];
    NSMutableArray *failed = [NSMutableArray array];
    __block NSUInteger added = 0;
    __block void (^next)(void);
    void (^step)(void) = ^{
        if (!queue.count) {
            completion(added, failed);
            next = nil; // break the block's reference to itself
            return;
        }
        id entry = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *input = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"url"] : entry;
        NSString *title = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"title"] : nil;
        if (progress)
            progress(inputs.count - queue.count, inputs.count);
        if (NRSSFeedWithURL(NRSSURLFromUserInput(input).absoluteString)) {
            next();
            return;
        }
        [self addFeedFromString:input title:title completion:^(NSString *feedID, NSString *errorMessage) {
            if (feedID)
                added++;
            else
                [failed addObject:input];
            next();
        }];
    };
    next = step;
    next();
}

+ (NSString *)alreadyAddedMessage:(NSDictionary *)existing {
    return [NSString stringWithFormat:NRSSLocalized(@"\u201c%@\u201d is already on your shelf.", @"\u201c%@\u201d ya está en tu estantería."),
            [existing objectForKey:@"title"]];
}

+ (void)loadURL:(NSURL *)url source:(NSString *)source title:(NSString *)preferredTitle allowDiscovery:(BOOL)allowDiscovery
    completion:(NRSSAddCompletion)completion {
    [NRSSFetcher fetchURL:url completion:^(NSData *data, NSURL *finalURL, NSError *error) {
        if (error) {
            completion(nil, error.localizedDescription);
            return;
        }
        NSURL *base = finalURL ?: url;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NRSSFeed *feed = [NRSSFeedParser parseData:data baseURL:base];
            NSURL *discovered = feed ? nil : [NRSSFeedParser discoverFeedURLInHTML:data baseURL:base];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (feed)
                    [self addParsedFeed:feed data:data url:base source:source title:preferredTitle completion:completion];
                else if (discovered && allowDiscovery)
                    [self loadURL:discovered source:source title:preferredTitle allowDiscovery:NO completion:completion];
                else
                    completion(nil, NRSSLocalized(@"No RSS or Atom feed was found at that address.",
                                                  @"No se encontró un feed RSS o Atom en esa dirección."));
            });
        });
    }];
}

+ (void)addParsedFeed:(NRSSFeed *)feed data:(NSData *)data url:(NSURL *)url completion:(NRSSAddCompletion)completion {
    [self addParsedFeed:feed data:data url:url source:url.absoluteString title:nil completion:completion];
}

+ (void)addParsedFeed:(NRSSFeed *)feed data:(NSData *)data url:(NSURL *)url source:(NSString *)source title:(NSString *)preferredTitle
           completion:(NRSSAddCompletion)completion {
    NSString *address = url.absoluteString;
    NSDictionary *existing = NRSSFeedWithURL(address) ?: NRSSFeedWithURL(source);
    if (existing) {
        completion(nil, [self alreadyAddedMessage:existing]);
        return;
    }
    NSString *feedID = NRSSNewFeedID();
    NSString *title = [self displayNameFromString:preferredTitle.length ? preferredTitle : feed.title fallback:url.host];
    NSDictionary *record = @{@"id": feedID, @"url": address, @"source": source ?: address, @"title": title,
                             @"site": feed.siteURL ?: @"", @"added": [NSDate date]};
    if (!NRSSSaveFeed(record)) {
        completion(nil, NRSSLocalized(@"The feed list could not be saved.", @"No se pudo guardar la lista de fuentes."));
        return;
    }
    [data writeToFile:NRSSCachePathForFeedID(feedID, @"xml") atomically:YES];
    // A plain cover first, so the magazine never appears blank even if the photo download is slow.
    [NRSSCover writeCoverForFeedID:feedID title:title feed:feed photo:nil];
    [NRSSCover updateCoverForFeedID:feedID title:title feed:feed completion:^{
        completion(feedID, nil);
    }];
}

@end
