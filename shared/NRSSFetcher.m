#import "NRSSFetcher.h"
#import "NRSSHTTPS.h"
#import "NRSSShared.h"
#import <Security/Security.h>

#define NRSSMaximumDownloadBytes (8 * 1024 * 1024)

// The iOS 10.3 SDK places the URL loading classes in CFNetwork, but on iOS 6 they live in Foundation. Direct
// references would bind to CFNetwork and fail to load on the phone, so they are looked up at run time.
#define NRSSURLClass(name) ((Class)NSClassFromString(@#name))

static NSArray *NRSSExtraAnchors(void) {
    static NSArray *anchors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *certificates = [NSMutableArray array];
        NSFileManager *files = [NSFileManager defaultManager];
        for (NSString *name in [files contentsOfDirectoryAtPath:NRSSRootsDirectory error:NULL]) {
            if (![name.pathExtension isEqualToString:@"der"])
                continue;
            NSData *der = [NSData dataWithContentsOfFile:[NRSSRootsDirectory stringByAppendingPathComponent:name]];
            SecCertificateRef certificate = der ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der) : NULL;
            if (certificate) {
                [certificates addObject:(__bridge id)certificate];
                CFRelease(certificate);
            }
        }
        anchors = [certificates copy];
    });
    return anchors;
}

#define NRSSUserAgent @"Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Mobile/10B329 NewsstandRSS/1.0"
#define NRSSAccept @"application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5"

@interface NRSSFetcher () <NSURLConnectionDataDelegate>
@end

// Hosts whose TLS iOS 6 cannot negotiate (modern servers only offer AES-GCM / ChaCha20). Their downloads go
// straight to the BearSSL client after the first failure.
static NSMutableSet *NRSSModernTLSHosts;

static BOOL NRSSIsTLSFailure(NSError *error, BOOL trustRejected) {
    if (trustRejected)
        return YES;
    return [error.domain isEqualToString:NSURLErrorDomain] && error.code <= -1200 && error.code >= -1206;
}

static NSString *NRSSRequestTarget(NSURL *url) {
    // Path and query exactly as written (still percent-encoded), without the fragment.
    NSString *absolute = url.absoluteString;
    NSRange scheme = [absolute rangeOfString:@"://"];
    NSRange slash = scheme.location == NSNotFound ? scheme
        : [absolute rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(scheme), absolute.length - NSMaxRange(scheme))];
    NSString *target = slash.location == NSNotFound ? @"/" : [absolute substringFromIndex:slash.location];
    NSRange fragment = [target rangeOfString:@"#"];
    return fragment.location == NSNotFound ? target : [target substringToIndex:fragment.location];
}

@implementation NRSSFetcher {
    NSURLConnection *_connection;
    NSMutableData *_data;
    NSURL *_finalURL;
    NSInteger _statusCode;
    NRSSFetchCompletion _completion;
    BOOL _trustRejected;
    BOOL _retriedWithModernTLS;
}

static NSMutableSet *NRSSActiveFetchers;

+ (void)fetchURL:(NSURL *)url completion:(NRSSFetchCompletion)completion {
    if (!NRSSActiveFetchers) {
        NRSSActiveFetchers = [NSMutableSet set];
        NRSSModernTLSHosts = [NSMutableSet set];
    }
    if ([url.scheme.lowercaseString isEqualToString:@"https"] && [NRSSModernTLSHosts containsObject:url.host.lowercaseString]) {
        [self fetchWithModernTLS:url completion:completion];
        return;
    }
    NRSSFetcher *fetcher = [[NRSSFetcher alloc] init];
    fetcher->_completion = [completion copy];
    fetcher->_data = [NSMutableData data];
    fetcher->_finalURL = url;
    NSMutableURLRequest *request = [NRSSURLClass(NSMutableURLRequest) requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30];
    // Some hosts reject unknown agents; present as the phone's own Safari plus our name.
    [request setValue:NRSSUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:NRSSAccept forHTTPHeaderField:@"Accept"];
    [NRSSActiveFetchers addObject:fetcher];
    fetcher->_connection = [[NRSSURLClass(NSURLConnection) alloc] initWithRequest:request delegate:fetcher startImmediately:NO];
    [fetcher->_connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [fetcher->_connection start];
}

+ (void)fetchWithModernTLS:(NSURL *)url completion:(NRSSFetchCompletion)completion {
    completion = [completion copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *current = url;
        NSData *data = nil;
        NSString *message = nil;
        for (int redirects = 0; redirects <= 5; redirects++) {
            if (![current.scheme.lowercaseString isEqualToString:@"https"] || !current.host.length) {
                // Redirected to plain HTTP: the system stack handles that fine.
                NSURL *next = current;
                dispatch_async(dispatch_get_main_queue(), ^{ [self fetchURL:next completion:completion]; });
                return;
            }
            nrss_https_response response;
            int status = nrss_https_get(current.host.UTF8String, current.port ? current.port.intValue : 443,
                                        NRSSRequestTarget(current).UTF8String, NRSSUserAgent.UTF8String, NRSSAccept.UTF8String,
                                        NRSSMaximumDownloadBytes, 30, &response);
            if (status != 0) {
                message = [NSString stringWithUTF8String:response.error];
                nrss_https_response_free(&response);
                break;
            }
            if (response.status >= 300 && response.status < 400 && response.location) {
                current = [[NSURL URLWithString:[NSString stringWithUTF8String:response.location] relativeToURL:current] absoluteURL];
                nrss_https_response_free(&response);
                if (!current)
                    break;
                continue;
            }
            if (response.status >= 200 && response.status < 300)
                data = [NSData dataWithBytes:response.body length:response.body_length];
            else
                message = [NSString stringWithFormat:NRSSLocalized(@"The server answered with error %d.", @"El servidor respondió con el error %d."),
                           response.status];
            nrss_https_response_free(&response);
            break;
        }
        if (!data && !message)
            message = NRSSLocalized(@"Too many redirects.", @"Demasiadas redirecciones.");
        NSError *error = message ? [NSError errorWithDomain:@"NRSSFetcher" code:-1 userInfo:@{NSLocalizedDescriptionKey: message}] : nil;
        NSURL *finalURL = current;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (data)
                [NRSSModernTLSHosts addObject:url.host.lowercaseString];
            completion(data, finalURL, error);
        });
    });
}

- (void)finishWithError:(NSError *)error {
    if (error && !_retriedWithModernTLS && [_finalURL.scheme.lowercaseString isEqualToString:@"https"]
        && NRSSIsTLSFailure(error, _trustRejected)) {
        _retriedWithModernTLS = YES;
        NRSSFetchCompletion completion = _completion;
        _completion = nil;
        [_connection cancel];
        _connection = nil;
        [NRSSActiveFetchers removeObject:self];
        [NRSSFetcher fetchWithModernTLS:_finalURL completion:completion];
        return;
    }
    NRSSFetchCompletion completion = _completion;
    _completion = nil;
    [_connection cancel];
    _connection = nil;
    NSData *data = error ? nil : _data;
    NSURL *finalURL = _finalURL;
    [NRSSActiveFetchers removeObject:self];
    if (completion)
        dispatch_async(dispatch_get_main_queue(), ^{ completion(data, finalURL, error); });
}

- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"NRSSFetcher" code:_statusCode
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (![space.authenticationMethod isEqualToString:@"NSURLAuthenticationMethodServerTrust"]) {
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
        return;
    }
    // The trust object already carries the SSL policy for this host name; only add anchors.
    SecTrustRef trust = space.serverTrust;
    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)NRSSExtraAnchors());
    SecTrustSetAnchorCertificatesOnly(trust, false);
    SecTrustResultType result = kSecTrustResultInvalid;
    if (SecTrustEvaluate(trust, &result) == errSecSuccess
        && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed))
        [challenge.sender useCredential:[NRSSURLClass(NSURLCredential) credentialForTrust:trust] forAuthenticationChallenge:challenge];
    else {
        _trustRejected = YES;
        [challenge.sender cancelAuthenticationChallenge:challenge];
    }
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
    if (request.URL)
        _finalURL = request.URL;
    return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    _statusCode = [response isKindOfClass:NRSSURLClass(NSHTTPURLResponse)] ? [(NSHTTPURLResponse *)response statusCode] : 200;
    _data.length = 0;
    if (response.URL)
        _finalURL = response.URL;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [_data appendData:data];
    if (_data.length > NRSSMaximumDownloadBytes)
        [self finishWithError:[self errorWithMessage:NRSSLocalized(@"The download is too large.", @"La descarga es demasiado grande.")]];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (_statusCode < 200 || _statusCode >= 300)
        [self finishWithError:[self errorWithMessage:[NSString stringWithFormat:
            NRSSLocalized(@"The server answered with error %ld.", @"El servidor respondió con el error %ld."), (long)_statusCode]]];
    else
        [self finishWithError:nil];
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    return nil; // feeds and images are cached by NewsstandRSS itself
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self finishWithError:error];
}

@end
