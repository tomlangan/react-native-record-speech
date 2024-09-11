#import <AVFoundation/AVFoundation.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <AudioToolbox/AudioToolbox.h>

#define kNumberBuffers 3

typedef struct {
    __unsafe_unretained id      mSelf;
    AudioStreamBasicDescription mDataFormat;
    AudioQueueRef               mQueue;
    AudioQueueBufferRef         mBuffers[kNumberBuffers];
    AudioFileID                 mAudioFile;
    UInt32                      bufferByteSize;
    SInt64                      mCurrentPacket;
    bool                        mIsRunning;
    UInt32                      frameNumber;
    NSString*                   detectionMethod;
    NSDictionary*               detectionParams;
    AudioComponentInstance      audioUnit;
} AQRecordState;

#ifdef RCT_NEW_ARCH_ENABLED
#import "RNRecordSpeechSpec.h"

@interface RNRecordSpeech : NSObject <NativeRecordSpeechSpec>
#else
#import <React/RCTBridgeModule.h>

@interface RNRecordSpeech : RCTEventEmitter <RCTBridgeModule, AVAudioRecorderDelegate>
#endif


@property (nonatomic, assign) AQRecordState recordState;
@property (nonatomic, strong) NSString* filePath;
@property (nonatomic, strong) CADisplayLink *progressUpdateTimer;
@property (nonatomic, assign) int timeSlice;
@property (nonatomic, strong) NSDate *prevProgressUpdateTime;
@property (nonatomic, strong) NSDictionary *features;
@property (nonatomic, strong) AVAudioEngine *audioEngine;

- (void)init:(NSDictionary *)options;
- (void)start;
- (void)stop:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;

@end