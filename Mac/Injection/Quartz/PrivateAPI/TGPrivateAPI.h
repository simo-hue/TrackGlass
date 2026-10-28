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

FOUNDATION_EXPORT id _Nullable TGCreateDockHIDEvent(int64_t kind, int64_t phase, double progress, double velocity);
// G-NC trial: a FluidTouchGesture (type 27) HIDEvent with the given motion/flavor, phase in the options and progress.
FOUNDATION_EXPORT id _Nullable TGCreateFluidTouchHIDEvent(int64_t motion, int64_t flavor, int64_t phase, double progress);
// G-FORCE trial: a Force (type 32) HIDEvent carrying stage, stage pressure and progress (behavior 0).
FOUNDATION_EXPORT id _Nullable TGCreateForceHIDEvent(int64_t stage, double pressure, double progress);
// Attaches a HIDEvent to a CGEvent through the resolved private symbol; false when the mechanism is unavailable.
FOUNDATION_EXPORT bool TGAttachHIDEvent(CGEventRef event, id hidEvent);
FOUNDATION_EXPORT bool TGAttachDockHIDEvent(CGEventRef event, id hidEvent);
NS_ASSUME_NONNULL_END
#endif
