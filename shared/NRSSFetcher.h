#import <Foundation/Foundation.h>

typedef void (^NRSSFetchCompletion)(NSData *data, NSURL *finalURL, NSError *error);

// HTTP(S) download that also trusts the modern root certificates shipped in NRSSRootsDirectory
// (iOS 6's own store predates Let's Encrypt and several current CAs). Completion runs on the main queue.
@interface NRSSFetcher : NSObject
+ (void)fetchURL:(NSURL *)url completion:(NRSSFetchCompletion)completion;
@end
