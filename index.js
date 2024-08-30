import { NativeModules, NativeEventEmitter } from 'react-native';

const { RNRecordSpeech } = NativeModules;
const eventEmitter = new NativeEventEmitter(RNRecordSpeech);

class RNRecordSpeechModule {
  init(params) {
    return RNRecordSpeech.init(params);
  }

  on(event, callback) {
    RNRecordSpeech.on(event); // This call is mostly for logging purposes
    return eventEmitter.addListener(event, callback);
  }

  start() {
    return RNRecordSpeech.start();
  }

  stop() {
    return RNRecordSpeech.stop();
  }
}

export default new RNRecordSpeechModule();