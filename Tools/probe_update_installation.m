#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <unistd.h>

// Test-only SPUUserDriver. The runner embeds this in a uniquely identified copy.
// It accepts only that copy and its signed loopback feed, never the real app.
@interface InstallProbe : NSObject <NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic, strong) NSFileHandle *events;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) uint64_t received;
@end

@implementation InstallProbe
- (void)record:(NSString *)event values:(NSDictionary *)values {
    NSMutableDictionary *row = [values mutableCopy] ?: [NSMutableDictionary dictionary];
    row[@"event"] = event;
    row[@"pid"] = @(getpid());
    row[@"time"] = @([NSDate date].timeIntervalSince1970);
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
    [self.events writeData:data];
    [self.events writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.events synchronizeFile];
}
- (void)reportError:(NSError *)error {
    NSMutableArray *chain = [NSMutableArray array];
    for (NSError *next = error; next && chain.count < 8; next = next.userInfo[NSUnderlyingErrorKey]) {
        [chain addObject:@{@"domain": next.domain, @"code": @(next.code), @"message": next.localizedDescription}];
    }
    [self record:@"error" values:@{@"errors": chain}];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSBundle *bundle = NSBundle.mainBundle;
    [self record:@"started" values:@{@"mode": self.mode, @"version": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"]}];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:self delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) { [self reportError:error]; return; }
    if ([self.mode isEqualToString:@"automatic"]) {
        [self.updater checkForUpdatesInBackground];
    } else {
        [self.updater checkForUpdates];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self record:@"timeout" values:nil];
        [NSApp terminate:nil];
    });
}
- (void)applicationWillTerminate:(NSNotification *)notification { [self record:@"terminated" values:nil]; }
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    [self record:@"permission-request" values:nil];
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    [self record:@"check-started" values:nil];
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    [self record:@"found" values:@{@"version": item.versionString, @"userInitiated": @(state.userInitiated), @"stage": @(state.stage)}];
    if ([self.mode isEqualToString:@"automatic"]) {
        [self record:@"unexpected-user-interface" values:nil];
        reply(SPUUserUpdateChoiceSkip);
        [NSApp terminate:nil];
    } else {
        reply(SPUUserUpdateChoiceInstall);
    }
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { [self record:@"release-notes" values:nil]; }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { [self reportError:error]; }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self reportError:error]; acknowledgement();
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self reportError:error]; acknowledgement();
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { [self record:@"download-started" values:nil]; }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { [self record:@"download-length" values:@{@"bytes": @(length)}]; }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length { self.received += length; }
- (void)showDownloadDidStartExtractingUpdate { [self record:@"extracting" values:@{@"received": @(self.received)}]; }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    [self record:@"ready-to-relaunch" values:nil]; reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    [self record:@"installing" values:@{@"applicationTerminated": @(terminated)}];
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    [self record:@"installed" values:@{@"relaunched": @(relaunched)}]; acknowledgement();
}
- (void)dismissUpdateInstallation { [self record:@"dismissed" values:nil]; }
- (void)updater:(SPUUpdater *)updater willDownloadUpdate:(SUAppcastItem *)item withRequest:(NSMutableURLRequest *)request {
    NSURL *feed = [NSURL URLWithString:[NSBundle.mainBundle objectForInfoDictionaryKey:@"SUFeedURL"]];
    if (![request.URL.scheme isEqualToString:@"http"] || ![request.URL.host isEqualToString:@"127.0.0.1"] ||
        ![request.URL.port isEqual:feed.port]) {
        [self record:@"non-loopback-download-refused" values:nil];
        exit(2);
    }
    [self record:@"download-request" values:@{@"url": request.URL.absoluteString}];
}
- (void)updater:(SPUUpdater *)updater didDownloadUpdate:(SUAppcastItem *)item { [self record:@"downloaded" values:nil]; }
- (void)updater:(SPUUpdater *)updater didExtractUpdate:(SUAppcastItem *)item {
    // Sparkle 2.10 can send this before its installer reports a signature
    // failure. The runner checks the installer error and actual bundle bytes.
    [self record:@"extraction-callback" values:nil];
}
- (void)updater:(SPUUpdater *)updater willInstallUpdate:(SUAppcastItem *)item { [self record:@"will-install" values:nil]; }
- (void)updaterWillRelaunchApplication:(SPUUpdater *)updater { [self record:@"will-relaunch" values:nil]; }
- (BOOL)updater:(SPUUpdater *)updater willInstallUpdateOnQuit:(SUAppcastItem *)item immediateInstallationBlock:(void (^)(void))install {
    [self record:@"ready-on-quit" values:@{@"version": item.versionString}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    return NO;
}
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error { [self reportError:error]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *prefix = @"com.shunnag.KaitoFinder.UpdateInstallVerification.";
        NSString *identifier = bundle.bundleIdentifier;
        NSString *root = [[bundle objectForInfoDictionaryKey:@"KaitoUpdateVerificationRoot"] stringByResolvingSymlinksInPath];
        NSString *expected = [[root stringByAppendingPathComponent:@"installed"] stringByAppendingPathComponent:@"KaitoFinder.app"];
        NSURL *feed = [NSURL URLWithString:[bundle objectForInfoDictionaryKey:@"SUFeedURL"] ?: @""];
        NSString *mode = [bundle objectForInfoDictionaryKey:@"KaitoUpdateVerificationMode"];
        BOOL identifierOK = [identifier hasPrefix:prefix] && [[NSUUID alloc] initWithUUIDString:[identifier substringFromIndex:prefix.length]];
        BOOL pathOK = [root containsString:@"/kaitofinder-install-verify-"] &&
            [[bundle.bundleURL.path stringByResolvingSymlinksInPath] isEqualToString:expected];
        BOOL feedOK = [feed.scheme isEqualToString:@"http"] && [feed.host isEqualToString:@"127.0.0.1"] && feed.port.intValue > 0;
        if (!identifierOK || !pathOK || !feedOK || ![@[@"manual", @"automatic", @"corrupt"] containsObject:mode]) return 2;
        NSString *log = [root stringByAppendingPathComponent:@"events.jsonl"];
        NSFileHandle *events = [NSFileHandle fileHandleForWritingAtPath:log];
        if (!events) return 2;
        [events seekToEndOfFile];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        __attribute__((objc_precise_lifetime)) InstallProbe *probe = [InstallProbe new];
        probe.mode = mode; probe.events = events;
        NSApp.delegate = probe;
        [NSApp run];
    }
    return 0;
}
