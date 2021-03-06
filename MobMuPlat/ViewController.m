//
//  ViewController.m
//  MobMuPlat
//
//  Created by Daniel Iglesia on 11/15/12.
//  Copyright (c) 2012 Daniel Iglesia. All rights reserved.
//
//  The main class of MobMuPlat.
//  Functionality includes:
//  -initializing libPD audio processing
//  -loading a MMP file (from its JSON String) into the right canvas size and orientation, and laying out the GUI widget objects it specifies
//  -loading the PD patch the above file specifies
//  -starting the device motion data and sending it into PD
//  -methods (called from SettingsViewController) to change audio/DSP/MIDI parameters
//  -sending messages from PD to the appropriate GUI object
//  -receving messages from GUI objects to send into PD
//  -intializing and sending/receiving network data and sending it in/out of PD
//  -receiving MIDI bytes (via PGMidi objects), formatting into messages to send to PD
//


#define DEFAULT_PORT_NUMBER 54321

#import "ViewController.h"

#import "VVOSC.h"

#import "MeSlider.h"
#import "MeKnob.h"
#import "MeLabel.h"
#import "MeButton.h"
#import "MeToggle.h"
#import "MeXYSlider.h"
#import "MeGrid.h"
#import "MePanel.h"
#import "MeMultiSlider.h"


extern void expr_setup(void);
extern void bonk_tilde_setup(void);
extern void choice_setup(void);
extern void fiddle_tilde_setup(void);
extern void loop_tilde_setup(void);
extern void lrshift_tilde_setup(void);
extern void sigmund_tilde_setup(void);


@implementation ViewController
@synthesize audioController, settingsVC;


//what kind of device am I one? iphone 3.5", iphone 4", or ipad
+(canvasType)getCanvasType{
    canvasType hardwareCanvasType;
    if([[UIDevice currentDevice]userInterfaceIdiom]==UIUserInterfaceIdiomPhone)
    {
        if ([[UIScreen mainScreen] bounds].size.height == 568)hardwareCanvasType=canvasTypeIPhone4Inch;
        else hardwareCanvasType=canvasTypeIPhone3p5Inch;
    }
    else hardwareCanvasType=canvasTypeIPad;
    return hardwareCanvasType;
}



-(id) init{
    self=[super init];

    openPDFile=nil;
    
    allGUIControl = [[NSMutableArray alloc]init];

    //for using the flash
    avCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    //MIDI library
    midi=[[PGMidi alloc]init];
    [midi setNetworkEnabled:YES];
    [midi setVirtualDestinationEnabled:YES];
    [midi.virtualDestinationSource addDelegate:self];
    //out
    [midi setVirtualEndpointName:@"MobMuPlat"];
    [midi setVirtualSourceEnabled:YES];
    //[midi.virtualSourceDestination]
    
    
    settingsVC = [[SettingsViewController alloc] init ];//]WithNibName:@"SettingsView" bundle:nil];
    int ticksPerBuffer;

#if TARGET_IPHONE_SIMULATOR
    ticksPerBuffer = 8;  // No other value seems to work with the simulator.
#else
    ticksPerBuffer=16;
	//was 32 NO - means buffer is 64 blocksize * 64 ticks per buffer=4096
#endif
    
	//OSC setup
    manager = [[OSCManager alloc] init];
	[manager setDelegate:self];

    
    //libPD setup
    
    audioController = [[PdAudioController alloc] init] ;
	[audioController configurePlaybackWithSampleRate:44100 numberChannels:2 inputEnabled:YES mixingEnabled:NO];
    [audioController configureTicksPerBuffer:ticksPerBuffer];
    
    //access to PD externals not normally part of libPD
    expr_setup();
    bonk_tilde_setup();
    choice_setup();
    fiddle_tilde_setup();
    loop_tilde_setup();
    lrshift_tilde_setup();
    sigmund_tilde_setup();
    
    //hardware polling freqs
    self.accelFrequency=10;
    self.gyroFrequency=10;
    self.motionFrequency=10;
    
    //start accelerometer
    [[UIAccelerometer sharedAccelerometer] setUpdateInterval:1.0 / self.accelFrequency];
	[[UIAccelerometer sharedAccelerometer] setDelegate:self];
    
    //start device motion detection
    
    motionManager = [[CMMotionManager alloc] init];
    motionManager.deviceMotionUpdateInterval = 1.0 / self.gyroFrequency;
    motionManager.gyroUpdateInterval=1.0/self.motionFrequency;
    if (motionManager.deviceMotionAvailable){
        [motionManager startDeviceMotionUpdatesToQueue:[NSOperationQueue currentQueue] withHandler:^ (CMDeviceMotion *devMotion, NSError *error){
         CMAttitude *currentAttitude = devMotion.attitude;
         /*float xRotation = currentAttitude.roll*180/M_PI;
         float yRotation = currentAttitude.pitch*180/M_PI;
         float zRotation = currentAttitude.yaw*180/M_PI;
         printf("\n %.2f, %.2f %.2f", xRotation, yRotation, zRotation);*/
        NSArray* motionArray=[NSArray arrayWithObjects:@"/motion", [NSNumber numberWithFloat:currentAttitude.roll],[NSNumber numberWithFloat:currentAttitude.pitch], [NSNumber numberWithFloat:currentAttitude.yaw], nil];
     
        [PdBase sendList:motionArray toReceiver:@"fromSystem"];

     }];
    } else {
        NSLog(@"No device motion on device.");
    }
    
    //gyro
    if(motionManager.gyroAvailable){
        [motionManager startGyroUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMGyroData *gyroData, NSError *error) {
    
            NSArray* gyroArray=[NSArray arrayWithObjects:@"/gyro", [NSNumber numberWithFloat:gyroData.rotationRate.x],[NSNumber numberWithFloat:gyroData.rotationRate.y], [NSNumber numberWithFloat:gyroData.rotationRate.z], nil];
            
            [PdBase sendList:gyroArray toReceiver:@"fromSystem"];
            //printf("\n %.2f, %.2f %.2f", gyroData.rotationRate.x, gyroData.rotationRate.y, gyroData.rotationRate.z);
        

    }];
    } else {
        NSLog(@"No gyro info on device.");
    }
    
    //GPS location
       
    locationManager = [[CLLocationManager alloc] init] ;
    locationManager.delegate = self;
    [locationManager setDistanceFilter:1.0];
    //[locationManager startUpdatingLocation ];
              
    
    //copy bundle stuff if not there, i.e. first time we are running it on a new version #
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *publicDocumentsDir = [paths objectAtIndex:0];
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    
    canvasType hardwareCanvasType = [ViewController getCanvasType];
      
    //first run on new version
    NSString *bundleVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
    
    NSString *appFirstStartOfVersionKey = [NSString stringWithFormat:@"first_start_%@", bundleVersion];
    
    NSNumber *alreadyStartedOnVersion =[[NSUserDefaults standardUserDefaults] objectForKey:appFirstStartOfVersionKey];
    //printf("\n bundle %s  already started %d", [bundleVersion cString], [alreadyStartedOnVersion boolValue]);
    
    if(!alreadyStartedOnVersion || [alreadyStartedOnVersion boolValue] == NO) {
         NSArray* defaultPatches;
        if(hardwareCanvasType==canvasTypeIPhone3p5Inch ){
            defaultPatches=[NSArray arrayWithObjects: @"MMPTutorial0-HelloSine.mmp", @"MMPTutorial1-GUI.mmp", @"MMPTutorial2-Input.mmp", @"MMPTutorial3-Hardware.mmp", @"MMPTutorial4-Networking.mmp",@"MMPTutorial5-Files.mmp",@"MMPExamples-Vocoder.mmp", @"MMPExamples-Motion.mmp", @"MMPExamples-Sequencer.mmp", @"MMPExamples-GPS.mmp",nil];
        }
        else if (hardwareCanvasType==canvasTypeIPhone4Inch){
            defaultPatches=[NSArray arrayWithObjects: @"MMPTutorial0-HelloSine-ip5.mmp", @"MMPTutorial1-GUI-ip5.mmp", @"MMPTutorial2-Input-ip5.mmp", @"MMPTutorial3-Hardware-ip5.mmp", @"MMPTutorial4-Networking-ip5.mmp",@"MMPTutorial5-Files-ip5.mmp", @"MMPExamples-Vocoder-ip5.mmp", @"MMPExamples-Motion-ip5.mmp", @"MMPExamples-Sequencer-ip5.mmp",@"MMPExamples-GPS-ip5.mmp", nil];
        }
        else{//pad
            defaultPatches=[NSArray arrayWithObjects: @"MMPTutorial0-HelloSine-Pad.mmp", @"MMPTutorial1-GUI-Pad.mmp", @"MMPTutorial2-Input-Pad.mmp", @"MMPTutorial3-Hardware-Pad.mmp", @"MMPTutorial4-Networking-Pad.mmp",@"MMPTutorial5-Files-Pad.mmp", @"MMPExamples-Vocoder-Pad.mmp", @"MMPExamples-Motion-Pad.mmp", @"MMPExamples-Sequencer-Pad.mmp",@"MMPExamples-GPS-Pad.mmp", nil];
        }
        
        NSArray* commonFiles = [NSArray arrayWithObjects:@"MMPTutorial0-HelloSine.pd",@"MMPTutorial1-GUI.pd", @"MMPTutorial2-Input.pd", @"MMPTutorial3-Hardware.pd", @"MMPTutorial4-Networking.pd",@"MMPTutorial5-Files.pd",@"cats1.jpg", @"cats2.jpg",@"cats3.jpg",@"clap.wav",@"Welcome.pd",  @"MMPExamples-Vocoder.pd", @"vocod_channel.pd", @"MMPExamples-Motion.pd", @"MMPExamples-Sequencer.pd", @"MMPExamples-GPS.pd", nil];
        
        defaultPatches = [defaultPatches arrayByAddingObjectsFromArray:commonFiles];
        
        
        for(NSString* patchName in defaultPatches){//copy all from default and common
            NSString* patchDocPath = [publicDocumentsDir stringByAppendingPathComponent:patchName];
           
            NSString* patchBundlePath = [bundlePath stringByAppendingPathComponent:patchName];
            NSError* error = nil;
            if([[NSFileManager defaultManager] fileExistsAtPath:patchDocPath])
                [[NSFileManager defaultManager] removeItemAtPath:patchDocPath error:&error];
            [[NSFileManager defaultManager] copyItemAtPath:patchBundlePath toPath:patchDocPath error:&error];
        }
        
        
        
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:YES] forKey:appFirstStartOfVersionKey];
    }
    //end first run and copy

       
    return self;
}


- (void)viewDidLoad{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor grayColor];
    isLandscape=NO;
    
    //setup upper left info button, but don't add it anywhere yet
    settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [settingsButton setImage:[UIImage imageNamed:@"infoicon_100x100.png"] forState:UIControlStateNormal];
    [settingsButton addTarget:self action:@selector(showInfo:) forControlEvents:UIControlEventTouchUpInside];
    
    
    canvasType hardwareCanvasType = [ViewController getCanvasType];
    
    //create info label "underneath" interfaces, that show only when running no interface
    patchOnlyLabel = [[UILabel alloc]init];
    if(hardwareCanvasType==canvasTypeIPad){
        patchOnlyLabel.frame = CGRectMake(40, 100, 768-80, 300);
        [patchOnlyLabel setFont:[UIFont systemFontOfSize:28]];
        settingsButton.frame=CGRectMake(20, 20, 40, 40);
    }
    else{
        patchOnlyLabel.frame = CGRectMake(20, 100, 280, 300);
        settingsButton.frame=CGRectMake(10, 10, 30, 30);
    }
    patchOnlyLabel.textAlignment=NSTextAlignmentCenter;
    patchOnlyLabel.numberOfLines=6;
    patchOnlyLabel.backgroundColor = [UIColor clearColor];
    patchOnlyLabel.textColor=[UIColor whiteColor];
    [self.view addSubview:patchOnlyLabel];
        
    
    //midi setup
    midi.delegate=self;
	if([midi.sources count]>0){
		[self setMidiSourceIndex:0];//connect to first device in MIDI source list
	}
    if([midi.destinations count]>0){
		[self setMidiDestinationIndex:0];//connect to first device in MIDI source list
	}
    
    //delegate for file loading, etc
    settingsVC.delegate = self;
    //delegate (from audio+midi screen of settingsVC) for setting audio+midi parameters (sampling rate, MIDI source, etc)
    settingsVC.audioDelegate = self;
    
    navigationController = [[UINavigationController alloc] initWithRootViewController:settingsVC];
    navigationController.navigationBar.barStyle = UIBarStyleBlack;
    navigationController.modalTransitionStyle = UIModalTransitionStyleFlipHorizontal;
    
        
    //PD setup
    // set self as PdRecieverDelegate to recieve messages from Libpd
	[PdBase setDelegate:self];
    [PdBase setMidiDelegate:self];
		
	[PdBase subscribe:@"toGUI"];
    [PdBase subscribe:@"toNetwork"];
    [PdBase subscribe:@"toSystem"];
	
    [audioController setActive:YES];
	
    //start default intro patch
    NSString* path;
    if(hardwareCanvasType==canvasTypeIPhone3p5Inch )
        path = [[NSBundle mainBundle] pathForResource:@"Welcome" ofType:@"mmp"];
    else if (hardwareCanvasType==canvasTypeIPhone4Inch)
        path = [[NSBundle mainBundle] pathForResource:@"Welcome-ip5" ofType:@"mmp"];
    else//pad
        path = [[NSBundle mainBundle] pathForResource:@"Welcome-Pad" ofType:@"mmp"];
    
    NSString* jsonString = [NSString stringWithContentsOfFile: path encoding:NSUTF8StringEncoding error:nil];
   
    if(jsonString)[self loadScene:[jsonString objectFromJSONString]];
  
}

//I believe next two methods were neccessary to receive "shake" gesture
- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self resignFirstResponder];
    [super viewWillDisappear:animated];
}

//called often by accelerometer, package accel values and send to PD
-(void)accelerometer:(UIAccelerometer *)accelerometer didAccelerate:(UIAcceleration *)acceleration{
    
    //first, "cook" the values to get a nice tilt value without going beyond -1 to 1
    
	//printf("\naccel %.2f %.2f %.2f", acceleration.x, acceleration.y, acceleration.z);
	float cookedX = acceleration.x;
	float cookedY = acceleration.y;
	//cook it via Z accel to see when we have tipped it beyond 90 degrees
	
	if(acceleration.x>0 && acceleration.z>0) cookedX=(2-acceleration.x); //tip towards long side
	else if(acceleration.x<0 && acceleration.z>0) cookedX=(-2-acceleration.x); //tip away long side
	
	if(acceleration.y>0 && acceleration.z>0) cookedY=(2-acceleration.y); //tip right
	else if(acceleration.y<0 && acceleration.z>0) cookedY=(-2-acceleration.y); //tip left
	
    //clip
    if(cookedX<-1)cookedX=-1;
    else if(cookedX>1)cookedX=1;
    if(cookedY<-1)cookedY=-1;
    else if(cookedY>1)cookedY=1;
	
	//send the cooked values as "tilts", and the raw values as "accel"
	  
    NSArray* msgArray=[NSArray arrayWithObjects:@"/tilts", [NSNumber numberWithFloat:cookedX],[NSNumber numberWithFloat:cookedY], nil];

    [PdBase sendList:msgArray toReceiver:@"fromSystem"];
    
    NSArray* accelArray=[NSArray arrayWithObjects:@"/accel", [NSNumber numberWithFloat:acceleration.x],[NSNumber numberWithFloat:acceleration.y], [NSNumber numberWithFloat:acceleration.z], nil];
    
     [PdBase sendList:accelArray toReceiver:@"fromSystem"];
    
}

- (void)showInfo:(id)sender {
    [self presentModalViewController:navigationController animated:YES];
}

//=====audio settings delegate methods

-(int)blockSize{
    return [PdBase getBlockSize];
}

-(int)setTicksPerBuffer:(int)newTick{ //return actual value
    [audioController configureTicksPerBuffer:newTick];
    return [audioController ticksPerBuffer];
}

-(int)setRate:(int)inRate{//return actual value
    samplingRate=inRate;
    [self.audioController configurePlaybackWithSampleRate:samplingRate numberChannels:2 inputEnabled:YES mixingEnabled:NO];
    NSLog(@"sample rate set to %d", [self.audioController sampleRate]);
    return [self.audioController sampleRate];
}

-(int)sampleRate{
    return [self.audioController sampleRate];
}

-(int)actualTicksPerBuffer{
    //NSLog(@"actual ticks is %d",[audioController ticksPerBuffer] );
    return [audioController ticksPerBuffer];
}

-(PGMidi*) midi{
    return midi;
}

-(void)connectPorts{//could probably use some error checking...
    if(currPortNumber>0){
        outPort = [manager createNewOutputToAddress:@"224.0.0.1" atPort:currPortNumber];
        inPort = [manager createNewInputForPort:currPortNumber];
    }
}

-(void)disconnectPorts{
    if(inPort!=nil)[manager deleteAllInputs];
    if(outPort!=nil)[manager deleteAllOutputs];
}

//====settingsVC delegate methods

- (void)settingsViewControllerDidFinish:(SettingsViewController *)controller{
     [self dismissModalViewControllerAnimated:YES];
}


-(BOOL)loadScenePatchOnly:(NSString*)filename{
    
    if(scrollView)[scrollView removeFromSuperview];
    
    [allGUIControl removeAllObjects];
    
    [self disconnectPorts];
    
    [locationManager stopUpdatingLocation];
    
    currPortNumber = DEFAULT_PORT_NUMBER;
    [self connectPorts];
    
    if(openPDFile!=nil)[PdBase closeFile:openPDFile];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *publicDocumentsDir = [paths objectAtIndex:0];
    
    openPDFile = [PdBase openFile:filename path:publicDocumentsDir];
    if(!openPDFile) return NO;
    NSLog(@"open pd file %@", filename);
    
    [self.view addSubview:settingsButton];
    patchOnlyLabel.text = [NSString stringWithFormat:@"running %@ \nwith no interface\n\n(any network data will be\n on default port %d)", filename, DEFAULT_PORT_NUMBER];
    
    return YES;
}

-(BOOL)loadScene:(NSDictionary*) sceneDict{
    if(!sceneDict)return NO;
    
    if(scrollView)[scrollView removeFromSuperview];
    
    [allGUIControl removeAllObjects];
    
    [locationManager stopUpdatingLocation];
    
    [self disconnectPorts];
   
    //type of canvas for device
    canvasType hardwareCanvasType = [ViewController getCanvasType];
    
    //type of canvas used in the _editor_ to make the interface. If it doesn't match the above hardwareCnvasType, then we will be scaling to fit
    canvasType editorCanvasType = canvasTypeIPhone3p5Inch;
    if([sceneDict objectForKey:@"canvasType"]){
        if([[sceneDict objectForKey:@"canvasType"] isEqualToString:@"iPhone3p5Inch"])editorCanvasType=canvasTypeIPhone3p5Inch;
        else if([[sceneDict objectForKey:@"canvasType"] isEqualToString:@"iPhone4Inch"])editorCanvasType=canvasTypeIPhone4Inch;
        else if([[sceneDict objectForKey:@"canvasType"] isEqualToString:@"iPad"])editorCanvasType=canvasTypeIPad;
    }
    
    //get two necessary layout values from the JSON file
    // page count
    int pageCount = 1;
    if([sceneDict objectForKey:@"pageCount"]){
        pageCount = [[sceneDict objectForKey:@"pageCount"] intValue];
        if(pageCount<=0)pageCount=1;
    }
    
	//orientation and init scrollview
    BOOL isOrientationLandscape = NO;
    if([sceneDict objectForKey:@"isOrientationLandscape"]){
         isOrientationLandscape = [[sceneDict objectForKey:@"isOrientationLandscape"] boolValue];
    }
    
    //big switch to get layout of the scrollview that holds the GUI
    float zoomFactor=1;
    CGRect scrollViewFrame;
    CGSize nativeSize;//portrait
    CGSize docSize;
    
    switch(editorCanvasType){
            case canvasTypeIPhone3p5Inch:
            switch(hardwareCanvasType){
                    case canvasTypeIPhone3p5Inch:
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(0, 0, 320, 480);break;
                            case YES:scrollViewFrame=CGRectMake(0, 0, 480, 320);break;
                        }break;
                    case canvasTypeIPhone4Inch:
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(0, 44, 320, 480);break;
                            case YES:scrollViewFrame=CGRectMake(44, 0, 480, 320);break;
                        }break;
                    case canvasTypeIPad:
                        zoomFactor=2; //letterboxed on all sides, just so that we get to use a nice round zoom factor of 2
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(64, 32, 640, 960);break;
                            case YES:scrollViewFrame=CGRectMake(32, 64, 960, 640);break;
                        }break;
                }break;
            
            case canvasTypeIPhone4Inch:
                switch(hardwareCanvasType){
                    case canvasTypeIPhone3p5Inch:
                        zoomFactor=.84507;
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(24.8, 0, 270.4, 480);break;
                            case YES:scrollViewFrame=CGRectMake(0, 24.8, 480, 270.4);break;
                        }break;
                    case canvasTypeIPhone4Inch:
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(0, 0, 320, 568);break;
                            case YES:scrollViewFrame=CGRectMake(0, 0, 568, 320);break;
                        }break;
                    case canvasTypeIPad:
                        zoomFactor=1.802;
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(95.55, 0, 576.9, 1024);break;
                            case YES:scrollViewFrame=CGRectMake(0, 95.55, 1024, 576.9);break;
                        }break;
                }break;
            case canvasTypeIPad:
                switch(hardwareCanvasType){
                    case canvasTypeIPhone3p5Inch:
                        zoomFactor=.416666;
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(0, 26.66, 320, 426.666);break;
                            case YES:scrollViewFrame=CGRectMake(26.66, 0, 426.666, 320);break;
                        }break;
                    case canvasTypeIPhone4Inch:
                        zoomFactor=.416666;
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(0, 70.66, 320, 426.666);break;
                            case YES:scrollViewFrame=CGRectMake(70.66, 0, 426.666, 320);break;
                        }break;
                    case canvasTypeIPad:
                        switch (isOrientationLandscape) {
                            case NO:scrollViewFrame=CGRectMake(0,0,768, 1024);break;
                            case YES:scrollViewFrame=CGRectMake(0, 0, 1024, 768);break;
                        }break;
                }break;
        }
    //end of big switch
  
    
    //get my size, rotatepoint
    CGPoint rotatePoint;
    switch (hardwareCanvasType) {
        case canvasTypeIPhone3p5Inch:
            nativeSize = CGSizeMake(320, 480);
            rotatePoint = CGPointMake(160,240);
            break;
        case canvasTypeIPhone4Inch:
            nativeSize = CGSizeMake(320, 568);
            rotatePoint = CGPointMake(160,284);
            break;
        case canvasTypeIPad:
            nativeSize = CGSizeMake(768, 1024);
            rotatePoint = CGPointMake(384,512);
            break;
    }
    
    //get editor document intended size 
    switch (editorCanvasType) {
        case canvasTypeIPhone3p5Inch:
            switch(isOrientationLandscape){
                case NO:docSize= CGSizeMake(320, 480);break;
                case YES:docSize=CGSizeMake( 480, 320);break;
            }break;
        case canvasTypeIPhone4Inch:
            switch(isOrientationLandscape){
                case NO:docSize=CGSizeMake(320, 568);break;
                case YES:docSize=CGSizeMake( 568, 320);break;
            }break;
        case canvasTypeIPad: switch(isOrientationLandscape){
            case NO:docSize=CGSizeMake(768, 1024);break;
            case YES:docSize=CGSizeMake( 1024, 768);break;
        }break;
    }
    
    scrollView = [[UIScrollView alloc]initWithFrame:scrollViewFrame];
    scrollInnerView = [[UIView alloc]initWithFrame:CGRectMake(0, 0, docSize.width*pageCount, docSize.height)];
    
    [scrollView setContentSize:scrollInnerView.frame.size];
    [scrollView addSubview:scrollInnerView];
    
    if(isOrientationLandscape){//rotate
        scrollView.center = rotatePoint;
        scrollView.transform = CGAffineTransformMakeRotation(M_PI/2);
    }
    
    scrollView.pagingEnabled = YES;
    scrollView.delaysContentTouches=NO;
    scrollView.maximumZoomScale = zoomFactor;
    scrollView.minimumZoomScale = zoomFactor;
    [scrollView setDelegate:self];
    [self.view addSubview:scrollView];
    
    
    
    //continue getting parameters from JSON
    //OSC port number
    if ([sceneDict objectForKey:@"port"]){
        int port = [[sceneDict objectForKey:@"port"] intValue];
        currPortNumber=port;
        
    }
    else currPortNumber=DEFAULT_PORT_NUMBER;
    
    [self connectPorts];//conencts to value of currPortNumber 
    
    //start page
    int startPageIndex = 0;
    if([sceneDict objectForKey:@"startPageIndex"]){
        startPageIndex = [[sceneDict objectForKey:@"startPageIndex"] intValue];
        //check if beyond pageCount, then set to last page
        if(startPageIndex>pageCount)startPageIndex=pageCount-1;
    }
    
    //bg color
    if([sceneDict objectForKey:@"backgroundColor"])
        scrollView.backgroundColor=[MeControl colorFromRGBArray:[sceneDict objectForKey:@"backgroundColor"]];
    
    
    //get array of all widgets 
    NSArray* controlArray = [sceneDict objectForKey:@"gui"];
    if(!controlArray)return NO;
    //check that it is an array of NSDictionary 
    if([controlArray count]>0 && ![[controlArray objectAtIndex:0] isKindOfClass:[NSDictionary class]])return NO;
    
    //step through each gui widget, big loop each time
   	for(NSDictionary* currDict in controlArray){
        MeControl* currObject;
      
        //start with elements common to all widget subclasses
        //frame - if no frame is found, skip this widget
        NSArray* frameRectArray = [currDict objectForKey:@"frame"];
        if(!frameRectArray)continue;
        
        CGRect frame = CGRectMake([[frameRectArray objectAtIndex:0] floatValue], [[frameRectArray objectAtIndex:1] floatValue], [[frameRectArray objectAtIndex:2] floatValue], [[frameRectArray objectAtIndex:3] floatValue]);
        
       
        //widget color
        UIColor* color = [UIColor colorWithRed:1 green:1 blue:1 alpha:1];
        if([currDict objectForKey:@"color"]){
            NSArray* colorArray = [currDict objectForKey:@"color"];
            if([colorArray count]==3)//old format before translucency
                color =[MeControl colorFromRGBArray:colorArray];
            else if([colorArray count]==4)//newer format including transulcency
                color =[MeControl colorFromRGBAArray:colorArray];
        }
        
        //widget highlight color
        UIColor* highlightColor = [UIColor grayColor];
        if([currDict objectForKey:@"highlightColor"]){
            NSArray* highlightColorArray = [currDict objectForKey:@"highlightColor"];
            if([highlightColorArray count]==3)
                highlightColor =[MeControl colorFromRGBArray:highlightColorArray];
            else if([highlightColorArray count]==4)
                highlightColor =[MeControl colorFromRGBAArray:highlightColorArray];
        }
        
        //get the subclass type, and do subclass-specific stuff
        NSString* newObjectClass =[currDict objectForKey:@"class"];
        if(!newObjectClass) continue;
        
        if([newObjectClass isEqualToString:@"MMPSlider"]){
            currObject = [[MeSlider alloc] initWithFrame:frame];
            if([currDict objectForKey:@"isHorizontal"] ){
                if( [[currDict objectForKey:@"isHorizontal"] boolValue]==YES )[(MeSlider*)currObject setHorizontal];
            }
            if([currDict objectForKey:@"range"])  [(MeSlider*)currObject setRange:[[currDict objectForKey:@"range"] intValue]];
            
        }
        else if([newObjectClass isEqualToString:@"MMPKnob"]){
            currObject=[[MeKnob alloc]initWithFrame:frame];// alloc] init];
            if([currDict objectForKey:@"range"])  [(MeKnob*)currObject setRange:[[currDict objectForKey:@"range"] intValue]];
            UIColor* indicatorColor = [UIColor colorWithRed:1 green:1 blue:1 alpha:1];
            if([currDict objectForKey:@"indicatorColor"]){
                indicatorColor = [MeControl colorFromRGBAArray:[currDict objectForKey:@"indicatorColor"]];
            }
            [(MeKnob*)currObject setIndicatorColor:indicatorColor];
        }
        else if([newObjectClass isEqualToString:@"MMPLabel"]){
            currObject = [[MeLabel alloc]initWithFrame:frame];
            if([currDict objectForKey:@"text"]) [(MeLabel*)currObject setStringValue:[currDict objectForKey:@"text"]];
            if([currDict objectForKey:@"textSize"]) [(MeLabel*)currObject setTextSize:[[currDict objectForKey:@"textSize"] intValue] ];
            if([currDict objectForKey:@"textFont"] && [currDict objectForKey:@"textFontFamily"])
                [(MeLabel*)currObject setFontFamily:[currDict objectForKey:@"textFontFamily"] fontName:[currDict objectForKey:@"textFont"] ];
            [(MeLabel*)currObject sizeToFit];
            
        }
        else if([newObjectClass isEqualToString:@"MMPButton"]){
            currObject = [[MeButton alloc]initWithFrame:frame];
        }
        else if([newObjectClass isEqualToString:@"MMPToggle"]){
            currObject = [[MeToggle alloc]initWithFrame:frame];
            if([currDict objectForKey:@"borderThickness"])[(MeToggle*)currObject setBorderThickness:[[currDict objectForKey:@"borderThickness"] intValue]];
        }
        else if([newObjectClass isEqualToString:@"MMPXYSlider"]){
            currObject = [[MeXYSlider alloc]initWithFrame:frame];
        }
        else if([newObjectClass isEqualToString:@"MMPGrid"]){
            currObject = [[MeGrid alloc]initWithFrame:frame];
            if([currDict objectForKey:@"dim"]){
                NSArray* dimArray =[currDict objectForKey:@"dim"];
                [(MeGrid*)currObject setDimX: [[dimArray objectAtIndex:0]intValue] Y:[[dimArray objectAtIndex:1]intValue] ];
            }
            if([currDict objectForKey:@"cellPadding"])[(MeGrid*)currObject setCellPadding:[[currDict objectForKey:@"cellPadding"] intValue]];
            if([currDict objectForKey:@"borderThickness"])[(MeGrid*)currObject setBorderThickness:[[currDict objectForKey:@"borderThickness"] intValue]];
        }
        else if([newObjectClass isEqualToString:@"MMPPanel"]){
            currObject = [[MePanel alloc]initWithFrame:frame];
            if([currDict objectForKey:@"imagePath"]) [(MePanel*)currObject setImagePath:[currDict objectForKey:@"imagePath"] ];
        }
        else if([newObjectClass isEqualToString:@"MMPMultiSlider"]){
            currObject = [[MeMultiSlider alloc] initWithFrame:frame];
            if([currDict objectForKey:@"range"])  [(MeMultiSlider*)currObject setRange:[[currDict objectForKey:@"range"] intValue]];
        }
        //end subclass-specific list

        if(currObject){//if successfully created object
            currObject.controlDelegate=self;
        
            if([currObject respondsToSelector:@selector(setColor:)]){//in theory all mecontrol respond to these
                [currObject setColor:color];
            }
            if([currObject respondsToSelector:@selector(setHighlightColor:)]){
                [currObject setHighlightColor:highlightColor];
            }
        
            [allGUIControl addObject:currObject];
        
            //set OSC address for widget
            NSString* address = @"dummy";
            if([currDict objectForKey:@"address"])address = [currDict objectForKey:@"address"];
            [currObject setAddress:address];
        
            [scrollInnerView addSubview:currObject];
        }
        
    }
    //end of big loop through widgets
    
    //scroll to start page, and put settings button on top
    [scrollView zoomToRect:CGRectMake(docSize.width*startPageIndex, 0, docSize.width, docSize.height) animated:NO];
    [scrollView addSubview:settingsButton];
    
    ///===PureData patch
    //if one is open, close it
    if(openPDFile!=nil)[PdBase closeFile:openPDFile];
    
    if([sceneDict objectForKey:@"pdFile"]){
        NSString* filename = [sceneDict objectForKey:@"pdFile"];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *publicDocumentsDir = [paths objectAtIndex:0];
        
        openPDFile = [PdBase openFile:filename path:publicDocumentsDir];//attempt to open
        NSLog(@"open pd file %@", filename );
        
        if(openPDFile==nil){//failure to load the named patch
             NSLog(@"did not find named patch!" );
            UIAlertView *alert = [[UIAlertView alloc]
                                  initWithTitle: @"Pd file not found"
                                  message: [NSString stringWithFormat:@"Pd file %@ not found, make sure you add it to Documents in iTunes", filename]
                                  delegate: nil
                                  cancelButtonTitle:@"OK"
                                  otherButtonTitles:nil];
            [alert show];
            
        }
    }
    else{//if no JSON entry found for file, say so
        openPDFile=nil;
        //printf("\n did not find patch!");
        NSLog(@"did not find a patch name!" );
        UIAlertView *alert = [[UIAlertView alloc]
                              initWithTitle: @"Pd file not specified"
                              message: @"This interface has not been linked to a Pd file. Add it in the editor!"
                              delegate: nil
                              cancelButtonTitle:@"OK"
                              otherButtonTitles:nil];
        [alert show];
    }

    
    return YES;
}

//scrollview delegate
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return scrollInnerView;
}

//I want to send a message into PD patch from a gui widget
-(void)sendGUIMessageArray:(NSArray*)msgArray{
    [PdBase sendList:msgArray toReceiver:@"fromGUI"];
}

//PureData has sent out a message from the patch (from a receive object, we look for messages from "toNetwork","toGUI","toSystem")
- (void)receiveList:(NSArray *)list fromSource:(NSString *)source{
    if([source isEqualToString:@"toNetwork"]){
        OSCMessage *msg = [OSCMessage createWithAddress:[list objectAtIndex:0]];
        for(id item in [list subarrayWithRange:NSMakeRange(1, [list count]-1)]){
            if([item isKindOfClass:[NSString class]]) [msg addString:item];
            else if([item isKindOfClass:[NSNumber class]])[msg addFloat:[item floatValue]];
        }
        [outPort sendThisPacket:[OSCPacket createWithContent:msg]];
    }
    
    else if([source isEqualToString:@"toGUI"]){
        for(MeControl* control in allGUIControl){
            if([[control address] isEqualToString:[list objectAtIndex:0]]){
                [control receiveList:[list subarrayWithRange:NSMakeRange(1, [list count]-1)]];
            }
        }
    }
    
    else if([source isEqualToString:@"toSystem"]){
        //for some reason, there is a conflict with the audio session, and sending a command to vibrate doesn't work...
        /*if([[list objectAtIndex:0] isEqualToString:@"/vibrate"]){
            //printf("\nvib?");
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate); 
        }*/
        //camera flash
        if([[list objectAtIndex:0] isEqualToString:@"/flash"] && [[list objectAtIndex:1] isKindOfClass:[NSNumber class]]){
            float val = [[list objectAtIndex:1] floatValue];
            if ([avCaptureDevice hasTorch]) {
                [avCaptureDevice lockForConfiguration:nil];
                if(val>0)[avCaptureDevice setTorchMode:AVCaptureTorchModeOn];  // use AVCaptureTorchModeOff to turn off
                else [avCaptureDevice setTorchMode:AVCaptureTorchModeOff];
                [avCaptureDevice unlockForConfiguration];
            }
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/setAccelFrequency"] && [[list objectAtIndex:1] isKindOfClass:[NSNumber class]]){
            float val = [[list objectAtIndex:1] floatValue];
            if(val<0.01)val=0.01;//clip
            if(val>100)val=100;
            self.accelFrequency=val;
            [[UIAccelerometer sharedAccelerometer] setUpdateInterval:1.0/val];
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/getAccelFrequency"]){
            NSArray* msgArray=[NSArray arrayWithObjects:@"/accelFrequency", [NSNumber numberWithFloat:self.accelFrequency], nil];
            [PdBase sendList:msgArray toReceiver:@"fromSystem"];
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/setGyroFrequency"] && [[list objectAtIndex:1] isKindOfClass:[NSNumber class]]){
            float val = [[list objectAtIndex:1] floatValue];
            if(val<0.01)val=0.01;//clip
            if(val>100)val=100;
            self.gyroFrequency=val;
            motionManager.gyroUpdateInterval=1.0/val;
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/getGyroFrequency"]){
            NSArray* msgArray=[NSArray arrayWithObjects:@"/gyroFrequency", [NSNumber numberWithFloat:self.gyroFrequency], nil];
            [PdBase sendList:msgArray toReceiver:@"fromSystem"];
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/setMotionFrequency"] && [[list objectAtIndex:1] isKindOfClass:[NSNumber class]]){
            float val = [[list objectAtIndex:1] floatValue];
            if(val<0.01)val=0.01;//clip
            if(val>100)val=100;
            self.motionFrequency=val;
            motionManager.deviceMotionUpdateInterval=1.0/val;
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/getMotionFrequency"]){
            NSArray* msgArray=[NSArray arrayWithObjects:@"/motionFrequency", [NSNumber numberWithFloat:self.motionFrequency], nil];
            [PdBase sendList:msgArray toReceiver:@"fromSystem"];
        }
        //GPS
        else if([[list objectAtIndex:0] isEqualToString:@"/enableLocation"] && [[list objectAtIndex:1] isKindOfClass:[NSNumber class]]){
            float val = [[list objectAtIndex:1] floatValue];
            //printf("\nenable location %.2f", val );
            if(val>0)[locationManager startUpdatingLocation];
            else [locationManager stopUpdatingLocation ];
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/setDistanceFilter"] && [[list objectAtIndex:1] isKindOfClass:[NSNumber class]]){
            float val = [[list objectAtIndex:1] floatValue];
            //printf("\ndistance filter %.2f", val );
            if(val>0)[locationManager setDistanceFilter:val];
            else [locationManager setDistanceFilter:kCLDistanceFilterNone];
        }
        else if([[list objectAtIndex:0] isEqualToString:@"/getDistanceFilter"]){
            NSArray* msgArray=[NSArray arrayWithObjects:@"/distanceFilter", [NSNumber numberWithFloat:locationManager.distanceFilter], nil];
            [PdBase sendList:msgArray toReceiver:@"fromSystem"];
        }
        /*else if([[list objectAtIndex:0] isEqualToString:@"/getMotionFrequency"]){
            NSArray* msgArray=[NSArray arrayWithObjects:@"/motionFrequency", [NSNumber numberWithFloat:self.motionFrequency], nil];
            [PdBase sendList:msgArray toReceiver:@"fromSystem"];
        }*/
        


    }
}

//not used, since we only receive lists
/*- (void)receiveSymbol:(NSString *)symbol fromSource:(NSString *)source{
}*/

- (void)receivePrint:(NSString *)message
{
    [settingsVC consolePrint:message];
}

//receive OSC message from network, format into message to send into PureData patch
- (void) receivedOSCMessage:(OSCMessage *)m	{
	NSString *address = [m address];
	
    NSMutableArray* msgArray = [[NSMutableArray alloc]init];//create blank message array for sending to pd
    NSMutableArray* tempOSCValueArray = [[NSMutableArray alloc]init];
    
    //VV library handles receiving a value confusingly: if just one value, it has a single value in message "m" and no valueArray, if more than one value, it has valuearray. here we just shove either into a temp array to iterate over
    
    if([m valueCount]==1)[tempOSCValueArray addObject:[m value]];
    else for(OSCValue *val in [m valueArray])[tempOSCValueArray addObject:val];
    
    //first element in msgArray is address
    [msgArray addObject:address];
    
    //then iterate over all values
    for(OSCValue *val in tempOSCValueArray){//unpack OSC value to NSNumber or NSString
        if([val type]==OSCValInt){
            [msgArray addObject:[NSNumber numberWithInt:[val intValue]]];
        }
        else if([val type]==OSCValFloat){
            [msgArray addObject:[NSNumber numberWithFloat:[val floatValue]]];
        }
        else if([val type]==OSCValString){
            [msgArray addObject:[val stringValue]];
        }
        
    }
    
    [PdBase sendList:msgArray toReceiver:@"fromNetwork"];
}


//receive shake gesture
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if ( event.subtype == UIEventSubtypeMotionShake ){
        NSArray* msgArray=[NSArray arrayWithObjects:@"/shake", [NSNumber numberWithInt:1], nil];
        
        [PdBase sendList:msgArray toReceiver:@"fromSystem"];
    }
    
    /*//not sure if necessary, pass it up responder chain...
    if ( [super respondsToSelector:@selector(motionEnded:withEvent:)] )
        [super motionEnded:motion withEvent:event];*/
}

- (BOOL)canBecomeFirstResponder{
    return YES;
}

-(void)setMidiSourceIndex:(int)inIndex{
	currMidiSourceIndex=inIndex;
	[currMidiSource removeDelegate:self];
    currMidiSource = [midi.sources objectAtIndex:inIndex];
	[currMidiSource addDelegate:self];
    NSLog(@"set MidiSourceIndex to %d, %@", inIndex, currMidiSource.name);
}

-(void)setMidiDestinationIndex:(int)inIndex{
    currMidiDestinationIndex = inIndex;
    //[currMidiDestination]
    currMidiDestination=[midi.destinations objectAtIndex:inIndex];
    NSLog(@"set MidiDestinationIndex to %d, %@", inIndex, currMidiDestination.name);
}

//==== pgmidi delegate methods
- (void) midi:(PGMidi*)midi sourceAdded:(PGMidiSource *)source
{
    //printf("\nmidi source added");
    [settingsVC reloadMidiSources];
   
}

- (void) midi:(PGMidi*)midi sourceRemoved:(PGMidiSource *)source{
     [settingsVC reloadMidiSources];
}


- (void) midi:(PGMidi*)midi destinationAdded:(PGMidiDestination *)destination{
    //NSLog(@"added %@", destination.name);
    [settingsVC reloadMidiSources];
}

- (void) midi:(PGMidi*)midi destinationRemoved:(PGMidiDestination *)destination{
    //NSLog(@"removed %@", destination.name);
    [settingsVC reloadMidiSources];
}


-(NSMutableArray*)midiSourcesArray{//of PGMIDIConnection, get name connection.name
	return midi.sources;
}

//PG midisource delegate
/*NSString *StringFromPacket(const MIDIPacket *packet)
{
    // Note - this is not an example of MIDI parsing. I'm just dumping
    // some bytes for diagnostics.
    // See comments in PGMidiSourceDelegate for an example of how to
    // interpret the MIDIPacket structure.
    return [NSString stringWithFormat:@"  %u bytes: [%02x,%02x,%02x]",
            packet->length,
            (packet->length > 0) ? packet->data[0] : 0,
            (packet->length > 1) ? packet->data[1] : 0,
            (packet->length > 2) ? packet->data[2] : 0
			];
}*/


#if TARGET_CPU_ARM
// MIDIPacket must be 4-byte aligned
#define MyMIDIPacketNext(pkt)	((MIDIPacket *)(((uintptr_t)(&(pkt)->data[(pkt)->length]) + 3) & ~3))
#else
#define MyMIDIPacketNext(pkt)	((MIDIPacket *)&(pkt)->data[(pkt)->length])
#endif

- (void) midiSource:(PGMidiSource*)midi midiReceived:(const MIDIPacketList *)packetList{

       const MIDIPacket *packet = &packetList->packet[0];
	
    for (int i = 0; i < packetList->numPackets; ++i){
		//chop packets into messages, there could be more than one!
		
		int messageLength;//2 or 3
		/*Byte**/ const unsigned char* statusByte=nil;
		for(int i=0;i<packet->length;i++){//step throguh each byte, i
			if(((packet->data[i] >>7) & 0x01) ==1){//if a newstatus byte
				//send existing
				if(statusByte!=nil)[self performSelectorOnMainThread:@selector(parseMessageData:) withObject:[NSData dataWithBytes:statusByte length:messageLength] waitUntilDone:NO];
				messageLength=0;
				//now point to new start
				statusByte=&packet->data[i];
			}
			messageLength++;
		}
		//send what is left
		[self performSelectorOnMainThread:@selector(parseMessageData:) withObject:[NSData dataWithBytes:statusByte length:messageLength] waitUntilDone:NO];

        packet = MyMIDIPacketNext(packet);
    }
	
}

//take messageData, derive the MIDI message type, and send it into PD to be picked up by PD's midi objects
-(void)parseMessageData:(NSData*)messageData{//2 or 3 bytes
	
	
	Byte* bytePtr = ((Byte*)([messageData bytes]));
	char type = ( bytePtr[0] >> 4) & 0x07 ;//remove leading 1 bit 0-7
	char channel = (bytePtr[0] & 0x0F);
    
    for(int i=0;i<[messageData length];i++)
        [PdBase sendMidiByte:currMidiSourceIndex byte:(int)bytePtr[i]];
	
	
    switch (type) {
			case 0://noteoff
				[PdBase sendNoteOn:(int)channel pitch:(int)bytePtr[1] velocity:0];
				break;
			case 1://noteon
                [PdBase sendNoteOn:(int)channel pitch:(int)bytePtr[1] velocity:(int)bytePtr[2]];
                break;
            case 2://poly aftertouch
                [PdBase sendPolyAftertouch:(int)channel pitch:(int)bytePtr[1] value:(int)bytePtr[2]];
                break;
			case 3://CC
                [PdBase sendControlChange:(int)channel controller:(int)bytePtr[1] value:(int)bytePtr[2]];
                break;
            case 4://prgm change
                [PdBase sendProgramChange:(int)channel value:(int)bytePtr[1]];
                break;
            case 5://aftertouch
                [PdBase sendAftertouch:(int)channel value:(int)bytePtr[1]];
                break;
            case 6://pitch bend - lsb, msb
                {
                    int bendValue;
                    if([messageData length]==3)
                         bendValue= (bytePtr[1] | bytePtr[2]<<7) -8192;
                    else //2
                        bendValue=(bytePtr[1] | bytePtr[1]<<7)-8192;
                    [PdBase sendPitchBend:(int)channel value:bendValue];
                }
                break;
				
			default:
				break;
		}
}

//receive midi from PD, out to PGMidi

- (void)receiveNoteOn:(int)pitch withVelocity:(int)velocity forChannel:(int)channel {
    const UInt8 bytes[]  = { 0x90+channel, pitch, velocity };
    [currMidiDestination sendBytes:bytes size:sizeof(bytes)];
}

- (void)receiveControlChange:(int)value forController:(int)controller forChannel:(int)channel {
    const UInt8 bytes[]  = { 0xB0+channel, controller, value };
    [currMidiDestination sendBytes:bytes size:sizeof(bytes)];
}

- (void)receiveProgramChange:(int)value forChannel:(int)channel {
    const UInt8 bytes[]  = { 0xC0+channel, value };
    [currMidiDestination sendBytes:bytes size:sizeof(bytes)];
}

- (void)receivePitchBend:(int)value forChannel:(int)channel {
    const UInt8 bytes[]  = { 0xE0+channel, (value-8192)&0x7F, ((value-8192)>>7)&0x7F };
    [currMidiDestination sendBytes:bytes size:sizeof(bytes)];
}

- (void)receiveAftertouch:(int)value forChannel:(int)channel {
    const UInt8 bytes[]  = { 0xD0+channel, value };
    [currMidiDestination sendBytes:bytes size:sizeof(bytes)];
}

- (void)receivePolyAftertouch:(int)value forPitch:(int)pitch forChannel:(int)channel {
    const UInt8 bytes[]  = { 0xA0+channel, pitch, value };
    [currMidiDestination sendBytes:bytes size:sizeof(bytes)];
}

- (void)receiveMidiByte:(int)byte forPort: (int)port {
    const UInt8 shortByte = (UInt8)byte;
    [currMidiDestination sendBytes:&shortByte size:1];
}

///GPS
- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation fromLocation:(CLLocation *)oldLocation {
	//printf("\ndidupdate! : %f %f", newLocation.coordinate.latitude, newLocation.coordinate.longitude);
    //[settingsVC consolePrint:[NSString stringWithFormat:@"\ngps %f %f\n", newLocation.coordinate.latitude, newLocation.coordinate.longitude]];
    
    ///location lat long alt horizacc vertacc, lat fine long fine
    int latRough = (int)( newLocation.coordinate.latitude*1000);
    int longRough = (int)( newLocation.coordinate.longitude*1000);
    int latFine = (int)fabs((fmod( newLocation.coordinate.latitude , .001)*1000000));
    int longFine = (int)fabs((fmod( newLocation.coordinate.longitude , .001)*1000000));

    //printf("\n %f %f %d %d %d %d", newLocation.coordinate.latitude, newLocation.coordinate.longitude, latRough, longRough, latFine, longFine);
    
    NSArray* locationArray=[NSArray arrayWithObjects:@"/location", [NSNumber numberWithFloat:newLocation.coordinate.latitude],[NSNumber numberWithFloat:newLocation.coordinate.longitude], [NSNumber numberWithFloat:newLocation.altitude], [NSNumber numberWithFloat:newLocation.horizontalAccuracy], [NSNumber numberWithFloat:newLocation.verticalAccuracy], [NSNumber numberWithInt:latRough], [NSNumber numberWithInt:longRough], [NSNumber numberWithInt:latFine], [NSNumber numberWithInt:longFine], nil];
    
    [PdBase sendList:locationArray toReceiver:@"fromSystem"];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
	//printf("\nupdatefail!");
    if (![CLLocationManager locationServicesEnabled]){
        UIAlertView *alert = [[UIAlertView alloc]
                              initWithTitle: @"Location Fail"
                              message: @"Location Services Disabled"
                              delegate: nil
                              cancelButtonTitle:@"OK"
                              otherButtonTitles:nil];
        [alert show];
    }
       
    
    
   else if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusDenied){
        UIAlertView *alert = [[UIAlertView alloc]
                              initWithTitle: @"Location Fail"
                              message: @"Location Services Denied - check iOS privacy settings"
                              delegate: nil
                              cancelButtonTitle:@"OK"
                              otherButtonTitles:nil];
    [alert show];
    }
    
   else {
       UIAlertView *alert = [[UIAlertView alloc]
                             initWithTitle: @"Location Fail"
                             message: @"Location Services Unavailable"
                             delegate: nil
                             cancelButtonTitle:@"OK"
                             otherButtonTitles:nil];
       [alert show];
   }

    
   /* if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorized)
        NSLog(@"location services are enabled");
    
    if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusNotDetermined)
        NSLog(@"about to show a dialog requesting permission");*/

    

	
}


- (void)didReceiveMemoryWarning{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
