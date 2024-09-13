#import "RNRecordSpeech.h"
#import <React/RCTLog.h>
#import <Accelerate/Accelerate.h>

@implementation RNRecordSpeech {
    NSUInteger _frameCounter;
    AVAudioUnitEQ *_normalizationEQ;
    float _runningMaxAmplitude;
    NSUInteger _sampleCounter;
    NSUInteger _normalizationInterval;
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
        
        // Initialize audio engine
        self.audioEngine = [[AVAudioEngine alloc] init];
        
        // Configure recording format
        AVAudioInputNode *inputNode = self.audioEngine.inputNode;
        AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];
        
        double sampleRate = inputFormat.sampleRate;
        NSUInteger channels = [self.config[@"channels"] unsignedIntegerValue];
        
        // Ensure we're using a valid channel count
        if (channels == 0 || channels > 2) {
            channels = inputFormat.channelCount;
        }
        
        _recordingFormat = [[AVAudioFormat alloc] 
                            initWithCommonFormat:AVAudioPCMFormatFloat32
                            sampleRate:sampleRate 
                            channels:channels 
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
        
        NSLog(@"Audio initialization complete. Recording format: %@", _recordingFormat);
        
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
        AVAudioSessionCategoryOptionMixWithOthers;
    
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
        [self.audioEngine attachNode:eqNode];
        [self.audioEngine connect:lastNode to:eqNode format:_recordingFormat];
        
        // Configure noise reduction
        AVAudioUnitEQFilterParameters *noiseReductionFilter = eqNode.bands[0];
        noiseReductionFilter.filterType = AVAudioUnitEQFilterTypeHighPass;
        noiseReductionFilter.frequency = 80.0;
        noiseReductionFilter.bandwidth = 1.0;
        noiseReductionFilter.bypass = NO;
        
        lastNode = eqNode;
    }
    
    if ([self isFeatureEnabled:@"normalization"]) {
        // Add normalization EQ
        _normalizationEQ = [[AVAudioUnitEQ alloc] initWithNumberOfBands:1];
        [self.audioEngine attachNode:_normalizationEQ];
        [self.audioEngine connect:lastNode to:_normalizationEQ format:_recordingFormat];
        
        // Configure normalization
        AVAudioUnitEQFilterParameters *normalizationFilter = _normalizationEQ.bands[0];
        normalizationFilter.filterType = AVAudioUnitEQFilterTypeParametric;
        normalizationFilter.frequency = 1000.0; // Center frequency
        normalizationFilter.bandwidth = 2.0;
        normalizationFilter.gain = 0.0; // Initial gain
        normalizationFilter.bypass = NO;
        
        lastNode = _normalizationEQ;
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
        if ([self.audioEngine isRunning]) {
            // call stopInternal to clean up the audio engine
            [self stopInternal];
        }
        
        // Set up audio session
        [self setupAudioSession];
        
        // Set up the audio processing chain
        [self setupAudioProcessingChain];
        
        NSError *error = nil;
        [self.audioEngine startAndReturnError:&error];
        if (error) {
            [self throwException:@"AudioEngineError" reason:error.localizedDescription];
        }

        _frameCounter = 0; // Initialize frame counter
        
        // Initialize normalization variables
        if ([self isFeatureEnabled:@"normalization"]) {
            _runningMaxAmplitude = 0.0;
            _sampleCounter = 0;
            _normalizationInterval = 1 * _recordingFormat.sampleRate; // best for 2-3 second recordings
        }

        NSTimeInterval timeSlice = [self.config[@"timeSlice"] doubleValue] / 1000.0;
        NSUInteger samplesPerSlice = timeSlice * _recordingFormat.sampleRate;
        
        __block NSMutableData *audioBuffer = [NSMutableData dataWithCapacity:samplesPerSlice * sizeof(float)];
        __block NSUInteger sampleCount = 0;
        
        [self.audioEngine.inputNode installTapOnBus:0 bufferSize:1024 format:_recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
           NSUInteger numberOfFrames = buffer.frameLength;
            float *samples = buffer.floatChannelData[0];

            // check for the normalization feature flag
            if ([self isFeatureEnabled:@"normalization"]) {
                // Calculate max amplitude for normalization
                float maxAmplitude = 0.0;
                vDSP_maxmgv(samples, 1, &maxAmplitude, numberOfFrames);
                self->_runningMaxAmplitude = MAX(self->_runningMaxAmplitude, maxAmplitude);
                
                self->_sampleCounter += numberOfFrames;
                if (self->_sampleCounter >= self->_normalizationInterval) {
                    // Adjust normalization every 5 seconds
                    [self adjustNormalization:self->_runningMaxAmplitude];
                    self->_runningMaxAmplitude = 0.0;
                    self->_sampleCounter = 0;
                }
            }
            
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
    } @catch (NSException *exception) {
        reject(@"StartError", exception.reason, nil);
    }
}

- (void)adjustNormalization:(float)maxAmplitude {
    if (![self isFeatureEnabled:@"normalization"] || !_normalizationEQ) {
        return;
    }
    
    float targetAmplitude = 0.8; 
    float gainAdjustment = 20 * log10f(targetAmplitude / maxAmplitude);
    
    // Limit the gain adjustment to avoid excessive amplification
    gainAdjustment = MIN(gainAdjustment, 30.0); 
    gainAdjustment = MAX(gainAdjustment, -20.0);
    
    AVAudioUnitEQFilterParameters *normalizationFilter = _normalizationEQ.bands[0];
    normalizationFilter.gain = gainAdjustment;
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
    if (![self.audioEngine isRunning]) {
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
    _normalizationEQ = nil;
    
    // Deactivate audio session
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
    if (error) {
        NSLog(@"Error deactivating audio session: %@", error.localizedDescription);
    }
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