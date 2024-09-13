# react-native-record-speech

## Overview

react-native-record-speech is a React Native module designed for real-time speech detection and audio processing. The main interface, `SpeechDetection`, provides a high-level API for capturing audio, detecting speech, and processing audio data with features like noise reduction, echo cancellation, and audio normalization.

**Warning: Currently, only iOS is supported.**

## Features

- Real-time speech detection
- Audio processing with configurable features:
  - Noise reduction
  - Echo cancellation
  - Audio normalization
  - Input gain control
- Continuous or speech-activated recording
- Customizable detection parameters

## Installation

1. Install the package:

```bash
npm install react-native-record-speech
# or
yarn add react-native-record-speech
```

2. Install dependencies:

```bash
npm install react-native-fs
# or
yarn add react-native-fs
```

3. For iOS, run:

```bash
cd ios && pod install
```

4. Add the following to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to detect and analyze speech.</string>
```

## Basic Usage

Here's a React component example that demonstrates how to use the `SpeechDetection` API, including recording and playback functionality:

```jsx
import React, { useState, useEffect } from 'react';
import { View, Button, Text } from 'react-native';
import { SpeechDetection } from 'react-native-record-speech';
import Sound from 'react-native-sound';

const speechDetection = new SpeechDetection();

const AudioRecorder = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [audioFile, setAudioFile] = useState(null);

  useEffect(() => {
    const initializeSpeechDetection = async () => {
      await speechDetection.init();
      
      speechDetection.on('dataBlob', (audioData, metadata) => {
        if (metadata.isFinal) {
          setAudioFile(audioData.data);
        }
      });
    };

    initializeSpeechDetection();

    return () => {
      speechDetection.cleanup();
    };
  }, []);

  const toggleRecording = async () => {
    if (isRecording) {
      await speechDetection.stopRecording();
    } else {
      await speechDetection.startRecording();
    }
    setIsRecording(!isRecording);
  };

  const playAudio = () => {
    if (audioFile) {
      const sound = new Sound(audioFile.uri, '', (error) => {
        if (error) {
          console.log('Failed to load the sound', error);
          return;
        }
        sound.play((success) => {
          if (success) {
            console.log('Sound played successfully');
          } else {
            console.log('Playback failed due to audio decoding errors');
          }
        });
      });
    }
  };

  return (
    <View>
      <Button
        title={isRecording ? 'Stop Recording' : 'Start Recording'}
        onPress={toggleRecording}
      />
      <Button
        title="Play Recording"
        onPress={playAudio}
        disabled={!audioFile}
      />
      <Text>Recording status: {isRecording ? 'Recording' : 'Not recording'}</Text>
    </View>
  );
};

export default AudioRecorder;
```

## Configuration

You can customize the `SpeechDetection` behavior by passing a configuration object to the `init` method:

```javascript
await speechDetection.init({
  detectionMethod: 'voice_activity_detection',
  detectionParams: {
    threshold: -50.0,
  },
  sampleRate: 48000,
  channels: 1,
  bitsPerSample: 16,
  continuousRecording: false,
  onlyRecordOnSpeaking: true,
  timeSlice: 400,
  silenceTimeout: 400,
  minimumSpeechDuration: 200,
  features: {
    noiseReduction: true,
    echoCancellation: true,
    normalization: true,
    inputGain: true,
  },
  inputGain: 0.8,
});
```

## Advanced Usage: Direct Access to RNRecordSpeech

For more fine-grained control, you can use the `RNRecordSpeech` module directly. Here's an example of a React component that uses `RNRecordSpeech` to start/stop recording and display the speech probability:

```jsx
import React, { useState, useEffect } from 'react';
import { View, Button, Text } from 'react-native';
import RNRecordSpeech from 'react-native-record-speech/RNRecordSpeech';

const AdvancedAudioRecorder = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [speechProbability, setSpeechProbability] = useState(0);

  useEffect(() => {
    const initializeRecorder = async () => {
      await RNRecordSpeech.init({
        // Your configuration here
      });
    };

    initializeRecorder();

    return () => {
      RNRecordSpeech.stop();
    };
  }, []);

  const toggleRecording = async () => {
    if (isRecording) {
      await RNRecordSpeech.stop();
    } else {
      const unsubscribe = RNRecordSpeech.on('frame', (data) => {
        setSpeechProbability(data.speechProbability);
      });
      
      await RNRecordSpeech.start();
      
      // Don't forget to unsubscribe when needed
      // unsubscribe();
    }
    setIsRecording(!isRecording);
  };

  return (
    <View>
      <Button
        title={isRecording ? 'Stop Recording' : 'Start Recording'}
        onPress={toggleRecording}
      />
      <Text>Speech Probability: {speechProbability.toFixed(2)}</Text>
    </View>
  );
};

export default AdvancedAudioRecorder;
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License.