

#import "NSString+Localization.h"

@implementation NSString (Localization)

- (NSString *)localizedString {
    // The app's own strings win; the package's .lproj files are the fallback.
    NSString *localized = [[NSBundle mainBundle] localizedStringForKey:self value:self table:nil];
#ifdef SWIFTPM_MODULE_BUNDLE
    if ([localized isEqualToString:self]) {
        NSBundle *bundle = SWIFTPM_MODULE_BUNDLE;
        if (bundle) localized = [bundle localizedStringForKey:self value:self table:nil];
    }
#endif
    return localized ?: self;
}

@end
