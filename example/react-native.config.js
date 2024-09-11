const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');
const path = require('path');
const pkg = require('../package.json');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * @type {import('metro-config').MetroConfig}
 */
const config = {
  dependencies: {
    [pkg.name]: {
      root: path.join(__dirname, '..'),
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
