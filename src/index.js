import { NativeModules, NativeEventEmitter, Platform } from 'react-native';
import { SpeechDetection, defaultSpeechRecorderConfig } from './SpeechDetection';

const LINKING_ERROR =
  `The package 'react-native-record-speech' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const supportedEvents = ['frame'];

const RNRecordSpeechModule = NativeModules.RNRecordSpeech
  ? NativeModules.RNRecordSpeech
  : new Proxy(
    {},
    {
      get() {
        throw new Error(LINKING_ERROR);
      },
    }
  );

const eventEmitter = new NativeEventEmitter(RNRecordSpeechModule);

class RNRecordSpeech {
  init(config) {
    return RNRecordSpeechModule.init(config);
  }

  on(event, callback) {
    if (!supportedEvents.includes(event)) {
      console.warn(`Unsupported event type: ${event}. Supported events: `, supportedEvents.join(', ')); 
      return;
    }
    return eventEmitter.addListener(event, callback);
  }

  start() {
    return RNRecordSpeechModule.start();
  }

  stop() {
    return RNRecordSpeechModule.stop();
  }
}

export { SpeechDetection, defaultSpeechRecorderConfig };

export default RNRecordSpeech;