#import "NRSSArticleViewController.h"
#import "NRSSFeedParser.h"
#import "NRSSFetcher.h"
#import "NRSSShared.h"
#import "NRSSSpeechReader.h"

@interface NRSSArticleViewController () <UIWebViewDelegate, UIActionSheetDelegate>
@end

static NSString *NRSSEscapeHTML(NSString *string) {
    NSMutableString *escaped = [(string ?: @"") mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString *NRSSBase64(NSData *data) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = data.bytes;
    NSUInteger length = data.length;
    NSMutableData *encoded = [NSMutableData dataWithLength:(length + 2) / 3 * 4];
    char *out = encoded.mutableBytes;
    for (NSUInteger i = 0, o = 0; i < length; i += 3, o += 4) {
        unsigned value = bytes[i] << 16 | (i + 1 < length ? bytes[i + 1] << 8 : 0) | (i + 2 < length ? bytes[i + 2] : 0);
        out[o] = alphabet[(value >> 18) & 63];
        out[o + 1] = alphabet[(value >> 12) & 63];
        out[o + 2] = i + 1 < length ? alphabet[(value >> 6) & 63] : '=';
        out[o + 3] = i + 2 < length ? alphabet[value & 63] : '=';
    }
    return [[NSString alloc] initWithData:encoded encoding:NSASCIIStringEncoding];
}

static NSString *NRSSImageType(NSData *data) {
    const unsigned char *bytes = data.bytes;
    if (data.length >= 4 && bytes[0] == 0x89 && bytes[1] == 'P')
        return @"image/png";
    if (data.length >= 3 && bytes[0] == 'G' && bytes[1] == 'I' && bytes[2] == 'F')
        return @"image/gif";
    if (data.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8)
        return @"image/jpeg";
    return nil; // WebP, SVG, HTML error pages: nothing iOS 6 can show
}

@implementation NRSSArticleViewController {
    NRSSItem *_item;
    NSString *_feedTitle;
    UIWebView *_webView;
    BOOL _checkedImages;
    BOOL _articleLoaded;
    NRSSSpeechReader *_speechReader;
    UIBarButtonItem *_speechButton;
    UIBarButtonItem *_stopSpeechButton;
    UISegmentedControl *_speechSpeed;
}

- (instancetype)initWithItem:(NRSSItem *)item feedTitle:(NSString *)feedTitle {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _item = item;
        _feedTitle = [feedTitle copy];
        self.title = feedTitle;
    }
    return self;
}

- (void)loadView {
    _webView = [[UIWebView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    _webView.delegate = self;
    _webView.scalesPageToFit = NO;
    _webView.dataDetectorTypes = UIDataDetectorTypeNone;
    NSString *theme = NRSSPreference(NRSSReaderThemeKey, @"sepia");
    _webView.backgroundColor = [theme isEqualToString:@"dark"] ? [UIColor colorWithWhite:0.11 alpha:1]
        : [theme isEqualToString:@"light"] ? [UIColor whiteColor] : [UIColor colorWithRed:0.98 green:0.97 blue:0.95 alpha:1];
    _webView.opaque = NO;
    self.view = _webView;
    if (_item.link)
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                               target:self action:@selector(showActions)];
}

- (NSString *)articleHTML {
    // Scripts would run with the article's origin and slow the phone down; the text and images are what matter here.
    NSString *content = _item.html ?: @"";
    NSRegularExpression *scripts = [NSRegularExpression regularExpressionWithPattern:@"<script\\b[^>]*>.*?</script\\s*>|<script\\b[^>]*/>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:NULL];
    content = [scripts stringByReplacingMatchesInString:content options:0 range:NSMakeRange(0, content.length) withTemplate:@""];
    if ([content rangeOfString:@"<"].location == NSNotFound)
        content = [NSString stringWithFormat:@"<p>%@</p>", [NRSSEscapeHTML(content) stringByReplacingOccurrencesOfString:@"\n\n" withString:@"</p><p>"]];
    NSString *lead = @"";
    if (_item.imageURL && [content rangeOfString:_item.imageURL].location == NSNotFound)
        lead = [NSString stringWithFormat:@"<img class=\"lead\" src=\"%@\">", NRSSEscapeHTML(_item.imageURL)];

    NSMutableArray *meta = [NSMutableArray array];
    if (_item.author.length)
        [meta addObject:NRSSEscapeHTML(_item.author)];
    if (_item.date)
        [meta addObject:[NSDateFormatter localizedStringFromDate:_item.date dateStyle:NSDateFormatterLongStyle timeStyle:NSDateFormatterShortStyle]];
    NSString *more = _item.link
        ? [NSString stringWithFormat:@"<a class=\"more\" href=\"%@\">%@</a>", NRSSEscapeHTML(_item.link),
           NRSSLocalized(@"Read on the Website", @"Leer en el sitio web")]
        : @"";

    NSString *theme = NRSSPreference(NRSSReaderThemeKey, @"sepia");
    NSDictionary *colors = [theme isEqualToString:@"dark"]
        ? @{@"bg": @"#1c1c1e", @"text": @"#dcdcdc", @"title": @"#f2f2f2", @"meta": @"#8e8e93", @"accent": @"#ff8a65", @"box": @"#2c2c2e", @"line": @"#444"}
        : [theme isEqualToString:@"light"]
            ? @{@"bg": @"#ffffff", @"text": @"#222", @"title": @"#111", @"meta": @"#888", @"accent": @"#9b1b30", @"box": @"#f4f4f4", @"line": @"#ddd"}
            : @{@"bg": @"#faf8f2", @"text": @"#222", @"title": @"#111", @"meta": @"#888", @"accent": @"#9b1b30", @"box": @"#ffffff", @"line": @"#cfc8b8"};
    NSInteger textSize = MAX(13, MIN(26, NRSSIntegerPreference(NRSSReaderTextSizeKey, 17)));
    NSString *style = [NSString stringWithFormat:
        @"body{font:%ldpx/1.55 Georgia,serif;color:%@;background:%@;margin:0;padding:18px 15px 40px;"
        "-webkit-text-size-adjust:none;word-wrap:break-word}"
        ".kicker{font:bold 11px 'Helvetica Neue',Helvetica;letter-spacing:1px;text-transform:uppercase;color:%@}"
        "h1{font:bold %ldpx/1.2 'Helvetica Neue',Helvetica;margin:6px 0 8px;color:%@}"
        ".meta{font:13px 'Helvetica Neue',Helvetica;color:%@;margin-bottom:18px}"
        "a{color:%@}blockquote{margin:0 0 0 10px;padding-left:10px;border-left:3px solid %@;opacity:.85}"
        ".more{display:block;margin-top:28px;padding:12px;text-align:center;border:1px solid %@;border-radius:7px;"
        "font:bold 15px 'Helvetica Neue',Helvetica;text-decoration:none;color:%@;background:%@}",
        (long)textSize, colors[@"text"], colors[@"bg"], colors[@"accent"], (long)(textSize + 7), colors[@"title"], colors[@"meta"],
        colors[@"accent"], colors[@"line"], colors[@"line"], colors[@"text"], colors[@"box"]];

    return [NSString stringWithFormat:
        @"<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=4\">"
        "<style>%@"
        "img,video,iframe,embed,object{max-width:100%%!important;height:auto}"
        "img.lead{display:block;width:100%%;margin:0 0 16px}figure{margin:0 0 14px}figcaption{font:12px 'Helvetica Neue';opacity:.7}"
        "pre,code{white-space:pre-wrap;font-size:13px}table{max-width:100%%;display:block;overflow:auto}"
        "</style></head><body><div class=\"kicker\">%@</div><h1 id=\"nrss-title\">%@</h1><div class=\"meta\">%@</div>%@<div id=\"nrss-content\">%@</div>%@</body></html>",
        style, NRSSEscapeHTML(_feedTitle), NRSSEscapeHTML(_item.title), [meta componentsJoinedByString:@" · "], lead, content, more];
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _speechReader.stateDidChange = nil;
    [_speechReader stop];
    _webView.delegate = nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _speechReader = [[NRSSSpeechReader alloc] init];
    float savedSpeed = [[NSUserDefaults standardUserDefaults] floatForKey:@"NRSSSpeechSpeed"];
    _speechReader.speed = savedSpeed;
    __weak NRSSArticleViewController *weakSelf = self;
    _speechReader.stateDidChange = ^{ [weakSelf updateSpeechControls]; };
    _speechButton = [[UIBarButtonItem alloc] initWithTitle:NRSSLocalized(@"Read Aloud", @"Leer en voz alta")
        style:UIBarButtonItemStyleBordered target:self action:@selector(toggleSpeech)];
    _speechButton.width = 126;
    _speechSpeed = [[UISegmentedControl alloc] initWithItems:@[@"1×", @"1.5×", @"2×"]];
    _speechSpeed.frame = CGRectMake(0, 0, 120, 30);
    _speechSpeed.segmentedControlStyle = UISegmentedControlStyleBar;
    _speechSpeed.selectedSegmentIndex = _speechReader.speed == 2.0f ? 2 : _speechReader.speed == 1.5f ? 1 : 0;
    _speechSpeed.accessibilityLabel = NRSSLocalized(@"Reading speed", @"Velocidad de lectura");
    [_speechSpeed addTarget:self action:@selector(changeSpeechSpeed) forControlEvents:UIControlEventValueChanged];
    _stopSpeechButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop
        target:self action:@selector(stopSpeech)];
    _stopSpeechButton.accessibilityLabel = NRSSLocalized(@"Stop reading", @"Detener lectura");
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[_speechButton, space, [[UIBarButtonItem alloc] initWithCustomView:_speechSpeed],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], _stopSpeechButton];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pauseSpeechWhenInactive)
        name:UIApplicationWillResignActiveNotification object:nil];
    [self updateSpeechControls];
    NSURL *base = _item.link ? [NSURL URLWithString:_item.link] : nil;
    [_webView loadHTMLString:[self articleHTML] baseURL:base];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_speechReader stop];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)updateSpeechControls {
    NRSSSpeechState state = _speechReader.state;
    _speechButton.title = state == NRSSSpeechStateStopped ? NRSSLocalized(@"Read Aloud", @"Leer en voz alta")
        : state == NRSSSpeechStateSpeaking ? NRSSLocalized(@"Pause", @"Pausar") : NRSSLocalized(@"Resume", @"Reanudar");
    _speechButton.enabled = _articleLoaded && state != NRSSSpeechStatePausing;
    _stopSpeechButton.enabled = state != NRSSSpeechStateStopped;
    if (_speechReader.error)
        [[[UIAlertView alloc] initWithTitle:NRSSLocalized(@"Couldn't Read Aloud", @"No se pudo leer en voz alta")
            message:NRSSLocalized(@"Check that a voice is installed in Settings → General → Accessibility → Speak Selection.",
                @"Comprueba que haya una voz instalada en Ajustes → General → Accesibilidad → Leer selección.")
            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

- (void)toggleSpeech {
    if (_speechReader.state == NRSSSpeechStateSpeaking) {
        [_speechReader pause];
    } else if (_speechReader.state == NRSSSpeechStatePaused) {
        [_speechReader resume];
    } else if (_speechReader.state == NRSSSpeechStateStopped && _articleLoaded) {
        // innerText decodes entities and excludes hidden markup, metadata and the website button.
        NSString *text = [_webView stringByEvaluatingJavaScriptFromString:
            @"(function(){var t=document.getElementById('nrss-title'),b=document.getElementById('nrss-content');"
             "return (t?t.innerText:'')+'\\n\\n'+(b?b.innerText:'');})()"];
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!text.length)
            return;
        NSString *language = (__bridge_transfer NSString *)CFStringTokenizerCopyBestStringLanguage((__bridge CFStringRef)text,
            CFRangeMake(0, text.length));
        if (!language.length)
            language = [[NSLocale preferredLanguages] objectAtIndex:0];
        [_speechReader startText:text languageCode:language];
    }
}

- (void)changeSpeechSpeed {
    _speechReader.speed = _speechSpeed.selectedSegmentIndex == 2 ? 2.0f : _speechSpeed.selectedSegmentIndex == 1 ? 1.5f : 1.0f;
    [[NSUserDefaults standardUserDefaults] setFloat:_speechReader.speed forKey:@"NRSSSpeechSpeed"];
}

- (void)stopSpeech {
    [_speechReader stop];
}

- (void)pauseSpeechWhenInactive {
    [_speechReader pause];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    _articleLoaded = YES;
    [self updateSpeechControls];
    if (_checkedImages)
        return;
    _checkedImages = YES;
    [self performSelector:@selector(repairImages) withObject:nil afterDelay:1];
}

- (void)repairImages {
    UIWebView *webView = _webView;
    // UIWebView uses iOS 6's TLS, which many image hosts no longer accept. Images that failed are downloaded
    // through NRSSFetcher (which falls back to BearSSL) and swapped in as data: URLs.
    NSString *json = [webView stringByEvaluatingJavaScriptFromString:
        @"(function(){var s=[],i=document.images;for(var n=0;n<i.length;n++){var u=i[n].src;"
         "if(u.indexOf('https:')==0&&(!i[n].complete||i[n].naturalWidth==0)&&s.indexOf(u)<0)s.push(u);}return JSON.stringify(s.slice(0,25));})()"];
    NSArray *sources = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    __weak UIWebView *weakWebView = webView;
    for (NSString *source in [sources isKindOfClass:[NSArray class]] ? sources : nil) {
        NSURL *url = [NSURL URLWithString:source];
        if (!url)
            continue;
        [NRSSFetcher fetchURL:url completion:^(NSData *data, NSURL *finalURL, NSError *error) {
            NSString *type = data.length < 6 * 1024 * 1024 ? NRSSImageType(data) : nil;
            if (!type || !weakWebView)
                return;
            NSData *quoted = [NSJSONSerialization dataWithJSONObject:@[source] options:0 error:NULL];
            NSString *literal = [[NSString alloc] initWithData:quoted encoding:NSUTF8StringEncoding];
            [weakWebView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:
                @"(function(u,d){var i=document.images;for(var n=0;n<i.length;n++)if(i[n].src==u){i[n].removeAttribute('srcset');i[n].src=d;}})(%@[0],'data:%@;base64,%@')",
                literal, type, NRSSBase64(data)]];
        }];
    }
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)type {
    // The article itself is the only page shown here; every tapped link opens in Safari.
    if (type == UIWebViewNavigationTypeLinkClicked) {
        [[UIApplication sharedApplication] openURL:request.URL];
        return NO;
    }
    return YES;
}

- (void)showActions {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:self
                                              cancelButtonTitle:NRSSLocalized(@"Cancel", @"Cancelar") destructiveButtonTitle:nil
                                              otherButtonTitles:NRSSLocalized(@"Open in Safari", @"Abrir en Safari"),
                                                                NRSSLocalized(@"Copy Link", @"Copiar enlace"), nil];
    [sheet showFromBarButtonItem:self.navigationItem.rightBarButtonItem animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index == sheet.firstOtherButtonIndex)
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:_item.link]];
    else if (index == sheet.firstOtherButtonIndex + 1)
        [UIPasteboard generalPasteboard].string = _item.link;
}

@end
