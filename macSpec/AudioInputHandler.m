// AudioSpectrum: A sample app using Audio Unit and vDSP
// By Keijiro Takahashi, 2013, 2014
// https://github.com/keijiro/AudioSpectrum

#import <CoreAudio/CoreAudio.h>

#import "AudioInputHandler.h"
#import "macSpec-Swift.h"

#pragma mark Private method definition

@interface AudioInputHandler ()

- (void)initAudioUnit;
- (void)inputCallback:(AudioUnitRenderActionFlags *)ioActionFlags
          inTimeStamp:(const AudioTimeStamp *)inTimeStamp
          inBusNumber:(UInt32)inBusNumber
        inNumberFrame:(UInt32)inNumberFrame;

@end

#pragma mark Audio Unit callback

static OSStatus InputRenderProc(void *inRefCon,
                                AudioUnitRenderActionFlags *ioActionFlags,
                                const AudioTimeStamp *inTimeStamp,
                                UInt32 inBusNumber,
                                UInt32 inNumberFrame,
                                AudioBufferList *ioData)
{
    AudioInputHandler* owner = (__bridge AudioInputHandler *)(inRefCon);
    [owner inputCallback:ioActionFlags
             inTimeStamp:inTimeStamp
             inBusNumber:inBusNumber
           inNumberFrame:inNumberFrame];
    return noErr;
}

#pragma mark

@implementation AudioInputHandler

#if ! __has_feature(objc_arc)
@synthesize sampleRate = _sampleRate;
@synthesize ringBuffers = _ringBuffers;
#endif

#pragma mark Constructor / destructor

- (id)init
{
    self = [super init];
    if (self) {
        [self initAudioUnit];
    }
    return self;
}

- (void)dealloc
{
    AudioComponentInstanceDispose(_auHAL);
#if ! __has_feature(objc_arc)
    [_ringBuffers release];
    [super dealloc];
#endif
}

#pragma mark Control methods

- (void)start
{
    OSStatus error = AudioOutputUnitStart(_auHAL);
    NSAssert(error == noErr, @"Failed to start the AUHAL (%d).", (int)error);
    (void)error; // To avoid warning.
}

- (void)stop
{
    AudioOutputUnitStop(_auHAL);
}

#pragma mark Private method

- (void)initAudioUnit
{
    //
    // Create an AUHAL instance.
    //
    
    AudioComponent component;
    AudioComponentDescription description;
    
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_HALOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    description.componentFlags = 0;
    description.componentFlagsMask = 0;
    
    component = AudioComponentFindNext(NULL, &description);
    NSAssert(component, @"Failed to find an input device.");
    
    OSStatus error = AudioComponentInstanceNew(component, &_auHAL);
    NSAssert(error == noErr, @"Failed to create an AUHAL instance.");
    
    //
    // Enable the input bus, and disable the output bus.
    //
    
    const UInt32 kInputElement = 1;
    const UInt32 kOutputElement = 0;

    UInt32 enableIO = 1;
    error = AudioUnitSetProperty(_auHAL,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input,
                                 kInputElement,
                                 &enableIO,
                                 sizeof(enableIO));
    NSAssert(error == noErr, @"Failed to enable the input bus.");
    
    enableIO = 0;
    error = AudioUnitSetProperty(_auHAL,
                                 kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output,
                                 kOutputElement,
                                 &enableIO,
                                 sizeof(enableIO));
    NSAssert(error == noErr, @"Failed to disable the output bus.");
    
    //
    // Set the unit to the default input device.
    //
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    AudioDeviceID inputDevice;
    UInt32 size = sizeof(AudioDeviceID);
    
    error = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                       &address,
                                       0,
                                       NULL,
                                       &size,
                                       &inputDevice);
    NSAssert(error == noErr, @"Failed to retrieve the default input device.");

    error = AudioUnitSetProperty(_auHAL,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global,
                                 0,
                                 &inputDevice,
                                 sizeof(inputDevice));
    NSAssert(error == noErr, @"Failed to set the unit to the default input device.");
    
    //
    // Adopt the stream format.
    //
    
    AudioStreamBasicDescription deviceFormat;
    AudioStreamBasicDescription desiredFormat;
    size = sizeof(AudioStreamBasicDescription);
    
    error = AudioUnitGetProperty(_auHAL,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input,
                                 kInputElement,
                                 &deviceFormat,
                                 &size);
    NSAssert(error == noErr, @"Failed to get the input format.");

    error = AudioUnitGetProperty(_auHAL,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 kInputElement,
                                 &desiredFormat,
                                 &size);
    NSAssert(error == noErr, @"Failed to get the output format.");
    
    // Same sample rate, same number of channels.
    desiredFormat.mSampleRate = deviceFormat.mSampleRate;
    desiredFormat.mChannelsPerFrame = deviceFormat.mChannelsPerFrame;
    
    // Canonical audio format.
    desiredFormat.mFormatID = kAudioFormatLinearPCM;
    desiredFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    desiredFormat.mFramesPerPacket = 1;
    desiredFormat.mBytesPerFrame = sizeof(Float32);
    desiredFormat.mBytesPerPacket = sizeof(Float32);
    desiredFormat.mBitsPerChannel = 8 * sizeof(Float32);
    
    error = AudioUnitSetProperty(_auHAL,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output,
                                 kInputElement,
                                 &desiredFormat,
                                 sizeof(AudioStreamBasicDescription));
    NSAssert(error == noErr, @"Failed to set the output format.");
    
    // Store the format information.
    _sampleRate = desiredFormat.mSampleRate;
    
    //
    // Get the buffer frame size.
    //
    
    UInt32 bufferSizeFrames;
    size = sizeof(UInt32);
    
    error = AudioUnitGetProperty(_auHAL,
                                 kAudioDevicePropertyBufferFrameSize,
                                 kAudioUnitScope_Global,
                                 0,
                                 &bufferSizeFrames,
                                 &size);
    NSAssert(error == noErr, @"Failed to get the buffer frame size.");
    
    //
    // Allocate the buffer.
    //
    
    UInt32 bufferSizeBytes = bufferSizeFrames * sizeof(Float32);
    UInt32 channels = deviceFormat.mChannelsPerFrame;
    
    _inputBufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer) * channels);
    _inputBufferList->mNumberBuffers = channels;
    
    for (UInt32 i = 0; i < channels; i++) {
        AudioBuffer *buffer = &_inputBufferList->mBuffers[i];
        buffer->mNumberChannels = 1;
        buffer->mDataByteSize = bufferSizeBytes;
        buffer->mData = malloc(bufferSizeBytes);
    }
    
    //
    // Initialize the ring buffers.
    //
    
    RingBuffer *buffers[channels];
    
    for (UInt32 i = 0; i < channels; i++) {
        buffers[i] = [[RingBuffer alloc] init];
    }
    
    _ringBuffers = [NSArray arrayWithObjects:buffers count:channels];
#if ! __has_feature(objc_arc)
    [_ringBuffers retain];
#endif
    
    //
    // Set up the input callback.
    //
    
    AURenderCallbackStruct cb = { InputRenderProc, (__bridge void *)(self) };
    
    error = AudioUnitSetProperty(_auHAL,
                                 kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global,
                                 0,
                                 &cb,
                                 sizeof(AURenderCallbackStruct));
    NSAssert(error == noErr, @"Failed to set up the input callback.");
    
    //
    // Complete the initialization.
    //
    
    error = AudioUnitInitialize(_auHAL);
    NSAssert(error == noErr, @"Failed to initialize the AUHAL.");
}

- (void)inputCallback:(AudioUnitRenderActionFlags *)ioActionFlags
          inTimeStamp:(const AudioTimeStamp *)inTimeStamp
          inBusNumber:(UInt32)inBusNumber
        inNumberFrame:(UInt32)inNumberFrame
{
    // Retrieve input samples.
    OSStatus error = AudioUnitRender(_auHAL,
                                     ioActionFlags,
                                     inTimeStamp,
                                     inBusNumber,
                                     inNumberFrame,
                                     _inputBufferList);
    
    if (error == noErr) {
        for (UInt32 i = 0; i < _inputBufferList->mNumberBuffers; i++) {
            AudioBuffer *input = &_inputBufferList->mBuffers[i];
            [[_ringBuffers objectAtIndex:i]  pushSamples:input->mData count:input->mDataByteSize / sizeof(Float32)];
        }
    }
}

#pragma mark Static method

+ (AudioInputHandler *)sharedInstance
{
    static AudioInputHandler *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioInputHandler alloc] init];
    });
    return instance;
}

@end
