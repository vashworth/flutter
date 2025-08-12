// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:file/memory.dart';
import 'package:file_testing/file_testing.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/base/version.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/device_port_forwarder.dart';
import 'package:flutter_tools/src/ios/application_package.dart';
import 'package:flutter_tools/src/ios/core_devices.dart';
import 'package:flutter_tools/src/ios/devices.dart';
import 'package:flutter_tools/src/ios/ios_deploy.dart';
import 'package:flutter_tools/src/ios/iproxy.dart';
import 'package:flutter_tools/src/ios/mac.dart';
import 'package:flutter_tools/src/ios/xcode_debug.dart';
import 'package:flutter_tools/src/ios/xcodeproj.dart';
import 'package:flutter_tools/src/macos/xcode.dart';
import 'package:flutter_tools/src/mdns_discovery.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:test/fake.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../../src/common.dart';
import '../../src/context.dart' hide FakeXcodeProjectInterpreter;
import '../../src/fake_devices.dart';
import '../../src/fake_process_manager.dart';
import '../../src/fakes.dart';
import '../../src/package_config.dart';
import '../../src/throwing_pub.dart';

final macPlatform = FakePlatform(operatingSystem: 'macos', environment: <String, String>{});

final os = FakeOperatingSystemUtils(hostPlatform: HostPlatform.darwin_arm64);

void main() {
  late Artifacts artifacts;

  setUp(() {
    artifacts = Artifacts.test();
  });
  group('IOSDevice.startApp for CoreDevice', () {
    late FileSystem fileSystem;
    late FakeProcessManager processManager;
    late BufferLogger logger;
    late Xcode xcode;
    late FakeXcodeProjectInterpreter fakeXcodeProjectInterpreter;
    late XcodeProjectInfo projectInfo;

    setUp(() {
      logger = BufferLogger.test();
      fileSystem = MemoryFileSystem.test();
      processManager = FakeProcessManager.empty();
      projectInfo = XcodeProjectInfo(<String>['Runner'], <String>['Debug', 'Release'], <String>[
        'Runner',
      ], logger);
      fakeXcodeProjectInterpreter = FakeXcodeProjectInterpreter(
        projectInfo: projectInfo,
        xcodeVersion: Version(15, 0, 0),
      );
      xcode = Xcode.test(
        processManager: FakeProcessManager.any(),
        xcodeProjectInterpreter: fakeXcodeProjectInterpreter,
      );
    });
    group('launches app', () {
      group('in release mode', () {
        testUsingContext(
          'launches with Core Device without a debugger',
          () async {
            final fakeExactAnalytics = FakeExactAnalytics();
            final coreDeviceLauncher = FakeIOSCoreDeviceLauncher();
            final IOSDevice iosDevice = setUpIOSDevice(
              fileSystem: fileSystem,
              processManager: FakeProcessManager.any(),
              logger: logger,
              artifacts: artifacts,
              isCoreDevice: true,
              coreDeviceLauncher: coreDeviceLauncher,
              analytics: fakeExactAnalytics,
            );
            setUpIOSProject(fileSystem);
            final FlutterProject flutterProject = FlutterProject.fromDirectory(
              fileSystem.currentDirectory,
            );
            final buildableIOSApp = BuildableIOSApp(
              flutterProject.ios,
              'flutter',
              'My Super Awesome App',
            );
            fileSystem
                .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                .createSync(recursive: true);

            final LaunchResult launchResult = await iosDevice.startApp(
              buildableIOSApp,
              debuggingOptions: DebuggingOptions.disabled(BuildInfo.release),
              platformArgs: <String, Object>{},
            );

            expect(fileSystem.directory('build/ios/iphoneos'), exists);
            expect(launchResult.started, true);
            expect(processManager, hasNoRemainingExpectations);
            expect(coreDeviceLauncher.launchedWithLLDB, false);
            expect(coreDeviceLauncher.launchedWithXcode, false);
            expect(coreDeviceLauncher.launchedWithoutDebugger, true);
            expect(fakeExactAnalytics.sentEvents, [
              Event.appleUsageEvent(
                workflow: 'ios-physical-deployment',
                parameter: IOSDeploymentMethod.coreDeviceWithoutDebugger.name,
                result: 'release success',
              ),
            ]);
          },
          overrides: <Type, Generator>{
            ProcessManager: () => FakeProcessManager.any(),
            Pub: () => const ThrowingPub(),
            FileSystem: () => fileSystem,
            Logger: () => logger,
            OperatingSystemUtils: () => os,
            Platform: () => macPlatform,
            XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
            Xcode: () => xcode,
          },
        );

        testUsingContext(
          'fails when launch fails',
          () async {
            final fakeExactAnalytics = FakeExactAnalytics();
            final coreDeviceLauncher = FakeIOSCoreDeviceLauncher(withouDebuggerLaunchResult: false);
            final IOSDevice iosDevice = setUpIOSDevice(
              fileSystem: fileSystem,
              processManager: FakeProcessManager.any(),
              logger: logger,
              artifacts: artifacts,
              isCoreDevice: true,
              coreDeviceLauncher: coreDeviceLauncher,
              analytics: fakeExactAnalytics,
            );
            setUpIOSProject(fileSystem);
            final FlutterProject flutterProject = FlutterProject.fromDirectory(
              fileSystem.currentDirectory,
            );
            final buildableIOSApp = BuildableIOSApp(
              flutterProject.ios,
              'flutter',
              'My Super Awesome App',
            );
            fileSystem
                .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                .createSync(recursive: true);

            final LaunchResult launchResult = await iosDevice.startApp(
              buildableIOSApp,
              debuggingOptions: DebuggingOptions.disabled(BuildInfo.release),
              platformArgs: <String, Object>{},
            );

            expect(fileSystem.directory('build/ios/iphoneos'), exists);
            expect(launchResult.started, false);
            expect(processManager, hasNoRemainingExpectations);
            expect(coreDeviceLauncher.launchedWithLLDB, false);
            expect(coreDeviceLauncher.launchedWithXcode, false);
            expect(coreDeviceLauncher.launchedWithoutDebugger, true);
            expect(fakeExactAnalytics.sentEvents, [
              Event.appleUsageEvent(
                workflow: 'ios-physical-deployment',
                parameter: IOSDeploymentMethod.coreDeviceWithoutDebugger.name,
                result: 'launch failed',
              ),
            ]);
          },
          overrides: <Type, Generator>{
            ProcessManager: () => FakeProcessManager.any(),
            Pub: () => const ThrowingPub(),
            FileSystem: () => fileSystem,
            Logger: () => logger,
            OperatingSystemUtils: () => os,
            Platform: () => macPlatform,
            XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
            Xcode: () => xcode,
          },
        );
      });

      group('in debug mode', () {
        testUsingContext(
          'launches with Xcode',
          () async {
            final fakeExactAnalytics = FakeExactAnalytics();
            final coreDeviceLauncher = FakeIOSCoreDeviceLauncher();
            final IOSDevice iosDevice = setUpIOSDevice(
              fileSystem: fileSystem,
              processManager: FakeProcessManager.any(),
              logger: logger,
              artifacts: artifacts,
              isCoreDevice: true,
              coreDeviceLauncher: coreDeviceLauncher,
              analytics: fakeExactAnalytics,
            );

            setUpIOSProject(fileSystem);
            final FlutterProject flutterProject = FlutterProject.fromDirectory(
              fileSystem.currentDirectory,
            );
            final buildableIOSApp = BuildableIOSApp(
              flutterProject.ios,
              'flutter',
              'My Super Awesome App',
            );
            fileSystem
                .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                .createSync(recursive: true);

            final deviceLogReader = FakeDeviceLogReader();

            iosDevice.portForwarder = const NoOpDevicePortForwarder();
            iosDevice.setLogReader(buildableIOSApp, deviceLogReader);

            // Start writing messages to the log reader.
            Timer.run(() {
              deviceLogReader.addLine('Foo');
              deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
            });

            final LaunchResult launchResult = await iosDevice.startApp(
              buildableIOSApp,
              debuggingOptions: DebuggingOptions.enabled(
                const BuildInfo(
                  BuildMode.debug,
                  null,
                  buildName: '1.2.3',
                  buildNumber: '4',
                  treeShakeIcons: false,
                  packageConfigPath: '.dart_tool/package_config.json',
                ),
              ),
              platformArgs: <String, Object>{},
            );

            expect(logger.errorText, isEmpty);
            expect(fileSystem.directory('build/ios/iphoneos'), exists);
            expect(launchResult.started, true);
            expect(processManager, hasNoRemainingExpectations);
            expect(coreDeviceLauncher.launchedWithLLDB, false);
            expect(coreDeviceLauncher.launchedWithXcode, true);
            expect(coreDeviceLauncher.launchedWithoutDebugger, false);
            expect(fakeExactAnalytics.sentEvents, [
              Event.appleUsageEvent(
                workflow: 'ios-physical-deployment',
                parameter: IOSDeploymentMethod.coreDeviceWithXcode.name,
                result: 'debugging success',
              ),
            ]);
          },
          overrides: <Type, Generator>{
            ProcessManager: () => FakeProcessManager.any(),
            Pub: () => const ThrowingPub(),
            FileSystem: () => fileSystem,
            Logger: () => logger,
            OperatingSystemUtils: () => os,
            Platform: () => macPlatform,
            XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
            Xcode: () => xcode,
          },
        );

        testUsingContext(
          'fails when launch with Xcode fails',
          () async {
            final fakeExactAnalytics = FakeExactAnalytics();
            final coreDeviceLauncher = FakeIOSCoreDeviceLauncher(xcodeLaunchResult: false);
            final IOSDevice iosDevice = setUpIOSDevice(
              fileSystem: fileSystem,
              processManager: FakeProcessManager.any(),
              logger: logger,
              artifacts: artifacts,
              isCoreDevice: true,
              coreDeviceLauncher: coreDeviceLauncher,
              analytics: fakeExactAnalytics,
            );

            setUpIOSProject(fileSystem);
            final FlutterProject flutterProject = FlutterProject.fromDirectory(
              fileSystem.currentDirectory,
            );
            final buildableIOSApp = BuildableIOSApp(
              flutterProject.ios,
              'flutter',
              'My Super Awesome App',
            );
            fileSystem
                .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                .createSync(recursive: true);

            final deviceLogReader = FakeDeviceLogReader();

            iosDevice.portForwarder = const NoOpDevicePortForwarder();
            iosDevice.setLogReader(buildableIOSApp, deviceLogReader);

            // Start writing messages to the log reader.
            Timer.run(() {
              deviceLogReader.addLine('Foo');
              deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
            });

            final LaunchResult launchResult = await iosDevice.startApp(
              buildableIOSApp,
              debuggingOptions: DebuggingOptions.enabled(
                const BuildInfo(
                  BuildMode.debug,
                  null,
                  buildName: '1.2.3',
                  buildNumber: '4',
                  treeShakeIcons: false,
                  packageConfigPath: '.dart_tool/package_config.json',
                ),
              ),
              platformArgs: <String, Object>{},
            );

            expect(fileSystem.directory('build/ios/iphoneos'), exists);
            expect(launchResult.started, false);
            expect(processManager, hasNoRemainingExpectations);
            expect(coreDeviceLauncher.launchedWithLLDB, false);
            expect(coreDeviceLauncher.launchedWithXcode, true);
            expect(coreDeviceLauncher.launchedWithoutDebugger, false);
            expect(fakeExactAnalytics.sentEvents, [
              Event.appleUsageEvent(
                workflow: 'ios-physical-deployment',
                parameter: IOSDeploymentMethod.coreDeviceWithXcode.name,
                result: 'launch failed',
              ),
            ]);
          },
          overrides: <Type, Generator>{
            ProcessManager: () => FakeProcessManager.any(),
            Pub: () => const ThrowingPub(),
            FileSystem: () => fileSystem,
            Logger: () => logger,
            OperatingSystemUtils: () => os,
            Platform: () => macPlatform,
            XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
            Xcode: () => xcode,
          },
        );

        testUsingContext(
          'updates Generated.xcconfig after launch',
          () async {
            final IOSDevice iosDevice = setUpIOSDevice(
              fileSystem: fileSystem,
              processManager: FakeProcessManager.any(),
              logger: logger,
              artifacts: artifacts,
              isCoreDevice: true,
              coreDeviceControl: FakeIOSCoreDeviceControl(),
            );

            setUpIOSProject(fileSystem);
            final FlutterProject flutterProject = FlutterProject.fromDirectory(
              fileSystem.currentDirectory,
            );
            final buildableIOSApp = BuildableIOSApp(
              flutterProject.ios,
              'flutter',
              'My Super Awesome App',
            );
            fileSystem
                .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                .createSync(recursive: true);

            final deviceLogReader = FakeDeviceLogReader();

            iosDevice.portForwarder = const NoOpDevicePortForwarder();
            iosDevice.setLogReader(buildableIOSApp, deviceLogReader);

            // Start writing messages to the log reader.
            Timer.run(() {
              deviceLogReader.addLine('Foo');
              deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
            });

            final File config = fileSystem.directory('ios').childFile('Flutter/Generated.xcconfig');
            config.createSync(recursive: true);
            config.writeAsStringSync('CONFIGURATION_BUILD_DIR=/build/ios/iphoneos');
            String contents = config.readAsStringSync();
            expect(contents.contains('CONFIGURATION_BUILD_DIR'), isTrue);

            await iosDevice.startApp(
              buildableIOSApp,
              debuggingOptions: DebuggingOptions.enabled(
                const BuildInfo(
                  BuildMode.debug,
                  null,
                  buildName: '1.2.3',
                  buildNumber: '4',
                  treeShakeIcons: false,
                  packageConfigPath: '.dart_tool/package_config.json',
                ),
              ),
              platformArgs: <String, Object>{},
            );

            // Validate CoreDevice build settings were removed after launch
            contents = config.readAsStringSync();
            expect(contents.contains('CONFIGURATION_BUILD_DIR'), isFalse);
          },
          overrides: <Type, Generator>{
            ProcessManager: () => FakeProcessManager.any(),
            Pub: () => const ThrowingPub(),
            FileSystem: () => fileSystem,
            Logger: () => logger,
            OperatingSystemUtils: () => os,
            Platform: () => macPlatform,
            XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
            Xcode: () => xcode,
          },
        );

        group('with Xcode 26', () {
          late Xcode xcode;
          late FakeXcodeProjectInterpreter fakeXcodeProjectInterpreter;

          setUp(() {
            fakeXcodeProjectInterpreter = FakeXcodeProjectInterpreter(
              projectInfo: projectInfo,
              xcodeVersion: Version(26, 0, 0),
            );
            xcode = Xcode.test(
              processManager: FakeProcessManager.any(),
              xcodeProjectInterpreter: fakeXcodeProjectInterpreter,
            );
          });

          testUsingContext(
            'launches with Core Device with LLDB debugger',
            () async {
              final fakeExactAnalytics = FakeExactAnalytics();
              final coreDeviceLauncher = FakeIOSCoreDeviceLauncher();
              final IOSDevice iosDevice = setUpIOSDevice(
                fileSystem: fileSystem,
                processManager: FakeProcessManager.any(),
                logger: logger,
                artifacts: artifacts,
                isCoreDevice: true,
                coreDeviceLauncher: coreDeviceLauncher,
                analytics: fakeExactAnalytics,
              );

              setUpIOSProject(fileSystem);
              final FlutterProject flutterProject = FlutterProject.fromDirectory(
                fileSystem.currentDirectory,
              );
              final buildableIOSApp = BuildableIOSApp(
                flutterProject.ios,
                'flutter',
                'My Super Awesome App',
              );
              fileSystem
                  .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                  .createSync(recursive: true);

              final deviceLogReader = FakeDeviceLogReader();

              iosDevice.portForwarder = const NoOpDevicePortForwarder();
              iosDevice.setLogReader(buildableIOSApp, deviceLogReader);

              // Start writing messages to the log reader.
              Timer.run(() {
                deviceLogReader.addLine('Foo');
                deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
              });

              final LaunchResult launchResult = await iosDevice.startApp(
                buildableIOSApp,
                debuggingOptions: DebuggingOptions.enabled(
                  const BuildInfo(
                    BuildMode.debug,
                    null,
                    buildName: '1.2.3',
                    buildNumber: '4',
                    treeShakeIcons: false,
                    packageConfigPath: '.dart_tool/package_config.json',
                  ),
                ),
                platformArgs: <String, Object>{},
              );

              expect(logger.errorText, isEmpty);
              expect(fileSystem.directory('build/ios/iphoneos'), exists);
              expect(launchResult.started, true);
              expect(processManager, hasNoRemainingExpectations);
              expect(coreDeviceLauncher.launchedWithLLDB, true);
              expect(coreDeviceLauncher.launchedWithXcode, false);
              expect(coreDeviceLauncher.launchedWithoutDebugger, false);
              expect(fakeExactAnalytics.sentEvents, [
                Event.appleUsageEvent(
                  workflow: 'ios-physical-deployment',
                  parameter: IOSDeploymentMethod.coreDeviceWithLLDB.name,
                  result: 'debugging success',
                ),
              ]);
            },
            overrides: <Type, Generator>{
              ProcessManager: () => FakeProcessManager.any(),
              Pub: () => const ThrowingPub(),
              FileSystem: () => fileSystem,
              Logger: () => logger,
              OperatingSystemUtils: () => os,
              Platform: () => macPlatform,
              XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
              Xcode: () => xcode,
            },
          );

          testUsingContext(
            'launches with Xcode if LLDB fails',
            () async {
              final fakeExactAnalytics = FakeExactAnalytics();
              final coreDeviceLauncher = FakeIOSCoreDeviceLauncher(lldbLaunchResult: false);
              final IOSDevice iosDevice = setUpIOSDevice(
                fileSystem: fileSystem,
                processManager: FakeProcessManager.any(),
                logger: logger,
                artifacts: artifacts,
                isCoreDevice: true,
                coreDeviceLauncher: coreDeviceLauncher,
                analytics: fakeExactAnalytics,
              );

              setUpIOSProject(fileSystem);
              final FlutterProject flutterProject = FlutterProject.fromDirectory(
                fileSystem.currentDirectory,
              );
              final buildableIOSApp = BuildableIOSApp(
                flutterProject.ios,
                'flutter',
                'My Super Awesome App',
              );
              fileSystem
                  .directory('build/ios/Release-iphoneos/My Super Awesome App.app')
                  .createSync(recursive: true);

              final deviceLogReader = FakeDeviceLogReader();

              iosDevice.portForwarder = const NoOpDevicePortForwarder();
              iosDevice.setLogReader(buildableIOSApp, deviceLogReader);

              // Start writing messages to the log reader.
              Timer.run(() {
                deviceLogReader.addLine('Foo');
                deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
              });

              final LaunchResult launchResult = await iosDevice.startApp(
                buildableIOSApp,
                debuggingOptions: DebuggingOptions.enabled(
                  const BuildInfo(
                    BuildMode.debug,
                    null,
                    buildName: '1.2.3',
                    buildNumber: '4',
                    treeShakeIcons: false,
                    packageConfigPath: '.dart_tool/package_config.json',
                  ),
                ),
                platformArgs: <String, Object>{},
              );

              expect(logger.errorText, isEmpty);
              expect(fileSystem.directory('build/ios/iphoneos'), exists);
              expect(launchResult.started, true);
              expect(processManager, hasNoRemainingExpectations);
              expect(coreDeviceLauncher.launchedWithLLDB, true);
              expect(coreDeviceLauncher.launchedWithXcode, true);
              expect(coreDeviceLauncher.launchedWithoutDebugger, false);
              expect(fakeExactAnalytics.sentEvents, [
                Event.appleUsageEvent(
                  workflow: 'ios-physical-deployment',
                  parameter: IOSDeploymentMethod.coreDeviceWithLLDB.name,
                  result: 'launch failed',
                ),
                Event.appleUsageEvent(
                  workflow: 'ios-physical-deployment',
                  parameter: IOSDeploymentMethod.coreDeviceWithXcodeFallback.name,
                  result: 'debugging success',
                ),
              ]);
            },
            overrides: <Type, Generator>{
              ProcessManager: () => FakeProcessManager.any(),
              Pub: () => const ThrowingPub(),
              FileSystem: () => fileSystem,
              Logger: () => logger,
              OperatingSystemUtils: () => os,
              Platform: () => macPlatform,
              XcodeProjectInterpreter: () => fakeXcodeProjectInterpreter,
              Xcode: () => xcode,
            },
          );
        });
      });

      testUsingContext('prints warning message if it takes too long to start debugging', () async {
        final FileSystem fileSystem = MemoryFileSystem.test();
        final processManager = FakeProcessManager.empty();
        final logger = BufferLogger.test();
        final Directory bundleLocation = fileSystem.currentDirectory;
        final completer = Completer<void>();
        final xcodeDebug = FakeXcodeDebug();
        final IOSDevice device = setUpIOSDevice(
          processManager: processManager,
          fileSystem: fileSystem,
          logger: logger,
          isCoreDevice: true,
          coreDeviceControl: FakeIOSCoreDeviceControl(),
          xcodeDebug: xcodeDebug,
        );
        final IOSApp iosApp = PrebuiltIOSApp(
          projectBundleId: 'app',
          bundleName: 'Runner',
          uncompressedBundle: bundleLocation,
          applicationPackage: bundleLocation,
        );
        final deviceLogReader = FakeDeviceLogReader();

        device.portForwarder = const NoOpDevicePortForwarder();
        device.setLogReader(iosApp, deviceLogReader);

        // Start writing messages to the log reader.
        Timer.run(() {
          deviceLogReader.addLine('Foo');
          deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
        });

        FakeAsync().run((FakeAsync fakeAsync) {
          device.startApp(
            iosApp,
            prebuiltApplication: true,
            debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
            platformArgs: <String, dynamic>{},
          );

          fakeAsync.flushTimers();
          expect(
            logger.errorText,
            contains(
              'Xcode is taking longer than expected to start debugging the app. '
              'If the issue persists, try closing Xcode and re-running your Flutter command.',
            ),
          );
          completer.complete();
        });
      });

      testUsingContext('succeeds with shutdown hook added when running from CI', () async {
        final FileSystem fileSystem = MemoryFileSystem.test();
        final processManager = FakeProcessManager.empty();

        final Directory bundleLocation = fileSystem.currentDirectory;
        final fakeAnalytics = FakeExactAnalytics();
        final IOSDevice device = setUpIOSDevice(
          processManager: processManager,
          fileSystem: fileSystem,
          isCoreDevice: true,
          analytics: fakeAnalytics,
        );
        final IOSApp iosApp = PrebuiltIOSApp(
          projectBundleId: 'app',
          bundleName: 'Runner',
          uncompressedBundle: bundleLocation,
          applicationPackage: bundleLocation,
        );
        final deviceLogReader = FakeDeviceLogReader();

        device.portForwarder = const NoOpDevicePortForwarder();
        device.setLogReader(iosApp, deviceLogReader);

        // Start writing messages to the log reader.
        Timer.run(() {
          deviceLogReader.addLine('Foo');
          deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
        });

        final shutDownHooks = FakeShutDownHooks();

        final LaunchResult launchResult = await device.startApp(
          iosApp,
          prebuiltApplication: true,
          debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug, usingCISystem: true),
          platformArgs: <String, dynamic>{},
          shutdownHooks: shutDownHooks,
        );

        expect(launchResult.started, true);
        expect(shutDownHooks.hooks.length, 1);
        expect(fakeAnalytics.sentEvents, [
          Event.appleUsageEvent(
            workflow: 'ios-physical-deployment',
            parameter: IOSDeploymentMethod.coreDeviceWithXcode.name,
            result: 'debugging success',
          ),
        ]);
      });
    });

    group('finds Dart VM', () {
      testUsingContext(
        'IOSDevice.startApp attaches in debug mode via mDNS when device logging fails',
        () async {
          final FileSystem fileSystem = MemoryFileSystem.test();
          final processManager = FakeProcessManager.empty();
          final Directory bundleLocation = fileSystem.currentDirectory;
          final fakeAnalytics = FakeExactAnalytics();
          final IOSDevice device = setUpIOSDevice(
            processManager: processManager,
            fileSystem: fileSystem,
            isCoreDevice: true,
            analytics: fakeAnalytics,
          );
          final IOSApp iosApp = PrebuiltIOSApp(
            projectBundleId: 'app',
            bundleName: 'Runner',
            uncompressedBundle: bundleLocation,
            applicationPackage: bundleLocation,
          );
          final deviceLogReader = FakeDeviceLogReader();

          device.portForwarder = const NoOpDevicePortForwarder();
          device.setLogReader(iosApp, deviceLogReader);

          final LaunchResult launchResult = await device.startApp(
            iosApp,
            prebuiltApplication: true,
            debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
            platformArgs: <String, dynamic>{},
          );

          expect(launchResult.started, true);
          expect(launchResult.hasVmService, true);
          expect(await device.stopApp(iosApp), true);
          expect(fakeAnalytics.sentEvents, [
            Event.appleUsageEvent(
              workflow: 'ios-physical-deployment',
              parameter: IOSDeploymentMethod.coreDeviceWithXcode.name,
              result: 'debugging success',
            ),
          ]);
        },
        // If mDNS is not the only method of discovery, it shouldn't throw on error.
        overrides: <Type, Generator>{
          MDnsVmServiceDiscovery: () =>
              FakeMDnsVmServiceDiscovery(allowthrowOnMissingLocalNetworkPermissionsError: false),
        },
      );

      group('IOSDevice.startApp attaches in debug mode via device logging', () {
        late FakeMDnsVmServiceDiscovery mdnsDiscovery;
        setUp(() {
          mdnsDiscovery = FakeMDnsVmServiceDiscovery(returnsNull: true);
        });

        testUsingContext('when mDNS fails', () async {
          final FileSystem fileSystem = MemoryFileSystem.test();
          final processManager = FakeProcessManager.empty();
          final fakeAnalytics = FakeExactAnalytics();
          final Directory bundleLocation = fileSystem.currentDirectory;
          final IOSDevice device = setUpIOSDevice(
            processManager: processManager,
            fileSystem: fileSystem,
            isCoreDevice: true,
            analytics: fakeAnalytics,
          );
          final IOSApp iosApp = PrebuiltIOSApp(
            projectBundleId: 'app',
            bundleName: 'Runner',
            uncompressedBundle: bundleLocation,
            applicationPackage: bundleLocation,
          );
          final deviceLogReader = FakeDeviceLogReader();

          device.portForwarder = const NoOpDevicePortForwarder();
          device.setLogReader(iosApp, deviceLogReader);

          unawaited(
            mdnsDiscovery.completer.future.whenComplete(() {
              // Start writing messages to the log reader.
              Timer.run(() {
                deviceLogReader.addLine('Foo');
                deviceLogReader.addLine('The Dart VM service is listening on http://127.0.0.1:456');
              });
            }),
          );

          final LaunchResult launchResult = await device.startApp(
            iosApp,
            prebuiltApplication: true,
            debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
            platformArgs: <String, dynamic>{},
          );

          expect(launchResult.started, true);
          expect(launchResult.hasVmService, true);
          expect(await device.stopApp(iosApp), true);
          expect(fakeAnalytics.sentEvents, [
            Event.appleUsageEvent(
              workflow: 'ios-physical-deployment',
              parameter: IOSDeploymentMethod.coreDeviceWithXcode.name,
              result: 'debugging success',
            ),
          ]);
        }, overrides: <Type, Generator>{MDnsVmServiceDiscovery: () => mdnsDiscovery});
      });

      testUsingContext(
        'IOSDevice.startApp fails to find Dart VM in CI',
        () async {
          final FileSystem fileSystem = MemoryFileSystem.test();
          final processManager = FakeProcessManager.empty();

          const pathToFlutterLogs = '/path/to/flutter/logs';
          const pathToHome = '/path/to/home';
          final Directory bundleLocation = fileSystem.currentDirectory;
          final fakeAnalytics = FakeExactAnalytics();
          final IOSDevice device = setUpIOSDevice(
            processManager: processManager,
            fileSystem: fileSystem,
            isCoreDevice: true,
            analytics: fakeAnalytics,
          );

          final IOSApp iosApp = PrebuiltIOSApp(
            projectBundleId: 'app',
            bundleName: 'Runner',
            uncompressedBundle: bundleLocation,
            applicationPackage: bundleLocation,
          );
          final deviceLogReader = FakeDeviceLogReader();

          device.portForwarder = const NoOpDevicePortForwarder();
          device.setLogReader(iosApp, deviceLogReader);

          const projectLogsPath = 'Runner-project1/Logs/Launch/Runner.xcresults';
          fileSystem
              .directory('$pathToHome/Library/Developer/Xcode/DerivedData/$projectLogsPath')
              .createSync(recursive: true);

          final completer = Completer<void>();
          await FakeAsync().run((FakeAsync time) {
            final Future<LaunchResult> futureLaunchResult = device.startApp(
              iosApp,
              prebuiltApplication: true,
              debuggingOptions: DebuggingOptions.enabled(
                BuildInfo.debug,
                usingCISystem: true,
                debugLogsDirectoryPath: pathToFlutterLogs,
              ),
              platformArgs: <String, dynamic>{},
            );
            futureLaunchResult.then((LaunchResult launchResult) {
              expect(launchResult.started, false);
              expect(launchResult.hasVmService, false);
              expect(
                fileSystem
                    .directory('$pathToFlutterLogs/DerivedDataLogs/$projectLogsPath')
                    .existsSync(),
                true,
              );
              expect(fakeAnalytics.sentEvents, [
                Event.appleUsageEvent(
                  workflow: 'ios-physical-deployment',
                  parameter: IOSDeploymentMethod.coreDeviceWithXcode.name,
                  result: 'debugging failed',
                ),
              ]);
              completer.complete();
            });
            time.elapse(const Duration(minutes: 15));
            time.flushMicrotasks();
            return completer.future;
          });
        },
        overrides: <Type, Generator>{
          MDnsVmServiceDiscovery: () => FakeMDnsVmServiceDiscovery(returnsNull: true),
        },
      );

      testUsingContext(
        'IOSDevice.startApp prints guided message when iOS 18.4 crashes due to JIT',
        () async {
          final FileSystem fileSystem = MemoryFileSystem.test();
          final processManager = FakeProcessManager.empty();
          final Directory bundleLocation = fileSystem.currentDirectory;
          final IOSDevice device = setUpIOSDevice(
            sdkVersion: '18.4',
            processManager: processManager,
            fileSystem: fileSystem,
            isCoreDevice: true,
          );
          final IOSApp iosApp = PrebuiltIOSApp(
            projectBundleId: 'app',
            bundleName: 'Runner',
            uncompressedBundle: bundleLocation,
            applicationPackage: bundleLocation,
          );
          final deviceLogReader = FakeDeviceLogReader();

          device.portForwarder = const NoOpDevicePortForwarder();
          device.setLogReader(iosApp, deviceLogReader);

          // Start writing messages to the log reader.
          Timer.run(() {
            deviceLogReader.addLine(kJITCrashFailureMessage);
          });

          final completer = Completer<void>();
          // device.startApp() asynchronously calls throwToolExit, so we
          // catch it in a zone.
          unawaited(
            runZonedGuarded<Future<void>?>(
              () {
                unawaited(
                  device.startApp(
                    iosApp,
                    prebuiltApplication: true,
                    debuggingOptions: DebuggingOptions.enabled(BuildInfo.debug),
                    platformArgs: <String, dynamic>{},
                  ),
                );
                return null;
              },
              (Object error, StackTrace stack) {
                expect(error.toString(), contains(jITCrashFailureInstructions('iOS 18.4')));
                completer.complete();
              },
            ),
          );
          await completer.future;
        },
      );
    });
  });
}

void setUpIOSProject(
  FileSystem fileSystem, {
  bool createWorkspace = true,
  String scheme = 'Runner',
}) {
  fileSystem.file('pubspec.yaml').writeAsStringSync('''
name: my_app
''');
  writePackageConfigFiles(directory: fileSystem.currentDirectory, mainLibName: 'my_app');
  fileSystem.directory('ios').createSync();
  if (createWorkspace) {
    fileSystem.directory('ios/Runner.xcworkspace').createSync();
  }
  fileSystem.file('ios/Runner.xcodeproj/project.pbxproj').createSync(recursive: true);
  final File schemeFile = fileSystem.file(
    'ios/Runner.xcodeproj/xcshareddata/xcschemes/$scheme.xcscheme',
  )..createSync(recursive: true);
  schemeFile.writeAsStringSync(_validScheme);
  // This is the expected output directory.
  fileSystem.directory('build/ios/iphoneos/My Super Awesome App.app').createSync(recursive: true);
}

IOSDevice setUpIOSDevice({
  String sdkVersion = '13.0.1',
  FileSystem? fileSystem,
  Logger? logger,
  ProcessManager? processManager,
  Artifacts? artifacts,
  bool isCoreDevice = false,
  IOSCoreDeviceControl? coreDeviceControl,
  IOSCoreDeviceLauncher? coreDeviceLauncher,
  FakeXcodeDebug? xcodeDebug,
  DarwinArch cpuArchitecture = DarwinArch.arm64,
  FakeExactAnalytics? analytics,
}) {
  artifacts ??= Artifacts.test();
  final cache = Cache.test(
    artifacts: <ArtifactSet>[FakeDyldEnvironmentArtifact()],
    processManager: FakeProcessManager.any(),
  );

  logger ??= BufferLogger.test();
  return IOSDevice(
    '123',
    name: 'iPhone 1',
    sdkVersion: sdkVersion,
    fileSystem: fileSystem ?? MemoryFileSystem.test(),
    platform: macPlatform,
    iProxy: IProxy.test(logger: logger, processManager: processManager ?? FakeProcessManager.any()),
    logger: logger,
    iosDeploy: IOSDeploy(
      logger: logger,
      platform: macPlatform,
      processManager: processManager ?? FakeProcessManager.any(),
      artifacts: artifacts,
      cache: cache,
    ),
    analytics: analytics ?? FakeExactAnalytics(),
    iMobileDevice: IMobileDevice(
      logger: logger,
      processManager: processManager ?? FakeProcessManager.any(),
      artifacts: artifacts,
      cache: cache,
    ),
    coreDeviceControl: coreDeviceControl ?? FakeIOSCoreDeviceControl(),
    coreDeviceLauncher: coreDeviceLauncher ?? FakeIOSCoreDeviceLauncher(),
    xcodeDebug: xcodeDebug ?? FakeXcodeDebug(),
    cpuArchitecture: cpuArchitecture,
    connectionInterface: DeviceConnectionInterface.attached,
    isConnected: true,
    isPaired: true,
    devModeEnabled: true,
    isCoreDevice: isCoreDevice,
  );
}

class FakeXcodeProjectInterpreter extends Fake implements XcodeProjectInterpreter {
  FakeXcodeProjectInterpreter({
    this.projectInfo,
    this.buildSettings = const <String, String>{
      'TARGET_BUILD_DIR': 'build/ios/Release-iphoneos',
      'WRAPPER_NAME': 'My Super Awesome App.app',
      'DEVELOPMENT_TEAM': '3333CCCC33',
    },
    Version? xcodeVersion,
  }) : version = xcodeVersion ?? Version(1000, 0, 0);

  final Map<String, String> buildSettings;
  final XcodeProjectInfo? projectInfo;

  @override
  final isInstalled = true;

  @override
  Version? version;

  @override
  String get versionText => version.toString();

  @override
  List<String> xcrunCommand() => <String>['xcrun'];

  @override
  Future<XcodeProjectInfo?> getInfo(String projectPath, {String? projectFilename}) async =>
      projectInfo;

  @override
  Future<Map<String, String>> getBuildSettings(
    String projectPath, {
    required XcodeProjectBuildContext buildContext,
    Duration timeout = const Duration(minutes: 1),
  }) async => buildSettings;
}

class FakeXcodeDebug extends Fake implements XcodeDebug {}

class FakeIOSCoreDeviceControl extends Fake implements IOSCoreDeviceControl {}

const _validScheme = '''
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1510"
   version = "1.3">
   <BuildAction>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <MacroExpansion>
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "97C146ED1CF9000F007C117D"
            BuildableName = "Runner.app"
            BlueprintName = "Runner"
            ReferencedContainer = "container:Runner.xcodeproj">
         </BuildableReference>
      </MacroExpansion>
      <Testables>
         <TestableReference
            skipped = "NO"
            parallelizable = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "331C8080294A63A400263BE5"
               BuildableName = "RunnerTests.xctest"
               BlueprintName = "RunnerTests"
               ReferencedContainer = "container:Runner.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      enableGPUValidationMode = "1"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "97C146ED1CF9000F007C117D"
            BuildableName = "Runner.app"
            BlueprintName = "Runner"
            ReferencedContainer = "container:Runner.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction>
   </ProfileAction>
   <AnalyzeAction>
   </AnalyzeAction>
   <ArchiveAction>
   </ArchiveAction>
</Scheme>
''';

class FakeIOSCoreDeviceLauncher extends Fake implements IOSCoreDeviceLauncher {
  FakeIOSCoreDeviceLauncher({
    this.lldbLaunchResult = true,
    this.xcodeLaunchResult = true,
    this.withouDebuggerLaunchResult = true,
  });

  bool lldbLaunchResult;
  bool xcodeLaunchResult;
  bool withouDebuggerLaunchResult;
  var launchedWithLLDB = false;
  var launchedWithXcode = false;
  var launchedWithoutDebugger = false;

  Completer<void>? xcodeCompleter;

  @override
  Future<bool> launchAppWithoutDebugger({
    required String deviceId,
    required String bundlePath,
    required String bundleId,
    required List<String> launchArguments,
  }) async {
    launchedWithoutDebugger = true;
    return withouDebuggerLaunchResult;
  }

  @override
  Future<bool> launchAppWithLLDBDebugger({
    required String deviceId,
    required String bundlePath,
    required String bundleId,
    required List<String> launchArguments,
  }) async {
    launchedWithLLDB = true;
    return lldbLaunchResult;
  }

  @override
  Future<bool> launchAppWithXcodeDebugger({
    required String deviceId,
    required DebuggingOptions debuggingOptions,
    required IOSApp package,
    required List<String> launchArguments,
    required TemplateRenderer templateRenderer,
    required Duration launchTimeout,
    required ShutdownHooks shutdownHooks,
    String? mainPath,
  }) async {
    if (xcodeCompleter != null) {
      await xcodeCompleter!.future;
    }
    launchedWithXcode = true;
    return xcodeLaunchResult;
  }

  @override
  Future<bool> stopApp({required String deviceId, int? processId}) async {
    return false;
  }
}

class FakeExactAnalytics extends Fake implements Analytics {
  final sentEvents = <Event>[];

  @override
  void send(Event event) {
    sentEvents.add(event);
  }
}

class FakeShutDownHooks extends Fake implements ShutdownHooks {
  var hooks = <ShutdownHook>[];
  @override
  void addShutdownHook(ShutdownHook shutdownHook) {
    hooks.add(shutdownHook);
  }
}

class FakeMDnsVmServiceDiscovery extends Fake implements MDnsVmServiceDiscovery {
  FakeMDnsVmServiceDiscovery({
    this.returnsNull = false,
    this.allowthrowOnMissingLocalNetworkPermissionsError = true,
  });
  bool returnsNull;
  bool allowthrowOnMissingLocalNetworkPermissionsError;

  var completer = Completer<void>();
  @override
  Future<Uri?> getVMServiceUriForLaunch(
    String applicationId,
    Device device, {
    bool usesIpv6 = false,
    int? hostVmservicePort,
    int? deviceVmservicePort,
    bool useDeviceIPAsHost = false,
    Duration timeout = Duration.zero,
    bool throwOnMissingLocalNetworkPermissionsError = true,
  }) async {
    completer.complete();
    if (returnsNull) {
      return null;
    }
    expect(
      throwOnMissingLocalNetworkPermissionsError,
      allowthrowOnMissingLocalNetworkPermissionsError,
    );

    return Uri.tryParse('http://0.0.0.0:1234');
  }
}
