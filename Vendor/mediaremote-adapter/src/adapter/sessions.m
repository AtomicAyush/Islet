// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.

// Local change (Islet), see VENDORED.md.
//
// The calls and notifications the stream uses are about one application only:
// the one MediaRemote has elected as now playing, which is the one that most
// recently started playing, kept while it is paused. Another application that
// plays on meanwhile, such as a video in a browser while a music player plays,
// is reported by none of them. MediaRemote still knows every such session:
// MRMediaRemoteGetNowPlayingClients lists them all, each one's information and
// playback state can be read for its player path, and the per-player
// notifications, which carry that path, are posted for every one of them.
// This reports them all, so that a caller can offer each one.
//
// It runs as a process of its own, beside the stream rather than inside it: it
// leans on more of MediaRemote's private functions than the stream does, with
// signatures only checked on recent systems. Should one of them be missing or
// throw, this ends with kMRAExitCannotListSessions, and should one crash, this
// process goes alone; the stream carries on either way.
//
// It only reads. A command still reaches the elected application alone, which
// is why expect.m exists.

#include <errno.h>
#include <signal.h>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

#import "MediaRemoteAdapter.h"
#import "adapter/env.h"
#import "adapter/globals.h"
#import "adapter/keys.h"
#import "adapter/now_playing.h"
#import "private/MediaRemote.h"
#import "utility/Debounce.h"
#import "utility/helpers.h"

// The list is looked at again this often in any case, for a session that
// changes, starts or ends without a notification reaching this process.
#define SESSIONS_POLL_SECONDS 10
// A reading MediaRemote has not answered by then is given up; the next
// notification or poll reads again.
#define SESSIONS_READ_TIMEOUT_MILLIS 2000
// MediaRemote can name a session's artwork before it has the image: the first
// reading after a session appears may carry the type and size but no data. One
// more reading this much later has it.
#define SESSIONS_ARTWORK_RETRY_MILLIS 500

// MRMediaRemoteGetPlaybackStateForPlayer's "playing"; 2 is paused, 3 stopped
// and 4 interrupted.
#define MR_PLAYBACK_STATE_PLAYING 1

static NSString *kMRASessionElected = @"elected";

// Posted for every player, elected or not, naming it by its player path.
static NSString *kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification =
    @"kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification";
static NSString *kMRMediaRemotePlayerIsPlayingDidChangeNotification =
    @"kMRMediaRemotePlayerIsPlayingDidChangeNotification";
static NSString *kMRMediaRemotePlayerPlaybackStateDidChangeNotification =
    @"kMRMediaRemotePlayerPlaybackStateDidChangeNotification";

// Exported by MediaRemote but not loaded by the MediaRemote class; signatures
// as checked on macOS 26 and 27. Where they differ, this process is what
// fails, not the stream.
typedef void (*MRMediaRemoteGetNowPlayingClients_t)(
    dispatch_queue_t queue, void (^completion)(NSArray *clients, NSError *error));
typedef void (*MRMediaRemoteGetNowPlayingInfoForPlayer_t)(
    id playerPath, BOOL withArtwork, dispatch_queue_t queue,
    void (^completion)(NSDictionary *information, void *artwork));
typedef void (*MRMediaRemoteGetPlaybackStateForPlayer_t)(
    id playerPath, dispatch_queue_t queue,
    void (^completion)(unsigned int state));
typedef CFStringRef (*MRNowPlayingClientGetString_t)(id client);
typedef int (*MRNowPlayingClientGetProcessIdentifier_t)(id client);

@interface NSObject (MediaRemoteAdapterSessions)
+ (id)localOrigin;
- (id)initWithOrigin:(id)origin client:(id)client player:(id)player;
@end

static struct {
    MRMediaRemoteGetNowPlayingClients_t getNowPlayingClients;
    MRMediaRemoteGetNowPlayingInfoForPlayer_t getNowPlayingInfoForPlayer;
    MRMediaRemoteGetPlaybackStateForPlayer_t getPlaybackStateForPlayer;
    MRNowPlayingClientGetString_t getBundleIdentifier;
    MRNowPlayingClientGetString_t getParentAppBundleIdentifier;
    MRNowPlayingClientGetProcessIdentifier_t getProcessIdentifier;
    Class originClass;
    Class playerPathClass;
} mr;

// Everything below is touched on g_serialdispatchQueue only, once started.
static bool g_convertMicros = false;
static bool g_noArtwork = false;
static Debounce *g_debounce = nil;
static dispatch_source_t g_poll = nil;
static NSArray *g_observers = nil;
// The payload last printed for each session, by its identifier.
static NSMutableDictionary<NSString *, NSDictionary *> *g_reported = nil;
// Sessions read again once already for artwork MediaRemote named but did not
// hand over, so that one that never has it is not read forever.
static NSMutableSet<NSString *> *g_artworkRetried = nil;
// A whole list has been printed, so the reader knows every session there is,
// even when there is none.
static bool g_listedOnce = false;
static bool g_reading = false;
static bool g_readAgain = false;

static bool loadFunctions(void) {
    void *handle =
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/"
               "MediaRemote",
               RTLD_LAZY);
    if (handle == NULL) {
        return false;
    }
    mr.getNowPlayingClients =
        dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
    mr.getNowPlayingInfoForPlayer =
        dlsym(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer");
    mr.getPlaybackStateForPlayer =
        dlsym(handle, "MRMediaRemoteGetPlaybackStateForPlayer");
    mr.getBundleIdentifier =
        dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
    mr.getParentAppBundleIdentifier =
        dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
    mr.getProcessIdentifier =
        dlsym(handle, "MRNowPlayingClientGetProcessIdentifier");
    mr.originClass = NSClassFromString(@"MROrigin");
    mr.playerPathClass = NSClassFromString(@"MRPlayerPath");
    return mr.getNowPlayingClients != NULL &&
           mr.getNowPlayingInfoForPlayer != NULL &&
           mr.getPlaybackStateForPlayer != NULL &&
           mr.getBundleIdentifier != NULL &&
           mr.getParentAppBundleIdentifier != NULL &&
           mr.getProcessIdentifier != NULL && mr.originClass != nil &&
           mr.playerPathClass != nil &&
           [mr.originClass respondsToSelector:@selector(localOrigin)] &&
           [mr.playerPathClass
               instancesRespondToSelector:@selector(initWithOrigin:
                                                            client:player:)];
}

// Gives up for good: a MediaRemote that does not behave as this expects would
// only give a list that is wrong, and the reader does better without one.
static void cannotList(NSString *reason) {
    printErrf(@"MediaRemote cannot list its now playing sessions here: %@",
              reason);
    exit(kMRAExitCannotListSessions);
}

static NSString *clientString(MRNowPlayingClientGetString_t get, id client) {
    NSString *value = (__bridge NSString *)get(client);
    return [value isKindOfClass:[NSString class]] && [value length] > 0
               ? value
               : nil;
}

// MediaRemote can list a client for a moment after its process is gone, as
// when the application just quit.
static bool processIsRunning(int pid) {
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

static bool isSameSessionItem(NSDictionary *a, NSDictionary *b) {
    for (NSString *key in identifyingPayloadKeys()) {
        id aValue = a[key];
        id bValue = b[key];
        if (aValue == nil && bValue == nil) {
            continue;
        }
        if (aValue == nil || bValue == nil || ![aValue isEqual:bValue]) {
            return false;
        }
    }
    return true;
}

static NSDictionary *sessionDifference(NSDictionary *a, NSDictionary *b) {
    NSMutableDictionary *difference = [NSMutableDictionary dictionary];
    NSMutableSet *keys = [NSMutableSet setWithArray:[a allKeys]];
    [keys addObjectsFromArray:[b allKeys]];
    for (id key in keys) {
        id oldValue = a[key];
        id newValue = b[key];
        if ((oldValue == nil) != (newValue == nil) ||
            (oldValue != nil && ![oldValue isEqual:newValue])) {
            difference[key] = newValue ?: [NSNull null];
        }
    }
    return difference;
}

// The payload for one session, in the stream's keys plus "elected", or nil for
// one without the mandatory keys (a session with no title, say).
static NSMutableDictionary *sessionPayload(NSDictionary *information,
                                           unsigned int state, int pid,
                                           NSString *bundleIdentifier,
                                           NSString *parentBundleIdentifier,
                                           bool elected, bool withArtwork) {
    if (information == nil ||
        [information[kMRMediaRemoteNowPlayingInfoServiceIdentifier]
            isEqual:@"com.vandenbe.MediaRemoteAdapter.TestClient"]) {
        return nil;
    }
    NSMutableDictionary *payload = convertNowPlayingInformation(
        information, g_convertMicros, false, !withArtwork);
    payload[kMRAProcessIdentifier] = @(pid);
    if (bundleIdentifier != nil) {
        payload[kMRABundleIdentifier] = bundleIdentifier;
    }
    if (parentBundleIdentifier != nil) {
        payload[kMRAParentApplicationBundleIdentifier] = parentBundleIdentifier;
    }
    payload[kMRAPlaying] = state == MR_PLAYBACK_STATE_PLAYING ? @YES : @NO;
    payload[kMRASessionElected] = elected ? @YES : @NO;
    return allMandatoryPayloadKeysSet(payload, false) ? payload : nil;
}

// Reads every session, with or without artwork, and calls completion on the
// serial queue with their payloads by identifier ("PID/BUNDLE_ID"), or with
// nil when MediaRemote did not answer in time or could not list them. A failed
// reading is not an empty one: reporting it as such would end every session
// until the next.
static void readSessions(bool withArtwork,
                         void (^completion)(NSDictionary *sessions)) {
    __block bool finished = false;
    void (^finish)(NSDictionary *) = ^(NSDictionary *sessions) {
      if (finished) {
          return;
      }
      finished = true;
      completion(sessions);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 SESSIONS_READ_TIMEOUT_MILLIS * NSEC_PER_MSEC),
                   g_serialdispatchQueue, ^{
                     if (!finished) {
                         printErrf(@"Reading the now playing sessions timed "
                                   @"out after %d milliseconds",
                                   SESSIONS_READ_TIMEOUT_MILLIS);
                     }
                     finish(nil);
                   });

    __block NSArray *clients = nil;
    __block id electedClient = nil;
    dispatch_group_t listing = dispatch_group_create();
    dispatch_group_enter(listing);
    mr.getNowPlayingClients(g_serialdispatchQueue,
                            ^(NSArray *result, NSError *error) {
                              clients = error == nil ? (result ?: @[]) : nil;
                              dispatch_group_leave(listing);
                            });
    dispatch_group_enter(listing);
    g_mediaRemote.getNowPlayingClient(g_serialdispatchQueue, ^(id client) {
      electedClient = client;
      dispatch_group_leave(listing);
    });

    dispatch_group_notify(listing, g_serialdispatchQueue, ^{
      if (finished) {
          return;
      }
      if (clients == nil) {
          printErr(@"MediaRemote could not list the now playing sessions");
          finish(nil);
          return;
      }
      NSMutableDictionary<NSString *, NSMutableDictionary *> *readings =
          [NSMutableDictionary dictionary];
      dispatch_group_t reading = dispatch_group_create();
      // The methods were checked for when starting, but a private class can
      // still throw for an argument it does not expect.
      @try {
          int electedPID =
              electedClient != nil ? mr.getProcessIdentifier(electedClient)
                                   : 0;
          NSString *electedBundle =
              electedClient != nil
                  ? clientString(mr.getBundleIdentifier, electedClient)
                  : nil;
          id origin = [mr.originClass localOrigin];
          for (id client in clients) {
              int pid = mr.getProcessIdentifier(client);
              if (!processIsRunning(pid)) {
                  continue;
              }
              NSString *bundle = clientString(mr.getBundleIdentifier, client);
              NSString *parent =
                  clientString(mr.getParentAppBundleIdentifier, client);
              NSString *identifier =
                  [NSString stringWithFormat:@"%d/%@", pid, bundle ?: @""];
              NSMutableDictionary *entry = [NSMutableDictionary dictionary];
              entry[@"pid"] = @(pid);
              entry[@"bundle"] = bundle;
              entry[@"parent"] = parent;
              entry[@"elected"] = @(pid == electedPID &&
                                    (bundle == electedBundle ||
                                     [bundle isEqual:electedBundle]));
              readings[identifier] = entry;

              // No player: MediaRemote resolves the client's active one.
              id path = [[mr.playerPathClass alloc] initWithOrigin:origin
                                                            client:client
                                                            player:nil];
              dispatch_group_enter(reading);
              mr.getNowPlayingInfoForPlayer(
                  path, withArtwork, g_serialdispatchQueue,
                  ^(NSDictionary *information, void *artwork) {
                    entry[@"information"] = information;
                    dispatch_group_leave(reading);
                  });
              dispatch_group_enter(reading);
              mr.getPlaybackStateForPlayer(path, g_serialdispatchQueue,
                                           ^(unsigned int state) {
                                             entry[@"state"] = @(state);
                                             dispatch_group_leave(reading);
                                           });
          }
      } @catch (NSException *exception) {
          cannotList([NSString stringWithFormat:@"%@: %@", [exception name],
                                                [exception reason]]);
      }
      dispatch_group_notify(reading, g_serialdispatchQueue, ^{
        NSMutableDictionary *sessions = [NSMutableDictionary dictionary];
        for (NSString *identifier in readings) {
            NSDictionary *entry = readings[identifier];
            NSDictionary *payload = sessionPayload(
                entry[@"information"], [entry[@"state"] unsignedIntValue],
                [entry[@"pid"] intValue], entry[@"bundle"], entry[@"parent"],
                [entry[@"elected"] boolValue], withArtwork);
            if (payload != nil) {
                sessions[identifier] = payload;
            }
        }
        finish(sessions);
      });
    });
}

static void readAndReport(void);

static void printSessionLine(NSDictionary *line) {
    NSString *serialized = serializeJsonDictionarySafe(line, false);
    if (serialized != nil) {
        printOut(serialized);
    }
}

// Prints what changed since the last report: a full payload for a session that
// is new or has moved on to another item, only the changed keys (null for one
// that is gone) for the same item, and "sessionEnded" for one no longer listed.
// Returns whether it printed anything.
static bool report(NSDictionary<NSString *, NSDictionary *> *sessions) {
    bool printed = false;
    NSArray *identifiers =
        [[sessions allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *identifier in identifiers) {
        NSMutableDictionary *payload = [sessions[identifier] mutableCopy];
        NSDictionary *previous = g_reported[identifier];
        bool sameItem =
            previous != nil && isSameSessionItem(previous, payload);
        // MediaRemote often lets go of an item's artwork and loads it again
        // shortly after, as the stream also finds; keep what it had.
        if (sameItem && payload[kMRAArtworkData] == nil &&
            previous[kMRAArtworkData] != nil) {
            payload[kMRAArtworkData] = previous[kMRAArtworkData];
            if (payload[kMRAArtworkMimeType] == nil &&
                previous[kMRAArtworkMimeType] != nil) {
                payload[kMRAArtworkMimeType] = previous[kMRAArtworkMimeType];
            }
        }
        if (!g_noArtwork && payload[kMRAArtworkMimeType] != nil &&
            payload[kMRAArtworkData] == nil) {
            if (![g_artworkRetried containsObject:identifier]) {
                [g_artworkRetried addObject:identifier];
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  SESSIONS_ARTWORK_RETRY_MILLIS * NSEC_PER_MSEC),
                    g_serialdispatchQueue, ^{
                      readAndReport();
                    });
            }
        } else {
            [g_artworkRetried removeObject:identifier];
        }

        if (sameItem) {
            NSDictionary *difference = sessionDifference(previous, payload);
            if ([difference count] == 0) {
                continue;
            }
            printSessionLine(@{
                @"type" : @"session",
                @"id" : identifier,
                @"diff" : @YES,
                @"payload" : difference,
            });
        } else {
            printSessionLine(@{
                @"type" : @"session",
                @"id" : identifier,
                @"diff" : @NO,
                @"payload" : payload,
            });
        }
        g_reported[identifier] = payload;
        printed = true;
    }
    for (NSString *identifier in [g_reported allKeys]) {
        if (sessions[identifier] == nil) {
            [g_reported removeObjectForKey:identifier];
            [g_artworkRetried removeObject:identifier];
            printSessionLine(@{@"type" : @"sessionEnded", @"id" : identifier});
            printed = true;
        }
    }
    return printed;
}

// Whether a reading without artwork finds every session as last reported,
// but for the artwork it leaves out, and none still waits for artwork
// MediaRemote named but never handed over: a full reading may have it by now.
static bool matchesReported(NSDictionary<NSString *, NSDictionary *> *sessions) {
    if ([sessions count] != [g_reported count]) {
        return false;
    }
    for (NSString *identifier in sessions) {
        NSMutableDictionary *reported = [g_reported[identifier] mutableCopy];
        if (reported == nil || (reported[kMRAArtworkMimeType] != nil &&
                                reported[kMRAArtworkData] == nil)) {
            return false;
        }
        [reported
            removeObjectsForKeys:@[ kMRAArtworkMimeType, kMRAArtworkData ]];
        if (![reported isEqual:sessions[identifier]]) {
            return false;
        }
    }
    return true;
}

// One reading at a time: a request while one is on its way reads once more
// after it, which covers any number of requests meanwhile.
static void readAndReport(void) {
    if (g_reading) {
        g_readAgain = true;
        return;
    }
    g_reading = true;
    readSessions(!g_noArtwork, ^(NSDictionary *sessions) {
      if (sessions != nil) {
          // The end of the reading's lines, so that the reader takes the list
          // whole rather than a part of it, and after the first reading in any
          // case, which tells it when there is no session at all.
          if (report(sessions) || !g_listedOnce) {
              printSessionLine(@{@"type" : @"sessionsListed"});
              g_listedOnce = true;
          }
      }
      g_reading = false;
      if (g_readAgain) {
          g_readAgain = false;
          readAndReport();
      }
    });
}

// The slow poll looks without artwork, which is most of what a reading
// carries, and reads in full only when something changed that no notification
// told of. While nothing is listed there is nothing to look at: a session that
// starts playing is elected, and MediaRemote says so.
static void poll(void) {
    if (!g_listedOnce) {
        readAndReport();
        return;
    }
    if (g_reading || [g_reported count] == 0) {
        return;
    }
    g_reading = true;
    readSessions(false, ^(NSDictionary *sessions) {
      g_reading = false;
      bool changed = sessions != nil && !matchesReported(sessions);
      if (changed || g_readAgain) {
          g_readAgain = false;
          readAndReport();
      }
    });
}

static void requestRead(void) {
    dispatch_async(g_serialdispatchQueue, ^{
      [g_debounce call:^{
        readAndReport();
      }];
    });
}

static void startSessions(int debounceMillis, bool convertMicros,
                          bool noArtwork) {
    g_convertMicros = convertMicros;
    g_noArtwork = noArtwork;
    g_reported = [NSMutableDictionary dictionary];
    g_artworkRetried = [NSMutableSet set];
    g_debounce = [[Debounce alloc] initWithDelay:(debounceMillis / 1000.0)
                                           queue:g_serialdispatchQueue];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSMutableArray *observers = [NSMutableArray array];
    for (NSString *name in @[
             kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification,
             kMRMediaRemotePlayerIsPlayingDidChangeNotification,
             kMRMediaRemotePlayerPlaybackStateDidChangeNotification,
             kMRMediaRemoteNowPlayingApplicationDidChangeNotification,
         ]) {
        [observers addObject:[center addObserverForName:name
                                                 object:nil
                                                  queue:nil
                                             usingBlock:^(NSNotification *n) {
                                               requestRead();
                                             }]];
    }
    // A quitting application's sessions end with it, whether or not
    // MediaRemote says so straight away.
    [observers
        addObject:[[[NSWorkspace sharedWorkspace] notificationCenter]
                      addObserverForName:
                          NSWorkspaceDidTerminateApplicationNotification
                                  object:nil
                                   queue:nil
                              usingBlock:^(NSNotification *n) {
                                requestRead();
                              }]];
    g_observers = observers;

    g_poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                    g_serialdispatchQueue);
    dispatch_source_set_timer(
        g_poll,
        dispatch_time(DISPATCH_TIME_NOW, SESSIONS_POLL_SECONDS * NSEC_PER_SEC),
        SESSIONS_POLL_SECONDS * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_poll, ^{
      poll();
    });
    dispatch_resume(g_poll);

    // Listing the clients once after registering is also what gets this
    // process the non-elected players' information notifications, not only
    // their play and pause ones.
    dispatch_async(g_serialdispatchQueue, ^{
      readAndReport();
    });
}

void adapter_sessions(void) {
    NSNumber *debounceOption = getEnvOptionInt(@"debounce");
    int debounceMillis = debounceOption != nil ? [debounceOption intValue] : 0;
    bool convertMicros = getEnvOption(@"micros") != nil;
    bool noArtwork = getEnvOption(@"no-artwork") != nil;

    if (!loadFunctions()) {
        cannotList(@"a function or method it needs is missing");
    }
    g_mediaRemote.registerForNowPlayingNotifications(g_serialdispatchQueue);
    startSessions(debounceMillis, convertMicros, noArtwork);
    CFRunLoopRun();
    g_mediaRemote.unregisterForNowPlayingNotifications();
}

void adapter_sessions_env(void) { adapter_sessions(); }
