/*
 * Logging stubs for STHIDEventGenerator (IOHID).
 * Upstream module: OwnGoalStudio STHIDEventGenerator (GPL-2.0).
 */
#import <Foundation/Foundation.h>
#import <Foundation/NSObjCRuntime.h>

FOUNDATION_EXPORT BOOL iohidLoggingEnabled;
FOUNDATION_EXPORT BOOL iohidVerboseLoggingEnabled;

#define TVLog(fmt, ...)                                                                                                \
    do {                                                                                                               \
        if (iohidLoggingEnabled)                                                                                       \
            NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);                                 \
    } while (0)

#define TVLogVerbose(fmt, ...)                                                                                         \
    do {                                                                                                               \
        if (iohidVerboseLoggingEnabled)                                                                                \
            NSLog((@"%s:%d " fmt "\r"), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);                                 \
    } while (0)
