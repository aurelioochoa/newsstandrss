#import "NRSSFeedParser.h"

@implementation NRSSItem
@end

@implementation NRSSFeed
@end

typedef enum { NRSSKindUnknown, NRSSKindRSS, NRSSKindRDF, NRSSKindAtom } NRSSKind;

static NSString *NRSSTrim(NSString *string) {
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *NRSSResolve(NSString *value, NSURL *baseURL) {
    value = NRSSTrim(value);
    if (!value.length)
        return nil;
    NSURL *url = [NSURL URLWithString:value relativeToURL:baseURL];
    if (!url)
        url = [NSURL URLWithString:[value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] relativeToURL:baseURL];
    NSString *scheme = url.scheme.lowercaseString;
    return ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ? url.absoluteString : nil;
}

static NSDate *NRSSParseDate(NSString *string) {
    static NSDateFormatter *formatter;
    static NSArray *rfc822Formats;
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        rfc822Formats = @[@"EEE, d MMM yyyy HH:mm:ss Z", @"EEE, d MMM yyyy HH:mm:ss zzz", @"EEE, d MMM yyyy HH:mm Z",
                          @"EEE, d MMM yyyy HH:mm zzz", @"d MMM yyyy HH:mm:ss Z", @"d MMM yyyy HH:mm:ss zzz",
                          @"EEE, d MMM yy HH:mm:ss Z", @"EEE, d MMM yyyy"];
    }
    string = NRSSTrim(string);
    if (string.length < 8)
        return nil;
    if ([string characterAtIndex:4] == '-') {
        // ISO 8601 / RFC 3339: drop fractional seconds and rewrite Z / ±hh:mm as ±hhmm for the "Z" pattern.
        NSMutableString *iso = [string mutableCopy];
        NSRange fraction = [iso rangeOfString:@"\\.[0-9]+" options:NSRegularExpressionSearch];
        if (fraction.location != NSNotFound)
            [iso deleteCharactersInRange:fraction];
        if ([iso hasSuffix:@"Z"] || [iso hasSuffix:@"z"])
            [iso replaceCharactersInRange:NSMakeRange(iso.length - 1, 1) withString:@"+0000"];
        else if (iso.length > 6 && [iso characterAtIndex:iso.length - 3] == ':'
                 && ([iso characterAtIndex:iso.length - 6] == '+' || [iso characterAtIndex:iso.length - 6] == '-'))
            [iso deleteCharactersInRange:NSMakeRange(iso.length - 3, 1)];
        for (NSString *format in @[@"yyyy-MM-dd'T'HH:mm:ssZ", @"yyyy-MM-dd'T'HH:mmZ", @"yyyy-MM-dd'T'HH:mm:ss",
                                   @"yyyy-MM-dd HH:mm:ssZ", @"yyyy-MM-dd"]) {
            formatter.dateFormat = format;
            NSDate *date = [formatter dateFromString:iso];
            if (date)
                return date;
        }
        return nil;
    }
    for (NSString *format in rfc822Formats) {
        formatter.dateFormat = format;
        NSDate *date = [formatter dateFromString:string];
        if (date)
            return date;
    }
    return nil;
}

static NSString *NRSSDecodeEntities(NSString *string) {
    if ([string rangeOfString:@"&"].location == NSNotFound)
        return string;
    static NSDictionary *named;
    if (!named)
        named = @{@"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'", @"nbsp": @"\u00a0",
                  @"hellip": @"\u2026", @"mdash": @"\u2014", @"ndash": @"\u2013", @"lsquo": @"\u2018",
                  @"rsquo": @"\u2019", @"ldquo": @"\u201c", @"rdquo": @"\u201d", @"laquo": @"\u00ab",
                  @"raquo": @"\u00bb", @"middot": @"\u00b7", @"bull": @"\u2022", @"copy": @"\u00a9",
                  @"reg": @"\u00ae", @"trade": @"\u2122", @"euro": @"\u20ac", @"iexcl": @"\u00a1",
                  @"iquest": @"\u00bf", @"aacute": @"\u00e1", @"eacute": @"\u00e9", @"iacute": @"\u00ed",
                  @"oacute": @"\u00f3", @"uacute": @"\u00fa", @"ntilde": @"\u00f1", @"Aacute": @"\u00c1",
                  @"Eacute": @"\u00c9", @"Iacute": @"\u00cd", @"Oacute": @"\u00d3", @"Uacute": @"\u00da",
                  @"Ntilde": @"\u00d1", @"uuml": @"\u00fc", @"Uuml": @"\u00dc"};
    static NSRegularExpression *entity;
    if (!entity)
        entity = [NSRegularExpression regularExpressionWithPattern:@"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});"
                                                           options:0 error:NULL];
    NSMutableString *result = [NSMutableString string];
    __block NSUInteger last = 0;
    [entity enumerateMatchesInString:string options:0 range:NSMakeRange(0, string.length)
                          usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSString *name = [string substringWithRange:[match rangeAtIndex:1]];
        NSString *replacement = nil;
        if ([name hasPrefix:@"#"]) {
            BOOL hex = name.length > 1 && ([name characterAtIndex:1] == 'x' || [name characterAtIndex:1] == 'X');
            unsigned long code = strtoul([[name substringFromIndex:hex ? 2 : 1] UTF8String], NULL, hex ? 16 : 10);
            if (code > 0 && code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF)) {
                if (code > 0xFFFF) {
                    unichar pair[2] = {(unichar)(0xD800 + ((code - 0x10000) >> 10)), (unichar)(0xDC00 + ((code - 0x10000) & 0x3FF))};
                    replacement = [NSString stringWithCharacters:pair length:2];
                } else {
                    unichar character = (unichar)code;
                    replacement = [NSString stringWithCharacters:&character length:1];
                }
            }
        } else {
            replacement = [named objectForKey:name];
        }
        if (!replacement)
            return;
        [result appendString:[string substringWithRange:NSMakeRange(last, match.range.location - last)]];
        [result appendString:replacement];
        last = NSMaxRange(match.range);
    }];
    [result appendString:[string substringFromIndex:last]];
    return result;
}

static NSString *NRSSFirstImageInHTML(NSString *html, NSURL *baseURL) {
    if (!html.length)
        return nil;
    static NSRegularExpression *image;
    if (!image)
        image = [NSRegularExpression regularExpressionWithPattern:@"<img\\b[^>]*?\\bsrc\\s*=\\s*[\"']([^\"']+)[\"']"
                                                          options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *match = [image firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    return match ? NRSSResolve(NRSSDecodeEntities([html substringWithRange:[match rangeAtIndex:1]]), baseURL) : nil;
}

@interface NRSSFeedParser () <NSXMLParserDelegate>
@end

@implementation NRSSFeedParser {
    NSURL *_baseURL;
    NRSSKind _kind;
    NRSSFeed *_feed;
    NSMutableArray *_items;
    NSMutableArray *_stack;
    NSMutableString *_text;
    NRSSItem *_item;
    NSString *_itemDescription;
    NSString *_itemContent;
    BOOL _itemHasPublished;
}

+ (NRSSFeed *)parseData:(NSData *)data baseURL:(NSURL *)baseURL {
    if (!data.length)
        return nil;
    NRSSFeedParser *delegate = [[NRSSFeedParser alloc] init];
    delegate->_baseURL = baseURL;
    delegate->_feed = [[NRSSFeed alloc] init];
    delegate->_items = [NSMutableArray array];
    delegate->_stack = [NSMutableArray array];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = delegate;
    parser.shouldProcessNamespaces = NO;
    parser.shouldResolveExternalEntities = NO;
    [parser parse];
    // A broken entity late in the document still leaves the items read so far usable.
    if (delegate->_kind == NRSSKindUnknown || (!delegate->_items.count && !delegate->_feed.title.length))
        return nil;
    NSArray *items = delegate->_items;
    if ([items indexOfObjectPassingTest:^BOOL(NRSSItem *item, NSUInteger i, BOOL *stop) { return !item.date; }] == NSNotFound)
        items = [items sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NRSSItem *a, NRSSItem *b) {
            return [b.date compare:a.date];
        }];
    delegate->_feed.items = items;
    if (!delegate->_feed.title.length)
        delegate->_feed.title = baseURL.host;
    return delegate->_feed;
}

+ (NSURL *)discoverFeedURLInHTML:(NSData *)data baseURL:(NSURL *)baseURL {
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html)
        html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!html.length)
        return nil;
    NSRegularExpression *links = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>"
                                                                           options:NSRegularExpressionCaseInsensitive error:NULL];
    NSRegularExpression *href = [NSRegularExpression regularExpressionWithPattern:@"\\bhref\\s*=\\s*[\"']([^\"']+)[\"']"
                                                                          options:NSRegularExpressionCaseInsensitive error:NULL];
    for (NSTextCheckingResult *match in [links matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *tag = [html substringWithRange:match.range];
        NSString *lower = tag.lowercaseString;
        if ([lower rangeOfString:@"alternate"].location == NSNotFound
            || ([lower rangeOfString:@"application/rss+xml"].location == NSNotFound
                && [lower rangeOfString:@"application/atom+xml"].location == NSNotFound))
            continue;
        NSTextCheckingResult *value = [href firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
        NSString *resolved = value ? NRSSResolve(NRSSDecodeEntities([tag substringWithRange:[value rangeAtIndex:1]]), baseURL) : nil;
        if (resolved)
            return [NSURL URLWithString:resolved];
    }
    return nil;
}

+ (NSString *)plainTextFromHTML:(NSString *)html {
    if (!html.length)
        return @"";
    static NSRegularExpression *blocks, *breaks, *tags, *spaces;
    if (!blocks) {
        blocks = [NSRegularExpression regularExpressionWithPattern:@"<(script|style)\\b[^>]*>.*?</\\1\\s*>"
                                                           options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:NULL];
        breaks = [NSRegularExpression regularExpressionWithPattern:@"<(br|/p|/div|/li|/h[1-6])\\b[^>]*>"
                                                           options:NSRegularExpressionCaseInsensitive error:NULL];
        tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:NULL];
        spaces = [NSRegularExpression regularExpressionWithPattern:@"[\\s\u00a0]+" options:0 error:NULL];
    }
    NSString *text = [blocks stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@" "];
    text = [breaks stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    text = [tags stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    text = NRSSDecodeEntities(text);
    text = [spaces stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    return NRSSTrim(text);
}

- (BOOL)inItem {
    return _item != nil;
}

- (NSString *)parentName {
    return _stack.count >= 2 ? [_stack objectAtIndex:_stack.count - 2] : nil;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary *)attributes {
    NSString *name = elementName.lowercaseString;
    if (_kind == NRSSKindUnknown) {
        if ([name isEqualToString:@"rss"])
            _kind = NRSSKindRSS;
        else if ([name isEqualToString:@"rdf:rdf"])
            _kind = NRSSKindRDF;
        else if ([name isEqualToString:@"feed"])
            _kind = NRSSKindAtom;
        else {
            [parser abortParsing];
            return;
        }
    }
    [_stack addObject:name];
    _text = [NSMutableString string];

    if ([name isEqualToString:@"item"] || [name isEqualToString:@"entry"]) {
        _item = [[NRSSItem alloc] init];
        _itemDescription = nil;
        _itemContent = nil;
        _itemHasPublished = NO;
        return;
    }

    NSString *type = [[attributes objectForKey:@"type"] lowercaseString];
    if ([name isEqualToString:@"link"] && [attributes objectForKey:@"href"]) { // Atom
        NSString *rel = [[attributes objectForKey:@"rel"] lowercaseString];
        NSString *href = NRSSResolve([attributes objectForKey:@"href"], _baseURL);
        if (self.inItem) {
            if ((!rel || [rel isEqualToString:@"alternate"]) && !_item.link)
                _item.link = href;
            else if ([rel isEqualToString:@"enclosure"] && [type hasPrefix:@"image/"] && !_item.imageURL)
                _item.imageURL = href;
        } else if ((!rel || [rel isEqualToString:@"alternate"]) && !_feed.siteURL) {
            _feed.siteURL = href;
        }
    } else if (self.inItem && [name isEqualToString:@"enclosure"] && [type hasPrefix:@"image/"] && !_item.imageURL) {
        _item.imageURL = NRSSResolve([attributes objectForKey:@"url"], _baseURL);
    } else if (self.inItem && ([name isEqualToString:@"media:thumbnail"]
                               || ([name isEqualToString:@"media:content"]
                                   && ([[attributes objectForKey:@"medium"] isEqualToString:@"image"] || [type hasPrefix:@"image/"]))) && !_item.imageURL) {
        _item.imageURL = NRSSResolve([attributes objectForKey:@"url"], _baseURL);
    } else if (!self.inItem && [name isEqualToString:@"itunes:image"] && !_feed.imageURL) {
        _feed.imageURL = NRSSResolve([attributes objectForKey:@"href"], _baseURL);
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock {
    NSString *string = [[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];
    if (string)
        [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName {
    NSString *name = elementName.lowercaseString;
    NSString *parent = self.parentName;
    NSString *text = NRSSTrim(_text ?: @"");
    _text = [NSMutableString string];

    if (self.inItem) {
        if ([name isEqualToString:@"item"] || [name isEqualToString:@"entry"]) {
            [self finishItem];
        } else if ([name isEqualToString:@"title"] && ([parent isEqualToString:@"item"] || [parent isEqualToString:@"entry"])) {
            _item.title = [NRSSFeedParser plainTextFromHTML:text];
        } else if ([name isEqualToString:@"link"] && text.length && !_item.link) {
            _item.link = NRSSResolve(text, _baseURL);
        } else if (([name isEqualToString:@"guid"] || [name isEqualToString:@"id"]) && text.length) {
            _item.identifier = text;
        } else if ([name isEqualToString:@"description"] || [name isEqualToString:@"summary"]) {
            _itemDescription = text;
        } else if ([name isEqualToString:@"content:encoded"] || [name isEqualToString:@"content"]) {
            _itemContent = text;
        } else if ([name isEqualToString:@"pubdate"] || [name isEqualToString:@"published"] || [name isEqualToString:@"dc:date"]) {
            NSDate *date = NRSSParseDate(text);
            if (date) {
                _item.date = date;
                _itemHasPublished = YES;
            }
        } else if ([name isEqualToString:@"updated"] && !_itemHasPublished) {
            _item.date = NRSSParseDate(text) ?: _item.date;
        } else if (([name isEqualToString:@"author"] || [name isEqualToString:@"dc:creator"]) && text.length && !_item.author) {
            _item.author = text;
        } else if ([name isEqualToString:@"name"] && [parent isEqualToString:@"author"] && text.length) {
            _item.author = text;
        }
    } else if ([name isEqualToString:@"title"] && ([parent isEqualToString:@"channel"] || [parent isEqualToString:@"feed"])) {
        if (!_feed.title.length)
            _feed.title = [NRSSFeedParser plainTextFromHTML:text];
    } else if ([name isEqualToString:@"link"] && [parent isEqualToString:@"channel"] && text.length && !_feed.siteURL) {
        _feed.siteURL = NRSSResolve(text, _baseURL);
    } else if ([name isEqualToString:@"url"] && [parent isEqualToString:@"image"] && !_feed.imageURL) {
        _feed.imageURL = NRSSResolve(text, _baseURL);
    } else if (([name isEqualToString:@"logo"] || ([name isEqualToString:@"icon"] && !_feed.imageURL)) && [parent isEqualToString:@"feed"]) {
        _feed.imageURL = NRSSResolve(text, _baseURL) ?: _feed.imageURL;
    }
    if (_stack.count)
        [_stack removeLastObject];
}

- (void)finishItem {
    NRSSItem *item = _item;
    _item = nil;
    item.html = _itemContent.length ? _itemContent : _itemDescription;
    NSString *summary = [NRSSFeedParser plainTextFromHTML:_itemDescription.length ? _itemDescription : _itemContent];
    item.summary = summary.length > 280 ? [[summary substringToIndex:279] stringByAppendingString:@"\u2026"] : summary;
    if (!item.imageURL)
        item.imageURL = NRSSFirstImageInHTML(item.html, item.link ? [NSURL URLWithString:item.link] : _baseURL);
    if (!item.title.length)
        item.title = item.summary.length > 80 ? [[item.summary substringToIndex:79] stringByAppendingString:@"\u2026"] : item.summary;
    if (!item.identifier.length)
        item.identifier = item.link ?: item.title;
    if (item.title.length || item.link.length)
        [_items addObject:item];
}

@end
