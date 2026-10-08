// newsstandrss-helper: setuid-root tool that creates and removes the per-feed Newsstand app bundles in
// /Applications, which SpringBoard (running as mobile) cannot write. Arguments are validated strictly and
// only /Applications/NewsstandRSS-<12 hex>.app paths are ever touched.
//
//   install <feed id> <display name>   (re)create the bundle from the template
//   remove <feed id>                   delete the bundle
//     (any number of install/remove operations may follow each other; uicache runs once at the end)
//   reinstall-all                      rebuild existing bundles from the current template (package upgrade)
//   remove-all                         delete every feed bundle (package removal)

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#import "NRSSShared.h"

#define NRSSMobileUID 501

static NSString *NRSSCleanName(NSString *name) {
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *control = [NSCharacterSet controlCharacterSet];
    for (NSUInteger i = 0; i < name.length && clean.length < 40; i++) {
        unichar character = [name characterAtIndex:i];
        if (![control characterIsMember:character])
            [clean appendFormat:@"%C", character];
    }
    NSString *trimmed = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : @"RSS";
}

static BOOL NRSSInstall(NSString *feedID, NSString *name) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *destination = NRSSAppPathForFeedID(feedID);
    NSString *staging = [NSString stringWithFormat:@"/Applications/.NewsstandRSS-%@.tmp", feedID];
    [files removeItemAtPath:staging error:NULL];
    NSError *error = nil;
    if (![files copyItemAtPath:NRSSTemplatePath toPath:staging error:&error]) {
        fprintf(stderr, "copy template: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }
    NSString *infoPath = [staging stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath];
    if (!info) {
        fprintf(stderr, "template Info.plist unreadable\n");
        [files removeItemAtPath:staging error:NULL];
        return NO;
    }
    [info setObject:NRSSBundleIDForFeedID(feedID) forKey:@"CFBundleIdentifier"];
    [info setObject:name forKey:@"CFBundleDisplayName"];
    [info setObject:feedID forKey:NRSSFeedIDInfoKey];
    // The cover lives in mobile's data directory so the tweak and the reader can refresh it without root.
    for (NSString *suffix in @[@"", @"@2x"]) {
        NSString *link = [staging stringByAppendingPathComponent:[NSString stringWithFormat:@"Cover%@.png", suffix]];
        [files removeItemAtPath:link error:NULL];
        if (![files createSymbolicLinkAtPath:link withDestinationPath:NRSSCoverPathForFeedID(feedID, suffix.length > 0) error:&error]) {
            fprintf(stderr, "cover link: %s\n", error.localizedDescription.UTF8String);
            [files removeItemAtPath:staging error:NULL];
            return NO;
        }
    }
    if (![info writeToFile:infoPath atomically:YES]) {
        fprintf(stderr, "write Info.plist failed\n");
        [files removeItemAtPath:staging error:NULL];
        return NO;
    }
    [files removeItemAtPath:destination error:NULL];
    if (rename(staging.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
        perror("rename");
        [files removeItemAtPath:staging error:NULL];
        return NO;
    }
    return YES;
}

static NSArray *NRSSInstalledFeedIDs(void) {
    return NRSSInstalledFeeds().allKeys;
}

static BOOL NRSSRefreshApplicationCache(void) {
    pid_t pid = fork();
    if (pid < 0)
        return NO;
    if (pid == 0) {
        // uicache must run as mobile so the installation cache keeps its owner.
        if (setgid(NRSSMobileUID) != 0 || setuid(NRSSMobileUID) != 0)
            _exit(126);
        setenv("HOME", "/var/mobile", 1);
        setenv("USER", "mobile", 1);
        setenv("LOGNAME", "mobile", 1);
        execl("/usr/bin/uicache", "uicache", (char *)NULL);
        _exit(127);
    }
    int status;
    while (waitpid(pid, &status, 0) == -1)
        if (errno != EINTR)
            return NO;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int NRSSUsage(void) {
    fprintf(stderr, "usage: newsstandrss-helper [install <id> <name> | remove <id>]... | reinstall-all | remove-all\n");
    return 64;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        uid_t caller = getuid();
        if (caller != 0 && caller != NRSSMobileUID) {
            fprintf(stderr, "not allowed\n");
            return 77;
        }
        if (setgid(0) != 0 || setuid(0) != 0) {
            fprintf(stderr, "helper is not setuid root\n");
            return 77;
        }
        umask(022);
        if (argc < 2)
            return NRSSUsage();
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        BOOL changed = NO;

        if ([command isEqualToString:@"reinstall-all"] && argc == 2) {
            for (NSString *installed in NRSSInstalledFeedIDs()) {
                NSString *infoPath = [NRSSAppPathForFeedID(installed) stringByAppendingPathComponent:@"Info.plist"];
                NSString *name = [[NSDictionary dictionaryWithContentsOfFile:infoPath] objectForKey:@"CFBundleDisplayName"];
                changed |= NRSSInstall(installed, NRSSCleanName([name isKindOfClass:[NSString class]] ? name : @""));
            }
        } else if ([command isEqualToString:@"remove-all"] && argc == 2) {
            for (NSString *installed in NRSSInstalledFeedIDs())
                changed |= [[NSFileManager defaultManager] removeItemAtPath:NRSSAppPathForFeedID(installed) error:NULL];
        } else {
            // A sequence of "install <id> <name>" and "remove <id>" operations, validated in full before any runs.
            NSMutableArray *operations = [NSMutableArray array];
            for (int i = 1; i < argc;) {
                NSString *verb = [NSString stringWithUTF8String:argv[i]];
                NSString *feedID = i + 1 < argc ? [NSString stringWithUTF8String:argv[i + 1]] : nil;
                if ([verb isEqualToString:@"install"] && i + 2 < argc && NRSSIsValidFeedID(feedID)) {
                    [operations addObject:@[verb, feedID, NRSSCleanName([NSString stringWithUTF8String:argv[i + 2]] ?: @"")]];
                    i += 3;
                } else if ([verb isEqualToString:@"remove"] && NRSSIsValidFeedID(feedID)) {
                    [operations addObject:@[verb, feedID]];
                    i += 2;
                } else {
                    return NRSSUsage();
                }
            }
            int failures = 0;
            for (NSArray *operation in operations) {
                NSString *feedID = [operation objectAtIndex:1];
                if ([[operation objectAtIndex:0] isEqualToString:@"install"]) {
                    if (NRSSInstall(feedID, [operation objectAtIndex:2]))
                        changed = YES;
                    else
                        failures++;
                } else {
                    changed |= [[NSFileManager defaultManager] removeItemAtPath:NRSSAppPathForFeedID(feedID) error:NULL];
                }
            }
            if (failures) {
                if (changed)
                    NRSSRefreshApplicationCache();
                return 1;
            }
        }

        if (changed && !NRSSRefreshApplicationCache()) {
            fprintf(stderr, "uicache failed\n");
            return 2;
        }
        return 0;
    }
}
