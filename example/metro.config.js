const path = require('path');
const { getDefaultConfig } = require('@react-native/metro-config');
const { getConfig } = require('react-native-builder-bob/metro-config');
const pkg = require('../package.json');

const root = path.resolve(__dirname, '..');
const nodeModulesPath = path.resolve(root, 'node_modules');

/**
 * Metro configuration
 * https://facebook.github.io/metro/docs/configuration
 *
 * @type {import('metro-config').MetroConfig}
 */
module.exports = (async () => {
  const defaultConfig = await getDefaultConfig(__dirname);
  const builderBobConfig = getConfig(defaultConfig, {
    root,
    pkg,
    project: __dirname,
    resolver: {
      sourceExts: ['js', 'json', 'ts', 'tsx', 'jsx'],
      nodeModulesPaths: [nodeModulesPath],
    },
    watchFolders: [root],
  });

  return {
    ...builderBobConfig,
    resolver: {
      ...builderBobConfig.resolver,
      extraNodeModules: new Proxy(
        {},
        {
          get: (target, name) => {
            return path.join(nodeModulesPath, name);
          },
        }
      ),
    },
    watchFolders: [
      ...builderBobConfig.watchFolders,
      nodeModulesPath,
    ],
  };
})();