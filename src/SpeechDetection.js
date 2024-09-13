import {
  arrayBufferToBase64,
  concatenateBase64BlobsToArrayBuffer,
  calculateBase64ByteLength,
} from "./utils/bufferutils";
import RNFS from 'react-native-fs';
import { EventEmitter } from './utils/eventemitter';
import RNRecordSpeech from './RNRecordSpeech';
import lamejs from 'lamejs';

export const defaultSpeechRecorderConfig = {
  // 'volume_threshold' or 'voice_activity_detection'
  detectionMethod: 'voice_activity_detection',
  detectionParams: {
    threshold: -50.0,
  },
  sampleRate: 48000,
  channels: 1,
  bitsPerSample: 16,
  wavFile: 'audio.wav',
  continuousRecording: false,
  onlyRecordOnSpeaking: true,
  timeSlice: 400,
  silenceTimeout: 400,
  minimumSpeechDuration: 200,
  debug: false,
  features: {
    noiseReduction: true,
    echoCancellation: true,
    normalization: true,  
    inputGain: true,
  },
  inputGain: 0.8,
};

// avoid dependency on native iOS uuid pod 
function generatePseudoUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
    var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

const INTRO_OUTRO_CHUNK_COUNT = 1;

export class SpeechDetection extends EventEmitter {
  constructor() {
    super();
    this.config = {};
    this.chunks = [];
    this.tempChunks = [];
    this.trailingChunksToAdd = 0;
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
    this.unregisterCallback = null;
  }

  async init(config = {}) {
    this.config = {
      ...defaultSpeechRecorderConfig,
      ...config,
      features: {
        ...defaultSpeechRecorderConfig.features,
        ...(config.features || {})
      }
    };

    await RNRecordSpeech.init(this.config);

    if (!this.encoder) {
      this.encoder = new lamejs.Mp3Encoder(1, this.config.sampleRate, 128);
    }
  }

  setupEventListeners() {
    this.unregisterCallback = RNRecordSpeech.on('frame', this.onFrame);
  }

  removeEventListeners() {
    if (this.unregisterCallback) {
      this.unregisterCallback();
      this.unregisterCallback = null;
    }
  }

  onFrame = (data) => {
    this.onDataAvailable(data.audioData);
    const isSpeaking = data.speechProbability > 0.75;
    this.config.debug && console.log(`${data.frameNumber} ${isSpeaking ? "+" : "-"} PROB ${data.speechProbability} `, data.info);
    this.processSpeechEvent(isSpeaking);
  }

  async startRecording() {
    if (!this.recording) {
      try {
        this.setupEventListeners();

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
        this.trailingChunksToAdd = INTRO_OUTRO_CHUNK_COUNT;
        this.setSpeakingState('getting_final_chunks');
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

    // if there are already chunks in tempChunks, add the first one to chunks
    // and set the speaking state to 'no_speech'. If there are no chunks in
    // tempChunks, we'll wait for the final chunk to arrive.
    
    this.trailingChunksToAdd = INTRO_OUTRO_CHUNK_COUNT;
    if (this.tempChunks.length > 0) {
      const chunksToAdd = this.tempChunks.length > this.trailingChunksToAdd ? this.tempChunks.slice(0, this.trailingChunksToAdd) : this.tempChunks;
      console.log("onSilenceTimeout: GRABBING TEMP CHUNKS: ", chunksToAdd.length);
      this.chunks = [...this.chunks, ...chunksToAdd];
      this.trailingChunksToAdd -= chunksToAdd.length;
    }

    if (this.trailingChunksToAdd === 0) {
      this.setSpeakingState('no_speech');
      this.onSendSpeechData();
    } else {
      console.log("onSilenceTimeout: WAITING FOR FINAL CHUNK");
      this.setSpeakingState('getting_final_chunks');
      this.setFinalDataCallback();
    }

    this.tempChunks = [];
    this.silenceStartTime = null;
  };

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
        case 'getting_final_chunks':
          this.trailingChunksToAdd = 0;
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
    this.config.debug && console.log(`Speaking state: ${this.speakingState} -> ${state}`);
    this.speakingState = state;
  }

  onDataAvailable(data) {
    if (data === undefined || data === null || typeof data !== 'string') {
      console.error('Received data is undefined or null');
      return;
    }

    let finalData = data;

    const addChunkToCircularBuffer = (chunk) => {
      if (this.chunks.length > INTRO_OUTRO_CHUNK_COUNT) {
        this.chunks.shift();
      }
      this.chunks.push(chunk);
    };

    const addChunkToRecording = (chunk) => {
      this.chunks.push(chunk);
    };

    if (this.config.onlyRecordOnSpeaking) {
      switch (this.speakingState) {
        case 'getting_final_chunks':
          if (!this.trailingChunksToAdd == 0) {
            throw new Error('Unexpected state: getting_final_chunks but not waiting for final chunk');
          }
          this.trailingChunksToAdd--;
          console.log("TRAILING CHUNKS LEFT: ", this.trailingChunksToAdd);
          this.chunks.push(finalData);
          if (this.trailingChunksToAdd === 0) {
            this.setSpeakingState('no_speech');
            this.onSendSpeechData();
          }
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

      if (this.trailingChunksToAdd > 0) {
        this.trailingChunksToAdd--;
        if (this.trailingChunksToAdd === 0) {
          this.onSendSpeechData();
        }
      }
    }
  }

  async createFileObjectFromBase64(audioBuffer, mimeType) {
    const path = RNFS.CachesDirectoryPath + '/';
    let fileName = generatePseudoUUID() + ".mp3";
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
    this.removeEventListeners();
    this.stopRecording();
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
