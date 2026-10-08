#import <UIKit/UIKit.h>

@interface NRSSItemsViewController : UITableViewController
- (instancetype)initWithFeedID:(NSString *)feedID;
- (void)refresh;
@end
