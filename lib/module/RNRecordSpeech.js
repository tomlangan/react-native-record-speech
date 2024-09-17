"use strict";

import { NativeModules, NativeEventEmitter, Platform } from 'react-native';
const LINKING_ERROR = `The package 'react-native-record-speech' doesn't seem to be linked. Make sure: \n\n` + Platform.select({
  ios: "- You have run 'pod install'\n",
  default: ''
}) + '- You rebuilt the app after installing the package\n' + '- You are not using Expo Go\n';
const supportedEvents = ['frame'];
const RNRecordSpeechModule = NativeModules.RNRecordSpeech ? NativeModules.RNRecordSpeech : new Proxy({}, {
  get() {
    throw new Error(LINKING_ERROR);
  }
});
console.log("RNRecordSpeechModule", RNRecordSpeechModule);
const eventEmitter = new NativeEventEmitter(RNRecordSpeechModule);
console.log("eventEmitter", eventEmitter);
class RNRecordSpeech {
  constructor() {
    this.initialized = false;
  }
  async init(config) {
    await RNRecordSpeechModule.init(config);
    this.initialized = true;
  }
  on(event, callback) {
    if (!supportedEvents.includes(event)) {
      console.warn(`Unsupported event type: ${event}. Supported events: `, supportedEvents.join(', '));
      return;
    }
    eventEmitter.addListener(event, callback);
    return () => eventEmitter.removeAllListeners(event);
  }
  start() {
    if (!this.initialized) {
      throw new Error('You must call init() before calling start()');
    }
    return RNRecordSpeechModule.start();
  }
  stop() {
    return RNRecordSpeechModule.stop();
  }
  normalizeAudio(base64AudioData, gain) {
    if (typeof base64AudioData !== 'string') {
      throw new Error('audioData must be a base64 encoded string');
    }
    return RNRecordSpeechModule.normalizeAudio(base64AudioData, gain);
  }
  convertFloat32ToInt16(base64AudioData) {
    if (typeof base64AudioData !== 'string') {
      throw new Error('audioData must be a base64 encoded string');
    }
    return RNRecordSpeechModule.convertFloat32ToInt16(base64AudioData);
  }
}
export default new RNRecordSpeech();
//# sourceMappingURL=RNRecordSpeech.js.map