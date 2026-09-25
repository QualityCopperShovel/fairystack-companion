#import "WebKitPermissionFixtures.h"

// NSObject doubles intentionally return nil at the Objective-C boundary. Swift
// cannot implement that override: it imports request as a nonoptional URLRequest.
// No WebKit private object allocation/ivars or production swizzling is involved.
@interface FSOriginFixture : NSObject
@property(nonatomic, copy) NSString *protocol;
@property(nonatomic, copy) NSString *host;
@property(nonatomic) NSInteger port;
@end
@implementation FSOriginFixture
@end
@interface FSFrameFixture : NSObject
@property(nonatomic) BOOL isMainFrame;
@property(nonatomic, strong) WKSecurityOrigin *securityOrigin;
@property(nonatomic, weak) WKWebView *webView;
@property(nonatomic) NSUInteger reads;
@end
@implementation FSFrameFixture
- (NSURLRequest *)request { self.reads++; return nil; }
@end
WKSecurityOrigin *FSOrigin(NSString *scheme, NSString *host, NSInteger port) {
    FSOriginFixture *origin = [FSOriginFixture new];
    origin.protocol = scheme; origin.host = host; origin.port = port;
    return (WKSecurityOrigin *)origin;
}
WKFrameInfo *FSNilRequestFrame(BOOL mainFrame, WKSecurityOrigin *origin, WKWebView *view) {
    FSFrameFixture *frame = [FSFrameFixture new];
    frame.isMainFrame = mainFrame; frame.securityOrigin = origin; frame.webView = view;
    return (WKFrameInfo *)frame;
}
NSUInteger FSRequestReads(WKFrameInfo *frame) { return ((FSFrameFixture *)frame).reads; }
void FSRequestPermission(id<WKUIDelegate> delegate, WKWebView *view, WKSecurityOrigin *origin,
                         WKFrameInfo *frame, WKMediaCaptureType type,
                         void (^completion)(WKPermissionDecision)) {
    [delegate webView:view requestMediaCapturePermissionForOrigin:origin initiatedByFrame:frame type:type decisionHandler:completion];
}
// Explicit SPI setters: their leading underscore does not follow KVC's setter
// naming convention. KVC would throw instead of configuring fake devices.
@interface WKPreferences (FSCaptureTestSPI)
- (void)_setMediaDevicesEnabled:(BOOL)enabled;
- (void)_setMockCaptureDevicesEnabled:(BOOL)enabled;
- (void)_setMockCaptureDevicesPromptEnabled:(BOOL)enabled;
- (BOOL)_mockCaptureDevicesEnabled;
@end
BOOL FSConfigureMockCapture(WKPreferences *preferences) {
    // WebKit's own test SPI, confined to this test target. Missing SPI fails CI.
    if (![preferences respondsToSelector:@selector(_setMediaDevicesEnabled:)] ||
        ![preferences respondsToSelector:@selector(_setMockCaptureDevicesEnabled:)] ||
        ![preferences respondsToSelector:@selector(_setMockCaptureDevicesPromptEnabled:)] ||
        ![preferences respondsToSelector:@selector(_mockCaptureDevicesEnabled)]) return NO;
    [preferences _setMediaDevicesEnabled:YES];
    [preferences _setMockCaptureDevicesEnabled:YES];
    [preferences _setMockCaptureDevicesPromptEnabled:YES];
    return [preferences _mockCaptureDevicesEnabled];
}
