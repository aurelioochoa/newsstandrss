#import "NRSSAppDelegate.h"
#import "NRSSItemsViewController.h"
#import "NRSSShared.h"

@implementation NRSSAppDelegate {
    NRSSItemsViewController *_itemsController;
    NSDate *_lastRefresh;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // A memory-only URL cache: iOS kills suspended apps that hold the on-disk cache database open (0xdead10cc).
    // NSURLCache is looked up at run time because the 10.3 SDK links it to CFNetwork, not iOS 6's Foundation.
    Class cacheClass = NSClassFromString(@"NSURLCache");
    [cacheClass setSharedURLCache:[[cacheClass alloc] initWithMemoryCapacity:4 * 1024 * 1024 diskCapacity:0 diskPath:nil]];

    // Every feed bundle runs this same binary; the bundle says which feed it is.
    NSString *feedID = [[NSBundle mainBundle] objectForInfoDictionaryKey:NRSSFeedIDInfoKey];
    _itemsController = [[NRSSItemsViewController alloc] initWithFeedID:feedID];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:_itemsController];
    navigation.navigationBar.tintColor = [UIColor colorWithRed:0.24 green:0.17 blue:0.12 alpha:1];
    navigation.toolbar.tintColor = navigation.navigationBar.tintColor;
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    _lastRefresh = [NSDate date];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    if (-[_lastRefresh timeIntervalSinceNow] > 120) {
        _lastRefresh = [NSDate date];
        [_itemsController refresh];
    }
}

@end
