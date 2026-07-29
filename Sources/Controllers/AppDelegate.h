//
//  AppDelegate.h
//  iTunes Volume Control
//
//  Created by Andrea Alberti on 25.12.12.
//  Copyright (c) 2012 Andrea Alberti and contributors.
//  Modified in 2026 by Luca Leukert.
//  SPDX-License-Identifier: GPL-3.0-only
//

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CoreAnimation.h>

#import "iTunes.h"
// #import "Music.h"
#import "Spotify.h"
#import "Doppler.h"
#import "Swinsian.h"

@class IntroWindowController, StatusBarItem, PlayerApplication, SystemApplication;

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation> {
    CALayer *volumeImageLayer;
    CALayer *volumeBar[16];
    
    NSImage *imgVolOn,*imgVolOff;
    
    NSUserDefaults *preferences;
    
    CABasicAnimation *fadeOutAnimation;
    CABasicAnimation *fadeInAnimation;
    
    CFMachPortRef eventTap;
    CFRunLoopSourceRef runLoopSource;

    bool menuIsVisible;
    
    NSInteger oldVolumeSetting;
    
    NSInteger osxVersion;
    
    double increment;
    
    id currentPlayer;
    
    Class OSDManager;
    
@public
    PlayerApplication* iTunes;
    PlayerApplication* spotify;
    SystemApplication* systemAudio;
    PlayerApplication* doppler;
    PlayerApplication* swinsian;

    IntroWindowController *introWindowController;
}

@property (nonatomic, strong) NSStatusItem *statusBar;

@property (assign, nonatomic) NSInteger volumeInc;
@property (assign, nonatomic) bool AppleRemoteConnected;
@property (assign, nonatomic) bool StartAtLogin;
@property (assign, nonatomic) bool Tapping;
@property (assign, nonatomic) bool UseAppleCMDModifier;
@property (assign, nonatomic) bool LockSystemAndPlayerVolume;
@property (assign, nonatomic) bool AppleCMDModifierPressed;
@property (assign, nonatomic) bool loadIntroAtStart;

- (IBAction)toggleUseAppleCMDModifier:(id)sender;
- (IBAction)toggleLockSystemAndPlayerVolume:(id)sender;
- (IBAction)toggleStartAtLogin:(id)sender;
- (IBAction)toggleTapping:(id)sender;
- (IBAction)aboutPanel:(id)sender;
- (IBAction)copyDiagnostics:(id)sender;
- (void)updateVolumeIncrement:(NSInteger)value;
- (void)updateVolumeIncrementNumber:(NSNumber *)value;
- (void)applyVolumeLimitForPreference:(NSString *)preference;
//- (IBAction)showIntroWindow:(id)sender;
- (IBAction)terminate:(id)sender;
- (BOOL)tryCreateEventTap;

// - (void)appleRemoteButton: (AppleRemoteEventIdentifier)buttonIdentifier pressedDown: (BOOL) pressedDown clickCount: (unsigned int) count;
- (void)wasAuthorized;
- (void)handleAsynchronouslyTappedEventWithKeyCode:(int)keyCode
                                          keyState:(BOOL)keyState
                                       keyIsRepeat:(BOOL)keyIsRepeat
                                       keyModifier:(CGEventFlags)keyModifier;

@end

@interface PlayerApplication : NSObject {
    id musicPlayer;
    NSString *_bundleIdentifier;
    NSAppleScript *_playerStateScript;
}

- (BOOL) isRunning;
- (NSInteger) playerState;

@property (assign, nonatomic) double currentVolume;
@property (assign, nonatomic) double oldVolume;
@property (assign, nonatomic) double doubleVolume;
@property (strong, nonatomic) NSImage* icon;
@property (copy, nonatomic, readonly) NSString* bundleIdentifier;

- (double)protectedVolumeForRequestedVolume:(double)requestedVolume;
- (double)maximumAllowedVolume;
- (double)restoreVolumeAfterMute:(double)requestedVolume;

@end
