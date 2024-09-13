package com.tomlangan.RNRecordSpeech;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.media.audiofx.NoiseSuppressor;
import android.media.audiofx.AcousticEchoCanceler;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class RNRecordSpeechModule extends ReactContextBaseJavaModule {
    private static final String TAG = "RNRecordSpeech";
    private static final int SAMPLE_RATE = 44100;
    private static final int CHANNELS = AudioFormat.CHANNEL_IN_MONO;
    private static final int ENCODING = AudioFormat.ENCODING_PCM_FLOAT;

    private ReactApplicationContext reactContext;
    private AudioRecord audioRecord;
    private boolean isRecording = false;
    private ExecutorService executorService;
    private Handler handler;
    private ReadableMap config;
    private int frameCounter = 0;
    private float runningMaxAmplitude = 0.0f;
    private int sampleCounter = 0;
    private int normalizationInterval;
    private ArrayList<Float> energyHistory;
    private static final int HISTORY_SIZE = 20;

    private NoiseSuppressor noiseSuppressor;
    private AcousticEchoCanceler echoCanceler;

    public RNRecordSpeechModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
        this.handler = new Handler(Looper.getMainLooper());
        this.energyHistory = new ArrayList<>(HISTORY_SIZE);
    }

    @Override
    public String getName() {
        return "RNRecordSpeech";
    }

    @ReactMethod
    public void init(ReadableMap config, Promise promise) {
        this.config = config;
        promise.resolve(Arguments.createMap());
    }

    @ReactMethod
    public void start(Promise promise) {
        if (isRecording) {
            promise.reject("ALREADY_RECORDING", "Recording is already in progress");
            return;
        }

        setupAudioSession();
        setupAudioProcessingChain();

        int bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNELS, ENCODING);
        audioRecord = new AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, CHANNELS, ENCODING, bufferSize);

        if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
            promise.reject("AUDIO_RECORD_ERROR", "Failed to initialize AudioRecord");
            return;
        }

        isRecording = true;
        frameCounter = 0;
        runningMaxAmplitude = 0.0f;
        sampleCounter = 0;
        normalizationInterval = SAMPLE_RATE; // 1 second

        executorService = Executors.newSingleThreadExecutor();
        executorService.execute(this::recordAudio);

        promise.resolve(Arguments.createMap());
    }

    @ReactMethod
    public void stop(Promise promise) {
        if (!isRecording) {
            promise.reject("NOT_RECORDING", "No recording in progress");
            return;
        }

        stopInternal();
        promise.resolve(Arguments.createMap());
    }

    private void setupAudioSession() {
        // Android doesn't have a direct equivalent to iOS's AVAudioSession
        // Most of the audio session management is done automatically
        // We can focus on specific features like noise suppression and echo cancellation
    }

    private void setupAudioProcessingChain() {
        if (isFeatureEnabled("noiseReduction") && NoiseSuppressor.isAvailable()) {
            noiseSuppressor = NoiseSuppressor.create(audioRecord.getAudioSessionId());
            if (noiseSuppressor != null) {
                noiseSuppressor.setEnabled(true);
            }
        }

        if (isFeatureEnabled("echoCancellation") && AcousticEchoCanceler.isAvailable()) {
            echoCanceler = AcousticEchoCanceler.create(audioRecord.getAudioSessionId());
            if (echoCanceler != null) {
                echoCanceler.setEnabled(true);
            }
        }
    }

    private void recordAudio() {
        int timeSlice = config.hasKey("timeSlice") ? config.getInt("timeSlice") : 400;
        int bufferSize = SAMPLE_RATE * (timeSlice / 1000) * 4; // 32-bit float samples
        ByteBuffer buffer = ByteBuffer.allocateDirect(bufferSize);
        buffer.order(ByteOrder.LITTLE_ENDIAN);

        audioRecord.startRecording();

        while (isRecording) {
            int bytesRead = audioRecord.read(buffer, bufferSize, AudioRecord.READ_BLOCKING);
            if (bytesRead > 0) {
                buffer.rewind();
                float[] samples = new float[bytesRead / 4]; // 4 bytes per float
                buffer.asFloatBuffer().get(samples);

                if (isFeatureEnabled("normalization")) {
                    adjustNormalization(samples);
                }

                String base64Audio = Base64.encodeToString(floatToByteArray(samples), Base64.NO_WRAP);
                WritableMap detectionResults = detectSpeech(samples);
                WritableMap info = detectionResults.getMap("info");

                sendFrame(base64Audio, detectionResults.getDouble("speechProbability"), info);

                buffer.clear();
            }
        }
    }

    private void adjustNormalization(float[] samples) {
        float maxAmplitude = 0.0f;
        for (float sample : samples) {
            maxAmplitude = Math.max(maxAmplitude, Math.abs(sample));
        }
        runningMaxAmplitude = Math.max(runningMaxAmplitude, maxAmplitude);

        sampleCounter += samples.length;
        if (sampleCounter >= normalizationInterval) {
            float targetAmplitude = 0.8f;
            float gainAdjustment = (float) (20 * Math.log10(targetAmplitude / runningMaxAmplitude));
            gainAdjustment = Math.min(gainAdjustment, 30.0f);
            gainAdjustment = Math.max(gainAdjustment, -20.0f);

            float gain = (float) Math.pow(10, gainAdjustment / 20);
            for (int i = 0; i < samples.length; i++) {
                samples[i] *= gain;
            }

            runningMaxAmplitude = 0.0f;
            sampleCounter = 0;
        }
    }

    private WritableMap detectSpeech(float[] samples) {
        String detectionMethod = config.getString("detectionMethod");
        if ("voice_activity_detection".equals(detectionMethod)) {
            return detectSpeechUsingVAD(samples);
        } else if ("volume_threshold".equals(detectionMethod)) {
            return detectSpeechUsingVolumeThreshold(samples);
        }

        throw new IllegalArgumentException("Invalid detection method specified.");
    }

    private WritableMap detectSpeechUsingVAD(float[] samples) {
        float energy = 0.0f;
        for (float sample : samples) {
            energy += sample * sample;
        }
        energy /= samples.length;

        float logEnergy = (float) (10 * Math.log10(energy + 1e-10));

        energyHistory.add(logEnergy);
        if (energyHistory.size() > HISTORY_SIZE) {
            energyHistory.remove(0);
        }

        float sum = 0.0f;
        float sumSquares = 0.0f;
        for (float e : energyHistory) {
            sum += e;
            sumSquares += e * e;
        }

        float mean = sum / energyHistory.size();
        float variance = (sumSquares / energyHistory.size()) - (mean * mean);
        variance = Math.max(variance, 0.0f);
        float stdDev = (float) Math.sqrt(variance);

        float zScore = 0.0f;
        if (stdDev > 1e-10) {
            zScore = (logEnergy - mean) / stdDev;
            zScore *= 1.5f;  // Increase sensitivity
        }

        float speechProbability = (float) (1.0 / (1.0 + Math.exp(-zScore)));
        speechProbability = (float) Math.pow(speechProbability, 0.7);
        speechProbability = Math.max(0.0f, Math.min(1.0f, speechProbability));

        WritableMap result = Arguments.createMap();
        result.putDouble("speechProbability", speechProbability);

        WritableMap info = Arguments.createMap();
        info.putDouble("energy", logEnergy);
        info.putDouble("mean", mean);
        info.putDouble("stdDev", stdDev);
        info.putDouble("zScore", zScore);
        info.putDouble("instantProbability", speechProbability);
        result.putMap("info", info);

        return result;
    }

    private WritableMap detectSpeechUsingVolumeThreshold(float[] samples) {
        float sum = 0.0f;
        float maxAmplitude = 0.0f;
        float minSample = Float.MAX_VALUE;
        float maxSample = Float.MIN_VALUE;

        for (float sample : samples) {
            float absValue = Math.abs(sample);
            sum += absValue;
            maxAmplitude = Math.max(maxAmplitude, absValue);
            minSample = Math.min(minSample, sample);
            maxSample = Math.max(maxSample, sample);
        }

        float meanAmplitude = sum / samples.length;
        float maxdb = (float) (20 * Math.log10(maxAmplitude));
        float meandb = (float) (20 * Math.log10(meanAmplitude));

        float threshold = config.hasKey("detectionParams") ? 
            (float) config.getMap("detectionParams").getDouble("threshold") : -40.0f;

        float sensitivity = 5.0f;
        float shift = (float) (Math.log(1.0 / 0.8 - 1.0) / sensitivity);
        float probability = (float) (1.0 / (1.0 + Math.exp(-sensitivity * (maxdb - threshold + shift))));

        WritableMap result = Arguments.createMap();
        result.putDouble("speechProbability", probability);

        WritableMap info = Arguments.createMap();
        info.putDouble("meandb", meandb);
        info.putDouble("maxdb", maxdb);
        info.putDouble("threshold", threshold);
        info.putDouble("minSample", minSample);
        info.putDouble("maxSample", maxSample);
        result.putMap("info", info);

        return result;
    }

    private void sendFrame(String audioData, double speechProbability, WritableMap info) {
        handler.post(() -> {
            WritableMap params = Arguments.createMap();
            params.putString("audioData", audioData);
            params.putDouble("speechProbability", speechProbability);
            params.putMap("info", info);
            params.putInt("frameNumber", frameCounter++);

            sendEvent("frame", params);
        });
    }

    private void sendEvent(String eventName, WritableMap params) {
        reactContext
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, params);
    }

    private void stopInternal() {
        isRecording = false;
        if (audioRecord != null) {
            audioRecord.stop();
            audioRecord.release();
            audioRecord = null;
        }

        if (noiseSuppressor != null) {
            noiseSuppressor.release();
            noiseSuppressor = null;
        }

        if (echoCanceler != null) {
            echoCanceler.release();
            echoCanceler = null;
        }

        if (executorService != null) {
            executorService.shutdown();
            executorService = null;
        }
    }

    private boolean isFeatureEnabled(String featureName) {
        return config != null && config.hasKey("features") && 
               config.getMap("features").hasKey(featureName) && 
               config.getMap("features").getBoolean(featureName);
    }

    private byte[] floatToByteArray(float[] floatArray) {
        ByteBuffer buffer = ByteBuffer.allocate(floatArray.length * 4);
        buffer.order(ByteOrder.LITTLE_ENDIAN);
        for (float f : floatArray) {
            buffer.putFloat(f);
        }
        return buffer.array();
    }

    @Override
    public void onCatalystInstanceDestroy() {
        stopInternal();
        super.onCatalystInstanceDestroy();
    }
}