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
    
    // Convert RMS to decibels
    float db = 20 * log10f(rms);
    
    // Clean up
    free(floatSamples);
    
    return db;
}
