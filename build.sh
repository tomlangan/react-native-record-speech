#!/bin/bash

# If there are any errors, exit the script
set -e

cd example
yarn install
cd ios
pod install
cd ..
cd ..
yarn example ios

