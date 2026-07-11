//
//  AppDelegate.m
//  iTunes Volume Control
//
//  Created by Andrea Alberti on 25.12.12.
//  Copyright (c) 2012 Andrea Alberti. All rights reserved.
//

#import <Carbon/Carbon.h>
#import "AppDelegate.h"

#import "SystemVolume.h"

// Debug aid: set to 1 to force -hasControllableVolume to always report NO, so
// the "no output controls" handling can be exercised on hardware that actually
// supports software volume control (e.g. the built-in speakers). This simulates
// the behavior of digital outputs such as HDMI/DisplayPort displays that expose
// no controllable volume. MUST be 0 in shipping builds.
#define FAKE_NO_CONTROLLABLE_VOLUME 0

@implementation SystemApplication

@synthesize currentVolume = _currentVolume;
@synthesize icon = _icon;

-(AudioDeviceID) getDefaultOutputDevice
{
	AudioObjectPropertyAddress getDefaultOutputDevicePropertyAddress = {
		kAudioHardwarePropertyDefaultOutputDevice,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain
	};

	AudioDeviceID defaultOutputDeviceID;
	UInt32 volumedataSize = sizeof(defaultOutputDeviceID);
	OSStatus result = AudioObjectGetPropertyData(kAudioObjectSystemObject,
												 &getDefaultOutputDevicePropertyAddress,
												 0, NULL,
												 &volumedataSize, &defaultOutputDeviceID);

	if(kAudioHardwareNoError != result)
	{
		NSLog(@"Cannot find default output device!");
	}

	return defaultOutputDeviceID;
}

- (void)setCurrentVolume:(double)currentVolume
{
	AudioDeviceID defaultOutputDeviceID = [self getDefaultOutputDevice];

	AudioObjectPropertyAddress volumePropertyAddress = {
		kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
		kAudioDevicePropertyScopeOutput,
		kAudioObjectPropertyElementMain
	};

	AudioObjectPropertyAddress mutePropertyAddress = {
		kAudioDevicePropertyMute,
		kAudioDevicePropertyScopeOutput,
		kAudioObjectPropertyElementMain
	};

	Float32 volume = (Float32)(currentVolume / 100.);
	UInt32 dataSize;

	// Raising the volume above 0 should also clear any active mute, matching
	// the behavior of the native macOS volume keys. We intentionally do NOT set
	// the mute flag when the level reaches 0: a scalar of 0 already produces
	// silence, and muting here would conflate "user lowered the volume to 0%"
	// with an explicit device mute (handled separately via the mute key). On
	// hardware that keeps mute and scalar independent, forcing a mute at 0%
	// could otherwise leave the device stuck muted after the volume is raised
	// again.
	if (volume > 0) {
		// Clear the mute flag in case the device was previously muted, so that
		// raising the volume actually produces sound again.
		UInt32 mute = 0;
		dataSize = sizeof(mute);
		AudioObjectSetPropertyData(defaultOutputDeviceID,
								   &mutePropertyAddress,
								   0, NULL,
								   dataSize, &mute);
	}

	// Set the volume to the requested level (including 0).
	dataSize = sizeof(volume);
	OSStatus result = AudioObjectSetPropertyData(defaultOutputDeviceID,
												 &volumePropertyAddress,
												 0, NULL,
												 dataSize, &volume);
	if (result != noErr) {
		NSLog(@"Failed to set volume for device 0x%0x", defaultOutputDeviceID);
	}
}

- (bool) isMuted
{
	AudioDeviceID defaultOutputDeviceID = [self getDefaultOutputDevice];

	AudioObjectPropertyAddress volumePropertyAddress = {
		kAudioDevicePropertyMute,
		kAudioDevicePropertyScopeOutput,
		kAudioObjectPropertyElementMain
	};

	UInt32 muteVal;
	UInt32 muteValSize = sizeof(muteVal);
	OSStatus result = AudioObjectGetPropertyData(defaultOutputDeviceID,
										&volumePropertyAddress,
										0, NULL,
										&muteValSize, &muteVal);

	if (result != kAudioHardwareNoError) {
		NSLog(@"No volume reported for device 0x%0x", defaultOutputDeviceID);
	}

	return muteVal;
}

// Reports whether the current default output device exposes a software-
// controllable volume. Digital outputs such as HDMI/DisplayPort displays often
// do not implement a master volume element, in which case macOS itself cannot
// change their volume and neither can we. Callers use this to present an honest
// "no output controls" state instead of a misleading 0%.
- (bool)hasControllableVolume
{
#if FAKE_NO_CONTROLLABLE_VOLUME
	return NO;
#else
	AudioDeviceID defaultOutputDeviceID = [self getDefaultOutputDevice];

	if (defaultOutputDeviceID == kAudioObjectUnknown) {
		return NO;
	}

	AudioObjectPropertyAddress volumePropertyAddress = {
		kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
		kAudioDevicePropertyScopeOutput,
		kAudioObjectPropertyElementMain
	};

	return AudioObjectHasProperty(defaultOutputDeviceID, &volumePropertyAddress) ? YES : NO;
#endif
}

- (double) currentVolume
{
	AudioDeviceID defaultOutputDeviceID = [self getDefaultOutputDevice];

	// First, check mute state
	AudioObjectPropertyAddress mutePropertyAddress = {
		kAudioDevicePropertyMute,
		kAudioDevicePropertyScopeOutput,
		kAudioObjectPropertyElementMain
	};

	UInt32 muteVal = 0;
	UInt32 muteValSize = sizeof(muteVal);
	OSStatus muteResult = AudioObjectGetPropertyData(defaultOutputDeviceID,
													 &mutePropertyAddress,
													 0, NULL,
													 &muteValSize, &muteVal);

	if (muteResult == kAudioHardwareNoError && muteVal == 1) {
		return 0.0; // Treat mute as 0%
	}

	// Otherwise, get the real volume
	AudioObjectPropertyAddress volumePropertyAddress = {
		kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
		kAudioDevicePropertyScopeOutput,
		kAudioObjectPropertyElementMain
	};

	Float32 volume = 0;
	UInt32 volumedataSize = sizeof(volume);
	OSStatus result = AudioObjectGetPropertyData(defaultOutputDeviceID,
												 &volumePropertyAddress,
												 0, NULL,
												 &volumedataSize, &volume);

	if (result != kAudioHardwareNoError) {
		NSLog(@"No volume reported for device 0x%0x", defaultOutputDeviceID);
	}

	return ((double)volume) * 100.0;
}

- (NSString *)getDefaultOutputDeviceName
{
    AudioDeviceID defaultOutputDeviceID = [self getDefaultOutputDevice];
    
    if (defaultOutputDeviceID == kAudioObjectUnknown) {
        return @"Unknown Device";
    }
    
    CFStringRef deviceName = NULL;
    UInt32 dataSize = sizeof(deviceName);
    
    AudioObjectPropertyAddress propertyAddress = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    
    OSStatus result = AudioObjectGetPropertyData(defaultOutputDeviceID,
                                                 &propertyAddress,
                                                 0,
                                                 NULL,
                                                 &dataSize,
                                                 &deviceName);
    
    if (result != kAudioHardwareNoError || deviceName == NULL) {
        NSLog(@"Could not get device name for device 0x%0x", defaultOutputDeviceID);
        return @"Unknown Device";
    }
    
    NSString *name = [NSString stringWithString:(__bridge NSString *)deviceName];
    CFRelease(deviceName);
    return name;
}


-(void)dealloc
{
}

-(id)init{
	if (self = [super init])  {
		[self setOldVolume:[self currentVolume]];
        if (@available(macOS 16.0, *)) {
            [self setIcon:[NSImage imageNamed:@"FinderTahoe"]];
        } else {
            [self setIcon:[NSImage imageNamed:@"FinderSequoia"]];
        }
	}
	return self;
}

@end
