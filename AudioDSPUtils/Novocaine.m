// Copyright (c) 2012 Alex Wiltschko
// Updated for iOS7 Eric Larson, 2013
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//
// TODO:
// Switching mic and speaker on/off
// Updating audio route from user
//
// HOUSEKEEPING AND NICE FEATURES:
// Disambiguate outputFormat (the AUHAL's stream format)
// More nuanced input detection on the Mac
// Route switching should work, check with iPhone
// Device switching should work, check with laptop. Read that damn book.
// Wrap logging with debug macros.
// Think about what should be public, what private.
// Ability to select non-default devices.


#import "Novocaine.h"
#define kInputBus 1
#define kOutputBus 0
#define kDefaultDevice 999999

#import "TargetConditionals.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
//#import <AVFoundation/AVAudioSession.h>
//#import <AVFoundation/AVCaptureDevice.h>
#import <pthread.h>


//static Novocaine *audioManager = nil;

@interface Novocaine()

@property (nonatomic) AudioBufferList convertedFileData;
@property (nonatomic) ExtAudioFileRef audioFileRef;
@property (nonatomic) ExtAudioFileRef audioFileRefOutput;
@property (nonatomic) UInt32 audioFileFrameCount;
@property (nonatomic) BOOL shouldUseAudioFromFile;
@property (nonatomic, strong) NSString *audioFileName;
@property (nonatomic, strong) NSTimer *audioFileTimer;
@property (nonatomic) float *outputBuffer;
@property float phaseIncrement;
@property Float64 samplingRate;


- (void)setupAudio;

- (NSString *)applicationDocumentsDirectory;

@end


@implementation Novocaine
@synthesize sineFrequency = _sineFrequency;

static pthread_mutex_t outputAudioFileLock;

#pragma mark - Singleton Methods
+ (Novocaine *) audioManager
{
    static Novocaine * _sharedInstance = nil;
    
    static dispatch_once_t oncePredicate;
    
    dispatch_once(&oncePredicate,^{
        _sharedInstance = [[Novocaine alloc] init];
        // Fire up the audio session ( with steady error checking ... )
        [_sharedInstance ifAudioInputIsAvailableThenSetupAudioSession];
    });
    
    return _sharedInstance;
}


- (id)init
{
    if (self = [super init])
    {
        
        // Initialize some stuff k?
        _outputBlock = nil;
        _inputBlock    = nil;
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        self.samplingRate = session.sampleRate; // need this setup right away
        
        // Initialize a float buffer to hold audio
        _inData  = (float *)calloc(8192, sizeof(float)); // probably more than we'll need
        _outData = (float *)calloc(8192, sizeof(float));
        
        _outputBuffer = (float *)calloc(2*self.samplingRate, sizeof(float));
        pthread_mutex_init(&outputAudioFileLock, NULL);
        
        _playing = NO;
        _shouldUseAudioFromFile = NO;
        _audioFileTimer = nil;
        _shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile = NO;
        _audioFileWrittenOut = nil;
        
        return self;
        
    }
    
    return nil;
}

-(void)dealloc{
    
    
    for(int i=0;i<_convertedFileData.mNumberBuffers;i++){
        free(_convertedFileData.mBuffers[i].mData);
    }
    
    _inputBlock = nil;
    _outputBlock = nil;
    
    free(_inData);
    free(_outData);
    free(_outputBuffer);
    
    
}


//setter for audio file
-(void)setShouldSaveContinuouslySampledMicrophoneAudioDataToNewFile:(BOOL)shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile {
    if(!self.playing) // don't allow changes midstream, as this could cause a buidlup of unclosed files on the disk
    {
        _shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile = shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile;
    }
    
    // next time the play button is set, we will create an audio file if this was set to true
}


#pragma mark - Block Handling, Setters
- (void)setInputBlock:(InputBlock)newInputBlock
{
    _inputBlock = newInputBlock;
    //inputBlock = CFBridgingRelease();
    //Block_release(tmpBlock);
}

- (void)setOutputBlock:(OutputBlock)newOutputBlock
{
    _outputBlock = newOutputBlock;
    //outputBlock = Block_copy(newOutputBlock);
    //Block_release(tmpBlock);
}

-(void)setSineFrequency:(float)sineFrequency{
    _sineFrequency = sineFrequency;
    self.phaseIncrement = 2*M_PI*sineFrequency/self.samplingRate;
}

-(void)setOutputBlockToPlaySineWave:(float)frequency{
    self.sineFrequency = frequency;
    __block float phase = 0.0;
    double sineWaveRepeatMax = 2*M_PI;

    __block Novocaine * __weak  weakSelf = self;
    [self setOutputBlock:^(float *data, UInt32 numFrames, UInt32 numChannels)
     {
        if(numChannels == 1){
            for (int i=0; i < numFrames; ++i)
            {
                data[i] = sin(phase);
                
                phase += weakSelf.phaseIncrement;
                if (phase >= sineWaveRepeatMax) phase -= sineWaveRepeatMax;
            }
        }else if(numChannels==2){
            for (int i=0; i < numFrames*numChannels; i+=2)
            {
                data[i] = sin(phase);
                data[i+1] = data[i];
                
                phase += weakSelf.phaseIncrement;
                if (phase >= sineWaveRepeatMax) phase -= sineWaveRepeatMax;
            }
        }
     }];
}

-(void)setAudioRoute{
    //    NSArray* inputs = [session availableInputs];
    //
    //    // Locate the Port corresponding to the built-in microphone.
    //    AVAudioSessionPortDescription* builtInMicPort = nil;
    //    for (AVAudioSessionPortDescription* port in inputs)
    //    {
    //        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic])
    //        {
    //            builtInMicPort = port;
    //            break;
    //        }
    //    }
    //
    //    // Print out a description of the data sources for the built-in microphone
    //    NSLog(@"There are %u data sources for port :\"%@\"", (unsigned)[builtInMicPort.dataSources count], builtInMicPort);
    //    NSLog(@"%@", builtInMicPort.dataSources);
    //
    //    // loop over the built-in mic's data sources and attempt to locate the front microphone
    //    AVAudioSessionDataSourceDescription* frontDataSource = nil;
    //    for (AVAudioSessionDataSourceDescription* source in builtInMicPort.dataSources)
    //    {
    //        // other options:
    //        //      AVAudioSessionOrientation( Top | {Front} | Back | Bottom )
    //        if ([source.orientation isEqual:AVAudioSessionOrientationBottom])
    //        {
    //            frontDataSource = source;
    //            break;
    //        }
    //    } // end data source iteration
    //
    //    if (frontDataSource)
    //    {
    //        NSLog(@"Currently selected source is \"%@\" for port \"%@\"", builtInMicPort.selectedDataSource.dataSourceName, builtInMicPort.portName);
    //        NSLog(@"Attempting to select source \"%@\" on port \"%@\"", frontDataSource, builtInMicPort.portName);
    //
    //        // Set a preference for the front data source.
    //        error = nil;
    //        if (![builtInMicPort setPreferredDataSource:frontDataSource error:&error])
    //        {
    //            // an error occurred.
    //            NSLog(@"setPreferredDataSource failed");
    //        }
    //    }
    //    else{
    //        NSLog(@"Front Data Source is nil, cannot change source.");
    //    }
    //
    //    // Make sure the built-in mic is selected for input. This will be a no-op if the built-in mic is
    //    // already the current input Port.
    //    error = nil;
    //    if(![session setPreferredInput:builtInMicPort error:&error]){
    //        NSLog(@"%@ Couldn't set mic as preferred port %@",
    //              NSStringFromSelector(_cmd), [error localizedDescription]);
    //        @throw error;
    //    }
        
        // Add a property listener, to listen to changes to the Route of Audio Input
    //    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    //    [nc addObserver:self selector:@selector(audioRouteChangedListener:) name:AVAudioSessionRouteChangeNotification object:nil];
}


#pragma mark - Audio Methods


- (void)ifAudioInputIsAvailableThenSetupAudioSession {
    
    // Initialize and configure the audio session, and add an interuption listener
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioSessionDidChangeListener:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:[AVAudioSession sharedInstance]];
    // Check the session properties (available input routes, number of channels, etc)
    [self checkAudioSource];

    
    // If we do have input, then let's rock 'n roll.
    if (_inputAvailable) {
        [self setupAudio];
    }
    
}

- (void) teardownAudio {
  if (!_isSetUp)
    return;
  
  [self pause];
    
  NSError *error = nil;
  
  NSLog(@"Tearing down audio session");
    
  // Set the audio session to not active
    if(![[AVAudioSession sharedInstance] setActive:NO error:&error]){
        NSLog(@"%@ Couldn't set activate audio session %@",
              NSStringFromSelector(_cmd), [error localizedDescription]);
        @throw error;
    }
  
    
  //CheckError( AudioSessionSetActive(NO), "Couldn't de-activate the audio session");
  
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
  // Remove a property listener, to listen to changes to the session
//  CheckError( AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange, sessionPropertyListener, self), "Couldn't remove audio session property listener");

  // Uninitialize and dispose the audio input unit
  CheckError( AudioUnitUninitialize(self.audioUnit), "Couldn't uninitialize audio input unit");
  CheckError( AudioComponentInstanceDispose(self.audioUnit), "Couldn't dispose of audio input unit");
  self.audioUnit = nil;
  
  
  _isSetUp = NO;
}


- (void)setupAudio
{
  
  if (_isSetUp)
    return;
  NSError *error = nil;
  NSLog(@"Setting up audio session");
  
    // --- Audio Session Setup ---
    // ---------------------------
    // Initialize the audio session
    AVAudioSession *session = [AVAudioSession sharedInstance];
    
    // configure session to be input from microphone only, other options include: AVAudioSessionCategoryPlayAndRecord, AVAudioSessionCategoryAudioProcessing, AVAudioSessionCategoryRecord but Record is ideal for our application because we are doing "online" processing
    if(![session setCategory:AVAudioSessionCategoryPlayAndRecord
                       error:&error])
    {
        NSLog(@"%@ Error setting category: %@",
              NSStringFromSelector(_cmd), [error localizedDescription]);
        @throw error;
    }

    
    // Set the audio session active
    if(![session setActive:YES error:&error])
    {
        NSLog(@"%@ Couldn't activate audio session %@",
              NSStringFromSelector(_cmd), [error localizedDescription]);
        @throw error;
    }
    
    
    // Code inserted by Eric Larson for setting audio route
    // Get the set of available inputs. If there are no audio accessories attached, there will be
    // only one available input -- the built in microphone.
    [self setAudioRoute]; // currently does nothing
    
    
    // Set the buffer size, this will affect the number of samples that get rendered every time the audio callback is fired
    // A small number will get you lower latency audio, but will make your processor work harder
    Float32 preferredBufferSize = 1024.0/self.samplingRate; // 1024/44100 = 0.0232

    [session setPreferredIOBufferDuration:preferredBufferSize error:&error];
    if(error!=nil){
        NSLog(@"Could not set preferred buffer duration, Error: %@",error.localizedDescription);
    }
    
    [session setPreferredSampleRate: self.samplingRate error:&error];
    if(error!=nil){
        NSLog(@"Could not set preferred sample rate, Error: %@",error.localizedDescription);
    }
    
    
    [self checkSessionProperties];
    
    // ----- Audio Unit Setup -----
    // ----------------------------
    
    
    // Describe the output unit.
    AudioComponentDescription inputDescription = {0};
    inputDescription.componentType = kAudioUnitType_Output;
    inputDescription.componentSubType = kAudioUnitSubType_RemoteIO;
    inputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    // Get component
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &inputDescription);
    CheckError( AudioComponentInstanceNew(inputComponent, &_audioUnit), "Couldn't create the output audio unit");
    
    
    // Enable input
    UInt32 one = 1;
    CheckError( AudioUnitSetProperty(_audioUnit,
                                     kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input,
                                     kInputBus,
                                     &one,
                                     sizeof(one)), "Couldn't enable IO on the input scope of output unit");
    
    // TODO: first query the hardware for desired stream descriptions
    // Check the input stream format
    
    UInt32 size;
    size = sizeof( AudioStreamBasicDescription );
    CheckError( AudioUnitGetProperty( _audioUnit,
                                     kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input,
                                     1,
                                     &_inputFormat,
                                     &size ),
               "Couldn't get the hardware input stream format");
    
    // Check the output stream format
    size = sizeof( AudioStreamBasicDescription );
    CheckError( AudioUnitGetProperty( _audioUnit,
                                     kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output,
                                     1,
                                     &_outputFormat,
                                     &size ),
               "Couldn't get the hardware output stream format");
    
    _inputFormat.mSampleRate = self.samplingRate;
    _outputFormat.mSampleRate = self.samplingRate;
    //self.samplingRate = _inputFormat.mSampleRate;
    self.numBytesPerSample = _inputFormat.mBitsPerChannel / 8;
    
    size = sizeof(AudioStreamBasicDescription);
    CheckError(AudioUnitSetProperty(_audioUnit,
                                    kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output,
                                    kInputBus,
                                    &_outputFormat,
                                    size),
               "Couldn't set the ASBD on the audio unit (after setting its sampling rate)");
    
    

    
    
    UInt32 numFramesPerBuffer;
    size = sizeof(UInt32);
    CheckError(AudioUnitGetProperty(_audioUnit,
                                    kAudioUnitProperty_MaximumFramesPerSlice,
                                    kAudioUnitScope_Global,
                                    kOutputBus,
                                    &numFramesPerBuffer,
                                    &size),
               "Couldn't get the number of frames per callback");
    
    UInt32 bufferSizeBytes = _outputFormat.mBytesPerFrame * _outputFormat.mFramesPerPacket * numFramesPerBuffer;
    
    
    
    
    if (_outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
        // The audio is non-interleaved
        printf("Not interleaved!\n");
        _isInterleaved = NO;
        
        // allocate an AudioBufferList plus enough space for array of AudioBuffers
        UInt32 propsize = offsetof(AudioBufferList, mBuffers[0]) + (sizeof(AudioBuffer) * _outputFormat.mChannelsPerFrame);
        
        //malloc buffer lists
        _inputBuffer = (AudioBufferList *)malloc(propsize);
        _inputBuffer->mNumberBuffers = _outputFormat.mChannelsPerFrame;
        
        //pre-malloc buffers for AudioBufferLists
        for(UInt32 i =0; i< self.inputBuffer->mNumberBuffers ; i++) {
            _inputBuffer->mBuffers[i].mNumberChannels = 1;
            _inputBuffer->mBuffers[i].mDataByteSize = bufferSizeBytes;
            _inputBuffer->mBuffers[i].mData = malloc(bufferSizeBytes);
            memset(self.inputBuffer->mBuffers[i].mData, 0, bufferSizeBytes);
        }
        
    } else {
        printf ("Format is interleaved\n");
        _isInterleaved = YES;
        
        // allocate an AudioBufferList plus enough space for array of AudioBuffers
        UInt32 propsize = offsetof(AudioBufferList, mBuffers[0]) + (sizeof(AudioBuffer) * 1);
        
        //malloc buffer lists
        _inputBuffer = (AudioBufferList *)malloc(propsize);
        _inputBuffer->mNumberBuffers = 1;
        
        //pre-malloc buffers for AudioBufferLists
        _inputBuffer->mBuffers[0].mNumberChannels = _outputFormat.mChannelsPerFrame;
        _inputBuffer->mBuffers[0].mDataByteSize = bufferSizeBytes;
        _inputBuffer->mBuffers[0].mData = malloc(bufferSizeBytes);
        memset(self.inputBuffer->mBuffers[0].mData, 0, bufferSizeBytes);
        
    }
    
    
    // setup a render callback on the unit
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = inputCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    
    CheckError( AudioUnitSetProperty(_audioUnit,
                                     kAudioOutputUnitProperty_SetInputCallback,
                                     kAudioUnitScope_Global,
                                     0,
                                     &callbackStruct,
                                     sizeof(callbackStruct)), "Couldn't set the callback on the input unit");
    
    
    callbackStruct.inputProc = renderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);

    CheckError( AudioUnitSetProperty(_audioUnit,
                                     kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input,
                                     0,
                                     &callbackStruct,
                                     sizeof(callbackStruct)),
               "Couldn't set the render callback on the input unit");
    
    
    
    
    CheckError(AudioUnitInitialize(_audioUnit), "Couldn't initialize the output unit");

  
    _isSetUp = YES;
}



- (void)pause {
    
    if (self.playing) {
        if(self.audioFileTimer)
            [self.audioFileTimer invalidate];
        
        if(self.shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile)
            [self closeAudioFileForWritingFromMicrophone];
        
        CheckError( AudioOutputUnitStop(_audioUnit), "Couldn't stop the output unit");
        self.playing = NO;
    }
    
}

- (void)play {
    
    
    
    if(self.shouldUseAudioFromFile){ //Play from file
        CheckError( AudioOutputUnitStop(_audioUnit), "Couldn't stop the output unit");
        
        // setup audio file for continuous reading
        float preferredTimeInterval = [self initAudioFileForReadingWithName:self.audioFileName];
        
        // if saving microphone data to audio file, setup the file
        if(self.shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile)
            [self setupAudioFileForWritingFromMicrophone];
        
        // turn on timer function for releasing audio to the input block in 1024 sample chunks
        // using "timer" so don't get too comfortable with the actual timing, its just a preferred interval
        self.audioFileTimer = [NSTimer scheduledTimerWithTimeInterval:preferredTimeInterval
                                         target:self
                                       selector:@selector(sendAudioFileChunkToProcessBlock:)
                                       userInfo:nil
                                        repeats:YES]; // the interval is in seconds...

        self.playing = YES;
        
    }else{
        // play from the microphone
        AVAudioSession *session =  [AVAudioSession sharedInstance];
        
        self.inputAvailable = session.isInputAvailable;
        
        if ( self.inputAvailable ) {
            // Set the audio session category for simultaneous play and record
            if (!self.playing) {
                
                // if saving microphone data to audio file, setup the file
                if(self.shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile)
                   [self setupAudioFileForWritingFromMicrophone];
                
                CheckError( AudioOutputUnitStart(self.audioUnit), "Couldn't start the output unit");
                self.playing = YES;
                
            }
        }
    }
    
}




#pragma mark - Render Methods
OSStatus inputCallback   (void                        *inRefCon,
                          AudioUnitRenderActionFlags    * ioActionFlags,
                          const AudioTimeStamp         * inTimeStamp,
                          UInt32                        inOutputBusNumber,
                          UInt32                        inNumberFrames,
                          AudioBufferList            * ioData)
{
    
    
    Novocaine *sm = (__bridge Novocaine *)inRefCon;
    
    // setup rendering callback
    if (!sm.playing)
        return noErr;
    if (sm.inputBlock == nil)
        return noErr;
    
    
    // Check the current number of channels
    // Let's actually grab the audio
#if TARGET_IPHONE_SIMULATOR
    // this is a workaround for an issue with core audio on the simulator, //
    //  likely due to 44100 vs 48000 difference in OSX //
    if( inNumberFrames == 471 )
        inNumberFrames = 470;
#endif
    // NSLog(@"Frames: %d",inNumberFrames); // had some weird stuff going on
    CheckError( AudioUnitRender(sm.audioUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, sm.inputBuffer), "Couldn't render the audio unit");
    
    
    // Convert the audio in something manageable
    // For Float32s ...
    if ( sm.numBytesPerSample == 4 ) // then we've already got floats
    {
        
        float zero = 0.0f;
        if ( ! sm.isInterleaved ) { // if the data is in separate buffers, make it interleaved
            for (int i=0; i < sm.numInputChannels; ++i) {
                vDSP_vsadd((float *)sm.inputBuffer->mBuffers[i].mData, 1, &zero, sm.inData+i,
                           sm.numInputChannels, inNumberFrames);
            }
        }
        else { // if the data is already interleaved, copy it all in one happy block.
            // TODO: check mDataByteSize is proper
            memcpy(sm.inData, (float *)sm.inputBuffer->mBuffers[0].mData, sm.inputBuffer->mBuffers[0].mDataByteSize);
        }
    }
    
    // For SInt16s ...
    else if ( sm.numBytesPerSample == 2 ) // then we're dealing with SInt16's
    {
        if ( ! sm.isInterleaved ) {
            for (int i=0; i < sm.numInputChannels; ++i) {
                vDSP_vflt16((SInt16 *)sm.inputBuffer->mBuffers[i].mData, 1, sm.inData+i, sm.numInputChannels, inNumberFrames);
            }
        }
        else {
            vDSP_vflt16((SInt16 *)sm.inputBuffer->mBuffers[0].mData, 1, sm.inData, 1, inNumberFrames*sm.numInputChannels);
        }
        
        float scale = 1.0 / (float)INT16_MAX;
        vDSP_vsmul(sm.inData, 1, &scale, sm.inData, 1, inNumberFrames*sm.numInputChannels);
    }
    
    // Now do the processing!
    sm.inputBlock(sm.inData, inNumberFrames, sm.numInputChannels);
    
    // save audio data to file if we are told to do so
    if(sm.shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile){
        //ExtAudioFileWrite(sm.audioFileRefOutput,inNumberFrames,sm.inputBuffer);
        //ExtAudioFileWriteAsync(sm.audioFileRefOutput,inNumberFrames,sm.inputBuffer);
        UInt32 numIncomingBytes = inNumberFrames*sm.numInputChannels*sizeof(float);
        memcpy(sm.outputBuffer, sm.inData, numIncomingBytes);
        
        AudioBufferList outgoingAudio;
        outgoingAudio.mNumberBuffers = 1;
        outgoingAudio.mBuffers[0].mNumberChannels = inNumberFrames;
        outgoingAudio.mBuffers[0].mDataByteSize = numIncomingBytes;
        outgoingAudio.mBuffers[0].mData = sm.outputBuffer;
        
        if( 0 == pthread_mutex_trylock( &outputAudioFileLock ) )
        {
            ExtAudioFileWriteAsync(sm.audioFileRefOutput, inNumberFrames, &outgoingAudio);
        }
        pthread_mutex_unlock( &outputAudioFileLock );
        
    }
    
    return noErr;
    
    
}

OSStatus renderCallback (void                        *inRefCon,
                         AudioUnitRenderActionFlags    * ioActionFlags,
                         const AudioTimeStamp         * inTimeStamp,
                         UInt32                        inOutputBusNumber,
                         UInt32                        inNumberFrames,
                         AudioBufferList            * ioData)
{
    
    
    Novocaine *sm = (__bridge Novocaine *)inRefCon;
    float zero = 0.0;
    
    
    for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    if (!sm.playing)
        return noErr;
    if (!sm.outputBlock)
        return noErr;


    // Collect data to render from the callbacks
    sm.outputBlock(sm.outData, inNumberFrames, sm.numOutputChannels);
    
    
    // Put the rendered data into the output buffer
    // TODO: convert SInt16 ranges to float ranges.
    if ( sm.numBytesPerSample == 4 ) // then we've already got floats
    {
        
        for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
            
            int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
            
            for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                vDSP_vsadd(sm.outData+iChannel, sm.numOutputChannels, &zero, (float *)ioData->mBuffers[iBuffer].mData, thisNumChannels, inNumberFrames);
            }
        }
    }
    else if ( sm.numBytesPerSample == 2 ) // then we need to convert SInt16 -> Float (and also scale)
    {
        float scale = (float)INT16_MAX;
        vDSP_vsmul(sm.outData, 1, &scale, sm.outData, 1, inNumberFrames*sm.numOutputChannels);
        
        for (int iBuffer=0; iBuffer < ioData->mNumberBuffers; ++iBuffer) {
            
            int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
            
            for (int iChannel = 0; iChannel < thisNumChannels; ++iChannel) {
                vDSP_vfix16(sm.outData+iChannel, sm.numOutputChannels, (SInt16 *)ioData->mBuffers[iBuffer].mData+iChannel, thisNumChannels, inNumberFrames);
            }
        }
        
    }

    return noErr;
    
}

#pragma mark - Audio Session Listeners
void sessionPropertyListener(void *                  inClientData,
                             AudioSessionPropertyID  inID,
                             UInt32                  inDataSize,
                             const void *            inData){
    
    
    if (inID == kAudioSessionProperty_AudioRouteChange)
    {
        Novocaine *sm = (__bridge Novocaine *)inClientData;
        [sm checkSessionProperties];
    }
    
}

- (void)audioSessionDidChangeListener:(NSNotification *)notification
{
    NSLog(@"Called interuption");
    AVAudioSessionInterruptionType interruptionType = [[[notification userInfo]
                                                        objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (AVAudioSessionInterruptionTypeBegan == interruptionType)
    {
        NSLog(@"Begin interuption");
        self.inputAvailable = NO;
        [self pause];
    }
    else if (AVAudioSessionInterruptionTypeEnded == interruptionType)
    {
        NSLog(@"End interuption");
        self.inputAvailable = YES;
        [self play];
        
    }
    
}



//- (void) audioRouteChangedListener:(NSNotification*)notification
//{
//
//    NSLog(@"audioRouteChanged");
//    [self checkSessionProperties];
//
//    //    UInt32 routeSize = sizeof (CFStringRef);
//    //    CFStringRef route;
//    //
//    //    OSStatus error = AudioSessionGetProperty (kAudioSessionProperty_AudioRoute, &routeSize, &route);
//
//    /* Known values of route:
//     * "Headset"
//     * "Headphone"
//     * "Speaker"
//     * "SpeakerAndMicrophone"
//     * "HeadphonesAndMicrophone"
//     * "HeadsetInOut"
//     * "ReceiverAndMicrophone"
//     * "Lineout"
//     */
//
//
//}

- (void)checkAudioSource {
    // Check what the incoming audio route is.
    //UInt32 propertySize = sizeof(CFStringRef);
    //CFStringRef route;
    
    
    AVAudioSession *session = [AVAudioSession sharedInstance];

    //CheckError( AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &propertySize, &route), "Couldn't check the audio route");
    //self.inputRoute = (NSString *)route;
    //CFRelease(route);
    //NSLog(@"AudioRoute: %@", self.inputRoute);
    
    // Check if there's input available.
    // TODO: check if checking for available input is redundant.
    //          Possibly there's a different property ID change?
    self.inputAvailable = session.isInputAvailable;
    NSLog(@"Input available? %d", self.inputAvailable);
    
}


// To be run ONCE per session property change and once on initialization.
- (void)checkSessionProperties
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    
    NSLog(@"Checking session properties");
  
    // Check if there is input, and from where
    [self checkAudioSource];
    
    
    // Check the number of input channels.
    // Find the number of channels
    self.numInputChannels = (UInt32)session.inputNumberOfChannels;
    //    self.numInputChannels = 1;
    NSLog(@"We've got %u input channels", (unsigned int)self.numInputChannels);
    
    
    // Check the number of input channels.
    // Find the number of channels
    self.numOutputChannels = (UInt32)session.outputNumberOfChannels;
    //    self.numOutputChannels = 1;
    NSLog(@"We've got %u output channels", (unsigned int)self.numOutputChannels);
    
    
    // Get the hardware sampling rate. This is settable, but here we're only reading.
    NSLog(@"Current sampling rate: Preferred:%.1f, Actual:%.1f", self.samplingRate, session.sampleRate);
    
    
    NSLog(@"Actual Buffer Duration: %.4f, length %d", session.IOBufferDuration,
          (UInt32)(session.IOBufferDuration*session.sampleRate+1));
    
    
}

void sessionInterruptionListener(void *inClientData, UInt32 inInterruption) {
    
    Novocaine *sm = (__bridge Novocaine *)inClientData;
    
    if (inInterruption == kAudioSessionBeginInterruption) {
        NSLog(@"Begin interuption");
        sm.inputAvailable = NO;
    }
    else if (inInterruption == kAudioSessionEndInterruption) {
        NSLog(@"End interuption");
        sm.inputAvailable = YES;
        [sm play];
    }
    
}


#pragma mark - Convenience Methods
- (NSString *)applicationDocumentsDirectory {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
}


void CheckError(OSStatus error, const char *operation)
{
    if (error == noErr) return;
    
    char str[20];
    // see if it appears to be a 4-char-code
    UInt32 tmp = CFSwapInt32HostToBig(error);
    //*(UInt32 *)(str + 1) = tmp;
    memset(&str[1], tmp, 4); // make it not so damn obfusticated
    if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
        str[0] = str[5] = '\'';
        str[6] = '\0';
    } else{
        // no, format it as an integer
        sprintf(str, "%d", (int)error);
    }
    
    fprintf(stderr, "Error: %s (%s)\n", operation, str);
    
    exit(1);
}

+(enum AVAudioSessionRecordPermission)checkAudioAuthorization{
    return [[AVAudioSession sharedInstance] recordPermission];
}


#pragma mark Spoof Microphone as Audio File Functions
- (float) initAudioFileForReadingWithName: (NSString*)name {
    
    // other comment
    // code modified from  http://stackoverflow.com/questions/7537505/ios-how-to-read-an-audio-file-into-a-float-buffer
    
    
    NSString * source = [[NSBundle mainBundle] pathForResource:name ofType:@"m4a"]; // SPECIFY YOUR FILE FORMAT
    
    if(source==nil){
        //TODO: issue an NSError here for caller to deal with properly
        NSLog(@"BadFileAccess:File provided does not exist, %@",name);
        return -1.0;
    }
    
    const char *cString = [source cStringUsingEncoding:NSASCIIStringEncoding];
    
    CFStringRef str = CFStringCreateWithCString(
                                                NULL,
                                                cString,
                                                kCFStringEncodingMacRoman
                                                );
    
    CFURLRef inputFileURL = CFURLCreateWithFileSystemPath(
                                                          kCFAllocatorDefault,
                                                          str,
                                                          kCFURLPOSIXPathStyle,
                                                          false
                                                          );
    
    ExtAudioFileOpenURL(inputFileURL, &_audioFileRef);
    
    // avoid any CF memory leaks
    CFRelease(str);
    CFRelease(inputFileURL);
    
    
    AudioStreamBasicDescription audioFormat;
    audioFormat.mSampleRate = self.samplingRate;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kLinearPCMFormatFlagIsFloat;
    audioFormat.mBitsPerChannel = sizeof(Float32) * 8;
    audioFormat.mChannelsPerFrame = 1; // Mono
    audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * sizeof(Float32);  // == sizeof(Float32)
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerPacket = audioFormat.mFramesPerPacket * audioFormat.mBytesPerFrame; // = sizeof(Float32)
    
    // 3) Apply audio format to the Extended Audio File
    ExtAudioFileSetProperty(
                            _audioFileRef,
                            kExtAudioFileProperty_ClientDataFormat,
                            sizeof(AudioStreamBasicDescription), //= audioFormat
                            &audioFormat);
    
    int numSamples = 1024; // How many samples to read in at a time
    UInt32 sizePerPacket = audioFormat.mBytesPerPacket; // = sizeof(Float32) = 32bytes
    UInt32 packetsPerBuffer = numSamples;
    UInt32 outputBufferSize = packetsPerBuffer * sizePerPacket;
    UInt8 *outputBuffer = (UInt8 *)malloc(sizeof(UInt8) * outputBufferSize);
    
    _convertedFileData.mNumberBuffers = 1;    // Set this to 1 for mono
    _convertedFileData.mBuffers[0].mNumberChannels = audioFormat.mChannelsPerFrame;  //also = 1
    _convertedFileData.mBuffers[0].mDataByteSize = outputBufferSize;
    _convertedFileData.mBuffers[0].mData = outputBuffer;
    
    _audioFileFrameCount = numSamples;
    
    return ((float)numSamples) / ((float)audioFormat.mSampleRate);
    
}



-(void)sendAudioFileChunkToProcessBlock:(NSTimer *)timer{
    float *samplesAsCArray;
    UInt32 numChannels = _convertedFileData.mBuffers[0].mNumberChannels;
    
    // read from the last place we were in the file
    ExtAudioFileRead(
                     _audioFileRef,
                     &_audioFileFrameCount,
                     &_convertedFileData
                     );
    
    // send to process block
    if (_audioFileFrameCount > 0)  {
        AudioBuffer audioBuffer = _convertedFileData.mBuffers[0];
        samplesAsCArray = (float *)audioBuffer.mData;
        
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),^{
            if(self.inputBlock != nil)
                self.inputBlock(samplesAsCArray, self->_audioFileFrameCount, numChannels);
        });
        
        // save audio data to file if we are told to do so
        if(self.shouldSaveContinuouslySampledMicrophoneAudioDataToNewFile){
            //ExtAudioFileWrite(sm.audioFileRefOutput,inNumberFrames,sm.inputBuffer);
            //ExtAudioFileWriteAsync(sm.audioFileRefOutput,inNumberFrames,sm.inputBuffer);
            UInt32 numIncomingBytes = _audioFileFrameCount*numChannels*sizeof(float);
            memcpy(self.outputBuffer, samplesAsCArray, numIncomingBytes);
            
            AudioBufferList outgoingAudio;
            outgoingAudio.mNumberBuffers = 1;
            outgoingAudio.mBuffers[0].mNumberChannels = _audioFileFrameCount;
            outgoingAudio.mBuffers[0].mDataByteSize = numIncomingBytes;
            outgoingAudio.mBuffers[0].mData = self.outputBuffer;
            
            if( 0 == pthread_mutex_trylock( &outputAudioFileLock ) )
            {
                ExtAudioFileWriteAsync(self.audioFileRefOutput, _audioFileFrameCount, &outgoingAudio);
            }
            pthread_mutex_unlock( &outputAudioFileLock );
            
        }

    }
    else{
        [timer invalidate];
        //stop reading and close the file
        ExtAudioFileDispose(_audioFileRef);
    }
}

-(void) overrideMicrophoneWithAudioFile:(NSString*)audioFileName{
    self.shouldUseAudioFromFile = YES;
    self.audioFileName = audioFileName;
}

-(void)setDebugModeOffAndUseMicrophone{
    //TODO: this method is not tested
    self.shouldUseAudioFromFile = NO;
    self.audioFileName = nil;
    
    if (self.playing) {
        [self pause]; // invalidates timers etc. associated with file
        [self play]; // start it up again with newly created audio object for microphone
    }
}


#pragma mark Save Audio Data From Microphone
-(void)setupAudioFileForWritingFromMicrophone{
    // this places the audio into the documents directory
    
    
    // manipualted from http://stackoverflow.com/questions/6821517/save-an-image-to-application-documents-folder-from-uiview-on-ios
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsPath = [paths objectAtIndex:0]; //Get the docs directory
    NSString *timeString = [NSString stringWithFormat:@"%f.m4a",[[NSDate date] timeIntervalSince1970]]; // get UTC time string
    
    self.audioFileWrittenOut = timeString;
    NSString *source = [documentsPath stringByAppendingPathComponent:timeString]; //Add the file name
    
    const char *cString = [source cStringUsingEncoding:NSASCIIStringEncoding];
    
    CFStringRef str = CFStringCreateWithCString(
                                                NULL,
                                                cString,
                                                kCFStringEncodingMacRoman
                                                );
    
    CFURLRef outputFileURL = CFURLCreateWithFileSystemPath(
                                                          kCFAllocatorDefault,
                                                          str,
                                                          kCFURLPOSIXPathStyle,
                                                          false
                                                          );
    
    // Create a file for writing to
    
    AudioStreamBasicDescription audioFormat;
    
    AudioStreamBasicDescription outputFileDesc = {self.samplingRate,  kAudioFormatMPEG4AAC, 0, 0, 1024, 0, self.numInputChannels, 0, 0};
    
    CheckError(ExtAudioFileCreateWithURL(outputFileURL, kAudioFileM4AType, &outputFileDesc, NULL, kAudioFileFlags_EraseFile, &_audioFileRefOutput), "Creating file");
    
    audioFormat.mSampleRate = self.samplingRate;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsFloat;
    audioFormat.mBytesPerPacket = 4*self.numInputChannels;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = 4*self.numInputChannels;
    audioFormat.mChannelsPerFrame = self.numInputChannels;
    audioFormat.mBitsPerChannel = 32;
    
    // Apply the format to our file
    OSStatus tmp = ExtAudioFileSetProperty(_audioFileRefOutput, kExtAudioFileProperty_ClientDataFormat, sizeof(AudioStreamBasicDescription), &audioFormat);
    CheckError(tmp,"Could not open file for writing");
    
    
    if( 0 == pthread_mutex_trylock( &outputAudioFileLock ) )
    {
        tmp = ExtAudioFileWriteAsync(_audioFileRefOutput,0,NULL);
        CheckError(tmp,"Could not initialize asynchronous writing");
    }
    pthread_mutex_unlock( &outputAudioFileLock );
    
    // okay so it is ready to be written to!!
    
    // avoid any CF memory leaks
    CFRelease(str);
    CFRelease(outputFileURL);
}

-(void)closeAudioFileForWritingFromMicrophone{
    pthread_mutex_lock( &outputAudioFileLock );
    OSStatus tmp = ExtAudioFileDispose(_audioFileRefOutput);
    CheckError(tmp,"File Could not be closed");
    pthread_mutex_unlock( &outputAudioFileLock );
}

@end







