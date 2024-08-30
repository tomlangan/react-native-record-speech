#import "RNAudioRecordAndLevel.h"
#import <React/RCTConvert.h>
#import <React/RCTBridge.h>
#import <React/RCTUtils.h>
#import <React/RCTEventDispatcher.h>

@implementation RNAudioRecordAndLevel

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(init:(NSDictionary *)options)
{
    RCTLogInfo(@"init");
    _recordState.mDataFormat.mSampleRate        = options[@"sampleRate"] == nil ? 44100 : [options[@"sampleRate"] doubleValue];
    _recordState.mDataFormat.mBitsPerChannel    = options[@"bitsPerSample"] == nil ? 16 : [options[@"bitsPerSample"] unsignedIntValue];
    _recordState.mDataFormat.mChannelsPerFrame  = options[@"channels"] == nil ? 1 : [options[@"channels"] unsignedIntValue];
    _recordState.mDataFormat.mBytesPerPacket    = (_recordState.mDataFormat.mBitsPerChannel / 8) * _recordState.mDataFormat.mChannelsPerFrame;
    _recordState.mDataFormat.mBytesPerFrame     = _recordState.mDataFormat.mBytesPerPacket;
    _recordState.mDataFormat.mFramesPerPacket   = 1;
    _recordState.mDataFormat.mReserved          = 0;
    _recordState.mDataFormat.mFormatID          = kAudioFormatLinearPCM;
    _recordState.mDataFormat.mFormatFlags       = _recordState.mDataFormat.mBitsPerChannel == 8 ? kLinearPCMFormatFlagIsPacked : (kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked);

    _recordState.bufferByteSize = 2048;
    _recordState.mSelf = self;

    NSString *fileName = options[@"wavFile"] == nil ? @"audio.wav" : options[@"wavFile"];
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    _filePath = [NSString stringWithFormat:@"%@/%@", docDir, fileName];
    
    _progressUpdateInterval = [options[@"monitorInterval"] intValue] ?: 250;
}

RCT_EXPORT_METHOD(on:(NSString *)eventName)
{
    // This method is just for logging purposes on the native side
    RCTLogInfo(@"Registered listener for event: %@", eventName);
}

RCT_EXPORT_METHOD(start)
{
    RCTLogInfo(@"start");

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];

    _recordState.mIsRunning = true;
    _recordState.mCurrentPacket = 0;

    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
    AudioFileCreateWithURL(url, kAudioFileWAVEType, &_recordState.mDataFormat, kAudioFileFlags_EraseFile, &_recordState.mAudioFile);
    CFRelease(url);

    AudioQueueNewInput(&_recordState.mDataFormat, HandleInputBuffer, &_recordState, NULL, NULL, 0, &_recordState.mQueue);
    for (int i = 0; i < kNumberBuffers; i++) {
        AudioQueueAllocateBuffer(_recordState.mQueue, _recordState.bufferByteSize, &_recordState.mBuffers[i]);
        AudioQueueEnqueueBuffer(_recordState.mQueue, _recordState.mBuffers[i], 0, NULL);
    }
    AudioQueueStart(_recordState.mQueue, NULL);

    [self startProgressTimer];
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
    RCTLogInfo(@"stop");
    if (_recordState.mIsRunning) {
        _recordState.mIsRunning = false;
        AudioQueueStop(_recordState.mQueue, true);
        AudioQueueDispose(_recordState.mQueue, true);
        AudioFileClose(_recordState.mAudioFile);
    }
    [self stopProgressTimer];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    
    resolve(_filePath);
    unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
    RCTLogInfo(@"file path %@", _filePath);
    RCTLogInfo(@"file size %llu", fileSize);
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"data"];
}

- (void)startProgressTimer
{
    [self stopProgressTimer];
    self.progressUpdateTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(sendProgressUpdate)];
    [self.progressUpdateTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)stopProgressTimer
{
    [self.progressUpdateTimer invalidate];
    self.progressUpdateTimer = nil;
}

- (void)sendProgressUpdate
{
    if (!_recordState.mIsRunning) {
        return;
    }

    if (self.prevProgressUpdateTime == nil ||
        (([self.prevProgressUpdateTime timeIntervalSinceNow] * -1000.0) >= self.progressUpdateInterval)) {
        self.frameId++;
        
        float currentLevel = [self getCurrentAudioLevel];
        
        [self sendEventWithName:@"level" body:@{
            @"id": @(self.frameId),
            @"value": @(currentLevel),
            @"rawValue": @(currentLevel)
        }];

        self.prevProgressUpdateTime = [NSDate date];
    }
}

- (float)getCurrentAudioLevel
{
    float currentLevel = -160.0f;
    if (_recordState.mQueue != NULL) {
        UInt32 propertySize = sizeof(AudioQueueLevelMeterState);
        AudioQueueLevelMeterState levelMeter;
        AudioQueueGetProperty(_recordState.mQueue, kAudioQueueProperty_CurrentLevelMeterDB, &levelMeter, &propertySize);
        currentLevel = levelMeter.mAveragePower;
    }
    return currentLevel;
}

void HandleInputBuffer(void *inUserData,
                       AudioQueueRef inAQ,
                       AudioQueueBufferRef inBuffer,
                       const AudioTimeStamp *inStartTime,
                       UInt32 inNumPackets,
                       const AudioStreamPacketDescription *inPacketDesc)
{
    AQRecordState* pRecordState = (AQRecordState *)inUserData;

    if (!pRecordState->mIsRunning) {
        return;
    }

    // Write audio data to file
    if (AudioFileWritePackets(pRecordState->mAudioFile,
                              false,
                              inBuffer->mAudioDataByteSize,
                              inPacketDesc,
                              pRecordState->mCurrentPacket,
                              &inNumPackets,
                              inBuffer->mAudioData
                              ) == noErr) {
        pRecordState->mCurrentPacket += inNumPackets;
    }

    // Calculate the current audio level
    float currentLevel = -160.0f;
    UInt32 propertySize = sizeof(AudioQueueLevelMeterState);
    AudioQueueLevelMeterState levelMeter;
    if (AudioQueueGetProperty(pRecordState->mQueue, kAudioQueueProperty_CurrentLevelMeterDB, &levelMeter, &propertySize) == noErr) {
        currentLevel = levelMeter.mAveragePower;
    }

    // Encode audio data and include the level in the event payload
    NSData *data = [NSData dataWithBytes:inBuffer->mAudioData length:inBuffer->mAudioDataByteSize];
    NSString *str = [data base64EncodedStringWithOptions:0];
    [pRecordState->mSelf sendEventWithName:@"data" body:@{
        @"audioData": str,
        @"level": @(currentLevel)
    }];

    // Re-enqueue the buffer for continued recording
    AudioQueueEnqueueBuffer(pRecordState->mQueue, inBuffer, 0, NULL);
}

- (void)dealloc
{
    RCTLogInfo(@"dealloc");

    // Ensure that recording is stopped if it is still running
    if (_recordState.mIsRunning) {
        [self stop:nil rejecter:nil];
    }

    // Dispose of the audio queue
    if (_recordState.mQueue != NULL) {
        AudioQueueDispose(_recordState.mQueue, true);
        _recordState.mQueue = NULL;
    }

    // Stop the progress timer if it is still running
    [self stopProgressTimer];
}

@end