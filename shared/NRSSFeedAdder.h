#import <Foundation/Foundation.h>

@class NRSSFeed;

// feedID is nil on failure, with a message for the user.
typedef void (^NRSSAddCompletion)(NSString *feedID, NSString *errorMessage);

// Resolves what the user typed to a feed (following the website's feed link when needed), saves its record,
// cached document and cover. The magazine bundle itself is created by SpringBoard's sync. Main queue only.
@interface NRSSFeedAdder : NSObject
+ (void)addFeedFromString:(NSString *)input completion:(NRSSAddCompletion)completion;
+ (void)addParsedFeed:(NRSSFeed *)feed data:(NSData *)data url:(NSURL *)url completion:(NRSSAddCompletion)completion;
// Adds several feeds one after another, skipping ones already on the shelf. Each entry is an address or a
// catalog entry {url, title}, whose title is used instead of the feed's own. Main queue only.
+ (void)addFeedsFromStrings:(NSArray *)inputs progress:(void (^)(NSUInteger done, NSUInteger total))progress
                 completion:(void (^)(NSUInteger added, NSArray *failedInputs))completion;
// Name stored for a feed: trimmed, at most 40 characters.
+ (NSString *)displayNameFromString:(NSString *)name fallback:(NSString *)fallback;
@end
