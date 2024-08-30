require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name            = "RNRecordSpeech"

  s.version         = package['1.0']
  s.summary         = package['React Native module for detecting and recording speech']
  s.description     = package['description']
  s.license         = package['MIT']
  s.author          = package['Tom Langan']
  s.homepage        = package['homepage']

  s.platform        = :ios, "13.0"

  s.source          = { :git => package['repository']['url'] }
  s.source_files    = "ios/**/*.{h,m}"
  s.preserve_paths  = "**/*.js"
  s.requires_arc    = true
  s.dependency 'React'
end
