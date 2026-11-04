//
//  AVAudioEngineInputInjector.h
//  instrumentation
//
//  Makes ios.injectAudio() reach apps that consume the microphone through
//  AVAudioEngine.inputNode (Apple Speech Recognition / SFSpeechRecognizer, custom
//  real-time ML audio processing, level meters, etc.) -- see AVAudioEngineInputInjector.m
//  for the full design rationale and open risks.
//
//  This file enables automatic swizzling of AVAudioEngine when the dylib loads.
//  No public interface is needed -- swizzling happens automatically via +load.
//
