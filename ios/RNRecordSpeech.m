#import "RNRecordSpeech.h"
#import <React/RCTLog.h>
#import <Accelerate/Accelerate.h>

@implementation RNRecordSpeech {
    NSUInteger _frameCounter;
}

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

- (NSData *)convertFloat32ToInt16:(float *)floatData length:(NSUInteger)length {
    NSMutableData *int16Data = [NSMutableData dataWithLength:length * sizeof(int16_t)];
    int16_t *int16Samples = (int16_t *)int16Data.bytes;
    
    // Create a temporary float buffer to hold the scaled values
    float *scaledFloatData = (float *)malloc(length * sizeof(float));
    
    // Scale floating-point values to 16-bit integer range
    float scalingFactor = 32767.0f;
    vDSP_vsmul(floatData, 1, &scalingFactor, scaledFloatData, 1, length);
    
    // Convert scaled floating-point values to 16-bit integers
    vDSP_vfixr16(scaledFloatData, 1, int16Samples, 1, length);
    
    // Free the temporary float buffer
    free(scaledFloatData);
    
    return int16Data;
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
        
        AVAudioFormat *recordingFormat = [[AVAudioFormat alloc] 
                                          initWithCommonFormat:AVAudioPCMFormatFloat32
                                          sampleRate:sampleRate 
                                          channels:channels.unsignedIntegerValue 
                                          interleaved:NO];
        
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
            NSError *error = nil;
            [self.audioEngine startAndReturnError:&error];
            if (error) {
                [self throwException:@"AudioEngineError" reason:error.localizedDescription];
            }
            
            _frameCounter = 0; // Initialize frame counter
            
            AVAudioInputNode *inputNode = self.audioEngine.inputNode;
            AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
            
            NSTimeInterval timeSlice = [self.config[@"timeSlice"] doubleValue] / 1000.0;
            NSUInteger samplesPerSlice = timeSlice * recordingFormat.sampleRate;
            
            __block NSMutableData *audioBuffer = [NSMutableData dataWithCapacity:samplesPerSlice * sizeof(float)];
            __block NSUInteger sampleCount = 0;
            
            NSLog(@"bitsPerSample: %@", self.config[@"bitsPerSample"]);
            NSLog(@"sampleRate: %f", recordingFormat.sampleRate);
            NSLog(@"channels: %lu", (unsigned long)recordingFormat.channelCount);
            NSLog(@"timeSlice: %f", timeSlice);
            NSLog(@"samplesPerSlice: %lu", (unsigned long)samplesPerSlice);

            [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
                NSUInteger numberOfFrames = buffer.frameLength;
                float *samples = buffer.floatChannelData[0];
                
                [audioBuffer appendBytes:samples length:numberOfFrames * sizeof(float)];
                sampleCount += numberOfFrames;
                
                if (sampleCount >= samplesPerSlice) {
                    self->_frameCounter++; // Increment frame counter

                    NSDictionary* detectionResults = [self detectSpeechInBuffer:audioBuffer];
                    
                    NSString *base64AudioData = nil;
                    if ([self.config[@"bitsPerSample"] unsignedIntegerValue] == 16) {

                        NSData *int16AudioData = [self convertFloat32ToInt16:(float *)audioBuffer.bytes length:sampleCount];

                        base64AudioData = [int16AudioData base64EncodedStringWithOptions:0];
                    } else {
                        NSLog(@"Using float32 audio data");
                        // Default to float32 if bitsPerSample is not 16 or not specified
                        base64AudioData = [audioBuffer base64EncodedStringWithOptions:0];
                    }

                    NSLog(@"base64AudioData length: %lu", (unsigned long)[base64AudioData length]);

                    NSDictionary *frameData = @{
                        @"audioData": base64AudioData,
                        @"frameNumber": @(self->_frameCounter),
                        @"speechProbability": detectionResults[@"speechProbability"],
                        @"info": detectionResults[@"info"]
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

- (NSDictionary*)detectSpeechInBuffer:(NSData *)audioBuffer
{
    NSString *detectionMethod = self.config[@"detectionMethod"];
    if ([detectionMethod isEqualToString:@"voice_activity_detection"]) {
        return [self detectSpeechUsingVAD:audioBuffer];
    } else if ([detectionMethod isEqualToString:@"volume_threshold"]) {
        return [self detectSpeechUsingVolumeThreshold:audioBuffer];
    }
    
    [self throwException:@"DetectionError" reason:@"Invalid detection method specified."];
    return nil;
}

- (NSDictionary*)detectSpeechUsingVAD:(NSData *)audioBuffer
{
    if (!self.recentSpeechProbabilities) {
        self.recentSpeechProbabilities = [NSMutableArray array];
        self.maxProbabilityBufferSize = 10; // Adjust this value as needed
    }

    float speechProbability = 0.0;
    NSDictionary *info = @{};

    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 
                                                            sampleRate:[self.config[@"sampleRate"] doubleValue]
                                                              channels:[self.config[@"channels"] unsignedIntegerValue]
                                                            interleaved:NO];
    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                                frameCapacity:audioBuffer.length / sizeof(float)];
    memcpy(pcmBuffer.floatChannelData[0], audioBuffer.bytes, audioBuffer.length);
    pcmBuffer.frameLength = audioBuffer.length / sizeof(float);

    if (!self.recognitionTask) {
        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.recognitionRequest.shouldReportPartialResults = YES;

        __weak typeof(self) weakSelf = self;
        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (result) {
                float confidence = result.bestTranscription.segments.lastObject.confidence;
                [strongSelf.recentSpeechProbabilities addObject:@(confidence)];
                if (strongSelf.recentSpeechProbabilities.count > strongSelf.maxProbabilityBufferSize) {
                    [strongSelf.recentSpeechProbabilities removeObjectAtIndex:0];
                }
            }
        }];
    }

    [self.recognitionRequest appendAudioPCMBuffer:pcmBuffer];

    // Calculate average probability
    float sum = 0.0f;
    for (NSNumber *prob in self.recentSpeechProbabilities) {
        sum += prob.floatValue;
    }
    speechProbability = self.recentSpeechProbabilities.count > 0 ? sum / self.recentSpeechProbabilities.count : 0.0f;

    info = @{
        @"confidenceScores": [self.recentSpeechProbabilities copy],
    };

    return @{@"speechProbability": @(speechProbability), @"info": info};
}

- (NSDictionary*)detectSpeechUsingVolumeThreshold:(NSData *)audioBuffer
{
    float *samples = (float *)audioBuffer.bytes;
    NSUInteger sampleCount = audioBuffer.length / sizeof(float);
    
    float sum = 0.0;
    float maxAmplitude = 0.0;
    float minSample = FLT_MAX;
    float maxSample = -FLT_MAX;
    
    for (NSUInteger i = 0; i < sampleCount; i++) {
        float absValue = fabsf(samples[i]);
        sum += absValue;
        if (absValue > maxAmplitude) {
            maxAmplitude = absValue;
        }
        if (samples[i] < minSample) {
            minSample = samples[i];
        }
        if (samples[i] > maxSample) {
            maxSample = samples[i];
        }
    }
    
    float meanAmplitude = sum / sampleCount;
    float maxdb = 20 * log10f(maxAmplitude);
    float meandb = 20 * log10f(meanAmplitude);
    
    // Use the threshold from detectionParams
    float threshold = [self.config[@"detectionParams"][@"threshold"] floatValue]? : -40.0;
    
    // Adjust sigmoid function to give 80% probability when maxdb == threshold
    float sensitivity = 5.0; // Adjust this value to change the steepness of the probability curve
    float shift = logf(1.0 / 0.8 - 1.0) / sensitivity;
    float probability = 1.0 / (1.0 + expf(-sensitivity * (maxdb - threshold + shift)));
    
    return @{@"speechProbability": @(probability), 
             @"info": @{@"meandb": @(meandb), 
                        @"maxdb": @(maxdb), 
                        @"threshold": @(threshold),
                        @"minSample": @(minSample),
                        @"maxSample": @(maxSample)}};
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
    [self.audioEngine stop];
    [self.audioEngine.inputNode removeTapOnBus:0];
    
    if (self.recognitionTask) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    
    self.recognitionRequest = nil;
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