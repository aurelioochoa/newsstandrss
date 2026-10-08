#import "NRSSShared.h"
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

NSString *NRSSLocalized(NSString *english, NSString *spanish) {
    static BOOL spanishFirst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *languages = [NSLocale preferredLanguages];
        spanishFirst = languages.count && [[languages objectAtIndex:0] hasPrefix:@"es"];
    });
    return spanishFirst ? spanish : english;
}

BOOL NRSSIsValidFeedID(NSString *feedID) {
    if (![feedID isKindOfClass:[NSString class]] || feedID.length != 12)
        return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [feedID rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

NSString *NRSSNewFeedID(void) {
    NSString *feedID;
    do {
        feedID = [NSString stringWithFormat:@"%06x%06x", arc4random_uniform(0x1000000), arc4random_uniform(0x1000000)];
    } while (NRSSFeedWithID(feedID) || [[NSFileManager defaultManager] fileExistsAtPath:NRSSAppPathForFeedID(feedID)]);
    return feedID;
}

NSString *NRSSBundleIDForFeedID(NSString *feedID) {
    return [NRSSBundlePrefix stringByAppendingString:feedID];
}

NSString *NRSSFeedIDForBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:[NSString class]] || ![bundleID hasPrefix:NRSSBundlePrefix])
        return nil;
    NSString *feedID = [bundleID substringFromIndex:NRSSBundlePrefix.length];
    return NRSSIsValidFeedID(feedID) ? feedID : nil;
}

NSString *NRSSAppPathForFeedID(NSString *feedID) {
    return [NSString stringWithFormat:@"/Applications/NewsstandRSS-%@.app", feedID];
}

NSDictionary *NRSSInstalledFeeds(void) {
    NSMutableDictionary *installed = [NSMutableDictionary dictionary];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/Applications" error:NULL]) {
        if (![name hasPrefix:@"NewsstandRSS-"] || ![name hasSuffix:@".app"] || name.length != 13 + 12 + 4)
            continue;
        NSString *feedID = [name substringWithRange:NSMakeRange(13, 12)];
        if (!NRSSIsValidFeedID(feedID))
            continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[NRSSAppPathForFeedID(feedID) stringByAppendingPathComponent:@"Info.plist"]];
        NSString *displayName = [info objectForKey:@"CFBundleDisplayName"];
        [installed setObject:[displayName isKindOfClass:[NSString class]] ? displayName : @"" forKey:feedID];
    }
    return installed;
}

NSArray *NRSSLoadFeeds(void) {
    NSArray *feeds = [[NSDictionary dictionaryWithContentsOfFile:NRSSFeedsPath] objectForKey:@"feeds"];
    NSMutableArray *valid = [NSMutableArray array];
    for (NSDictionary *feed in [feeds isKindOfClass:[NSArray class]] ? feeds : nil)
        if ([feed isKindOfClass:[NSDictionary class]] && NRSSIsValidFeedID([feed objectForKey:@"id"])
            && [[feed objectForKey:@"url"] isKindOfClass:[NSString class]])
            [valid addObject:feed];
    return valid;
}

NSDictionary *NRSSFeedWithID(NSString *feedID) {
    for (NSDictionary *feed in NRSSLoadFeeds())
        if ([[feed objectForKey:@"id"] isEqualToString:feedID])
            return feed;
    return nil;
}

NSDictionary *NRSSFeedWithURL(NSString *url) {
    if (!url)
        return nil;
    for (NSDictionary *feed in NRSSLoadFeeds())
        for (NSString *key in @[@"url", @"source"]) {
            NSString *value = [feed objectForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value caseInsensitiveCompare:url] == NSOrderedSame)
                return feed;
        }
    return nil;
}

static BOOL NRSSWriteFeeds(NSArray *feeds) {
    NRSSEnsureDataDirectories();
    return [@{@"version": @1, @"feeds": feeds} writeToFile:NRSSFeedsPath atomically:YES];
}

BOOL NRSSSaveFeed(NSDictionary *feed) {
    NSMutableArray *feeds = [NRSSLoadFeeds() mutableCopy];
    NSUInteger index = [feeds indexOfObjectPassingTest:^BOOL(NSDictionary *existing, NSUInteger i, BOOL *stop) {
        return [[existing objectForKey:@"id"] isEqualToString:[feed objectForKey:@"id"]];
    }];
    if (index == NSNotFound)
        [feeds addObject:feed];
    else
        [feeds replaceObjectAtIndex:index withObject:feed];
    return NRSSWriteFeeds(feeds);
}

BOOL NRSSRemoveFeedRecord(NSString *feedID) {
    if (!NRSSIsValidFeedID(feedID))
        return NO;
    NSMutableArray *feeds = [NRSSLoadFeeds() mutableCopy];
    [feeds filterUsingPredicate:[NSPredicate predicateWithFormat:@"id != %@", feedID]];
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *path in @[NRSSCoverPathForFeedID(feedID, NO), NRSSCoverPathForFeedID(feedID, YES),
                             NRSSCachePathForFeedID(feedID, @"xml"), NRSSCachePathForFeedID(feedID, @"read.plist"),
                             NRSSCachePathForFeedID(feedID, @"photo")])
        [files removeItemAtPath:path error:NULL];
    return NRSSWriteFeeds(feeds);
}

NSString *NRSSCoverPathForFeedID(NSString *feedID, BOOL retina) {
    return [NRSSCoversDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:retina ? @"%@@2x.png" : @"%@.png", feedID]];
}

NSString *NRSSCachePathForFeedID(NSString *feedID, NSString *suffix) {
    return [NRSSCacheDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", feedID, suffix]];
}

void NRSSEnsureDataDirectories(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:NRSSCoversDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    [files createDirectoryAtPath:NRSSCacheDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
}

void NRSSPostCoversChanged(void) {
    notify_post(NRSSCoversChangedNotification);
}

void NRSSPostFeedsChanged(void) {
    notify_post(NRSSFeedsChangedNotification);
}

id NRSSPreference(NSString *key, id fallback) {
    id value = [[NSDictionary dictionaryWithContentsOfFile:NRSSPreferencesPath] objectForKey:key];
    return value ?: fallback;
}

BOOL NRSSBoolPreference(NSString *key, BOOL fallback) {
    id value = NRSSPreference(key, nil);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

NSInteger NRSSIntegerPreference(NSString *key, NSInteger fallback) {
    id value = NRSSPreference(key, nil);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

NSURL *NRSSURLFromUserInput(NSString *input) {
    NSString *text = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text.lowercaseString hasPrefix:@"feed://"])
        text = [@"http://" stringByAppendingString:[text substringFromIndex:7]];
    if ([text rangeOfString:@"://"].location == NSNotFound)
        text = [@"http://" stringByAppendingString:text];
    NSURL *url = [NSURL URLWithString:text];
    NSString *scheme = url.scheme.lowercaseString;
    return url.host.length && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ? url : nil;
}

int NRSSRunHelper(NSArray *arguments) {
    NSUInteger count = arguments.count;
    char **argv = calloc(count + 2, sizeof(char *));
    argv[0] = (char *)[NRSSHelperPath fileSystemRepresentation];
    for (NSUInteger i = 0; i < count; i++)
        argv[i + 1] = (char *)[[arguments objectAtIndex:i] UTF8String];
    pid_t pid;
    int status = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    free(argv);
    if (status != 0)
        return -1;
    while (waitpid(pid, &status, 0) == -1)
        if (errno != EINTR)
            return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}
