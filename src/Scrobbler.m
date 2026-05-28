#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import "Scrobbler.h"
#import "CredentialStore.h"
#import "ScrubbleUtils.h"
#import "MetadataFilter.h"

#define TRACK_CHANGE_DEBOUNCE 1.0
#define TRACK_INFO_DELAY 5.0
#define MIN_SCROBBLE_DURATION 30.0

typedef void (*MRUnregisterFn)(void);
static MRUnregisterFn SCRGetUnregisterFn(void) {
	static MRUnregisterFn fn = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		fn = (MRUnregisterFn)dlsym(RTLD_DEFAULT, "MRMediaRemoteUnregisterForNowPlayingNotifications");
	});
	return fn;
}

BOOL SCRMediaRemoteSymbolsAvailable(void) {
	return dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfo")
		&& dlsym(RTLD_DEFAULT, "MRMediaRemoteRegisterForNowPlayingNotifications");
}

@implementation Scrobbler {
	dispatch_block_t _pendingScrobbleBlock;
	NSDate *_lastNotificationTime;
}

- (void)requestLastfm:(NSMutableDictionary *)params completionHandler:(void(^)(NSData *, NSHTTPURLResponse *, NSError *))completionHandler {
	params[@"sk"] = self.token;
	params[@"api_key"] = self.apiKey;

	NSMutableString *sigRaw = [NSMutableString new];
	for (NSString *key in [params.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
		[sigRaw appendFormat:@"%@%@", key, params[key]];
	}
	[sigRaw appendString:self.apiSecret];

	NSString *payload = [NSString stringWithFormat:@"%@&api_sig=%@", ScrubbleQueryString(params), ScrubbleMD5(sigRaw)];

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LASTFM_API_URL]];
	request.HTTPMethod = @"POST";
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [payload dataUsingEncoding:NSUTF8StringEncoding];

	[[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
		if (resp.statusCode == 403) {
			[self tokenExpired];
			return;
		}
		if (resp.statusCode != 200) {
			NSLog(@"[Scrubble] Error: %ld - %@", (long)resp.statusCode, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
		}
		if (completionHandler) completionHandler(data, resp, error);
	}] resume];
}

#if TARGET_OS_OSX
- (void)postNotification:(NSNotificationName)name track:(NSString *)track artist:(NSString *)artist album:(NSString *)album {
	dispatch_async(dispatch_get_main_queue(), ^{
		[[NSNotificationCenter defaultCenter] postNotificationName:name
			object:self
			userInfo:@{@"track": track ?: @"", @"artist": artist ?: @"", @"album": album ?: @""}];
	});
}
#endif

- (void)updateNowPlaying:(NSString *)music withArtist:(NSString *)artist album:(NSString *)album {
	_currentTrack = music;
	_currentArtist = artist;
	_currentAlbum = album;

	NSMutableDictionary *params = [@{
		@"track": music,
		@"artist": artist,
		@"album": album,
		@"method": @"track.updateNowPlaying"
	} mutableCopy];

	[self requestLastfm:params completionHandler:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
		if (response.statusCode != 200) return;
		NSLog(@"[Scrubble] Updated now playing: %@", music);
#if TARGET_OS_OSX
		[self postNotification:ScrubbleNowPlayingChangedNotification track:music artist:artist album:album];
#endif
	}];
}

- (void)scrobbleTrack:(NSString *)music withArtist:(NSString *)artist album:(NSString *)album atTimestamp:(NSString *)timestamp {
	NSMutableDictionary *params = [@{
		@"track[0]": music,
		@"artist[0]": artist,
		@"album[0]": album,
		@"timestamp[0]": timestamp,
		@"method": @"track.scrobble"
	} mutableCopy];

	[self requestLastfm:params completionHandler:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
		if (response.statusCode == 200) {
			NSLog(@"[Scrubble] Scrobbled: %@", music);
			self->_lastScrobbledTrack = music;
			self->_lastScrobbledArtist = artist;
			self->_lastScrobbledAlbum = album;
			self->_lastScrobbledDate = [NSDate date];
#if TARGET_OS_OSX
			[self postNotification:ScrubbleTrackScrobbledNotification track:music artist:artist album:album];
#endif
			return;
		}
		NSString *reason = error
			? error.localizedDescription
			: [NSString stringWithFormat:@"HTTP %ld %@", (long)response.statusCode, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""];
		NSLog(@"[Scrubble] Scrobble failed: %@ - %@ (%@)", artist, music, reason);
#if TARGET_OS_OSX
		dispatch_async(dispatch_get_main_queue(), ^{
			[[NSNotificationCenter defaultCenter] postNotificationName:ScrubbleScrobbleFailedNotification
				object:self
				userInfo:@{
					@"track": music ?: @"", @"artist": artist ?: @"",
					@"album": album ?: @"", @"timestamp": timestamp ?: @"",
					@"reason": reason ?: @""
				}];
		});
#endif
	}];
}

- (void)scheduleScrobbleTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album date:(NSDate *)date afterSeconds:(NSTimeInterval)delaySeconds {
	dispatch_block_t scrobbleBlock = dispatch_block_create(0, ^{
		[self getCurrentlyPlayingMusicWithcompletionHandler:^(NSString *currentTrack, NSString *currentArtist, NSString *currentAlbum, NSDate *currentDate, NSNumber *currentDuration) {
			if (![currentTrack isEqualToString:track] || ![currentAlbum isEqualToString:album] || ![currentArtist isEqualToString:artist]) return;
			MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
				if (!isPlaying) {
					NSLog(@"[Scrubble] Playback paused, dropping scrobble for '%@'", track);
					return;
				}
				[self scrobbleTrack:track withArtist:artist album:album atTimestamp:[NSString stringWithFormat:@"%f", date.timeIntervalSince1970]];
			});
		}];
	});
	_pendingScrobbleBlock = scrobbleBlock;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), scrobbleBlock);
}

- (void)tokenExpired {
	self.loggedIn = NO;
	self.token = nil;
	[[CredentialStore sharedStore] deleteToken];

	if (self.password.length > 0) {
		dispatch_async(dispatch_get_main_queue(), ^{
			NSLog(@"[Scrubble] Reloading token via mobile session");
			[self loadToken];
		});
	} else {
		NSLog(@"[Scrubble] Token expired — please re-authorize via settings");
	}
}

- (void)loadToken {
	NSString *storedToken = [[CredentialStore sharedStore] token];
	if (storedToken) {
		self.token = storedToken;
		self.loggedIn = YES;
		[self registerObserver];
		NSLog(@"[Scrubble] Found token in keychain");
		return;
	}

	if (!self.password || self.password.length == 0) {
		NSLog(@"[Scrubble] No token and no password — authorize via settings");
		return;
	}

	NSLog(@"[Scrubble] Authenticating with last.fm via mobile session...");
	NSString *sigContent = [NSString stringWithFormat:@"api_key%@method%@password%@username%@%@",
		self.apiKey, @"auth.getMobileSession", self.password, self.username, self.apiSecret];

	NSDictionary *queryParams = @{
		@"method": @"auth.getMobileSession",
		@"username": self.username,
		@"password": self.password,
		@"api_key": self.apiKey,
		@"api_sig": ScrubbleMD5(sigContent),
		@"format": @"json"
	};

	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LASTFM_API_URL]];
	req.HTTPMethod = @"POST";
	[req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	req.HTTPBody = [ScrubbleQueryString(queryParams) dataUsingEncoding:NSUTF8StringEncoding];

	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
		if (resp.statusCode != 200) {
			NSLog(@"[Scrubble] Failed to login");
			return;
		}
		NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
		self.token = dict[@"session"][@"key"];
		self.loggedIn = YES;
		[[CredentialStore sharedStore] setToken:self.token];
		[self registerObserver];
	}] resume];
}

- (void)getCurrentlyPlayingMusicWithcompletionHandler:(void(^)(NSString *, NSString *, NSString *, NSDate *, NSNumber *))completionHandler {
	MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
		if (!info) return;
		NSDictionary *dict = (__bridge NSDictionary *)info;
		NSString *music = dict[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoTitle];
		NSString *artist = dict[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoArtist];
		NSString *album = dict[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoAlbum];
		NSDate *date = dict[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoTimestamp];
		id durationValue = dict[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoDuration];

		if (!music || !artist || !album) return;

		NSNumber *duration = [durationValue isKindOfClass:[NSNumber class]] ? durationValue :
			[durationValue isKindOfClass:[NSString class]] ? @([durationValue doubleValue]) : nil;

		completionHandler(music, artist, album, date, duration);
	});
}

- (void)registerObserver {
	[[NSNotificationCenter defaultCenter] addObserver:self
		selector:@selector(musicDidChange:)
		name:(__bridge NSNotificationName)kMRMediaRemoteNowPlayingInfoDidChangeNotification
		object:nil];
	MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_get_main_queue());

	[self getCurrentlyPlayingMusicWithcompletionHandler:^(NSString *rawTrack, NSString *rawArtist, NSString *rawAlbum, NSDate *date, NSNumber *duration) {
		NSString *track = rawTrack, *artist = rawArtist, *album = rawAlbum;
		if ([[CredentialStore sharedStore] isMetadataFilterEnabled]) {
			MetadataFilter *filter = [MetadataFilter defaultFilter];
			track = [filter filterTrack:rawTrack];
			artist = [filter filterArtist:rawArtist];
			album = [filter filterAlbum:rawAlbum];
		}
		[self updateNowPlaying:track withArtist:artist album:album];

		if (![[CredentialStore sharedStore] isScrobbleOnStartup]) return;

		NSTimeInterval durationSeconds = duration.doubleValue;
		if (durationSeconds < MIN_SCROBBLE_DURATION || !date) return;

		NSTimeInterval elapsed = -[date timeIntervalSinceNow];
		NSTimeInterval delaySeconds = MAX(0, durationSeconds * self.scrobbleAfter - elapsed);
		NSLog(@"[Scrubble] Will scrobble already-playing '%@' in %.0f seconds", track, delaySeconds);
		[self scheduleScrobbleTrack:track artist:artist album:album date:date afterSeconds:delaySeconds];
	}];
}

- (void)unregisterObserver {
	[[NSNotificationCenter defaultCenter] removeObserver:self
		name:(__bridge NSNotificationName)kMRMediaRemoteNowPlayingInfoDidChangeNotification
		object:nil];
	MRUnregisterFn unreg = SCRGetUnregisterFn();
	if (unreg) unreg();
	[self cancelPendingScrobble];
}

- (void)cancelPendingScrobble {
	if (!_pendingScrobbleBlock) return;
	dispatch_block_cancel(_pendingScrobbleBlock);
	_pendingScrobbleBlock = nil;
}

- (void)musicDidChange:(NSNotification *)notification {
	NSDictionary *userInfo = notification.userInfo;
	NSString *originatingNotification = userInfo[@"_MROriginatingNotification"];

	if (![originatingNotification isEqualToString:@"_kMRNowPlayingPlaybackQueueChangedNotification"]) return;

	NSDate *now = [NSDate date];
	if (_lastNotificationTime && [now timeIntervalSinceDate:_lastNotificationTime] < TRACK_CHANGE_DEBOUNCE) return;
	_lastNotificationTime = now;

	NSString *appBID = [userInfo[@"kMRNowPlayingClientUserInfoKey"] bundleIdentifier];
	if (self.selectedApps && ![self.selectedApps containsObject:appBID]) return;

	[self cancelPendingScrobble];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TRACK_INFO_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
			if (!isPlaying) {
				NSLog(@"[Scrubble] Track-change notification but nothing is playing, ignoring");
				return;
			}
			[self getCurrentlyPlayingMusicWithcompletionHandler:^(NSString *rawTrack, NSString *rawArtist, NSString *rawAlbum, NSDate *date, NSNumber *duration) {
				NSString *track = rawTrack, *artist = rawArtist, *album = rawAlbum;
				if ([[CredentialStore sharedStore] isMetadataFilterEnabled]) {
					MetadataFilter *filter = [MetadataFilter defaultFilter];
					track = [filter filterTrack:rawTrack];
					artist = [filter filterArtist:rawArtist];
					album = [filter filterAlbum:rawAlbum];
				}
				[self updateNowPlaying:track withArtist:artist album:album];

				NSTimeInterval durationSeconds = duration.doubleValue;
				if (durationSeconds < MIN_SCROBBLE_DURATION) return;

				NSTimeInterval delaySeconds = durationSeconds * self.scrobbleAfter;
				NSLog(@"[Scrubble] Will scrobble '%@' in %.0f seconds", track, delaySeconds);
				[self scheduleScrobbleTrack:track artist:artist album:album date:date afterSeconds:delaySeconds];
			}];
		});
	});
}

- (NSString *)lastScrobbledDisplayString {
	if (!_lastScrobbledTrack) return @"No tracks scrobbled yet";
	return [NSString stringWithFormat:@"%@ - %@", _lastScrobbledArtist ?: @"Unknown Artist", _lastScrobbledTrack];
}

- (NSString *)currentPlayingDisplayString {
	if (!_currentTrack) return @"Nothing playing";
	return [NSString stringWithFormat:@"%@ - %@", _currentArtist ?: @"Unknown Artist", _currentTrack];
}

@end
