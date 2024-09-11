import React, { useState, useEffect, useRef } from 'react';
import { View, Text, TouchableOpacity, ScrollView, StyleSheet } from 'react-native';
import { SpeechDetection, defaultSpeechRecorderConfig } from 'react-native-record-speech';
import Sound from 'react-native-sound';


const App = () => {
  const [isRecording, setIsRecording] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [recordedAudios, setRecordedAudios] = useState([]);
  const [mostRecentSpeakingDuration, setMostRecentSpeakingDuration] = useState(0);
  const [longestSilenceDuration, setLongestSilenceDuration] = useState(0);
  const [currentlyPlaying, setCurrentlyPlaying] = useState(null);

  const speechDetectionRef = useRef(null);

  useEffect(() => {
    const initSpeechDetection = async () => {
      speechDetectionRef.current = new SpeechDetection();
      await speechDetectionRef.current.init(defaultSpeechRecorderConfig);

      speechDetectionRef.current.on('recording', setIsRecording);
      speechDetectionRef.current.on('speaking', setIsSpeaking);
      speechDetectionRef.current.on('mostRecentSpeakingDuration', setMostRecentSpeakingDuration);
      speechDetectionRef.current.on('longestSilenceDuration', setLongestSilenceDuration);
      speechDetectionRef.current.on('dataBlob', (audioData) => {
        console.log('Received dataBlob event:', audioData);
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
      }
    };
  }, []);

  const toggleRecording = () => {
    if (isRecording) {
      speechDetectionRef.current.stopRecording();
    } else {
      speechDetectionRef.current.startRecording();
    }
  };

  const playAudio = (audioData, index) => {
    // Stop currently playing audio if any
    if (currentlyPlaying) {
      currentlyPlaying.stop();
      setCurrentlyPlaying(null);
    }

    Sound.setCategory('Playback');
    
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
    <ScrollView style={styles.container}>
      <Text style={styles.title}>Speech Detection Example</Text>

      <View style={styles.statusContainer}>
        <Text>Recording: {isRecording ? 'Yes' : 'No'}</Text>
        <Text>Speaking: {isSpeaking ? 'Yes' : 'No'}</Text>
        <Text>Most Recent Speaking Duration: {mostRecentSpeakingDuration}ms</Text>
        <Text>Longest Silence Duration: {longestSilenceDuration}ms</Text>
      </View>

      <TouchableOpacity style={styles.button} onPress={toggleRecording}>
        <Text style={styles.buttonText}>
          {isRecording ? 'Stop Recording' : 'Start Recording'}
        </Text>
      </TouchableOpacity>

      <Text style={styles.subtitle}>Recorded Audios</Text>
      {recordedAudios.length === 0 ? (
        <Text>No recordings yet</Text>
      ) : (
        recordedAudios.map((audio, index) => (
          <TouchableOpacity
            key={index}
            style={styles.audioButton}
            onPress={() => playAudio(audio, index)}
          >
            <Text style={styles.audioButtonText}>
              {currentlyPlaying && currentlyPlaying === index ? 'Playing: ' : 'Play: '}
              Recording {index + 1} - {formatTimestamp(audio.timestamp)}
            </Text>
          </TouchableOpacity>
        ))
      )}
    </ScrollView>
  );
};


const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 16,
    marginTop: 50,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 16,
  },
  subtitle: {
    fontSize: 18,
    fontWeight: 'bold',
    marginTop: 16,
    marginBottom: 8,
  },
  button: {
    backgroundColor: '#007AFF',
    padding: 6,
    borderRadius: 8,
    alignItems: 'center',
    marginBottom: 16,
    marginTop: 16,
    height: 40,
  },
  buttonText: {
    color: 'white',
    fontSize: 16,
    fontWeight: 'bold',
  },
  statusContainer: {
    marginBottom: 5,
    padding: 10,
    backgroundColor: '#f0f0f0',
    borderRadius: 8,
  },
  audioButton: {
    backgroundColor: '#4CD964',
    padding: 8,
    borderRadius: 8,
    marginBottom: 8,
  },
  audioButtonText: {
    color: 'white',
    fontSize: 14,
    textAlign: 'center',
  },
});

export default App;