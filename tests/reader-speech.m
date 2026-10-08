// UI controls and rendered-text probes, included only in diagnostic Reader builds.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "../app/NRSSArticleViewController.h"
#import "../app/NRSSSpeechReader.h"
#import "../app/NRSSAppDelegate.h"
#import "NRSSFeedParser.h"

static __weak NRSSArticleViewController *lastArticle;

static void NRSSReaderTestRequested(CFNotificationCenterRef center, void *observer, CFStringRef name,
    const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:@"/tmp/nrss-reader-test.plist"];
        NSString *operation = request[@"op"];
        UIWindow *window = ((NRSSAppDelegate *)[UIApplication sharedApplication].delegate).window;
        UINavigationController *navigation = (id)window.rootViewController;
        if ([operation isEqualToString:@"fixture"]) {
            NRSSItem *item = [[NRSSItem alloc] init];
            item.title = @"Una noticia & su lectura";
            item.author = @"METADATA_EXCLUDED";
            item.html = @"<p>Este artículo prueba la lectura en voz alta &amp; los controles de velocidad.</p>"
                "<p>Podemos pausar y reanudar desde el mismo punto. El lector permite escuchar cada noticia "
                "a velocidad normal, una vez y media o al doble de velocidad.</p>"
                "<p style='display:none'>HIDDEN_EXCLUDED</p>";
            NSMutableString *body = [item.html mutableCopy];
            for (NSUInteger i = 0; i < 8; i++)
                [body appendString:@"<p>La lectura sigue con más información sobre esta noticia. Cada párrafo "
                    "forma parte del artículo y debe escucharse en orden. Los controles permiten cambiar la velocidad "
                    "y continuar escuchando sin regresar al comienzo.</p>"];
            item.html = body;
            item.link = @"https://example.com/";
            NRSSArticleViewController *fixture = [[NRSSArticleViewController alloc] initWithItem:item feedTitle:@"FEED_EXCLUDED"];
            [navigation pushViewController:fixture animated:NO];
            lastArticle = fixture;
        }
        NRSSArticleViewController *article = [navigation.topViewController isKindOfClass:[NRSSArticleViewController class]]
            ? (id)navigation.topViewController : lastArticle;
        [article view];
        NRSSSpeechReader *reader = [article valueForKey:@"speechReader"];
        UIBarButtonItem *play = [article valueForKey:@"speechButton"];
        UIBarButtonItem *stop = [article valueForKey:@"stopSpeechButton"];
        UISegmentedControl *speed = [article valueForKey:@"speechSpeed"];
        if ([operation isEqualToString:@"toggle"])
            [[UIApplication sharedApplication] sendAction:play.action to:play.target from:play forEvent:nil];
        else if ([operation isEqualToString:@"speed"]) {
            speed.selectedSegmentIndex = [request[@"index"] integerValue];
            [speed sendActionsForControlEvents:UIControlEventValueChanged];
        } else if ([operation isEqualToString:@"stop"])
            [[UIApplication sharedApplication] sendAction:stop.action to:stop.target from:stop forEvent:nil];
        else if ([operation isEqualToString:@"inactive"])
            [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationWillResignActiveNotification object:nil];
        else if ([operation isEqualToString:@"back"]) {
            // Retain the article until its stopped state has been captured below.
            [navigation popViewControllerAnimated:NO];
        } else if ([operation isEqualToString:@"screenshot"]) {
            UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 0);
            [window.layer renderInContext:UIGraphicsGetCurrentContext()];
            [UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()) writeToFile:@"/tmp/nrss-reader-screen.png" atomically:YES];
            UIGraphicsEndImageContext();
        }
        // Even nonanimated navigation finishes its view lifecycle on a later run-loop turn.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSMutableDictionary *result = [@{@"op": operation ?: @"", @"requestID": request[@"requestID"] ?: @"", @"article": @(article != nil),
                @"toolbarHidden": @(navigation.toolbarHidden)} mutableCopy];
            if (article) {
                result[@"state"] = @(reader.state);
                result[@"speed"] = @(reader.speed);
                result[@"playTitle"] = play.title ?: @"";
                result[@"playEnabled"] = @(play.enabled);
                result[@"stopEnabled"] = @(stop.enabled);
                result[@"position"] = [reader valueForKey:@"position"] ?: @0;
                result[@"spokenText"] = [reader valueForKey:@"text"] ?: @"";
                result[@"language"] = [reader valueForKey:@"languageCode"] ?: @"";
                result[@"error"] = reader.error.description ?: @"";
                result[@"selectedSpeed"] = @(speed.selectedSegmentIndex);
                result[@"toolbarFrame"] = NSStringFromCGRect(navigation.toolbar.frame);
            }
            [result writeToFile:@"/tmp/nrss-reader-test-result.plist" atomically:YES];
        });
    });
}

@interface NRSSReaderSpeechTest : NSObject
@end

@implementation NRSSReaderSpeechTest
+ (void)load {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NRSSReaderTestRequested,
        CFSTR("com.aurelio.newsstandrss/reader-test"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}
@end
