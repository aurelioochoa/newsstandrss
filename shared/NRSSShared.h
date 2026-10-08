#import <Foundation/Foundation.h>
#import <sys/cdefs.h>

// Paths and identifiers shared by the SpringBoard tweak, the reader app and the root helper.
#define NRSSDataDirectory @"/var/mobile/Library/NewsstandRSS"
#define NRSSFeedsPath NRSSDataDirectory @"/Feeds.plist"
#define NRSSCoversDirectory NRSSDataDirectory @"/Covers"
#define NRSSCacheDirectory NRSSDataDirectory @"/Cache"
#define NRSSRootsDirectory @"/Library/NewsstandRSS/Roots"
#define NRSSTemplatePath @"/Library/NewsstandRSS/Reader.app"
#define NRSSCatalogPath @"/Library/NewsstandRSS/Catalog.plist"
#define NRSSCountryKey @"Country"                     // catalog country code chosen in Settings
#define NRSSHelperPath @"/usr/libexec/newsstandrss-helper"
#define NRSSBundlePrefix @"com.aurelio.newsstandrss.feed."
#define NRSSFeedIDInfoKey @"NRSSFeedID"
#define NRSSCoversChangedNotification "com.aurelio.newsstandrss/covers-changed"
#define NRSSFeedsChangedNotification "com.aurelio.newsstandrss/feeds-changed"
#define NRSSPreferencesChangedNotification "com.aurelio.newsstandrss/prefs-changed"
#define NRSSRefreshCoversNotification "com.aurelio.newsstandrss/refresh-covers"
#define NRSSPreferencesPath @"/var/mobile/Library/Preferences/com.aurelio.newsstandrss.plist"

// Preference keys (values written by the Settings pane).
#define NRSSButtonPlacementKey @"ButtonPlacement"     // "beside" (default), "replace", "hidden"
#define NRSSCoverPhotosKey @"CoverPhotos"             // BOOL, default YES
#define NRSSCoverHeadlinesKey @"CoverHeadlines"       // 1 or 3, default 3
#define NRSSCoverRefreshHoursKey @"CoverRefreshHours" // 0 = never, default 6
#define NRSSReaderTextSizeKey @"ReaderTextSize"       // points, default 17
#define NRSSReaderThemeKey @"ReaderTheme"             // "light", "sepia" (default), "dark"
#define NRSSListThumbnailsKey @"ListThumbnails"       // BOOL, default YES

__BEGIN_DECLS

// Spanish when the phone's first language is Spanish, English otherwise.
NSString *NRSSLocalized(NSString *english, NSString *spanish);

BOOL NRSSIsValidFeedID(NSString *feedID);
NSString *NRSSNewFeedID(void);
NSString *NRSSBundleIDForFeedID(NSString *feedID);
NSString *NRSSFeedIDForBundleID(NSString *bundleID); // nil when not one of ours
NSString *NRSSAppPathForFeedID(NSString *feedID);

// Feed bundles present in /Applications: feed id -> display name.
NSDictionary *NRSSInstalledFeeds(void);

// Feed records: {id, url, source, title, site, added}; source is the address the user (or catalog) gave. Only the tweak (mobile, inside SpringBoard) writes them.
NSArray *NRSSLoadFeeds(void);
NSDictionary *NRSSFeedWithID(NSString *feedID);
NSDictionary *NRSSFeedWithURL(NSString *url); // matches the feed address or the address it was added from
BOOL NRSSSaveFeed(NSDictionary *feed);
BOOL NRSSRemoveFeedRecord(NSString *feedID); // also deletes its cover and cache files

NSString *NRSSCoverPathForFeedID(NSString *feedID, BOOL retina);
NSString *NRSSCachePathForFeedID(NSString *feedID, NSString *suffix);
void NRSSEnsureDataDirectories(void);
void NRSSPostCoversChanged(void);

// Current value of a preference, or the fallback when unset.
id NRSSPreference(NSString *key, id fallback);
BOOL NRSSBoolPreference(NSString *key, BOOL fallback);
NSInteger NRSSIntegerPreference(NSString *key, NSInteger fallback);

// http(s) URL for what the user typed ("example.com", "feed://…"), or nil.
NSURL *NRSSURLFromUserInput(NSString *input);
void NRSSPostFeedsChanged(void);

// Runs the setuid helper and waits for it. Returns its exit status, or -1 when it could not start.
int NRSSRunHelper(NSArray *arguments);

__END_DECLS
