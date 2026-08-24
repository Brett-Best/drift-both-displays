#import <Foundation/Foundation.h>

FOUNDATION_EXPORT int NSExtensionMain(int argc, const char *argv[]);

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        return NSExtensionMain(argc, argv);
    }
}
