//
//  TargetBridge-Bridging-Header.h
//  TargetBridge
//
//  Private API declarations for CGVirtualDisplay and IOAVService.
//  Property names verified against Chromium's virtual_display_mac_util.mm.
//

#ifndef TargetBridge_Bridging_Header_h
#define TargetBridge_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/i2c/IOI2CInterface.h>

#import "../TBDisplaySender/TBLZ4AppleFrame.h"

static inline uint64_t TBChecksum64(const void *data, size_t length) {
    const uint8_t *bytes = (const uint8_t *)data;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (size_t index = 0; index < length; index++) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

// MARK: - CGVirtualDisplay Private API (macOS 14+)

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) CGSize   sizeInMillimeters;   // physical size (width, height) in mm
@property (nonatomic) uint32_t maxPixelsWide;       // max pixel width
@property (nonatomic) uint32_t maxPixelsHigh;       // max pixel height
@property (nonatomic) NSPoint  whitePoint;
@property (nonatomic) NSPoint  redPrimary;
@property (nonatomic) NSPoint  greenPrimary;
@property (nonatomic) NSPoint  bluePrimary;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic, copy) id terminationHandler;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double     refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

// MARK: - CGSDisplayMode (advanced resolution switching)

typedef struct {
    uint32_t modeID;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    double   refreshRate;
    uint32_t flags;        // bit 0x20000 = HiDPI
} CGSDisplayMode;

typedef int CGSConnectionID_t;
extern CGError CGSConfigureDisplayMode(CGSConnectionID_t connection, CGDirectDisplayID display, uint32_t modeID);
extern CGSConnectionID_t CGSMainConnectionID(void);

// MARK: - IOAVService Private API (Apple Silicon DDC)

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service,
                                   uint32_t chipAddress,
                                   uint32_t offset,
                                   void *outputBuffer,
                                   uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service,
                                    uint32_t chipAddress,
                                    uint32_t dataAddress,
                                    void *inputBuffer,
                                    uint32_t inputBufferSize);

extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);
extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t *service);

#endif /* TargetBridge_Bridging_Header_h */
