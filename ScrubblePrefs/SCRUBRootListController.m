#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <libroot.h>
#import "Preferences/PSSpecifier.h"
#import "SCRUBRootListController.h"
#import "include/NSTask.h"
#import "ScrubbleUtils.h"
#import "Constants.h"

@implementation SCRUBRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
        self.daemonRunning = false;
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
	}

	return _specifiers;
}

- (void)open:(PSSpecifier *)btn {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:[btn propertyForKey:@"url"]] options:@{} completionHandler:nil];
}

- (NSString*)daemonStatus:(PSSpecifier*)sender {
    @try{
        NSPipe *pipe = [NSPipe pipe];
        NSFileHandle *file = pipe.fileHandleForReading;

        NSTask *task = [[NSTask alloc] init];
        task.launchPath = JBROOT_PATH_NSSTRING(@"/bin/sh");
        task.arguments = @[@"-c", [NSString stringWithFormat:@"%@ list | %@ scrubble | %@ '{print $1}'", JBROOT_PATH_NSSTRING(@"/usr/bin/launchctl"), JBROOT_PATH_NSSTRING(@"/usr/bin/grep"), JBROOT_PATH_NSSTRING(@"/usr/bin/awk")]];
        task.standardOutput = pipe;
        task.standardError = pipe;

        [task launch];
        [task waitUntilExit];

        NSData *data = [file readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [file closeFile];

        if (!output || [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:@""]) return @"Stopped";
        
        self.daemonRunning = ![output hasPrefix:@"-"];
        [self reloadDaemonToggleLabel];
        return (self.daemonRunning ? @"Running" : @"Stopped");
    }
    @catch(NSException *e){
        NSLog(@"[Scrubble] Exception: %@", e.reason);
    }

    return @"Stopped";
}

-(void) reloadDaemonToggleLabel {
    PSSpecifier *daemonToggleLabel = [self specifierForID:@"daemonToggle"];
    if (daemonToggleLabel) daemonToggleLabel.name = [self toggleDaemonLabel];
}

-(void) reloadDaemonStatus {
    PSSpecifier *daemonStatus = [self specifierForID:@"daemonStatus"];
    if (daemonStatus) [self reloadSpecifier:daemonStatus];
    [self reloadDaemonToggleLabel];
}

- (void)toggleDaemon {
    NSString *action = (!self.daemonRunning ? @"start" : @"stop");
    NSString *command = [NSString stringWithFormat:@"sudo %@ %@ %@", JBROOT_PATH_NSSTRING(@"/usr/bin/launchctl"), action, @"fr.rootfs.scrubble"];

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Scrubble" message:[NSString stringWithFormat:@"In order to %@ Scrubble, you need to paste this command into NewTerm. \n The default password is alpine.", action] preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* openNewTermAction = [UIAlertAction actionWithTitle:@"Open NewTerm" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = command;
        [[objc_getClass("LSApplicationWorkspace") performSelector:@selector(defaultWorkspace)] performSelector:@selector(openApplicationWithBundleID:) withObject:@"ws.hbang.Terminal"];
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];

    [alertController addAction:openNewTermAction];
    [alertController addAction:cancelAction];

    [self presentViewController:alertController animated:YES completion:nil];
}

- (NSString*)toggleDaemonLabel {
    return (self.daemonRunning ? @"Stop Scrubble" : @"Start Scrubble");
}

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:@"fr.rootfs.scrubbleprefs"];
}

- (void)authorizeWithLastfm {
    NSString *apiKey = [self readPreferenceValue:[self specifierForID:@"apiKey"]];
    NSString *apiSecret = [self readPreferenceValue:[self specifierForID:@"apiSecret"]];

    if (!apiKey.length || !apiSecret.length) {
        [self showAlert:@"Error" message:@"API Key and Secret are required"];
        return;
    }

    NSString *sigContent = [NSString stringWithFormat:@"api_key%@methodauth.getToken%@", apiKey, apiSecret];

    NSDictionary *params = @{
        @"method": @"auth.getToken",
        @"api_key": apiKey,
        @"api_sig": ScrubbleMD5(sigContent),
        @"format": @"json"
    };

    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:LASTFM_API_URL]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:[ScrubbleQueryString(params) dataUsingEncoding:NSUTF8StringEncoding]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
            if (resp.statusCode != 200 || !data) {
                [self showAlert:@"Error" message:@"Failed to get token"];
                return;
            }

            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *token = dict[@"token"];
            if (!token) {
                [self showAlert:@"Error" message:dict[@"message"] ?: @"Failed to get token"];
                return;
            }

            // Persist pending token (survives controller dealloc when switching to Safari)
            [[self prefs] setObject:token forKey:@"pendingAuthToken"];
            [[self prefs] synchronize];

            NSString *authURL = [NSString stringWithFormat:@"https://www.last.fm/api/auth/?api_key=%@&token=%@", apiKey, token];
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:authURL] options:@{} completionHandler:nil];

            [self showAlert:@"Authorize" message:@"Authorize in browser, then come back and tap Complete Authorization"];
        });
    }] resume];
}

- (void)completeAuthorization {
    NSString *pendingToken = [[self prefs] objectForKey:@"pendingAuthToken"];
    if (!pendingToken) {
        [self showAlert:@"Error" message:@"No pending authorization. Tap 'Authorize with Last.fm' first."];
        return;
    }

    NSString *apiKey = [self readPreferenceValue:[self specifierForID:@"apiKey"]];
    NSString *apiSecret = [self readPreferenceValue:[self specifierForID:@"apiSecret"]];

    NSString *sigContent = [NSString stringWithFormat:@"api_key%@methodauth.getSessiontoken%@%@", apiKey, pendingToken, apiSecret];

    NSDictionary *params = @{
        @"method": @"auth.getSession",
        @"api_key": apiKey,
        @"token": pendingToken,
        @"api_sig": ScrubbleMD5(sigContent),
        @"format": @"json"
    };

    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:LASTFM_API_URL]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:[ScrubbleQueryString(params) dataUsingEncoding:NSUTF8StringEncoding]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
            if (resp.statusCode != 200 || !data) {
                [self showAlert:@"Error" message:@"Authorization failed"];
                return;
            }

            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *session = dict[@"session"];
            if (!session) {
                [self showAlert:@"Error" message:dict[@"message"] ?: @"Authorization failed"];
                return;
            }

            NSString *sessionKey = session[@"key"];
            NSString *username = session[@"name"];

            // Store in prefs so the daemon can read them
            NSUserDefaults *defaults = [self prefs];
            [defaults setObject:sessionKey forKey:@"token"];
            if (username) [defaults setObject:username forKey:@"username"];
            [defaults removeObjectForKey:@"pendingAuthToken"];
            [defaults synchronize];

            // Update the username specifier in the UI
            if (username) {
                PSSpecifier *usernameSpec = [self specifierForID:@"username"];
                if (usernameSpec) [self setPreferenceValue:username specifier:usernameSpec];
            }

            // Notify daemon
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFSTR("fr.rootfs.scrubbleprefs-updated"),
                                                 NULL, NULL, true);

            [self showAlert:@"Success" message:[NSString stringWithFormat:@"Authorized as %@!", username ?: @"unknown"]];
        });
    }] resume];
}

- (void)openLibrary {
    NSString *username = [self readPreferenceValue:[self specifierForID:@"username"]];
    NSString *url = (username.length > 0)
        ? [NSString stringWithFormat:@"https://www.last.fm/user/%@/library", username]
        : @"https://www.last.fm/";
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

-(void) testLogin {
    NSString *username = [self readPreferenceValue:[self specifierForID:@"username"]];
    NSString *password = [self readPreferenceValue:[self specifierForID:@"password"]];
	NSString *apiKey = [self readPreferenceValue:[self specifierForID:@"apiKey"]];
    NSString *apiSecret = [self readPreferenceValue:[self specifierForID:@"apiSecret"]];

    NSString *sigContent = [NSString stringWithFormat:@"api_key%@method%@password%@username%@%@", apiKey, @"auth.getMobileSession", password, username, apiSecret];
	NSString *sig = ScrubbleMD5(sigContent);

	NSString *query = ScrubbleQueryString(@{@"method": @"auth.getMobileSession", @"username": username, @"password": password, @"api_key": apiKey, @"api_sig": sig, @"format": @"json"});

	NSURL *url = [NSURL URLWithString:LASTFM_API_URL];

	NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:url];
	[req setHTTPMethod:@"POST"];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:[query dataUsingEncoding:NSUTF8StringEncoding]];

	[[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
		NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
		BOOL success = [resp statusCode] == 200;

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *controller = [UIAlertController alertControllerWithTitle:(success ? @"Login succeeded" : @"Login failed") message:(success ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *action = [UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDefault handler:nil];

            [controller addAction:action];
            [self presentViewController:controller animated:YES completion:nil];
        });

	}] resume];
}

@end
