#import <TargetConditionals.h>
#if TARGET_OS_OSX

#import "ScrubbleMacSettings.h"
#import "Scrobbler.h"
#import "ScrubbleUtils.h"

static NSDictionary<NSString *, NSString *> *kSupportedApps(void) {
    return @{
        @"com.apple.Music": @"Apple Music",
        @"org.videolan.vlc": @"VLC",
        @"com.foobar2000.mac": @"foobar2000"
    };
}

@interface ScrubbleMacSettings ()

@property (strong) NSTextField *apiKeyField;
@property (strong) NSSecureTextField *apiSecretField;
@property (strong) NSButton *authorizeButton;
@property (strong) NSButton *completeAuthButton;
@property (strong) NSTextField *usernameField;
@property (strong) NSSecureTextField *passwordField;
@property (strong) NSSlider *scrobbleAfterSlider;
@property (strong) NSTextField *scrobbleAfterLabel;
@property (strong) NSButton *enabledCheckbox;
@property (strong) NSButton *notificationsCheckbox;
@property (strong) NSButton *metadataFilterCheckbox;
@property (strong) NSButton *scrobbleOnStartupCheckbox;
@property (strong) NSButton *testLoginButton;
@property (strong) NSTextField *statusLabel;
@property (strong) NSMutableDictionary<NSString *, NSButton *> *appCheckboxes;
@property (strong) NSString *pendingAuthToken;

@end

@implementation ScrubbleMacSettings

- (instancetype)initWithScrobbler:(Scrobbler *)scrobbler {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 450, 675)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _scrobbler = scrobbler;
        _appCheckboxes = [NSMutableDictionary new];
        [self setupWindow];
        [self loadSettings];
    }
    return self;
}

- (void)setupWindow {
    NSWindow *window = self.window;
    window.title = @"Scrubble Settings";
    [window center];
    window.delegate = self;

    NSView *cv = window.contentView;
    const CGFloat kPad = 20;
    const CGFloat kLblW = 100;
    const CGFloat kFldW = 300;
    const CGFloat kFldX = kPad + kLblW + 10;
    __block CGFloat y = 635;

    NSButton *(^addCheckbox)(NSString *, CGFloat, CGFloat) = ^(NSString *title, CGFloat gap, CGFloat indent) {
        y -= gap;
        NSButton *cb = [NSButton checkboxWithTitle:title target:nil action:nil];
        cb.frame = NSMakeRect(kPad + indent, y, kFldW + kLblW - indent, 20);
        [cv addSubview:cb];
        return cb;
    };

    NSTextField *(^addField)(NSString *, NSString *, BOOL, CGFloat) = ^(NSString *labelText, NSString *placeholder, BOOL secure, CGFloat gap) {
        y -= gap;
        NSTextField *lbl = [NSTextField labelWithString:labelText];
        lbl.frame = NSMakeRect(kPad, y, kLblW, 20);
        [cv addSubview:lbl];
        NSRect r = NSMakeRect(kFldX, y, kFldW, 22);
        NSTextField *fld = secure ? [[NSSecureTextField alloc] initWithFrame:r] : [[NSTextField alloc] initWithFrame:r];
        fld.placeholderString = placeholder;
        [cv addSubview:fld];
        return fld;
    };

    NSButton *(^addButton)(NSString *, CGFloat, CGFloat, CGFloat, SEL, NSBezelStyle) = ^(NSString *title, CGFloat x, CGFloat width, CGFloat gap, SEL action, NSBezelStyle bezel) {
        if (gap > 0) y -= gap;
        NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(x, y, width, bezel == NSBezelStyleInline ? 20 : 30)];
        b.title = title;
        b.bezelStyle = bezel;
        b.target = self;
        b.action = action;
        [cv addSubview:b];
        return b;
    };

    NSTextField *(^addLabel)(NSString *, CGFloat, NSColor *, NSFont *) = ^(NSString *text, CGFloat gap, NSColor *color, NSFont *font) {
        y -= gap;
        NSTextField *lbl = [NSTextField labelWithString:text];
        lbl.frame = NSMakeRect(kPad, y, kFldW + kLblW, 20);
        if (color) lbl.textColor = color;
        if (font) lbl.font = font;
        [cv addSubview:lbl];
        return lbl;
    };

    // --- Toggles ---
    _enabledCheckbox = addCheckbox(@"Enable Scrobbling", 30, 0);
    _notificationsCheckbox = addCheckbox(@"Show Notifications", 25, 0);
    _metadataFilterCheckbox = addCheckbox(@"Filter Metadata (remove Remastered, Live, etc.)", 25, 0);
    _scrobbleOnStartupCheckbox = addCheckbox(@"Scrobble current track on launch", 25, 0);

    // --- API Credentials ---
    _apiKeyField = addField(@"API Key:", @"Last.fm API key", NO, 35);
    _apiSecretField = (NSSecureTextField *)addField(@"API Secret:", @"Last.fm API secret", YES, 35);
    addButton(@"Get API Key from Last.fm", kFldX, 200, 25, @selector(openAPIKeyPage:), NSBezelStyleInline);

    // --- OAuth Authorization ---
    _authorizeButton = addButton(@"Authorize with Last.fm", kPad, 170, 40, @selector(authorizeWithLastfm:), NSBezelStyleRounded);
    _completeAuthButton = addButton(@"Complete Authorization", kPad + 180, 170, 0, @selector(completeAuthorization:), NSBezelStyleRounded);
    _completeAuthButton.hidden = YES;
    _statusLabel = addLabel(@"", 25, NSColor.secondaryLabelColor, nil);

    // --- Password Auth (optional) ---
    y -= 30;
    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y, kFldW + kLblW, 1)];
    separator.boxType = NSBoxSeparator;
    [cv addSubview:separator];
    addLabel(@"Password Auth (optional)", 25, NSColor.secondaryLabelColor, [NSFont systemFontOfSize:11]);

    _usernameField = addField(@"Username:", @"Last.fm username", NO, 30);
    _passwordField = (NSSecureTextField *)addField(@"Password:", @"Last.fm password", YES, 35);
    _testLoginButton = addButton(@"Test Login", kPad, 120, 30, @selector(testLogin:), NSBezelStyleRounded);

    // --- Scrobble Settings ---
    y -= 45;
    NSTextField *scrobbleLabel = [NSTextField labelWithString:@"Scrobble After:"];
    scrobbleLabel.frame = NSMakeRect(kPad, y, kLblW, 20);
    [cv addSubview:scrobbleLabel];

    _scrobbleAfterSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(kFldX, y, kFldW - 50, 20)];
    _scrobbleAfterSlider.minValue = 0.0;
    _scrobbleAfterSlider.maxValue = 1.0;
    _scrobbleAfterSlider.doubleValue = 0.7;
    _scrobbleAfterSlider.target = self;
    _scrobbleAfterSlider.action = @selector(sliderChanged:);
    [cv addSubview:_scrobbleAfterSlider];

    _scrobbleAfterLabel = [NSTextField labelWithString:@"70%"];
    _scrobbleAfterLabel.frame = NSMakeRect(kPad + kLblW + kFldW - 30, y, 50, 20);
    [cv addSubview:_scrobbleAfterLabel];

    addLabel(@"Scrobble from:", 35, nil, [NSFont boldSystemFontOfSize:12]);

    NSDictionary *apps = kSupportedApps();
    for (NSString *bundleID in [apps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSButton *cb = addCheckbox(apps[bundleID], 25, 20);
        cb.state = NSControlStateValueOn;
        _appCheckboxes[bundleID] = cb;
    }

    // --- Save / Cancel ---
    NSButton *saveButton = addButton(@"Save", kPad + kFldW + kLblW - 90, 100, 45, @selector(saveSettings:), NSBezelStyleRounded);
    saveButton.keyEquivalent = @"\r";

    NSButton *cancelButton = addButton(@"Cancel", kPad + kFldW + kLblW - 200, 100, 0, @selector(cancelSettings:), NSBezelStyleRounded);
    cancelButton.keyEquivalent = @"\033";
}

- (void)loadSettings {
    CredentialStore *store = [CredentialStore sharedStore];

    _apiKeyField.stringValue = [store apiKey] ?: @"";
    _apiSecretField.stringValue = [store apiSecret] ?: @"";
    _usernameField.stringValue = [store username] ?: @"";
    _passwordField.stringValue = [store password] ?: @"";
    _scrobbleAfterSlider.doubleValue = [store scrobbleAfter];
    _enabledCheckbox.state = [store isEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _notificationsCheckbox.state = [store isNotificationsEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _metadataFilterCheckbox.state = [store isMetadataFilterEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    _scrobbleOnStartupCheckbox.state = [store isScrobbleOnStartup] ? NSControlStateValueOn : NSControlStateValueOff;

    NSArray *enabledApps = [store enabledApps];
    for (NSString *bundleID in _appCheckboxes) {
        NSButton *checkbox = _appCheckboxes[bundleID];
        checkbox.state = (!enabledApps || [enabledApps containsObject:bundleID]) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    [self updateScrobbleAfterLabel];

    // Show auth status
    if ([store token]) {
        NSString *user = [store username];
        _statusLabel.stringValue = user.length > 0 ? [NSString stringWithFormat:@"Authorized as %@", user] : @"Authorized";
        _statusLabel.textColor = NSColor.systemGreenColor;
    }
}

- (void)saveSettings:(id)sender {
    CredentialStore *store = [CredentialStore sharedStore];

    [store setAPIKey:_apiKeyField.stringValue];
    [store setAPISecret:_apiSecretField.stringValue];
    [store setUsername:_usernameField.stringValue];
    [store setPassword:_passwordField.stringValue];
    [store setScrobbleAfter:_scrobbleAfterSlider.floatValue];
    [store setEnabled:_enabledCheckbox.state == NSControlStateValueOn];
    [store setNotificationsEnabled:_notificationsCheckbox.state == NSControlStateValueOn];
    [store setMetadataFilterEnabled:_metadataFilterCheckbox.state == NSControlStateValueOn];
    [store setScrobbleOnStartup:_scrobbleOnStartupCheckbox.state == NSControlStateValueOn];

    NSMutableArray *enabledApps = [NSMutableArray new];
    for (NSString *bundleID in _appCheckboxes) {
        if (_appCheckboxes[bundleID].state == NSControlStateValueOn) {
            [enabledApps addObject:bundleID];
        }
    }
    [store setEnabledApps:enabledApps];

    if (self.onSettingsChanged) {
        self.onSettingsChanged();
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("fr.rootfs.scrubbleprefs-updated"),
                                         NULL, NULL, true);

    [self.window close];
}

- (void)cancelSettings:(id)sender {
    [self.window close];
}

- (void)setStatus:(NSString *)text color:(NSColor *)color {
    _statusLabel.stringValue = text;
    _statusLabel.textColor = color;
}

- (void)postLastfm:(NSDictionary *)params completion:(void(^)(NSDictionary *json, NSHTTPURLResponse *http))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LASTFM_API_URL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [ScrubbleQueryString(params) dataUsingEncoding:NSUTF8StringEncoding];

    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(json, http);
        });
    }] resume];
}

- (void)authorizeWithLastfm:(id)sender {
    NSString *apiKey = _apiKeyField.stringValue;
    NSString *apiSecret = _apiSecretField.stringValue;

    if (apiKey.length == 0 || apiSecret.length == 0) {
        [self setStatus:@"API Key and Secret are required" color:NSColor.systemRedColor];
        return;
    }

    _authorizeButton.enabled = NO;
    [self setStatus:@"Requesting token..." color:NSColor.secondaryLabelColor];

    NSString *sigContent = [NSString stringWithFormat:@"api_key%@methodauth.getToken%@", apiKey, apiSecret];
    NSDictionary *params = @{
        @"method": @"auth.getToken",
        @"api_key": apiKey,
        @"api_sig": ScrubbleMD5(sigContent),
        @"format": @"json"
    };

    [self postLastfm:params completion:^(NSDictionary *json, NSHTTPURLResponse *http) {
        self->_authorizeButton.enabled = YES;
        if (http.statusCode != 200 || !json) {
            [self setStatus:@"Failed to get token" color:NSColor.systemRedColor];
            return;
        }
        NSString *token = json[@"token"];
        if (!token) {
            [self setStatus:json[@"message"] ?: @"Failed to get token" color:NSColor.systemRedColor];
            return;
        }
        self->_pendingAuthToken = token;
        NSString *authURL = [NSString stringWithFormat:@"https://www.last.fm/api/auth/?api_key=%@&token=%@", apiKey, token];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:authURL]];
        [self setStatus:@"Authorize in browser, then click Complete" color:NSColor.systemOrangeColor];
        self->_completeAuthButton.hidden = NO;
    }];
}

- (void)completeAuthorization:(id)sender {
    NSString *apiKey = _apiKeyField.stringValue;
    NSString *apiSecret = _apiSecretField.stringValue;

    if (!_pendingAuthToken) {
        [self setStatus:@"No pending authorization" color:NSColor.systemRedColor];
        return;
    }

    _completeAuthButton.enabled = NO;
    [self setStatus:@"Completing authorization..." color:NSColor.secondaryLabelColor];

    NSString *sigContent = [NSString stringWithFormat:@"api_key%@methodauth.getSessiontoken%@%@",
                            apiKey, _pendingAuthToken, apiSecret];
    NSDictionary *params = @{
        @"method": @"auth.getSession",
        @"api_key": apiKey,
        @"token": _pendingAuthToken,
        @"api_sig": ScrubbleMD5(sigContent),
        @"format": @"json"
    };

    [self postLastfm:params completion:^(NSDictionary *json, NSHTTPURLResponse *http) {
        self->_completeAuthButton.enabled = YES;
        if (http.statusCode != 200 || !json) {
            [self setStatus:@"Authorization failed" color:NSColor.systemRedColor];
            return;
        }
        NSDictionary *session = json[@"session"];
        if (!session) {
            [self setStatus:json[@"message"] ?: @"Authorization failed" color:NSColor.systemRedColor];
            return;
        }
        NSString *sessionKey = session[@"key"];
        NSString *username = session[@"name"];

        CredentialStore *store = [CredentialStore sharedStore];
        [store setToken:sessionKey];
        if (username) {
            [store setUsername:username];
            self->_usernameField.stringValue = username;
        }

        self->_pendingAuthToken = nil;
        self->_completeAuthButton.hidden = YES;
        [self setStatus:[NSString stringWithFormat:@"Authorized as %@!", username ?: @"unknown"] color:NSColor.systemGreenColor];
    }];
}

- (void)testLogin:(id)sender {
    NSString *username = _usernameField.stringValue;
    NSString *password = _passwordField.stringValue;
    NSString *apiKey = _apiKeyField.stringValue;
    NSString *apiSecret = _apiSecretField.stringValue;

    if (username.length == 0 || password.length == 0 || apiKey.length == 0 || apiSecret.length == 0) {
        [self setStatus:@"Please fill all fields" color:NSColor.systemRedColor];
        return;
    }

    _testLoginButton.enabled = NO;
    [self setStatus:@"Testing..." color:NSColor.secondaryLabelColor];

    NSString *sigContent = [NSString stringWithFormat:@"api_key%@method%@password%@username%@%@",
                            apiKey, @"auth.getMobileSession", password, username, apiSecret];
    NSDictionary *params = @{
        @"method": @"auth.getMobileSession",
        @"username": username,
        @"password": password,
        @"api_key": apiKey,
        @"api_sig": ScrubbleMD5(sigContent),
        @"format": @"json"
    };

    [self postLastfm:params completion:^(NSDictionary *json, NSHTTPURLResponse *http) {
        self->_testLoginButton.enabled = YES;
        if (http.statusCode != 200) {
            [self setStatus:[NSString stringWithFormat:@"Error: %ld", (long)http.statusCode] color:NSColor.systemRedColor];
            return;
        }
        if (json[@"session"]) {
            [self setStatus:@"Login successful!" color:NSColor.systemGreenColor];
        } else {
            [self setStatus:json[@"message"] ?: @"Unknown error" color:NSColor.systemRedColor];
        }
    }];
}

- (void)sliderChanged:(id)sender {
    [self updateScrobbleAfterLabel];
}

- (void)updateScrobbleAfterLabel {
    int percentage = (int)(_scrobbleAfterSlider.doubleValue * 100);
    _scrobbleAfterLabel.stringValue = [NSString stringWithFormat:@"%d%%", percentage];
}

- (void)openAPIKeyPage:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://www.last.fm/api/account/create"]];
}

- (void)showWindow {
    [self loadSettings];
    _pendingAuthToken = nil;
    _completeAuthButton.hidden = YES;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

@end

#endif
