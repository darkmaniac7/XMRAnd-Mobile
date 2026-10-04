#import <UIKit/UIKit.h>

@interface MinerSettingsViewController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *profilePath;
@property(nonatomic, copy) NSString *minerLogPath;
@property(nonatomic, copy) void (^onStart)(void);
@property(nonatomic, copy) void (^onStop)(void);
@property(nonatomic, copy) NSString *(^miningStatus)(void);
@property(nonatomic, copy) BOOL (^isRunning)(void);
@end
