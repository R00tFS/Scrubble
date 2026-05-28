#import "CredentialStore.h"

NSString *const kCredentialKeyUsername = @"username";
NSString *const kCredentialKeyPassword = @"password";
NSString *const kCredentialKeyAPIKey = @"apiKey";
NSString *const kCredentialKeyAPISecret = @"apiSecret";
NSString *const kCredentialKeyToken = @"token";
NSString *const kCredentialKeyEnabled = @"enabled";
NSString *const kCredentialKeyScrobbleAfter = @"scrobbleAfter";
NSString *const kCredentialKeyEnabledApps = @"enabledApplications";
NSString *const kCredentialKeyNotificationsEnabled = @"notificationsEnabled";
NSString *const kCredentialKeyMetadataFilterEnabled = @"metadataFilterEnabled";
NSString *const kCredentialKeyScrobbleOnStartup = @"scrobbleOnStartup";

@implementation CredentialStore {
    NSUserDefaults *_cachedDefaults;
}

+ (instancetype)sharedStore {
    static CredentialStore *sharedStore = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedStore = [[CredentialStore alloc] init];
    });
    return sharedStore;
}

- (BOOL)setKeychainValue:(NSString *)value forKey:(NSString *)key {
    if (!value || !key) return NO;
    [self deleteKeychainValueForKey:key];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecAttrService: BUNDLE_ID,
        (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
#if TARGET_OS_OSX
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
#else
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
#endif
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess) {
        NSLog(@"[Scrubble] Failed to save %@ to keychain: %d", key, (int)status);
        return NO;
    }
    return YES;
}

- (NSString *)keychainValueForKey:(NSString *)key {
    if (!key) return nil;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecAttrService: BUNDLE_ID,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

    if (status == errSecSuccess && result != NULL) {
        return [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding];
    }

    if (status != errSecItemNotFound) {
        NSLog(@"[Scrubble] Keychain read failed for %@: %d", key, (int)status);
    }

    return nil;
}

- (BOOL)deleteKeychainValueForKey:(NSString *)key {
    if (!key) return NO;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecAttrService: BUNDLE_ID,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return (status == errSecSuccess || status == errSecItemNotFound);
}

- (NSUserDefaults *)preferencesStore {
    if (!_cachedDefaults) {
        _cachedDefaults = [[NSUserDefaults alloc] initWithSuiteName:PREFS_BUNDLE_ID];
    }
    return _cachedDefaults;
}

- (void)setPreferenceValue:(id)value forKey:(NSString *)key {
    [[self preferencesStore] setObject:value forKey:key];
    [[self preferencesStore] synchronize];
}

- (id)preferenceValueForKey:(NSString *)key {
    return [[self preferencesStore] objectForKey:key];
}

- (void)setUsername:(NSString *)username {
#if TARGET_OS_OSX
    [self setKeychainValue:username forKey:kCredentialKeyUsername];
#else
    [self setPreferenceValue:username forKey:kCredentialKeyUsername];
#endif
}

- (NSString *)username {
#if TARGET_OS_OSX
    return [self keychainValueForKey:kCredentialKeyUsername];
#else
    return [self preferenceValueForKey:kCredentialKeyUsername];
#endif
}

- (void)setPassword:(NSString *)password {
#if TARGET_OS_OSX
    [self setKeychainValue:password forKey:kCredentialKeyPassword];
#else
    [self setPreferenceValue:password forKey:kCredentialKeyPassword];
#endif
}

- (NSString *)password {
#if TARGET_OS_OSX
    return [self keychainValueForKey:kCredentialKeyPassword];
#else
    return [self preferenceValueForKey:kCredentialKeyPassword];
#endif
}

- (void)setAPIKey:(NSString *)apiKey {
#if TARGET_OS_OSX
    [self setKeychainValue:apiKey forKey:kCredentialKeyAPIKey];
#else
    [self setPreferenceValue:apiKey forKey:kCredentialKeyAPIKey];
#endif
}

- (NSString *)apiKey {
#if TARGET_OS_OSX
    return [self keychainValueForKey:kCredentialKeyAPIKey];
#else
    return [self preferenceValueForKey:kCredentialKeyAPIKey];
#endif
}

- (void)setAPISecret:(NSString *)apiSecret {
#if TARGET_OS_OSX
    [self setKeychainValue:apiSecret forKey:kCredentialKeyAPISecret];
#else
    [self setPreferenceValue:apiSecret forKey:kCredentialKeyAPISecret];
#endif
}

- (NSString *)apiSecret {
#if TARGET_OS_OSX
    return [self keychainValueForKey:kCredentialKeyAPISecret];
#else
    return [self preferenceValueForKey:kCredentialKeyAPISecret];
#endif
}

- (void)setToken:(NSString *)token {
    [self setKeychainValue:token forKey:kCredentialKeyToken];
}

- (NSString *)token {
    return [self keychainValueForKey:kCredentialKeyToken];
}

- (void)deleteToken {
    [self deleteKeychainValueForKey:kCredentialKeyToken];
}

- (void)setEnabled:(BOOL)enabled {
    [self setPreferenceValue:@(enabled) forKey:kCredentialKeyEnabled];
}

- (BOOL)isEnabled {
    id value = [self preferenceValueForKey:kCredentialKeyEnabled];
    return value ? [value boolValue] : YES;
}

- (void)setScrobbleAfter:(float)percentage {
    [self setPreferenceValue:@(percentage) forKey:kCredentialKeyScrobbleAfter];
}

- (float)scrobbleAfter {
    id value = [self preferenceValueForKey:kCredentialKeyScrobbleAfter];
    return value ? [value floatValue] : 0.7f;
}

- (void)setEnabledApps:(NSArray<NSString *> *)apps {
    [self setPreferenceValue:apps forKey:kCredentialKeyEnabledApps];
}

- (NSArray<NSString *> *)enabledApps {
    return [self preferenceValueForKey:kCredentialKeyEnabledApps];
}

- (void)setNotificationsEnabled:(BOOL)enabled {
    [self setPreferenceValue:@(enabled) forKey:kCredentialKeyNotificationsEnabled];
}

- (BOOL)isNotificationsEnabled {
    id value = [self preferenceValueForKey:kCredentialKeyNotificationsEnabled];
    return value ? [value boolValue] : YES;
}

- (void)setMetadataFilterEnabled:(BOOL)enabled {
    [self setPreferenceValue:@(enabled) forKey:kCredentialKeyMetadataFilterEnabled];
}

- (BOOL)isMetadataFilterEnabled {
    id value = [self preferenceValueForKey:kCredentialKeyMetadataFilterEnabled];
    return value ? [value boolValue] : YES;
}

- (void)setScrobbleOnStartup:(BOOL)enabled {
    [self setPreferenceValue:@(enabled) forKey:kCredentialKeyScrobbleOnStartup];
}

- (BOOL)isScrobbleOnStartup {
    id value = [self preferenceValueForKey:kCredentialKeyScrobbleOnStartup];
    return value ? [value boolValue] : NO;
}

- (BOOL)isKeychainAccessible {
    static NSString *const kTestKey = @"_scrubble_keychain_test";
    BOOL writeOK = [self setKeychainValue:@"1" forKey:kTestKey];
    [self deleteKeychainValueForKey:kTestKey];
    return writeOK;
}

- (NSDictionary *)allCredentials {
    return @{
        kCredentialKeyUsername: [self username] ?: @"",
        kCredentialKeyPassword: [self password] ?: @"",
        kCredentialKeyAPIKey: [self apiKey] ?: @"",
        kCredentialKeyAPISecret: [self apiSecret] ?: @"",
        kCredentialKeyToken: [self token] ?: @"",
    };
}

- (void)clearAllCredentials {
    [self deleteKeychainValueForKey:kCredentialKeyUsername];
    [self deleteKeychainValueForKey:kCredentialKeyPassword];
    [self deleteKeychainValueForKey:kCredentialKeyAPIKey];
    [self deleteKeychainValueForKey:kCredentialKeyAPISecret];
    [self deleteKeychainValueForKey:kCredentialKeyToken];
}

@end
