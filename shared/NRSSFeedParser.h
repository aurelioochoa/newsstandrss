#import <Foundation/Foundation.h>

@interface NRSSItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *link;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *html;    // full content when the feed has it, else the description
@property (nonatomic, copy) NSString *summary; // plain text, shortened
@property (nonatomic, copy) NSString *imageURL;
@property (nonatomic, strong) NSDate *date;
@end

@interface NRSSFeed : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *siteURL;
@property (nonatomic, copy) NSString *imageURL;
@property (nonatomic, strong) NSArray *items; // NRSSItem, newest first
@end

@interface NRSSFeedParser : NSObject
// Returns nil when the data is not an RSS 2.0, RSS 1.0 (RDF) or Atom document.
+ (NRSSFeed *)parseData:(NSData *)data baseURL:(NSURL *)baseURL;
// First <link rel="alternate" type="application/rss+xml|atom+xml"> in an HTML page.
+ (NSURL *)discoverFeedURLInHTML:(NSData *)data baseURL:(NSURL *)baseURL;
+ (NSString *)plainTextFromHTML:(NSString *)html;
@end
