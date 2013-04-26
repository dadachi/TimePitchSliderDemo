//
//  SNFViewController.m
//  TimePitchScratch
//
//  Created by Chris Adamson on 10/13/12.
//  Copyright (c) 2012 Your Organization. All rights reserved.
//

#import "SNFViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "DCFileProducer.h"

@interface SNFViewController ()
-(NSError*) setUpAudioSession;
-(void) setUpAUGraph;
-(void) resetRate;
@property (atomic) AUGraph auGraph;
@property (atomic) AudioUnit ioUnit;
@property (atomic) AudioUnit effectUnit;
@property (atomic) AudioUnit filePlayerUnit;
@property (weak, nonatomic) IBOutlet UISlider *timeSlider;
@property (weak, nonatomic) IBOutlet UISlider *pitchSlider;
@property (weak, nonatomic) IBOutlet UILabel *rateLabel;
- (IBAction)timeSliderChanged:(id)sender;
- (IBAction)pitchSliderChanged:(id)sender;
- (IBAction)handleResetTo1Tapped:(id)sender;

@property(nonatomic, retain)DCMediaExporter *mediaExporter;
@property(nonatomic, retain)DCAudioProducer *audioProducer;
@property(nonatomic, retain)UIAlertView *alertView;
- (NSURL *)_exportURLForMediaItem:(MPMediaItem *)mediaItem;

@end

@implementation SNFViewController

@synthesize auGraph = _auGraph;
@synthesize ioUnit = _ioUnit;
@synthesize effectUnit = _effectUnit;
@synthesize filePlayerUnit = _filePlayerUnit;

@synthesize song;
@synthesize songLabel;
@synthesize artistLabel;
@synthesize coverArtView;

static void CheckError(OSStatus error, const char *operation)
{
	if (error == noErr) return;
	
	char str[20];
	// see if it appears to be a 4-char-code
	*(UInt32 *)(str + 1) = CFSwapInt32HostToBig(error);
	if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
		str[0] = str[5] = '\'';
		str[6] = '\0';
	} else
		// no, format it as an integer
		sprintf(str, "%d", (int)error);
    
	fprintf(stderr, "Error: %s (%s)\n", operation, str);
    
	exit(1);
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
	
	[self setUpAudioSession];
//	[self setUpAUGraph];
//	[self resetRate];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)chooseSongButtonPressed:(id)sender
{
    NSLog(@"chooseSongButtonPressed");
//    [audioPlayer stop];
//    songRateSlider.value = 0.0f;
//    [self speedSliderValueChanged:songRateSlider];
	MPMediaPickerController *pickerController =	[[MPMediaPickerController alloc]
												 initWithMediaTypes: MPMediaTypeMusic];
	pickerController.prompt = @"Choose song";
	pickerController.allowsPickingMultipleItems = NO;
	pickerController.delegate = self;
	[self presentModalViewController:pickerController animated:YES];
}

#pragma mark slider stuff
- (IBAction)timeSliderChanged:(id)sender {
	[self resetRate];
}

#pragma mark slider stuff
- (IBAction)pitchSliderChanged:(id)sender {
	[self resetPitch];
}

- (IBAction)handleResetTo1Tapped:(id)sender {
	self.timeSlider.value = 5.0; // see math explainer in resetRate
	[self resetRate];
}

#pragma mark av foundation stuff
-(NSError*) setUpAudioSession {
	NSError *sessionErr;
	[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
										   error:&sessionErr];
	if (sessionErr) { return sessionErr; }
	[[AVAudioSession sharedInstance] setActive:YES
										 error:&sessionErr];
	if (sessionErr) { return sessionErr; }
	
	return nil;
}


#pragma mark core audio stuff
-(void) setUpAUGraph {
	if (self.auGraph) {
		CheckError(AUGraphClose(self.auGraph),
				   "Couldn't close old AUGraph");
		CheckError (DisposeAUGraph(self.auGraph),
					"Couldn't dispose old AUGraph");
	}
	
	CheckError(NewAUGraph(&_auGraph),
			   "Couldn't create new AUGraph");
	
	CheckError(AUGraphOpen(self.auGraph),
			   "Couldn't open AUGraph");

	// start with file player unit
	AudioComponentDescription fileplayercd = {0};
	fileplayercd.componentType = kAudioUnitType_Generator;
	fileplayercd.componentSubType = kAudioUnitSubType_AudioFilePlayer;
	fileplayercd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AUNode filePlayerNode;
	CheckError(AUGraphAddNode(self.auGraph,
							  &fileplayercd,
							  &filePlayerNode),
			   "Couldn't add file player node");
	// get the actual unit
	CheckError(AUGraphNodeInfo(self.auGraph,
							   filePlayerNode,
							   NULL,
							   &_filePlayerUnit),
			   "couldn't get file player node");
	
	// remote io unit
	AudioComponentDescription outputcd = {0};
	outputcd.componentType = kAudioUnitType_Output;
	outputcd.componentSubType = kAudioUnitSubType_RemoteIO;
	outputcd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AUNode ioNode;
	CheckError(AUGraphAddNode(self.auGraph,
							  &outputcd,
							  &ioNode),
			   "couldn't add remote io node");
	
	// get the remote io unit from the node
	CheckError(AUGraphNodeInfo(self.auGraph,
							   ioNode,
							   NULL,
							   &_ioUnit),
			   "couldn't get remote io unit");
	
	
	// effect unit here
	AudioComponentDescription effectcd = {0};
	effectcd.componentType = kAudioUnitType_FormatConverter;
	effectcd.componentSubType = kAudioUnitSubType_NewTimePitch;
	effectcd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AUNode effectNode;
	CheckError(AUGraphAddNode(self.auGraph,
							  &effectcd,
							  &effectNode),
			   "couldn't get effect node [time/pitch]");
	
	// get effect unit from the node
	CheckError(AUGraphNodeInfo(self.auGraph,
							   effectNode,
							   NULL,
							   &_effectUnit),
			   "couldn't get effect unit from node");
	
	// enable output to the remote io unit
    UInt32 oneFlag = 1;
    UInt32 busZero = 0;
	CheckError(AudioUnitSetProperty(self.ioUnit,
									kAudioOutputUnitProperty_EnableIO,
									kAudioUnitScope_Output,
									busZero,
									&oneFlag,
									sizeof(oneFlag)),
			   "Couldn't enable output on bus 0");
//	UInt32 busOne = 1;
//
//	CheckError(AudioUnitSetProperty(self.ioUnit,
//									kAudioOutputUnitProperty_EnableIO,
//									kAudioUnitScope_Input,
//									busOne,
//									&oneFlag,
//									sizeof(oneFlag)),
//			   "Couldn't enable input on bus 1");
	
	// set stream format that the effect wants
	AudioStreamBasicDescription streamFormat;
	UInt32 propertySize = sizeof (streamFormat);
	CheckError(AudioUnitGetProperty(self.effectUnit,
									kAudioUnitProperty_StreamFormat,
									kAudioUnitScope_Input,
									0,
									&streamFormat,
									&propertySize),
			   "Couldn't get effect unit stream format");
	
//	CheckError(AudioUnitSetProperty(self.ioUnit,
//									kAudioUnitProperty_StreamFormat,
//									kAudioUnitScope_Output,
//									busOne,
//									&streamFormat,
//									sizeof(streamFormat)),
//			   "couldn't set stream format on iounit bus 1 output");

	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_StreamFormat,
									kAudioUnitScope_Output,
									busZero,
									&streamFormat,
									sizeof(streamFormat)),
			   "couldn't set stream format on file player bus 0 output");
	
	CheckError(AudioUnitSetProperty(self.ioUnit,
									kAudioUnitProperty_StreamFormat,
									kAudioUnitScope_Input,
									busZero,
									&streamFormat,
									sizeof(streamFormat)),
			   "couldn't set stream format on iounit bus 0 input");


	// file player was here
	
	// make connections
	
	CheckError(AUGraphConnectNodeInput(self.auGraph,
									   filePlayerNode,
									   0,
									   effectNode,
									   0),
			   "couldn't connect file player bus 0 output to effect bus 0 input");
	
	CheckError(AUGraphConnectNodeInput(self.auGraph,
									   effectNode,
									   0,
									   ioNode,
									   0),
			   "couldn't connect effect bus 0 output to remoteio bus 0 input");
	
	
	CheckError(AUGraphInitialize(self.auGraph),
			   "Couldn't initialize AUGraph");

	// configure file player
	CFURLRef audioFileURL = CFBridgingRetain(
											 [[NSBundle mainBundle] URLForResource:@"Bossa Lounger Long"
																	 withExtension:@"caf"]);
	NSLog (@"found URL %@", audioFileURL);
	AudioFileID audioFile;
	CheckError(AudioFileOpenURL(audioFileURL,
								kAudioFileReadPermission,
								kAudioFileCAFType,
								&audioFile),
			   "Couldn't open audio file");
	
	AudioStreamBasicDescription fileStreamFormat;
	UInt32 propsize = sizeof (fileStreamFormat);
	CheckError(AudioFileGetProperty(audioFile,
									kAudioFilePropertyDataFormat,
									&propertySize,
									&fileStreamFormat),
			   "couldn't get input file's stream format");
	
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduledFileIDs,
									kAudioUnitScope_Global,
									0,
									&audioFile,
									sizeof(audioFile)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduledFileIDs] failed");
	
	UInt64 nPackets;
	propsize = sizeof(nPackets);
	CheckError(AudioFileGetProperty(audioFile,
									kAudioFilePropertyAudioDataPacketCount,
									&propsize,
									&nPackets),
			   "AudioFileGetProperty[kAudioFilePropertyAudioDataPacketCount] failed");
	
	// tell the file player AU to play the entire file
	ScheduledAudioFileRegion rgn;
	memset (&rgn.mTimeStamp, 0, sizeof(rgn.mTimeStamp));
	rgn.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
	rgn.mTimeStamp.mSampleTime = 0;
	rgn.mCompletionProc = NULL;
	rgn.mCompletionProcUserData = NULL;
	rgn.mAudioFile = audioFile;
	rgn.mLoopCount = 100;
	rgn.mStartFrame = 0;
	rgn.mFramesToPlay = nPackets * fileStreamFormat.mFramesPerPacket;
	
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduledFileRegion,
									kAudioUnitScope_Global,
									0,
									&rgn,
									sizeof(rgn)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduledFileRegion] failed");
	
	// prime the file player AU with default values
	UInt32 defaultVal = 0;
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduledFilePrime,
									kAudioUnitScope_Global,
									0,
									&defaultVal,
									sizeof(defaultVal)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduledFilePrime] failed");
	
	// tell the file player AU when to start playing (-1 sample time means next render cycle)
	AudioTimeStamp startTime;
	memset (&startTime, 0, sizeof(startTime));
	startTime.mFlags = kAudioTimeStampSampleTimeValid;
	startTime.mSampleTime = -1;
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduleStartTimeStamp,
									kAudioUnitScope_Global,
									0,
									&startTime,
									sizeof(startTime)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduleStartTimeStamp]");

	
	
	
	CheckError(AUGraphStart(self.auGraph),
			   "Couldn't start AUGraph");
	
	
	
	NSLog (@"bottom of setUpAUGraph");
}

-(void) playSongWithAssetURL:(NSURL *)assetURL
{
	NSLog (@"playSong");
    [self setUpAUGraphWithAssetURL:assetURL];
}

-(void) setUpAUGraphWithAssetURL:(NSURL *)assetURL {
	if (self.auGraph) {
		CheckError(AUGraphClose(self.auGraph),
				   "Couldn't close old AUGraph");
		CheckError (DisposeAUGraph(self.auGraph),
					"Couldn't dispose old AUGraph");
	}
	
	CheckError(NewAUGraph(&_auGraph),
			   "Couldn't create new AUGraph");
	
	CheckError(AUGraphOpen(self.auGraph),
			   "Couldn't open AUGraph");
    
	// start with file player unit
	AudioComponentDescription fileplayercd = {0};
	fileplayercd.componentType = kAudioUnitType_Generator;
	fileplayercd.componentSubType = kAudioUnitSubType_AudioFilePlayer;
	fileplayercd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AUNode filePlayerNode;
	CheckError(AUGraphAddNode(self.auGraph,
							  &fileplayercd,
							  &filePlayerNode),
			   "Couldn't add file player node");
	// get the actual unit
	CheckError(AUGraphNodeInfo(self.auGraph,
							   filePlayerNode,
							   NULL,
							   &_filePlayerUnit),
			   "couldn't get file player node");
	
	// remote io unit
	AudioComponentDescription outputcd = {0};
	outputcd.componentType = kAudioUnitType_Output;
	outputcd.componentSubType = kAudioUnitSubType_RemoteIO;
	outputcd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AUNode ioNode;
	CheckError(AUGraphAddNode(self.auGraph,
							  &outputcd,
							  &ioNode),
			   "couldn't add remote io node");
	
	// get the remote io unit from the node
	CheckError(AUGraphNodeInfo(self.auGraph,
							   ioNode,
							   NULL,
							   &_ioUnit),
			   "couldn't get remote io unit");
	
	
	// effect unit here
	AudioComponentDescription effectcd = {0};
	effectcd.componentType = kAudioUnitType_FormatConverter;
	effectcd.componentSubType = kAudioUnitSubType_NewTimePitch;
	effectcd.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	AUNode effectNode;
	CheckError(AUGraphAddNode(self.auGraph,
							  &effectcd,
							  &effectNode),
			   "couldn't get effect node [time/pitch]");
	
	// get effect unit from the node
	CheckError(AUGraphNodeInfo(self.auGraph,
							   effectNode,
							   NULL,
							   &_effectUnit),
			   "couldn't get effect unit from node");
	
	// enable output to the remote io unit
    UInt32 oneFlag = 1;
    UInt32 busZero = 0;
	CheckError(AudioUnitSetProperty(self.ioUnit,
									kAudioOutputUnitProperty_EnableIO,
									kAudioUnitScope_Output,
									busZero,
									&oneFlag,
									sizeof(oneFlag)),
			   "Couldn't enable output on bus 0");
    //	UInt32 busOne = 1;
    //
    //	CheckError(AudioUnitSetProperty(self.ioUnit,
    //									kAudioOutputUnitProperty_EnableIO,
    //									kAudioUnitScope_Input,
    //									busOne,
    //									&oneFlag,
    //									sizeof(oneFlag)),
    //			   "Couldn't enable input on bus 1");
	
	// set stream format that the effect wants
	AudioStreamBasicDescription streamFormat;
	UInt32 propertySize = sizeof (streamFormat);
	CheckError(AudioUnitGetProperty(self.effectUnit,
									kAudioUnitProperty_StreamFormat,
									kAudioUnitScope_Input,
									0,
									&streamFormat,
									&propertySize),
			   "Couldn't get effect unit stream format");
	
    //	CheckError(AudioUnitSetProperty(self.ioUnit,
    //									kAudioUnitProperty_StreamFormat,
    //									kAudioUnitScope_Output,
    //									busOne,
    //									&streamFormat,
    //									sizeof(streamFormat)),
    //			   "couldn't set stream format on iounit bus 1 output");
    
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_StreamFormat,
									kAudioUnitScope_Output,
									busZero,
									&streamFormat,
									sizeof(streamFormat)),
			   "couldn't set stream format on file player bus 0 output");
	
	CheckError(AudioUnitSetProperty(self.ioUnit,
									kAudioUnitProperty_StreamFormat,
									kAudioUnitScope_Input,
									busZero,
									&streamFormat,
									sizeof(streamFormat)),
			   "couldn't set stream format on iounit bus 0 input");
    
    
	// file player was here
	
	// make connections
	
	CheckError(AUGraphConnectNodeInput(self.auGraph,
									   filePlayerNode,
									   0,
									   effectNode,
									   0),
			   "couldn't connect file player bus 0 output to effect bus 0 input");
	
	CheckError(AUGraphConnectNodeInput(self.auGraph,
									   effectNode,
									   0,
									   ioNode,
									   0),
			   "couldn't connect effect bus 0 output to remoteio bus 0 input");
	
	
	CheckError(AUGraphInitialize(self.auGraph),
			   "Couldn't initialize AUGraph");
    
	// configure file player
//	CFURLRef audioFileURL = CFBridgingRetain(
//											 [[NSBundle mainBundle] URLForResource:@"Bossa Lounger Long"
//																	 withExtension:@"caf"]);
    
	CFURLRef audioFileURL = CFBridgingRetain(assetURL);
    
	NSLog (@"found URL %@", audioFileURL);
	AudioFileID audioFile;
	CheckError(AudioFileOpenURL(audioFileURL,
								kAudioFileReadPermission,
								kAudioFileCAFType,
								&audioFile),
			   "Couldn't open audio file");
    
//	CheckError(AudioFileOpenURL(audioFileURL,
//								kAudioFileReadPermission,
//								0,
//								&audioFile),
//			   "Couldn't open audio file");
    
	
	AudioStreamBasicDescription fileStreamFormat;
	UInt32 propsize = sizeof (fileStreamFormat);
	CheckError(AudioFileGetProperty(audioFile,
									kAudioFilePropertyDataFormat,
									&propertySize,
									&fileStreamFormat),
			   "couldn't get input file's stream format");
	
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduledFileIDs,
									kAudioUnitScope_Global,
									0,
									&audioFile,
									sizeof(audioFile)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduledFileIDs] failed");
	
	UInt64 nPackets;
	propsize = sizeof(nPackets);
	CheckError(AudioFileGetProperty(audioFile,
									kAudioFilePropertyAudioDataPacketCount,
									&propsize,
									&nPackets),
			   "AudioFileGetProperty[kAudioFilePropertyAudioDataPacketCount] failed");
	
	// tell the file player AU to play the entire file
	ScheduledAudioFileRegion rgn;
	memset (&rgn.mTimeStamp, 0, sizeof(rgn.mTimeStamp));
	rgn.mTimeStamp.mFlags = kAudioTimeStampSampleTimeValid;
	rgn.mTimeStamp.mSampleTime = 0;
	rgn.mCompletionProc = NULL;
	rgn.mCompletionProcUserData = NULL;
	rgn.mAudioFile = audioFile;
	rgn.mLoopCount = 100;
	rgn.mStartFrame = 0;
	rgn.mFramesToPlay = nPackets * fileStreamFormat.mFramesPerPacket;
	
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduledFileRegion,
									kAudioUnitScope_Global,
									0,
									&rgn,
									sizeof(rgn)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduledFileRegion] failed");
	
	// prime the file player AU with default values
	UInt32 defaultVal = 0;
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduledFilePrime,
									kAudioUnitScope_Global,
									0,
									&defaultVal,
									sizeof(defaultVal)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduledFilePrime] failed");
	
	// tell the file player AU when to start playing (-1 sample time means next render cycle)
	AudioTimeStamp startTime;
	memset (&startTime, 0, sizeof(startTime));
	startTime.mFlags = kAudioTimeStampSampleTimeValid;
	startTime.mSampleTime = -1;
	CheckError(AudioUnitSetProperty(self.filePlayerUnit,
									kAudioUnitProperty_ScheduleStartTimeStamp,
									kAudioUnitScope_Global,
									0,
									&startTime,
									sizeof(startTime)),
			   "AudioUnitSetProperty[kAudioUnitProperty_ScheduleStartTimeStamp]");
    
	
	
	
	CheckError(AUGraphStart(self.auGraph),
			   "Couldn't start AUGraph");
	
	
	
	NSLog (@"bottom of setUpAUGraphWithAssetURL");
}

-(void) resetRate {
	// available rates are from 1/32 to 32. slider runs 0 to 10, where each whole
	// value is a power of 2:
	//		1/32, 1/16, 1/8, 1/4, 1/2, 1, 2, 4, 8, 16, 32
	// so:
	//		slider = 5, rateParam = 1.0
	//		slider = 0, rateParam = 1/32
	//		slider = 10, rateParam = 32
	Float32 rateParam =  powf(2.0, [self.timeSlider value] - 5.0);
	self.rateLabel.text = [NSString stringWithFormat: @"%0.3f", rateParam];
	CheckError(AudioUnitSetParameter(self.effectUnit,
									 kNewTimePitchParam_Rate,
									 kAudioUnitScope_Global,
									 0,
									 rateParam,
									 0),
			   "couldn't set pitch parameter");
	
}

-(void) resetPitch {
	Float32 pitchParam = [self.pitchSlider value];
	CheckError(AudioUnitSetParameter(self.effectUnit,
									 kNewTimePitchParam_Pitch,
									 kAudioUnitScope_Global,
									 0,
									 pitchParam,
									 0),
			   "couldn't set pitch parameter");
	
}

#pragma mark MPMediaPickerControllerDelegate

- (void)mediaPicker: (MPMediaPickerController *)mediaPicker didPickMediaItems:(MPMediaItemCollection *)mediaItemCollection
{
    NSLog (@"mediaPicker didPickMediaItems");

	[self dismissViewControllerAnimated:YES completion:nil];
	if ( [mediaItemCollection count] < 1 )
    {
		return;
	}
	self.song = [[mediaItemCollection items] objectAtIndex:0];
    
	songLabel.hidden = NO;
	artistLabel.hidden = NO;
	coverArtView.hidden = NO;
	songLabel.text = [song valueForProperty:MPMediaItemPropertyTitle];
	artistLabel.text = [song valueForProperty:MPMediaItemPropertyArtist];
	coverArtView.image = [[song valueForProperty:MPMediaItemPropertyArtwork]
						  imageWithSize: coverArtView.bounds.size];
    coverArtView.hidden = NO;
//    stopPlayingButton.enabled = YES;
    
    self.mediaExporter = [[DCMediaExporter alloc] initWithMediaItem:self.song exportURL:[self _exportURLForMediaItem:self.song] delegate:self];

	if([self.mediaExporter startExporting]) {
		// Make the UI reflect the fact that we're exporting.
		[[UIApplication sharedApplication] beginIgnoringInteractionEvents];
        //TODO
//		[self.spinner startAnimating];
	}
	else {
		// If something went wrong, tell the user to select a different song.
		self.alertView = [[UIAlertView alloc] initWithTitle:@"Oh no!" message:@"Sorry, we can't copy that track. Please select another." delegate:self cancelButtonTitle:@"D'oh!" otherButtonTitles:nil];
		[self.alertView show];
	}
    
    
    
//    [self playSong];
}

- (NSURL *)_exportURLForMediaItem:(MPMediaItem *)mediaItem {
	// Get the file path.
	NSString *documentsDirectoryPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
	NSString *exportFilePath = [documentsDirectoryPath stringByAppendingPathComponent:@"auto-old.caf"];
	
	// Make sure the file path we want to export to doesn't already exist.
	if([[NSFileManager defaultManager] fileExistsAtPath:exportFilePath]) {
		NSError *error = nil;
		if(![[NSFileManager defaultManager] removeItemAtPath:exportFilePath error:&error]) {
			NSLog(@"Failed to clear out export file, with error: %@", error);
		}
	}
	
	return [NSURL fileURLWithPath:exportFilePath];
}

- (void)mediaPickerDidCancel:(MPMediaPickerController *)mediaPicker
{
    NSLog (@"mediaPickerDidCancel");
	[self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark -
#pragma DCMediaExporterDelegate
- (void)exporterCompleted:(DCMediaExporter *)exporter {
    NSLog (@"exporterCompleted");
	// Create a file producer for the file.
//	self.audioProducer = [[DCFileProducer alloc] initWithMediaURL:exporter.exportURL];
	
	// Pass the file producer to our media player.
//	self.mediaPlayer.audioProducer = self.audioProducer;
	
	[[UIApplication sharedApplication] endIgnoringInteractionEvents];
//	[self.spinner stopAnimating];
//	[self.mediaPlayer play];
    
    
    [self playSongWithAssetURL:exporter.exportURL];
}


@end
