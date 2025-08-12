// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:process/process.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../application_package.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/os.dart';
import '../base/platform.dart';
import '../base/process.dart';
import '../base/utils.dart';
import '../base/version.dart';
import '../build_info.dart';
import '../darwin/darwin.dart';
import '../device.dart';
import '../device_port_forwarder.dart';
import '../device_vm_service_discovery_for_attach.dart';
import '../features.dart';
import '../globals.dart' as globals;
import '../macos/xcdevice.dart';
import '../mdns_discovery.dart';
import '../project.dart';
import '../protocol_discovery.dart';
import 'application_package.dart';
import 'core_devices.dart';
import 'ios_deploy.dart';
import 'ios_device_log_reader.dart';
import 'ios_workflow.dart';
import 'iproxy.dart';
import 'mac.dart';
import 'xcode_build_settings.dart';
import 'xcode_debug.dart';
import 'xcodeproj.dart';

const kJITCrashFailureMessage =
    'Crash occurred when compiling unknown function in unoptimized JIT mode in unknown pass';

@visibleForTesting
String jITCrashFailureInstructions(String deviceVersion) =>
    '''
════════════════════════════════════════════════════════════════════════════════
A change to iOS has caused a temporary break in Flutter's debug mode on
physical devices.
See https://github.com/flutter/flutter/issues/163984 for details.

In the meantime, we recommend these temporary workarounds:

* When developing with a physical device, use one running iOS 18.3 or lower.
* Use a simulator for development rather than a physical device.
* If you must use a device updated to $deviceVersion, use Flutter's release or
  profile mode via --release or --profile flags.
════════════════════════════════════════════════════════════════════════════════''';

enum IOSDeploymentMethod {
  iosDeployLaunch,
  iosDeployLaunchAndAttach,
  coreDeviceWithoutDebugger,
  coreDeviceWithLLDB,
  coreDeviceWithXcode,
  coreDeviceWithXcodeFallback,
}

class IOSDevices extends PollingDeviceDiscovery {
  IOSDevices({
    required Platform platform,
    required this.xcdevice,
    required IOSWorkflow iosWorkflow,
    required Logger logger,
  }) : _platform = platform,
       _iosWorkflow = iosWorkflow,
       _logger = logger,
       super('iOS devices');

  final Platform _platform;
  final IOSWorkflow _iosWorkflow;
  final Logger _logger;

  @visibleForTesting
  final XCDevice xcdevice;

  @override
  bool get supportsPlatform => _platform.isMacOS;

  @override
  bool get canListAnything => _iosWorkflow.canListDevices;

  @override
  bool get requiresExtendedWirelessDeviceDiscovery => true;

  StreamSubscription<XCDeviceEventNotification>? _observedDeviceEventsSubscription;

  /// Cache for all devices found by `xcdevice list`, including not connected
  /// devices. Used to minimize the need to call `xcdevice list`.
  ///
  /// Separate from `deviceNotifier` since `deviceNotifier` should only contain
  /// connected devices.
  final _cachedPolledDevices = <String, IOSDevice>{};

  /// Maps device id to a map of the device's observed connections. When the
  /// mapped connection is `true`, that means that observed events indicated
  /// the device is connected via that particular interface.
  ///
  /// The device id must be missing from the map or both interfaces must be
  /// false for the device to be considered disconnected.
  ///
  /// Example:
  /// {
  ///   device-id: {
  ///     usb: false,
  ///     wifi: false,
  ///   },
  /// }
  final _observedConnectionsByDeviceId = <String, Map<XCDeviceEventInterface, bool>>{};

  @override
  Future<void> startPolling() async {
    if (!_platform.isMacOS) {
      throw UnsupportedError('Control of iOS devices or simulators only supported on macOS.');
    }
    if (!xcdevice.isInstalled) {
      return;
    }

    // Start by populating all currently attached devices.
    _updateCachedDevices(await pollingGetDevices());
    _updateNotifierFromCache();

    // cancel any outstanding subscriptions.
    await _observedDeviceEventsSubscription?.cancel();
    _observedDeviceEventsSubscription = xcdevice.observedDeviceEvents()?.listen(
      onDeviceEvent,
      onError: (Object error, StackTrace stack) {
        _logger.printTrace('Process exception running xcdevice observe:\n$error\n$stack');
      },
      onDone: () {
        // If xcdevice is killed or otherwise dies, polling will be stopped.
        // No retry is attempted and the polling client will have to restart polling
        // (restart the IDE). Avoid hammering on a process that is
        // continuously failing.
        _logger.printTrace('xcdevice observe stopped');
      },
      cancelOnError: true,
    );
  }

  @visibleForTesting
  Future<void> onDeviceEvent(XCDeviceEventNotification event) async {
    final ItemListNotifier<Device> notifier = deviceNotifier;

    Device? knownDevice;
    for (final Device device in notifier.items) {
      if (device.id == event.deviceIdentifier) {
        knownDevice = device;
      }
    }

    final Map<XCDeviceEventInterface, bool> deviceObservedConnections =
        _observedConnectionsByDeviceId[event.deviceIdentifier] ??
        <XCDeviceEventInterface, bool>{
          XCDeviceEventInterface.usb: false,
          XCDeviceEventInterface.wifi: false,
        };

    if (event.eventType == XCDeviceEvent.attach) {
      // Update device's observed connections.
      deviceObservedConnections[event.eventInterface] = true;
      _observedConnectionsByDeviceId[event.deviceIdentifier] = deviceObservedConnections;

      // If device was not already in notifier, add it.
      if (knownDevice == null) {
        if (_cachedPolledDevices[event.deviceIdentifier] == null) {
          // If device is not found in cache, there's no way to get details
          // for an individual attached device, so repopulate them all.
          _updateCachedDevices(await pollingGetDevices());
        }
        _updateNotifierFromCache();
      }
    } else {
      // Update device's observed connections.
      deviceObservedConnections[event.eventInterface] = false;
      _observedConnectionsByDeviceId[event.deviceIdentifier] = deviceObservedConnections;

      // If device is in the notifier and does not have other observed
      // connections, remove it.
      if (knownDevice != null && !_deviceHasObservedConnection(deviceObservedConnections)) {
        notifier.removeItem(knownDevice);
      }
    }
  }

  /// Adds or updates devices in cache. Does not remove devices from cache.
  void _updateCachedDevices(List<Device> devices) {
    for (final device in devices) {
      if (device is! IOSDevice) {
        continue;
      }
      _cachedPolledDevices[device.id] = device;
    }
  }

  /// Updates notifier with devices found in the cache that are determined
  /// to be connected.
  void _updateNotifierFromCache() {
    final ItemListNotifier<Device> notifier = deviceNotifier;

    // Device is connected if it has either an observed usb or wifi connection
    // or it has not been observed but was found as connected in the cache.
    final List<Device> connectedDevices = _cachedPolledDevices.values.where((Device device) {
      final Map<XCDeviceEventInterface, bool>? deviceObservedConnections =
          _observedConnectionsByDeviceId[device.id];
      return (deviceObservedConnections != null &&
              _deviceHasObservedConnection(deviceObservedConnections)) ||
          (deviceObservedConnections == null && device.isConnected);
    }).toList();

    notifier.updateWithNewList(connectedDevices);
  }

  bool _deviceHasObservedConnection(Map<XCDeviceEventInterface, bool> deviceObservedConnections) {
    return (deviceObservedConnections[XCDeviceEventInterface.usb] ?? false) ||
        (deviceObservedConnections[XCDeviceEventInterface.wifi] ?? false);
  }

  @override
  Future<void> stopPolling() async {
    await _observedDeviceEventsSubscription?.cancel();
  }

  @override
  Future<List<Device>> pollingGetDevices({Duration? timeout}) async {
    if (!_platform.isMacOS) {
      throw UnsupportedError('Control of iOS devices or simulators only supported on macOS.');
    }

    return xcdevice.getAvailableIOSDevices(timeout: timeout);
  }

  Future<Device?> waitForDeviceToConnect(IOSDevice device, Logger logger) async {
    final XCDeviceEventNotification? eventDetails = await xcdevice.waitForDeviceToConnect(
      device.id,
    );

    if (eventDetails != null) {
      device.isConnected = true;
      device.connectionInterface = eventDetails.eventInterface.connectionInterface;
      return device;
    }
    return null;
  }

  void cancelWaitForDeviceToConnect() {
    xcdevice.cancelWaitForDeviceToConnect();
  }

  @override
  Future<List<String>> getDiagnostics() async {
    if (!_platform.isMacOS) {
      return const <String>['Control of iOS devices or simulators only supported on macOS.'];
    }

    return xcdevice.getDiagnostics();
  }

  @override
  List<String> get wellKnownIds => const <String>[];
}

class IOSDevice extends Device {
  IOSDevice(
    super.id, {
    required FileSystem fileSystem,
    required this.name,
    required this.cpuArchitecture,
    required this.connectionInterface,
    required this.isConnected,
    required this.isPaired,
    required this.devModeEnabled,
    required this.isCoreDevice,
    String? sdkVersion,
    required Platform platform,
    required IOSDeploy iosDeploy,
    required IMobileDevice iMobileDevice,
    required IOSCoreDeviceControl coreDeviceControl,
    required IOSCoreDeviceLauncher coreDeviceLauncher,
    required XcodeDebug xcodeDebug,
    required IProxy iProxy,
    required super.logger,
    required Analytics analytics,
  }) : _sdkVersion = sdkVersion,
       _iosDeploy = iosDeploy,
       _iMobileDevice = iMobileDevice,
       _coreDeviceControl = coreDeviceControl,
       _coreDeviceLauncher = coreDeviceLauncher,
       _xcodeDebug = xcodeDebug,
       _iproxy = iProxy,
       _fileSystem = fileSystem,
       _logger = logger,
       _analytics = analytics,
       _platform = platform,
       super(category: Category.mobile, platformType: PlatformType.ios, ephemeral: true) {
    if (!_platform.isMacOS) {
      assert(false, 'Control of iOS devices or simulators only supported on Mac OS.');
      return;
    }
  }

  final String? _sdkVersion;
  final IOSDeploy _iosDeploy;
  final Analytics _analytics;
  final FileSystem _fileSystem;
  final Logger _logger;
  final Platform _platform;
  final IMobileDevice _iMobileDevice;
  final IOSCoreDeviceControl _coreDeviceControl;
  final IOSCoreDeviceLauncher _coreDeviceLauncher;
  final XcodeDebug _xcodeDebug;
  final IProxy _iproxy;

  Version? get sdkVersion {
    return Version.parse(_sdkVersion);
  }

  /// May be 0 if version cannot be parsed.
  int get majorSdkVersion {
    return sdkVersion?.major ?? 0;
  }

  @override
  final String name;

  @override
  bool supportsRuntimeMode(BuildMode buildMode) => buildMode != BuildMode.jitRelease;

  final DarwinArch cpuArchitecture;

  @override
  /// The [connectionInterface] provided from `XCDevice.getAvailableIOSDevices`
  /// may not be accurate. Sometimes if it doesn't have a long enough time
  /// to connect, wireless devices will have an interface of `usb`/`attached`.
  /// This may change after waiting for the device to connect in
  /// `waitForDeviceToConnect`.
  DeviceConnectionInterface connectionInterface;

  @override
  bool isConnected;

  var devModeEnabled = false;

  /// Device has trusted this computer and paired.
  var isPaired = false;

  /// CoreDevice is a device connectivity stack introduced in Xcode 15. Devices
  /// with iOS 17 or greater are CoreDevices.
  final bool isCoreDevice;

  final _logReaders = <IOSApp?, DeviceLogReader>{};

  DevicePortForwarder? _portForwarder;

  @visibleForTesting
  IOSDeployDebugger? iosDeployDebugger;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<String?> get emulatorId async => null;

  @override
  bool get supportsStartPaused => false;

  @override
  bool get supportsFlavors => true;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app, {String? userIdentifier}) async {
    bool result;
    try {
      if (isCoreDevice) {
        result = await _coreDeviceControl.isAppInstalled(bundleId: app.id, deviceId: id);
      } else {
        result = await _iosDeploy.isAppInstalled(bundleId: app.id, deviceId: id);
      }
    } on ProcessException catch (e) {
      _logger.printError(e.message);
      return false;
    }
    return result;
  }

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => false;

  @override
  Future<bool> installApp(covariant IOSApp app, {String? userIdentifier}) async {
    final Directory bundle = _fileSystem.directory(app.deviceBundlePath);
    if (!bundle.existsSync()) {
      _logger.printError(
        'Could not find application bundle at ${bundle.path}; have you run "flutter build ios"?',
      );
      return false;
    }

    int installationResult;
    try {
      if (isCoreDevice) {
        final (bool installSuccess, _) = await _coreDeviceControl.installApp(
          deviceId: id,
          bundlePath: bundle.path,
        );
        installationResult = installSuccess ? 0 : 1;
      } else {
        installationResult = await _iosDeploy.installApp(
          deviceId: id,
          bundlePath: bundle.path,
          appDeltaDirectory: app.appDeltaDirectory,
          launchArguments: <String>[],
          interfaceType: connectionInterface,
        );
      }
    } on ProcessException catch (e) {
      _logger.printError(e.message);
      return false;
    }
    if (installationResult != 0) {
      _logger.printError('Could not install ${bundle.path} on $id.');
      _logger.printError('Try launching Xcode and selecting "Product > Run" to fix the problem:');
      _logger.printError('  open ios/Runner.xcworkspace');
      _logger.printError('');
      return false;
    }
    return true;
  }

  @override
  Future<bool> uninstallApp(ApplicationPackage app, {String? userIdentifier}) async {
    int uninstallationResult;
    try {
      if (isCoreDevice) {
        uninstallationResult = await _coreDeviceControl.uninstallApp(deviceId: id, bundleId: app.id)
            ? 0
            : 1;
      } else {
        uninstallationResult = await _iosDeploy.uninstallApp(deviceId: id, bundleId: app.id);
      }
    } on ProcessException catch (e) {
      _logger.printError(e.message);
      return false;
    }
    if (uninstallationResult != 0) {
      _logger.printError('Could not uninstall ${app.id} on $id.');
      return false;
    }
    return true;
  }

  @override
  // 32-bit devices are not supported.
  Future<bool> isSupported() async => cpuArchitecture == DarwinArch.arm64;

  @override
  Future<LaunchResult> startApp(
    IOSApp package, {
    String? mainPath,
    String? route,
    required DebuggingOptions debuggingOptions,
    Map<String, Object?> platformArgs = const <String, Object?>{},
    bool prebuiltApplication = false,
    String? userIdentifier,
    @visibleForTesting Duration? discoveryTimeout,
    @visibleForTesting ShutdownHooks? shutdownHooks,
  }) async {
    String? packageId;
    if (isWirelesslyConnected &&
        debuggingOptions.debuggingEnabled &&
        debuggingOptions.disablePortPublication) {
      throwToolExit(
        'Cannot start app on wirelessly tethered iOS device. Try running again with the --publish-port flag',
      );
    }

    if (!prebuiltApplication) {
      _logger.printTrace('Building ${package.name} for $id');

      // Step 1: Build the precompiled/DBC application if necessary.
      final XcodeBuildResult buildResult = await buildXcodeProject(
        app: package as BuildableIOSApp,
        buildInfo: debuggingOptions.buildInfo,
        targetOverride: mainPath,
        activeArch: cpuArchitecture,
        deviceID: id,
        disablePortPublication:
            debuggingOptions.usingCISystem && debuggingOptions.disablePortPublication,
      );
      if (!buildResult.success) {
        _logger.printError('Could not build the precompiled application for the device.');
        await diagnoseXcodeBuildFailure(
          buildResult,
          analytics: _analytics,
          fileSystem: globals.fs,
          logger: globals.logger,
          platform: FlutterDarwinPlatform.ios,
          project: package.project.parent,
        );
        _logger.printError('');
        return LaunchResult.failed();
      }
      packageId = buildResult.xcodeBuildExecution?.buildSettings[IosProject.kProductBundleIdKey];
    }

    packageId ??= package.id;

    // Step 2: Check that the application exists at the specified path.
    final Directory bundle = _fileSystem.directory(package.deviceBundlePath);
    if (!bundle.existsSync()) {
      _logger.printError('Could not find the built application bundle at ${bundle.path}.');
      return LaunchResult.failed();
    }

    // Step 3: Attempt to install the application on the device.
    final List<String> launchArguments = debuggingOptions.getIOSLaunchArguments(
      EnvironmentType.physical,
      route,
      platformArgs,
      interfaceType: connectionInterface,
    );
    Status startAppStatus = _logger.startProgress('Installing and launching...');

    IOSDeploymentMethod deploymentMethod = _getDeploymentMethod(debuggingOptions: debuggingOptions);

    try {
      final ProtocolDiscovery? vmServiceDiscovery = _setupLoggers(
        deploymentMethod,
        package: package,
        bundle: bundle,
        debuggingOptions: debuggingOptions,
        launchArguments: launchArguments,
        uninstallFirst: debuggingOptions.uninstallFirst,
      );

      var installationResult = 1;
      switch (deploymentMethod) {
        case IOSDeploymentMethod.iosDeployLaunch:
          installationResult = await _iosDeploy.launchApp(
            deviceId: id,
            bundlePath: bundle.path,
            appDeltaDirectory: package.appDeltaDirectory,
            launchArguments: launchArguments,
            interfaceType: connectionInterface,
            uninstallFirst: debuggingOptions.uninstallFirst,
          );
        case IOSDeploymentMethod.iosDeployLaunchAndAttach:
          installationResult = await iosDeployDebugger!.launchAndAttach() ? 0 : 1;
        case IOSDeploymentMethod.coreDeviceWithoutDebugger:
          final bool launchSuccess = await _coreDeviceLauncher.launchAppWithoutDebugger(
            deviceId: id,
            bundlePath: package.deviceBundlePath,
            bundleId: package.id,
            launchArguments: launchArguments,
          );
          installationResult = launchSuccess ? 0 : 1;
        case IOSDeploymentMethod.coreDeviceWithLLDB:
          final bool launchSuccess = await _coreDeviceLauncher.launchAppWithLLDBDebugger(
            deviceId: id,
            bundlePath: package.deviceBundlePath,
            bundleId: package.id,
            launchArguments: launchArguments,
          );
          installationResult = launchSuccess ? 0 : 1;
        case IOSDeploymentMethod.coreDeviceWithXcode:
          final bool launchSuccess = await _coreDeviceLauncher.launchAppWithXcodeDebugger(
            deviceId: id,
            debuggingOptions: debuggingOptions,
            package: package,
            launchArguments: launchArguments,
            mainPath: mainPath,
            templateRenderer: globals.templateRenderer,
          );
          installationResult = launchSuccess ? 0 : 1;
        case IOSDeploymentMethod.coreDeviceWithXcodeFallback:
          return LaunchResult.failed();
      }

      // If LLDB fails, try again with Xcode.
      if (installationResult != 0 && deploymentMethod == IOSDeploymentMethod.coreDeviceWithLLDB) {
        _analytics.send(
          Event.appleUsageEvent(
            workflow: 'ios-physical-deployment',
            parameter: deploymentMethod.name,
            result: 'launch failed',
          ),
        );
        final bool launchSuccess = await _coreDeviceLauncher.launchAppWithXcodeDebugger(
          deviceId: id,
          debuggingOptions: debuggingOptions,
          package: package,
          launchArguments: launchArguments,
          mainPath: mainPath,
          templateRenderer: globals.templateRenderer,
        );
        installationResult = launchSuccess ? 0 : 1;
        deploymentMethod = IOSDeploymentMethod.coreDeviceWithXcodeFallback;
      }

      if (installationResult != 0) {
        _analytics.send(
          Event.appleUsageEvent(
            workflow: 'ios-physical-deployment',
            parameter: deploymentMethod.name,
            result: 'launch failed',
          ),
        );
        _printInstallError(bundle);
        await dispose();
        return LaunchResult.failed();
      }

      if (!debuggingOptions.debuggingEnabled) {
        _analytics.send(
          Event.appleUsageEvent(
            workflow: 'ios-physical-deployment',
            parameter: deploymentMethod.name,
            result: 'release success',
          ),
        );
        return LaunchResult.succeeded();
      }

      final Uri? localUri = await _discoverDartVM(
        deploymentMethod,
        package: package,
        bundle: bundle,
        debuggingOptions: debuggingOptions,
        packageId: packageId,
        discoveryTimeout: discoveryTimeout,
        vmServiceDiscovery: vmServiceDiscovery,
      );

      if (localUri == null) {
        await iosDeployDebugger?.stopAndDumpBacktrace();
        await dispose();
        _analytics.send(
          Event.appleUsageEvent(
            workflow: 'ios-physical-deployment',
            parameter: deploymentMethod.name,
            result: 'debugging failed',
          ),
        );
        return LaunchResult.failed();
      }
      _analytics.send(
        Event.appleUsageEvent(
          workflow: 'ios-physical-deployment',
          parameter: deploymentMethod.name,
          result: 'debugging success',
        ),
      );

      return LaunchResult.succeeded(vmServiceUri: localUri);
    } on ProcessException catch (e) {
      await iosDeployDebugger?.stopAndDumpBacktrace();
      _logger.printError(e.message);
      await dispose();
      _analytics.send(
        Event.appleUsageEvent(
          workflow: 'ios-physical-deployment',
          parameter: deploymentMethod.name,
          result: 'process exception',
        ),
      );
      return LaunchResult.failed();
    } finally {
      startAppStatus.stop();

      if (isCoreDevice && debuggingOptions.debuggingEnabled && package is BuildableIOSApp) {
        // When debugging via Xcode, after the app launches, reset the Generated
        // settings to not include the custom configuration build directory.
        // This is to prevent confusion if the project is later ran via Xcode
        // rather than the Flutter CLI.
        await updateGeneratedXcodeProperties(
          project: FlutterProject.current(),
          buildInfo: debuggingOptions.buildInfo,
          targetOverride: mainPath,
        );
      }
    }
  }

  IOSDeploymentMethod _getDeploymentMethod({required DebuggingOptions debuggingOptions}) {
    if (isCoreDevice) {
      final Version? xcodeVersion = globals.xcode?.currentVersion;
      final bool lldbFeatureEnabled = featureFlags.isLLDBDebuggingEnabled;
      if (!debuggingOptions.debuggingEnabled) {
        return IOSDeploymentMethod.coreDeviceWithoutDebugger;
      } else if (xcodeVersion != null && xcodeVersion.major >= 26 && lldbFeatureEnabled) {
        return IOSDeploymentMethod.coreDeviceWithLLDB;
      } else {
        return IOSDeploymentMethod.coreDeviceWithXcode;
      }
    } else if (majorSdkVersion < IOSDeviceLogReader.minimumUniversalLoggingSdkVersion) {
      // If the device supports syslog reading, prefer launching the app without
      // attaching the debugger to avoid the overhead of the unnecessary extra running process.
      return IOSDeploymentMethod.iosDeployLaunch;
    } else {
      return IOSDeploymentMethod.iosDeployLaunchAndAttach;
    }
  }

  void _printInstallError(Directory bundle) {
    _logger.printError('Could not run ${bundle.path} on $id.');
    _logger.printError('Try launching Xcode and selecting "Product > Run" to fix the problem:');
    _logger.printError('  open ios/Runner.xcworkspace');
    _logger.printError('');
  }

  /// Find the Dart VM url using ProtocolDiscovery (logs from `idevicesyslog`)
  /// and mDNS simultaneously, using whichever is found first. `idevicesyslog`
  /// does not work on wireless devices, so only use mDNS for wireless devices.
  /// Wireless devices require using the device IP as the host.
  Future<Uri?> _discoverDartVMForCoreDevice({
    required String packageId,
    required DebuggingOptions debuggingOptions,
    ProtocolDiscovery? vmServiceDiscovery,
    IOSApp? package,
  }) async {
    final StreamSubscription<String>? errorListener = await _interceptErrorsFromLogs(
      package,
      debuggingOptions: debuggingOptions,
    );

    final bool discoverVMUrlFromLogs = vmServiceDiscovery != null && !isWirelesslyConnected;

    // If mDNS fails, don't throw since url may still be findable through vmServiceDiscovery.
    final Future<Uri?> vmUrlFromMDns = MDnsVmServiceDiscovery.instance!.getVMServiceUriForLaunch(
      packageId,
      this,
      usesIpv6: debuggingOptions.ipv6,
      useDeviceIPAsHost: isWirelesslyConnected,
      throwOnMissingLocalNetworkPermissionsError: !discoverVMUrlFromLogs,
    );

    final discoveryOptions = <Future<Uri?>>[
      vmUrlFromMDns,
      // vmServiceDiscovery uses device logs (`idevicesyslog`), which doesn't work
      // on wireless devices.
      if (discoverVMUrlFromLogs) vmServiceDiscovery.uri,
    ];

    Uri? localUri = await Future.any(<Future<Uri?>>[...discoveryOptions]);

    // If the first future to return is null, wait for the other to complete
    // unless canceled.
    if (localUri == null) {
      final Future<List<Uri?>> allDiscoveryOptionsComplete = Future.wait(discoveryOptions);
      await Future.any(<Future<Object?>>[allDiscoveryOptionsComplete]);
      final List<Uri?> vmUrls = await allDiscoveryOptionsComplete;
      localUri = vmUrls.where((Uri? vmUrl) => vmUrl != null).firstOrNull;
    }

    await errorListener?.cancel();
    return localUri;
  }

  /// Listen to device logs for crash on iOS 18.4+ due to JIT restriction. If
  /// found, give guided error and throw tool exit. Returns null and does not
  /// listen if device is less than iOS 18.4.
  Future<StreamSubscription<String>?> _interceptErrorsFromLogs(
    IOSApp? package, {
    required DebuggingOptions debuggingOptions,
  }) async {
    // Currently only checking for kJITCrashFailureMessage, which only should
    // be checked on iOS 18.4+.
    if (sdkVersion == null || sdkVersion! < Version(18, 4, null)) {
      return null;
    }
    final DeviceLogReader deviceLogReader = getLogReader(
      app: package,
      usingCISystem: debuggingOptions.usingCISystem,
    );

    final Stream<String> logStream = deviceLogReader.logLines;

    final String deviceSdkVersion = await sdkNameAndVersion;

    final StreamSubscription<String> errorListener = logStream.listen((String line) {
      if (line.contains(kJITCrashFailureMessage)) {
        throwToolExit(jITCrashFailureInstructions(deviceSdkVersion));
      }
    });

    return errorListener;
  }

  ProtocolDiscovery? _setupLoggers(
    IOSDeploymentMethod deploymentMethod, {
    required IOSApp package,
    required Directory bundle,
    required DebuggingOptions debuggingOptions,
    required List<String> launchArguments,
    required bool uninstallFirst,
    bool skipInstall = false,
  }) {
    if (!debuggingOptions.debuggingEnabled) {
      return null;
    }
    _logger.printTrace('Debugging is enabled, connecting to vmService');
    final DeviceLogReader deviceLogReader = getLogReader(
      app: package,
      usingCISystem: debuggingOptions.usingCISystem,
    );

    if (deploymentMethod == IOSDeploymentMethod.iosDeployLaunchAndAttach) {
      iosDeployDebugger = _iosDeploy.prepareDebuggerForLaunch(
        deviceId: id,
        bundlePath: bundle.path,
        appDeltaDirectory: package.appDeltaDirectory,
        launchArguments: launchArguments,
        interfaceType: connectionInterface,
        uninstallFirst: uninstallFirst,
        skipInstall: skipInstall,
      );
      if (deviceLogReader is IOSDeviceLogReader) {
        deviceLogReader.listenToIOSDeploy(iosDeployDebugger!);
      }
    } else if (deploymentMethod == IOSDeploymentMethod.coreDeviceWithLLDB) {
      if (deviceLogReader is IOSDeviceLogReader) {
        deviceLogReader.listenToCoreDeviceConsole(_coreDeviceLauncher.coreDeviceLogger);
      }
    }

    // Don't port forward if debugging with a wireless device.
    return ProtocolDiscovery.vmService(
      deviceLogReader,
      portForwarder: isWirelesslyConnected ? null : portForwarder,
      hostPort: debuggingOptions.hostVmServicePort,
      devicePort: debuggingOptions.deviceVmServicePort,
      ipv6: debuggingOptions.ipv6,
      logger: _logger,
    );
  }

  Future<Uri?> _discoverDartVM(
    IOSDeploymentMethod deploymentMethod, {
    required IOSApp package,
    required Directory bundle,
    required DebuggingOptions debuggingOptions,
    required String packageId,
    @visibleForTesting Duration? discoveryTimeout,
    ProtocolDiscovery? vmServiceDiscovery,
  }) async {
    _logger.printTrace('Application launched on the device. Waiting for Dart VM Service url.');

    final int defaultTimeout;
    if (isCoreDevice && debuggingOptions.debuggingEnabled) {
      // Core devices with debugging enabled takes longer because this
      // includes time to install and launch the app on the device.
      defaultTimeout = isWirelesslyConnected ? 75 : 60;
    } else if (isWirelesslyConnected) {
      defaultTimeout = 45;
    } else {
      defaultTimeout = 30;
    }

    final timer = Timer(discoveryTimeout ?? Duration(seconds: defaultTimeout), () {
      _logger.printError(
        'The Dart VM Service was not discovered after $defaultTimeout seconds. This is taking much longer than expected...',
      );
      // If debugging with a wireless device and the timeout is reached, remind the
      // user to allow local network permissions.
      if (isWirelesslyConnected) {
        _logger.printError(
          '\nYour debugging device seems wirelessly connected. '
          'Consider plugging it in and trying again.',
        );
        _logger.printError(
          '\nClick "Allow" to the prompt asking if you would like to find and connect devices on your local network. '
          'This is required for wireless debugging. If you selected "Don\'t Allow", '
          'you can turn it on in Settings > Your App Name > Local Network. '
          "If you don't see your app in the Settings, uninstall the app and rerun to see the prompt again.",
        );
      } else {
        iosDeployDebugger?.checkForSymbolsFiles(_fileSystem);
        iosDeployDebugger?.pauseDumpBacktraceResume();
      }
    });

    Uri? localUri;
    if (isCoreDevice) {
      localUri = await _discoverDartVMForCoreDevice(
        debuggingOptions: debuggingOptions,
        packageId: packageId,
        vmServiceDiscovery: vmServiceDiscovery,
        package: package,
      );
    } else if (isWirelesslyConnected) {
      // Wait for the Dart VM url to be discovered via logs (from `ios-deploy`)
      // in ProtocolDiscovery. Then via mDNS, construct the Dart VM url using
      // the device IP as the host by finding Dart VM services matching the
      // app bundle id and Dart VM port.

      // Wait for Dart VM Service to start up.
      final Uri? serviceURL = await vmServiceDiscovery?.uri;
      if (serviceURL == null) {
        return null;
      }

      // If Dart VM Service URL with the device IP is not found within 5 seconds,
      // change the status message to prompt users to click Allow. Wait 5 seconds because it
      // should only show this message if they have not already approved the permissions.
      // MDnsVmServiceDiscovery usually takes less than 5 seconds to find it.
      final mDNSLookupTimer = Timer(const Duration(seconds: 5), () {
        // startAppStatus.stop();
        // startAppStatus = _logger.startProgress(
        //   'Waiting for approval of local network permissions...',
        // );
      });

      // Get Dart VM Service URL with the device IP as the host.
      localUri = await MDnsVmServiceDiscovery.instance!.getVMServiceUriForLaunch(
        packageId,
        this,
        usesIpv6: debuggingOptions.ipv6,
        deviceVmservicePort: serviceURL.port,
        useDeviceIPAsHost: true,
      );

      mDNSLookupTimer.cancel();
    } else {
      localUri = await vmServiceDiscovery?.uri;
    }
    timer.cancel();

    return localUri;
  }

  @override
  Future<bool> stopApp(ApplicationPackage? app, {String? userIdentifier}) async {
    // If the debugger is not attached, killing the ios-deploy process won't stop the app.
    final IOSDeployDebugger? deployDebugger = iosDeployDebugger;
    if (deployDebugger != null && deployDebugger.debuggerAttached) {
      return deployDebugger.exit();
    }
    if (_xcodeDebug.debugStarted) {
      return _xcodeDebug.exit();
    }
    return _coreDeviceLauncher.stopApp(deviceId: id);
  }

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.ios;

  @override
  Future<String> get sdkNameAndVersion async => 'iOS ${_sdkVersion ?? 'unknown version'}';

  @override
  DeviceLogReader getLogReader({
    covariant IOSApp? app,
    bool includePastLogs = false,
    bool usingCISystem = false,
  }) {
    assert(!includePastLogs, 'Past log reading not supported on iOS devices.');
    return _logReaders.putIfAbsent(
      app,
      () => IOSDeviceLogReader.create(
        app: app,
        iMobileDevice: _iMobileDevice,
        xcode: globals.xcode!,
        majorSdkVersion: majorSdkVersion,
        deviceId: id,
        deviceName: displayName,
        isWirelesslyConnected: isWirelesslyConnected,
        isCoreDevice: isCoreDevice,
      ),
    );
  }

  @visibleForTesting
  void setLogReader(IOSApp app, DeviceLogReader logReader) {
    _logReaders[app] = logReader;
  }

  @override
  DevicePortForwarder get portForwarder => _portForwarder ??= IOSDevicePortForwarder(
    logger: _logger,
    iproxy: _iproxy,
    id: id,
    operatingSystemUtils: globals.os,
  );

  @visibleForTesting
  set portForwarder(DevicePortForwarder forwarder) {
    _portForwarder = forwarder;
  }

  @override
  void clearLogs() {}

  @override
  VMServiceDiscoveryForAttach getVMServiceDiscoveryForAttach({
    String? appId,
    String? fuchsiaModule,
    int? filterDevicePort,
    int? expectedHostPort,
    required bool ipv6,
    required Logger logger,
  }) {
    final bool compatibleWithProtocolDiscovery =
        majorSdkVersion < IOSDeviceLogReader.minimumUniversalLoggingSdkVersion &&
        !isWirelesslyConnected;
    final mdnsVMServiceDiscoveryForAttach = MdnsVMServiceDiscoveryForAttach(
      device: this,
      appId: appId,
      deviceVmservicePort: filterDevicePort,
      hostVmservicePort: expectedHostPort,
      usesIpv6: ipv6,
      useDeviceIPAsHost: isWirelesslyConnected,
    );

    if (compatibleWithProtocolDiscovery) {
      return DelegateVMServiceDiscoveryForAttach(<VMServiceDiscoveryForAttach>[
        mdnsVMServiceDiscoveryForAttach,
        super.getVMServiceDiscoveryForAttach(
          appId: appId,
          fuchsiaModule: fuchsiaModule,
          filterDevicePort: filterDevicePort,
          expectedHostPort: expectedHostPort,
          ipv6: ipv6,
          logger: logger,
        ),
      ]);
    } else {
      return mdnsVMServiceDiscoveryForAttach;
    }
  }

  @override
  bool get supportsScreenshot {
    if (isCoreDevice) {
      // `idevicescreenshot` stopped working with iOS 17 / Xcode 15
      // (https://github.com/flutter/flutter/issues/128598).
      return false;
    }
    return _iMobileDevice.isInstalled;
  }

  @override
  Future<void> takeScreenshot(File outputFile) async {
    await _iMobileDevice.takeScreenshot(outputFile, id, connectionInterface);
  }

  @override
  bool isSupportedForProject(FlutterProject flutterProject) {
    return flutterProject.ios.existsSync();
  }

  @override
  Future<void> dispose() async {
    for (final DeviceLogReader logReader in _logReaders.values) {
      logReader.dispose();
    }
    _logReaders.clear();
    await _portForwarder?.dispose();
  }
}

/// A [DevicePortForwarder] specialized for iOS usage with iproxy.
class IOSDevicePortForwarder extends DevicePortForwarder {
  /// Create a new [IOSDevicePortForwarder].
  IOSDevicePortForwarder({
    required Logger logger,
    required String id,
    required IProxy iproxy,
    required OperatingSystemUtils operatingSystemUtils,
  }) : _logger = logger,
       _id = id,
       _iproxy = iproxy,
       _operatingSystemUtils = operatingSystemUtils;

  /// Create a [IOSDevicePortForwarder] for testing.
  ///
  /// This specifies the path to iproxy as 'iproxy` and the dyLdLibEntry as
  /// 'DYLD_LIBRARY_PATH: /path/to/libs'.
  ///
  /// The device id may be provided, but otherwise defaults to '1234'.
  factory IOSDevicePortForwarder.test({
    required ProcessManager processManager,
    required Logger logger,
    String? id,
    required OperatingSystemUtils operatingSystemUtils,
  }) {
    return IOSDevicePortForwarder(
      logger: logger,
      iproxy: IProxy.test(logger: logger, processManager: processManager),
      id: id ?? '1234',
      operatingSystemUtils: operatingSystemUtils,
    );
  }

  final Logger _logger;
  final String _id;
  final IProxy _iproxy;
  final OperatingSystemUtils _operatingSystemUtils;

  @override
  var forwardedPorts = <ForwardedPort>[];

  @visibleForTesting
  void addForwardedPorts(List<ForwardedPort> ports) {
    ports.forEach(forwardedPorts.add);
  }

  static const _kiProxyPortForwardTimeout = Duration(seconds: 1);

  @override
  Future<int> forward(int devicePort, {int? hostPort}) async {
    final bool autoselect = hostPort == null || hostPort == 0;
    if (autoselect) {
      final int freePort = await _operatingSystemUtils.findFreePort();
      // Dynamic port range 49152 - 65535.
      hostPort = freePort == 0 ? 49152 : freePort;
    }

    Process? process;

    var connected = false;
    while (!connected) {
      _logger.printTrace('Attempting to forward device port $devicePort to host port $hostPort');
      process = await _iproxy.forward(devicePort, hostPort!, _id);
      // TODO(ianh): This is a flaky race condition, https://github.com/libimobiledevice/libimobiledevice/issues/674
      connected = !await process.stdout.isEmpty.timeout(
        _kiProxyPortForwardTimeout,
        onTimeout: () => false,
      );
      if (!connected) {
        process.kill();
        if (autoselect) {
          hostPort += 1;
          if (hostPort > 65535) {
            throw Exception('Could not find open port on host.');
          }
        } else {
          throw Exception('Port $hostPort is not available.');
        }
      }
    }
    assert(connected);
    assert(process != null);

    final forwardedPort = ForwardedPort.withContext(hostPort!, devicePort, process);
    _logger.printTrace('Forwarded port $forwardedPort');
    forwardedPorts.add(forwardedPort);
    return hostPort;
  }

  @override
  Future<void> unforward(ForwardedPort forwardedPort) async {
    if (!forwardedPorts.remove(forwardedPort)) {
      // Not in list. Nothing to remove.
      return;
    }

    _logger.printTrace('Un-forwarding port $forwardedPort');
    forwardedPort.dispose();
  }

  @override
  Future<void> dispose() async {
    for (final ForwardedPort forwardedPort in forwardedPorts) {
      forwardedPort.dispose();
    }
  }
}
