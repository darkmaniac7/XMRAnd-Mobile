#import "MinerSettingsViewController.h"
#import "MinerConfiguration.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MinerSettingsViewController ()
@property(nonatomic, strong) NSMutableDictionary *profile;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *fields;
@property(nonatomic, strong) UIStackView *stack;
@property(nonatomic, strong) UISwitch *tls;
@property(nonatomic, strong) UISwitch *charging;
@property(nonatomic, strong) UISwitch *autostart;
@property(nonatomic, strong) UISwitch *interpreter;
@property(nonatomic, strong) UITextView *backups;
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UITextView *editor;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation MinerSettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"XMRAnd"; self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.fields = [NSMutableDictionary dictionary];
    NSError *error = nil; self.profile = XMRLoadProfile(self.profilePath, &error) ?: XMRDefaultProfile();
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    self.stack = [UIStackView new]; self.stack.axis = UILayoutConstraintAxisVertical; self.stack.spacing = 10;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];
    [self label:@"Use your own wallet and pool. Keep XMRAnd open and foregrounded while mining. Locking the screen or switching apps suspends mining."];
    [self button:@"Setup and how-to" action:@selector(showGuide) identifier:@"setup"];
    [self field:@"url" label:@"Pool address (host:port)"];
    [self field:@"user" label:@"Wallet / pool account"];
    [self field:@"pass" label:@"Pool password (usually x)"].secureTextEntry = YES;
    [self field:@"worker" label:@"Worker / rig name"];
    self.tls = [self toggle:@"TLS connection" identifier:@"tls"];
    [self label:@"Backup pools: one host:port per line. Use advanced JSON for separate logins."];
    self.backups = [self textArea:90]; self.backups.accessibilityIdentifier = @"backups";
    [self field:@"algo" label:@"Algorithm (rx/0 for Monero; supported build options only)"];
    [self field:@"threads" label:@"CPU threads: 0 = automatic; custom = advanced profile"];
    [self field:@"priority" label:@"CPU priority: 0 (lowest) to 5 (highest), auto = default"];
    [self field:@"mode" label:@"RandomX memory: auto, fast (~2 GB), light (slower)"];
    [self field:@"donate" label:@"XMRig developer donation (%), minimum 1"];
    self.charging = [self toggle:@"Mine only while charging" identifier:@"charging"];
    [self field:@"pause" label:@"Pause below battery (%)"];
    [self field:@"resume" label:@"Resume at battery (%)"];
    [self label:@"Mining also pauses when iOS reports serious heat. iOS does not expose battery temperature in degrees."];
    self.autostart = [self toggle:@"Start automatically when I open XMRAnd" identifier:@"autostart"];
    self.interpreter = [self toggle:@"Allow slow interpreter if JIT is unavailable" identifier:@"interpreter"];
    [self button:@"Save settings" action:@selector(saveTapped) identifier:@"save"];
    self.startButton = [self button:@"Start" action:@selector(startTapped) identifier:@"start"];
    [self button:@"Stop" action:@selector(stopTapped) identifier:@"stop"];
    [self label:@"Changes apply on the next Start. Stop the miner before starting with new settings."];
    [self button:@"Advanced JSON" action:@selector(showAdvanced) identifier:@"advanced"];
    [self button:@"Import JSON" action:@selector(importTapped) identifier:@"import"];
    [self button:@"Export JSON" action:@selector(exportTapped) identifier:@"export"];
    self.statusLabel = [self label:@"Stopped"]; self.statusLabel.accessibilityIdentifier = @"status";
    self.logView = [self textArea:220]; self.logView.editable = NO; self.logView.accessibilityIdentifier = @"log";
    [self render];
    __weak MinerSettingsViewController * weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
    if (error) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf error:@"Saved configuration could not be read. Correct the fields or import a valid file before saving."]; });
}
- (void)dealloc { [self.timer invalidate]; }
- (UILabel *)label:(NSString *)text {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0; label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES; [self.stack addArrangedSubview:label]; return label;
}
- (UITextField *)field:(NSString *)key label:(NSString *)label {
    [self label:label]; UITextField *field = [UITextField new]; field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.accessibilityLabel = label; field.accessibilityIdentifier = key; self.fields[key] = field;
    [self.stack addArrangedSubview:field]; return field;
}
- (UITextView *)textArea:(CGFloat)height {
    UITextView *view = [UITextView new]; view.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    view.backgroundColor = UIColor.secondarySystemBackgroundColor; view.autocorrectionType = UITextAutocorrectionTypeNo; view.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [view.heightAnchor constraintEqualToConstant:height].active = YES; [self.stack addArrangedSubview:view]; return view;
}
- (UISwitch *)toggle:(NSString *)label identifier:(NSString *)identifier {
    UILabel *title = [UILabel new]; title.text = label; title.numberOfLines = 0;
    UISwitch *toggle = [UISwitch new]; toggle.accessibilityIdentifier = identifier; toggle.accessibilityLabel = label;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[title,toggle]]; row.spacing = 12;
    [self.stack addArrangedSubview:row]; return toggle;
}
- (UIButton *)button:(NSString *)label action:(SEL)selector identifier:(NSString *)identifier {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:label forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier; [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES; [self.stack addArrangedSubview:button]; return button;
}
- (NSString *)value:(NSString *)key { return [self.fields[key].text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
- (NSNumber *)integer:(NSString *)key error:(NSError **)error {
    NSString *value = [self value:key]; NSScanner *scanner = [NSScanner scannerWithString:value]; NSInteger number = 0;
    if (![scanner scanInteger:&number] || !scanner.isAtEnd) {
        if (error) *error = [NSError errorWithDomain:@"XMRAnd.Settings" code:1 userInfo:@{NSLocalizedDescriptionKey:[key stringByAppendingString:@" must be a whole number."]}];
        return nil;
    }
    return @(number);
}
- (void)render {
    NSDictionary *pool = [self.profile[@"pools"] firstObject]; NSDictionary *cpu = self.profile[@"cpu"] ?: @{};
    self.fields[@"url"].text = pool[@"url"] ?: @""; self.fields[@"user"].text = pool[@"user"] ?: @"";
    self.fields[@"pass"].text = pool[@"pass"] ?: @"x"; self.fields[@"worker"].text = pool[@"rig-id"] ?: @"";
    self.fields[@"algo"].text = pool[@"algo"] ?: @"rx/0"; self.tls.on = [pool[@"tls"] boolValue];
    NSMutableArray *urls = [NSMutableArray array]; NSArray *pools = self.profile[@"pools"];
    for (NSUInteger i=1;i<pools.count;i++) [urls addObject:pools[i][@"url"] ?: @""];
    self.backups.text = [urls componentsJoinedByString:@"\n"];
    id threads = cpu[pool[@"algo"] ?: @"rx/0"];
    self.fields[@"threads"].text = !threads ? @"0" : [threads isKindOfClass:NSDictionary.class] ? [threads[@"threads"] ?: @0 stringValue] : @"custom";
    self.fields[@"priority"].text = [cpu[@"priority"] isKindOfClass:NSNumber.class] ? [cpu[@"priority"] stringValue] : cpu[@"priority"] == NSNull.null ? @"auto" : @"2";
    self.fields[@"mode"].text = self.profile[@"randomx"][@"mode"] ?: @"auto";
    self.fields[@"donate"].text = [self.profile[@"donate-level"] ?: @1 stringValue];
    NSDictionary *prefs = self.profile[@"xmrand"] ?: @{};
    self.fields[@"pause"].text = [prefs[@"pause-battery"] ?: @15 stringValue]; self.fields[@"resume"].text = [prefs[@"resume-battery"] ?: @40 stringValue];
    self.charging.on = [prefs[@"charging-only"] boolValue]; self.autostart.on = [prefs[@"autostart"] boolValue]; self.interpreter.on = [prefs[@"allow-interpreter"] boolValue];
}
- (NSMutableDictionary *)collect:(BOOL)ready error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.profile options:0 error:error];
    NSMutableDictionary *next = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] : nil;
    if (!next) return nil;
    NSMutableArray *oldPools = next[@"pools"]; NSMutableDictionary *pool = oldPools.firstObject;
    NSDictionary *previous = [pool copy];
    pool[@"url"] = [self value:@"url"]; pool[@"user"] = [self value:@"user"]; pool[@"pass"] = self.fields[@"pass"].text ?: @"";
    pool[@"rig-id"] = [self value:@"worker"]; pool[@"tls"] = @(self.tls.on); pool[@"algo"] = [self value:@"algo"];
    NSMutableArray *pools = [NSMutableArray arrayWithObject:pool];
    for (NSString *raw in [self.backups.text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *url = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; if (!url.length) continue;
        NSMutableDictionary *backup = nil;
        for (NSUInteger i=1;i<oldPools.count;i++) if ([oldPools[i][@"url"] isEqual:url]) backup = [oldPools[i] mutableCopy];
        if (!backup) { backup = [pool mutableCopy]; backup[@"url"] = url; }
        else for (NSString *key in @[@"user",@"pass",@"rig-id",@"tls",@"algo"]) if ([backup[key] isEqual:previous[key]]) backup[key] = pool[key];
        [pools addObject:backup];
    }
    next[@"pools"] = pools;
    NSMutableDictionary *cpu = next[@"cpu"] ?: [NSMutableDictionary dictionary];
    if (![[self value:@"threads"] isEqual:@"custom"]) {
        NSNumber *count = [self integer:@"threads" error:error];
        if (!count) return nil;
        if (count.integerValue < 0 || count.integerValue > (NSInteger)NSProcessInfo.processInfo.activeProcessorCount) {
            if (error) *error = [NSError errorWithDomain:@"XMRAnd.Settings" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Thread count must be 0 (automatic) or no greater than the device CPU count."}]; return nil;
        }
        NSString *algorithm = [self value:@"algo"];
        if (!count.integerValue) [cpu removeObjectForKey:algorithm];
        else {
            NSMutableDictionary *tuning = [cpu[algorithm] isKindOfClass:NSDictionary.class] ? [cpu[algorithm] mutableCopy] : [@{@"intensity":@1,@"affinity":@(-1)} mutableCopy];
            tuning[@"threads"] = count; cpu[algorithm] = tuning;
        }
    }
    id priority = [[self value:@"priority"] isEqual:@"auto"] ? NSNull.null : [self integer:@"priority" error:error];
    NSNumber *donate = [self integer:@"donate" error:error], *pause = [self integer:@"pause" error:error], *resume = [self integer:@"resume" error:error];
    if (!priority || !donate || !pause || !resume) return nil;
    cpu[@"priority"] = priority; next[@"cpu"] = cpu; next[@"donate-level"] = donate;
    NSMutableDictionary *rx = next[@"randomx"] ?: [NSMutableDictionary dictionary]; rx[@"mode"] = [self value:@"mode"]; next[@"randomx"] = rx;
    NSMutableDictionary *prefs = next[@"xmrand"] ?: [NSMutableDictionary dictionary];
    prefs[@"pause-battery"] = pause; prefs[@"resume-battery"] = resume; prefs[@"charging-only"] = @(self.charging.on);
    prefs[@"autostart"] = @(self.autostart.on); prefs[@"allow-interpreter"] = @(self.interpreter.on); next[@"xmrand"] = prefs;
    return XMRValidateProfile(next,ready,error) ? next : nil;
}
- (BOOL)save:(BOOL)ready {
    NSError *error = nil; NSMutableDictionary *next = [self collect:ready error:&error];
    if (!next || !XMRSaveProfile(next,self.profilePath,&error)) { [self error:error.localizedDescription]; return NO; }
    self.profile = next; self.statusLabel.text = @"Saved. Settings apply on the next Start."; return YES;
}
- (void)saveTapped { [self.view endEditing:YES]; [self save:NO]; }
- (void)startTapped { [self.view endEditing:YES]; if ([self save:YES] && self.onStart) { self.onStart(); [self refresh]; } }
- (void)stopTapped { if (self.onStop) self.onStop(); [self refresh]; }
- (void)refresh {
    if (self.miningStatus) self.statusLabel.text = self.miningStatus();
    if (self.isRunning) self.startButton.enabled = !self.isRunning();
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:self.minerLogPath];
    if (!handle) return;
    @try {
        unsigned long long size = [handle seekToEndOfFile]; [handle seekToFileOffset:size > 60000 ? size - 60000 : 0];
        self.logView.text = [[NSString alloc] initWithData:[handle readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
    } @catch (NSException *exception) {} @finally { [handle closeFile]; }
}
- (void)error:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"XMRAnd" message:message ?: @"Configuration could not be read." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *presenter = self.presentedViewController ?: self; [presenter presentViewController:alert animated:YES completion:nil];
}
- (void)showAdvanced {
    NSError *error = nil; NSDictionary *next = [self collect:NO error:&error]; if (!next) { [self error:error.localizedDescription]; return; }
    UIViewController *controller = [UIViewController new]; controller.title = @"Advanced JSON";
    self.editor = [UITextView new]; self.editor.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular]; self.editor.autocorrectionType = UITextAutocorrectionTypeNo; self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.editor.accessibilityIdentifier = @"jsonEditor"; self.editor.text = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:next options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding];
    controller.view = self.editor;
    controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(closeModal)];
    controller.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save" style:UIBarButtonItemStyleDone target:self action:@selector(saveAdvanced)];
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:controller] animated:YES completion:nil];
}
- (void)closeModal { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)saveAdvanced {
    NSError *error = nil; NSMutableDictionary *profile = XMRParseProfile([self.editor.text dataUsingEncoding:NSUTF8StringEncoding], &error);
    if (!profile || !XMRSaveProfile(profile,self.profilePath,&error)) { [self error:error.localizedDescription]; return; }
    self.profile = profile; [self render]; [self closeModal];
}
- (void)importTapped {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON,UTTypePlainText,UTTypeData] asCopy:YES];
    picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject; if (!url) return;
    BOOL access = [url startAccessingSecurityScopedResource]; NSError *error = nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
    NSData *data = [attrs[NSFileSize] unsignedLongLongValue] <= 256*1024 ? [NSData dataWithContentsOfURL:url options:0 error:&error] : nil;
    NSMutableDictionary *imported = data ? XMRParseProfile(data,&error) : nil;
    if (access) [url stopAccessingSecurityScopedResource];
    if (!imported) { [self error:error.localizedDescription ?: @"File exceeds 256 KB."]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Replace saved settings?" message:@"Review the wallet and pools after import. Import never starts mining automatically." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        imported[@"xmrand"][@"autostart"] = @NO; NSError *failure = nil;
        if (!XMRSaveProfile(imported,self.profilePath,&failure)) { [self error:failure.localizedDescription]; return; }
        self.profile = imported; [self render];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportTapped {
    if (![self save:NO]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export private configuration?" message:@"The file includes your wallet/account, pool passwords and any advanced API credentials. Remove private values before sharing it." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Choose destination" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *url = [directory URLByAppendingPathComponent:@"xmrand-config.json"]; NSError *error = nil;
        if (!XMRSaveProfile(self.profile,url.path,&error)) { [self error:error.localizedDescription]; return; }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = self.view; share.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2,self.view.bounds.size.height/2,1,1);
        share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *failure) { [NSFileManager.defaultManager removeItemAtURL:directory error:nil]; };
        [self presentViewController:share animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showGuide {
    UIViewController *controller = [UIViewController new]; controller.title = @"Setup and how-to";
    WKWebView *web = [WKWebView new]; controller.view = web;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"public-setup" withExtension:@"html"];
    if (url) [web loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
    else [web loadHTMLString:@"<h1>Setup guide is missing</h1><p>Use the public setup guide from the same source release before mining.</p>" baseURL:nil];
    controller.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(closeModal)];
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:controller] animated:YES completion:nil];
}
@end
