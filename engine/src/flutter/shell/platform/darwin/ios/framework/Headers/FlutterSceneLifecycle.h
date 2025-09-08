// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_DARWIN_IOS_FRAMEWORK_HEADERS_FLUTTERSCENELIFECYCLE_H_
#define FLUTTER_SHELL_PLATFORM_DARWIN_IOS_FRAMEWORK_HEADERS_FLUTTERSCENELIFECYCLE_H_

NS_ASSUME_NONNULL_BEGIN

@class FlutterEngine;
@class FlutterViewController;

/**
 * Propagates `UIAppDelegate` callbacks to registered plugins.
 */
FLUTTER_DARWIN_EXPORT

// This is the class that holds all the engines associated with the scene. It is held by the
// FlutterSceneDelegate. The FlutterSceneDelegate forwards events to it and then it forwards the
// events FlutterEnginePluginSceneLifeCycleDelegate.
@interface FlutterPluginSceneLifeCycleDelegate : NSObject

- (void)addFlutterEngine:(FlutterEngine*)engine;

- (void)removeFlutterEngine:(FlutterEngine*)engine;

- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
                 options:(UISceneConnectionOptions*)connectionOptions;

- (void)sceneDidDisconnect:(UIScene*)scene;

- (void)sceneWillEnterForeground:(UIScene*)scene;

- (void)sceneDidBecomeActive:(UIScene*)scene;

- (void)sceneWillResignActive:(UIScene*)scene;

- (void)sceneDidEnterBackground:(UIScene*)scene;

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts;

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType;

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity;

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error;

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity;

// - (void)windowScene:(UIWindowScene*)windowScene
//     didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry;

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler;

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata;

- (NSUserActivity*)stateRestorationActivityForScene:(UIScene*)scene;

- (void)scene:(UIScene*)scene
    restoreInteractionStateWithUserActivity:(NSUserActivity*)stateRestorationActivity;
@end

// This is the protocol the SceneDelegate conforms to allow add to app use flutter plugin scene
// forwarding without subclassing the FlutterSceneDelegate.
@protocol FlutterSceneLifeCycleProvider

@property(nonatomic, strong) FlutterPluginSceneLifeCycleDelegate* sceneLifeCycleDelegate;
@end

// This is the protocol that Flutter plugins should conform to
@protocol FlutterSceneLifeCycleDelegate

@optional
- (void)flutterViewDidConnectToScene:(UIScene*)scene
                             options:(UISceneConnectionOptions*)connectionOptions;

- (void)sceneDidDisconnect:(UIScene*)scene;

- (void)sceneWillEnterForeground:(UIScene*)scene;

- (void)sceneDidBecomeActive:(UIScene*)scene;

- (void)sceneWillResignActive:(UIScene*)scene;

- (void)sceneDidEnterBackground:(UIScene*)scene;

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts;

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType;

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity;

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error;

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity;

// - (void)windowScene:(UIWindowScene*)windowScene
//     didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry;

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler;

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata;

@end

// This is the class that holds all the plugins. It is held by the FlutterEngine.
// The FlutterPluginSceneLifeCycleDelegate forwards events to it and then it forwards the events to
// the plugins.
@interface FlutterEnginePluginSceneLifeCycleDelegate : NSObject

- (void)addDelegate:(NSObject<FlutterSceneLifeCycleDelegate>*)delegate;

- (void)flutterViewDidConnectToScene:(UIScene*)scene
                             options:(UISceneConnectionOptions*)connectionOptions;

- (void)sceneDidDisconnect:(UIScene*)scene;

- (void)sceneWillEnterForeground:(UIScene*)scene;

- (void)sceneDidBecomeActive:(UIScene*)scene;

- (void)sceneWillResignActive:(UIScene*)scene;

- (void)sceneDidEnterBackground:(UIScene*)scene;

- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts;

- (void)scene:(UIScene*)scene willContinueUserActivityWithType:(NSString*)userActivityType;

- (void)scene:(UIScene*)scene continueUserActivity:(NSUserActivity*)userActivity;

- (void)scene:(UIScene*)scene
    didFailToContinueUserActivityWithType:(NSString*)userActivityType
                                    error:(NSError*)error;

- (void)scene:(UIScene*)scene didUpdateUserActivity:(NSUserActivity*)userActivity;

// - (void)windowScene:(UIWindowScene*)windowScene
//     didUpdateEffectiveGeometry:(UIWindowSceneGeometry*)previousEffectiveGeometry;

- (void)windowScene:(UIWindowScene*)windowScene
    performActionForShortcutItem:(UIApplicationShortcutItem*)shortcutItem
               completionHandler:(void (^)(BOOL succeeded))completionHandler;

- (void)windowScene:(UIWindowScene*)windowScene
    userDidAcceptCloudKitShareWithMetadata:(CKShareMetadata*)cloudKitShareMetadata;

@end

NS_ASSUME_NONNULL_END

#endif  // FLUTTER_SHELL_PLATFORM_DARWIN_IOS_FRAMEWORK_HEADERS_FLUTTERSCENELIFECYCLE_H_
