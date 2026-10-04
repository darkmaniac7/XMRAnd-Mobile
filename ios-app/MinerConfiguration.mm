#import "MinerConfiguration.h"
#include <cmath>

static BOOL fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"XMRAnd.Settings" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL text(id value) {
    return [value isKindOfClass:NSString.class] && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL number(NSDictionary *d, NSString *key, NSInteger fallback, NSInteger low, NSInteger high, NSError **error) {
    id value = d[key] ?: @(fallback);
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        || !std::isfinite([value doubleValue]) || [value doubleValue] != [value integerValue]
        || [value integerValue] < low || [value integerValue] > high)
        return fail(error, [NSString stringWithFormat:@"%@ must be a whole number from %ld to %ld.", key, (long)low, (long)high]);
    return YES;
}
static BOOL boolean(NSDictionary *d, NSString *key, NSError **error) {
    id value = d[key];
    if (value && (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()))
        return fail(error, [key stringByAppendingString:@" must be true or false."]);
    return YES;
}
static BOOL endpoint(NSString *value) {
    if ([value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:[value containsString:@"://"] ? value : [@"stratum+tcp://" stringByAppendingString:value]];
    return [@[@"stratum+tcp",@"stratum+ssl",@"stratum+tls",@"tcp",@"ssl",@"tls"] containsObject:url.scheme ?: @""]
        && url.host.length > 0 && url.port.integerValue >= 1 && url.port.integerValue <= 65535
        && !url.user && !url.password && !url.query && !url.fragment && url.path.length == 0;
}

NSMutableDictionary *XMRDefaultProfile(void) {
    NSDictionary *value = @{
        @"pools":@[@{@"url":@"",@"user":@"",@"pass":@"x",@"rig-id":@"xmrand-ios",@"tls":@YES,@"enabled":@YES,@"keepalive":@YES,@"algo":@"rx/0"}],
        @"cpu":@{@"enabled":@YES,@"priority":@2,@"yield":@YES,@"max-threads-hint":@100},
        @"randomx":@{@"mode":@"auto"},@"donate-level":@1,@"autosave":@NO,
        @"xmrand":@{@"autostart":@NO,@"charging-only":@NO,@"pause-battery":@15,@"resume-battery":@40,@"allow-interpreter":@NO}
    };
    return [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] options:NSJSONReadingMutableContainers error:nil];
}

BOOL XMRValidateProfile(NSDictionary *profile, BOOL ready, NSError **error) {
    if (![profile isKindOfClass:NSDictionary.class]) return fail(error, @"Configuration must be a JSON object.");
    NSArray *pools = profile[@"pools"];
    if (![pools isKindOfClass:NSArray.class] || pools.count < 1 || pools.count > 32) return fail(error, @"Use 1 to 32 pools.");
    NSUInteger enabled = 0;
    for (id object in pools) {
        if (![object isKindOfClass:NSDictionary.class]) return fail(error, @"Each pool must be an object.");
        NSDictionary *pool = object;
        for (NSString *key in @[@"url",@"user",@"pass",@"rig-id",@"algo"])
            if (pool[key] && !text(pool[key])) return fail(error, [key stringByAppendingString:@" must be text without control characters."]);
        if (!boolean(pool,@"tls",error) || !boolean(pool,@"enabled",error)) return NO;
        NSString *url = pool[@"url"] ?: @"";
        if (url.length && !endpoint(url)) return fail(error, @"Pool address must be host:port (IPv6: [address]:port), without a wallet or path.");
        if (!pool[@"enabled"] || [pool[@"enabled"] boolValue]) {
            enabled++;
            NSString *user = pool[@"user"] ?: @"";
            if (ready && (!url.length || !user.length || [user hasPrefix:@"YOUR_"])) return fail(error,@"Enter your pool address and wallet/account for every enabled pool.");
        }
    }
    if (ready && !enabled) return fail(error,@"Enable at least one pool.");
    NSDictionary *cpu = profile[@"cpu"] ?: @{};
    NSDictionary *rx = profile[@"randomx"] ?: @{};
    NSDictionary *prefs = profile[@"xmrand"] ?: @{};
    if (![cpu isKindOfClass:NSDictionary.class] || ![rx isKindOfClass:NSDictionary.class] || ![prefs isKindOfClass:NSDictionary.class])
        return fail(error,@"cpu, randomx and xmrand settings must be objects.");
    if (!boolean(cpu,@"enabled",error)) return NO;
    if (ready && cpu[@"enabled"] && ![cpu[@"enabled"] boolValue]) return fail(error,@"Enable CPU mining first.");
    if (cpu[@"priority"] != NSNull.null && !number(cpu,@"priority",2,0,5,error)) return NO;
    if (!number(cpu,@"max-threads-hint",100,1,100,error)) return NO;
    for (id value in cpu.allValues) if ([value isKindOfClass:NSDictionary.class] && value[@"threads"] && !number(value,@"threads",1,1,256,error)) return NO;
    if (![@[@"auto",@"fast",@"light"] containsObject:rx[@"mode"] ?: @"auto"]) return fail(error,@"RandomX mode must be auto, fast or light.");
    if (!number(profile,@"donate-level",1,1,100,error) || !number(prefs,@"pause-battery",15,1,98,error) || !number(prefs,@"resume-battery",40,2,100,error)) return NO;
    if ([prefs[@"resume-battery"] ?: @40 integerValue] <= [prefs[@"pause-battery"] ?: @15 integerValue]) return fail(error,@"Resume battery must be higher than pause battery.");
    for (NSString *key in @[@"autostart",@"charging-only",@"allow-interpreter"]) if (!boolean(prefs,key,error)) return NO;
    return YES;
}

NSMutableDictionary *XMRParseProfile(NSData *data, NSError **error) {
    if (data.length > 256 * 1024) { fail(error,@"Configuration is larger than 256 KB."); return nil; }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error];
    if (!XMRValidateProfile(parsed,NO,error)) return nil;
    if (!parsed[@"xmrand"]) parsed[@"xmrand"] = XMRDefaultProfile()[@"xmrand"];
    return parsed;
}
NSMutableDictionary *XMRLoadProfile(NSString *path, NSError **error) {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return XMRDefaultProfile();
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
    if (!attrs) return nil;
    if ([attrs[NSFileSize] unsignedLongLongValue] > 256 * 1024) { fail(error,@"Configuration is larger than 256 KB."); return nil; }
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    return data ? XMRParseProfile(data,error) : nil;
}
BOOL XMRSaveProfile(NSDictionary *profile, NSString *path, NSError **error) {
    if (!XMRValidateProfile(profile,NO,error)) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;
    if (data.length > 256 * 1024) return fail(error,@"Configuration is larger than 256 KB.");
    if (![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}
NSMutableDictionary *XMRRuntimeProfile(NSDictionary *profile, NSString *logPath, NSInteger cores, NSError **error) {
    if (!XMRValidateProfile(profile,YES,error)) return nil;
    NSMutableDictionary *runtime = [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:profile options:0 error:error] options:NSJSONReadingMutableContainers error:error];
    if (!runtime) return nil;
    [runtime removeObjectForKey:@"xmrand"];
    runtime[@"autosave"] = @NO; runtime[@"background"] = @NO; runtime[@"colors"] = @NO; runtime[@"log-file"] = logPath;
    NSMutableDictionary *cpu = runtime[@"cpu"] ?: [NSMutableDictionary dictionary];
    cpu[@"huge-pages"] = @NO; cpu[@"huge-pages-jit"] = @NO;
    runtime[@"cpu"] = cpu;
    NSMutableDictionary *rx = runtime[@"randomx"] ?: [NSMutableDictionary dictionary];
    if (!rx[@"init"] || [rx[@"init"] integerValue] < 1) rx[@"init"] = @(MAX(1,cores));
    rx[@"1gb-pages"] = @NO; rx[@"rdmsr"] = @NO; rx[@"wrmsr"] = @NO; rx[@"numa"] = @NO;
    runtime[@"randomx"] = rx;
    return runtime;
}
