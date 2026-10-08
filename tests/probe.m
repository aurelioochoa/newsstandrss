// Device probe: fetch + parse real feeds with the shared code. (UIFont needs a UIApplication, so covers are
// exercised in SpringBoard instead.)
// Usage: nrss-probe <url>...   (run on the phone; not part of the package)
#import <UIKit/UIKit.h>
#import "NRSSCover.h"
#import "NRSSFeedParser.h"
#import "NRSSFetcher.h"

static NSUInteger pending;

static void probe(NSURL *url, BOOL discover) {
    pending++;
    [NRSSFetcher fetchURL:url completion:^(NSData *data, NSURL *finalURL, NSError *error) {
        if (error) {
            printf("FAIL %s: %s (%ld)\n", url.absoluteString.UTF8String, error.localizedDescription.UTF8String, (long)error.code);
        } else {
            NRSSFeed *feed = [NRSSFeedParser parseData:data baseURL:finalURL];
            NSURL *found = feed ? nil : [NRSSFeedParser discoverFeedURLInHTML:data baseURL:finalURL];
            if (feed) {
                NRSSItem *first = feed.items.count ? feed.items[0] : nil;
                printf("OK   %s: \"%s\" items=%lu site=%s image=%s\n     first=\"%s\" date=%s img=%s\n     summary=\"%.90s\"\n",
                       url.absoluteString.UTF8String, feed.title.UTF8String, (unsigned long)feed.items.count,
                       feed.siteURL.UTF8String ?: "-", feed.imageURL.UTF8String ?: "-", first.title.UTF8String ?: "-",
                       first.date.description.UTF8String ?: "-", first.imageURL.UTF8String ?: "-", first.summary.UTF8String ?: "-");
                printf("     items with images=%lu, photo for cover=%s\n",
                       (unsigned long)[[feed.items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"imageURL != nil"]] count],
                       [NRSSCover photoURLForFeed:feed].UTF8String ?: "-");
            } else if (found && discover) {
                printf("DISC %s -> %s\n", url.absoluteString.UTF8String, found.absoluteString.UTF8String);
                probe(found, NO);
            } else {
                printf("NONE %s (%lu bytes)\n", url.absoluteString.UTF8String, (unsigned long)data.length);
            }
        }
        if (--pending == 0)
            exit(0);
    }];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++)
            probe([NSURL URLWithString:[NSString stringWithUTF8String:argv[i]]], YES);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:90]];
        printf("TIMEOUT\n");
    }
    return 1;
}
