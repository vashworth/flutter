// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/ios/framework/Headers/FlutterSceneDelegate.h"

#import "flutter/shell/platform/darwin/common/InternalFlutterSwiftCommon/InternalFlutterSwiftCommon.h"
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

static BOOL IsPowerOfTwo(NSUInteger x) {
  return x != 0 && (x & (x - 1)) == 0;
}

static NSString* const kRestorationStateAppModificationKey = @"mod-date";

@interface FlutterPluginSceneLifeCycleDelegate () {
}
@property(nonatomic, strong) NSPointerArray* engines;
@property(nonatomic, strong) UISceneConnectionOptions* sceneConnectionOptions;
@end

@implementation FlutterPluginSceneLifeCycleDelegate
- (instancetype)init {
  if (self = [super init]) {
    _engines = [NSPointerArray weakObjectsPointerArray];
    _sceneConnectionOptions = nil;
  }
  return self;
}

- (void)addFlutterViewController:(FlutterViewController*)controller {
  // NSPointerArray is clever and assumes that unless a mutation operation has occurred on it that
  // has set one of its values to nil, nothing could have changed and it can skip compaction.
  // That's reasonable behaviour on a regular NSPointerArray but not for a weakObjectPointerArray.
  // As a workaround, we mutate it first. See: http://www.openradar.me/15396578
  [self.engines addPointer:nil];
  [self.engines compact];

  // Check if the engine is already in the array to avoid duplicates.
  if ([self.engines.allObjects containsObject:controller.engine]) {
    return;
  }

  NSLog(@"Engine added to scene");
  [self.engines addPointer:(__bridge void*)controller.engine];

  [controller.engine.sceneLifeCycleDelegate flutterViewController:controller
                                                didConnectToScene:(UIScene*)self
                                                          options:self.sceneConnectionOptions];
}

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions {
  // NSLog(@"Scene willConnectToSession");
  self.sceneConnectionOptions = connectionOptions;
}

- (void)sceneDidDisconnect:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneDidDisconnect";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate sceneDidDisconnect:scene];
  }
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneWillEnterForeground";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate sceneWillEnterForeground:scene];
  }
}

- (void)sceneDidBecomeActive:(UIScene*)scene {
  FML_LOG(ERROR) << "sceneDidBecomeActive";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate sceneDidBecomeActive:scene];
  }
}

- (void)sceneWillResignActive:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneWillResignActive";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate sceneWillResignActive:scene];
  }
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  // FML_LOG(ERROR) << "sceneDidEnterBackground";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate sceneDidEnterBackground:scene];
  }
}

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
  // FML_LOG(ERROR) << "scene:openURLContexts";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate scene:scene openURLContexts:URLContexts];
  }
}

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType {
  // FML_LOG(ERROR) << "scene:willContinueUserActivityWithType";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate scene:scene willContinueUserActivityWithType:userActivityType];
  }
}

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity {
  // FML_LOG(ERROR) << "scene:continueUserActivity";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate scene:scene continueUserActivity:userActivity];
  }
}

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error {
  // FML_LOG(ERROR) << "scene:didFailToContinueUserActivityWithType";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate scene:scene
        didFailToContinueUserActivityWithType:userActivityType
                                        error:error];
  }
}

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity {
  // FML_LOG(ERROR) << "scene:didUpdateUserActivity";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate scene:scene didUpdateUserActivity:userActivity];
  }
}

// - (void)windowScene:(UIWindowScene*)windowScene
//     didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry {
//   // FML_LOG(ERROR) << "windowScene:didUpdateEffectiveGeometry";
//   for (FlutterEngine* engine in [_engines allObjects]) {
//     if (!engine) {
//       continue;
//     }
//     [engine.sceneLifeCycleDelegate windowScene:windowScene
//     didUpdateEffectiveGeometry:previousEffectiveGeometry];
//   }
// }

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler {
  // FML_LOG(ERROR) << "windowScene:performActionForShortcutItem";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate windowScene:windowScene
                  performActionForShortcutItem:shortcutItem
                             completionHandler:completionHandler];
  }
}

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata {
  // FML_LOG(ERROR) << "windowScene:userDidAcceptCloudKitShareWithMetadata";
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    [engine.sceneLifeCycleDelegate windowScene:windowScene
        userDidAcceptCloudKitShareWithMetadata:cloudKitShareMetadata];
  }
}

// - (UISceneWindowingControlStyle *) preferredWindowingControlStyleForScene:(UIWindowScene *)
// windowScene;

/** This is the NSUserActivity that you use to restore state when the Scene reconnects.
  It can be the same activity that you use for handoff or spotlight, or it can be a separate
  activity with a different activity type and/or userInfo.

  This object must be lightweight. You should store the key information about what the user was
  doing last.

  After the system calls this function, and before it saves the activity in the restoration file, if
  the returned NSUserActivity has a delegate (NSUserActivityDelegate), the function
  userActivityWillSave calls that delegate. Additionally, if any UIResponders have the activity set
  as their userActivity property, the system calls the UIResponder updateUserActivityState function
  to update the activity. This happens synchronously and ensures that the system has filled in all
  the information for the activity before saving it.
*/
- (NSUserActivity*)stateRestorationActivityForScene:(UIScene*)scene {
  FML_LOG(ERROR) << "scene:stateRestorationActivityForScene";
  // Saves activity to the state
  NSUserActivity* activity = scene.userActivity;
  if (!activity) {
    activity = [[NSUserActivity alloc] initWithActivityType:scene.session.configuration.name];
  }

  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    UIViewController* vc = (UIViewController*)engine.viewController;
    NSString* restorationId = vc.restorationIdentifier;
    if (restorationId && restorationId.length > 0) {
      NSData* restorationData = [engine.restorationPlugin restorationData];
      if (restorationData) {
        int64_t stateDate = [self lastAppModificationTime];

        FML_LOG(ERROR) << "save for " << restorationId.UTF8String;
        [activity addUserInfoEntriesFromDictionary:@{restorationId : restorationData}];
        [activity addUserInfoEntriesFromDictionary:@{
          kRestorationStateAppModificationKey : [NSNumber numberWithLongLong:stateDate]
        }];
      }
    }
  }

  return activity;
}

- (void)scene:(UIScene*)scene
    restoreInteractionStateWithUserActivity:(NSUserActivity*)stateRestorationActivity {
  NSDictionary<NSString*, id>* userInfo = stateRestorationActivity.userInfo;
  for (FlutterEngine* engine in [_engines allObjects]) {
    if (!engine) {
      continue;
    }
    UIViewController* vc = (UIViewController*)engine.viewController;
    NSString* restorationId = vc.restorationIdentifier;
    if (restorationId && restorationId.length > 0) {
      NSNumber* stateDateNumber = userInfo[kRestorationStateAppModificationKey];
      int64_t stateDate = 0;
      if (stateDateNumber && [stateDateNumber isKindOfClass:[NSNumber class]]) {
        stateDate = [stateDateNumber longLongValue];
      }
      if (self.lastAppModificationTime != stateDate) {
        // Don't restore state if the app has been re-installed since the state was last saved
        return;
      }
      NSData* restorationData = userInfo[restorationId];
      if ([restorationData isKindOfClass:[NSData class]]) {
        [engine.restorationPlugin setRestorationData:restorationData];
      }
    }
  }
}

- (int64_t)lastAppModificationTime {
  NSDate* fileDate;
  NSError* error = nil;
  [[[NSBundle mainBundle] executableURL] getResourceValue:&fileDate
                                                   forKey:NSURLContentModificationDateKey
                                                    error:&error];
  NSAssert(error == nil, @"Cannot obtain modification date of main bundle: %@", error);
  return [fileDate timeIntervalSince1970];
}

@end

@implementation FlutterEnginePluginSceneLifeCycleDelegate {
  // Weak references to registered plugins.
  NSPointerArray* _delegates;
}

- (instancetype)init {
  if (self = [super init]) {
    _delegates = [NSPointerArray weakObjectsPointerArray];
  }
  return self;
}

- (void)addDelegate:(NSObject<FlutterSceneLifeCycleDelegate>*)delegate {
  [_delegates addPointer:(__bridge void*)delegate];
  if (IsPowerOfTwo([_delegates count])) {
    [_delegates compact];
  }
}

- (void)flutterViewController:(FlutterViewController*)controller
            didConnectToScene:(UIScene*)scene
                      options:(UISceneConnectionOptions*)connectionOptions {
  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate flutterViewController:controller didConnectToScene:scene options:connectionOptions];
    }
  }
}

- (void)sceneDidDisconnect:(UIScene*)scene {
  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate sceneDidDisconnect:scene];
    }
  }
}

- (void)sceneWillEnterForeground:(UIScene*)scene {
  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate sceneWillEnterForeground:scene];
    }
  }
}

- (void)sceneDidBecomeActive:(UIScene*)scene {
  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate sceneDidBecomeActive:scene];
    } else {
      Class classOfObject = object_getClass(delegate);
      NSLog(@"Class %@", classOfObject);
      unsigned int methodCount;
      Method* methodList = class_copyMethodList(classOfObject, &methodCount);
      for (unsigned int i = 0; i < methodCount; i++) {
        SEL selector = method_getName(methodList[i]);
        NSLog(@"Method #%d: %s", i, sel_getName(selector));
      }
    }
  }
}

- (void)sceneWillResignActive:(UIScene*)scene {
  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate sceneWillResignActive:scene];
    }
  }
}

- (void)sceneDidEnterBackground:(UIScene*)scene {
  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate sceneDidEnterBackground:scene];
    }
  }
}

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
}

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType {
}

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity {
}

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error {
}

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity {
}

// - (void)windowScene:(UIWindowScene*)windowScene
//     didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry {

// }

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler {
  FlutterPluginAppLifeCycleDelegate* appLifeCycleDelegate = [self applicationLifeCycleDelegate];

  for (NSObject<FlutterSceneLifeCycleDelegate>* delegate in [_delegates allObjects]) {
    if (!delegate) {
      continue;
    }
    if ([delegate respondsToSelector:_cmd]) {
      [delegate windowScene:windowScene
          performActionForShortcutItem:shortcutItem
                     completionHandler:completionHandler];
    } else {
      // Fallback to application callback
      if (appLifeCycleDelegate != nil) {
        [FlutterLogger
            logWarning:
                @"Plugin does not support scene. Falling back to application lifecycle event."];
        [appLifeCycleDelegate application:FlutterSharedApplication.application
             performActionForShortcutItem:shortcutItem
                        completionHandler:completionHandler];
      } else {
        [FlutterLogger logWarning:@"Plugin does not support scene"];
      }
    }
  }
}

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata {
}

- (FlutterPluginAppLifeCycleDelegate*)applicationLifeCycleDelegate {
  id appDelegate = FlutterSharedApplication.application.delegate;
  FlutterPluginAppLifeCycleDelegate* appLifeCycleDelegate = nil;
  if ([appDelegate respondsToSelector:@selector(lifeCycleDelegate)]) {
    appLifeCycleDelegate = [appDelegate lifeCycleDelegate];
  }
  return appLifeCycleDelegate;
}
@end
