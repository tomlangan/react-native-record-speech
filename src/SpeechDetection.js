import {
  arrayBufferToBase64,
  concatenateBase64BlobsToArrayBuffer,
  calculateBase64ByteLength,
} from "./utils/bufferutils";
import RNFS from 'react-native-fs';
import { v4 as uuidv4 } from 'uuid';
import { EventEmitter } from './utils/eventemitter';
import RNRecordSpeech from './RNRecordSpeech';
import lamejs from 'lamejs';

export const defaultSpeechRecorderConfig = {
  detectionMethod: 'volume_threshold',
  detectionParams: {
    threshold: -30.0,
  },
  sampleRate: 44100,
  channels: 1,
  bitsPerSample: 16,
  wavFile: 'audio.wav',
  monitorInterval: 250,
  continuousRecording: false,
  onlyRecordOnSpeaking: true,
  timeSlice: 500,
  speechInterval: 40,
  silenceTimeout: 750,
  minimumSpeechDuration: 200,
  debug: false,
};

export class SpeechDetection extends EventEmitter {
  constructor() {
    super();
    this.config = {};
    this.chunks = [];
    this.tempChunks = [];
    this.waitingForFinalChunk = false;
    this.speakingState = 'no_speech';
    this.encoder = null;
    this.currentSpeakingStartTime = null;
    this.silenceStartTime = null;
    this.speaking = false;
    this.recording = false;
    this.listeningForSpeech = false;
    this.speakingLevelsDetected = false;
    this.finalDataCallbackTimeout = null;
    this.mostRecentSpeakingDuration = 0;
    this.longestSilenceDuration = 0;
  }

  async init(config = {}) {
    this.config = {
      ...defaultSpeechRecorderConfig,
      ...config,
    };

    await RNRecordSpeech.init(this.config);

    this.setupEventListeners();

    if (!this.encoder) {
      this.encoder = new lamejs.Mp3Encoder(1, this.config.sampleRate, 128);
    }
  }

  setupEventListeners() {
    RNRecordSpeech.on('frame', this.onFrame);
  }

  removeEventListeners() {
    RNRecordSpeech.off('frame');
  }

  onFrame = (data) => {
    this.onDataAvailable(data.audioData);
    const isSpeaking = data.speechProbability > 0.75;
    this.processSpeechEvent(isSpeaking);
    console.log('onFrame ', JSON.stringify(data));
    console.log(`onFrame ${isSpeaking ? 'YES' : 'NO '} speechProbability=${data.speechProbability}`);
    console.log('onFrame ============================');
  }

  async startRecording() {
    if (!this.recording) {
      try {
        await RNRecordSpeech.start();
        this.recording = true;
        this.emit('recording', true);
        if (!this.config.onlyRecordOnSpeaking) {
          this.onStartSpeaking();
        }
      } catch (err) {
        console.error('startRecording error:', err);
      }
    }
  }

  async stopRecording() {
    if (this.recording) {
      if ((!this.config.onlyRecordOnSpeaking || this.speaking) && this.chunks.length > 0) {
        this.waitingForFinalChunk = true;
        this.setSpeakingState('getting_final_chunk');
        this.setFinalDataCallback();
      } else {
        await this.onStopRecording();
      }
    }
  }

  async onStopRecording() {
    if (this.recording) {
      await RNRecordSpeech.stop();
      this.recording = false;
      this.emit('recording', false);
      if (!this.config.onlyRecordOnSpeaking) {
        this.onSendSpeechData();
      }
    }
    this.removeEventListeners();
  }

  onStartSpeaking() {
    this.config.debug && console.log('start speaking');
    this.processSpeechEvent(true);
  }

  startSpeechTimer() {
    this.cancelSpeechTimer();
    this.speechTimer = setTimeout(() => {
      this.config.debug && console.log("Minimum speech duration met");
      if (!this.speaking) {
        this.speaking = true;
        this.setSpeakingState('speaking');
        this.emit('speaking', true);
        if (this.config.onlyRecordOnSpeaking) {
          this.startRecording();
        }
      }
    }, this.config.minimumSpeechDuration);
  }

  cancelSpeechTimer() {
    if (this.speechTimer) {
      this.config.debug && console.log("Cancel speech timer");
      clearTimeout(this.speechTimer);
      this.speechTimer = null;
    }
  }

  async onSilenceTimeout() {
    this.config.debug && console.log("Silence timeout");
    if (this.speaking) {
      this.speaking = false;
      this.emit('speaking', false);
      if (this.config.onlyRecordOnSpeaking) {
        await this.stopRecording();
      }
    }
    this.waitingForFinalChunk = true;
    console.log("SpeechDetection: onSilenceTimeout chunk length=", this.chunks.length);
    this.setSpeakingState('getting_final_chunk');
    this.setFinalDataCallback();

    this.tempChunks = [];

    this.silenceStartTime = null;
  }

  startSilenceTimer() {
    this.cancelSilenceTimer();
    this.silenceStartTime = Date.now();
    this.silenceTimer = setTimeout(() => {
      this.onSilenceTimeout();
    }, this.config.silenceTimeout);
  }

  cancelSilenceTimer() {
    if (this.silenceTimer) {
      this.config.debug && console.log("Cancel silence timer");
      clearTimeout(this.silenceTimer);
      this.silenceTimer = null;
    }
    this.silenceStartTime = null;
  }

  updateLongestSilence() {
    if (this.silenceStartTime) {
      const currentSilenceDuration = Date.now() - this.silenceStartTime;
      this.config.debug && console.log("Silence duration:", currentSilenceDuration);
      if (currentSilenceDuration > this.longestSilenceDuration) {
        this.longestSilenceDuration = currentSilenceDuration;
        this.emit('longestSilenceDuration', this.longestSilenceDuration);
      }
    }
  }

  processSpeechEvent(isSpeaking) {
    const currentTime = Date.now();
    if (isSpeaking) {
      if (this.currentSpeakingStartTime === null) {
        this.currentSpeakingStartTime = currentTime;
      }

      switch (this.speakingState) {
        case 'no_speech':
          this.startSpeechTimer();
          this.setSpeakingState('waiting_for_min_duration');
          break;
        case 'waiting_for_silence_timeout':
          this.cancelSilenceTimer();
          if (this.tempChunks.length > 0) {
            this.chunks = [...this.chunks, ...this.tempChunks];
            this.tempChunks = [];
          }
          this.updateLongestSilence();
          this.setSpeakingState('speaking');
          break;
        case 'getting_final_chunk':
          this.waitingForFinalChunk = false;
          this.cancelFinalDataCallback();
          this.setSpeakingState('speaking');
          break;
      }
    } else {
      if (this.currentSpeakingStartTime !== null) {
        const speakingDuration = currentTime - this.currentSpeakingStartTime;
        this.config.debug && console.log("Speaking duration:", speakingDuration);
        this.config.debug && console.log("chunk length:", this.chunks.length);
        this.mostRecentSpeakingDuration = speakingDuration;
        this.emit('mostRecentSpeakingDuration', this.mostRecentSpeakingDuration);
        this.currentSpeakingStartTime = null;
      }

      switch (this.speakingState) {
        case 'waiting_for_min_duration':
          this.cancelSpeechTimer();
          this.setSpeakingState('no_speech');
          break;
        case 'speaking':
          this.startSilenceTimer();
          this.setSpeakingState('waiting_for_silence_timeout');
          break;
      }
    }
  }

  onStopSpeaking() {
    this.config.debug && console.log('stop speaking');
    this.processSpeechEvent(false);
  }

  setSpeakingState(state) {
    console.log(`Speaking state: ${this.speakingState} -> ${state}`);
    this.speakingState = state;
  }

  onDataAvailable(data) {
    if (data === undefined || data === null || typeof data !== 'string') {
      console.error('Received data is undefined or null');
      return;
    }

    let finalData = data;

    const addChunkToCircularBuffer = (chunk) => {
      if (this.chunks.length > 2) {
        this.chunks.shift();
      }
      this.chunks.push(chunk);
    };

    const addChunkToRecording = (chunk) => {
      this.chunks.push(chunk);
    };

    if (this.config.onlyRecordOnSpeaking) {
      switch (this.speakingState) {
        case 'getting_final_chunk':
          if (!this.waitingForFinalChunk) {
            throw new Error('Unexpected state: getting_final_chunk but not waiting for final chunk');
          }
          this.waitingForFinalChunk = false;
          this.chunks.push(finalData);
          this.setSpeakingState('no_speech');
          this.onSendSpeechData();
          break;
        case 'speaking':
        case 'waiting_for_min_duration':
          addChunkToRecording(finalData);
          break;
        case 'waiting_for_silence_timeout':
          this.tempChunks.push(finalData);
          break;
        case 'no_speech':
          addChunkToCircularBuffer(finalData);
          break;
        default:
          console.error('Unexpected speaking state in onDataAvailable:', this.speakingState);
          throw new Error('Unexpected speaking state in onDataAvailable: ' + this.speakingState);
      }
    } else {
      addChunkToRecording(finalData);

      if (this.waitingForFinalChunk) {
        this.waitingForFinalChunk = false;
        this.onSendSpeechData();
      }
    }
  }

  async createFileObjectFromBase64(audioBuffer, mimeType) {
    const path = RNFS.CachesDirectoryPath + '/';
    let fileName = uuidv4() + ".mp3";
    const rawBufferFile = path + fileName;
    const mime_type = mimeType || "audio/mp3";

    const dirExists = await RNFS.exists(path);
    if (!dirExists) {
      await RNFS.mkdir(path);
    }

    await RNFS.writeFile(rawBufferFile, audioBuffer, 'base64');

    let fileUri = Platform.select({
      ios: rawBufferFile,
      android: 'file://' + rawBufferFile,
      default: 'file://' + rawBufferFile,
    });

    var file = { uri: fileUri, name: fileName, type: mime_type };

    return file;
  }

  setFinalDataCallback() {
    this.cancelFinalDataCallback();

    this.finalDataCallbackTimeout = setTimeout(() => {
      this.config.debug && console.log("Final data callback timeout");
      this.setSpeakingState('no_speech');
      this.onSendSpeechData();
    }, this.config.timeSlice * 2);
  }

  cancelFinalDataCallback() {
    if (this.finalDataCallbackTimeout) {
      this.config.debug && console.log("Cancel final data callback");
      clearTimeout(this.finalDataCallbackTimeout);
      this.finalDataCallbackTimeout = null;
    }
  }

  onSendSpeechData = async () => {
    console.log('onSendSpeechData length=', this.chunks.length);

    this.cancelFinalDataCallback();

    if (this.chunks.length > 0) {

        const allChunks = this.chunks;

        this.chunks = [];
        this.tempChunks = [];

        const arrayBuffer = await concatenateBase64BlobsToArrayBuffer(allChunks);
        const mp3buffer = this.encoder.encodeBuffer(new Int16Array(arrayBuffer));
        const base64inputbuffer = arrayBufferToBase64(mp3buffer);
        const fileBlob = await this.createFileObjectFromBase64(base64inputbuffer, "audio/mp3");

        const audioData = {
        data: fileBlob,
        mimeType: 'audio/mp3',
        size: calculateBase64ByteLength(base64inputbuffer),
        source: 'blob'
        };

        console.log('Sending speech data:', this.chunks.length, audioData.size);
        this.emit('dataBlob', audioData, { isFinal: true });

        if (this.silenceStartTime) {
        const silenceDuration = Date.now() - this.silenceStartTime;
        if (silenceDuration > this.longestSilenceDuration) {
            this.longestSilenceDuration = silenceDuration;
            this.emit('longestSilenceDuration', this.longestSilenceDuration);
        }
        }
    }

    console.log("Continuous recording: ", this.config.continuousRecording);
    if (!this.config.continuousRecording) {
      await this.onStopRecording();
    }    
  };

  calculateBase64ByteLength(base64String) {
    const padding = base64String.endsWith('==') ? 2 : base64String.endsWith('=') ? 1 : 0;
    return (base64String.length * 3) / 4 - padding;
  }
  
  cleanup() {
    this.stopRecording();
    this.removeEventListeners();
    this.chunks = [];
    if (this.encoder) {
      this.encoder.flush();
      this.encoder = null;
    }
    this.cancelSilenceTimer();
    this.cancelSpeechTimer();
    this.cancelFinalDataCallback();
  }
}
