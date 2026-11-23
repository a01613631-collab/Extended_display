// Bridging header: declaraciones de la API PRIVADA CGVirtualDisplay (CoreGraphics).
//
// No es pública ni está documentada; estas declaraciones describen lo que macOS 14/15 expone
// en tiempo de ejecución. Todo su uso está aislado en VirtualDisplayManager.swift.
//
// Las clases se declaran weak_import: si una actualización de macOS las elimina, la app
// sigue arrancando (las referencias quedan en nil) y VirtualDisplayManager.isAvailable
// devuelve false para mostrar un error claro en lugar de fallar al lanzar.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

__attribute__((weak_import))
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic, copy, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

__attribute__((weak_import))
@interface CGVirtualDisplayMode : NSObject
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

__attribute__((weak_import))
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;
@end

__attribute__((weak_import))
@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) uint32_t hiDPI;
@property (nonatomic, readonly) NSArray<CGVirtualDisplayMode *> *modes;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
