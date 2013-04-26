//
//  SNFViewController.h
//  TimeSliderDemo
//
//  Created by Chris Adamson on 10/14/12.
//  Copyright (c) 2012 Subsequently & Furthermore, Inc. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import "DCMediaExporter.h"

@interface SNFViewController : UIViewController <MPMediaPickerControllerDelegate, DCMediaExporterDelegate>


@property (nonatomic, retain) MPMediaItem *song;
@property (nonatomic, assign) IBOutlet UILabel *songLabel;
@property (nonatomic, assign) IBOutlet UILabel *artistLabel;
@property (nonatomic, assign) IBOutlet UIImageView *coverArtView;

- (IBAction)chooseSongButtonPressed:(id)sender;

@end
