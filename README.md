A package to dynamically measure sound input level in React Native applications.
Can be used to help user to adjust microphone sensitivity.

### Installation

Install the npm package and link it to your project:

```
npm install react-native-record-speech react-native-fs
# or
yarn add react-native-record-speech react-native-fs
```

On *iOS* you need to add a usage description to `Info.plist`:

```
<key>NSMicrophoneUsageDescription</key>
<string>This sample uses the microphone to analyze sound level.</string>
```

On *Android* you need to add a permission to `AndroidManifest.xml`:

```
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

### React Native 0.60+
To make it run correctly on iOS you may need the following:
1. Add `pod 'react-native-sound-level', :podspec => '../node_modules/react-native-sound-level/RNSoundLevel.podspec'` to your `ios/Podfile` file.
2. Unlink the library if linked before (`react-native unlink react-native-sound-level`).
3. Run `pod install` from within your project `ios` directory


### Usage

1. Request permission to access microphone, handle the UI by yourself.
You may use [react-native-permissions](https://www.npmjs.com/package/react-native-permissions) package or simply
[PermissionsAndroid](https://reactnative.dev/docs/permissionsandroid) module.
2. Configure the monitor and start it.
3. Makes sense to stop it when not used.

```ts
See Example app for usage
```
