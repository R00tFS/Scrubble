#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import "Scrobbler.h"
#import "CredentialStore.h"

#if TARGET_OS_OSX

#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import "ScrubbleMacSettings.h"

#else

#import <objc/objc.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#endif

static BOOL enabled;
static BOOL mediaRemoteAvailable = YES;
static Scrobbler *scrobbler;

void initScrobbler(NSString *apiKey, NSString *apiSecret, NSString *username, NSString *password, float scrobbleAfter, NSArray *apps) {
	if (!mediaRemoteAvailable) return;
	if (!scrobbler) scrobbler = [[Scrobbler alloc] init];
	scrobbler.apiKey = apiKey;
	scrobbler.apiSecret = apiSecret;
	scrobbler.username = username;
	scrobbler.password = password;
	scrobbler.loggedIn = false;
	scrobbler.scrobbleAfter = scrobbleAfter;
	scrobbler.selectedApps = apps;
	[scrobbler loadToken];
}

void updatePrefs() {
#if TARGET_OS_OSX
	CredentialStore *store = [CredentialStore sharedStore];
	enabled = [store isEnabled];

	NSString *apiKey = [store apiKey];
	NSString *apiSecret = [store apiSecret];
	NSString *username = [store username];
	NSString *password = [store password];
	float scrobbleAfter = [store scrobbleAfter];
	NSArray *apps = [store enabledApps];
#else

#ifdef JAILED
	NSDictionary *const prefs = [[NSDictionary alloc] initWithContentsOfFile:@"ScrubblePrefs"] ?: [[NSDictionary alloc] init];
#else
	NSUserDefaults *const prefs = [[NSUserDefaults alloc] initWithSuiteName:PREFS_BUNDLE_ID];
#endif
	enabled = (prefs && [prefs objectForKey:@"enabled"]) ? [[prefs valueForKey:@"enabled"] boolValue] : YES;

	NSString *apiKey = [prefs objectForKey:@"apiKey"];
	NSString *apiSecret = [prefs objectForKey:@"apiSecret"];
	NSString *username = [prefs objectForKey:@"username"];
	NSString *password = [prefs objectForKey:@"password"];
	float scrobbleAfter = [prefs objectForKey:@"scrobbleAfter"] ? [[prefs objectForKey:@"scrobbleAfter"] floatValue] : 0.7;
	NSArray *apps = [prefs objectForKey:@"enabledApplications"];

	// Sync prefs to CredentialStore for the daemon
	NSString *oauthToken = [prefs objectForKey:@"token"];
	if (oauthToken) {
		[[CredentialStore sharedStore] setToken:oauthToken];
	}
	id metadataFilterPref = [prefs objectForKey:@"metadataFilterEnabled"];
	[[CredentialStore sharedStore] setMetadataFilterEnabled:metadataFilterPref ? [metadataFilterPref boolValue] : YES];
	id scrobbleOnStartupPref = [prefs objectForKey:@"scrobbleOnStartup"];
	[[CredentialStore sharedStore] setScrobbleOnStartup:scrobbleOnStartupPref ? [scrobbleOnStartupPref boolValue] : NO];
#endif

	if (!apiKey || !apiSecret || !enabled) { enabled = NO; return; }
	// Allow token-only init (OAuth) — no password needed if token exists
	NSString *existingToken = [[CredentialStore sharedStore] token];
	if (!existingToken && (!username || !password)) { enabled = NO; return; }
	initScrobbler(apiKey, apiSecret, username ?: @"", password ?: @"", scrobbleAfter, apps);
}

#if TARGET_OS_OSX

static NSString *launchAgentPlistPath(void) {
	return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/fr.rootfs.scrubble.plist"];
}

static BOOL isLaunchAgentInstalled(void) {
	return [[NSFileManager defaultManager] fileExistsAtPath:launchAgentPlistPath()];
}

static void setLaunchAgentEnabled(BOOL enable) {
	NSString *path = launchAgentPlistPath();
	if (enable) {
		NSDictionary *plist = @{
			@"Label": BUNDLE_ID,
			@"ProgramArguments": @[@"/usr/bin/open", [[NSBundle mainBundle] bundlePath]],
			@"RunAtLoad": @YES,
		};
		[plist writeToFile:path atomically:YES];
	} else {
		[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
	}
}

@interface ScrubbleMenuBarController : NSObject <NSMenuDelegate, UNUserNotificationCenterDelegate>

@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *statusMenu;
@property (strong) NSMenuItem *lastScrobbledItem;
@property (strong) NSMenuItem *nowPlayingItem;
@property (strong) NSMenuItem *enabledItem;
@property (strong) NSMenuItem *launchAtLoginItem;
@property (strong) NSMenuItem *notificationsItem;
@property (strong) ScrubbleMacSettings *settingsWindow;

+ (instancetype)sharedController;
- (void)setupMenuBar;
- (void)updateMenuItems;

@end

@implementation ScrubbleMenuBarController

+ (instancetype)sharedController {
    static ScrubbleMenuBarController *sharedController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedController = [[ScrubbleMenuBarController alloc] init];
    });
    return sharedController;
}

- (BOOL)isLaunchAtLoginEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return isLaunchAgentInstalled();
}

- (void)setupMenuBar {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];

    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageNamed:@"StatusBarIcon"];
        if (!img) img = [[NSImage alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"StatusBarIcon" ofType:@"png"]];
        [img setTemplate:YES];
        _statusItem.button.image = img;
    } else {
        _statusItem.button.title = @"Scrubble";
    }

    _statusItem.button.toolTip = @"Scrubble - Last.fm Scrobbler";

    _statusMenu = [[NSMenu alloc] init];
    _statusMenu.delegate = self;

    _nowPlayingItem = [[NSMenuItem alloc] initWithTitle:@"Now Playing: Nothing" action:nil keyEquivalent:@""];
    _nowPlayingItem.enabled = NO;
    [_statusMenu addItem:_nowPlayingItem];

    _lastScrobbledItem = [[NSMenuItem alloc] initWithTitle:@"Last Scrobbled: None" action:nil keyEquivalent:@""];
    _lastScrobbledItem.enabled = NO;
    [_statusMenu addItem:_lastScrobbledItem];

    NSMenuItem *openLibraryItem = [[NSMenuItem alloc] initWithTitle:@"Open Library" action:@selector(openLibrary:) keyEquivalent:@"l"];
    openLibraryItem.target = self;
    [_statusMenu addItem:openLibraryItem];

    [_statusMenu addItem:[NSMenuItem separatorItem]];

    _enabledItem = [[NSMenuItem alloc] initWithTitle:@"Scrobbling Enabled" action:@selector(toggleEnabled:) keyEquivalent:@"e"];
    _enabledItem.target = self;
    _enabledItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [_statusMenu addItem:_enabledItem];

    _launchAtLoginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    _launchAtLoginItem.target = self;
    _launchAtLoginItem.state = [self isLaunchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [_statusMenu addItem:_launchAtLoginItem];

    _notificationsItem = [[NSMenuItem alloc] initWithTitle:@"Show Notifications" action:@selector(toggleNotifications:) keyEquivalent:@""];
    _notificationsItem.target = self;
    _notificationsItem.state = [[CredentialStore sharedStore] isNotificationsEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [_statusMenu addItem:_notificationsItem];

    [_statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings..." action:@selector(openSettings:) keyEquivalent:@","];
    settingsItem.target = self;
    [_statusMenu addItem:settingsItem];

    [_statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Scrubble" action:@selector(quitApp:) keyEquivalent:@"q"];
    quitItem.target = self;
    [_statusMenu addItem:quitItem];

    _statusItem.menu = _statusMenu;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(trackScrobbled:)
                                                 name:ScrubbleTrackScrobbledNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nowPlayingChanged:)
                                                 name:ScrubbleNowPlayingChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrobbleFailed:)
                                                 name:ScrubbleScrobbleFailedNotification
                                               object:nil];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;

    UNNotificationAction *retry = [UNNotificationAction actionWithIdentifier:@"RETRY"
                                                                       title:@"Retry"
                                                                     options:UNNotificationActionOptionNone];
    UNNotificationAction *copy = [UNNotificationAction actionWithIdentifier:@"COPY_REASON"
                                                                      title:@"Copy reason"
                                                                    options:UNNotificationActionOptionNone];
    UNNotificationCategory *failedCategory = [UNNotificationCategory categoryWithIdentifier:@"SCROBBLE_FAILED"
                                                                                    actions:@[retry, copy]
                                                                          intentIdentifiers:@[]
                                                                                    options:UNNotificationCategoryOptionNone];
    [center setNotificationCategories:[NSSet setWithObject:failedCategory]];

    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        if (!granted) NSLog(@"[Scrubble] Notification permission denied");
    }];
}

- (void)updateMenuItems {
    _enabledItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;

    if (scrobbler) {
        _nowPlayingItem.title = [NSString stringWithFormat:@"Now Playing: %@", [scrobbler currentPlayingDisplayString]];
        _lastScrobbledItem.title = [NSString stringWithFormat:@"Last Scrobbled: %@", [scrobbler lastScrobbledDisplayString]];
    }
}

- (void)trackScrobbled:(NSNotification *)notification {
    [self updateMenuItems];

    if ([[CredentialStore sharedStore] isNotificationsEnabled]) {
        NSDictionary *info = notification.userInfo;
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = @"Scrobbled";
        content.body = [NSString stringWithFormat:@"%@ - %@", info[@"artist"] ?: @"Unknown Artist", info[@"track"] ?: @"Unknown Track"];

        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Scrubble" ofType:@"icns"];
        if (iconPath) {
            UNNotificationAttachment *icon = [UNNotificationAttachment attachmentWithIdentifier:@"icon"
                                                                                            URL:[NSURL fileURLWithPath:iconPath]
                                                                                        options:nil
                                                                                          error:nil];
            if (icon) content.attachments = @[icon];
        }

        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                                              content:content
                                                                              trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    }
}

- (void)nowPlayingChanged:(NSNotification *)notification {
    [self updateMenuItems];
}

- (void)scrobbleFailed:(NSNotification *)notification {
    if (![[CredentialStore sharedStore] isNotificationsEnabled]) return;
    NSDictionary *info = notification.userInfo;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Scrobble failed";
    content.body = [NSString stringWithFormat:@"%@ - %@",
        info[@"artist"] ?: @"Unknown Artist",
        info[@"track"] ?: @"Unknown Track"];
    content.categoryIdentifier = @"SCROBBLE_FAILED";
    content.userInfo = info;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *info = response.notification.request.content.userInfo;
    if ([response.actionIdentifier isEqualToString:@"COPY_REASON"]) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:info[@"reason"] ?: @"" forType:NSPasteboardTypeString];
    } else if ([response.actionIdentifier isEqualToString:@"RETRY"]) {
        [scrobbler scrobbleTrack:info[@"track"]
                      withArtist:info[@"artist"]
                           album:info[@"album"]
                     atTimestamp:info[@"timestamp"]];
    }
    completionHandler();
}

- (void)toggleEnabled:(id)sender {
    enabled = !enabled;
    [[CredentialStore sharedStore] setEnabled:enabled];
    _enabledItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;

    if (enabled) {
        updatePrefs();
    } else {
        [scrobbler unregisterObserver];
    }

}

- (void)toggleLaunchAtLogin:(id)sender {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        if (SMAppService.mainAppService.status == SMAppServiceStatusEnabled) {
            [SMAppService.mainAppService unregisterAndReturnError:&error];
        } else {
            [SMAppService.mainAppService registerAndReturnError:&error];
        }
        if (error) NSLog(@"[Scrubble] Launch at login error: %@", error);
    } else {
        setLaunchAgentEnabled(!isLaunchAgentInstalled());
    }
    _launchAtLoginItem.state = [self isLaunchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)openLibrary:(id)sender {
    NSString *username = [[CredentialStore sharedStore] username];
    NSString *url = (username.length > 0)
        ? [NSString stringWithFormat:@"https://www.last.fm/user/%@/library", username]
        : @"https://www.last.fm/";
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (void)toggleNotifications:(id)sender {
    BOOL current = [[CredentialStore sharedStore] isNotificationsEnabled];
    [[CredentialStore sharedStore] setNotificationsEnabled:!current];
    _notificationsItem.state = !current ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)openSettings:(id)sender {
    if (!_settingsWindow) {
        _settingsWindow = [[ScrubbleMacSettings alloc] initWithScrobbler:scrobbler];
        __weak typeof(self) weakSelf = self;
        _settingsWindow.onSettingsChanged = ^{
            updatePrefs();
            [weakSelf updateMenuItems];
        };
    }
    [_settingsWindow showWindow];
}

- (void)quitApp:(id)sender {
    [[NSApplication sharedApplication] terminate:nil];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateMenuItems];
    _launchAtLoginItem.state = [self isLaunchAtLoginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

@end

void setupMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Scrubble" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenuItem setSubmenu:editMenu];

    [NSApp setMainMenu:mainMenu];
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"[Scrubble] Scrubble macOS started!");

        mediaRemoteAvailable = SCRMediaRemoteSymbolsAvailable();
        if (!mediaRemoteAvailable) NSLog(@"[Scrubble] MediaRemote symbols missing — scrobbling disabled");

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        setupMainMenu();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        (CFNotificationCallback)updatePrefs,
                                        CFSTR("fr.rootfs.scrubbleprefs-updated"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        if (![[CredentialStore sharedStore] isKeychainAccessible]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Keychain Access Denied";
            alert.informativeText = @"Scrubble needs keychain access to store your credentials securely. Please grant access in System Settings > Privacy & Security > Keychain Access, then relaunch.";
            alert.alertStyle = NSAlertStyleWarning;
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
        }

        updatePrefs();
        [[ScrubbleMenuBarController sharedController] setupMenuBar];
        [app run];
    }
    return 0;
}

#else // TARGET_OS_IOS

//#define JAILED
#ifdef JAILED

BOOL hooked_UIWindow_canBecomeFirstReponder(UIWindow *window, SEL _cmd) { return YES; }

void (*orig_UIWindow_viewDidAppear)(UIWindow *self, SEL _cmd);
void hooked_UIWindow_viewDidAppear(UIWindow *self, SEL _cmd) {
	orig_UIWindow_viewDidAppear(self, _cmd);
	[self becomeFirstResponder];
}

void (*orig_UIResponder_motionEnded_withEvent)(UIResponder *self, SEL _cmd, UIEventSubtype subtype, UIEvent *event);
void hooked_UIResponder_motionEnded_withEvent(UIResponder *self, SEL _cmd, UIEventSubtype subtype, UIEvent *event) {
	if (subtype == UIEventSubtypeMotionShake) {
		UIAlertController *controller = [UIAlertController alertControllerWithTitle:@"Scrubble" message:@"Input your credentials here" preferredStyle:UIAlertControllerStyleAlert];
		[controller addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
			textField.placeholder = @"username";
		}];

		[controller addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
			textField.placeholder = @"password";
			textField.secureTextEntry = YES;
		}];

		[controller addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
			textField.placeholder = @"API Key";
		}];

		[controller addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
			textField.placeholder = @"API Secret";
		}];

		UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
			NSString *username = controller.textFields[0].text;
			NSString *password = controller.textFields[1].text;
			NSString *apiKey = controller.textFields[2].text;
			NSString *apiSecret = controller.textFields[3].text;


		}];

		[controller addAction:save];
		[self.inputViewController presentViewController:controller animated:YES completion:nil];
	}

	orig_UIResponder_motionEnded_withEvent(self, _cmd, subtype, event);
}

void hook(Class clz, SEL target, void *replace, IMP *orig) {
	Method m = class_getInstanceMethod(clz, target) ?: class_getClassMethod(clz, target);
	if (m == NULL) return;

	orig = class_replaceMethod(clz, target, (IMP)replace, method_getTypeEncoding(m));
}

void init_jailed_hooks() {
	hook(objc_getClass("UIWindow"), sel_registerName("viewDidAppear"), hooked_UIWindow_viewDidAppear, (IMP*)&orig_UIWindow_viewDidAppear);
	hook(objc_getClass("UIWindow"), sel_registerName("canBecomeFirstReponder"), hooked_UIWindow_canBecomeFirstReponder, NULL);
	hook(objc_getClass("UIResponder"), sel_registerName("motionEnded:withEvent:"), hooked_UIResponder_motionEnded_withEvent, (IMP*) &orig_UIResponder_motionEnded_withEvent);
}

__attribute__((constructor)) void init() {
	init_jailed_hooks();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)updatePrefs, CFSTR("fr.rootfs.scrubbleprefs-updated"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

#else

int main(int argc, char *argv[], char *envp[]) {
	@autoreleasepool {
		NSLog(@"[Scrubble] Scrubble started!");

		mediaRemoteAvailable = SCRMediaRemoteSymbolsAvailable();
		if (!mediaRemoteAvailable) NSLog(@"[Scrubble] MediaRemote symbols missing — scrobbling disabled");

		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)updatePrefs, CFSTR("fr.rootfs.scrubbleprefs-updated"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
		updatePrefs();
		CFRunLoopRun();
		return 0;
	}
}

#endif // JAILED

#endif // TARGET_OS_OSX
