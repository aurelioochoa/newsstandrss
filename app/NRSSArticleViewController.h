#import <UIKit/UIKit.h>

@class NRSSItem;

@interface NRSSArticleViewController : UIViewController
- (instancetype)initWithItem:(NRSSItem *)item feedTitle:(NSString *)feedTitle;
@end
