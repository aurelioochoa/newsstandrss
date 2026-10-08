#import "NRSSCover.h"
#import "NRSSFeedParser.h"
#import "NRSSFetcher.h"
#import "NRSSShared.h"

#define NRSSCoverSize CGSizeMake(150, 200)

static UIColor *NRSSCoverColor(NSString *title) {
    static const unsigned palette[] = {0x9B1B30, 0x1F3A5F, 0x2E5E3E, 0x2B2B2B, 0x0F5C63, 0x5B2A55, 0xB4531F, 0x6B4E16};
    unsigned hash = 5381;
    for (NSUInteger i = 0; i < title.length; i++)
        hash = hash * 33 + [title characterAtIndex:i];
    unsigned rgb = palette[hash % (sizeof(palette) / sizeof(palette[0]))];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

static UIFont *NRSSFont(NSString *name, NSString *fallback, CGFloat size) {
    return [UIFont fontWithName:name size:size] ?: [UIFont fontWithName:fallback size:size] ?: [UIFont boldSystemFontOfSize:size];
}

static UIImage *NRSSShrink(UIImage *image, CGFloat maxSide) {
    CGFloat factor = maxSide / MAX(image.size.width * image.scale, image.size.height * image.scale);
    if (factor >= 1)
        return image;
    CGSize size = CGSizeMake(floor(image.size.width * image.scale * factor), floor(image.size.height * image.scale * factor));
    UIGraphicsBeginImageContextWithOptions(size, YES, 1);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return small;
}

@implementation NRSSCover

+ (NSString *)photoURLForFeed:(NRSSFeed *)feed {
    // Feed logos are usually small favicons, so only article photos are used; iOS 6 cannot decode WebP or SVG.
    NSUInteger checked = 0;
    for (NRSSItem *item in feed.items) {
        NSString *extension = [[NSURL URLWithString:item.imageURL] path].pathExtension.lowercaseString;
        if (item.imageURL && ![extension isEqualToString:@"webp"] && ![extension isEqualToString:@"svg"])
            return item.imageURL;
        if (++checked == 12)
            break;
    }
    return nil;
}

+ (UIImage *)coverForTitle:(NSString *)title feed:(NRSSFeed *)feed photo:(UIImage *)photo scale:(CGFloat)scale {
    CGSize size = NRSSCoverSize;
    UIColor *color = NRSSCoverColor(title);
    UIGraphicsBeginImageContextWithOptions(size, YES, scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();

    [color setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    if (photo.size.width * photo.scale >= 120 && photo.size.height * photo.scale >= 90) {
        CGFloat fill = MAX(size.width / photo.size.width, size.height / photo.size.height);
        CGSize drawn = CGSizeMake(photo.size.width * fill, photo.size.height * fill);
        [photo drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    } else {
        // No photo: a darker lower half keeps the headline area readable and still looks printed.
        CGFloat stops[] = {0, 1};
        NSArray *colors = @[(__bridge id)[UIColor colorWithWhite:0 alpha:0].CGColor, (__bridge id)[UIColor colorWithWhite:0 alpha:0.35].CGColor];
        CGGradientRef shade = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
        CGContextDrawLinearGradient(context, shade, CGPointMake(0, 40), CGPointMake(0, size.height), 0);
        CGGradientRelease(shade);
    }
    CGFloat stops[] = {0, 0.55, 1};
    NSArray *colors = @[(__bridge id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                        (__bridge id)[UIColor colorWithWhite:0 alpha:0.6].CGColor,
                        (__bridge id)[UIColor colorWithWhite:0 alpha:0.88].CGColor];
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 80), CGPointMake(0, size.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    // Masthead band.
    CGRect band = CGRectMake(0, 0, size.width, 42);
    [color setFill];
    UIRectFill(band);
    [[UIColor colorWithWhite:1 alpha:0.85] setFill];
    UIRectFill(CGRectMake(6, 33, size.width - 12, 0.5));

    NSString *masthead = (title.length ? title : @"RSS").uppercaseString;
    CGFloat fontSize = 28;
    UIFont *mastheadFont = NRSSFont(@"Didot-Bold", @"Georgia-Bold", fontSize);
    while (fontSize > 11 && [masthead sizeWithFont:mastheadFont].width > size.width - 12) {
        fontSize -= 1;
        mastheadFont = NRSSFont(@"Didot-Bold", @"Georgia-Bold", fontSize);
    }
    CGFloat mastheadHeight = [masthead sizeWithFont:mastheadFont].height;
    [[UIColor whiteColor] set];
    [masthead drawInRect:CGRectMake(6, MAX(1, (33 - mastheadHeight) / 2 + 1), size.width - 12, mastheadHeight)
                withFont:mastheadFont lineBreakMode:NSLineBreakByTruncatingTail alignment:NSTextAlignmentCenter];

    static NSDateFormatter *dateFormatter;
    if (!dateFormatter) {
        dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = @"d MMM yyyy";
    }
    NRSSItem *newest = feed.items.count ? [feed.items objectAtIndex:0] : nil;
    NSString *dateline = [dateFormatter stringFromDate:newest.date ?: [NSDate date]].uppercaseString;
    UIFont *smallFont = NRSSFont(@"HelveticaNeue-Bold", @"Helvetica-Bold", 5.5);
    [[UIColor colorWithWhite:1 alpha:0.85] set];
    [@"RSS" drawInRect:CGRectMake(7, 34.5, 40, 7) withFont:smallFont lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentLeft];
    [dateline drawInRect:CGRectMake(size.width - 87, 34.5, 80, 7) withFont:smallFont lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentRight];

    // Headlines, stacked upward from the bottom edge.
    CGContextSetShadowWithColor(context, CGSizeMake(0, 0.5), 1.5, [UIColor colorWithWhite:0 alpha:0.8].CGColor);
    CGFloat width = size.width - 14, bottom = size.height - 7;
    NSUInteger count = MIN((NSUInteger)(NRSSIntegerPreference(NRSSCoverHeadlinesKey, 3) <= 1 ? 1 : 3), feed.items.count);
    for (NSInteger i = (NSInteger)count - 1; i >= 0; i--) {
        NRSSItem *item = [feed.items objectAtIndex:i];
        if (!item.title.length)
            continue;
        BOOL lead = i == 0;
        UIFont *font = lead ? NRSSFont(@"HelveticaNeue-Bold", @"Helvetica-Bold", 11.5) : NRSSFont(@"HelveticaNeue", @"Helvetica", 7.5);
        CGFloat maxHeight = ceil(font.lineHeight * (lead ? 4 : 2));
        CGFloat height = MIN(maxHeight, [item.title sizeWithFont:font constrainedToSize:CGSizeMake(width, maxHeight)
                                                   lineBreakMode:NSLineBreakByWordWrapping].height);
        if (bottom - height < 50)
            break;
        [[UIColor whiteColor] set];
        [item.title drawInRect:CGRectMake(7, bottom - height, width, height) withFont:font
                 lineBreakMode:NSLineBreakByTruncatingTail alignment:NSTextAlignmentLeft];
        bottom -= height + (lead ? 0 : 4);
        if (!lead && i == 1) {
            [[UIColor colorWithWhite:1 alpha:0.6] setFill];
            UIRectFill(CGRectMake(7, bottom, 24, 0.5));
            bottom -= 5;
        }
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (BOOL)writeCoverForFeedID:(NSString *)feedID title:(NSString *)title feed:(NRSSFeed *)feed photo:(UIImage *)photo {
    NRSSEnsureDataDirectories();
    if (!NRSSBoolPreference(NRSSCoverPhotosKey, YES))
        photo = nil;
    NSData *normal = UIImagePNGRepresentation([self coverForTitle:title feed:feed photo:photo scale:1]);
    NSData *retina = UIImagePNGRepresentation([self coverForTitle:title feed:feed photo:photo scale:2]);
    BOOL written = normal && retina
        && [normal writeToFile:NRSSCoverPathForFeedID(feedID, NO) atomically:YES]
        && [retina writeToFile:NRSSCoverPathForFeedID(feedID, YES) atomically:YES];
    if (written)
        NRSSPostCoversChanged();
    return written;
}

+ (void)updateCoverForFeedID:(NSString *)feedID title:(NSString *)title feed:(NRSSFeed *)feed completion:(void (^)(void))completion {
    NSString *photoURL = NRSSBoolPreference(NRSSCoverPhotosKey, YES) ? [self photoURLForFeed:feed] : nil;
    if (!photoURL) {
        [[NSFileManager defaultManager] removeItemAtPath:NRSSCachePathForFeedID(feedID, @"photo") error:NULL];
        [self writeCoverForFeedID:feedID title:title feed:feed photo:nil];
        if (completion)
            completion();
        return;
    }
    [NRSSFetcher fetchURL:[NSURL URLWithString:photoURL] completion:^(NSData *data, NSURL *finalURL, NSError *error) {
        UIImage *photo = data ? [UIImage imageWithData:data] : nil;
        if (photo) {
            // Keep a small copy so the cover can be redrawn offline (renames, settings changes).
            [UIImageJPEGRepresentation(NRSSShrink(photo, 600), 0.8) writeToFile:NRSSCachePathForFeedID(feedID, @"photo") atomically:YES];
        }
        [self writeCoverForFeedID:feedID title:title feed:feed photo:photo];
        if (completion)
            completion();
    }];
}

+ (BOOL)redrawCoverForFeedID:(NSString *)feedID {
    NSDictionary *record = NRSSFeedWithID(feedID);
    if (!record)
        return NO;
    NRSSFeed *feed = [NRSSFeedParser parseData:[NSData dataWithContentsOfFile:NRSSCachePathForFeedID(feedID, @"xml")]
                                       baseURL:[NSURL URLWithString:[record objectForKey:@"url"]]];
    UIImage *photo = [UIImage imageWithContentsOfFile:NRSSCachePathForFeedID(feedID, @"photo")];
    return [self writeCoverForFeedID:feedID title:[record objectForKey:@"title"] feed:feed photo:photo];
}

@end
