#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

@interface RNRecordSpeech : RCTEventEmitter <RCTBridgeModule, AVAudioRecorderDelegate>

@property (nonatomic, strong) NSDictionary *config;
@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property (nonatomic, assign) BOOL debugMode;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *recentSpeechProbabilities;
@property (nonatomic, assign) NSUInteger maxProbabilityBufferSize;
@property (nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;


- (void)init:(NSDictionary *)config
    resolver:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject;
- (void)start:(RCTPromiseResolveBlock)resolve
     rejecter:(RCTPromiseRejectBlock)reject;
- (void)stop:(RCTPromiseResolveBlock)resolve
    rejecter:(RCTPromiseRejectBlock)reject;
- (void)cleanup;


@end