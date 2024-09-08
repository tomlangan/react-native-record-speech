module.exports = {
  presets: [
    ['module:react-native-builder-bob/babel-preset', { modules: 'commonjs' }],
  ],
  plugins: ["transform-inline-environment-variables"]
};
