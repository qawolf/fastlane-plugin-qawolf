# Camera Injection

This module provides comprehensive camera mocking capabilities for iOS applications through method swizzling and runtime injection. It allows automated tests to simulate camera input by intercepting AVFoundation camera APIs and providing mock video/image data.

## Architecture Overview

The camera injection system consists of several key components that work together to intercept and replace camera data across all major AVFoundation camera APIs:

### Core Components

**MockCamera (MockCamera.h/m)**

- Singleton that manages media injection configuration and provides mock frames
- Supports both image and video injection with file watching and hot-reloading
- Handles data URIs, file paths, and HTTP URLs for media sources
- Provides pixel buffer generation for real-time frame injection

**Configuration System**

- File-based configuration via `Documents/.qawolf/media.json`
- Supports JSON format: `{"data": "path/to/media", "type": "image|video", "loop": true}`
- Automatic file watching with hot-reload capabilities
- Backward compatibility with legacy configuration formats

### Injection Components

**AVCapturePhotoProxyInjector (AVCapturePhotoProxyInjector.h/m)**

- Intercepts `AVCapturePhotoOutput.capturePhotoWithSettings:delegate:` calls
- Replaces photo capture with mock images from MockCamera
- Maintains delegate callback compatibility and timing

**AVCaptureVideoDataOutputInjector (AVCaptureVideoDataOutputInjector.h/m)**

- Intercepts `AVCaptureVideoDataOutput` delegate registration
- Replaces real camera frames with mock video frames in real-time
- Preserves sample buffer timing and format metadata

**AVCaptureMovieFileOutputInjector (AVCaptureMovieFileOutputInjector.h/m)**

- Intercepts `AVCaptureMovieFileOutput` recording methods
- Replaces recorded video files with mock video content
- Handles start/stop recording delegate callbacks

**AVCaptureVideoPreviewLayerInjector (AVCaptureVideoPreviewLayerInjector.h/m)**

- Intercepts `AVCaptureVideoPreviewLayer` to show mock video in camera previews
- Provides visual feedback that matches the injected content
- Maintains layer geometry and display properties

## Technical Implementation

### Method Swizzling Pattern

All injectors use the same runtime method swizzling pattern:

```objective-c
// In +load method
Method originalMethod = class_getInstanceMethod([TargetClass class], @selector(originalMethod:));
Method swizzledMethod = class_getInstanceMethod([TargetClass class], @selector(swizzled_originalMethod:));
method_exchangeImplementations(originalMethod, swizzledMethod);
```

### Frame Generation

The MockCamera generates CVPixelBuffer frames through:

1. **Image Mode**: Converts static images to video frames using Core Image
2. **Video Mode**: Uses AVPlayer with AVPlayerItemVideoOutput for frame extraction
3. **Data URIs**: Automatically decodes base64 image/video data to temporary files

### Configuration Management

```json
{
  "data": "path/to/video.mp4", // File path, URL, or data URI
  "type": "video" // "image" or "video" (defaults to "image")
}
```

## Supported Media Sources

### File Types

- **Images**: Any format supported by UIImage (JPG, PNG, HEIC, GIF, BMP, TIFF, WebP)
- **Videos**: Any format supported by AVAsset (MP4, MOV, M4V with H.264/HEVC codecs)

### Source Formats

- **File Paths**: Relative to QAWolf folder or absolute paths
- **HTTP URLs**: Remote image/video resources
- **Data URIs**: Base64-encoded media data (`data:image/jpeg;base64,/9j/4AA...`)

## Integration Points

### AVFoundation APIs Covered

- `AVCapturePhotoOutput` - Photo capture
- `AVCaptureVideoDataOutput` - Video frame streaming
- `AVCaptureMovieFileOutput` - Video recording
- `AVCaptureVideoPreviewLayer` - Camera preview display
- `AVCaptureSession` - Output registration tracking

### Delegate Compatibility

All original delegate methods and callbacks are preserved:

- Photo capture delegates receive mock `AVCapturePhoto` objects
- Video data delegates receive mock `CMSampleBuffer` frames
- Recording delegates get proper start/finish notifications
- Preview layers display injected content seamlessly

## Usage in Tests

### Basic Setup

1. Place media file in `Documents/.qawolf/` folder
2. Create `media.json` configuration file
3. Launch app with instrumentation dylib injected
4. Camera APIs automatically use mock content

### Dynamic Configuration

The system watches for configuration file changes, allowing real-time switching between different media sources during test execution.

### Debugging

All injection activities are logged with `QAWolf:` prefixes for easy identification in device console logs.

## File Structure

```
camera/
├── README.md                              # This documentation
├── MockCamera.h/m                         # Core media injection engine
├── AVCapturePhotoProxyInjector.h/m        # Photo capture interception
├── AVCaptureVideoDataOutputInjector.h/m   # Video data stream interception
├── AVCaptureMovieFileOutputInjector.h/m   # Video recording interception
└── AVCaptureVideoPreviewLayerInjector.h/m # Camera preview interception
```

## Limitations

### Camera Hardware Features

- **Camera Selection**: Cannot select specific cameras (front/back, wide/telephoto/ultra-wide)
- **Camera Controls**: Does not mock hardware controls (zoom, focus, exposure, ISO, white balance)
- **Flash/Torch**: Flash and torch functionality is not mocked
- **Image Stabilization**: Stabilization settings are not simulated

### Display and Layout

- **Aspect Ratio**: Preview layers do not maintain original media aspect ratios
- **Video Gravity**: Preview scaling/cropping modes are not preserved
- **Resolution Matching**: Output resolution may not match camera session presets

### Advanced Features

- **Depth Data**: Portrait mode depth information is not generated
- **Face Detection**: Face/body detection metadata is not provided
- **Multiple Outputs**: Only one media source can be active at a time
- **Real-time Effects**: Filters and real-time processing are not applied to mock content

### Performance

- **Frame Rate**: Locked to 30fps for generated content
- **Memory Usage**: Large videos may impact performance during frame extraction
- **Startup Delay**: Initial frame delivery may have slight delay during player setup

## Compatibility

- **iOS Version**: iOS 10.0+
- **Device Support**: All iOS devices with camera capabilities
- **Language**: Works with Swift and Objective-C applications
- **Frameworks**: Compatible with all AVFoundation-based camera implementations
