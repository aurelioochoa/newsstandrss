#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, NRSSSpeechState) {
    NRSSSpeechStateStopped,
    NRSSSpeechStateSpeaking,
    NRSSSpeechStatePausing,
    NRSSSpeechStatePaused
};

@interface NRSSSpeechReader : NSObject
@property (nonatomic, readonly) NRSSSpeechState state;
@property (nonatomic) float speed;
@property (nonatomic, readonly) NSError *error;
@property (nonatomic, copy) void (^stateDidChange)(void);
- (void)startText:(NSString *)text languageCode:(NSString *)languageCode;
- (void)pause;
- (void)resume;
- (void)stop;
@end
