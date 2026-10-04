#import <Foundation/Foundation.h>

NSMutableDictionary *XMRDefaultProfile(void);
NSMutableDictionary *XMRParseProfile(NSData *data, NSError **error);
NSMutableDictionary *XMRLoadProfile(NSString *path, NSError **error);
BOOL XMRValidateProfile(NSDictionary *profile, BOOL ready, NSError **error);
BOOL XMRSaveProfile(NSDictionary *profile, NSString *path, NSError **error);
NSMutableDictionary *XMRRuntimeProfile(NSDictionary *profile, NSString *logPath, NSInteger cores, NSError **error);
