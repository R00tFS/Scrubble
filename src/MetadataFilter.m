#import "MetadataFilter.h"

static NSString *applyRule(NSString *text, NSString *pattern, NSString *replacement, NSRegularExpressionOptions opts) {
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:opts error:nil];
	if (!regex) return text;
	return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:replacement];
}

static NSString *applyRules(NSString *text, NSArray<NSDictionary *> *rules) {
	for (NSDictionary *rule in rules) {
		NSString *pattern = rule[@"p"];
		NSString *replacement = rule[@"r"];
		NSNumber *opts = rule[@"o"];
		text = applyRule(text, pattern, replacement, opts ? opts.unsignedIntegerValue : NSRegularExpressionCaseInsensitive);
	}
	return text;
}

static NSDictionary *rule(NSString *pattern, NSString *replacement) {
	return @{@"p": pattern, @"r": replacement, @"o": @(NSRegularExpressionCaseInsensitive)};
}

static NSDictionary *ruleCS(NSString *pattern, NSString *replacement) {
	return @{@"p": pattern, @"r": replacement, @"o": @(0)};
}

static NSArray *remasteredRules(void) {
	return @[
		ruleCS(@"Live\\s/\\sRemastered", @"Live"),
		rule(@"\\s[\\(\\[].*Re-?[Mm]aster(ed)?.*[\\)\\]]$", @""),
		rule(@"\\s-\\s\\d{4}(\\s-)?\\s.*Re-?[Mm]aster(ed)?.*$", @""),
		rule(@"\\s-\\sRe-?[Mm]aster(ed)?.*$", @""),
		rule(@"\\s\\[Remastered\\]\\s\\(Remastered\\sVersion\\)$", @""),
	];
}

static NSArray *versionRules(void) {
	return @[
		rule(@"\\s[\\(\\[]Album Version[\\)\\]]$", @""),
		rule(@"\\s[\\(\\[]Re-?recorded[\\)\\]]$", @""),
		rule(@"\\s[\\(\\[]Single Version[\\)\\]]$", @""),
		rule(@"\\s[\\(\\[]Edit[\\)\\]]$", @""),
		ruleCS(@"\\s-\\sMono Version$", @""),
		ruleCS(@"\\s-\\sStereo Version$", @""),
		rule(@"\\s\\(Deluxe Edition\\)$", @""),
		rule(@"\\s[\\(\\[]Expanded.*[\\)\\]]$", @""),
		rule(@"\\s-\\sExpanded Edition$", @""),
		rule(@"\\s[\\(\\[]Explicit Version[\\)\\]]", @""),
		rule(@"\\s[\\(\\[]Bonus Track Edition[\\)\\]]", @""),
		rule(@"\\s[\\(\\[]\\d+th\\sAnniversary.*[\\)\\]]", @""),
		rule(@"\\s-\\sOriginal$", @""),
		rule(@"\\s-\\sOriginal.*Version(\\s\\d{4})?$", @""),
	];
}

static NSArray *cleanExplicitRules(void) {
	return @[
		rule(@"\\s[\\(\\[]Explicit[\\)\\]]", @""),
		rule(@"\\s[\\(\\[]Clean[\\)\\]]", @""),
	];
}

static NSArray *featureRules(void) {
	return @[
		rule(@"\\s[\\(\\[]feat\\.\\s.+[\\)\\]]", @""),
		rule(@"\\s(feat\\.\\s.+)", @""),
	];
}

static NSArray *liveRules(void) {
	return @[
		ruleCS(@"\\s-\\sLive(\\s.+)?$", @""),
		ruleCS(@"\\s[\\(\\[]Live[\\)\\]]$", @""),
	];
}

static NSArray *reissueRules(void) {
	return @[
		rule(@"\\sRe-?issue$", @""),
		rule(@"\\s\\[.*?Re-?issue.*?\\]", @""),
		rule(@"\\s\\(.*?Re-?issue.*?\\)", @""),
	];
}

static NSArray *suffixRules(void) {
	return @[
		rule(@"-\\s(.+?)\\s((Re)?mix|edit|dub|mix|vip|version)$", @"($1 $2)"),
		rule(@"-\\s(Remix|VIP|Instrumental)$", @"($1)"),
	];
}

static NSArray *normalizeFeatureRules(void) {
	return @[
		rule(@"\\s[\\(\\[](feat\\.\\s.+)[\\)\\]]", @" $1"),
	];
}

static NSArray *trimSymbolsRules(void) {
	return @[
		ruleCS(@"\\(+\\s*\\)+", @""),
		ruleCS(@"^[/,:;~\\s\"-]+", @""),
		ruleCS(@"[/,:;~\\s\"-]+$", @""),
		ruleCS(@"\\x{0020}{2,}", @" "),
	];
}

static NSString *filterTrackText(NSString *text) {
	text = applyRules(text, remasteredRules());
	text = applyRules(text, cleanExplicitRules());
	text = applyRules(text, featureRules());
	text = applyRules(text, suffixRules());
	text = applyRules(text, versionRules());
	text = applyRules(text, liveRules());
	text = applyRules(text, trimSymbolsRules());
	return text;
}

static NSString *filterAlbumText(NSString *text) {
	text = applyRules(text, remasteredRules());
	text = applyRules(text, suffixRules());
	text = applyRules(text, versionRules());
	text = applyRules(text, liveRules());
	text = applyRules(text, reissueRules());
	text = applyRules(text, trimSymbolsRules());
	return text;
}

static NSString *filterArtistText(NSString *text) {
	text = applyRules(text, normalizeFeatureRules());
	text = applyRules(text, trimSymbolsRules());
	return text;
}

@implementation MetadataFilter

+ (instancetype)defaultFilter {
	return [[MetadataFilter alloc] init];
}

- (NSString *)filterTrack:(NSString *)track {
	if (!track.length) return track;
	return filterTrackText(track);
}

- (NSString *)filterAlbum:(NSString *)album {
	if (!album.length) return album;
	return filterAlbumText(album);
}

- (NSString *)filterArtist:(NSString *)artist {
	if (!artist.length) return artist;
	return filterArtistText(artist);
}

@end
