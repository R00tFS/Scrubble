#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

static inline NSString *ScrubbleMD5(NSString *str) {
	const char *cstr = str.UTF8String;
	unsigned char result[CC_MD5_DIGEST_LENGTH];
	CC_MD5(cstr, (CC_LONG)strlen(cstr), result);
	NSMutableString *hash = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
	for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
		[hash appendFormat:@"%02x", result[i]];
	}
	return hash;
}

static inline NSString *ScrubbleQueryString(NSDictionary *items) {
	NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
	[allowed removeCharactersInString:@"+&=?#"];
	NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:items.count];
	for (NSString *key in items) {
		NSString *encKey = [key stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
		NSString *encVal = [items[key] stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
		[pairs addObject:[NSString stringWithFormat:@"%@=%@", encKey, encVal]];
	}
	return [pairs componentsJoinedByString:@"&"];
}
