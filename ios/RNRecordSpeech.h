#import <AVFoundation/AVFoundation.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>

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
} AQRecordState;

@interface RNAudioRecordAndLevel : RCTEventEmitter <RCTBridgeModule, AVAudioRecorderDelegate>
    @property (nonatomic, assign) AQRecordState recordState;
    @property (nonatomic, strong) NSString* filePath;
    @property (nonatomic, strong) AVAudioRecorder *audioRecorder;
    @property (nonatomic, strong) CADisplayLink *progressUpdateTimer;
    @property (nonatomic, assign) int frameId;
    @property (nonatomic, assign) int progressUpdateInterval;
    @property (nonatomic, strong) NSDate *prevProgressUpdateTime;
    @property (nonatomic, strong) AVAudioSession *recordSession;
@end

