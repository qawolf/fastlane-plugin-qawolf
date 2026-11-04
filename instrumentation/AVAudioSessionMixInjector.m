//
//  AVAudioSessionMixInjector.m
//  instrumentation
//
//  Upgrades AVAudioSessionCategoryRecord to AVAudioSessionCategoryPlayAndRecord, and forces
//  AVAudioSessionCategoryOptionMixWithOthers where the category supports it, whenever the app
//  sets its AVAudioSession category.
//
//  AVAudioSession is a single process-wide singleton, so whatever category/options the app
//  sets apply to MockMediaSource's injected AVPlayer too. AVAudioSessionCategoryRecord
//  supports no audio output route at all, which starves the injected player's render graph of
//  output time -- it never gets a chance to deliver the injected audio. Upgrading to
//  .playAndRecord gives the shared hardware I/O unit real output capability. mixWithOthers is
//  only valid for .playback/.playAndRecord/.multiRoute (forcing it onto an incompatible
//  category would make setCategory: fail outright); it keeps the injected player from being
//  treated as a non-mixable session the OS is entitled to tear down.
//
//  Both mutations are gated on MockMediaSource actually having media queued for injection, so
//  an app running under this instrumentation with nothing to inject is left untouched -- an
//  app that depends on staying output-free under .record could otherwise behave differently
//  once silently granted an output route it never asked for.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "utils.h"
#import "camera/MockMediaSource.h"

// Gate for both mutations below: only touch the app's real session while there's an injected
// player to protect.
static BOOL qw_shouldProtectInjectedPlayer(void) {
    return [[MockMediaSource sharedInstance] isMediaInjectionEnabled];
}

static BOOL qw_categorySupportsMixing(AVAudioSessionCategory category) {
    return [category isEqualToString:AVAudioSessionCategoryPlayback] ||
           [category isEqualToString:AVAudioSessionCategoryPlayAndRecord] ||
           [category isEqualToString:AVAudioSessionCategoryMultiRoute];
}

static AVAudioSessionCategoryOptions qw_addMixIfSupported(AVAudioSessionCategory category,
                                                            AVAudioSessionCategoryOptions options) {
    if (!qw_shouldProtectInjectedPlayer()) return options;
    if (!qw_categorySupportsMixing(category)) return options;
    return options | AVAudioSessionCategoryOptionMixWithOthers;
}

// Upgrade .record -> .playAndRecord (see file header for why). Any other category, or no
// active injection, passes through unchanged.
static AVAudioSessionCategory qw_upgradeToPlayAndRecord(AVAudioSessionCategory category) {
    if (!qw_shouldProtectInjectedPlayer()) return category;
    if ([category isEqualToString:AVAudioSessionCategoryRecord]) {
        return AVAudioSessionCategoryPlayAndRecord;
    }
    return category;
}

@implementation AVAudioSession (QAWolfMixWithOthersInjection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [Utils swizzleMethodInClass:[AVAudioSession class]
                   originalSelector:@selector(setCategory:error:)
                   swizzledSelector:@selector(qw_setCategory:error:)];
        [Utils swizzleMethodInClass:[AVAudioSession class]
                   originalSelector:@selector(setCategory:withOptions:error:)
                   swizzledSelector:@selector(qw_setCategory:withOptions:error:)];
        [Utils swizzleMethodInClass:[AVAudioSession class]
                   originalSelector:@selector(setCategory:mode:options:error:)
                   swizzledSelector:@selector(qw_setCategory:mode:options:error:)];
        [Utils swizzleMethodInClass:[AVAudioSession class]
                   originalSelector:@selector(setCategory:mode:routeSharingPolicy:options:error:)
                   swizzledSelector:@selector(qw_setCategory:mode:routeSharingPolicy:options:error:)];
        NSLog(@"QAWolf:AVAudioSessionMix: swizzling complete");
    });
}

// No-options overload has nowhere to carry the extra flag, so route it through the
// options-based overload (itself swizzled below) instead of calling the original straight
// through.
- (BOOL)qw_setCategory:(AVAudioSessionCategory)category error:(NSError **)outError {
    return [self setCategory:category withOptions:0 error:outError];
}

- (BOOL)qw_setCategory:(AVAudioSessionCategory)category
            withOptions:(AVAudioSessionCategoryOptions)options
                  error:(NSError **)outError {
    AVAudioSessionCategory upgraded = qw_upgradeToPlayAndRecord(category);
    AVAudioSessionCategoryOptions merged = qw_addMixIfSupported(upgraded, options);
    return [self qw_setCategory:upgraded withOptions:merged error:outError];
}

- (BOOL)qw_setCategory:(AVAudioSessionCategory)category
                   mode:(AVAudioSessionMode)mode
                options:(AVAudioSessionCategoryOptions)options
                  error:(NSError **)outError {
    AVAudioSessionCategory upgraded = qw_upgradeToPlayAndRecord(category);
    AVAudioSessionCategoryOptions merged = qw_addMixIfSupported(upgraded, options);
    return [self qw_setCategory:upgraded mode:mode options:merged error:outError];
}

- (BOOL)qw_setCategory:(AVAudioSessionCategory)category
                    mode:(AVAudioSessionMode)mode
     routeSharingPolicy:(AVAudioSessionRouteSharingPolicy)policy
                 options:(AVAudioSessionCategoryOptions)options
                   error:(NSError **)outError {
    // Same .record -> .playAndRecord upgrade as the other overloads.
    AVAudioSessionCategory upgraded = qw_upgradeToPlayAndRecord(category);

    // Apple restricts this overload to AVAudioSessionRouteSharingPolicyDefault when any
    // options are set ("options are allowed when changing the routing policy back to
    // Default") -- forcing the flag on a non-default policy would make the call fail, so
    // only add it in the one case it's actually allowed.
    AVAudioSessionCategoryOptions merged = options;
    if (policy == AVAudioSessionRouteSharingPolicyDefault) {
        merged = qw_addMixIfSupported(upgraded, options);
    }
    return [self qw_setCategory:upgraded mode:mode routeSharingPolicy:policy options:merged error:outError];
}

@end
