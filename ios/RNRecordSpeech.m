#import "RNRecordSpeech.h"
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTConvert.h>
#import <React/RCTBridge.h>
#import <React/RCTUtils.h>
#import <React/RCTEventDispatcher.h>
#import "AudioProcessing.h"

@implementation RNRecordSpeech
    NSMutableData *accumulatedData;
    NSInteger accumulatedSamples;
    NSInteger samplesPerTimeSlice;

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(init:(NSDictionary *)options)
{
    
    RCTLogInfo(@"init");
    _recordState.mDataFormat.mSampleRate        = options[@"sampleRate"] ? [options[@"sampleRate"] doubleValue] : 44100;
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
    
    _timeSlice = options[@"timeSlice"] ? [options[@"timeSlice"] intValue] : 400;
    samplesPerTimeSlice = (_recordState.mDataFormat.mSampleRate * _timeSlice) / 1000;
    accumulatedData = [NSMutableData data];
    accumulatedSamples = 0;

    self.features = options[@"features"] ?: @{};

    [self setupAudioSession];
}

- (BOOL)isFeatureEnabled:(NSString *)featureName defaultValue:(BOOL)defaultValue {
    id featureValue = self.features[featureName];
    
    if ([featureValue isKindOfClass:[NSNumber class]]) {
        return [featureValue boolValue];
    } else if ([featureValue isKindOfClass:[NSString class]]) {
        return [featureValue boolValue];
    }
    
    return defaultValue;
}


- (void)setupAudioSession
{
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];

    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionMixWithOthers;
    
    [session setCategory:AVAudioSessionCategoryPlayAndRecord 
             withOptions:options
                   error:&error];
    if (error) {
        RCTLogError(@"Error setting AVAudioSession category: %@", error);
        return;
    }

    if ([self isFeatureEnabled:@"echoCancellation" defaultValue:NO]) {
        [session setMode:AVAudioSessionModeVoiceChat error:&error];
    } else {
        [session setMode:AVAudioSessionModeDefault error:&error];
    }
    if (error) {
        RCTLogError(@"Error setting AVAudioSession mode: %@", error);
        return;
    }

    [session setActive:YES error:&error];
    if (error) {
        RCTLogError(@"Error activating AVAudioSession: %@", error);
        return;
    }
}


- (void)setupAudioEngineWithAEC
{
    if (!self.audioEngine) {
        self.audioEngine = [[AVAudioEngine alloc] init];
    }

    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    
    // Enable voice processing on the input node if available
    if ([inputNode respondsToSelector:@selector(setVoiceProcessingEnabled:error:)]) {
        NSError *error = nil;
        if (![inputNode setVoiceProcessingEnabled:YES error:&error]) {
            RCTLogError(@"Failed to enable voice processing: %@", error);
        }
    } else {
        RCTLogWarn(@"Voice processing is not available on this device");
    }

    // Ensure the input is connected to the main mixer
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    [self.audioEngine connect:inputNode to:self.audioEngine.mainMixerNode format:inputFormat];

    // Prepare the engine
    NSError *error = nil;
    if (![self.audioEngine startAndReturnError:&error]) {
        RCTLogError(@"Error starting audio engine: %@", error);
    }
}

- (void)setupAudioUnit {
    if (![self isFeatureEnabled:@"noiseReduction" defaultValue:NO]) {
        return; // Skip Audio Unit setup if noise reduction is not enabled
    }

    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Effect;
    desc.componentSubType = kAudioUnitSubType_HighPassFilter;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    OSStatus status = AudioComponentInstanceNew(component, &_recordState.audioUnit);
    if (status != noErr) {
        RCTLogError(@"Error creating Audio Unit: %d", (int)status);
        return;
    }

    // Configure the high-pass filter
    AudioUnitInitialize(_recordState.audioUnit);
    
    // Set the cutoff frequency (adjust this value as needed)
    Float64 cutoffFrequency = 80.0;  // 80 Hz is a common starting point
    AudioUnitSetParameter(_recordState.audioUnit,
                          kHipassParam_CutoffFrequency,
                          kAudioUnitScope_Global,
                          0,
                          cutoffFrequency,
                          0);

    // Set the resonance (adjust this value as needed)
    Float64 resonance = 0.7;  // 0.7 is a moderate value
    AudioUnitSetParameter(_recordState.audioUnit,
                          kHipassParam_Resonance,
                          kAudioUnitScope_Global,
                          0,
                          resonance,
                          0);
}

RCT_EXPORT_METHOD(start)
{
    RCTLogInfo(@"start");
    
    [self setupAudioSession];

    if ([self isFeatureEnabled:@"echoCancellation" defaultValue:NO]) {
        [self setupAudioEngineWithAEC];
    }

    if ([self isFeatureEnabled:@"noiseReduction" defaultValue:NO]) {
        [self setupAudioUnit];
    }

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

    if (self.audioEngine) {
        [self.audioEngine stop];
    }
    
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    
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
- (NSDictionary *)detectSpeechWithLevel:(NSData *)data
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

    // Apply the high-pass filter only if noise reduction is enabled
    if (pRecordState->audioUnit != NULL) {
        AudioUnitRender(pRecordState->audioUnit,
                        0,
                        inStartTime,
                        0,
                        inNumPackets,
                        inBuffer);
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

    [pRecordState->mSelf accumulateAndProcessBuffer:inBuffer];

    // Re-enqueue the buffer for continued recording
    AudioQueueEnqueueBuffer(pRecordState->mQueue, inBuffer, 0, NULL);
}

- (void)accumulateAndProcessBuffer:(AudioQueueBufferRef)inBuffer
{
    [accumulatedData appendBytes:inBuffer->mAudioData length:inBuffer->mAudioDataByteSize];
    accumulatedSamples += inBuffer->mAudioDataByteSize / (_recordState.mDataFormat.mBitsPerChannel / 8);

    if (accumulatedSamples >= samplesPerTimeSlice) {
        [self processAccumulatedData];
    }
}


- (void)processAccumulatedData
{
    NSData *data = [NSData dataWithData:accumulatedData];

    NSDictionary *result = @{
        @"speechProbability": @(0.0f),
        @"info": @{@"level": @(-160.0f)}
    };
    
    if ([_recordState.detectionMethod isEqualToString:@"volume_threshold"]) {
        result = [self detectSpeechWithLevel:data];
    } else {
        throwRNException(@"Invalid detection method", 1);
    }

    // Encode audio data
    NSString *str = [data base64EncodedStringWithOptions:0];

    // Send a single event with frame number, audio data, speech probability, and debug info
    [self sendEventWithName:@"frame" body:@{
        @"frameNumber": @(_recordState.frameNumber),
        @"audioData": str,
        @"speechProbability": result[@"speechProbability"],
        @"info": result[@"info"]
    }];

    // Increment frame number
    _recordState.frameNumber++;

    // Reset accumulated data
    accumulatedData = [NSMutableData data];
    accumulatedSamples = 0;
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

    // Clean up the Audio Unit only if it was initialized
    if (_recordState.audioUnit != NULL) {
        AudioUnitUninitialize(_recordState.audioUnit);
        AudioComponentInstanceDispose(_recordState.audioUnit);
        _recordState.audioUnit = NULL;
    }
    
    if (self.audioEngine) {
        [self.audioEngine stop];
        self.audioEngine = nil;
    }
}

@end