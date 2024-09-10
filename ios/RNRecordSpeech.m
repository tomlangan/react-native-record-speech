#import "RNRecordSpeech.h"
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTConvert.h>
#import <React/RCTBridge.h>
#import <React/RCTUtils.h>
#import <React/RCTEventDispatcher.h>
#import "AudioProcessing.h"

@implementation RNRecordSpeech

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
    _recordState.detectionMethod                = options[@"detectionMethod"] ?: @"volume_threshold";
    _recordState.detectionParams                = options[@"detectionParams"];

    _recordState.bufferByteSize = 2048;
    _recordState.mSelf = self;
    _recordState.frameNumber = 0;

    NSString *fileName = options[@"wavFile"] == nil ? @"audio.wav" : options[@"wavFile"];
    NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    _filePath = [NSString stringWithFormat:@"%@/%@", docDir, fileName];
    
    _progressUpdateInterval = [options[@"monitorInterval"] intValue] ?: 250;
}

RCT_EXPORT_METHOD(start)
{
    RCTLogInfo(@"start");

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];

    _recordState.mIsRunning = true;
    _recordState.mCurrentPacket = 0;
    _recordState.frameNumber = 0;

    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
    AudioFileCreateWithURL(url, kAudioFileWAVEType, &_recordState.mDataFormat, kAudioFileFlags_EraseFile, &_recordState.mAudioFile);
    CFRelease(url);

    AudioQueueNewInput(&_recordState.mDataFormat, HandleInputBuffer, &_recordState, NULL, NULL, 0, &_recordState.mQueue);
    for (int i = 0; i < kNumberBuffers; i++) {
        AudioQueueAllocateBuffer(_recordState.mQueue, _recordState.bufferByteSize, &_recordState.mBuffers[i]);
        AudioQueueEnqueueBuffer(_recordState.mQueue, _recordState.mBuffers[i], 0, NULL);
    }
    AudioQueueStart(_recordState.mQueue, NULL);
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
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    
    resolve(_filePath);
    unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
    RCTLogInfo(@"file path %@", _filePath);
    RCTLogInfo(@"file size %llu", fileSize);
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"frame"];
}

void throwRNException(NSString *message, NSInteger code) {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: message
    };
    NSError *error = [NSError errorWithDomain:@"RNRecordSpeechErrorDomain"
                                         code:code
                                     userInfo:userInfo];
    RCTFatal(error);
}

// Take a raw buffer, calculate the audio level, and return a speech probability
- (float)detectSpeechWithLevel:(NSData *)data
{
    float defaultThreshold = -30.0f;

    // Get the volume threshold from the options or use the default
    float threshold = [_recordState.detectionParams[@"threshold"] floatValue]?: defaultThreshold;

    // Calculate the current audio level using our new utility function
    float currentLevel = calculateAudioLevel(data, _recordState.mDataFormat);

    // Simple speech detection based on volume threshold
    float speechProbability = (currentLevel > threshold) ? 0.8f : 0.2f;  // Simplified example

    NSDictionary *result = @{
        @"speechProbability": @(speechProbability),
        @"info": @{
            @"level": @(currentLevel),
        }
    };

    // Assuming this is part of a method that returns an NSDictionary
    return result;
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

    NSDictionary *result = @{
        @"speechProbability": @(0.0f),
        @"info": @{@"level": @(-160.0f)}
    };
    
    if ([pRecordState->detectionMethod isEqualToString:@"volume_threshold"]) {
        result = [(id)pRecordState->mSelf detectSpeechWithLevel:audioData];
    } else {
        throwRNException(@"Invalid detection method", 1);
    }

    // Encode audio data
    NSData *data = [NSData dataWithBytes:inBuffer->mAudioData length:inBuffer->mAudioDataByteSize];
    NSString *str = [data base64EncodedStringWithOptions:0];

    // Send a single event with frame number, audio data, speech probability, and debug info
    [pRecordState->mSelf sendEventWithName:@"frame" body:@{
        @"frameNumber": @(pRecordState->frameNumber),
        @"audioData": str,
        @"speechProbability": result[@"speechProbability"],
        @"info": result[@"info"]
    }];

    // Increment frame number
    pRecordState->frameNumber++;

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
}

@end