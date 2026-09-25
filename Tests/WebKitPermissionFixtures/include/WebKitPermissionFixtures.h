#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
WKSecurityOrigin *FSOrigin(NSString *scheme, NSString *host, NSInteger port);
WKFrameInfo *FSNilRequestFrame(BOOL mainFrame, WKSecurityOrigin *origin, WKWebView * _Nullable view);
NSUInteger FSRequestReads(WKFrameInfo *frame);
void FSRequestPermission(id<WKUIDelegate> delegate, WKWebView *view, WKSecurityOrigin *origin,
                         WKFrameInfo *frame, WKMediaCaptureType type,
                         void (^completion)(WKPermissionDecision));
BOOL FSConfigureMockCapture(WKPreferences *preferences);
NS_ASSUME_NONNULL_END
