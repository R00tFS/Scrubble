#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "Constants.h"

extern NSString *const kCredentialKeyUsername;
extern NSString *const kCredentialKeyPassword;
extern NSString *const kCredentialKeyAPIKey;
extern NSString *const kCredentialKeyAPISecret;
extern NSString *const kCredentialKeyToken;
extern NSString *const kCredentialKeyEnabled;
extern NSString *const kCredentialKeyScrobbleAfter;
extern NSString *const kCredentialKeyEnabledApps;
extern NSString *const kCredentialKeyNotificationsEnabled;
extern NSString *const kCredentialKeyMetadataFilterEnabled;
extern NSString *const kCredentialKeyScrobbleOnStartup;

@interface CredentialStore : NSObject

+ (instancetype)sharedStore;

- (BOOL)setKeychainValue:(NSString *)value forKey:(NSString *)key;
- (NSString *)keychainValueForKey:(NSString *)key;
- (BOOL)deleteKeychainValueForKey:(NSString *)key;

- (void)setPreferenceValue:(id)value forKey:(NSString *)key;
- (id)preferenceValueForKey:(NSString *)key;

- (void)setUsername:(NSString *)username;
- (NSString *)username;
- (void)setPassword:(NSString *)password;
- (NSString *)password;
- (void)setAPIKey:(NSString *)apiKey;
- (NSString *)apiKey;
- (void)setAPISecret:(NSString *)apiSecret;
- (NSString *)apiSecret;
- (void)setToken:(NSString *)token;
- (NSString *)token;
- (void)deleteToken;

- (void)setEnabled:(BOOL)enabled;
- (BOOL)isEnabled;
- (void)setScrobbleAfter:(float)percentage;
- (float)scrobbleAfter;
- (void)setEnabledApps:(NSArray<NSString *> *)apps;
- (NSArray<NSString *> *)enabledApps;

- (void)setNotificationsEnabled:(BOOL)enabled;
- (BOOL)isNotificationsEnabled;
- (void)setMetadataFilterEnabled:(BOOL)enabled;
- (BOOL)isMetadataFilterEnabled;
- (void)setScrobbleOnStartup:(BOOL)enabled;
- (BOOL)isScrobbleOnStartup;

- (BOOL)isKeychainAccessible;

- (NSDictionary *)allCredentials;
- (void)clearAllCredentials;

@end
