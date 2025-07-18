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
@property(nonatomic, strong) NSMutableSet<NSNumber*>* seenEngineIdentifiers;
@end

@implementation FlutterSceneDelegate

- (instancetype)init {
  if (self = [super init]) {
    _lifeCycleDelegate = nil;
    _seenEngineIdentifiers = [NSMutableSet set];
  }
  return self;
}

// Proposal 1 & 2
- (void)setSceneLifeCycleDelegate:(FlutterPluginSceneLifeCycleDelegate*)delegate engineIdentifier:(int64_t)engineIdentifier {
  NSNumber* engineID = @(engineIdentifier);
  if ([self.seenEngineIdentifiers containsObject:engineID]) {
    // FML_LOG(ERROR) << "Scene is already registered with this engine. Discarding.";
    return;
  }
  // FML_LOG(ERROR) << "New engine, adding to scene.";
  [self.seenEngineIdentifiers addObject:engineID];
  self.lifeCycleDelegate = delegate;
}

// Proposal 3
// - (void)setSceneLifeCycleDelegate {
//   FML_LOG(ERROR) << "Connecting the FlutterSceneDelegate to the plugin delegates.";
//   id appDelegate = FlutterSharedApplication.application.delegate;
//   self.lifeCycleDelegate = [appDelegate sceneLifeCycleDelegate];
// }

/// Tells the delegate about the addition of a scene to the app.
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  // NSLog(@"Scene willConnectToSession");
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

  // Proposal 3
  // [self setSceneLifeCycleDelegate];

}

- (void)sceneDidDisconnect:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneDidDisconnect";
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneWillEnterForeground";
}

- (void)sceneDidBecomeActive:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneDidBecomeActive";
  [self.lifeCycleDelegate sceneDidBecomeActive:scene];
}

- (void)sceneWillResignActive:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneWillResignActive";
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneDidEnterBackground";
  [self.lifeCycleDelegate sceneDidEnterBackground:scene];
}

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
  // FML_LOG(ERROR) << "scene:openURLContexts";
}

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType {
  // FML_LOG(ERROR) << "scene:willContinueUserActivityWithType";
}

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity {
  // FML_LOG(ERROR) << "scene:continueUserActivity";
}

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error {
  // FML_LOG(ERROR) << "scene:didFailToContinueUserActivityWithType";
}

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity {
  // FML_LOG(ERROR) << "scene:didUpdateUserActivity";
}

- (void)windowScene:(UIWindowScene*)windowScene
    didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry {
  // FML_LOG(ERROR) << "windowScene:didUpdateEffectiveGeometry";
}

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler {
  // FML_LOG(ERROR) << "windowScene:performActionForShortcutItem";
  [self.lifeCycleDelegate windowScene:windowScene
         performActionForShortcutItem:shortcutItem
                    completionHandler:completionHandler];
  //   id appDelegate = FlutterSharedApplication.application.delegate;
  //   if ([appDelegate respondsToSelector:@selector(lifeCycleDelegate)]) {
  //     FlutterPluginAppLifeCycleDelegate* lifeCycleDelegate = [appDelegate lifeCycleDelegate];
  //     [lifeCycleDelegate application:FlutterSharedApplication.application
  //         performActionForShortcutItem:shortcutItem
  //                    completionHandler:completionHandler];
  //   }
}

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata {
  // FML_LOG(ERROR) << "windowScene:userDidAcceptCloudKitShareWithMetadata";
}

// - (UISceneWindowingControlStyle *) preferredWindowingControlStyleForScene:(UIWindowScene *)
// windowScene;


/** This is the NSUserActivity that you use to restore state when the Scene reconnects.
  It can be the same activity that you use for handoff or spotlight, or it can be a separate activity
  with a different activity type and/or userInfo.

  This object must be lightweight. You should store the key information about what the user was doing last.

  After the system calls this function, and before it saves the activity in the restoration file, if the returned NSUserActivity has a
  delegate (NSUserActivityDelegate), the function userActivityWillSave calls that delegate. Additionally, if any UIResponders have the activity
  set as their userActivity property, the system calls the UIResponder updateUserActivityState function to update the activity.
  This happens synchronously and ensures that the system has filled in all the information for the activity before saving it.
*/
- (NSUserActivity *) stateRestorationActivityForScene:(UIScene *) scene {
  FML_LOG(ERROR) << "scene:stateRestorationActivityForScene";
  // Saves activity to the state

  // For each engine, get the state

  //  NSData* restorationData = [self.engine.restorationPlugin restorationData];
  // NSUserActivity* activity = scene.userActivity;
  // if (!activity) {
  //   activity = [[NSUserActivity alloc] initWithActivityType:scene.session.configuration.name];
  // }
  // [activity addUserInfoEntriesFromDictionary:@{kFlutterRestorationStateAppData : restorationData}];
  // return activity;


  return scene.userActivity;
}

- (void) scene:(UIScene *) scene
restoreInteractionStateWithUserActivity:(NSUserActivity *) stateRestorationActivity {
  FML_LOG(ERROR) << "scene:restoreInteractionStateWithUserActivity";
}

@end
