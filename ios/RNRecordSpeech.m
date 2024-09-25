#import "RNRecordSpeech.h"
#import <React/RCTLog.h>
#import <Accelerate/Accelerate.h>

@implementation RNRecordSpeech {
    NSUInteger _frameCounter;
    AVAudioMixerNode *_mixerNode;
    AVAudioFormat *_recordingFormat;
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

- (BOOL)isInputGainSettable {
    return [[AVAudioSession sharedInstance] isInputGainSettable];
}

RCT_EXPORT_METHOD(init:(NSDictionary *)config
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        self.config = config;
        self.debugMode = [config[@"debug"] boolValue];
        
        if (self.debugMode) {
            NSLog(@"Initializing RNRecordSpeech with config: %@", config);
        }

        resolve(@{@"status": @"initialized"});
    } @catch (NSException *exception) {
        reject(@"InitializationError", exception.reason, nil);
    }
}

- (void)setupAudioSession
{
    NSError *audioSessionError = nil;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    // Use PlayAndRecord category with specific options
    AVAudioSessionCategoryOptions options = 
        AVAudioSessionCategoryOptionDefaultToSpeaker |
        AVAudioSessionCategoryOptionAllowBluetooth |
        AVAudioSessionCategoryOptionDuckOthers;
    
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                  withOptions:options
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
    
    // Disable microphone audio routing to output
    [audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&audioSessionError];
    if (audioSessionError) {
        [self throwException:@"AudioSessionError" reason:audioSessionError.localizedDescription];
    }
    
    // Apply input gain if the feature is enabled and supported
    if ([self isFeatureEnabled:@"inputGain"] && [self isInputGainSettable]) {
        float inputGainValue = [self.config[@"inputGainValue"] floatValue] ?: 0.8;
        inputGainValue = MAX(0.0, MIN(1.0, inputGainValue)); // Ensure value is between 0.0 and 1.0
        
        NSError *gainError = nil;
        BOOL success = [audioSession setInputGain:inputGainValue error:&gainError];
        if (!success) {
            NSLog(@"Failed to set input gain: %@", gainError.localizedDescription);
        }
    }

    [audioSession setActive:YES error:&audioSessionError];
    if (audioSessionError) {
        [self throwException:@"AudioSessionError" reason:audioSessionError.localizedDescription];
    }
}

- (void)setupAudioProcessingChain {
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioNode *lastNode = inputNode;
    
    if ([self isFeatureEnabled:@"noiseReduction"]) {
        AVAudioUnitEQ *eqNode = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];

        AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];
        NSLog(@"Attaching AudioEngine with input node with format: %@", inputFormat);

        [self.audioEngine attachNode:eqNode];
        [self.audioEngine connect:lastNode to:eqNode format:_recordingFormat];

        NSLog(@"AudioEngine attached");
        
        // Configure noise reduction
        AVAudioUnitEQFilterParameters *noiseReductionFilter = eqNode.bands[0];
        noiseReductionFilter.filterType = AVAudioUnitEQFilterTypeHighPass;
        noiseReductionFilter.frequency = 80.0;
        noiseReductionFilter.bandwidth = 1.0;
        noiseReductionFilter.bypass = NO;
        
        lastNode = eqNode;
    }
    
    // Connect the last node to a mixer node
    _mixerNode = [[AVAudioMixerNode alloc] init];
    [self.audioEngine attachNode:_mixerNode];
    [self.audioEngine connect:lastNode to:_mixerNode format:_recordingFormat];
    
    // Important: Do not connect the mixer to the main mixer
    // This prevents the input from being routed to the output
}

RCT_EXPORT_METHOD(start:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        if (self.audioEngine && [self.audioEngine isRunning]) {
            [self stopInternal];
        }
        
        // Set up audio session
        [self setupAudioSession];
        
        // Initialize audio engine
        self.audioEngine = [[AVAudioEngine alloc] init];
        
        // Configure recording format
        AVAudioInputNode *inputNode = self.audioEngine.inputNode;
        AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];
        
        double sampleRate = inputFormat.sampleRate;
        NSUInteger channels = [self.config[@"channels"] unsignedIntegerValue];
        
        NSLog(@"SYSTEM INPUT FORMAT: %@", inputFormat);

        NSLog(@"USING: Sample rate: %f, Channels: %lu", inputFormat.sampleRate, inputFormat.channelCount);
        
        _recordingFormat = [[AVAudioFormat alloc] 
                            initWithCommonFormat:AVAudioPCMFormatFloat32
                            sampleRate:inputFormat.sampleRate 
                            channels:inputFormat.channelCount 
                            interleaved:NO];
        
        if (!_recordingFormat) {
            NSLog(@"Failed to create valid recording format. Using input format.");
            _recordingFormat = inputFormat;
        }
        
        // Initialize speech recognizer only if voice_activity_detection is the chosen method
        if ([self.config[@"detectionMethod"] isEqualToString:@"voice_activity_detection"]) {
            // Initialize VAD-related properties
            self.recentSpeechProbabilities = [NSMutableArray array];
            self.maxProbabilityBufferSize = 10; // Adjust this value as needed
        }
        
        // Set up the audio processing chain
        [self setupAudioProcessingChain];
        
        NSError *error = nil;
        [self.audioEngine startAndReturnError:&error];
        if (error) {
            [self throwException:@"AudioEngineError" reason:error.localizedDescription];
        }

        _frameCounter = 0; // Initialize frame counter

        NSTimeInterval timeSlice = [self.config[@"timeSlice"] doubleValue] / 1000.0;
        NSUInteger samplesPerSlice = timeSlice * _recordingFormat.sampleRate;
        
        __block NSMutableData *audioBuffer = [NSMutableData dataWithCapacity:samplesPerSlice * sizeof(float)];
        __block NSUInteger sampleCount = 0;
        
        [self.audioEngine.inputNode installTapOnBus:0 bufferSize:1024 format:_recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
           NSUInteger numberOfFrames = buffer.frameLength;
            float *samples = buffer.floatChannelData[0];
            
            [audioBuffer appendBytes:samples length:numberOfFrames * sizeof(float)];
            sampleCount += numberOfFrames;
            
            if (sampleCount >= samplesPerSlice) {
                self->_frameCounter++; // Increment frame counter

                NSDictionary* detectionResults = [self detectSpeechInBuffer:audioBuffer];
                
                // Convert NSData to base64 encoded string
                NSString *base64AudioData = [audioBuffer base64EncodedStringWithOptions:0];

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

        if (self.debugMode) {
            NSLog(@"Audio initialization complete. Recording format: %@", _recordingFormat);
        }

        // Return an object containing the recording format
        NSDictionary *result = @{
            @"status": @"started",
            @"recordingFormat": @{
                @"sampleRate": @(_recordingFormat.sampleRate),
                @"channels": @(_recordingFormat.channelCount),
                @"interleaved": @(_recordingFormat.isInterleaved)
            }
        };
        
        resolve(result);
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
    float *samples = (float *)audioBuffer.bytes;
    NSUInteger sampleCount = audioBuffer.length / sizeof(float);
    
    // Calculate energy
    float energy = 0.0f;
    vDSP_measqv(samples, 1, &energy, sampleCount);
    energy /= sampleCount;
    
    // Apply log scale
    float logEnergy = 10 * log10f(energy + 1e-10);
    
    // Update energy history
    static NSMutableArray<NSNumber *> *energyHistory = nil;
    static const NSUInteger historySize = 20;  // Reduced history size for shorter recordings
    
    if (!energyHistory) {
        energyHistory = [NSMutableArray arrayWithCapacity:historySize];
    }
    
    [energyHistory addObject:@(logEnergy)];
    if (energyHistory.count > historySize) {
        [energyHistory removeObjectAtIndex:0];
    }
    
    // Calculate statistics
    float sum = 0.0f;
    float sumSquares = 0.0f;
    for (NSNumber *e in energyHistory) {
        float value = e.floatValue;
        sum += value;
        sumSquares += value * value;
    }
    
    float mean = sum / energyHistory.count;
    float variance = (sumSquares / energyHistory.count) - (mean * mean);
    variance = fmaxf(variance, 0.0f);
    float stdDev = sqrtf(variance);
    
    // Calculate z-score with increased sensitivity
    float zScore = 0.0f;
    if (stdDev > 1e-10) {
        zScore = (logEnergy - mean) / stdDev;
        zScore *= 1.5f;  // Increase sensitivity
    }
    
    // Calculate speech probability
    float speechProbability = 1.0f / (1.0f + expf(-zScore));
    
    // Adjust probability curve to reach higher values more easily
    speechProbability = powf(speechProbability, 0.7f);
    
    // Ensure speechProbability is a valid number between 0 and 1
    speechProbability = isnan(speechProbability) ? 0.0f : speechProbability;
    speechProbability = fmaxf(0.0f, fminf(1.0f, speechProbability));
    
    return @{
        @"speechProbability": @(speechProbability),
        @"info": @{
            @"energy": @(logEnergy),
            @"mean": @(mean),
            @"stdDev": @(stdDev),
            @"zScore": @(zScore),
            @"instantProbability": @(speechProbability)
        }
    };
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

//Define internal routine stopInternal
- (void)stopInternal
{
    if (self.audioEngine == nil) {
        return;
    }

    if (![self.audioEngine isRunning]) {
        self.audioEngine = nil;
        return;
    }

    [self.audioEngine stop];
    [self.audioEngine.inputNode removeTapOnBus:0];
    
    if (self.recognitionTask) {
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
    }
    
    // Remove all attached nodes except the input and output nodes
    for (AVAudioNode *node in self.audioEngine.attachedNodes) {
        if (node != self.audioEngine.inputNode && node != self.audioEngine.outputNode) {
            [self.audioEngine detachNode:node];
        }
    }
    
    _mixerNode = nil;
    
    // Deactivate audio session
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
    if (error) {
        NSLog(@"Error deactivating audio session: %@", error.localizedDescription);
    }

    self.audioEngine = nil;
}

RCT_EXPORT_METHOD(stop:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        if (![self.audioEngine isRunning]) {
            resolve(@{@"status": @"already_stopped"});
            return;
        }

        [self stopInternal];

        resolve(@{@"status": @"stopped"});

    } @catch (NSException *exception) {
        reject(@"StopError", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(normalizeAudio:(NSString *)base64AudioData
                  withGain:(float)gain
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        // Decode Base64 string to NSData
        NSData *audioBuffer = [[NSData alloc] initWithBase64EncodedString:base64AudioData options:0];

        NSUInteger sampleCount = audioBuffer.length / sizeof(float);
        float *samples = (float *)audioBuffer.bytes;

        // Find max amplitude
        float maxAmplitude = 0.0f;
        vDSP_maxmgv(samples, 1, &maxAmplitude, sampleCount);

        // Calculate normalization factor (avoid division by zero)
        float normalizationFactor = (maxAmplitude > 0.0001f) ? (1.0f / maxAmplitude) : 1.0f;

        // Allocate a new buffer for the normalized samples
        NSMutableData *normalizedData = [NSMutableData dataWithLength:audioBuffer.length];
        float *normalizedSamples = (float *)normalizedData.bytes;

        // Apply normalization and gain
        float combinedFactor = normalizationFactor * gain;
        vDSP_vsmul(samples, 1, &combinedFactor, normalizedSamples, 1, sampleCount);

        // After processing, encode the result back to Base64
        NSString *base64NormalizedData = [normalizedData base64EncodedStringWithOptions:0];

        resolve(base64NormalizedData);
    } @catch (NSException *exception) {
        reject(@"NormalizationError", exception.reason, nil);
    }
}

RCT_EXPORT_METHOD(convertFloat32ToInt16:(NSString *)base64AudioData
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    @try {
        // Decode Base64 string to NSData
        NSData *audioData = [[NSData alloc] initWithBase64EncodedString:base64AudioData options:0];

        NSUInteger sampleCount = audioData.length / sizeof(float);
        float *floatSamples = (float *)audioData.bytes;
        
        // malloc a new buffer for the 16-bit samples
        NSMutableData *int16Data = [NSMutableData dataWithLength:sampleCount * sizeof(SInt16)];
        SInt16 *int16Samples = (SInt16 *)int16Data.bytes;
        
        // allocate a buffer for the scaled samples
        float *scaledSamples = (float *)malloc(sampleCount * sizeof(float));

        // Scale and convert floating-point values to 16-bit integers
        float scalingFactor = 32767.0f;
        vDSP_vsmul(floatSamples, 1, &scalingFactor, scaledSamples, 1, sampleCount);
        vDSP_vfixr16(scaledSamples, 1, int16Samples, 1, sampleCount);

        free(scaledSamples);
        
        // After processing, encode the result back to Base64
        NSString *base64Int16Data = [int16Data base64EncodedStringWithOptions:0];
        
        resolve(base64Int16Data);
    } @catch (NSException *exception) {
        reject(@"ConversionError", exception.reason, nil);
    }
}

- (void)cleanup
{
    [self stopInternal];

    self.audioEngine = nil;
    self.speechRecognizer = nil;
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