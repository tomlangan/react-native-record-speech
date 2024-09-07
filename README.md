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

### Manual installation on iOS
```
In XCode, in the project navigator:

* Right click _Libraries_
* Add Files to _[your project's name]_
* Go to `node_modules/react-native-sound-level`
* Add the `.xcodeproj` file

In XCode, in the project navigator, select your project.

* Add the `libRNSoundLevel.a` from the _soundlevel_ project to your project's _Build Phases ➜ Link Binary With Libraries_
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
import RNSoundLevel from 'react-native-sound-level'

const MONITOR_INTERVAL = 250 // in ms

const requestPermission = async () => {
  // request permission to access microphone
  // ...
  if (success) {
    // start monitoring
    RNSoundLevel.start()
    
    // you may also specify a monitor interval (default is 250ms)
    RNSoundLevel.start(MONITOR_INTERVAL)
    
    // or add even more options
    RNSoundLevel.start({
      monitorInterval: MONITOR_INTERVAL,
      samplingRate: 16000, // default is 22050
    })
  }
}

useEffect(() => {
  RNSoundLevel.onNewFrame = (data) => {
    // see "Returned data" section below
    console.log('Sound level info', data)
  }
  
  return () => {
    // don't forget to stop it
    RNSoundLevel.stop()
  }
}, [])

```

### Returned data
```
{
  "id",             // frame number
  "value",          // sound level in decibels, -160 is a silence level
  "rawValue"        // raw level value, OS-dependent
}
```
