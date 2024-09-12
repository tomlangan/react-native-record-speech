#import "AudioProcessing.h"
#import <Accelerate/Accelerate.h>

float calculateAudioLevel(NSData *audioData, AudioStreamBasicDescription format) {
    // Convert NSData to float array
    NSUInteger sampleCount = audioData.length / sizeof(int16_t);
    const int16_t *samples = (const int16_t *)audioData.bytes;
    
    float *floatSamples = (float *)malloc(sampleCount * sizeof(float));
    vDSP_vflt16(samples, 1, floatSamples, 1, sampleCount);
    
    // Calculate RMS
    float rms = 0;
    vDSP_rmsqv(floatSamples, 1, &rms, sampleCount);
    
    // Convert RMS to decibels, normalized to full scale
    float fullScale = 32767.0f; // For 16-bit audio
    float db = 20 * log10f(rms / fullScale);
    
    // Clean up
    free(floatSamples);
    
    return db;
}


VADState initializeVADState(float initialThreshold, float adaptationRate) {
    VADState state;
    state.threshold = initialThreshold;
    state.adaptationRate = adaptationRate;
    state.energy = 0.0f;
    return state;
}

BOOL detectSpeechWithEnergy(float currentEnergy, VADState *vadState) {
    // Update VAD energy using exponential moving average
    vadState->energy = (1 - vadState->adaptationRate) * vadState->energy + vadState->adaptationRate * currentEnergy;
    
    // Adaptive thresholding
    vadState->threshold = (1 - vadState->adaptationRate) * vadState->threshold + vadState->adaptationRate * vadState->energy;
    
    // Speech detection
    BOOL isSpeech = (currentEnergy > vadState->threshold * 1.5f); // 1.5 is a sensitivity factor, can be adjusted
    
    NSLog(@"Energy VAD Debug - Current Energy: %f, VAD Energy: %f, Threshold: %f, IsSpeech: %d", currentEnergy, vadState->energy, vadState->threshold, isSpeech);
    
    return isSpeech;
}

NSDictionary* detectSpeech(NSData *audioData, AudioStreamBasicDescription format, float volumeThreshold, VADState *vadState) {
    float currentLevel = calculateAudioLevel(audioData, format);
    
    // Calculate energy (can be adjusted based on your specific needs)
    float currentEnergy = powf(10, currentLevel / 10);
    
    // Use energy-based VAD
    BOOL isSpeech = detectSpeechWithEnergy(currentEnergy, vadState);
    
    // Combine volume threshold and VAD results
    float speechProbability = (currentLevel > volumeThreshold && isSpeech) ? 0.9f : 0.1f;
    
    return @{
        @"speechProbability": @(speechProbability),
        @"info": @{
            @"level": @(currentLevel),
            @"energy": @(currentEnergy),
            @"vadThreshold": @(vadState->threshold)
        }
    };
}
