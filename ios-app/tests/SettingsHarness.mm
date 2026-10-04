// Simulator-only controller integration checks. No engine, accounts or network mining.
#import "../MinerSettingsViewController.h"
#import "../MinerConfiguration.h"
@interface MinerSettingsViewController (Tests)
- (NSMutableDictionary *)collect:(BOOL)ready error:(NSError **)error;
- (void)render;
- (void)saveTapped;
- (void)startTapped;
- (void)stopTapped;
- (void)showGuide;
@end
@interface Harness : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation Harness
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    MinerSettingsViewController *vc = [MinerSettingsViewController new];
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    vc.profilePath = [docs stringByAppendingPathComponent:@"config.json"];
    vc.minerLogPath = [docs stringByAppendingPathComponent:@"miner.log"];
    __block int starts = 0, stops = 0;
    vc.onStart = ^{ starts++; }; vc.onStop = ^{ stops++; };
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:vc];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSMutableArray *failures = [NSMutableArray array]; int checks = 0;
#define VERIFY(...) do { checks++; if (!(__VA_ARGS__)) [failures addObject:[NSString stringWithFormat:@"line %d: %s",__LINE__,#__VA_ARGS__]]; } while(0)
        NSDictionary *fields = [vc valueForKey:@"fields"];
        VERIFY([fields[@"user"] text].length == 0); VERIFY(starts == 0);
        [fields[@"url"] setText:@"pool.example:443"]; [fields[@"user"] setText:@"simulator-account"];
        [fields[@"threads"] setText:@"1"]; [fields[@"priority"] setText:@"auto"];
        [[vc valueForKey:@"backups"] setText:@"backup.example:3333"];
        [vc saveTapped]; NSError *error = nil;
        NSMutableDictionary *saved = XMRLoadProfile(vc.profilePath,&error);
        VERIFY([saved[@"pools"][0][@"user"] isEqual:@"simulator-account"]);
        VERIFY([saved[@"pools"] count] == 2); VERIFY(saved[@"cpu"][@"priority"] == NSNull.null);
        [vc startTapped]; VERIFY(starts == 1); [vc stopTapped]; VERIFY(stops == 1);
        saved[@"cpu"][@"rx/0"] = @[@0,@2]; saved[@"retries"] = @9;
        saved[@"pools"][1][@"user"] = @"independent-backup";
        [vc setValue:saved forKey:@"profile"]; [vc render];
        VERIFY([[fields[@"threads"] text] isEqual:@"custom"]);
        [fields[@"user"] setText:@"new-primary"];
        NSDictionary *roundtrip = [vc collect:YES error:&error];
        VERIFY(roundtrip != nil); VERIFY([roundtrip[@"cpu"][@"rx/0"] isEqual:@[@0,@2]]);
        VERIFY([roundtrip[@"retries"] intValue] == 9);
        VERIFY([roundtrip[@"pools"][1][@"user"] isEqual:@"independent-backup"]);
        [fields[@"pause"] setText:@"90"]; VERIFY([vc collect:YES error:&error] == nil);
        [fields[@"pause"] setText:@"15"];
        NSURL *guide = [NSBundle.mainBundle URLForResource:@"public-setup" withExtension:@"html"];
        VERIFY(guide != nil); [vc showGuide];
        VERIFY(vc.presentedViewController != nil);
        NSString *report = [NSString stringWithFormat:@"%@ %d simulator controller checks\n%@\n",failures.count ? @"FAIL" : @"PASS", checks,[failures componentsJoinedByString:@"\n"]];
        [report writeToFile:[docs stringByAppendingPathComponent:@"test-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"%@",report);
    });
    return YES;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(Harness.class)); } }
