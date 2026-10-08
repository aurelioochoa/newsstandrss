#import "NRSSSpeechReader.h"
#import <dlfcn.h>

// AVSpeechSynthesizer arrived in iOS 7. VoiceServices supplies speech on iOS 6.
@interface VSSpeechSynthesizer : NSObject
- (void)setDelegate:(id)delegate;
- (id)setRate:(float)rate;
- (id)startSpeakingString:(NSString *)text withLanguageCode:(NSString *)languageCode;
- (id)pauseSpeakingAtNextBoundary:(int)boundary;
- (id)continueSpeaking;
- (id)stopSpeakingAtNextBoundary:(int)boundary;
@end

@implementation NRSSSpeechReader {
    VSSpeechSynthesizer *_synthesizer;
    NSString *_text;
    NSString *_languageCode;
    NSUInteger _position;
    NSUInteger _utteranceOffset;
    BOOL _started;
}

- (instancetype)init {
    if ((self = [super init]))
        _speed = 1.0f;
    return self;
}

- (void)dealloc {
    [_synthesizer setDelegate:nil];
    [_synthesizer stopSpeakingAtNextBoundary:0];
}

- (void)notifyStateChanged {
    if (self.stateDidChange)
        self.stateDidChange();
}

- (void)discardSynthesizer {
    // A replaced synthesizer must not deliver an old finish callback to this reader.
    VSSpeechSynthesizer *old = _synthesizer;
    _synthesizer = nil;
    _started = NO;
    [old setDelegate:nil];
    [old stopSpeakingAtNextBoundary:0];
}

- (void)failWithError:(NSError *)error {
    [self stop];
    _error = error;
    [self notifyStateChanged];
}

- (void)speakFromPosition {
    static Class synthClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/VoiceServices.framework/VoiceServices", RTLD_NOW);
        synthClass = NSClassFromString(@"VSSpeechSynthesizer");
    });
    _synthesizer = [[synthClass alloc] init];
    if (!_synthesizer) {
        [self failWithError:[NSError errorWithDomain:@"NewsstandRSS.Speech" code:1 userInfo:nil]];
        return;
    }
    [_synthesizer setDelegate:self];
    [_synthesizer setRate:_speed];
    _utteranceOffset = _position;
    _state = NRSSSpeechStateSpeaking;
    id result = [_synthesizer startSpeakingString:[_text substringFromIndex:_position] withLanguageCode:_languageCode];
    if ([result isKindOfClass:[NSError class]])
        [self failWithError:result];
    else
        [self notifyStateChanged];
}

- (void)startText:(NSString *)text languageCode:(NSString *)languageCode {
    [self stop];
    _error = nil;
    _text = [text copy];
    _languageCode = [languageCode copy];
    if (_text.length)
        [self speakFromPosition];
}

- (void)setSpeed:(float)speed {
    if (speed != 1.0f && speed != 1.5f && speed != 2.0f)
        return;
    if (_speed == speed)
        return;
    _speed = speed;
    if (_state == NRSSSpeechStateStopped)
        return;
    BOOL speaking = _state == NRSSSpeechStateSpeaking;
    // setRate: configures the next speech job. Restart at the current word to apply it now.
    [self discardSynthesizer];
    if (speaking)
        [self speakFromPosition];
    else {
        _state = NRSSSpeechStatePaused;
        [self notifyStateChanged];
    }
}

- (void)pause {
    if (_state != NRSSSpeechStateSpeaking)
        return;
    _state = NRSSSpeechStatePausing;
    // A speed change creates a new job; wait until that job has actually started before pausing it.
    if (_started)
        [self pauseSynthesizer];
    else
        [self notifyStateChanged];
}

- (void)pauseSynthesizer {
    id result = [_synthesizer pauseSpeakingAtNextBoundary:0];
    if ([result isKindOfClass:[NSError class]])
        [self failWithError:result];
    else
        [self notifyStateChanged];
}

- (void)resume {
    if (_state != NRSSSpeechStatePaused)
        return;
    if (!_synthesizer) {
        [self speakFromPosition];
        return;
    }
    _state = NRSSSpeechStateSpeaking;
    id result = [_synthesizer continueSpeaking];
    if ([result isKindOfClass:[NSError class]])
        [self failWithError:result];
    else
        [self notifyStateChanged];
}

- (void)stop {
    [self discardSynthesizer];
    _state = NRSSSpeechStateStopped;
    _text = nil;
    _languageCode = nil;
    _position = 0;
    _utteranceOffset = 0;
    _error = nil;
    [self notifyStateChanged];
}

- (void)speechSynthesizerDidStartSpeaking:(VSSpeechSynthesizer *)synthesizer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (synthesizer != self->_synthesizer)
            return;
        self->_started = YES;
        if (self->_state == NRSSSpeechStatePausing)
            [self pauseSynthesizer];
    });
}

- (void)speechSynthesizerDidPauseSpeaking:(VSSpeechSynthesizer *)synthesizer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (synthesizer != self->_synthesizer || self->_state != NRSSSpeechStatePausing)
            return;
        self->_state = NRSSSpeechStatePaused;
        [self notifyStateChanged];
    });
}

- (void)speechSynthesizer:(VSSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)range {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (synthesizer == self->_synthesizer && self->_state != NRSSSpeechStatePaused
            && range.location < self->_text.length - self->_utteranceOffset)
            self->_position = self->_utteranceOffset + range.location;
    });
}

- (void)speechSynthesizer:(VSSpeechSynthesizer *)synthesizer didFinishSpeaking:(BOOL)finished withError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (synthesizer != self->_synthesizer)
            return;
        if (error)
            [self failWithError:error];
        else
            [self stop];
    });
}

@end
