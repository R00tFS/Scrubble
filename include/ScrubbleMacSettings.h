#if TARGET_OS_OSX

#import <Cocoa/Cocoa.h>
#import "CredentialStore.h"

@class Scrobbler;

@interface ScrubbleMacSettings : NSWindowController <NSWindowDelegate>

@property (weak) Scrobbler *scrobbler;
@property (copy) void (^onSettingsChanged)(void);

- (instancetype)initWithScrobbler:(Scrobbler *)scrobbler;
- (void)showWindow;

@end

#endif
