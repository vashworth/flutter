// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterSceneDelegate.h"

#import "flutter/shell/platform/darwin/common/framework/Headers/FlutterMacros.h"
#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterPluginAppLifeCycleDelegate.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterAppDelegate_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterSharedApplication.h"

#import <os/log.h>
#include <memory>

#include "flutter/common/constants.h"
#include "flutter/fml/memory/weak_ptr.h"
#include "flutter/fml/message_loop.h"

FLUTTER_ASSERT_ARC

@interface FlutterSceneDelegate () {
}
@property(nonatomic, strong) FlutterPluginSceneLifeCycleDelegate* lifeCycleDelegate;
@end

@implementation FlutterSceneDelegate

- (instancetype)init {
  if (self = [super init]) {
      _lifeCycleDelegate = [[FlutterPluginSceneLifeCycleDelegate alloc] init];
//    id appDelegate = FlutterSharedApplication.application.delegate;
//
//    if ([appDelegate respondsToSelector:@selector(sceneLifeCycleDelegate)]) {
//        FlutterPluginSceneLifeCycleDelegate* sceneLifeCycleDelegate = [appDelegate sceneLifeCycleDelegate];
//        if (sceneLifeCycleDelegate == nil || sceneLifeCycleDelegate == NULL) {
//            _lifeCycleDelegate = [[FlutterPluginSceneLifeCycleDelegate alloc] init];
//        } else {
//            _lifeCycleDelegate = sceneLifeCycleDelegate;
//        }
//      
//    } else {
//        _lifeCycleDelegate = [[FlutterPluginSceneLifeCycleDelegate alloc] init];
//    }
  }
  return self;
}

/// Tells the delegate about the addition of a scene to the app.
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  NSLog(@"Scene willConnectToSession");
  NSObject<UIApplicationDelegate>* appDelegate = FlutterSharedApplication.application.delegate;
  if (appDelegate.window.rootViewController) {
    NSLog(@"WARNING - The UIApplicationDelegate is setting up the UIWindow and "
          @"UIWindow.rootViewController at launch. This was deprecated after the "
          @"UISceneDelegate adoption. Setup logic should be moved to a UISceneDelegate.");
    // If this is not nil we are running into a case where someone is manually
    // performing root view controller setup in the UIApplicationDelegate.
    UIWindowScene* windowScene = (UIWindowScene*)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = appDelegate.window.rootViewController;
    appDelegate.window = self.window;
    [self.window makeKeyAndVisible];
  }

  id appDelegate2 = FlutterSharedApplication.application.delegate;

  if ([appDelegate2 respondsToSelector:@selector(setScene:)]) {
    [appDelegate2 setScene:scene];
  }

  // We can't stash the plugins in the app delegate because the scene connects before they're registered.
  // if ([appDelegate2 respondsToSelector:@selector(sceneLifeCycleDelegate)]) {
  //   self.lifeCycleDelegate = [appDelegate2 sceneLifeCycleDelegate];
  // }
}

/// Adds a plugin to the life cycle delegate, which will send callbacks when events happen
- (void)addSceneLifeCycleDelegate:(NSObject<FlutterSceneLifeCycleDelegate>*)delegate {
  FML_LOG(ERROR) << "addSceneLifeCycleDelegate";
  [self.lifeCycleDelegate addDelegate:delegate];
}

- (void)sceneDidBecomeActive:(UIScene*)scene {
  [self.lifeCycleDelegate sceneDidBecomeActive:scene];
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  [self.lifeCycleDelegate sceneDidEnterBackground:scene];
}

// - (void)windowScene:(UIWindowScene*)windowScene
//     performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
//                completionHandler:(void (^)(BOOL succeeded))completionHandler {
//   id appDelegate = FlutterSharedApplication.application.delegate;
//   if ([appDelegate respondsToSelector:@selector(lifeCycleDelegate)]) {
//     FlutterPluginAppLifeCycleDelegate* lifeCycleDelegate = [appDelegate lifeCycleDelegate];
//     [lifeCycleDelegate application:FlutterSharedApplication.application
//         performActionForShortcutItem:shortcutItem
//                    completionHandler:completionHandler];
//   }
// }

// static NSDictionary<UIApplicationOpenURLOptionsKey, id>* ConvertOptions(
//     UISceneOpenURLOptions* options) {
//   if (@available(iOS 14.5, *)) {
//     return @{
//       UIApplicationOpenURLOptionsSourceApplicationKey : options.sourceApplication
//           ? options.sourceApplication
//           : [NSNull null],
//       UIApplicationOpenURLOptionsAnnotationKey : options.annotation ? options.annotation
//                                                                     : [NSNull null],
//       UIApplicationOpenURLOptionsOpenInPlaceKey : @(options.openInPlace),
//       UIApplicationOpenURLOptionsEventAttributionKey : options.eventAttribution
//           ? options.eventAttribution
//           : [NSNull null],
//     };
//   } else {
//     return @{
//       UIApplicationOpenURLOptionsSourceApplicationKey : options.sourceApplication
//           ? options.sourceApplication
//           : [NSNull null],
//       UIApplicationOpenURLOptionsAnnotationKey : options.annotation ? options.annotation
//                                                                     : [NSNull null],
//       UIApplicationOpenURLOptionsOpenInPlaceKey : @(options.openInPlace),
//     };
//   }
// }

// - (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
//   id appDelegate = FlutterSharedApplication.application.delegate;
//   if ([appDelegate respondsToSelector:@selector(lifeCycleDelegate)]) {
//     FlutterPluginAppLifeCycleDelegate* lifeCycleDelegate = [appDelegate lifeCycleDelegate];
//     for (UIOpenURLContext* context in URLContexts) {
//       [lifeCycleDelegate application:FlutterSharedApplication.application
//                              openURL:context.URL
//                              options:ConvertOptions(context.options)];
//     };
//   }
// }

@end
