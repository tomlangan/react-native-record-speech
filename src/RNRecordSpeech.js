import { NativeModules, NativeEventEmitter, Platform } from 'react-native';

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

console.log("RNRecordSpeechModule", RNRecordSpeechModule);
const eventEmitter = new NativeEventEmitter(RNRecordSpeechModule);
console.log("eventEmitter", eventEmitter);

class RNRecordSpeech {
  constructor() {
    this.listeners = new Map();
  }

  async init(config) {
     await RNRecordSpeechModule.init(config);
  }

  on(event, callback) {
    if (!supportedEvents.includes(event)) {
      console.warn(`Unsupported event type: ${event}. Supported events: `, supportedEvents.join(', ')); 
      return;
    }
    const listener = eventEmitter.addListener(event, callback);
    this.listeners.set(callback, listener);
    return () => this.off(event, callback);
  }

  off(event, callback) {
    const listener = this.listeners.get(callback);
    if (listener) {
      listener.remove();
      this.listeners.delete(callback);
    }
  }

  start() {
    return RNRecordSpeechModule.start();
  }

  stop() {
    return RNRecordSpeechModule.stop();
  }
}

export default new RNRecordSpeech();