#import "NRSSItemsViewController.h"
#import "NRSSArticleViewController.h"
#import "NRSSCover.h"
#import "NRSSFeedParser.h"
#import "NRSSFetcher.h"
#import "NRSSShared.h"

#define NRSSThumbnailSide 60.0
#define NRSSMaximumReadIDs 1500

@interface NRSSItemsViewController () <UIActionSheetDelegate>
@end

@implementation NRSSItemsViewController {
    NSString *_feedID;
    NSDictionary *_record;
    NRSSFeed *_feed;
    NSMutableArray *_readIDs;
    NSString *_message;
    BOOL _loading;
    NSCache *_thumbnails;
    NSMutableSet *_pendingThumbnails;
    UIImage *_blankThumbnail;
}

- (instancetype)initWithFeedID:(NSString *)feedID {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _feedID = [feedID copy];
        _thumbnails = [[NSCache alloc] init];
        _pendingThumbnails = [NSMutableSet set];
        _readIDs = [NSMutableArray array];
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The name may have been edited in Settings while the app was in the background.
    NSDictionary *record = NRSSIsValidFeedID(_feedID) ? NRSSFeedWithID(_feedID) : nil;
    if ([record objectForKey:@"title"])
        self.title = [record objectForKey:@"title"];
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 84;
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(showFeedActions)];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(NRSSThumbnailSide, NRSSThumbnailSide), NO, 0);
    _blankThumbnail = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    _record = NRSSIsValidFeedID(_feedID) ? NRSSFeedWithID(_feedID) : nil;
    self.title = [_record objectForKey:@"title"] ?: @"RSS";
    if (!_record) {
        _message = NRSSLocalized(@"This feed was removed from Newsstand.", @"Esta fuente se eliminó de Quiosco.");
        return;
    }
    NSArray *read = [NSArray arrayWithContentsOfFile:NRSSCachePathForFeedID(_feedID, @"read.plist")];
    if (read)
        [_readIDs addObjectsFromArray:read];
    NSData *cached = [NSData dataWithContentsOfFile:NRSSCachePathForFeedID(_feedID, @"xml")];
    _feed = [NRSSFeedParser parseData:cached baseURL:[NSURL URLWithString:[_record objectForKey:@"url"]]];
    [self refresh];
}

#pragma mark - Loading

- (void)refresh {
    if (!_record || _loading) {
        [self.refreshControl endRefreshing];
        return;
    }
    _loading = YES;
    if (!_feed.items.count) {
        _message = NRSSLocalized(@"Loading…", @"Cargando…");
        [self.tableView reloadData];
    }
    NSURL *url = [NSURL URLWithString:[_record objectForKey:@"url"]];
    [NRSSFetcher fetchURL:url completion:^(NSData *data, NSURL *finalURL, NSError *error) {
        if (error) {
            [self finishRefreshWithFeed:nil data:nil error:error.localizedDescription];
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NRSSFeed *feed = [NRSSFeedParser parseData:data baseURL:finalURL ?: url];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishRefreshWithFeed:feed data:data
                                      error:feed ? nil : NRSSLocalized(@"The address no longer returns an RSS or Atom feed.",
                                                                       @"La dirección ya no devuelve un feed RSS o Atom.")];
            });
        });
    }];
}

- (void)finishRefreshWithFeed:(NRSSFeed *)feed data:(NSData *)data error:(NSString *)error {
    _loading = NO;
    [self.refreshControl endRefreshing];
    if (feed) {
        NRSSEnsureDataDirectories();
        [data writeToFile:NRSSCachePathForFeedID(_feedID, @"xml") atomically:YES];
        _feed = feed;
        _message = feed.items.count ? nil : NRSSLocalized(@"This feed has no articles yet.", @"Esta fuente aún no tiene artículos.");
        [self updateCover];
    } else if (_feed.items.count) {
        // Keep showing the cached articles; just say the update failed.
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Couldn't Update", @"No se pudo actualizar")
                                                        message:error delegate:nil
                                              cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alert show];
    } else {
        _message = error;
    }
    [self.tableView reloadData];
#ifdef NRSS_DIAGNOSTICS
    // Device tests: open the newest article automatically.
    if (_feed.items.count && [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/nrss-open-article" error:NULL])
        [self tableView:self.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
#endif
}

- (void)updateCover {
    [NRSSCover updateCoverForFeedID:_feedID title:self.title feed:_feed completion:nil];
}

#pragma mark - Read state

- (BOOL)isRead:(NRSSItem *)item {
    return [_readIDs containsObject:item.identifier];
}

- (void)markRead:(NRSSItem *)item {
    if (!item.identifier || [self isRead:item])
        return;
    [_readIDs addObject:item.identifier];
    if (_readIDs.count > NRSSMaximumReadIDs)
        [_readIDs removeObjectsInRange:NSMakeRange(0, _readIDs.count - NRSSMaximumReadIDs)];
    NRSSEnsureDataDirectories();
    [_readIDs writeToFile:NRSSCachePathForFeedID(_feedID, @"read.plist") atomically:YES];
}

- (void)markAllRead {
    for (NRSSItem *item in _feed.items)
        if (item.identifier && ![self isRead:item])
            [_readIDs addObject:item.identifier];
    if (_readIDs.count > NRSSMaximumReadIDs)
        [_readIDs removeObjectsInRange:NSMakeRange(0, _readIDs.count - NRSSMaximumReadIDs)];
    NRSSEnsureDataDirectories();
    [_readIDs writeToFile:NRSSCachePathForFeedID(_feedID, @"read.plist") atomically:YES];
    [self.tableView reloadData];
}

- (void)showFeedActions {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[_record objectForKey:@"url"] delegate:self
                                              cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:NRSSLocalized(@"Mark All as Read", @"Marcar todo como leído")];
    if (_feed.siteURL)
        [sheet addButtonWithTitle:NRSSLocalized(@"Open Website in Safari", @"Abrir sitio web en Safari")];
    [sheet addButtonWithTitle:NRSSLocalized(@"Copy Feed Address", @"Copiar dirección del feed")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:NRSSLocalized(@"Cancel", @"Cancelar")];
    [sheet showFromBarButtonItem:self.navigationItem.rightBarButtonItem animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index == sheet.cancelButtonIndex || index < 0)
        return;
    NSString *title = [sheet buttonTitleAtIndex:index];
    if ([title isEqualToString:NRSSLocalized(@"Mark All as Read", @"Marcar todo como leído")])
        [self markAllRead];
    else if ([title isEqualToString:NRSSLocalized(@"Open Website in Safari", @"Abrir sitio web en Safari")])
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:_feed.siteURL]];
    else
        [UIPasteboard generalPasteboard].string = [_record objectForKey:@"url"];
}

#pragma mark - Thumbnails

- (void)loadThumbnailForItem:(NRSSItem *)item {
    NSString *imageURL = item.imageURL;
    if (!imageURL || [_pendingThumbnails containsObject:imageURL] || [_thumbnails objectForKey:imageURL])
        return;
    [_pendingThumbnails addObject:imageURL];
    [NRSSFetcher fetchURL:[NSURL URLWithString:imageURL] completion:^(NSData *data, NSURL *finalURL, NSError *error) {
        [_pendingThumbnails removeObject:imageURL];
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        UIImage *thumbnail = image ? [self thumbnailFromImage:image] : _blankThumbnail;
        [_thumbnails setObject:thumbnail forKey:imageURL];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows)
            if (path.row < (NSInteger)_feed.items.count && [[[_feed.items objectAtIndex:path.row] imageURL] isEqualToString:imageURL])
                [paths addObject:path];
        if (paths.count)
            [self.tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (UIImage *)thumbnailFromImage:(UIImage *)image {
    if (image.size.width < 1 || image.size.height < 1)
        return _blankThumbnail;
    CGFloat side = NRSSThumbnailSide;
    CGFloat fill = MAX(side / image.size.width, side / image.size.height);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), YES, 0);
    [[UIColor whiteColor] setFill];
    UIRectFill(CGRectMake(0, 0, side, side));
    [image drawInRect:CGRectMake((side - image.size.width * fill) / 2, (side - image.size.height * fill) / 2,
                                 image.size.width * fill, image.size.height * fill)];
    UIImage *thumbnail = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return thumbnail;
}

#pragma mark - Table

- (NSString *)ageOfDate:(NSDate *)date {
    if (!date)
        return nil;
    NSTimeInterval age = -[date timeIntervalSinceNow];
    if (age < 60)
        return NRSSLocalized(@"now", @"ahora");
    if (age < 3600)
        return [NSString stringWithFormat:@"%d min", (int)(age / 60)];
    if (age < 86400)
        return [NSString stringWithFormat:@"%d h", (int)(age / 3600)];
    static NSDateFormatter *formatter;
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterNoStyle;
    }
    return [formatter stringFromDate:date];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _feed.items.count ?: (_message ? 1 : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!_feed.items.count) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Message"]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Message"];
        cell.textLabel.text = _message;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.textLabel.textColor = [UIColor grayColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Item"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Item"];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    NRSSItem *item = [_feed.items objectAtIndex:indexPath.row];
    BOOL read = [self isRead:item];
    cell.textLabel.text = item.title;
    cell.textLabel.font = read ? [UIFont systemFontOfSize:15] : [UIFont boldSystemFontOfSize:15];
    cell.textLabel.textColor = read ? [UIColor darkGrayColor] : [UIColor blackColor];
    NSString *age = [self ageOfDate:item.date];
    cell.detailTextLabel.text = age.length ? [NSString stringWithFormat:@"%@ — %@", age, item.summary ?: @""] : item.summary;
    if (item.imageURL && NRSSBoolPreference(NRSSListThumbnailsKey, YES)) {
        cell.imageView.image = [_thumbnails objectForKey:item.imageURL] ?: _blankThumbnail;
        [self loadThumbnailForItem:item];
    } else {
        cell.imageView.image = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_feed.items.count)
        return;
    NRSSItem *item = [_feed.items objectAtIndex:indexPath.row];
    [self markRead:item];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self.navigationController pushViewController:[[NRSSArticleViewController alloc] initWithItem:item feedTitle:self.title] animated:YES];
}

@end
