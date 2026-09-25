// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

// Local change (Islet), see VENDORED.md.
//
// MediaRemote resolves a command sent with MRMediaRemoteSendCommand at the
// moment it arrives, to whichever application it has elected as now playing.
// Its targeted variants (MRMediaRemoteSendCommandToApp, ...ToClient,
// ...ToPlayer) do not help this process: mediaremoted redirects a targeted
// command from a client without Apple's private entitlement to that same
// elected application, unless the target is one of Apple's own media apps.
// So a caller that wants a command to reach one particular application checks
// here, immediately before sending, that it is the elected one.

#include "private/MediaRemote.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "utility/helpers.h"

#define EXPECT_TIMEOUT_MILLIS 2000

static NSString *clientString(id client, SEL selector) {
    if (client == nil || ![client respondsToSelector:selector]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id value = [client performSelector:selector];
#pragma clang diagnostic pop
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

void adapter_expect(NSString *bundleIdentifier) {
    if (bundleIdentifier == nil || [bundleIdentifier length] == 0) {
        fail(@"Missing bundle identifier");
    }

    // Every name the elected application goes by: the process MediaRemote
    // reports, and the now playing client with its parent application, so that
    // web media played by a browser's helper process matches the browser.
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    g_mediaRemote.getNowPlayingApplicationPID(
        g_serialdispatchQueue, ^(int pid) {
          appForPID(pid, ^(NSRunningApplication *process) {
            if (process.bundleIdentifier != nil) {
                [names addObject:process.bundleIdentifier];
            }
          });
          dispatch_group_leave(group);
        });

    dispatch_group_enter(group);
    g_mediaRemote.getNowPlayingClient(g_serialdispatchQueue, ^(id client) {
      for (NSString *name in @[
               clientString(client, @selector(bundleIdentifier)) ?: @"",
               clientString(client,
                            @selector(parentApplicationBundleIdentifier))
                   ?: @""
           ]) {
          if ([name length] > 0) {
              [names addObject:name];
          }
      }
      dispatch_group_leave(group);
    });

    dispatch_time_t timeout =
        dispatch_time(DISPATCH_TIME_NOW, EXPECT_TIMEOUT_MILLIS * NSEC_PER_MSEC);
    if (dispatch_group_wait(group, timeout) != 0) {
        printErrf(@"Reading the now playing application timed out after %d "
                  @"milliseconds",
                  EXPECT_TIMEOUT_MILLIS);
        exit(kMRAExitNoApplication);
    }
    if ([names count] == 0) {
        printErr(@"No application is now playing");
        exit(kMRAExitNoApplication);
    }
    if (![names containsObject:bundleIdentifier]) {
        printErrf(@"Commands would go to %@, not %@",
                  [[names allObjects] componentsJoinedByString:@" / "],
                  bundleIdentifier);
        exit(kMRAExitOtherApplication);
    }
}

void adapter_expect_env() {
    adapter_expect(getEnvFuncParamSafe(@"adapter_expect", 0, @"bundle"));
}
