// NewsstandRSS: adds a "+" button beside Newsstand's Store button. Each RSS/Atom feed added there (or in
// Settings) becomes its own magazine on the shelf: a copy of the reader app that the root helper creates.
// SpringBoard keeps the bundles in sync with the feed list, redraws covers and refreshes them periodically.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "NRSSCover.h"
#import "NRSSFeedAdder.h"
#import "NRSSFeedParser.h"
#import "NRSSFetcher.h"
#import "NRSSShared.h"

@interface SBNewsstandFolderView : UIView
- (void)_configureBars;
- (void)_placeBars;
@end

@interface SBApplication : NSObject
- (NSString *)bundleIdentifier;
- (void)setDisplayName:(NSString *)name;
@end

@interface SBIcon : NSObject
- (NSString *)applicationBundleID;
- (UIImage *)generateIconImage:(int)format;
- (void)reloadIconImagePurgingImageCache:(BOOL)purge;
- (void)purgeCachedImages;
- (BOOL)allowsUninstall;
@end

@interface SBApplicationIcon : SBIcon
@end

@interface SBNewsstandApplicationIcon : SBApplicationIcon
@end

@interface SBFolder : NSObject
@end

@interface SBIconModel : NSObject
- (SBApplicationIcon *)applicationIconForDisplayIdentifier:(NSString *)identifier;
- (SBFolder *)newsstandFolder;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (SBIconModel *)model;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)allApplications;
- (SBApplication *)applicationWithDisplayIdentifier:(NSString *)identifier;
// iOS 6 takes a single identifier here (it wraps it in a set itself).
- (void)loadApplicationsAndIcons:(NSString *)identifier reveal:(BOOL)reveal popIn:(BOOL)popIn;
- (void)removeApplicationsFromModelWithBundleIdentifier:(NSString *)identifier;
@end

static char NRSSAddButtonKey;
static __weak SBNewsstandFolderView *NRSSFolderView;
#ifdef NRSS_DIAGNOSTICS
static int NRSSStockCoverImageTestMode;
#endif

static SBApplicationController *NRSSApplications(void) {
    return [%c(SBApplicationController) sharedInstance];
}

#pragma mark - Keeping magazines in sync with the feed list

static dispatch_queue_t NRSSSyncQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.aurelio.newsstandrss.sync", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// Creates bundles for new feeds, renames changed ones and deletes bundles whose feed is gone, then updates
// SpringBoard's model. Completion runs on the main queue with the helper's exit status (0 when nothing to do).
static void NRSSSynchronizeFeeds(BOOL reveal, void (^completion)(int status)) {
    dispatch_async(NRSSSyncQueue(), ^{
        NSArray *records = NRSSLoadFeeds();
        NSDictionary *installed = NRSSInstalledFeeds();
        NSMutableArray *arguments = [NSMutableArray array];
        NSMutableArray *added = [NSMutableArray array], *removed = [NSMutableArray array];
        NSMutableDictionary *renamed = [NSMutableDictionary dictionary];
        NSMutableSet *known = [NSMutableSet set];
        for (NSDictionary *record in records) {
            NSString *feedID = [record objectForKey:@"id"];
            NSString *title = [NRSSFeedAdder displayNameFromString:[record objectForKey:@"title"] fallback:nil];
            NSString *current = [installed objectForKey:feedID];
            [known addObject:feedID];
            if (current && [current isEqualToString:title])
                continue;
            [arguments addObjectsFromArray:@[@"install", feedID, title]];
            if (current)
                [renamed setObject:title forKey:feedID];
            else
                [added addObject:feedID];
        }
        for (NSString *feedID in installed)
            if (![known containsObject:feedID]) {
                [arguments addObjectsFromArray:@[@"remove", feedID]];
                [removed addObject:feedID];
            }
        int status = arguments.count ? NRSSRunHelper(arguments) : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            SBApplicationController *applications = NRSSApplications();
            for (NSString *feedID in removed) {
                NSString *bundleID = NRSSBundleIDForFeedID(feedID);
                if ([applications applicationWithDisplayIdentifier:bundleID])
                    [applications removeApplicationsFromModelWithBundleIdentifier:bundleID];
            }
            for (NSString *feedID in renamed) {
                [[applications applicationWithDisplayIdentifier:NRSSBundleIDForFeedID(feedID)] setDisplayName:[renamed objectForKey:feedID]];
                [NRSSCover redrawCoverForFeedID:feedID];
            }
            for (NSString *feedID in added) {
                NSString *bundleID = NRSSBundleIDForFeedID(feedID);
                if ([[NSFileManager defaultManager] fileExistsAtPath:NRSSAppPathForFeedID(feedID)]
                    && ![applications applicationWithDisplayIdentifier:bundleID])
                    [applications loadApplicationsAndIcons:bundleID reveal:reveal popIn:YES];
            }
            if (status != 0)
                NSLog(@"NewsstandRSS: helper %@ exited with %d", arguments, status);
            if (completion)
                completion(status);
        });
    });
}

#pragma mark - Covers

static void NRSSReloadCovers(void) {
    SBIconModel *model = [(SBIconController *)[%c(SBIconController) sharedInstance] model];
    for (SBApplication *application in [NRSSApplications() allApplications]) {
        NSString *bundleID = [application bundleIdentifier];
        if (NRSSFeedIDForBundleID(bundleID))
            [[model applicationIconForDisplayIdentifier:bundleID] reloadIconImagePurgingImageCache:YES];
    }
}

static BOOL NRSSRefreshing;

// Downloads each feed whose cached copy is older than maxAge (all of them when maxAge is 0), one at a time.
static void NRSSRefreshFeeds(NSMutableArray *queue, NSTimeInterval maxAge) {
    NSDictionary *record = queue.firstObject;
    if (!record) {
        NRSSRefreshing = NO;
        return;
    }
    [queue removeObjectAtIndex:0];
    NSString *feedID = [record objectForKey:@"id"];
    NSDate *fetched = [[[NSFileManager defaultManager] attributesOfItemAtPath:NRSSCachePathForFeedID(feedID, @"xml") error:NULL] fileModificationDate];
    if (maxAge > 0 && fetched && -[fetched timeIntervalSinceNow] < maxAge) {
        NRSSRefreshFeeds(queue, maxAge);
        return;
    }
    NSURL *url = [NSURL URLWithString:[record objectForKey:@"url"]];
    [NRSSFetcher fetchURL:url completion:^(NSData *data, NSURL *finalURL, NSError *error) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            NRSSFeed *feed = data ? [NRSSFeedParser parseData:data baseURL:finalURL ?: url] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!feed || !NRSSFeedWithID(feedID)) {
                    NRSSRefreshFeeds(queue, maxAge);
                    return;
                }
                [data writeToFile:NRSSCachePathForFeedID(feedID, @"xml") atomically:YES];
                [NRSSCover updateCoverForFeedID:feedID title:[record objectForKey:@"title"] feed:feed completion:^{
                    NRSSRefreshFeeds(queue, maxAge);
                }];
            });
        });
    }];
}

static void NRSSStartRefresh(BOOL force) {
    NSInteger hours = NRSSIntegerPreference(NRSSCoverRefreshHoursKey, 6);
    if (NRSSRefreshing || (!force && hours <= 0))
        return;
    NRSSRefreshing = YES;
    NRSSRefreshFeeds([NRSSLoadFeeds() mutableCopy], force ? 0 : hours * 3600 - 60);
}

@interface NRSSRefreshTimerTarget : NSObject
@end

@implementation NRSSRefreshTimerTarget
- (void)fire:(NSTimer *)timer {
    NRSSStartRefresh(NO);
}
@end

#pragma mark - Adding feeds from Newsstand

@interface NRSSAddFeedController : NSObject <UIAlertViewDelegate>
+ (instancetype)sharedController;
- (void)showPrompt;
- (void)addFeedFromString:(NSString *)input;
- (void)finishAddingFeed:(NSString *)feedID error:(NSString *)message;
@end

@implementation NRSSAddFeedController {
    UIAlertView *_progress;
    BOOL _busy;
}

+ (instancetype)sharedController {
    static NRSSAddFeedController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [[NRSSAddFeedController alloc] init]; });
    return controller;
}

- (void)showPrompt {
    if (_busy)
        return;
    UIAlertView *prompt = [[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Add RSS Feed", @"Añadir fuente RSS")
                                                     message:NRSSLocalized(@"Enter the address of a feed or of the website.",
                                                                           @"Escribe la dirección del feed o del sitio web.")
                                                    delegate:self
                                           cancelButtonTitle:NRSSLocalized(@"Cancel", @"Cancelar")
                                           otherButtonTitles:NRSSLocalized(@"Add", @"Añadir"), nil];
    prompt.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *field = [prompt textFieldAtIndex:0];
    field.placeholder = @"example.com/feed";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    NSString *copied = [UIPasteboard generalPasteboard].string;
    if ([copied hasPrefix:@"http://"] || [copied hasPrefix:@"https://"])
        field.text = copied;
    [prompt show];
}

- (BOOL)alertViewShouldEnableFirstOtherButton:(UIAlertView *)alertView {
    return alertView.alertViewStyle != UIAlertViewStylePlainTextInput
        || [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 3;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)index {
    if (alertView.alertViewStyle == UIAlertViewStylePlainTextInput && index == alertView.firstOtherButtonIndex)
        [self addFeedFromString:[alertView textFieldAtIndex:0].text];
}

- (void)showProgress {
    _progress = [[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Adding Feed…", @"Añadiendo fuente…")
                                           message:@"\n" delegate:nil cancelButtonTitle:nil otherButtonTitles:nil];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [spinner startAnimating];
    [_progress show];
    spinner.center = CGPointMake(_progress.bounds.size.width / 2, _progress.bounds.size.height - 45);
    [_progress addSubview:spinner];
}

- (void)addFeedFromString:(NSString *)input {
    if (_busy)
        return;
    _busy = YES;
    [self showProgress];
    [NRSSFeedAdder addFeedFromString:input completion:^(NSString *feedID, NSString *errorMessage) {
        [self finishAddingFeed:feedID error:errorMessage];
    }];
}

- (void)finishAddingFeed:(NSString *)feedID error:(NSString *)message {
    void (^done)(NSString *) = ^(NSString *failure) {
        [_progress dismissWithClickedButtonIndex:0 animated:YES];
        _progress = nil;
        _busy = NO;
        if (failure)
            [[[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Couldn't Add Feed", @"No se pudo añadir la fuente")
                                        message:failure delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    };
    if (!feedID) {
        done(message);
        return;
    }
    NRSSSynchronizeFeeds(YES, ^(int status) {
        if (status == 0) {
            done(nil);
            return;
        }
        NRSSRemoveFeedRecord(feedID);
        done([NSString stringWithFormat:NRSSLocalized(@"The magazine could not be created (error %d).",
                                                      @"No se pudo crear la revista (error %d)."), status]);
    });
}

@end

#pragma mark - The "+" button

static void NRSSPlaceAddButton(SBNewsstandFolderView *folderView) {
    UIButton *store = MSHookIvar<UIButton *>(folderView, "_storeButton");
    UIView *container = store.superview;
    if (!store || !container)
        return;
    NRSSFolderView = folderView;
    NSString *placement = NRSSPreference(NRSSButtonPlacementKey, @"beside");
    UIButton *add = objc_getAssociatedObject(folderView, &NRSSAddButtonKey);
    if (!add) {
        add = [UIButton buttonWithType:UIButtonTypeCustom];
        for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted)]) {
            UIControlState value = state.unsignedIntegerValue;
            [add setBackgroundImage:[store backgroundImageForState:value] forState:value];
            [add setTitleColor:[store titleColorForState:value] forState:value];
            [add setTitleShadowColor:[store titleShadowColorForState:value] forState:value];
        }
        add.titleLabel.shadowOffset = store.titleLabel.shadowOffset;
        add.accessibilityLabel = NRSSLocalized(@"Add RSS Feed", @"Añadir fuente RSS");
        [add addTarget:[NRSSAddFeedController sharedController] action:@selector(showPrompt) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(folderView, &NRSSAddButtonKey, add, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (add.superview != container)
        [container addSubview:add];

    CGRect storeFrame = store.frame;
    BOOL replace = [placement isEqualToString:@"replace"];
    // Replacing hides Store and puts a labelled button in its place; beside it, a compact "+" sits to its left.
    if (replace) {
        store.hidden = YES;
        [add setTitle:NRSSLocalized(@"+ RSS", @"+ RSS") forState:UIControlStateNormal];
        add.titleLabel.font = store.titleLabel.font;
        add.titleEdgeInsets = UIEdgeInsetsZero;
        CGFloat width = MAX(storeFrame.size.width, [[add titleForState:UIControlStateNormal] sizeWithFont:add.titleLabel.font].width + 20);
        add.frame = CGRectMake(CGRectGetMaxX(storeFrame) - width, storeFrame.origin.y, width, storeFrame.size.height);
    } else {
        [add setTitle:@"+" forState:UIControlStateNormal];
        add.titleLabel.font = [UIFont boldSystemFontOfSize:MAX(store.titleLabel.font.pointSize + 6, 18)];
        add.titleEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
        CGFloat width = MAX(storeFrame.size.height + 6, 36);
        CGFloat right = store.hidden ? CGRectGetMaxX(storeFrame) : storeFrame.origin.x - 6;
        add.frame = CGRectMake(right - width, storeFrame.origin.y, width, storeFrame.size.height);
    }
    add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    add.hidden = [placement isEqualToString:@"hidden"];
    add.alpha = 1;
}

%hook SBNewsstandFolderView

- (void)_configureBars {
    %orig;
    NRSSPlaceAddButton(self);
}

- (void)_placeBars {
    %orig;
    NRSSPlaceAddButton(self);
}

%end

#pragma mark - Restoring the shelf after another app

%hook SBIconController

- (void)openFolder:(SBFolder *)folder animated:(BOOL)animated {
    // Covers-changed notifications repair an open shelf. Opening it again also needs to repair
    // images SpringBoard may have discarded while Settings or another app was in the foreground.
    if (folder && folder == [[self model] newsstandFolder])
        NRSSReloadCovers();
    %orig;
}

%end

#pragma mark - Cover images

// iOS 6 builds the shelf image from the app icon, not from UINewsstandIcon, so the cover is supplied here
// for the large formats (shelf and Newsstand folder thumbnail); small formats keep the RSS app icon.
%hook SBNewsstandApplicationIcon

- (UIImage *)generateIconImage:(int)format {
    UIImage *original = %orig;
#ifdef NRSS_DIAGNOSTICS
    if (format == 7 || format == 8) {
        if (NRSSStockCoverImageTestMode == 1)
            original = nil;
        else if (NRSSStockCoverImageTestMode == 2)
            original = [self generateIconImage:0];
    }
#endif
    NSString *feedID = NRSSFeedIDForBundleID([self applicationBundleID]);
    if (!feedID || (format != 7 && format != 8))
        return original;
    UIImage *cover = [UIImage imageWithContentsOfFile:NRSSCoverPathForFeedID(feedID, YES)];
    if (cover.size.width < 1 || cover.size.height < 1)
        return original;
    // SpringBoard can discard the stock image or return a small generic icon after another app.
    // Select by format, not stock-image size: 7 is the shelf (104pt), 8 the thumbnail (71pt).
    CGFloat edge = format == 7 ? 104 : 71;
    CGFloat fit = MIN(edge / cover.size.width, edge / cover.size.height);
    CGSize size = CGSizeMake(round(cover.size.width * fit), round(cover.size.height * fit));
    UIGraphicsBeginImageContextWithOptions(size, YES, [UIScreen mainScreen].scale);
    [cover drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image ?: original;
}

%end

#pragma mark - Deleting magazines from the shelf

%hook SBApplicationIcon

- (BOOL)allowsUninstall {
    return NRSSFeedIDForBundleID([self applicationBundleID]) ? YES : %orig;
}

%end

%hook SBApplicationController

- (void)uninstallApplication:(SBApplication *)application {
    NSString *feedID = NRSSFeedIDForBundleID([application bundleIdentifier]);
    if (!feedID) {
        %orig;
        return;
    }
    NRSSRemoveFeedRecord(feedID);
    NRSSSynchronizeFeeds(NO, nil);
}

%end

#pragma mark - Notifications

static void NRSSCoversChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ NRSSReloadCovers(); });
}

static void NRSSFeedsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NRSSSynchronizeFeeds(NO, ^(int status) {
            // A name edited in Settings changes the masthead even when the bundle name already matched.
            for (NSDictionary *record in NRSSLoadFeeds())
                [NRSSCover redrawCoverForFeedID:[record objectForKey:@"id"]];
        });
    });
}

static void NRSSPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SBNewsstandFolderView *folderView = NRSSFolderView;
        if (folderView) {
            // _configureBars restores Store's own visibility before the button is placed again.
            MSHookIvar<UIButton *>(folderView, "_storeButton").hidden = NO;
            [folderView _configureBars];
            [folderView _placeBars];
        }
        // Cover options may have changed; redraw from what is cached (no network).
        for (NSDictionary *record in NRSSLoadFeeds())
            [NRSSCover redrawCoverForFeedID:[record objectForKey:@"id"]];
    });
}

static void NRSSRefreshRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ NRSSStartRefresh(YES); });
}

#ifdef NRSS_DIAGNOSTICS
#pragma mark - Device test hooks (diagnostic builds only)

@interface SBIconController (NRSSDiagnostics)
- (void)openFolder:(SBFolder *)folder animated:(BOOL)animated;
- (void)closeFolderAnimated:(BOOL)animated;
- (BOOL)isNewsstandOpen;
- (BOOL)hasOpenFolder;
@end

@interface SBAwayController : NSObject
+ (instancetype)sharedAwayController;
- (BOOL)isLocked;
- (void)undimScreen;
- (void)unlockWithSound:(BOOL)sound;
@end

@interface SBDeviceLockController : NSObject
+ (instancetype)sharedController;
- (BOOL)isPasswordProtected;
@end

@interface SBIcon (NRSSDiagnostics)
- (int)iconFormatForLocation:(int)location;
- (UIImage *)generateIconImage:(int)format;
@end

@interface SBApplicationController (NRSSDiagnostics)
- (void)uninstallApplication:(SBApplication *)application;
@end

extern "C" CGImageRef UIGetScreenImage(void);

@interface UIApplication (NRSSDiagnostics)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (void)_handleMenuButtonEvent;
@end

static UIView *NRSSFindView(UIView *view, Class viewClass) {
    if ([view isKindOfClass:viewClass])
        return view;
    for (UIView *subview in view.subviews) {
        UIView *found = NRSSFindView(subview, viewClass);
        if (found)
            return found;
    }
    return nil;
}

static void NRSSRunTest(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:@"/tmp/nrss-test.plist"];
    NSString *operation = [request objectForKey:@"op"];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:operation ?: @"" forKey:@"op"];
    SBIconController *icons = [%c(SBIconController) sharedInstance];
    SBApplicationController *applications = NRSSApplications();
    SBAwayController *away = [%c(SBAwayController) sharedAwayController];
    if ([operation isEqualToString:@"unlock"]) {
        // Never bypasses a passcode: with one set, the phone stays locked and the result says so.
        BOOL hasPasscode = [[%c(SBDeviceLockController) sharedController] isPasswordProtected];
        [result setObject:@(hasPasscode) forKey:@"passwordProtected"];
        if (!hasPasscode && [away isLocked]) {
            [away undimScreen];
            [away unlockWithSound:NO];
        }
    } else if ([operation isEqualToString:@"open"]) {
        // Opening a folder that is already open trips an assertion in SpringBoard.
        if (![icons hasOpenFolder])
            [icons openFolder:[[icons model] newsstandFolder] animated:YES];
    } else if ([operation isEqualToString:@"close"]) {
        if ([icons hasOpenFolder])
            [icons closeFolderAnimated:YES];
    } else if ([operation isEqualToString:@"add"]) {
        [[NRSSAddFeedController sharedController] addFeedFromString:[request objectForKey:@"url"]];
    } else if ([operation isEqualToString:@"addLocal"]) {
        // Same path as "add", with the feed document read from disk instead of the network.
        NSURL *url = [NSURL URLWithString:[request objectForKey:@"url"]];
        NSData *data = [NSData dataWithContentsOfFile:[request objectForKey:@"path"]];
        NRSSFeed *feed = [NRSSFeedParser parseData:data baseURL:url];
        [result setObject:@(feed != nil) forKey:@"parsed"];
        if (feed)
            [NRSSFeedAdder addParsedFeed:feed data:data url:url completion:^(NSString *feedID, NSString *errorMessage) {
                [[NRSSAddFeedController sharedController] finishAddingFeed:feedID error:errorMessage];
            }];
    } else if ([operation isEqualToString:@"addCountry"]) {
        // The Settings pane's "add all" path, for a catalog country code.
        NSArray *urls = nil;
        for (NSDictionary *country in [[NSDictionary dictionaryWithContentsOfFile:NRSSCatalogPath] objectForKey:@"countries"])
            if ([[country objectForKey:@"code"] isEqualToString:[request objectForKey:@"code"]])
                urls = [country objectForKey:@"feeds"];
        [result setObject:@(urls.count) forKey:@"requested"];
        [NRSSFeedAdder addFeedsFromStrings:urls progress:nil completion:^(NSUInteger added, NSArray *failedInputs) {
            [@{@"added": @(added), @"failed": failedInputs} writeToFile:@"/tmp/nrss-batch-result.plist" atomically:YES];
            NRSSSynchronizeFeeds(NO, nil);
        }];
    } else if ([operation isEqualToString:@"prompt"]) {
        UIButton *add = NRSSFolderView ? objc_getAssociatedObject(NRSSFolderView, &NRSSAddButtonKey) : nil;
        [add sendActionsForControlEvents:UIControlEventTouchUpInside];
        [result setObject:@(add != nil) forKey:@"tapped"];
    } else if ([operation isEqualToString:@"dismiss"]) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            UIAlertView *alert = (UIAlertView *)NRSSFindView(window, [UIAlertView class]);
            [alert dismissWithClickedButtonIndex:alert.cancelButtonIndex animated:NO];
        }
    } else if ([operation isEqualToString:@"uninstall"]) {
        NSString *bundleID = [request objectForKey:@"bundleID"];
        [result setObject:@([[[icons model] applicationIconForDisplayIdentifier:bundleID] allowsUninstall]) forKey:@"allowsUninstall"];
        SBApplication *application = [applications applicationWithDisplayIdentifier:bundleID];
        if (application)
            [applications uninstallApplication:application];
    } else if ([operation isEqualToString:@"purgeCovers"]) {
        for (NSDictionary *record in NRSSLoadFeeds())
            [[[icons model] applicationIconForDisplayIdentifier:NRSSBundleIDForFeedID([record objectForKey:@"id"])] purgeCachedImages];
    } else if ([operation isEqualToString:@"coverRecovery"]) {
        NSMutableDictionary *images = [NSMutableDictionary dictionary];
        for (int mode = 1; mode <= 2; mode++) {
            NRSSStockCoverImageTestMode = mode;
            NSMutableDictionary *feeds = [NSMutableDictionary dictionary];
            for (NSDictionary *record in NRSSLoadFeeds()) {
                id icon = [[icons model] applicationIconForDisplayIdentifier:NRSSBundleIDForFeedID([record objectForKey:@"id"])];
                NSMutableDictionary *formats = [NSMutableDictionary dictionary];
                for (int format = 7; format <= 8; format++) {
                    UIImage *image = [icon generateIconImage:format];
                    [formats setObject:NSStringFromCGSize(image.size) forKey:[NSString stringWithFormat:@"%d", format]];
                }
                [feeds setObject:formats forKey:[record objectForKey:@"id"]];
            }
            [images setObject:feeds forKey:mode == 1 ? @"missing" : @"small"];
        }
        NRSSStockCoverImageTestMode = 0;
        [result setObject:images forKey:@"images"];
    } else if ([operation isEqualToString:@"iconInfo"]) {
        id icon = [[icons model] applicationIconForDisplayIdentifier:[request objectForKey:@"bundleID"]];
        NSMutableDictionary *formats = [NSMutableDictionary dictionary];
        for (int location = 0; location < 8; location++)
            [formats setObject:@((int)[icon iconFormatForLocation:location]) forKey:[NSString stringWithFormat:@"location%d", location]];
        for (int format = 0; format < 16; format++) {
            UIImage *image = [icon generateIconImage:format];
            if (image)
                [formats setObject:[NSString stringWithFormat:@"%@ x%.0f", NSStringFromCGSize(image.size), image.scale]
                            forKey:[NSString stringWithFormat:@"format%02d", format]];
        }
        [formats setObject:NSStringFromClass([icon class]) ?: @"nil" forKey:@"class"];
        [result setObject:formats forKey:@"icon"];
    } else if ([operation isEqualToString:@"launch"]) {
        [[UIApplication sharedApplication] launchApplicationWithIdentifier:[request objectForKey:@"bundleID"] suspended:NO];
    } else if ([operation isEqualToString:@"openURL"]) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[request objectForKey:@"url"]]];
    } else if ([operation isEqualToString:@"home"]) {
        [[UIApplication sharedApplication] _handleMenuButtonEvent];
    } else if ([operation isEqualToString:@"screenshot"]) {
        // The real screen contents, including whichever app is in front.
        CGImageRef screen = UIGetScreenImage();
        if (screen) {
            [UIImagePNGRepresentation([UIImage imageWithCGImage:screen]) writeToFile:@"/tmp/nrss-screen.png" atomically:YES];
            CGImageRelease(screen);
        }
    }
    [result setObject:@([icons isNewsstandOpen]) forKey:@"newsstandOpen"];
    [result setObject:@([away isLocked]) forKey:@"locked"];
    NSMutableArray *loaded = [NSMutableArray array];
    for (SBApplication *application in [applications allApplications])
        if (NRSSFeedIDForBundleID([application bundleIdentifier]))
            [loaded addObject:[application bundleIdentifier]];
    [result setObject:loaded forKey:@"loadedApplications"];
    [result setObject:NRSSInstalledFeeds() forKey:@"installedBundles"];
    [result setObject:NRSSLoadFeeds() forKey:@"feeds"];
    SBNewsstandFolderView *folderView = NRSSFolderView;
    if (folderView) {
        UIButton *store = MSHookIvar<UIButton *>(folderView, "_storeButton");
        UIButton *add = objc_getAssociatedObject(folderView, &NRSSAddButtonKey);
        [result setObject:NSStringFromCGRect(store.frame) forKey:@"storeFrame"];
        [result setObject:@(store.hidden) forKey:@"storeHidden"];
        [result setObject:NSStringFromCGRect(add.frame) forKey:@"addFrame"];
        [result setObject:@(add.hidden) forKey:@"addHidden"];
    }
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIAlertView *alert = (UIAlertView *)NRSSFindView(window, [UIAlertView class]);
        if (alert)
            [result setObject:[NSString stringWithFormat:@"%@ | %@", alert.title, alert.message] forKey:@"alert"];
    }
    [result writeToFile:@"/tmp/nrss-test-result.plist" atomically:YES];
}

static void NRSSTestRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ NRSSRunTest(); });
}
#endif

%ctor {
    @autoreleasepool {
        %init;
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationSuspensionBehavior immediately = CFNotificationSuspensionBehaviorDeliverImmediately;
        CFNotificationCenterAddObserver(darwin, NULL, NRSSCoversChanged, CFSTR(NRSSCoversChangedNotification), NULL, immediately);
        CFNotificationCenterAddObserver(darwin, NULL, NRSSFeedsChanged, CFSTR(NRSSFeedsChangedNotification), NULL, immediately);
        CFNotificationCenterAddObserver(darwin, NULL, NRSSPreferencesChanged, CFSTR(NRSSPreferencesChangedNotification), NULL, immediately);
        CFNotificationCenterAddObserver(darwin, NULL, NRSSRefreshRequested, CFSTR(NRSSRefreshCoversNotification), NULL, immediately);
#ifdef NRSS_DIAGNOSTICS
        CFNotificationCenterAddObserver(darwin, NULL, NRSSTestRequested, CFSTR("com.aurelio.newsstandrss/test"), NULL, immediately);
#endif
        // After boot settles: repair any feed/bundle mismatch, then keep covers fresh.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NRSSSynchronizeFeeds(NO, nil);
            static NRSSRefreshTimerTarget *target;
            target = [[NRSSRefreshTimerTarget alloc] init];
            [NSTimer scheduledTimerWithTimeInterval:20 * 60 target:target selector:@selector(fire:) userInfo:nil repeats:YES];
            NRSSStartRefresh(NO);
        });
    }
}
