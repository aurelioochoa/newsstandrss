// Device integration test. Run as mobile on iOS 6; exercises the real VoiceServices engine.
#import <Foundation/Foundation.h>
#import "NRSSSpeechReader.h"

@interface NSObject (NRSSSpeechTest)
- (float)rate;
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
    NSLog(@"PASS: %@", message);
}

static BOOL waitFor(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return condition();
}

int main(void) {
    @autoreleasepool {
        NRSSSpeechReader *reader = [[NRSSSpeechReader alloc] init];
        NSString *text = @"Esta es una prueba de lectura en voz alta. Vamos a escuchar un artículo completo, "
            "pausar la lectura y continuar desde el mismo punto. También vamos a cambiar la velocidad "
            "sin regresar al principio del artículo ni perder las palabras que todavía faltan por leer.";
        require(reader.state == NRSSSpeechStateStopped && reader.speed == 1, @"starts stopped at 1×");
        [reader startText:@"" languageCode:@"es"];
        require(reader.state == NRSSSpeechStateStopped, @"empty text stays stopped");
        [reader startText:text languageCode:@"es"];
        require(waitFor(10, ^BOOL{ return [[reader valueForKey:@"position"] unsignedIntegerValue] > 10 || reader.error != nil; })
            && !reader.error && reader.state == NRSSSpeechStateSpeaking, @"Spanish speech advances through real word callbacks");
        [reader pause];
        require(waitFor(3, ^BOOL{ return reader.state == NRSSSpeechStatePaused; }), @"native pause completes");
        NSUInteger position = [[reader valueForKey:@"position"] unsignedIntegerValue];
        waitFor(0.5, ^BOOL{ return NO; });
        require([[reader valueForKey:@"position"] unsignedIntegerValue] == position, @"paused position does not advance");
        [reader resume];
        require(waitFor(3, ^BOOL{ return [[reader valueForKey:@"position"] unsignedIntegerValue] > position; }), @"native resume continues from paused position");
        position = [[reader valueForKey:@"position"] unsignedIntegerValue];
        reader.speed = 1.5f;
        id synth = [reader valueForKey:@"synthesizer"];
        require(reader.state == NRSSSpeechStateSpeaking && [synth rate] == 1.5f
            && [[reader valueForKey:@"utteranceOffset"] unsignedIntegerValue] >= position, @"1.5× applies during playback without restarting the article");
        [reader pause];
        require(waitFor(3, ^BOOL{ return reader.state == NRSSSpeechStatePaused; }), @"pause after speed change");
        position = [[reader valueForKey:@"position"] unsignedIntegerValue];
        reader.speed = 2.0f;
        require(reader.state == NRSSSpeechStatePaused, @"changing to 2× keeps playback paused");
        [reader resume];
        synth = [reader valueForKey:@"synthesizer"];
        require([synth rate] == 2 && [[reader valueForKey:@"utteranceOffset"] unsignedIntegerValue] == position,
            @"resume uses 2× at the saved word");
        require(waitFor(3, ^BOOL{ return [[reader valueForKey:@"position"] unsignedIntegerValue] > position; })
            && reader.state == NRSSSpeechStateSpeaking, @"old cancellation callbacks cannot stop new playback");
        reader.speed = 0;
        require(reader.speed == 2, @"invalid speed is ignored");
        [reader stop];
        require(reader.state == NRSSSpeechStateStopped && [reader valueForKey:@"synthesizer"] == nil,
            @"stop releases speech and resets controls");
        [reader startText:@"Hola." languageCode:@"es"];
        require(waitFor(5, ^BOOL{ return reader.state == NRSSSpeechStateStopped; }) && !reader.error,
            @"natural completion returns to stopped");
        [reader startText:text languageCode:@"es"];
        [reader stop];
        [reader startText:@"Hello." languageCode:@"en"];
        require(waitFor(5, ^BOOL{ return reader.state == NRSSSpeechStateStopped; }) && !reader.error,
            @"rapid stop and restart completes in English");
        NSLog(@"SPEECH_TESTS_PASSED");
    }
    return 0;
}
