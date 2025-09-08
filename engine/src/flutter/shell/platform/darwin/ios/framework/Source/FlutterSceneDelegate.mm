// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterSceneDelegate.h"

#import "flutter/shell/platform/darwin/common/framework/Headers/FlutterMacros.h"
#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterPluginAppLifeCycleDelegate.h"
#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterViewController.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterAppDelegate_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterEngine_Internal.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterSharedApplication.h"

#import <UserNotifications/UserNotifications.h>
#import <os/log.h>
#include <memory>

#include "flutter/common/constants.h"
#include "flutter/fml/memory/weak_ptr.h"
#include "flutter/fml/message_loop.h"

FLUTTER_ASSERT_ARC

@implementation FlutterSceneDelegate

@synthesize sceneLifeCycleDelegate;

- (instancetype)init {
  if (self = [super init]) {
    self.sceneLifeCycleDelegate = [[FlutterPluginSceneLifeCycleDelegate alloc] init];
  }
  return self;
}

/// Tells the delegate about the addition of a scene to the app.
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  // NSLog(@"Scene willConnectToSession");
  NSObject<UIApplicationDelegate>* appDelegate = FlutterSharedApplication.application.delegate;
  if ([appDelegate respondsToSelector:@selector(window)] && appDelegate.window.rootViewController) {
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
  if ([self.window.rootViewController isKindOfClass:[FlutterViewController class]]) {
    [self.sceneLifeCycleDelegate
        addFlutterEngine:((FlutterViewController*)self.window.rootViewController).engine];
  }

  [self.sceneLifeCycleDelegate scene:scene willConnectToSession:session options:connectionOptions];
}

- (void)sceneDidDisconnect:(UIScene*)scene {
  [self.sceneLifeCycleDelegate sceneDidDisconnect:scene];
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  [self.sceneLifeCycleDelegate sceneWillEnterForeground:scene];
}

- (void)sceneDidBecomeActive:(UIScene*)scene {
  [self.sceneLifeCycleDelegate sceneDidBecomeActive:scene];
}

- (void)sceneWillResignActive:(UIScene*)scene {
  [self.sceneLifeCycleDelegate sceneWillResignActive:scene];
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  [self.sceneLifeCycleDelegate sceneDidEnterBackground:scene];
}

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
  [self.sceneLifeCycleDelegate scene:scene openURLContexts:URLContexts];
}

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType {
  [self.sceneLifeCycleDelegate scene:scene willContinueUserActivityWithType:userActivityType];
}

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity {
  [self.sceneLifeCycleDelegate scene:scene continueUserActivity:userActivity];
}

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error {
  [self.sceneLifeCycleDelegate scene:scene
      didFailToContinueUserActivityWithType:userActivityType
                                      error:error];
}

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity {
  [self.sceneLifeCycleDelegate scene:scene didUpdateUserActivity:userActivity];
}

// - (void)windowScene:(UIWindowScene*)windowScene
//     didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry {
// }

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler {
  [self.sceneLifeCycleDelegate windowScene:windowScene
              performActionForShortcutItem:shortcutItem
                         completionHandler:completionHandler];
}

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata {
  [self.sceneLifeCycleDelegate windowScene:windowScene
      userDidAcceptCloudKitShareWithMetadata:cloudKitShareMetadata];
}

// - (UISceneWindowingControlStyle *) preferredWindowingControlStyleForScene:(UIWindowScene *)
// windowScene;

- (NSUserActivity*)stateRestorationActivityForScene:(UIScene*)scene {
  return [self.sceneLifeCycleDelegate stateRestorationActivityForScene:scene];
}

- (void)scene:(UIScene*)scene
    restoreInteractionStateWithUserActivity:(NSUserActivity*)stateRestorationActivity {
  return [self.sceneLifeCycleDelegate scene:scene
      restoreInteractionStateWithUserActivity:stateRestorationActivity];
}

@end
