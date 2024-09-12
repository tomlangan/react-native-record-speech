#import "RNRecordSpeech.h"
#import <React/RCTLog.h>

@implementation RNRecordSpeech

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"frame"];
}

- (void)throwException:(NSString *)name reason:(NSString *)reason
{
    NSString *domain = @"com.RNRecordSpeech";
    NSDictionary *userInfo = @{NSLocalizedDescriptionKey: reason};
    NSError *error = [NSError errorWithDomain:domain code:-1 userInfo:userInfo];
    @throw [NSException exceptionWithName:name reason:reason userInfo:@{NSUnderlyingErrorKey: error}];
}

- (BOOL)isFeatureEnabled:(NSString *)featureName
{
    if (self.config && self.config[@"features"]) {
        NSDictionary *features = self.config[@"features"];
        NSNumber *isEnabled = features[featureName];
        return [isEnabled boolValue];
    }
    return NO;
}

// Add this new method to print debug information
- (void)printRecordingParameters {
    if (!self.debugMode) return;
    
    NSLog(@"RNRecordSpeech - Recording Parameters:");
    NSLog(@"Detection Method: %@", self.config[@"detectionMethod"]);
    NSLog(@"Sample Rate: %@", self.config[@"sampleRate"]);
    NSLog(@"Channels: %@", self.config[@"channels"]);
    NSLog(@"Bits Per Sample: %@", self.config[@"bitsPerSample"]);
    NSLog(@"Time Slice: %@ ms", self.config[@"timeSlice"]);
    NSLog(@"Silence Timeout: %@ ms", self.config[@"silenceTimeout"]);
    NSLog(@"Minimum Speech Duration: %@ ms", self.config[@"minimumSpeechDuration"]);
    NSLog(@"Continuous Recording: %@", self.config[@"continuousRecording"] ? @"Yes" : @"No");
    NSLog(@"Only Record On Speaking: %@", self.config[@"onlyRecordOnSpeaking"] ? @"Yes" : @"No");
    
    NSDictionary *features = self.config[@"features"];
    NSLog(@"Noise Reduction: %@", [features[@"noiseReduction"] boolValue] ? @"Enabled" : @"Disabled");
    NSLog(@"Echo Cancellation: %@", [features[@"echoCancellation"] boolValue] ? @"Enabled" : @"Disabled");
    
    if ([self.config[@"detectionMethod"] isEqualToString:@"volume_threshold"]) {
        NSLog(@"Volume Threshold: %@ dB", self.config[@"detectionParams"][@"threshold"]);
    }
}

RCT_EXPORT_METHOD(init:(NSDictionary *)config
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        self.config = config;
        self.debugMode = [config[@"debug"] boolValue];
        
        // Set up audio session
        NSError *audioSessionError = nil;
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord 
                      withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
                            error:&audioSessionError];
        if (audioSessionError) {
            [self throwException:@"AudioSessionError" reason:audioSessionError.localizedDescription];
        }
        
        // Set audio session mode based on echo cancellation setting
        if ([self isFeatureEnabled:@"echoCancellation"]) {
            [audioSession setMode:AVAudioSessionModeVoiceChat error:&audioSessionError];
        } else {
            [audioSession setMode:AVAudioSessionModeMeasurement error:&audioSessionError];
        }
        if (audioSessionError) {
            [self throwException:@"AudioSessionError" reason:audioSessionError.localizedDescription];
        }
        
        [audioSession setActive:YES error:&audioSessionError];
        if (audioSessionError) {
            [self throwException:@"AudioSessionError" reason:audioSessionError.localizedDescription];
        }
        
        // Initialize audio engine
        self.audioEngine = [[AVAudioEngine alloc] init];
        
        // Configure audio engine based on config
        AVAudioInputNode *inputNode = self.audioEngine.inputNode;
        AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];
        
        // Use the hardware's sample rate instead of the one from config
        double sampleRate = inputFormat.sampleRate;
        NSNumber *channels = config[@"channels"];

        // If the requested sample rate does not match the hardware's sample rate, pop a
        // warning and print the HW sample rate
        if (sampleRate != [config[@"sampleRate"] doubleValue]) {
            if (self.debugMode) {
                NSLog(@"RNRecordSpeech - Requested sample rate: %f", [config[@"sampleRate"] doubleValue]);
                NSLog(@"RNRecordSpeech - Using hardware sample rate: %f", sampleRate);
            }
        }

        
        AVAudioFormat *recordingFormat = [[AVAudioFormat alloc] 
                                          initWithCommonFormat:AVAudioPCMFormatFloat32
                                          sampleRate:sampleRate 
                                          channels:channels.unsignedIntegerValue 
                                          interleaved:NO];
        
        if (self.debugMode) {
            NSLog(@"RNRecordSpeech - Using hardware sample rate: %f", sampleRate);
        }
        
        // Set up detection method
        NSString *detectionMethod = config[@"detectionMethod"];
        if ([detectionMethod isEqualToString:@"voice_activity_detection"]) {
            self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale currentLocale]];
            if (!self.speechRecognizer.isAvailable) {
                [self throwException:@"SpeechRecognizerError" reason:@"Speech recognition is not available on this device."];
            }
        } else if ([detectionMethod isEqualToString:@"volume_threshold"]) {
            if (![config[@"detectionParams"] objectForKey:@"threshold"]) {
                [self throwException:@"ConfigurationError" reason:@"Threshold not specified for volume_threshold method."];
            }
        } else {
            [self throwException:@"ConfigurationError" reason:@"Invalid detection method specified."];
        }
        
        // Apply audio processing if features are enabled
        AVAudioNode *lastNode = inputNode;
        
        if ([self isFeatureEnabled:@"noiseReduction"]) {
            AVAudioUnitEQ *eqNode = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
            [self.audioEngine attachNode:eqNode];
            [self.audioEngine connect:lastNode to:eqNode format:recordingFormat];
            
            // Configure noise reduction
            AVAudioUnitEQFilterParameters *noiseReductionFilter = eqNode.bands[0];
            noiseReductionFilter.filterType = AVAudioUnitEQFilterTypeHighPass;
            noiseReductionFilter.frequency = 80.0;
            noiseReductionFilter.bandwidth = 1.0;
            noiseReductionFilter.bypass = NO;
            
            lastNode = eqNode;
        }
        
        resolve(@{@"status": @"initialized"});
    } @catch (NSException *exception) {
        reject(@"InitializationError", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(start:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        if (![self.audioEngine isRunning]) {
            [self printRecordingParameters];

            NSError *error = nil;
            [self.audioEngine startAndReturnError:&error];
            if (error) {
                [self throwException:@"AudioEngineError" reason:error.localizedDescription];
            }
            
            AVAudioInputNode *inputNode = self.audioEngine.inputNode;
            AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
            
            NSTimeInterval timeSlice = [self.config[@"timeSlice"] doubleValue] / 1000.0;
            NSUInteger samplesPerSlice = timeSlice * recordingFormat.sampleRate;
            
            __block NSMutableData *audioBuffer = [NSMutableData dataWithCapacity:samplesPerSlice * sizeof(float)];
            __block NSUInteger sampleCount = 0;
            __block SFSpeechAudioBufferRecognitionRequest *recognitionRequest = nil;
            __block SFSpeechRecognitionTask *recognitionTask = nil;
            
            if ([self.config[@"detectionMethod"] isEqualToString:@"voice_activity_detection"]) {
                recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
                recognitionRequest.taskHint = SFSpeechRecognitionTaskHintDictation;
                recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
                    // Handle continuous speech recognition results here
                }];
            }
            
            [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
                NSUInteger numberOfFrames = buffer.frameLength;
                float *samples = buffer.floatChannelData[0];
                
                [audioBuffer appendBytes:samples length:numberOfFrames * sizeof(float)];
                sampleCount += numberOfFrames;
                
                if (sampleCount >= samplesPerSlice) {
                    float speechProbability = [self detectSpeechInBuffer:audioBuffer withRecognitionRequest:recognitionRequest];
                    
                    NSString *base64AudioData = [audioBuffer base64EncodedStringWithOptions:0];
                    
                    NSDictionary *frameData = @{
                        @"audioData": base64AudioData,
                        @"speechProbability": @(speechProbability),
                        @"info": [self getDebugInfo]
                    };
                    
                    [self sendEventWithName:@"frame" body:frameData];
                    
                    audioBuffer = [NSMutableData dataWithCapacity:samplesPerSlice * sizeof(float)];
                    sampleCount = 0;
                }
            }];
            
            resolve(@{@"status": @"started"});
        } else {
            resolve(@{@"status": @"already_running"});
        }
    } @catch (NSException *exception) {
        reject(@"StartError", exception.reason, nil);
    }
}

- (float)detectSpeechInBuffer:(NSData *)audioBuffer withRecognitionRequest:(SFSpeechAudioBufferRecognitionRequest *)recognitionRequest
{
    NSString *detectionMethod = self.config[@"detectionMethod"];
    if ([detectionMethod isEqualToString:@"voice_activity_detection"]) {
        return [self detectSpeechUsingVAD:audioBuffer withRecognitionRequest:recognitionRequest];
    } else if ([detectionMethod isEqualToString:@"volume_threshold"]) {
        return [self detectSpeechUsingVolumeThreshold:audioBuffer];
    }
    return 0.0;
}


- (float)detectSpeechUsingVAD:(NSData *)audioBuffer withRecognitionRequest:(SFSpeechAudioBufferRecognitionRequest *)recognitionRequest
{
    if (!self.recentSpeechProbabilities) {
        self.recentSpeechProbabilities = [NSMutableArray array];
        self.maxProbabilityBufferSize = 10; // Adjust this value as needed
    }

    if (recognitionRequest) {
        AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100 channels:1 interleaved:NO] frameCapacity:audioBuffer.length / sizeof(float)];
        memcpy(pcmBuffer.floatChannelData[0], audioBuffer.bytes, audioBuffer.length);
        pcmBuffer.frameLength = audioBuffer.length / sizeof(float);
        
        [recognitionRequest appendAudioPCMBuffer:pcmBuffer];
        
        // Calculate speech probability based on audio energy
        float totalEnergy = 0.0f;
        float *samples = (float *)audioBuffer.bytes;
        NSUInteger sampleCount = audioBuffer.length / sizeof(float);
        
        for (NSUInteger i = 0; i < sampleCount; i++) {
            totalEnergy += samples[i] * samples[i];
        }
        
        float avgEnergy = totalEnergy / sampleCount;
        float normalizedEnergy = fmin(1.0f, fmax(0.0f, avgEnergy * 10)); // Adjust scaling factor as needed
        
        [self.recentSpeechProbabilities addObject:@(normalizedEnergy)];
        if (self.recentSpeechProbabilities.count > self.maxProbabilityBufferSize) {
            [self.recentSpeechProbabilities removeObjectAtIndex:0];
        }
        
        // Calculate the average of recent probabilities
        float sum = 0.0f;
        for (NSNumber *prob in self.recentSpeechProbabilities) {
            sum += prob.floatValue;
        }
        float averageProbability = sum / self.recentSpeechProbabilities.count;
        
        return averageProbability;
    }
    return 0.0;
}

- (float)detectSpeechUsingVolumeThreshold:(NSData *)audioBuffer
{
    float *samples = (float *)audioBuffer.bytes;
    NSUInteger sampleCount = audioBuffer.length / sizeof(float);
    
    float sum = 0.0;
    for (NSUInteger i = 0; i < sampleCount; i++) {
        sum += samples[i] * samples[i];
    }
    
    float rms = sqrtf(sum / sampleCount);
    float db = 20 * log10f(rms);
    
    float threshold = [self.config[@"detectionParams"][@"threshold"] floatValue];
    
    // Calculate the probability using a Gaussian function
    float variance = 21.6; // Calculated based on requirements
    float probabilityAtThreshold = 0.8;
    float maxProbability = 1.0;
    
    float dbDifference = db - threshold;
    float gaussianFactor = -powf(dbDifference, 2) / (2 * variance);
    float probability = maxProbability * exp(gaussianFactor);
    
    // Scale the probability so that it's exactly 0.8 at the threshold
    probability = probability * (probabilityAtThreshold / maxProbability);
    
    // Clamp the probability between 0 and 1
    probability = fmax(0.0, fmin(1.0, probability));
    
    return probability;
}

- (NSDictionary *)getDebugInfo
{
    // Implement this method to return any debug information you want to include
    // This could include things like current audio levels, VAD scores, etc.
    return @{
        @"currentTime": @([[NSDate date] timeIntervalSince1970]),
        // Add more debug info as needed
    };
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        if ([self.audioEngine isRunning]) {
            [self.audioEngine stop];
            [self.audioEngine.inputNode removeTapOnBus:0];
            
            if (self.recognitionTask) {
                [self.recognitionTask cancel];
                self.recognitionTask = nil;
            }
            
            if (self.debugMode) {
                NSLog(@"RNRecordSpeech - Recording stopped");
            }
            
            resolve(@{@"status": @"stopped"});
        } else {
            resolve(@{@"status": @"already_stopped"});
        }
    } @catch (NSException *exception) {
        reject(@"StopError", exception.reason, nil);
    }
}

- (void)cleanup
{
    if (self.debugMode) {
        NSLog(@"RNRecordSpeech - Cleaning up resources");
    }
    
    [self.audioEngine stop];
    [self.audioEngine.inputNode removeTapOnBus:0];
    
    self.audioEngine = nil;
    self.speechRecognizer = nil;
    
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [audioSession setActive:NO error:&error];
    if (error && self.debugMode) {
        NSLog(@"RNRecordSpeech - Error deactivating audio session: %@", error.localizedDescription);
    }
}

- (void)invalidate
{
    [self cleanup];
    [super invalidate];
}

- (void)dealloc
{
    [self cleanup];
}

@end