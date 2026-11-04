//
//  audiounit.h
//  instrumentation
//
//  GEN-2124: WebRTC/Agora broadcaster audio injection. Hooks the public AudioToolbox
//  AudioUnit C API (AudioUnitInitialize / AudioUnitRender / AudioComponentInstanceDispose)
//  to substitute injected PCM for real microphone input on the mic-capture bus of a live
//  broadcast's underlying RemoteIO/VoiceProcessingIO Audio Unit.
//
//  Makes ios.injectAudio() reach WebRTC broadcasts (e.g. Citizen's Agora-based live
//  broadcast) the same way it already reaches AVCaptureAudioDataOutput/AVAudioRecorder-based
//  mic consumption — no new test-facing API. See QWAudioUnitBridge.h for the format
//  conversion + ring buffer that feeds this hook from MockMediaSource's existing injected-
//  media pipeline, and TASK.md (task workspace) for the full design writeup, validation
//  evidence, and known open risks (viewer-side capture is explicitly out of scope here).
//
