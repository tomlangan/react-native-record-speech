import React, { useState, useEffect, useRef } from 'react';
import { View, Text, TouchableOpacity, ScrollView, StyleSheet, Switch, FlatList, SafeAreaView } from 'react-native';
import { SpeechDetection, defaultSpeechRecorderConfig } from 'react-native-record-speech';
import Sound from 'react-native-sound';
import { Settings } from './Settings';

const App = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [recordedAudios, setRecordedAudios] = useState([]);
  const [mostRecentSpeakingDuration, setMostRecentSpeakingDuration] = useState(0);
  const [longestSilenceDuration, setLongestSilenceDuration] = useState(0);
  const [currentlyPlaying, setCurrentlyPlaying] = useState(null);

  // State variables for settings
  const [detectionMethod, setDetectionMethod] = useState(defaultSpeechRecorderConfig.detectionMethod);
  const [volumeThreshold, setVolumeThreshold] = useState(defaultSpeechRecorderConfig.detectionParams.threshold.toString());
  const [continuousRecording, setContinuousRecording] = useState(defaultSpeechRecorderConfig.continuousRecording);
  const [onlyRecordOnSpeaking, setOnlyRecordOnSpeaking] = useState(defaultSpeechRecorderConfig.onlyRecordOnSpeaking);
  const [silenceTimeout, setSilenceTimeout] = useState(defaultSpeechRecorderConfig.silenceTimeout.toString());
  const [minimumSpeechDuration, setMinimumSpeechDuration] = useState(defaultSpeechRecorderConfig.minimumSpeechDuration.toString());
  const [noiseReduction, setNoiseReduction] = useState(defaultSpeechRecorderConfig.features.noiseReduction);
  const [echoCancellation, setEchoCancellation] = useState(defaultSpeechRecorderConfig.features.echoCancellation);

  const speechDetectionRef = useRef(null);

  useEffect(() => {
    const initSpeechDetection = async () => {

      Sound.setCategory('Playback', false);

      speechDetectionRef.current = new SpeechDetection();
      await speechDetectionRef.current.init({
        ...defaultSpeechRecorderConfig,
        detectionMethod,
        detectionParams: { threshold: parseFloat(volumeThreshold) },
        continuousRecording,
        onlyRecordOnSpeaking,
        silenceTimeout: parseInt(silenceTimeout),
        minimumSpeechDuration: parseInt(minimumSpeechDuration),
        debug: true,
        features: {
          noiseReduction,
          echoCancellation,
        },
      });

      speechDetectionRef.current.on('recording', setIsRecording);
      speechDetectionRef.current.on('speaking', setIsSpeaking);
      speechDetectionRef.current.on('mostRecentSpeakingDuration', setMostRecentSpeakingDuration);
      speechDetectionRef.current.on('longestSilenceDuration', setLongestSilenceDuration);
      speechDetectionRef.current.on('dataBlob', (audioData) => {
        const audioWithTimestamp = {
          ...audioData,
          timestamp: new Date().toISOString(),
        };
        setRecordedAudios((prevAudios) => [...prevAudios, audioWithTimestamp]);
      });
    };

    initSpeechDetection();

    return () => {
      if (speechDetectionRef.current) {
        speechDetectionRef.current.cleanup();
        speechDetectionRef.current = null;
      }
    };
  }, [detectionMethod, volumeThreshold, continuousRecording, onlyRecordOnSpeaking, silenceTimeout, minimumSpeechDuration, noiseReduction, echoCancellation]);

  const toggleRecording = () => {
    if (isRecording) {
      speechDetectionRef.current.stopRecording();
    } else {

      Sound.setActive(true);
      Sound.setCategory('PlayAndRecord', false);

      speechDetectionRef.current.startRecording();
    }
  };

  const playAudio = (audioData, index) => {
    // Stop currently playing audio if any
    if (currentlyPlaying) {
      currentlyPlaying.stop();
      setCurrentlyPlaying(null);
    }

    Sound.setCategory('Playback', false);
    
    // Create a new Sound instance
    const sound = new Sound(audioData.data.uri, '', (error) => {
      if (error) {
        console.log('Failed to load the sound', error);
        return;
      }
      
      // Play the sound
      sound.play((success) => {
        if (success) {
          console.log('Successfully finished playing');
        } else {
          console.log('Playback failed due to audio decoding errors');
        }
        setCurrentlyPlaying(null);
      });
    });

    setCurrentlyPlaying(sound);
  };

  const formatTimestamp = (timestamp) => {
    const date = new Date(timestamp);
    return date.toLocaleString();
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <View style={styles.container}>
        <Text style={styles.title}>Speech Detection Example</Text>

        <View style={styles.statusContainer}>
          <Text style={styles.statusText}>Recording: {isRecording ? 'Yes' : 'No'}</Text>
          <Text style={styles.statusText}>Speaking: {isSpeaking ? 'Yes' : 'No'}</Text>
          <Text style={styles.statusText}>Most Recent Speaking Duration: {mostRecentSpeakingDuration}ms</Text>
          <Text style={styles.statusText}>Longest Silence Duration: {longestSilenceDuration}ms</Text>
        </View>

        <TouchableOpacity style={styles.button} onPress={toggleRecording}>
          <Text style={styles.buttonText}>
            {isRecording ? 'Stop Recording' : 'Start Recording'}
          </Text>
        </TouchableOpacity>

        <Text style={styles.subtitle}>Recorded Audios</Text>
        <FlatList
          data={recordedAudios}
          keyExtractor={(item, index) => index.toString()}
          renderItem={({ item, index }) => (
            <TouchableOpacity
              style={styles.audioButton}
              onPress={() => playAudio(item, index)}
            >
              <Text style={styles.audioButtonText}>
                {currentlyPlaying && currentlyPlaying === index ? 'Playing: ' : 'Play: '}
                Recording {index + 1} - {formatTimestamp(item.timestamp)}
              </Text>
            </TouchableOpacity>
          )}
          ListEmptyComponent={<Text style={styles.noRecordingsText}>No recordings yet</Text>}
          style={styles.recordingsList}
        />

        <Text style={styles.subtitle}>Settings</Text>
        <Settings
          settings={{
            detectionMethod: {
              value: detectionMethod,
              items: [
                { label: 'Volume Threshold', value: 'volume_threshold' },
                { label: 'Voice Activity Detection', value: 'voice_activity_detection' },
              ],
            },
            volumeThreshold: {
              value: volumeThreshold,
              items: [
                { label: '-10 dB', value: '-10' },
                { label: '-20 dB', value: '-20' },
                { label: '-30 dB', value: '-30' },
                { label: '-40 dB', value: '-40' },
              ],
            },
            continuousRecording,
            onlyRecordOnSpeaking,
            silenceTimeout: {
              value: silenceTimeout,
              items: [
                { label: '500 ms', value: '500' },
                { label: '800 ms', value: '800' },
                { label: '1000 ms', value: '1000' },
                { label: '1500 ms', value: '1500' },
              ],
            },
            minimumSpeechDuration: {
              value: minimumSpeechDuration,
              items: [
                { label: '100 ms', value: '100' },
                { label: '200 ms', value: '200' },
                { label: '300 ms', value: '300' },
                { label: '500 ms', value: '500' },
              ],
            },
            noiseReduction,
            echoCancellation,
          }}
          onSettingChange={(key, value) => {
            switch (key) {
              case 'detectionMethod':
                setDetectionMethod(value);
                break;
              case 'volumeThreshold':
                setVolumeThreshold(value);
                break;
              case 'continuousRecording':
                setContinuousRecording(value);
                break;
              case 'onlyRecordOnSpeaking':
                setOnlyRecordOnSpeaking(value);
                break;
              case 'silenceTimeout':
                setSilenceTimeout(value);
                break;
              case 'minimumSpeechDuration':
                setMinimumSpeechDuration(value);
                break;
              case 'noiseReduction':
                setNoiseReduction(value);
                break;
              case 'echoCancellation':
                setEchoCancellation(value);
                break;
            }
          }}
        />
      </View>
    </SafeAreaView>
  );
};

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#f5f5f5', // Match this with your app's background color
  },
  container: {
    flex: 1,
    padding: 16,
    backgroundColor: '#f5f5f5',
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 16,
    color: '#333',
  },
  subtitle: {
    fontSize: 20,
    fontWeight: 'bold',
    marginTop: 24,
    marginBottom: 16,
    color: '#333',
  },
  button: {
    backgroundColor: '#007AFF',
    padding: 12,
    borderRadius: 8,
    alignItems: 'center',
    marginBottom: 24,
    marginTop: 16,
  },
  buttonText: {
    color: 'white',
    fontSize: 18,
    fontWeight: 'bold',
  },
  statusContainer: {
    marginBottom: 16,
    padding: 16,
    backgroundColor: '#e0e0e0',
    borderRadius: 8,
  },
  statusText: {
    fontSize: 16,
    marginBottom: 8,
    color: '#333',
  },
  audioButton: {
    backgroundColor: '#4CD964',
    padding: 12,
    borderRadius: 8,
    marginBottom: 12,
  },
  audioButtonText: {
    color: 'white',
    fontSize: 16,
    textAlign: 'center',
  },
  settingContainer: {
    marginBottom: 16,
  },
  settingLabel: {
    fontSize: 16,
    color: '#333',
    marginBottom: 8,
  },
  noRecordingsText: {
    fontSize: 16,
    color: '#666',
    textAlign: 'center',
    marginTop: 16,
  },
  recordingsList: {
    height: 300, // Adjust this value as needed
    marginBottom: 16,
  },
  settingsScrollView: {
    flexGrow: 0,
  },
});

export default App;