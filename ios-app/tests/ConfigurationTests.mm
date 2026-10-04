#import "../MinerConfiguration.h"
static int checks = 0;
#define CHECK(...) do { checks++; if (!(__VA_ARGS__)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#__VA_ARGS__); return 1; } } while (0)
int main() { @autoreleasepool {
    NSError *error = nil;
    NSMutableDictionary *c = XMRDefaultProfile();
    CHECK(![c[@"xmrand"][@"autostart"] boolValue]);
    CHECK(![c[@"xmrand"][@"allow-interpreter"] boolValue]);
    CHECK([c[@"pools"][0][@"user"] length] == 0);
    CHECK(XMRValidateProfile(c,NO,&error));
    CHECK(!XMRValidateProfile(c,YES,&error));
    c[@"pools"][0][@"url"] = @"pool.example:443"; c[@"pools"][0][@"user"] = @"test-account";
    [c[@"pools"] addObject:[@{@"url":@"backup.example:3333",@"user":@"backup-account",@"tls":@NO} mutableCopy]];
    c[@"cpu"][@"rx/0"] = @[@0,@2]; c[@"cpu"][@"priority"] = NSNull.null; c[@"retries"] = @7;
    c[@"randomx"][@"mode"] = @"light"; c[@"log-file"] = @"/wrong/path";
    CHECK(XMRValidateProfile(c,YES,&error));
    NSDictionary *runtime = XMRRuntimeProfile(c,@"/private/test.log",6,&error);
    CHECK(runtime != nil); CHECK(runtime[@"xmrand"] == nil);
    CHECK([runtime[@"log-file"] isEqual:@"/private/test.log"]);
    CHECK([runtime[@"pools"][1][@"user"] isEqual:@"backup-account"]);
    CHECK([runtime[@"cpu"][@"rx/0"] isEqual:@[@0,@2]]);
    CHECK([runtime[@"retries"] intValue] == 7);
    CHECK(![runtime[@"cpu"][@"huge-pages"] boolValue]);
    CHECK([c[@"log-file"] isEqual:@"/wrong/path"]);
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:@"config.json"];
    CHECK(XMRSaveProfile(c,path,&error));
    CHECK([XMRLoadProfile(path,&error) isEqual:c]);
    c[@"xmrand"][@"resume-battery"] = @15;
    CHECK(!XMRSaveProfile(c,path,&error));
    CHECK([XMRLoadProfile(path,&error)[@"xmrand"][@"resume-battery"] intValue] == 40);
    c[@"xmrand"][@"resume-battery"] = @40;
    for (NSString *url in @[@"pool.example",@"wallet@pool.example:443",@"https://pool.example:443",@"pool.example:0",@"pool.example:65536",@"pool.example:443/path"]) {
        c[@"pools"][0][@"url"] = url; CHECK(!XMRValidateProfile(c,YES,&error));
    }
    for (NSString *url in @[@"pool.example:443",@"[::1]:3333",@"stratum+ssl://pool.example:443"]) {
        c[@"pools"][0][@"url"] = url; CHECK(XMRValidateProfile(c,YES,&error));
    }
    c[@"cpu"][@"priority"] = @YES; CHECK(!XMRValidateProfile(c,YES,&error));
    for (NSString *json in @[@"[]",@"{} garbage",@"{\"pools\":null}"]) CHECK(!XMRParseProfile([json dataUsingEncoding:NSUTF8StringEncoding],&error));
    CHECK(!XMRParseProfile([NSMutableData dataWithLength:256*1024+1],&error));
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    printf("PASS %d configuration checks\n",checks);
} return 0; }
