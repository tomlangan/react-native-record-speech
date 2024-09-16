export type RNRecordSpeechConfig = {
  sampleRate?: number;
  channels?: number;
  wavFile?: string;
  monitorInterval?: number;
};

export type RNRecordSpeechData = {
  /**
   * @description Frame number
   */
  frameNumber: number;

  /**
   * @description Base64 encoded audio data
   */
  audioData: string;

  /**
   * @description Sound level in decibels
   * @description -160 is silence
   */
  level: number;
};

export type RNRecordSpeechModuleType = {
  init: (config: RNRecordSpeechConfig) => void;
  start: () => void;
  stop: () => Promise<string>;
  on: (event: 'frame', callback: (result: RNRecordSpeechData) => void) => void;
};

declare const RNRecordSpeech: RNRecordSpeechModuleType;

export default RNRecordSpeech;