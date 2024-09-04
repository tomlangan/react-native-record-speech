package com.tomlangan.RNRecordSpeech;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
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

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

public class RNRecordSpeechModule extends ReactContextBaseJavaModule {

    private static final String TAG = "RNRecordSpeech";

    private Context context;
    private AudioRecord recorder;
    private boolean isRecording = false;
    private int bufferSize;
    private int sampleRate;
    private int channelConfig;
    private int audioFormat;
    private Thread recordingThread;
    private String filePath;
    private int frameNumber = 0;

    public RNRecordSpeechModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.context = reactContext;
    }

    @Override
    public String getName() {
        return "RNRecordSpeech";
    }

    @ReactMethod
    public void init(ReadableMap config) {
      
        Log.w(TAG, "Warning: Android implementation is not fully tested. Expect potential issues.");
      
        sampleRate = config.hasKey("sampleRate") ? config.getInt("sampleRate") : 44100;
        int bitsPerSample = config.hasKey("bitsPerSample") ? config.getInt("bitsPerSample") : 16;
        int channels = config.hasKey("channels") ? config.getInt("channels") : 1;

        channelConfig = (channels == 1) ? AudioFormat.CHANNEL_IN_MONO : AudioFormat.CHANNEL_IN_STEREO;
        audioFormat = (bitsPerSample == 8) ? AudioFormat.ENCODING_PCM_8BIT : AudioFormat.ENCODING_PCM_16BIT;

        bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat);

        String fileName = config.hasKey("wavFile") ? config.getString("wavFile") : "audio.wav";
        filePath = context.getCacheDir().getAbsolutePath() + "/" + fileName;
    }

    @ReactMethod
    public void start(Promise promise) {
        if (isRecording) {
            promise.reject("INVALID_STATE", "Already recording");
            return;
        }

        recorder = new AudioRecord(MediaRecorder.AudioSource.MIC, sampleRate, channelConfig, audioFormat, bufferSize);

        if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
            promise.reject("INITIALIZATION_ERROR", "Failed to initialize AudioRecord");
            return;
        }

        isRecording = true;
        frameNumber = 0;

        recordingThread = new Thread(new Runnable() {
            @Override
            public void run() {
                writeAudioDataToFile();
            }
        }, "AudioRecorder Thread");

        recorder.startRecording();
        recordingThread.start();

        promise.resolve(null);
    }

    @ReactMethod
    public void stop(Promise promise) {
        if (!isRecording) {
            promise.reject("INVALID_STATE", "Not recording");
            return;
        }

        isRecording = false;
        if (recorder != null) {
            recorder.stop();
            recorder.release();
            recorder = null;
        }

        if (recordingThread != null) {
            try {
                recordingThread.join();
            } catch (InterruptedException e) {
                Log.e(TAG, "Error stopping recording thread", e);
            }
            recordingThread = null;
        }

        promise.resolve(filePath);
    }

    private void writeAudioDataToFile() {
        byte[] data = new byte[bufferSize];
        FileOutputStream os = null;

        try {
            os = new FileOutputStream(filePath);
        } catch (IOException e) {
            Log.e(TAG, "Error opening output file", e);
            return;
        }

        while (isRecording) {
            int read = recorder.read(data, 0, bufferSize);
            if (read != AudioRecord.ERROR_INVALID_OPERATION) {
                try {
                    os.write(data);
                } catch (IOException e) {
                    Log.e(TAG, "Error writing to output file", e);
                }

                String base64Audio = Base64.encodeToString(data, Base64.NO_WRAP);
                float level = calculateLevel(data);

                WritableMap event = Arguments.createMap();
                event.putInt("frameNumber", frameNumber++);
                event.putString("audioData", base64Audio);
                event.putDouble("level", level);

                sendEvent("audioData", event);
            }
        }

        try {
            os.close();
        } catch (IOException e) {
            Log.e(TAG, "Error closing output file", e);
        }
    }

    private float calculateLevel(byte[] audioData) {
        long sum = 0;
        for (int i = 0; i < audioData.length; i += 2) {
            short sample = (short) ((audioData[i + 1] << 8) | audioData[i]);
            sum += sample * sample;
        }
        double rms = Math.sqrt(sum / (audioData.length / 2));
        return (float) (20 * Math.log10(rms / 32768));
    }

    private void sendEvent(String eventName, WritableMap params) {
        getReactApplicationContext()
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, params);
    }
}