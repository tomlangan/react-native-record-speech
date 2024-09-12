#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Function to calculate audio level from PCM data
float calculateAudioLevel(NSData *audioData, AudioStreamBasicDescription format);

// New VAD structure
typedef struct {
    float threshold;
    float adaptationRate;
    float energy;
} VADState;

// Function to initialize VAD state
VADState initializeVADState(float initialThreshold, float adaptationRate);

// Function to perform energy-based VAD
BOOL detectSpeechWithEnergy(float currentEnergy, VADState *vadState);

// Function to detect speech using both level and energy
NSDictionary* detectSpeech(NSData *audioData, AudioStreamBasicDescription format, float volumeThreshold, VADState *vadState);

NS_ASSUME_NONNULL_END