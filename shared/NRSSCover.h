#import <UIKit/UIKit.h>

@class NRSSFeed;

// Magazine-style Newsstand cover: masthead, lead photo and the latest headlines.
@interface NRSSCover : NSObject
+ (UIImage *)coverForTitle:(NSString *)title feed:(NRSSFeed *)feed photo:(UIImage *)photo scale:(CGFloat)scale;
// Renders both scales into the shared covers directory and tells SpringBoard to redraw.
+ (BOOL)writeCoverForFeedID:(NSString *)feedID title:(NSString *)title feed:(NRSSFeed *)feed photo:(UIImage *)photo;
// Downloads the cover photo (when enabled in Settings), caches it, writes the cover. Completion on the main queue.
+ (void)updateCoverForFeedID:(NSString *)feedID title:(NSString *)title feed:(NRSSFeed *)feed completion:(void (^)(void))completion;
// Redraws from the cached feed and photo without network access.
+ (BOOL)redrawCoverForFeedID:(NSString *)feedID;
// The newest usable article photo, or nil for a plain colored cover.
+ (NSString *)photoURLForFeed:(NRSSFeed *)feed;
@end
