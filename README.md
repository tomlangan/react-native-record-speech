# react-native-record-speech

## Overview

react-native-record-speech is a React Native module for real-time speech detection and audio processing. It provides features like noise reduction, echo cancellation, and audio normalization.

**Warning: Currently, only iOS is supported.**

## Installation

```bash
npm install react-native-record-speech react-native-sound
cd ios && pod install
```

Add to your `Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to detect and analyze speech.</string>
```

## Basic Usage

Here's a basic example of using the `SpeechDetection` API:

```jsx
import React, { useState, useEffect, useRef } from 'react';
import { View, Text, Button, FlatList } from 'react-native';
import { SpeechDetection, defaultSpeechRecorderConfig } from 'react-native-record-speech';
import Sound from 'react-native-sound';

const App = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [recordedAudios, setRecordedAudios] = useState([]);
  const speechDetectionRef = useRef(null);

  useEffect(() => {
    const initSpeechDetection = async () => {
      speechDetectionRef.current = new SpeechDetection();
      await speechDetectionRef.current.init(defaultSpeechRecorderConfig);

      speechDetectionRef.current.on('recording', setIsRecording);
      speechDetectionRef.current.on('speaking', setIsSpeaking);
      speechDetectionRef.current.on('dataBlob', (audioData) => {
        setRecordedAudios(prev => [...prev, audioData]);
      });
    };

    initSpeechDetection();
    return () => speechDetectionRef.current?.cleanup();
  }, []);

  const toggleRecording = () => {
    if (isRecording) {
      speechDetectionRef.current.stopRecording();
    } else {
      speechDetectionRef.current.startRecording();
    }
  };

  const playAudio = (audioData) => {
    const sound = new Sound(audioData.data.uri, '', (error) => {
      if (!error) {
        sound.play();
      }
    });
  };

  return (
    <View>
      <Text>Recording: {isRecording ? 'Yes' : 'No'}</Text>
      <Text>Speaking: {isSpeaking ? 'Yes' : 'No'}</Text>
      <Button
        title={isRecording ? 'Stop Recording' : 'Start Recording'}
        onPress={toggleRecording}
      />
      <FlatList
        data={recordedAudios}
        keyExtractor={(item, index) => index.toString()}
        renderItem={({ item, index }) => (
          <Button
            title={`Play Recording ${index + 1}`}
            onPress={() => playAudio(item)}
          />
        )}
      />
    </View>
  );
};

export default App;
```

## Configuration

Customize the `SpeechDetection` behavior by passing a configuration object to the `init` method:

```javascript
await speechDetectionRef.current.init({
  ...defaultSpeechRecorderConfig,
  detectionMethod: 'voice_activity_detection',
  detectionParams: { threshold: -50 },
  continuousRecording: false,
  onlyRecordOnSpeaking: true,
  silenceTimeout: 1000,
  minimumSpeechDuration: 300,
  features: {
    noiseReduction: true,
    echoCancellation: true,
    normalization: true,
    inputGain: true,
  },
  inputGain: 0.8,
});
```

## Advanced Usage: RNRecordSpeech

For more control, use the `RNRecordSpeech` module directly:

```jsx
import React, { useState, useEffect } from 'react';
import { View, Button, Text } from 'react-native';
import RNRecordSpeech from 'react-native-record-speech/RNRecordSpeech';

const AdvancedAudioRecorder = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [speechProbability, setSpeechProbability] = useState(0);

  useEffect(() => {
    RNRecordSpeech.init({/* Your configuration */});
    return () => RNRecordSpeech.stop();
  }, []);

  const toggleRecording = async () => {
    if (isRecording) {
      await RNRecordSpeech.stop();
    } else {
      RNRecordSpeech.on('frame', (data) => {
        setSpeechProbability(data.speechProbability);
        // Process data.audioData here
      });
      await RNRecordSpeech.start();
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

## License

This project is licensed under the MIT License.