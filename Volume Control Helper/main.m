//
//  main.m
//  VolumeControlHelper
//
//  Created by Andrea Alberti on 27.09.25.
//  Copyright (c) 2025 Andrea Alberti and contributors.
//  Modified in 2026 by Luca Leukert.
//  SPDX-License-Identifier: GPL-3.0-only
//

@import Cocoa;

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Path to helper bundle
        NSString *helperPath = [[NSBundle mainBundle] bundlePath];

        // Step up to the main app bundle (4 levels)
        NSString *mainAppBundlePath = [[[[helperPath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];                                        // Volume Control.app

        NSURL *mainAppURL = [NSURL fileURLWithPath:mainAppBundlePath];

        // Use the modern configuration object
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];

        [[NSWorkspace sharedWorkspace] openApplicationAtURL:mainAppURL
                                              configuration:config
                                          completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {
            if (!app) {
                NSLog(@"[Volume Control Helper] Failed to launch main app: %@", error);
            }
            // Quit helper immediately after launching
            [NSApp terminate:nil];
        }];

        // Run the runloop briefly to allow async launch to complete
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    }
    return EXIT_SUCCESS;
}
