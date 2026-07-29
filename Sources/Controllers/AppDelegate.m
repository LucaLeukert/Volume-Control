//
//
//  AppDelegate.m
//  iTunes Volume Control
//
//  Created by Andrea Alberti on 25.12.12.
//  Copyright (c) 2012 Andrea Alberti and contributors.
//  Modified in 2026 by Luca Leukert.
//  SPDX-License-Identifier: GPL-3.0-only
//

#import "AppDelegate.h"
#import "SystemVolume.h"
#import "Volume_Control-Swift.h"

#import <IOKit/hidsystem/ev_keymap.h>
#import <ServiceManagement/ServiceManagement.h>
#import <stdatomic.h>
#import <CoreServices/CoreServices.h>
#import <sys/sysctl.h>

#import "OSD.h"

static NSImage *VCApplicationIcon(NSString *bundleIdentifier)
{
    NSURL *applicationURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleIdentifier];
    if (applicationURL != nil) {
        return [[NSWorkspace sharedWorkspace] iconForFile:applicationURL.path];
    }
    return [NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:nil];
}

//This will handle signals for us, specifically SIGTERM.
void handleSIGTERM(int sig) {
	[NSApp terminate:nil];
}

#define USE_APPLE_CMD_MODIFIER_MENU_ID 3
#define LOCK_SYSTEM_AND_PLAYER_VOLUME_ID 9
#define START_AT_LOGIN_ID 4
#define TAPPING_ID 1

#pragma mark - Tapping key stroke events

// Marks an event as one the tap should let pass through untouched rather than
// intercept and process. We stamp it onto the system-defined volume keys we
// re-post ourselves (see -repostSystemDefinedKey:keyDown:) when the active
// output device exposes no controllable volume and we want macOS to handle the
// key natively. The tag currently rides in the event's data2 field; real
// hardware volume-key events carry data2 == -1, so this distinct value cannot
// collide with them.
static const NSInteger kPassThroughEventTag = 0x0056434B; // 'VCK'

// Keycode of a volume/mute key we have currently handed off to macOS (or -1 if
// none). While a key is handed off, the tap lets that key's auto-repeat events
// and its release flow straight through so macOS ramps natively; without this we
// would consume every repeat and only single presses would work. Written by the
// main thread on key-down and cleared by either thread on key-up, so it is
// accessed atomically across the tap and main threads.
static _Atomic(int) gPassThroughKeyCode = -1;

CGEventRef event_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    // Keep track of how many consecutive timeouts we’ve seen.
    // macOS fires kCGEventTapDisabledByTimeout when it thinks the tap is “hung”
    // (e.g. if the app is suspended by TCC while showing an Apple Events dialog).
    // We auto-resume a few times, then give up and alert the user if it persists.
    static int timeout_count = 0;
    
    if (type == kCGEventTapDisabledByTimeout) {
        if (timeout_count < 5) {
            // This handles “false positives” that occur when macOS temporarily
            // suspends the app for Apple Events permission prompts.
            timeout_count++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // Try to resume tapping automatically.
                AppDelegate *app = (__bridge AppDelegate *)refcon;
                if ([app Tapping]) { // guard if user disabled it manually
                    [app setTapping:YES]; // attempt to re-enable tap
                }
            });
        } else {
            // After 5 consecutive timeouts, assume it’s a real problem
            // (e.g. the tap logic is genuinely unresponsive).
            // Disable tapping and inform the user instead of looping forever.
            timeout_count = 0; // reset counter for next time
            dispatch_async(dispatch_get_main_queue(), ^{
                AppDelegate *app = (__bridge AppDelegate *)refcon;
                [app setTapping:NO];
                
                [[SwiftUIModalController shared]
                    showMessage:@"Tapping Disabled"
                    details:@"Volume Control lost access to volume-key events. Tapping was paused and can be re-enabled from the menu."];
            });
        }
        return event; // always return quickly so system input isn’t blocked
    }

    // Pass through events we don't care about
    if (type != NX_SYSDEFINED) return event;

    NSEvent *sysEvent = [NSEvent eventWithCGEvent:event];
    if ([sysEvent subtype] != NX_SUBTYPE_AUX_CONTROL_BUTTONS) return event;

    // Let our own re-posted volume keys flow straight through to macOS, so it can
    // perform its native handling. Without this guard we would re-catch and
    // re-process them, defeating the passthrough (and looping).
    if ([sysEvent data2] == kPassThroughEventTag) return event;

    // Extract key info
    int keyFlags   = ([sysEvent data1] & 0x0000FFFF);
    int keyCode    = (([sysEvent data1] & 0xFFFF0000) >> 16);
    int keyState   = (((keyFlags & 0xFF00) >> 8)) == 0xA;
    bool keyIsRepeat = (keyFlags & 0x1);
    CGEventFlags keyModifier = [sysEvent modifierFlags] | 0xFFFF;

    // If this key is currently handed off to macOS (because the output device
    // has no controllable volume), let its auto-repeat events and its release
    // flow straight through until the key is released, so macOS ramps natively.
    if (atomic_load(&gPassThroughKeyCode) == keyCode) {
        if (keyState == 0) { // key up ends the hand-off
            atomic_store(&gPassThroughKeyCode, -1);
        }
        return event;
    }

    // Decide here if it's a volume/mute event
    BOOL isMediaKey = (keyCode == NX_KEYTYPE_MUTE ||
                       keyCode == NX_KEYTYPE_SOUND_UP ||
                       keyCode == NX_KEYTYPE_SOUND_DOWN);

    if(isMediaKey /*&& keyModifier==1114111*/) {
        // Hand off all actual logic to main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *app = (__bridge AppDelegate *)refcon;
            [app handleAsynchronouslyTappedEventWithKeyCode:keyCode
                                                   keyState:keyState
                                                keyIsRepeat:keyIsRepeat
                                                keyModifier:keyModifier];
        });
        
        return NULL;
    } else {
        // Always return immediately to keep the system input flowing
        return event;
    }
}


#pragma mark - Class extension for status menu

@interface AppDelegate ()
{
    //StatusItemView* _statusBarItemView;
    NSTimer* accessibilityCheckTimer;
    NSTimer* authorizationPollTimer;
    NSTimer* volumeRampTimer;
    NSTimer* timerImgSpeaker;
    NSTimer* checkPlayerTimer;
    NSTimer* updateSystemVolumeTimer;
    NSTimer* relevantVolumeTimer;
    NSTimeInterval waitOverlayPanel;
    bool fadeInAnimationReady;
    
    // Event tap state
    int _previousKeyCode;
    BOOL _muteDown;
}

// Forward declare private methods
- (id)runningPlayer;
- (void)completeInitialization;
- (void)setVolumeUp:(bool)increase;
- (void)repostSystemDefinedKey:(int)keyCode keyDown:(BOOL)keyDown;
- (void) setItunesVolume:(NSInteger)volume;
- (void) setSpotifyVolume:(NSInteger)volume;
- (void) setDopplerVolume:(NSInteger)volume;
- (void) setSwinsianVolume:(NSInteger)volume;
- (void) setSystemVolume:(NSInteger)volume;
- (void)stopVolumeRampTimer;
- (void)updatePercentages;
- (void)refreshRelevantMenuBarVolume:(NSTimer *)timer;
- (bool)createEventTap;
- (void)handleEventTapDisabledByUser;

@end

#pragma mark - Extention music applications

// ScriptingBridge players expose an integer 0...100 volume. Some players
// report a just-written value one point lower because their internal volume is
// normalized through a floating-point scale. Treat that as the same setting;
// larger differences still represent a genuine external change.
static const double playerVolumeReadbackTolerance = 1.01;
static const double maximumProtectedVolumeIncrease = 6.0;

@interface PlayerApplication () {
    dispatch_queue_t _writeQueue;  // serial queue for ScriptingBridge writes
    BOOL             _writeInFlight; // YES while a write is executing on _writeQueue
    double           _pendingWrite;  // latest desired volume while write is in flight; -1 = none
    BOOL             _rampActive;    // YES while a key-hold ramp is in progress
}
- (void)scheduleVolumeWrite:(double)volume;
- (void)scheduleVolumeVerification;
@property (nonatomic, assign) BOOL rampActive;
@end

@implementation PlayerApplication

@synthesize currentVolume = _currentVolume;
@synthesize icon = _icon;
@synthesize rampActive = _rampActive;

- (NSString *)volumePreferenceBase
{
    if ([_bundleIdentifier isEqualToString:@"com.apple.Music"]) return @"iTunesControl";
    if ([_bundleIdentifier isEqualToString:@"com.spotify.client"]) return @"spotifyControl";
    if ([_bundleIdentifier isEqualToString:@"co.brushedtype.doppler-macos"]) return @"dopplerControl";
    if ([_bundleIdentifier isEqualToString:@"com.swinsian.Swinsian"]) return @"swinsianControl";
    return nil;
}

- (double)minimumAllowedVolume
{
    NSString *base = [self volumePreferenceBase];
    if (base == nil) return 0;
    return fmax(0, fmin(100, [[NSUserDefaults standardUserDefaults]
                              doubleForKey:[base stringByAppendingString:@".minimumVolume"]]));
}

- (double)maximumAllowedVolume
{
    NSString *base = [self volumePreferenceBase];
    if (base == nil) return 100;
    double minimum = [self minimumAllowedVolume];
    double maximum = [[NSUserDefaults standardUserDefaults]
                      doubleForKey:[base stringByAppendingString:@".maximumVolume"]];
    return fmax(minimum, fmin(100, maximum));
}

- (double)protectedVolumeForRequestedVolume:(double)requestedVolume
{
    if (requestedVolume < 0) return requestedVolume;
    if (requestedVolume == 0) return 0; // Muting must always remain possible.

    double bounded = round(fmax([self minimumAllowedVolume],
                                fmin([self maximumAllowedVolume], requestedVolume)));
    double reference = [self doubleVolume];

    // A corrupt/stale target must never create one large upward write. Repeated
    // deliberate input can still raise the volume, at most six points at once.
    if (reference >= 0 && reference <= 100 &&
        bounded > reference + maximumProtectedVolumeIncrease) {
        bounded = round(reference + maximumProtectedVolumeIncrease);
    }
    return fmin([self maximumAllowedVolume], bounded);
}

- (double)restoreVolumeAfterMute:(double)requestedVolume
{
    // Restoring a value that was explicitly captured immediately before mute
    // is not an accidental increase. Apply the configured range, but do not
    // rate-limit the return to the remembered listening level.
    double restored = round(fmax([self minimumAllowedVolume],
                                 fmin([self maximumAllowedVolume], requestedVolume)));
    [self setDoubleVolume:restored];
    [self scheduleVolumeWrite:restored];
    return restored;
}

- (void) setCurrentVolume:(double)currentVolume
{
  /* We use setValue:forKey: (KVC) rather than calling setSoundVolume:
      directly because the generated headers declare soundVolume as
      NSInteger for Music/ Spotify/Doppler but as NSNumber * for
      Swinsian (whose sdef uses type="number").  The compiler would
      see conflicting method signatures and pick arbitrarily.  KVC
      bypasses that ambiguity by boxing the value as NSNumber
      regardless. */

    // Keep the cache, ScriptingBridge write, HUD, and subsequent key step on
    // the same integer value. Caching a fractional value that cannot be written
    // makes every verification read appear to move the volume backwards.
    double canonicalVolume = [self protectedVolumeForRequestedVolume:currentVolume];
    [self setDoubleVolume:canonicalVolume];

    // Negative sentinel values (e.g. -100 used during init) must not be
    // forwarded to the player — they are internal "unset" markers only.
    if (canonicalVolume >= 0) {
        [self scheduleVolumeWrite:canonicalVolume];
    }
}

// Sends `volume` to the ScriptingBridge player on a background serial queue.
// If a write is already in flight the new value is remembered and dispatched
// as soon as the in-flight write completes, so intermediate values are skipped
// rather than queued — keeping the player in sync with the latest position.
- (void) scheduleVolumeWrite:(double)volume
{
    if (_writeInFlight) {
        // A write is already on its way; just record the latest target.
        _pendingWrite = volume;
        return;
    }

    _writeInFlight = YES;
    _pendingWrite  = -1.0;

    dispatch_async(_writeQueue, ^{
        [self->musicPlayer setValue:@((NSInteger)round(volume)) forKey:@"soundVolume"];

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_writeInFlight = NO;
            if (self->_pendingWrite >= 0) {
                double v = self->_pendingWrite;
                self->_pendingWrite = -1.0;
                // Never let write coalescing turn multiple protected key steps
                // into one large player-side increase. Preserve the final target,
                // but send each upward segment separately.
                if (v > volume + maximumProtectedVolumeIncrease) {
                    double finalTarget = v;
                    [self scheduleVolumeWrite:volume + maximumProtectedVolumeIncrease];
                    self->_pendingWrite = finalTarget;
                } else {
                    [self scheduleVolumeWrite:v];
                }
            } else {
#ifdef DEBUG
                // All writes have been flushed to the player.
                // Skip the verification read while a ramp is active: Apple Music on
                // Tahoe acknowledges Apple Events before applying them, so an
                // immediate SB read after write completion returns a stale value and
                // produces spurious ⚠️ warnings.  The ramp-end path calls
                // scheduleVolumeVerification with a delay instead.
                if (!self->_rampActive) {
                    double sbVol     = [[self->musicPlayer valueForKey:@"soundVolume"] doubleValue];
                    double cachedVol = [self doubleVolume];
                    NSLog(@"[VC] flush internal=%.2f  player SB=%.2f  delta=%.2f%@",
                          cachedVol, sbVol, sbVol - cachedVol,
                          (fabs(sbVol - cachedVol) > playerVolumeReadbackTolerance) ? @"  ⚠️ MISMATCH" : @"");
                }
#endif
            }
        });
    });
}

// Called by AppDelegate when the key-hold ramp ends.  Waits 500 ms to give
// Apple Music time to apply the last write, then reads the actual volume and
// compares it with the internal cache.  The delay is intentional: on Tahoe,
// Apple Music acknowledges Apple Events before applying them, so an immediate
// read after write completion returns a stale value.
- (void)scheduleVolumeVerification
{
#ifdef DEBUG
    double expected = [self doubleVolume];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Skip if another ramp or write cycle started in the meantime.
        if (self->_writeInFlight || self->_pendingWrite >= 0) return;
        double sbVol = [[self->musicPlayer valueForKey:@"soundVolume"] doubleValue];
        NSLog(@"[VC] verify  internal=%.2f  player SB=%.2f  delta=%.2f%@",
              expected, sbVol, sbVol - expected,
              (fabs(sbVol - expected) > playerVolumeReadbackTolerance) ? @"  ⚠️ MISMATCH" : @"");
    });
#endif
}

- (double) currentVolume
{
  /* We use valueForKey: rather than calling soundVolume directly
  because ScriptingBridge returns a scalar for integer-typed
  properties but an NSNumber * for Swinsian's number-typed
  soundVolume.  Reading a pointer as a scalar produces garbage
  (e.g. the memory address).  valueForKey: always returns id, so
  doubleValue gives the correct numeric value uniformly. */

  double vol = [[musicPlayer valueForKey:@"soundVolume"] doubleValue];

  if (fabs(vol-[self doubleVolume]) <= playerVolumeReadbackTolerance) {
    vol = [self doubleVolume];
  } else if (!_writeInFlight && _pendingWrite < 0 && !_rampActive) {
    // Establish a trustworthy baseline for upward-jump protection.
    [self setDoubleVolume:round(fmin(100, fmax(0, vol)))];
  }

	return vol;
}

- (void) nextTrack
{
	return [musicPlayer nextTrack];
}

- (void) previousTrack
{
	return [musicPlayer previousTrack];
}

- (void) playPause
{
	return [musicPlayer playPause];
}

- (BOOL) isRunning
{
	return [musicPlayer isRunning];
}

- (NSInteger) playerState
{
    /* enum behaves like an integer and the default C enum size (4
       bytes) doesn't match NSInteger's size on 64-bit (8 bytes). The
       valueForKey: sidesteps this entirely by never calling
       playerState as a typed method at the call site.  valueForKey
       retrieves an id and then we can query the integer value
       safely. */
    return [[musicPlayer valueForKey:@"playerState"] integerValue];
}

-(id)initWithBundleIdentifier:(NSString*) bundleIdentifier andIcon:(NSImage*)icon {
	if (self = [super init])  {
        _bundleIdentifier = [bundleIdentifier copy];
        _playerStateScript = nil;
        _writeQueue    = dispatch_queue_create("de.lucaleukert.VolumeControl.sbWrite", DISPATCH_QUEUE_SERIAL);
        _writeInFlight = NO;
        _pendingWrite  = -1.0;
		[self setCurrentVolume: -100];
		[self setOldVolume: -1];
		musicPlayer = [SBApplication applicationWithBundleIdentifier:bundleIdentifier];
        [self setIcon:icon];
	}
	return self;
}

@end

#pragma mark - Implementation AppDelegate

@implementation AppDelegate

// @synthesize AppleRemoteConnected=_AppleRemoteConnected;
@synthesize StartAtLogin=_StartAtLogin;
@synthesize Tapping=_Tapping;
@synthesize UseAppleCMDModifier=_UseAppleCMDModifier;
@synthesize LockSystemAndPlayerVolume=_LockSystemAndPlayerVolume;
@synthesize AppleCMDModifierPressed=_AppleCMDModifierPressed;
@synthesize loadIntroAtStart = _loadIntroAtStart;
@synthesize statusBar = _statusBar;

static NSTimeInterval volumeRampTimeInterval=0.01f;
static NSTimeInterval checkPlayerTimeout=0.3f;
//static NSTimeInterval volumeLockSyncInterval=1.0f;
static NSTimeInterval updateSystemVolumeInterval=0.1f;

- (NSString *)helperBundleID {
    return [[[NSBundle mainBundle] bundleIdentifier] stringByAppendingString:@"Helper"];
}

- (IBAction)terminate:(id)sender
{
    if (eventTap && CFMachPortIsValid(eventTap)) {
        if (CFMachPortIsValid(eventTap)) {
            CFMachPortInvalidate(eventTap);
        }
        if (runLoopSource) {
            CFRunLoopSourceInvalidate(runLoopSource);
            CFRelease(runLoopSource);
            runLoopSource = nil;
        }
        CFRelease(eventTap);
        eventTap = nil;
    }
    
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    
    systemAudio = nil;
    iTunes = nil;
    spotify = nil;
    doppler = nil;
    swinsian = nil;
    
    _statusBar = nil;
    
    introWindowController = nil;
    
    [volumeRampTimer invalidate];
    volumeRampTimer = nil;
    [relevantVolumeTimer invalidate];
    relevantVolumeTimer = nil;
    
    [checkPlayerTimer invalidate];
    checkPlayerTimer = nil;
    
    [timerImgSpeaker invalidate];
    timerImgSpeaker = nil;
    
    [updateSystemVolumeTimer invalidate];
    updateSystemVolumeTimer = nil;
    [accessibilityCheckTimer invalidate];
    accessibilityCheckTimer = nil;
    [authorizationPollTimer invalidate];
    authorizationPollTimer = nil;
    
    preferences = nil;
    
    // IMPORTANT: Use [NSApp terminate:nil] for a clean exit.
    // This ensures AppKit tears down the NSStatusItem properly
    // and preserves the status bar icon position between launches.
    // Simply returning or calling exit() would skip this cleanup
    // and cause the icon to reset to the default position.
    [NSApp terminate:nil];
}

- (void)updateStartAtLoginMenuItem
{
}

- (IBAction)toggleStartAtLogin:(id)sender {
    BOOL currentlyEnabled = [self StartAtLogin];
    
    if (currentlyEnabled) {
        // User clicked to disable
        [self setStartAtLogin:NO savePreferences:YES];
    } else {
        // User clicked to enable
        [self setStartAtLogin:YES savePreferences:YES];
        
        if (@available(macOS 13.0, *)) {
            SMAppService *service = [SMAppService loginItemServiceWithIdentifier:[self helperBundleID]];
            if (service.status == SMAppServiceStatusRequiresApproval) {
                // TODO: prompt user to open System Settings
                NSLog(@"Login item requires approval in System Settings → Login Items");
            }
        }
    }
    [self updateStartAtLoginMenuItem];
}

- (void)setStartAtLogin:(BOOL)enabled savePreferences:(BOOL)savePreferences
{
    NSString *helperBundleID = [self helperBundleID];
    
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService loginItemServiceWithIdentifier:helperBundleID];
        NSError *error = nil;
        
        if (enabled) {
            if (service.status != SMAppServiceStatusEnabled) {
                if (![service registerAndReturnError:&error]) {
                    NSLog(@"[Volume Control] Error registering login item: %@", error.localizedDescription);
                }
            }
        } else {
            if (service.status != SMAppServiceStatusNotRegistered) {
                if (![service unregisterAndReturnError:&error]) {
                    NSLog(@"[Volume Control] Error unregistering login item: %@", error.localizedDescription);
                }
            }
        }
    } else {
        // Legacy fallback (macOS 12 and older)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!SMLoginItemSetEnabled((__bridge CFStringRef)helperBundleID, enabled)) {
            NSLog(@"[Volume Control] SMLoginItemSetEnabled failed.");
        }
#pragma clang diagnostic pop
    }
    
    if (savePreferences) {
        [preferences setBool:enabled forKey:@"StartAtLoginPreference"];
    }
    
    [self updateStartAtLoginMenuItem];
}

- (bool)StartAtLogin
{
    // Enabled → the login item is registered and will launch at login.
    // NotRegistered → no login item exists.
    // RequiresApproval → your app tried to register the login item, but the user hasn’t granted approval yet in System Settings
    //
    // sfltool dumpbtm → dump the entire macOS database of login authorizations for inspection from the command line.
    // sfltool resetbtm → reset the entire macOS database of login authorizations. Be careful: the reset applies to all apps, not only this one
    
    NSString *helperBundleID = [self helperBundleID];
    
    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService loginItemServiceWithIdentifier:helperBundleID];
        
        // In case of RequiresApproval, it means the user requested to start the app at login, but the request has not been approved yet.
        // In this case, "Start at login" should be assumed to be checked because it would confuse the user to have click on the toggle
        // and see no changes.
        return (service.status == SMAppServiceStatusEnabled ||
                service.status == SMAppServiceStatusRequiresApproval);
    } else {
        return [preferences boolForKey:@"StartAtLoginPreference"];
    }
}

- (void)wasAuthorized
{
    [authorizationPollTimer invalidate];
    authorizationPollTimer = nil;
    [[SwiftUIAccessibilityController shared] close];
    [self completeInitialization];
}

- (void)pollAccessibilityAuthorization:(NSTimer *)timer
{
    if ([self tryCreateEventTap]) {
        [self wasAuthorized];
    }
}

- (void)stopVolumeRampTimer
{
    [volumeRampTimer invalidate];
    volumeRampTimer=nil;

    checkPlayerTimer = [NSTimer timerWithTimeInterval:checkPlayerTimeout target:self selector:@selector(resetCurrentPlayer:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:checkPlayerTimer forMode:NSRunLoopCommonModes];

#ifdef DEBUG
    if ([currentPlayer isKindOfClass:[PlayerApplication class]]) {
        PlayerApplication *p = (PlayerApplication *)currentPlayer;
        p.rampActive = NO;
        [p scheduleVolumeVerification];
    }
#endif
}

- (void)rampVolumeUp:(NSTimer*)theTimer
{
    [self setVolumeUp:true];
}

- (void)rampVolumeDown:(NSTimer*)theTimer
{
    [self setVolumeUp:false];
}

- (void)checkAccessibilityTrust:(NSTimer *)timer {
    if (eventTap && ![self isTappingTrusted]) {
        // NSLog(@"Accessibility permission revoked during runtime. Cleaning up tap.");
        [self handleEventTapDisabledByUser];
    }
}

- (BOOL)isTappingTrusted {
    // Key must be a CFStringRef (no need to retain/release since it's a constant)
    const void *keys[]   = { kAXTrustedCheckOptionPrompt };
    // Value must be a CFBooleanRef
    const void *values[] = { kCFBooleanFalse };
    
    CFDictionaryRef options = CFDictionaryCreate(
                                                 kCFAllocatorDefault,   // allocator
                                                 keys,                  // keys
                                                 values,                // values
                                                 1,                     // number of keys/values
                                                 &kCFTypeDictionaryKeyCallBacks,    // standard key callbacks
                                                 &kCFTypeDictionaryValueCallBacks   // standard value callbacks
                                                 );
    
    BOOL trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);
    
    return trusted;
}

- (BOOL)tryCreateEventTap {
    BOOL trusted = [self isTappingTrusted];
    
    if (trusted) {
        if ([self createEventTap]) {
            return YES;
        }
    }
    return NO;
}

- (bool)createEventTap
{
    if (eventTap != nil && CFMachPortIsValid(eventTap)) {
        CFMachPortInvalidate(eventTap);
        CFRunLoopSourceInvalidate(runLoopSource);
        CFRelease(eventTap);
        CFRelease(runLoopSource);
        eventTap = nil;
        runLoopSource = nil;
    }
    
    CGEventMask eventMask = CGEventMaskBit(NX_SYSDEFINED);
    eventTap = CGEventTapCreate(kCGSessionEventTap,
                                kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault,
                                eventMask,
                                event_tap_callback,
                                (__bridge void *)self);
    
    if (eventTap != nil) {
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        
        // Start safety timer to monitor trust state
        accessibilityCheckTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                   target:self
                                                                 selector:@selector(checkAccessibilityTrust:)
                                                                 userInfo:nil
                                                                  repeats:YES];
        
        return true;
    } else {
        return false;
    }
}

- (void)handleEventTapDisabledByUser {
    if (eventTap && CFMachPortIsValid(eventTap)) {
        if (CFMachPortIsValid(eventTap)) {
            CFMachPortInvalidate(eventTap);
        }
        if (runLoopSource) {
            CFRunLoopSourceInvalidate(runLoopSource);
            CFRelease(runLoopSource);
            runLoopSource = nil;
        }
        CFRelease(eventTap);
        eventTap = nil;
    }
    
    if (accessibilityCheckTimer) {
        [accessibilityCheckTimer invalidate];
        accessibilityCheckTimer = nil;
    }
    
    // Update toggle state to reflect reality
    [self setTapping:NO];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SwiftUIAccessibilityController shared] show];
    });
}

- (void)handleAsynchronouslyTappedEventWithKeyCode:(int)keyCode
                                          keyState:(BOOL)keyState
                                       keyIsRepeat:(BOOL)keyIsRepeat
                                       keyModifier:(CGEventFlags)keyModifier
{
    [self setAppleCMDModifierPressed:(keyModifier & NX_COMMANDMASK) == NX_COMMANDMASK];

    // If the resolved target is the system output and that device exposes no
    // controllable volume (e.g. many HDMI/DisplayPort displays), don't handle
    // the key ourselves and don't show the HUD. Re-post it so macOS performs
    // its own native handling instead.
    if (keyCode == NX_KEYTYPE_MUTE ||
        keyCode == NX_KEYTYPE_SOUND_UP ||
        keyCode == NX_KEYTYPE_SOUND_DOWN)
    {
        if ([self runningPlayer] == systemAudio && ![systemAudio hasControllableVolume])
        {
            if (keyState == 1)
            {
                // Hand this key off to macOS: re-post the initial press (so a
                // single tap still registers), then flag it so the tap lets the
                // auto-repeat events and the release pass straight through until
                // the key is released, letting macOS ramp natively.
                atomic_store(&gPassThroughKeyCode, keyCode);
                [self repostSystemDefinedKey:keyCode keyDown:YES];
            }
            else
            {
                // Released before the tap saw the flag (fast tap) — clear it and
                // re-post the release so macOS sees a balanced key event.
                atomic_store(&gPassThroughKeyCode, -1);
                [self repostSystemDefinedKey:keyCode keyDown:NO];
            }
            return;
        }
    }

    switch (keyCode) {
        case NX_KEYTYPE_MUTE:
            if (_previousKeyCode != keyCode && self->volumeRampTimer) {
                [self stopVolumeRampTimer];
            }
            _previousKeyCode = keyCode;
            
            if (keyState == 1) {
                _muteDown = true;
                [self MuteVol];
            } else {
                _muteDown = false;
            }
            break;
            
        case NX_KEYTYPE_SOUND_UP:
        case NX_KEYTYPE_SOUND_DOWN:
            if (!_muteDown) {
                if (_previousKeyCode != keyCode && self->volumeRampTimer) {
                    [self stopVolumeRampTimer];
                }
                _previousKeyCode = keyCode;
                
                if (keyState == 1) {
                    if (!self->volumeRampTimer) {
                        BOOL increase = (keyCode == NX_KEYTYPE_SOUND_UP);
                        [self adjustVolumeUp:increase ramp:keyIsRepeat];
                    }
                } else {
                    if (self->volumeRampTimer) {
                        [self stopVolumeRampTimer];
                    }
                }
            }
            break;
    }
}

// Re-post a single system-defined volume/mute key so macOS handles it natively.
// The event is tagged (data2 == kPassThroughEventTag) so our own tap ignores
// it instead of re-catching it. Down and up are posted separately, mirroring the
// original events we consumed.
- (void)repostSystemDefinedKey:(int)keyCode keyDown:(BOOL)keyDown
{
    int stateNibble = keyDown ? 0xa : 0xb; // 0xa = key down, 0xb = key up

    NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                     location:NSZeroPoint
                                modifierFlags:(keyDown ? 0xa00 : 0xb00)
                                    timestamp:0
                                 windowNumber:0
                                      context:nil
                                      subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                                        data1:((keyCode << 16) | (stateNibble << 8))
                                        data2:kPassThroughEventTag];

    CGEventPost(kCGHIDEventTap, ev.CGEvent);
}

-(void) sendMediaKey: (int)key {
    // create and send down key event
    NSEvent* key_event;
    
    key_event = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:CGPointZero modifierFlags:0xa00 timestamp:0 windowNumber:0 context:0 subtype:8 data1:((key << 16) | (0xa << 8)) data2:-1];
    CGEventPost(0, key_event.CGEvent);
    // NSLog(@"%d keycode (down) sent",key);
    
    // create and send up key event
    key_event = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:CGPointZero modifierFlags:0xb00 timestamp:0 windowNumber:0 context:0 subtype:8 data1:((key << 16) | (0xb << 8)) data2:-1];
    CGEventPost(0, key_event.CGEvent);
    // NSLog(@"%d keycode (up) sent",key);
}

/*
- (void)PlayPauseMusic
{
    [self sendMediaKey:NX_KEYTYPE_PLAY];
}

- (void)NextTrackMusic
{
    [self sendMediaKey:NX_KEYTYPE_NEXT];
}

- (void)PreviousTrackMusic
{
    [self sendMediaKey:NX_KEYTYPE_PREVIOUS];
}
 */

- (void)MuteVol
{
	id runningPlayerPtr = [self runningPlayer];

	if (runningPlayerPtr != nil)
	{
		if([runningPlayerPtr oldVolume]<0)
		{
			[runningPlayerPtr setOldVolume:[runningPlayerPtr currentVolume]];
			[runningPlayerPtr setCurrentVolume:0];

			if (_LockSystemAndPlayerVolume && runningPlayerPtr != systemAudio) {
				[systemAudio setOldVolume:[systemAudio currentVolume]];
				[systemAudio setCurrentVolume:0];
			}

            if (@available(macOS 16.0, *)) {
                [[TahoeVolumeHUD sharedManager] showHUDWithVolume:0 usingMusicPlayer:runningPlayerPtr andLabel:[systemAudio getDefaultOutputDeviceName]];
            } else {
                id osdMgr = [self->OSDManager sharedManager];
                if (osdMgr) {
                    [osdMgr showImage:OSDGraphicSpeakerMute onDisplayID:CGSMainDisplayID() priority:OSDPriorityDefault msecUntilFade:1000 filledChiclets:0 totalChiclets:(unsigned int)100 locked:NO];
                }
            }
		}
		else
		{
            double restoredVolume = [runningPlayerPtr oldVolume];
			if ([runningPlayerPtr isKindOfClass:[PlayerApplication class]]) {
                restoredVolume = [(PlayerApplication *)runningPlayerPtr
                                  restoreVolumeAfterMute:restoredVolume];
            } else {
                [runningPlayerPtr setCurrentVolume:restoredVolume];
			}

			if (_LockSystemAndPlayerVolume && runningPlayerPtr != systemAudio) {
				[systemAudio setCurrentVolume:restoredVolume];
			}
            
            if (@available(macOS 16.0, *)) {
                [[TahoeVolumeHUD sharedManager] showHUDWithVolume:restoredVolume usingMusicPlayer:runningPlayerPtr andLabel:[systemAudio getDefaultOutputDeviceName]];
            } else {
                id osdMgr = [self->OSDManager sharedManager];
                if (osdMgr) {
                    [osdMgr showImage:OSDGraphicSpeaker onDisplayID:CGSMainDisplayID() priority:OSDPriorityDefault msecUntilFade:1000 filledChiclets:(unsigned int)restoredVolume totalChiclets:(unsigned int)100 locked:NO];
                }
            }
            
			[runningPlayerPtr setOldVolume:-1];
		}

		if (runningPlayerPtr == iTunes)
			[self setItunesVolume:[runningPlayerPtr currentVolume]];
		else if (runningPlayerPtr == spotify)
			[self setSpotifyVolume:[runningPlayerPtr currentVolume]];
		else if (runningPlayerPtr == doppler)
			[self setDopplerVolume:[runningPlayerPtr currentVolume]];
		else if (runningPlayerPtr == swinsian)
			[self setSwinsianVolume:[runningPlayerPtr currentVolume]];

		// Update system UI if system volume is affected or when locked
		if (_LockSystemAndPlayerVolume || runningPlayerPtr == systemAudio) {
			[self setSystemVolume:[systemAudio currentVolume]];
		}

	}
}

- (void)adjustVolumeUp:(BOOL)increase ramp:(BOOL)ramp {
    if (ramp) {
        [checkPlayerTimer invalidate];
        checkPlayerTimer = nil;

        SEL selector = increase ? @selector(rampVolumeUp:) : @selector(rampVolumeDown:);
        volumeRampTimer = [NSTimer timerWithTimeInterval:volumeRampTimeInterval * (NSTimeInterval)increment
                                                  target:self
                                                selector:selector
                                                userInfo:nil
                                                 repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:volumeRampTimer forMode:NSRunLoopCommonModes];

        if (timerImgSpeaker) {
            [timerImgSpeaker invalidate];
            timerImgSpeaker = nil;
        }

#ifdef DEBUG
        if ([currentPlayer isKindOfClass:[PlayerApplication class]]) {
            ((PlayerApplication *)currentPlayer).rampActive = YES;
        }
#endif
    } else {
        [self setVolumeUp:increase];
    }
}

- (id)init
{
	self = [super init];
	if(self)
	{
		self->eventTap = nil;
		menuIsVisible=false;
		currentPlayer=nil;

		updateSystemVolumeTimer=nil;
		volumeRampTimer=nil;
		timerImgSpeaker=nil;
		checkPlayerTimer=nil;
        
        // Explicitly initialize event tap state
        _previousKeyCode = 0;
        _muteDown = NO;
	}
	return self;
}

-(void)completeInitialization
{
	// [self _loadBezelServices]; // El Capitan and probably older systems
    if (@available(macOS 16.0, *)) {
        // Running on Tahoe (2026) or newer
    } else {
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/OSD.framework"] load];
        self->OSDManager = NSClassFromString(@"OSDManager");
    }

    iTunes = [[PlayerApplication alloc] initWithBundleIdentifier:@"com.apple.Music"
                                                        andIcon:VCApplicationIcon(@"com.apple.Music")];
	
    spotify = [[PlayerApplication alloc] initWithBundleIdentifier:@"com.spotify.client"
                                                         andIcon:VCApplicationIcon(@"com.spotify.client")];

    doppler = [[PlayerApplication alloc] initWithBundleIdentifier:@"co.brushedtype.doppler-macos"
                                                         andIcon:VCApplicationIcon(@"co.brushedtype.doppler-macos")];

    swinsian = [[PlayerApplication alloc] initWithBundleIdentifier:@"com.swinsian.Swinsian"
                                                          andIcon:VCApplicationIcon(@"com.swinsian.Swinsian")];

	// Force MacOS to ask for authorization to AppleEvents if this was not already given
	if([iTunes isRunning])
		[iTunes currentVolume];
	if([spotify isRunning])
		[spotify currentVolume];
	if([doppler isRunning])
		[doppler currentVolume];
	if([swinsian isRunning])
		[swinsian currentVolume];

	systemAudio = [[SystemApplication alloc] init];

	// NSString* iTunesVersion = [[NSString alloc] initWithString:[iTunes version]];
	// NSString* spotifyVersion = [[NSString alloc] initWithString:[spotify version]];

	[self initializePreferences];

    // At rest, the status item represents the source that the normal volume
    // keys currently control (a playing player wins over system audio).
    if (@available(macOS 16.0, *)) {
        [self refreshRelevantMenuBarVolume:nil];
        relevantVolumeTimer = [NSTimer timerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(refreshRelevantMenuBarVolume:)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:relevantVolumeTimer forMode:NSRunLoopCommonModes];
    }

	[self setStartAtLogin:[self StartAtLogin] savePreferences:false];

}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
	//    if (menuItem.tag == USE_APPLE_CMD_MODIFIER_MENU_ID) { // CMD Modifier menu item
	//        return ![self LockSystemAndPlayerVolume]; // Disable when locked
	//    }
	return YES; // Default behavior
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier.length == 0) {
        return;
    }

    pid_t currentPID = NSProcessInfo.processInfo.processIdentifier;
    for (NSRunningApplication *application in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier]) {
        // Launch Services normally prevents the duplicate before it reaches
        // this point. The PID tie-break also covers directly executing the
        // binary and prevents two simultaneous launches from both surviving.
        if (!application.terminated && application.processIdentifier < currentPID) {
            [application activateWithOptions:0];
            [NSApp terminate:nil];
            return;
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [[MenuBarStatusController shared] installWithDelegate:self];

	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self selector: @selector(receiveWakeNote:) name:NSWorkspaceDidWakeNotification object: NULL];

	signal(SIGTERM, handleSIGTERM);

	if ([self tryCreateEventTap]) {
		[self completeInitialization];
	} else {
        [[SwiftUIAccessibilityController shared] show];
        authorizationPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                                   target:self
                                                                 selector:@selector(pollAccessibilityAuthorization:)
                                                                 userInfo:nil
                                                                  repeats:YES];
	}
    
    [TahoeVolumeHUD sharedManager].delegate = self;
}

- (void)updateSystemVolume:(NSTimer*)theTimer
{
}

- (void)initializePreferences
{
	preferences = [NSUserDefaults standardUserDefaults];
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
						  [NSNumber numberWithInt:2],      @"volumeIncrement",
						  [NSNumber numberWithBool:true] , @"TappingEnabled",
						  [NSNumber numberWithBool:false], @"UseAppleCMDModifier",
						  [NSNumber numberWithBool:false], @"LockSystemAndPlayerVolume",
						  [NSNumber numberWithBool:false], @"iTunesControl",
						  [NSNumber numberWithBool:false], @"spotifyControl",
						  [NSNumber numberWithBool:false], @"dopplerControl",
						  [NSNumber numberWithBool:false], @"swinsianControl",
						  [NSNumber numberWithBool:true],  @"systemControl",
                          @0,   @"iTunesControl.minimumVolume",
                          @100, @"iTunesControl.maximumVolume",
                          @0,   @"spotifyControl.minimumVolume",
                          @100, @"spotifyControl.maximumVolume",
                          @0,   @"dopplerControl.minimumVolume",
                          @100, @"dopplerControl.maximumVolume",
                          @0,   @"swinsianControl.minimumVolume",
                          @100, @"swinsianControl.maximumVolume",
						  nil ]; // terminate the list
	[preferences registerDefaults:dict];
    
	[self setTapping:[preferences boolForKey:              @"TappingEnabled"]];
	[self setUseAppleCMDModifier:[preferences boolForKey:  @"UseAppleCMDModifier"]];
	[self setLockSystemAndPlayerVolume:[preferences boolForKey:  @"LockSystemAndPlayerVolume"]];

	NSInteger volumeIncSetting = [preferences integerForKey:@"volumeIncrement"];
	[self setVolumeInc:volumeIncSetting];

}

- (void) setUseAppleCMDModifier:(bool)enabled
{
	[preferences setBool:enabled forKey:@"UseAppleCMDModifier"];
	[preferences synchronize];

	_UseAppleCMDModifier=enabled;
}

- (IBAction)toggleUseAppleCMDModifier:(id)sender
{
	[self setUseAppleCMDModifier:![self UseAppleCMDModifier]];
}

- (IBAction)toggleLockSystemAndPlayerVolume:(id)sender
{
	[self setLockSystemAndPlayerVolume:![self LockSystemAndPlayerVolume]];
}

/*
 - (void) syncSystemVolume:(NSTimer*)theTimer
 {
 id runningPlayerPtr = [self runningPlayer];

 if (runningPlayerPtr != nil && runningPlayerPtr != systemAudio)
 {
 double systemVolume = [systemAudio currentVolume];
 double volume = [runningPlayerPtr currentVolume];
 double diff = systemVolume - volume;
 if (diff<0) diff = -diff;
 if( diff>1E-3 ) {
 NSLog(@"EQUALIZING");
 NSLog(@"Player volume: %1.5f",volume);
 NSLog(@"Apple Music: %d",runningPlayerPtr == iTunes);
 NSLog(@"System volume: %1.5f",systemVolume);
 NSLog(@"Diff: %1.10f",diff);
 [systemAudio setCurrentVolume:volume];
 [self setSystemVolume:volume];
 }
 }
 }
 */

- (void) setLockSystemAndPlayerVolume:(bool)enabled
{
	[preferences setBool:enabled forKey:@"LockSystemAndPlayerVolume"];
	[preferences synchronize];

	_LockSystemAndPlayerVolume=enabled;

	/*
	 if(_LockSystemAndPlayerVolume) {
	 volumeLockSyncTimer = [NSTimer timerWithTimeInterval:volumeLockSyncInterval target:self selector:@selector(syncSystemVolume:) userInfo:nil repeats:YES];
	 [[NSRunLoop mainRunLoop] addTimer:volumeLockSyncTimer forMode:NSRunLoopCommonModes];
	 } else {
	 [volumeLockSyncTimer invalidate];
	 volumeLockSyncTimer = nil;
	 }
	 */
}

- (void)setTapping:(bool)enabled {
    if (eventTap) {
        CGEventTapEnable(eventTap, enabled);
        // Reset key state tracking to avoid stale state after re-creation
        _previousKeyCode = 0;
        _muteDown = NO;
    } else if (enabled) {
        // Try to recreate the tap if it was torn down
        if (![self createEventTap]) {
            NSLog(@"[Volume Control] Failed to recreate event tap.");
            // You could also show an alert here if desired
            enabled = NO; // fallback
        }
    }
    
    [[[self statusBar] button] setAppearsDisabled:!enabled];

    [preferences setBool:enabled forKey:@"TappingEnabled"];
    [preferences synchronize];

    _Tapping = enabled;
    [[MenuBarStatusController shared] refreshEnabledState];
}

- (IBAction)toggleTapping:(id)sender
{
	[self setTapping:![self Tapping]];
}

- (void)updateVolumeIncrement:(NSInteger)volumeIncSetting
{
	[self setVolumeInc:volumeIncSetting];

	[preferences setInteger:volumeIncSetting forKey:@"volumeIncrement"];
	[preferences synchronize];

}

- (void)updateVolumeIncrementNumber:(NSNumber *)value
{
    [self updateVolumeIncrement:value.integerValue];
}

- (void) setVolumeInc:(NSInteger)volumeIncSetting
{
	switch(volumeIncSetting)
	{
		case 5:
			increment = 25;
			break;
		case 4:
			increment = 12.5;
			break;
		case 3:
			increment = 6.25;
			break;
		case 2:
			increment = 3.125;
			break;
		case 1:
		default:
			increment = 1.5625;
			break;

	}
}

- (IBAction)aboutPanel:(id)sender
{
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"—";
    NSString *buildNumber = info[@"CFBundleVersion"] ?: @"—";

    // Use AppKit's native About panel. Besides matching the rest of macOS, it
    // avoids the remote SwiftUI theme-widget connection used by the previous
    // custom glass window.
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationVersion: shortVersion,
        NSAboutPanelOptionVersion: buildNumber
    }];
}

#pragma mark - Diagnostics

// hw.model, e.g. "MacBookPro18,3".
- (NSString *)hardwareModel
{
    size_t len = 0;
    if (sysctlbyname("hw.model", NULL, &len, NULL, 0) != 0 || len == 0) {
        return @"(unknown)";
    }
    char *buf = malloc(len);
    NSString *model = @"(unknown)";
    if (sysctlbyname("hw.model", buf, &len, NULL, 0) == 0) {
        model = [NSString stringWithUTF8String:buf] ?: @"(unknown)";
    }
    free(buf);
    return model;
}

// Automation (Apple Events) permission for a target app, without prompting.
- (NSString *)automationStatusForBundleID:(NSString *)bundleID
{
    const char *cstr = [bundleID UTF8String];
    AEAddressDesc target;
    if (AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &target) != noErr) {
        return @"(check failed)";
    }

    OSStatus status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false);
    AEDisposeDesc(&target);

    switch (status) {
        case noErr:                             return @"granted";
        case errAEEventNotPermitted:            return @"denied";
        case errAEEventWouldRequireUserConsent: return @"not yet requested";
        case procNotFound:                      return @"app not running";
        default:                                return [NSString stringWithFormat:@"unknown (%d)", (int)status];
    }
}

// Builds the self-documenting plain-text diagnostics report placed on the
// clipboard. Sections are labelled and commented so the user can read it and
// remove anything they prefer not to share before posting.
- (NSString *)diagnosticsReport
{
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *buildNumber  = info[@"CFBundleVersion"] ?: @"?";
    NSString *osVersion    = [[NSProcessInfo processInfo] operatingSystemVersionString];

    NSMutableString *r = [NSMutableString string];
    [r appendString:@"# Volume Control — diagnostics\n"];
    [r appendString:@"# Plain text. Read it and delete any line you prefer not to share before posting.\n\n"];

    [r appendString:@"## Versions\n"];
    [r appendFormat:@"Volume Control : %@ (build %@)\n", shortVersion, buildNumber];
    [r appendFormat:@"macOS          : %@\n", osVersion];
    [r appendFormat:@"Mac model      : %@\n\n", [self hardwareModel]];

    [r appendString:@"## Permissions\n"];
    [r appendFormat:@"Accessibility (intercept volume keys) : %@\n", AXIsProcessTrusted() ? @"granted" : @"NOT granted"];
    [r appendString:@"Automation (control music players):\n"];
    [r appendFormat:@"  Apple Music : %@\n", [self automationStatusForBundleID:@"com.apple.Music"]];
    [r appendFormat:@"  Spotify     : %@\n", [self automationStatusForBundleID:@"com.spotify.client"]];
    [r appendFormat:@"  Doppler     : %@\n", [self automationStatusForBundleID:@"co.brushedtype.doppler-macos"]];
    [r appendFormat:@"  Swinsian    : %@\n\n", [self automationStatusForBundleID:@"com.swinsian.Swinsian"]];

    [r appendString:@"## Audio output devices\n"];
    [r appendString:@"# If a device shows \"no\" everywhere it exposes no software volume control;\n"];
    [r appendString:@"# its volume must be changed on the device itself. master = one volume;\n"];
    [r appendString:@"# per-channel = separate left/right controls.\n\n"];
    [r appendString:[SystemApplication outputDevicesDiagnostics]];

    // Collapse the trailing blank line left by the per-device blocks into a
    // single newline.
    while ([r hasSuffix:@"\n"]) {
        [r deleteCharactersInRange:NSMakeRange(r.length - 1, 1)];
    }
    [r appendString:@"\n"];

    return r;
}

- (IBAction)copyDiagnostics:(id)sender
{
    [[SwiftUIModalController shared] showDiagnostics:[self diagnosticsReport]];
}

- (void) receiveWakeNote: (NSNotification*) note
{
	NSLog(@"Received WakeNote: %@", [note name]);
	[self setTapping:[self Tapping]];
}

- (void)resetCurrentPlayer:(NSTimer*)theTimer
{
	// Keep memory of the current player until this timeout is reached
	// After the timeout, it is forced to check again what the current player is
	[checkPlayerTimer invalidate];
	checkPlayerTimer = nil;
	currentPlayer = nil;
}

- (id)runningPlayer
{
	if(currentPlayer)
		return currentPlayer;

	checkPlayerTimer = [NSTimer timerWithTimeInterval:checkPlayerTimeout target:self selector:@selector(resetCurrentPlayer:) userInfo:nil repeats:NO];
	[[NSRunLoop mainRunLoop] addTimer:checkPlayerTimer forMode:NSRunLoopCommonModes];

	if(_AppleCMDModifierPressed == _UseAppleCMDModifier)
	{
		if([preferences boolForKey:@"iTunesControl"] && [iTunes isRunning] && [iTunes playerState] == iTunesEPlSPlaying)
		{
			currentPlayer = iTunes;
		}
		else if([preferences boolForKey:@"spotifyControl"] && [spotify isRunning] && (SpotifyEPlS)[spotify playerState] == SpotifyEPlSPlaying)
		{
			currentPlayer = spotify;
		}
		else if([preferences boolForKey:@"dopplerControl"] && [doppler isRunning] && (DopplerEPlS)[doppler playerState] == DopplerEPlSPlaying)
		{
			currentPlayer = doppler;
		}
		else if([preferences boolForKey:@"swinsianControl"] && [swinsian isRunning] && (SwinsianPlayerState)[swinsian playerState] == SwinsianPlayerStatePlaying)
		{
			currentPlayer = swinsian;
		}
		else
		{
			currentPlayer = systemAudio;
		}
	}
	else
		currentPlayer = systemAudio;

	return currentPlayer;
}

- (void)refreshRelevantMenuBarVolume:(NSTimer *)timer
{
    // Re-evaluate instead of using the short key-repeat cache so starting or
    // stopping playback is reflected even when no volume key is pressed.
    [checkPlayerTimer invalidate];
    checkPlayerTimer = nil;
    currentPlayer = nil;

    id relevantPlayer = [self runningPlayer];
    if (relevantPlayer != nil) {
        double volume = [relevantPlayer currentVolume];
        if ([relevantPlayer isKindOfClass:[PlayerApplication class]]) {
            double maximum = [(PlayerApplication *)relevantPlayer maximumAllowedVolume];
            if (volume > maximum) {
                volume = maximum;
                [relevantPlayer setCurrentVolume:volume];
                if (_LockSystemAndPlayerVolume) [systemAudio setCurrentVolume:volume];
            }
        }
        [[TahoeVolumeHUD sharedManager] setMenuBarVolume:volume
                                       usingMusicPlayer:relevantPlayer];
    }
}

- (void)applyVolumeLimitForPreference:(NSString *)preference
{
    PlayerApplication *player = nil;
    if ([preference isEqualToString:@"iTunesControl"]) player = iTunes;
    else if ([preference isEqualToString:@"spotifyControl"]) player = spotify;
    else if ([preference isEqualToString:@"dopplerControl"]) player = doppler;
    else if ([preference isEqualToString:@"swinsianControl"]) player = swinsian;

    if (player == nil || ![player isRunning]) return;
    double current = [player currentVolume];
    double maximum = [player maximumAllowedVolume];
    if (current > maximum) {
        [player setCurrentVolume:maximum];
        if (_LockSystemAndPlayerVolume) [systemAudio setCurrentVolume:maximum];
        [[TahoeVolumeHUD sharedManager] setMenuBarVolume:maximum usingMusicPlayer:player];
    }
}

- (void)setVolumeUp:(bool)increase
{
	id runningPlayerPtr = [self runningPlayer];

	if (runningPlayerPtr != nil)
	{
        // During a ramp (key held) use the locally-cached doubleVolume for
        // PlayerApplication instances to avoid a blocking ScriptingBridge round-trip
        // on every tick.  The cache is always current because setCurrentVolume:
        // updates it synchronously, and the ramp cannot start before at least one
        // write has been issued (the initial key-down press calls setVolumeUp: once
        // before the timer starts).
        // SystemApplication reads CoreAudio in-process (no IPC), so it is fast
        // enough to use currentVolume directly — and it has no doubleVolume cache.
        double volume = (self->volumeRampTimer != nil && [runningPlayerPtr isKindOfClass:[PlayerApplication class]])
                      ? [(PlayerApplication *)runningPlayerPtr doubleVolume]
                      : [runningPlayerPtr currentVolume];

#ifdef DEBUG
        double dbgPrevVolume = volume; // internal belief before this step
#endif
        BOOL restoredPlayerFromMute = NO;

		if([runningPlayerPtr oldVolume]<0) // if it was not mute
		{
			//volume=[musicProgramPnt soundVolume]+_volumeInc*(increase?1:-1);
			volume += (increase?1:-1)*increment;
		}
		else // if it was mute
		{
			// [volumeImageLayer setContents:imgVolOn];  // restore the image of the speaker from mute speaker
			volume=[runningPlayerPtr oldVolume];
            if ([runningPlayerPtr isKindOfClass:[PlayerApplication class]]) {
                volume = [(PlayerApplication *)runningPlayerPtr
                          restoreVolumeAfterMute:volume];
                restoredPlayerFromMute = YES;
            }
			[runningPlayerPtr setOldVolume:-1];  // this says that it is not mute
		}
		if (volume<0) volume=0;
		if (volume>100) volume=100;

        // Player APIs only accept whole percentages. Quantize before presenting
        // the value so the HUD and status icon cannot disagree with the cache.
        if ([runningPlayerPtr isKindOfClass:[PlayerApplication class]]) {
            volume = [(PlayerApplication *)runningPlayerPtr
                      protectedVolumeForRequestedVolume:round(volume)];
        }
        
        OSDGraphic image = 0;
        NSInteger numFullBlks = 0;
        NSInteger numQrtsBlks = 0;
        
        if (@available(macOS 16.0, *)) {
            // On Tahoe, show the new popover HUD anchored to the status item.
        } else {
            image = (volume > 0)? OSDGraphicSpeaker : OSDGraphicSpeakerMute;
            numFullBlks = floor(volume/6.25);
            numQrtsBlks = round((volume-(double)numFullBlks*6.25)/1.5625);
        }

		//NSLog(@"%d %d",(int)numFullBlks,(int)numQrtsBlks);

        if (@available(macOS 16.0, *)) {
            [[TahoeVolumeHUD sharedManager] showHUDWithVolume:volume usingMusicPlayer:runningPlayerPtr andLabel:[systemAudio getDefaultOutputDeviceName]];
        } else {
            if(image) {
                id osdMgr = [self->OSDManager sharedManager];
                if (osdMgr) {
                    [osdMgr showImage:image onDisplayID:CGSMainDisplayID() priority:OSDPriorityDefault msecUntilFade:1000 filledChiclets:(unsigned int)(round(((numFullBlks*4+numQrtsBlks)*1.5625)*100)) totalChiclets:(unsigned int)10000 locked:NO];
                }
            }
        }

#ifdef DEBUG
        NSLog(@"[VC] step  internal=%.2f  →  target=%.2f", dbgPrevVolume, volume);
#endif

        // Player mute restoration was already written above so it can bypass
        // accidental-jump limiting while retaining the configured hard limit.
        if (!restoredPlayerFromMute) {
            [runningPlayerPtr setCurrentVolume:volume];
        }
		if (_LockSystemAndPlayerVolume && runningPlayerPtr != systemAudio) {
			[systemAudio setCurrentVolume:volume];
		}

		if( runningPlayerPtr == iTunes)
			[self setItunesVolume:volume];
		else if( runningPlayerPtr == spotify)
			[self setSpotifyVolume:volume];
		else if (runningPlayerPtr == doppler)
			[self setDopplerVolume:volume];
		else if (runningPlayerPtr == swinsian)
			[self setSwinsianVolume:volume];

		if(_LockSystemAndPlayerVolume || runningPlayerPtr == systemAudio)
			[self setSystemVolume:volume];

		[self refreshVolumeBar:(int)volume];
	}
}

- (void) setItunesVolume:(NSInteger)volume
{
}

- (void) setSpotifyVolume:(NSInteger)volume
{
}

- (void) setDopplerVolume:(NSInteger)volume
{
}

- (void) setSwinsianVolume:(NSInteger)volume
{
}

- (void) setSystemVolume:(NSInteger)volume
{
}

- (void) updatePercentages
{
	if([iTunes isRunning])
		[self setItunesVolume:[iTunes currentVolume]];
	else
		[self setItunesVolume:-1];

	if([spotify isRunning])
		[self setSpotifyVolume:[spotify currentVolume]];
	else
		[self setSpotifyVolume:-1];

	if ([doppler isRunning])
		[self setDopplerVolume:[doppler currentVolume]];
	else
		[self setDopplerVolume:-1];

	if ([swinsian isRunning])
		[self setSwinsianVolume:[swinsian currentVolume]];
	else
		[self setSwinsianVolume:-1];

	[self setSystemVolume:[systemAudio currentVolume]];
}

- (void) refreshVolumeBar:(NSInteger)volume
{
	NSInteger doubleFullRectangles = (NSInteger)round(32.0f * volume / 100.0f);
	NSInteger fullRectangles=doubleFullRectangles>>1;

	[CATransaction begin];
	[CATransaction setAnimationDuration: 0.0];
	[CATransaction setDisableActions: TRUE];

	if(volume==0)
	{
		[volumeImageLayer setContents:imgVolOff];
	}
	else
	{
		[volumeImageLayer setContents:imgVolOn];
	}

	CGRect frame;

	for(NSInteger i=0; i<fullRectangles; i++)
	{
		frame = [volumeBar[i] frame];
		frame.size.width=9;
		[volumeBar[i] setFrame:frame];

		[volumeBar[i] setHidden:NO];
	}
	for(NSInteger i=fullRectangles; i<16; i++)
	{
		frame = [volumeBar[i] frame];
		frame.size.width=9;
		[volumeBar[i] setFrame:frame];

		[volumeBar[i] setHidden:YES];
	}

	if(fullRectangles*2 != doubleFullRectangles)
	{

		frame = [volumeBar[fullRectangles] frame];
		frame.size.width=5;

		[volumeBar[fullRectangles] setFrame:frame];
		[volumeBar[fullRectangles] setHidden:NO];
	}

	[CATransaction commit];
}

#pragma mark - Music players

- (IBAction)toggleMusicPlayer:(id)sender
{
}

- (void)menuWillOpen:(NSMenu *)menu
{
	[self updatePercentages];

	if(!_Tapping)
	{
		updateSystemVolumeTimer = [NSTimer timerWithTimeInterval:updateSystemVolumeInterval target:self selector:@selector(updateSystemVolume:) userInfo:nil repeats:YES];
		[[NSRunLoop mainRunLoop] addTimer:updateSystemVolumeTimer forMode:NSRunLoopCommonModes];
	}

	menuIsVisible=true;
}

- (void)menuDidClose:(NSMenu *)menu
{
	menuIsVisible=false;

	// Remove timer used to update volume bar status in the menu bar
	if(updateSystemVolumeTimer)
	{
		[updateSystemVolumeTimer invalidate];
		updateSystemVolumeTimer = nil;
	}
}

#pragma mark - TahoeVolumeHUDDelegate

- (void)hud:(TahoeVolumeHUD *)hud didChangeVolume:(double)volume forPlayer:(PlayerApplication*)controlledPlayer{
    // This method is called every time the user drags the slider in the HUD.
    // The received 'volume' is a value between 0.0 and 1.0.

    // 1. Convert the 0.0-1.0 scale to the 0-100 scale our app uses.
    double volumePercent = volume * 100.0;

    // 2. Get the currently active player, just like we do for the volume keys.
    id runningPlayerPtr = controlledPlayer;
    
    if (runningPlayerPtr != nil) {
        if ([runningPlayerPtr isKindOfClass:[PlayerApplication class]]) {
            volumePercent = [(PlayerApplication *)runningPlayerPtr
                             protectedVolumeForRequestedVolume:volumePercent];
        }
        // 3. Set the volume for the active player.
        [runningPlayerPtr setCurrentVolume:volumePercent];
        
        // 4. If volume is locked, also set the system volume.
        if (_LockSystemAndPlayerVolume && runningPlayerPtr != systemAudio) {
            [systemAudio setCurrentVolume:volumePercent];
        }

        // 5. Update the percentage labels in the status menu to reflect the change in real-time.
        if (runningPlayerPtr == iTunes) {
            [self setItunesVolume:volumePercent];
        } else if (runningPlayerPtr == spotify) {
            [self setSpotifyVolume:volumePercent];
        } else if (runningPlayerPtr == doppler) {
            [self setDopplerVolume:volumePercent];
        } else if (runningPlayerPtr == swinsian) {
            [self setSwinsianVolume:volumePercent];
        }

        if (_LockSystemAndPlayerVolume || runningPlayerPtr == systemAudio) {
            [self setSystemVolume:volumePercent];
        }
    }
}

@end
