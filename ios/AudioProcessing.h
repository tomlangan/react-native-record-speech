#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Function to calculate audio level from PCM data
float calculateAudioLevel(NSData *audioData, AudioStreamBasicDescription format);

// Add more audio processing function declarations here in the future

NS_ASSUME_NONNULL_END