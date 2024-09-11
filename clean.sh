#!/bin/bash
rm -rf node_modules
rm -rf *.lock
rm -rf package-lock.json
cd example
rm -rf node_modules
rm -rf *.lock
rm -rf package-lock.json
cd ios
rm -rf Pods
rm -rf Podfile.lock
rm -rf build
cd ..
cd android
rm -rf build
rm -rf .gradle
cd ..
cd ..
