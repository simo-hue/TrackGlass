#pragma once
#include <CoreGraphics/CoreGraphics.h>

// Numeric facts only; independently declared from SPEC Appendix B and:
// https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/TouchSimulator.m
// https://github.com/noah-nuebling/mac-mouse-fix/blob/master/Helper/Core/Touch/GestureScrollSimulator.m
// Verified 2026-10-25. Event types 29/30 are values, not CGEventField keys.
static const CGEventType TGEventTypeGesture = 29;
static const CGEventType TGEventTypeDockCompanion = 30;
static const CGEventField TGFieldEventType = 55;
static const CGEventField TGFieldDirectionInvertedFromDevice = 137;
static const CGEventField TGFieldHIDEventType = 110;
static const CGEventField TGFieldGesturePhase = 132;
static const CGEventField TGFieldDockPhase = 134;
static const CGEventField TGFieldMagnification = 113;
static const CGEventField TGFieldRotation = 114;
static const CGEventField TGFieldSwipeMask = 115;
static const CGEventField TGFieldGestureDeltaX = 116;
static const CGEventField TGFieldGestureDeltaY = 119;
static const CGEventField TGFieldDockProgress = 124;
static const CGEventField TGFieldDockProgressFloatBits = 135;
static const CGEventField TGFieldDockTypeDenormal = 119;
static const CGEventField TGFieldDockTypeDenormalAlternate = 139;
static const CGEventField TGFieldDockType = 123;
static const CGEventField TGFieldDockTypeAlternate = 165;
static const CGEventField TGFieldDockInverted = 136;
static const CGEventField TGFieldDockExitSpeedX = 129;
static const CGEventField TGFieldDockExitSpeedY = 130;
static const CGEventField TGFieldDockMarker = 41;
static const int64_t TGDockMarkerValue = 33231;

// IOHID event subtype values: SPEC Appendix B, MMF TouchSimulator.m and
// https://github.com/calftrail/Touch/blob/master/TouchSynthesis/TouchEvents.h
enum {
    TGHIDRotation = 5, TGHIDScroll = 6, TGHIDZoom = 8, TGHIDVelocity = 9,
    TGHIDNavigationSwipe = 16, TGHIDZoomToggle = 22, TGHIDDockSwipe = 23,
    TGHIDFluidTouchGesture = 27, TGHIDForce = 32,
    TGHIDGestureBegan = 61, TGHIDGestureEnded = 62
};
enum {
    TGPhaseUndefined = 0, TGPhaseBegan = 1, TGPhaseChanged = 2,
    TGPhaseEnded = 4, TGPhaseCancelled = 8, TGPhaseMayBegin = 128
};
enum { TGMomentumNone = 0, TGMomentumBegin = 1, TGMomentumContinue = 2, TGMomentumEnd = 3 };
enum { TGSwipeUp = 1, TGSwipeDown = 2, TGSwipeLeft = 4, TGSwipeRight = 8 };

// Apple IOHIDEventFieldDefs/IOHIDEventTypes, as exposed by MMF Shared/IOKit/External.
// Field base = event type << 16; checked 2026-10-26.
enum {
    TGHIDPhaseShift = 24, TGHIDDockPrimary = 3,
    TGHIDDockMotionField = (23 << 16) | 1,
    TGHIDDockProgressField = (23 << 16) | 2,
    TGHIDDockFlavorField = (23 << 16) | 5,
    TGHIDVelocityXField = (9 << 16),
    TGHIDVelocityYField = (9 << 16) | 1,
    TGHIDVelocityZField = (9 << 16) | 2
};

// Gates G-NC / G-FORCE (SPEC §6.9.5, §6.9.6). Field offsets and enum values transcribed from Apple
// IOHIDFamily-1633.100.36 IOHIDEventFieldDefs.h / IOHIDEventTypes.h on 2026-10-28:
//   FluidTouchGesture (27): Mask |0, Motion |1, Progress |2, PositionX |3, PositionY |4, Flavor |5.
//   Force (32): Behavior |0, Progress |1, Stage |2, StagePressure |3.
//   IOHIDGestureMotion: FromRightEdge = 9.  IOHIDGestureFlavor: NotificationCenterPrimary = 1.
enum {
    TGHIDFluidMaskField = (27 << 16),
    TGHIDFluidMotionField = (27 << 16) | 1,
    TGHIDFluidProgressField = (27 << 16) | 2,
    TGHIDFluidPositionXField = (27 << 16) | 3,
    TGHIDFluidPositionYField = (27 << 16) | 4,
    TGHIDFluidFlavorField = (27 << 16) | 5,
    TGHIDForceBehaviorField = (32 << 16),
    TGHIDForceProgressField = (32 << 16) | 1,
    TGHIDForceStageField = (32 << 16) | 2,
    TGHIDForceStagePressureField = (32 << 16) | 3
};
enum { TGHIDGestureMotionFromRightEdge = 9, TGHIDGestureFlavorNotificationCenterPrimary = 1 };

// Legacy-field attempt for the fluid gesture (G-NC, macOS without the HID attachment): the swipe-family
// slots the Dock path proves (123 motion, 124 progress, 132/134 phase). No reference documents these slots
// for type 27; the physical gate decides. There is no documented slot set for Force (type 32), so that
// attempt exists only on the attached-HID-event path.
static const CGEventField TGFieldSwipeMotion = 123;
static const CGEventField TGFieldSwipeProgress = 124;
