#import <Foundation/Foundation.h>

@interface MetadataFilter : NSObject

+ (instancetype)defaultFilter;

- (NSString *)filterTrack:(NSString *)track;
- (NSString *)filterAlbum:(NSString *)album;
- (NSString *)filterArtist:(NSString *)artist;

@end
