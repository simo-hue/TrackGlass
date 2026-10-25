#ifndef TG_PRIVATE_API_H
#define TG_PRIVATE_API_H
#include <stdbool.h>
#import <Foundation/Foundation.h>
#import "TGPrivateFields.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    bool dockSwipe;
    bool gestureEvents;
    bool fluidTouchGesture;
    bool forceEvent;
    bool hidEventClass;
    // 0: unavailable, 1: CGEventSetHIDEvent, 2: CGEventSetIOHIDEvent.
    uint8_t attachmentSymbol;
} PrivateAPICapabilities;

// Immutable process-wide snapshot. Private framework handles remain open.
FOUNDATION_EXPORT PrivateAPICapabilities TGPrivateAPIGetCapabilities(void);

// Uncached dependency-injected probe for missing-symbol/OS-change tests.
// It never calls the returned function pointers or creates a private event.
typedef void * _Nullable (*TGSymbolLookup)(const char *name);
typedef Class _Nullable (*TGClassLookup)(const char *name);
FOUNDATION_EXPORT PrivateAPICapabilities TGPrivateAPIProbe(TGSymbolLookup symbols, TGClassLookup classes);

NS_ASSUME_NONNULL_END
#endif
