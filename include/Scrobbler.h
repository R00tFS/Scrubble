#import <Foundation/Foundation.h>
#import <MediaRemote/MediaRemote.h>
#import <TargetConditionals.h>
#import "Constants.h"

#define ScrubbleTrackScrobbledNotification @"ScrubbleTrackScrobbledNotification"
#define ScrubbleNowPlayingChangedNotification @"ScrubbleNowPlayingChangedNotification"
#define ScrubbleScrobbleFailedNotification @"ScrubbleScrobbleFailedNotification"

BOOL SCRMediaRemoteSymbolsAvailable(void);

@interface Scrobbler : NSObject

@property (strong, atomic) NSString *token;
@property (strong, atomic) NSString *apiKey;
@property (strong, atomic) NSString *apiSecret;
@property (strong, atomic) NSString *username;
@property (strong, atomic) NSString *password;
@property (strong, atomic) NSArray<NSString *> *selectedApps;
@property (atomic) float scrobbleAfter;
@property (atomic) bool loggedIn;

@property (strong, atomic, readonly) NSString *lastScrobbledTrack;
@property (strong, atomic, readonly) NSString *lastScrobbledArtist;
@property (strong, atomic, readonly) NSString *lastScrobbledAlbum;
@property (strong, atomic, readonly) NSDate *lastScrobbledDate;

@property (strong, atomic, readonly) NSString *currentTrack;
@property (strong, atomic, readonly) NSString *currentArtist;
@property (strong, atomic, readonly) NSString *currentAlbum;

-(void) registerObserver;
-(void) unregisterObserver;
-(void) musicDidChange:(NSNotification*)notification;
-(void) loadToken;
-(void) scrobbleTrack:(NSString *)music withArtist:(NSString *)artist album:(NSString *)album atTimestamp:(NSString *)timestamp;
-(NSString *) lastScrobbledDisplayString;
-(NSString *) currentPlayingDisplayString;

@end
