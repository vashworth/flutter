// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';
import 'package:process/process.dart';
import 'package:unified_analytics/unified_analytics.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/fingerprint.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/template.dart';
import '../base/version.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/ios.dart';
import '../build_system/targets/macos.dart';
import '../cache.dart';
import '../convert.dart';
import '../darwin/darwin.dart';
import '../features.dart';
import '../flutter_plugins.dart';
import '../globals.dart';
import '../ios/xcodeproj.dart';
import '../macos/cocoapod_utils.dart';
import '../macos/swift_package_manager.dart';
import '../macos/swift_packages.dart';
import '../macos/xcode.dart';
import '../plugins.dart';
import '../project.dart';
import '../runner/flutter_command.dart';
import '../version.dart';
import 'build.dart';

const String kPluginSwiftPackageName = 'FlutterPluginRegistrant';

class BuildSwiftPackages extends BuildSubCommand {
  BuildSwiftPackages({
    required super.logger,
    required Analytics analytics,
    required Artifacts artifacts,
    required BuildSystem buildSystem,
    required Cache cache,
    required FeatureFlags featureFlags,
    required FileSystem fileSystem,
    required FlutterVersion flutterVersion,
    required Platform platform,
    required ProcessManager processManager,
    required TemplateRenderer templateRenderer,
    required Xcode? xcode,
    required bool verboseHelp,
  }) : _analytics = analytics,
       _artifacts = artifacts,
       _cache = cache,
       _platform = platform,
       _processManager = processManager,
       _buildSystem = buildSystem,
       _featureFlags = featureFlags,
       _fileSystem = fileSystem,
       _flutterVersion = flutterVersion,
       _templateRenderer = templateRenderer,
       _xcode = xcode,
       super(verboseHelp: verboseHelp) {
    usesFlavorOption();
    addTreeShakeIconsFlag();
    usesTargetOption();
    usesPubOption();
    usesDartDefineOption();
    addSplitDebugInfoOption();
    addDartObfuscationOption();
    usesExtraDartFlagOptions(verboseHelp: verboseHelp);
    addEnableExperimentation(hide: !verboseHelp);
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'path/to/directory/',
        help: 'Location to write the frameworks.',
      )
      ..addMultiOption(
        'build-mode',
        allowed: ['debug', 'profile', 'release'],
        defaultsTo: ['debug', 'profile', 'release'],
      )
      ..addMultiOption('platforms', allowed: ['ios', 'macos'], defaultsTo: ['ios'])
      ..addFlag(
        'static',
        help:
            'Build CocoaPods plugins as static frameworks. Link on, but do not embed these frameworks in the existing Xcode project.',
      )
      ..addFlag(
        'cocoapods-as-binary-targets',
        defaultsTo: true,
        help: 'Adds CocoaPod-only plugins as binary targets in the generated swift package.',
      );
  }

  @override
  final name = 'swift-packages';

  @override
  final description =
      'Produces Swift packages and scripts for a Flutter project '
      'and its plugins for integration into existing, plain iOS and macOS Xcode projects.\n'
      'This can only be run on macOS hosts.';

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => const <DevelopmentArtifact>{
    DevelopmentArtifact.iOS,
    DevelopmentArtifact.macOS,
  };

  final Platform _platform;

  final BuildSystem _buildSystem;
  final FileSystem _fileSystem;
  final Artifacts _artifacts;
  final ProcessManager _processManager;
  final Xcode? _xcode;
  final Cache _cache;
  final Analytics _analytics;
  final TemplateRenderer _templateRenderer;
  final FlutterVersion _flutterVersion;
  final FeatureFlags _featureFlags;

  @override
  bool get supported => _platform.isMacOS;

  @protected
  List<FlutterDarwinPlatform> get targetPlatforms {
    final List<FlutterDarwinPlatform> platforms = [];
    stringsArg('platforms').forEach((platformString) {
      final FlutterDarwinPlatform? platform = FlutterDarwinPlatform.fromName(platformString);
      if (platform != null) {
        platforms.add(platform);
      }
    });
    return platforms;
  }

  bool get debugMode {
    return stringsArg('build-mode').where((mode) => mode == 'debug').isNotEmpty;
  }

  bool get profileMode {
    return stringsArg('build-mode').where((mode) => mode == 'profile').isNotEmpty;
  }

  bool get releaseMode {
    return stringsArg('build-mode').where((mode) => mode == 'release').isNotEmpty;
  }

  Future<List<BuildInfo>> getBuildInfos() async {
    return <BuildInfo>[
      if (debugMode) await getBuildInfo(forcedBuildMode: BuildMode.debug),
      if (profileMode) await getBuildInfo(forcedBuildMode: BuildMode.profile),
      if (releaseMode) await getBuildInfo(forcedBuildMode: BuildMode.release),
    ];
  }

  SwiftPackageSupportedPlatform iOSHighestSupportedVersion =
      FlutterDarwinPlatform.ios.supportedPackagePlatform;
  SwiftPackageSupportedPlatform macosHighestSupportedVersion =
      FlutterDarwinPlatform.macos.supportedPackagePlatform;

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
    if (targetPlatforms.isEmpty) {
      throwToolExit('--platforms is required.');
    }
    if (targetPlatforms.contains(FlutterDarwinPlatform.ios) && !project.ios.existsSync()) {
      throwToolExit(
        'The iOS platform is being targeted but the Flutter project does not support iOS. Use '
        'the "--platforms" flag to change the targeted platforms.',
      );
    }
    if (targetPlatforms.contains(FlutterDarwinPlatform.macos) && !project.macos.existsSync()) {
      throwToolExit(
        'The macOS platform is being targeted but the Flutter project does not support macOS. Use '
        'the "--platforms" flag to change the targeted platforms.',
      );
    }
    if (!_featureFlags.isSwiftPackageManagerEnabled) {
      throwToolExit(
        'Swift Package Manager is disabled. Ensure it is enabled in your global config ("flutter '
        'config --enable-swift-package-manager") and is not disabled in your Flutter '
        "project's pubspec.yaml.",
      );
    }
    final Version? xcodeVersion = _xcode?.currentVersion;
    if (xcodeVersion == null || xcodeVersion.major < 15) {
      throwToolExit(
        'Flutter requires Xcode 15 or greater when using Swift Package Manager. Please ensure '
        'Xcode is installed and meets the version requirements.',
      );
    }
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String outputArgument =
        stringArg('output') ??
        _fileSystem.path.join(_fileSystem.currentDirectory.path, 'build', 'ios', 'SwiftPackages');

    if (outputArgument.isEmpty) {
      throwToolExit('--output is required.');
    }

    final Directory outputDirectory = _fileSystem.directory(
      _fileSystem.path.absolute(_fileSystem.path.normalize(outputArgument)),
    );
    final List<BuildInfo> buildInfos = await getBuildInfos();
    return buildWithSwiftPM(buildInfos: buildInfos, outputDirectory: outputDirectory);
  }

  Future<FlutterCommandResult> buildWithSwiftPM({
    required List<BuildInfo> buildInfos,
    required Directory outputDirectory,
  }) async {
    await project.regeneratePlatformSpecificTooling(releaseMode: false);

    final Directory cacheDirectory = outputDirectory.childDirectory('.cache');
    final Directory pluginRegistrantSwiftPackage = outputDirectory.childDirectory(
      kPluginSwiftPackageName,
    );

    _deleteFiles(cacheDirectory, pluginRegistrantSwiftPackage);

    pluginRegistrantSwiftPackage.createSync(recursive: true);
    cacheDirectory.createSync(recursive: true);
    final Directory cachedFlutterFrameworks = cacheDirectory.childDirectory('FlutterFrameworks');
    final Directory cachedCocoaPodsFrameworks = cacheDirectory.childDirectory(
      'CocoaPodsFrameworks',
    );

    Status status;
    for (var i = 0; i < buildInfos.length; i++) {
      final BuildInfo buildInfo = buildInfos[i];
      final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
      final Directory xcframeworkOutput = pluginRegistrantSwiftPackage.childDirectory(
        xcodeBuildConfiguration,
      );

      logger.printStatus('Building for $xcodeBuildConfiguration...');

      status = logger.startProgress('   ├─Copying Flutter.xcframework...');
      await _copyFlutterFramework(buildMode: buildInfo.mode, xcframeworkOutput: xcframeworkOutput);
      status.stop();

      status = logger.startProgress('   ├─Building App.xcframework...');
      await _produceAppFramework(
        buildInfo: buildInfo,
        cacheDirectory: cachedFlutterFrameworks,
        xcframeworkOutput: xcframeworkOutput,
      );
      status.stop();

      status = logger.startProgress('   ├─Building CocoaPod xcframeworks...');
      await _produceCocoaPodPlugins(
        buildInfo: buildInfo,
        cacheDirectory: cachedCocoaPodsFrameworks,
        xcframeworkOutput: xcframeworkOutput.childDirectory('CocoaPods'),
      );
      status.stop();

      // TODO:
      // status = logger.startProgress('   ├─Creating Native Assets...');
      // _produceNativeAssets();
      // status.stop();
    }

    status = logger.startProgress('Generating swift packages...');
    final BuildMode defaultBuildMode = buildInfos[0].mode;

    final List<Plugin> plugins = await findPlugins(project);
    // Sort the plugins by name to keep ordering stable in generated files.
    plugins.sort((Plugin left, Plugin right) => left.name.compareTo(right.name));

    final (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies,
      List<SwiftPackageTarget> additionalTargets,
    ) = await _generateDependenciesAndTargets(
      defaultBuildMode: defaultBuildMode,
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      regularPlugins: plugins,
      cacheDirectory: cacheDirectory,
    );

    await _createPluginRegistrant(
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      packageDependencies: packageDependencies,
      targetDependencies: targetDependencies,
      additionalTargets: additionalTargets,
      buildInfos: buildInfos,
      plugins: plugins,
    );

    // The Flutter, App, and CocoaPods frameworks are built per build mode.
    final Link frameworksLink = pluginRegistrantSwiftPackage.childLink('Frameworks');
    if (!frameworksLink.existsSync()) {
      frameworksLink.createSync('./${defaultBuildMode.uppercaseName}');
    }

    _createBuildScripts(outputDirectory);

    status.stop();

    return FlutterCommandResult.success();
  }

  void _deleteFiles(Directory cacheDirectory, Directory pluginRegistrantSwiftPackage) {
    try {
      ErrorHandlingFileSystem.deleteIfExists(
        cacheDirectory.childDirectory('Packages'),
        recursive: true,
      );
    } on FileSystemException catch (e, stackTrace) {
      logger.printTrace(
        'Failed to delete ${cacheDirectory.childDirectory('Packages').path}: $e\n$stackTrace',
      );
    }

    ErrorHandlingFileSystem.deleteIfExists(
      pluginRegistrantSwiftPackage.childDirectory('Packages'),
      recursive: true,
    );
    ErrorHandlingFileSystem.deleteIfExists(pluginRegistrantSwiftPackage.childLink('Frameworks'));
    ErrorHandlingFileSystem.deleteIfExists(
      pluginRegistrantSwiftPackage.childDirectory('Sources'),
      recursive: true,
    );
  }

  /// Copy the Flutter xcframework from the engine cache to the [xcframeworkOutput].
  Future<void> _copyFlutterFramework({
    required BuildMode buildMode,
    required Directory xcframeworkOutput,
  }) async {
    for (final FlutterDarwinPlatform platform in targetPlatforms) {
      final String frameworkArtifactPath = _artifacts.getArtifactPath(
        platform.xcframeworkArtifact,
        platform: platform.targetPlatform,
        mode: buildMode,
      );
      final ProcessResult result = await _processManager.run(<String>[
        'rsync',
        '-av',
        '--delete',
        '--filter',
        '- .DS_Store/',
        '--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r',
        frameworkArtifactPath,
        xcframeworkOutput.path,
      ]);
      if (result.exitCode != 0) {
        throw Exception(
          'Failed to copy framework (exit ${result.exitCode}:\n'
          '${result.stdout}\n---\n${result.stderr}',
        );
      }
    }
  }

  /// Builds the App.framework for each platform sdk (iphoneos, iphonesimulator, macosx) into the
  /// [cacheDirectory]. Then packages them together into an xcframework in [xcframeworkOutput].
  Future<void> _produceAppFramework({
    required BuildInfo buildInfo,
    required Directory cacheDirectory,
    required Directory xcframeworkOutput,
  }) async {
    const appFrameworkName = 'App.framework';
    final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;

    final frameworks = <Directory>[];

    for (final FlutterDarwinPlatform platform in targetPlatforms) {
      for (final XcodeSdk sdk in platform.sdks) {
        final Directory outputBuildDirectory = cacheDirectory
            .childDirectory(xcodeBuildConfiguration)
            .childDirectory(sdk.platformName);
        frameworks.add(outputBuildDirectory.childDirectory(appFrameworkName));
        final platformDefines = <String, String>{};
        if (platform == FlutterDarwinPlatform.ios) {
          platformDefines.addAll(<String, String>{
            kIosArchs: defaultIOSArchsForEnvironment(
              sdk.sdkType,
              _artifacts,
            ).map((DarwinArch e) => e.name).join(' '),
            kSdkRoot: await _xcode!.sdkLocation(sdk.sdkType),
          });
        } else if (platform == FlutterDarwinPlatform.macos) {
          platformDefines.addAll(<String, String>{
            kDarwinArchs: defaultMacOSArchsForEnvironment(
              _artifacts,
            ).map((DarwinArch e) => e.name).join(' '),
          });
        }
        final environment = Environment(
          projectDir: _fileSystem.currentDirectory,
          packageConfigPath: packageConfigPath(),
          outputDir: outputBuildDirectory,
          buildDir: project.dartTool.childDirectory('flutter_build'),
          cacheDir: _cache.getRoot(),
          flutterRootDir: _fileSystem.directory(Cache.flutterRoot),
          defines: <String, String>{
            kTargetFile: targetFile,
            kTargetPlatform: getNameForTargetPlatform(platform.targetPlatform),
            ...platformDefines,
            ...buildInfo.toBuildSystemEnvironment(),
            kXcodeBuildScript: kXcodeBuildScriptValueNativeBuild,
          },
          artifacts: _artifacts,
          fileSystem: _fileSystem,
          logger: logger,
          processManager: _processManager,
          platform: _platform,
          analytics: _analytics,
          engineVersion: _artifacts.usesLocalArtifacts ? null : _flutterVersion.engineRevision,
          generateDartPluginRegistry: true,
        );
        final Target target = _determineTarget(platform, sdk, buildInfo);

        final BuildResult result = await _buildSystem.build(target, environment);
        if (!result.success) {
          for (final ExceptionMeasurement measurement in result.exceptions.values) {
            logger.printError(measurement.exception.toString());
          }
          throwToolExit('The App.xcframework build failed.');
        }
      }
    }

    await produceXCFramework(
      frameworks,
      'App',
      xcframeworkOutput,
      cacheDirectory,
      xcodeBuildConfiguration,
    );
  }

  Target _determineTarget(FlutterDarwinPlatform platform, XcodeSdk sdk, BuildInfo buildInfo) {
    switch (platform) {
      case FlutterDarwinPlatform.ios:
        // Always build debug for simulator.
        if (buildInfo.isDebug || sdk.sdkType == EnvironmentType.simulator) {
          return const DebugIosApplicationBundle();
        } else if (buildInfo.isProfile) {
          return const ProfileIosApplicationBundle();
        } else {
          return const ReleaseIosApplicationBundle();
        }
      case FlutterDarwinPlatform.macos:
        if (buildInfo.isDebug) {
          return const DebugMacOSBundleFlutterAssets();
        } else if (buildInfo.isProfile) {
          return const ProfileMacOSBundleFlutterAssets();
        } else {
          return const ReleaseMacOSBundleFlutterAssets();
        }
    }
  }

  /// Create an xcframework from a list of frameworks.
  Future<void> produceXCFramework(
    Iterable<Directory> frameworks,
    String frameworkBinaryName,
    Directory outputDirectory,
    Directory cacheDirectory,
    String buildMode,
  ) async {
    final Directory xcframeworkOutput = outputDirectory.childDirectory(
      '$frameworkBinaryName.xcframework',
    );

    ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
    final xcframeworkCommand = <String>[
      'xcrun',
      'xcodebuild',
      '-create-xcframework',
      for (final Directory framework in frameworks) ...<String>[
        '-framework',
        framework.path,
        ...framework.parent
            .listSync()
            .where(
              (FileSystemEntity entity) =>
                  entity.basename.endsWith('dSYM') && !entity.basename.startsWith('Flutter'),
            )
            .map((FileSystemEntity entity) => <String>['-debug-symbols', entity.path])
            .expand<String>((List<String> parameter) => parameter),
      ],
      '-output',
      xcframeworkOutput.path,
    ];

    final ProcessResult xcframeworkResult = await _processManager.run(
      xcframeworkCommand,
      includeParentEnvironment: false,
    );

    if (xcframeworkResult.exitCode != 0) {
      throwToolExit(
        'Unable to create $frameworkBinaryName.xcframework: ${xcframeworkResult.stderr}',
      );
    }
  }

  Future<void> _produceCocoaPodPlugins({
    required BuildInfo buildInfo,
    required Directory cacheDirectory,
    required Directory xcframeworkOutput,
  }) async {
    final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
    Fingerprinter fingerprinter = _cocoapodsFingerprinter(
      cacheDirectory.path,
      xcframeworkOutput,
      buildInfo.mode.cliName,
    );
    final bool dependenciesChanged = !fingerprinter.doesFingerprintMatch();
    if (!dependenciesChanged && xcframeworkOutput.existsSync()) {
      logger.printStatus('Skipping building CocoaPod plugins. No change detected');
      return;
    } else if (dependenciesChanged) {
      ErrorHandlingFileSystem.deleteIfExists(cacheDirectory, recursive: true);
      ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
    }

    final createdFrameworks = <String, List<Directory>>{};

    for (final FlutterDarwinPlatform platform in targetPlatforms) {
      final XcodeBasedProject xcodeProject = platform.xcodeProject(project);
      final Directory podsDirectory = xcodeProject.hostAppRoot.childDirectory('Pods');
      if (!podsDirectory.existsSync() || !xcodeProject.podfile.existsSync()) {
        continue;
      }
      final String buildDirectory;
      switch (platform) {
        case FlutterDarwinPlatform.ios:
          buildDirectory = getIosBuildDirectory();
        case FlutterDarwinPlatform.macos:
          buildDirectory = getMacOSBuildDirectory();
      }
      await processPodsIfNeeded(xcodeProject, buildDirectory, buildInfo.mode);

      for (final XcodeSdk sdk in platform.sdks) {
        final String configuration;
        if (sdk.sdkType == EnvironmentType.simulator) {
          // Always build debug for simulator.
          configuration = BuildMode.debug.uppercaseName;
        } else {
          configuration = xcodeBuildConfiguration;
        }
        final Directory outputBuildDirectory = cacheDirectory
            .childDirectory(xcodeBuildConfiguration)
            .childDirectory(sdk.platformName);
        final pluginsBuildCommand = <String>[
          ..._xcode!.xcrunCommand(),
          'xcodebuild',
          '-alltargets',
          '-sdk',
          sdk.platformName,
          '-configuration',
          configuration,
          'SYMROOT=${outputBuildDirectory.path}',
          'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
          'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
          if (boolArg('static')) 'MACH_O_TYPE=staticlib',
        ];
        final ProcessResult buildPluginsResult = await _processManager.run(
          pluginsBuildCommand,
          workingDirectory: podsDirectory.path,
        );
        if (buildPluginsResult.exitCode != 0) {
          throwToolExit('Unable to build plugin frameworks: ${buildPluginsResult.stderr}');
        }
        final Directory configurationBuildDir;
        if (platform == FlutterDarwinPlatform.macos) {
          configurationBuildDir = outputBuildDirectory.childDirectory(configuration);
        } else {
          configurationBuildDir = outputBuildDirectory.childDirectory('$configuration-${sdk.name}');
        }
        final Iterable<Directory> products = configurationBuildDir
            .listSync(followLinks: false)
            .whereType<Directory>();
        for (final builtProduct in products) {
          for (final Directory podProduct
              in builtProduct.listSync(followLinks: false).whereType<Directory>()) {
            final String podFrameworkName = podProduct.basename;
            if (_fileSystem.path.extension(podFrameworkName) != '.framework') {
              continue;
            }
            final String binaryName = _fileSystem.path.basenameWithoutExtension(podFrameworkName);
            if (createdFrameworks[binaryName] == null) {
              createdFrameworks[binaryName] = <Directory>[];
            }
            createdFrameworks[binaryName]?.add(podProduct);
          }
        }
      }
    }

    for (final String frameworkName in createdFrameworks.keys) {
      final List<Directory>? frameworkDirectories = createdFrameworks[frameworkName];
      if (frameworkDirectories != null) {
        await produceXCFramework(
          frameworkDirectories,
          frameworkName,
          xcframeworkOutput,
          cacheDirectory,
          xcodeBuildConfiguration,
        );
      }
    }
    fingerprinter = _cocoapodsFingerprinter(
      cacheDirectory.path,
      xcframeworkOutput,
      buildInfo.mode.cliName,
    );
    fingerprinter.writeFingerprint();
  }

  Fingerprinter _cocoapodsFingerprinter(
    String cacheDirectoryPath,
    Directory cocoapodFrameworkDirectory,
    String xcodeBuildConfiguration,
  ) {
    final fingerprintedFiles = <String>[];

    // Add already created xcframeworks
    if (cocoapodFrameworkDirectory.existsSync()) {
      for (final FileSystemEntity entity in cocoapodFrameworkDirectory.listSync(recursive: true)) {
        if (entity is File) {
          fingerprintedFiles.add(entity.path);
        }
      }
    }

    // If the Xcode project, Podfile, generated plugin Swift Package, or podhelper
    // have changed since last run, pods should be updated.
    for (final FlutterDarwinPlatform platform in targetPlatforms) {
      final XcodeBasedProject xcodeProject = platform.xcodeProject(project);
      fingerprintedFiles.add(xcodeProject.xcodeProjectInfoFile.path);
      fingerprintedFiles.add(xcodeProject.podfile.path);
      if (xcodeProject.flutterPluginSwiftPackageManifest.existsSync()) {
        fingerprintedFiles.add(xcodeProject.flutterPluginSwiftPackageManifest.path);
      }
    }

    final fingerprinter = Fingerprinter(
      fingerprintPath: _fileSystem.path.join(
        cacheDirectoryPath,
        'build_${xcodeBuildConfiguration}_pod_inputs.fingerprint',
      ),
      paths: <String>[
        _fileSystem.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'bin',
          'podhelper.rb',
        ),
        _fileSystem.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'lib',
          'src',
          'commands',
          'build_swift_packages.dart',
        ),
        ...fingerprintedFiles,
      ],
      fileSystem: _fileSystem,
      logger: logger,
    );
    return fingerprinter;
  }

  Future<
    (
      List<SwiftPackagePackageDependency>,
      List<SwiftPackageTargetDependency>,
      List<SwiftPackageTarget>,
    )
  >
  _generateDependenciesAndTargets({
    required BuildMode defaultBuildMode,
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> regularPlugins,
    required Directory cacheDirectory,
  }) async {
    final String defaultBuildConfiguration = defaultBuildMode.uppercaseName;

    final (SwiftPackageTargetDependency appTargetDependency, SwiftPackageTarget appTargetBinary) =
        _generateAppFrameworkSwiftDependency();

    final (
      List<SwiftPackageTargetDependency> cocoapodTargetDependencies,
      List<SwiftPackageTarget> cocoapodBinaryTargets,
    ) = _generateCocoaPodsBinaryTargets(
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      defaultBuildConfiguration: defaultBuildConfiguration,
      fileSystem: _fileSystem,
    );

    final (
      List<SwiftPackagePackageDependency> pluginPackageDependencies,
      List<SwiftPackageTargetDependency> pluginTargetDependencies,
    ) = await _generatePluginDependencies(
      flutterPluginsSwiftPackage: pluginRegistrantSwiftPackage,
      fileSystem: _fileSystem,
      plugins: regularPlugins,
      defaultBuildMode: defaultBuildMode,
      cacheDirectory: cacheDirectory,
    );

    final (
      SwiftPackagePackageDependency flutterFrameworkPackageDependency,
      SwiftPackageTargetDependency flutterFrameworkTargetDependency,
    ) = await _generateFlutterFrameworkSwiftPackage(
      packageDirectory: pluginRegistrantSwiftPackage.childDirectory('Packages'),
    );

    return (
      <SwiftPackagePackageDependency>[
        ...pluginPackageDependencies,
        flutterFrameworkPackageDependency,
      ],
      <SwiftPackageTargetDependency>[
        appTargetDependency,
        ...cocoapodTargetDependencies,
        ...pluginTargetDependencies,
        flutterFrameworkTargetDependency,
      ],
      <SwiftPackageTarget>[appTargetBinary, ...cocoapodBinaryTargets],
    );
  }

  (SwiftPackageTargetDependency, SwiftPackageTarget) _generateAppFrameworkSwiftDependency() {
    return (
      SwiftPackageTargetDependency.target(name: 'App'),
      SwiftPackageTarget.binaryTarget(name: 'App', relativePath: r'Frameworks/App.xcframework'),
    );
  }

  (List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) _generateCocoaPodsBinaryTargets({
    required Directory pluginRegistrantSwiftPackage,
    required String defaultBuildConfiguration,
    required FileSystem fileSystem,
  }) {
    final cocoapodTargetDependencies = <SwiftPackageTargetDependency>[];
    final cocoapodBinaryTargets = <SwiftPackageTarget>[];

    if (!boolArg('cocoapods-as-binary-targets')) {
      return (cocoapodTargetDependencies, cocoapodBinaryTargets);
    }

    // They should all have the same directories, so just pick the first.

    final Directory cocoapodsFrameworksDirectory = pluginRegistrantSwiftPackage
        .childDirectory(defaultBuildConfiguration)
        .childDirectory('CocoaPods');

    if (cocoapodsFrameworksDirectory.existsSync()) {
      for (final FileSystemEntity entity in cocoapodsFrameworksDirectory.listSync()) {
        if (entity is Directory && entity.basename.endsWith('xcframework')) {
          final String frameworkName = fileSystem.path.basenameWithoutExtension(entity.path);
          final platformConditions = <SwiftPackagePlatform>{};
          for (final FileSystemEntity subfile in entity.listSync()) {
            if (subfile.basename.contains(FlutterDarwinPlatform.ios.name)) {
              platformConditions.add(SwiftPackagePlatform.ios);
            } else {
              if (subfile.basename.contains(FlutterDarwinPlatform.macos.name)) {
                platformConditions.add(SwiftPackagePlatform.macos);
              }
            }
          }
          cocoapodTargetDependencies.add(
            SwiftPackageTargetDependency.target(
              name: frameworkName,
              platformCondition: platformConditions.toList(),
            ),
          );
          cocoapodBinaryTargets.add(
            SwiftPackageTarget.binaryTarget(
              name: frameworkName,
              relativePath: 'Frameworks/CocoaPods/${entity.basename}',
            ),
          );
        }
      }
    }
    return (cocoapodTargetDependencies, cocoapodBinaryTargets);
  }

  Future<void> produceRegistrantSourceFiles({
    required List<BuildInfo> buildInfos,
    required Directory pluginRegistrantSwiftPackage,
    required List<Plugin> plugins,
    required List<SwiftPackageTargetDependency> targetDependencies,
  }) async {
    for (final buildInfo in buildInfos) {
      final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
      final Directory modeDirectory = pluginRegistrantSwiftPackage.childDirectory(
        xcodeBuildConfiguration,
      );
      final File implementationFile = modeDirectory
          .childDirectory(kPluginSwiftPackageName)
          .childFile('GeneratedPluginRegistrant.m');
      final File headerFile = modeDirectory
          .childDirectory(kPluginSwiftPackageName)
          .childDirectory('include')
          .childFile('GeneratedPluginRegistrant.h');
      if (targetPlatforms.singleOrNull == FlutterDarwinPlatform.ios) {
        await writeIOSPluginRegistrant(
          project,
          plugins,
          pluginRegistrantHeader: headerFile,
          pluginRegistrantImplementation: implementationFile,
        );
      } else if (targetPlatforms.singleOrNull == FlutterDarwinPlatform.macos) {
        await writeMacOSPluginRegistrant(
          project,
          plugins,
          pluginRegistrantImplementation: modeDirectory
              .childDirectory(kPluginSwiftPackageName)
              .childFile('GeneratedPluginRegistrant.swift'),
        );
      } else {
        await writeDarwinPluginRegistrant(
          project,
          plugins,
          pluginRegistrantHeader: headerFile,
          pluginRegistrantImplementation: implementationFile,
        );
      }

      ErrorHandlingFileSystem.deleteIfExists(
        pluginRegistrantSwiftPackage.childDirectory('Sources'),
        recursive: true,
      );

      final Link sourcesLink = pluginRegistrantSwiftPackage
          .childDirectory('Sources')
          .childLink(kPluginSwiftPackageName);
      sourcesLink.createSync(
        './../${defaultBuildMode.uppercaseName}/$kPluginSwiftPackageName',
        recursive: true,
      );
    }
  }

  // Create FlutterPluginRegistrant Swift Package with dependencies on the
  // Swift Package plugins, CocoaPods xcframeworks, and Flutter/App xcframeworks.
  Future<void> _createPluginRegistrant({
    required Directory pluginRegistrantSwiftPackage,
    required List<SwiftPackagePackageDependency> packageDependencies,
    required List<SwiftPackageTargetDependency> targetDependencies,
    required List<SwiftPackageTarget> additionalTargets,
    required List<BuildInfo> buildInfos,
    required List<Plugin> plugins,
  }) async {
    const String swiftPackageName = kPluginSwiftPackageName;
    final File manifestFile = pluginRegistrantSwiftPackage.childFile('Package.swift');

    final generatedProduct = SwiftPackageProduct(
      name: swiftPackageName,
      targets: <String>[swiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

    final targets = <SwiftPackageTarget>[
      SwiftPackageTarget.defaultTarget(name: swiftPackageName, dependencies: targetDependencies),
      ...additionalTargets,
    ];

    final pluginsPackage = SwiftPackage(
      manifest: manifestFile,
      name: swiftPackageName,
      platforms: <SwiftPackageSupportedPlatform>[
        iOSHighestSupportedVersion,
        macosHighestSupportedVersion,
      ],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: packageDependencies,
      targets: targets,
      templateRenderer: _templateRenderer,
    );

    pluginsPackage.createSwiftPackage();

    // Create FlutterPluginRegistrant source files
    await produceRegistrantSourceFiles(
      buildInfos: buildInfos,
      pluginRegistrantSwiftPackage: pluginRegistrantSwiftPackage,
      plugins: plugins,
      targetDependencies: targetDependencies,
    );
  }

  Future<(List<SwiftPackagePackageDependency>, List<SwiftPackageTargetDependency>)>
  _generatePluginDependencies({
    required Directory flutterPluginsSwiftPackage,
    required FileSystem fileSystem,
    required List<Plugin> plugins,
    required BuildMode defaultBuildMode,
    required Directory cacheDirectory,
  }) async {
    final List<SwiftPackagePackageDependency> packageDependencies = [];
    final List<SwiftPackageTargetDependency> targetDependencies = [];
    for (final FlutterDarwinPlatform platform in targetPlatforms) {
      for (final plugin in plugins) {
        // Get Swift Package manifest
        final String? pluginSwiftPackageManifestPath = plugin.pluginSwiftPackageManifestPath(
          fileSystem,
          platform.name,
        );
        if (plugin.platforms[platform.name] == null ||
            pluginSwiftPackageManifestPath == null ||
            !fileSystem.file(pluginSwiftPackageManifestPath).existsSync()) {
          continue;
        }

        _validatePluginSupportsPlatformsCorrectly(plugin);
        if (packageDependencies.where((dependency) => dependency.name == plugin.name).isNotEmpty) {
          continue;
        }

        final Directory pluginSource = fileSystem.directory(plugin.path);
        final Directory pluginDestination =
            cacheDirectory.childDirectory('Packages').childDirectory(plugin.name)
              ..createSync(recursive: true);
        // Copy plugins from pubcache to swift package cache
        copyDirectory(
          pluginSource,
          pluginDestination,
          shouldCopyDirectory: (Directory dir) => !dir.path.endsWith('example'),
        );
        // Get new plugin path
        final String? packagePath = plugin.pluginSwiftPackagePath(
          fileSystem,
          platform.name,
          overridePath: pluginDestination.path,
        );
        if (packagePath == null) {
          throwToolExit('Failed to copy ${plugin.name}');
        }

        // Get new plugin Swift Package manifest path
        final File swiftPackageManifest = fileSystem.file(
          fileSystem.path.join(packagePath, 'Package.swift'),
        );
        if (!swiftPackageManifest.existsSync()) {
          throwToolExit('Failed to copy ${plugin.name}');
        }

        await _parseSwiftPackage(packagePath, swiftPackageManifest);

        // Xcode may put something here?
        ErrorHandlingFileSystem.deleteIfExists(
          flutterPluginsSwiftPackage.childDirectory('Packages').childDirectory(plugin.name),
          recursive: true,
        );

        // Create a symlink from FlutterPluginRegistrant to the cache path
        final Link linkToCache = flutterPluginsSwiftPackage
            .childDirectory('Packages')
            .childLink(plugin.name);
        linkToCache.createSync(
          _fileSystem.path.relative(packagePath, from: linkToCache.parent.path),
          recursive: true,
        );

        packageDependencies.add(
          SwiftPackagePackageDependency(name: plugin.name, path: 'Packages/${plugin.name}'),
        );
        targetDependencies.add(
          SwiftPackageTargetDependency.product(
            name: plugin.name.replaceAll('_', '-'),
            packageName: plugin.name,
            platformCondition: plugin.isDarwinPluginWithSharedSources()
                ? [SwiftPackagePlatform.ios, SwiftPackagePlatform.macos]
                : [platform.swiftPackagePlatform],
          ),
        );
      }
    }

    return (packageDependencies, targetDependencies);
  }

  void _validatePluginSupportsPlatformsCorrectly(Plugin plugin) {
    var count = 0;
    if (plugin.isDarwinPluginWithSharedSources()) {
      return;
    }
    for (final FlutterDarwinPlatform platform in targetPlatforms) {
      final String? pluginSwiftPackageManifestPath = plugin.pluginSwiftPackageManifestPath(
        _fileSystem,
        platform.name,
      );
      if (plugin.platforms[platform.name] == null ||
          pluginSwiftPackageManifestPath == null ||
          !_fileSystem.file(pluginSwiftPackageManifestPath).existsSync()) {
        continue;
      }

      count++;
      if (count > 1) {
        throwToolExit(
          'Plugin ${plugin.name} does not support building for multiple platforms. '
          'Please use the "--platforms" flag to target a single platform and file an issue with the '
          'plugin to add support to multiple platforms.',
        );
      }
    }
  }

  Future<void> _parseSwiftPackage(String packagePath, File swiftPackageManifest) async {
    try {
      final ProcessResult parsedManifest = await _processManager.run([
        'swift',
        'package',
        'dump-package',
      ], workingDirectory: packagePath);
      final SwiftPackage? pluginSwiftPackage = SwiftPackage.fromJson(
        json.decode(parsedManifest.stdout.toString()) as Map<String, Object?>,
        manifest: swiftPackageManifest,
        templateRenderer: _templateRenderer,
      );
      if (pluginSwiftPackage == null) {
        return;
      }
      // Parse the plugins with the minimum deployment target.
      // The FlutterPluginRegistrant needs to match the highest version. Otherwise, it will error.
      for (final SwiftPackageSupportedPlatform swiftPlatform in pluginSwiftPackage.platforms) {
        if (swiftPlatform.platform == SwiftPackagePlatform.ios &&
            swiftPlatform.version > iOSHighestSupportedVersion.version) {
          iOSHighestSupportedVersion = swiftPlatform;
        }
        if (swiftPlatform.platform == SwiftPackagePlatform.macos &&
            swiftPlatform.version > macosHighestSupportedVersion.version) {
          macosHighestSupportedVersion = swiftPlatform;
        }
      }

      // Parse swift package for FlutterFramework dependency and add if not found
      // If it's not found as a package dependency, add it and add it as a dependency for each target
      var hasDependencyOnFlutter = false;
      for (final SwiftPackagePackageDependency dependency in pluginSwiftPackage.dependencies) {
        if (dependency.name == 'FlutterFramework') {
          hasDependencyOnFlutter = true;
          break;
        }
      }
      if (!hasDependencyOnFlutter) {
        // Add the Flutter framework as a dependency for each target
        final ProcessResult addDependencyResult = await _processManager.run([
          'swift',
          'package',
          'add-dependency',
          '../FlutterFramework',
          '--type',
          'path',
        ], workingDirectory: packagePath);
        if (addDependencyResult.exitCode != 0) {
          logger.printTrace(
            'Failed to add FlutterFramework as a package dependency to $packagePath',
          );
          return;
        }
        for (final SwiftPackageTarget target in pluginSwiftPackage.targets) {
          final ProcessResult addDependencyResult = await _processManager.run([
            'swift',
            'package',
            'add-target-dependency',
            'FlutterFramework',
            target.name,
            '--package',
            'FlutterFramework',
          ], workingDirectory: packagePath);
          if (addDependencyResult.exitCode != 0) {
            logger.printTrace(
              'Failed to add FlutterFramework as a target dependency of ${target.name} to $packagePath',
            );
          }
        }
      }

      // swift package dump-package
      // swift package add-dependency ../FlutterFramework --type path
      // .package(name: "FlutterFramework", path: "../FlutterFramework")
      // swift package add-target-dependency FlutterFramework image_picker_ios --package FlutterFramework
      //   dependencies: [
      //     .product(name: "FlutterFramework", package: "FlutterFramework")
      // ],
    } on Exception catch (e) {}
  }

  Future<(SwiftPackagePackageDependency, SwiftPackageTargetDependency)>
  _generateFlutterFrameworkSwiftPackage({required Directory packageDirectory}) async {
    final flutterFrameworkPackage = SwiftPackage(
      manifest: packageDirectory
          .childDirectory(kFlutterGeneratedFrameworkSwiftPackageTargetName)
          .childFile('Package.swift'),
      name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
      platforms: <SwiftPackageSupportedPlatform>[],
      products: <SwiftPackageProduct>[
        SwiftPackageProduct(
          name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
          targets: <String>[kFlutterGeneratedFrameworkSwiftPackageTargetName],
        ),
      ],
      dependencies: <SwiftPackagePackageDependency>[],
      targets: <SwiftPackageTarget>[
        SwiftPackageTarget.defaultTarget(
          name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
          dependencies: [
            for (final platform in targetPlatforms)
              SwiftPackageTargetDependency.target(
                name: platform.binaryName,
                platformCondition: [platform.swiftPackagePlatform],
              ),
          ],
        ),
        for (final platform in targetPlatforms)
          SwiftPackageTarget.binaryTarget(
            name: platform.binaryName,
            relativePath: '../../Frameworks/${platform.binaryName}.xcframework',
          ),
      ],
      templateRenderer: _templateRenderer,
    );
    flutterFrameworkPackage.createSwiftPackage();

    return (
      SwiftPackagePackageDependency(
        name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
        path: 'Packages/FlutterFramework',
      ),
      SwiftPackageTargetDependency.product(
        name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
        packageName: kFlutterGeneratedFrameworkSwiftPackageTargetName,
      ),
    );
  }

  void _createBuildScripts(Directory outputDirectory) {
    const updateBuildModeScript = r'''
#!/bin/bash

# Generated file. Do not edit.

# exit on error, or usage of unset var
set -euo pipefail

EchoWarning() {
  echo "$@" 1>&2
}

ParseFlutterBuildMode() {
  # Use FLUTTER_BUILD_MODE if it's set, otherwise use the Xcode build configuration name
  # This means that if someone wants to use an Xcode build config other than Debug/Profile/Release,
  # they _must_ set FLUTTER_BUILD_MODE so we know what type of artifact to build.
  local build_mode="$(echo "${FLUTTER_BUILD_MODE:-${CONFIGURATION}}" | tr "[:upper:]" "[:lower:]")"

  case "$build_mode" in
    *release*) build_mode="Release";;
    *profile*) build_mode="Profile";;
    *debug*) build_mode="Debug";;
    *)
    # TODO: link to documentation
      EchoWarning "========================================================================"
      EchoWarning "WARNING: Unknown FLUTTER_BUILD_MODE: ${build_mode}. Please see [insert link here] on how to setup FLUTTER_BUILD_MODE."
      EchoWarning "========================================================================"
      exit -1;;
  esac

  echo "${build_mode}"
}

if [[ $ACTION == "clean" ]]; then
  exit 0
fi

# 1: Parse build mode
build_mode=$(ParseFlutterBuildMode)

# 2: Get the symlink of the Frameworks directory relative to this script. For example, if the script is available at frameworks/Scripts/update.sh, the Frameworks directory is located at frameworks/FlutterPluginRegistrant/Frameworks
# Needed because if it is set, cd may print the path it changed to.
unset CDPATH

function follow_links() (
  cd -P "$(dirname -- "$1")"
  file="$PWD/$(basename -- "$1")"
  while [[ -h "$file" ]]; do
    cd -P "$(dirname -- "$file")"
    file="$(readlink -- "$file")"
    cd -P "$(dirname -- "$file")"
    file="$PWD/$(basename -- "$file")"
  done
  echo "$file"
)

PROG_NAME="$(follow_links "${BASH_SOURCE[0]}")"
BIN_DIR="$(cd "${PROG_NAME%/*}" ; pwd -P)"
frameworks_symlink_path="$BIN_DIR/../FlutterPluginRegistrant/Frameworks"

# # 3: If symlink does not match build mode, update it if it exists, otherwise, throw an error
current_target=$(readlink "$frameworks_symlink_path")
EchoWarning "Current link: $current_target"

if [ "$current_target" == "./$build_mode" ]; then
  echo "Frameworks symlink is up-to-date."
  exit 0
fi

EchoWarning "Frameworks symlink is out-of-date. Current: $current_target, Expected: ./$build_mode"

symlink_dir=$(dirname "$frameworks_symlink_path")
new_target_dir="${symlink_dir}/${build_mode}"
if [ ! -d "$new_target_dir" ]; then
    EchoWarning "error: New framework target directory does not exist: $new_target_dir"
    exit 1
fi

echo "Updating frameworks symlink to point to $build_mode configuration."
ln -sfh "./$build_mode" "$frameworks_symlink_path"

echo "Frameworks symlink $frameworks_symlink_path updated to ./$build_mode."
''';
    const verifyScript = r'''
#!/bin/bash

# Generated file. Do not edit.

set -euo pipefail

EchoWarning() {
  echo "warning: $@" 1>&2
}

EchoError() {
  echo "error: $@" 1>&2
}

ParseFlutterBuildMode() {
  # Use FLUTTER_BUILD_MODE if it's set, otherwise use the Xcode build configuration name
  # This means that if someone wants to use an Xcode build config other than Debug/Profile/Release,
  # they _must_ set FLUTTER_BUILD_MODE so we know what type of artifact to build.
  local build_mode="$(echo "${FLUTTER_BUILD_MODE:-${CONFIGURATION}}" | tr "[:upper:]" "[:lower:]")"

  case "$build_mode" in
    *release*) build_mode="release";;
    *profile*) build_mode="profile";;
    *debug*) build_mode="debug";;
    *)
    # TODO: link to documentation
      EchoWarning "========================================================================"
      EchoWarning "WARNING: Unknown FLUTTER_BUILD_MODE: ${build_mode}. Please see [insert link here] on how to setup FLUTTER_BUILD_MODE."
      EchoWarning "========================================================================"
      exit -1;;
  esac

  echo "${build_mode}"
}

# 1, parse the build mode
build_mode=$(ParseFlutterBuildMode)

# Determine platform and Info.plist path
if [[ "${PLATFORM_NAME:-}" == "macosx" ]]; then
  info_plist_path="FlutterMacOS.framework/Resources/Info.plist"
else
  # Default to iOS
  info_plist_path="Flutter.framework/Info.plist"
fi

VerifyFrameworkBuildMode() {
  local destination_dir="$1"

  framework_info_plist_path="$destination_dir/$info_plist_path"
  local output=$(env -i plutil -extract BuildMode raw -o - $framework_info_plist_path 2>&1)

  local sdk_root="$(echo "${SDKROOT}" | tr "[:upper:]" "[:lower:]")"
  if [[ "$sdk_root" == *"simulator"* ]]; then
    local expected_build_mode="debug"
  else
    local expected_build_mode="$build_mode"
  fi

  if [ "$output" != $expected_build_mode ]; then
    EchoError "The Flutter framework's build mode does not match the currently targeted configuration in $framework_info_plist_path. Expected $build_mode, but found $output";
    exit -1;
  fi
}

VerifyFrameworkBuildMode "${BUILT_PRODUCTS_DIR}"
VerifyFrameworkBuildMode "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

# Ensure FLUTTER_APPLICATION_PATH is provided.
if [ -z "${FLUTTER_APPLICATION_PATH}" ]; then
  echo "error: FLUTTER_APPLICATION_PATH is not set." >&2
  exit 1
fi
resolved_path="${FLUTTER_APPLICATION_PATH}"
if [[ "${FLUTTER_APPLICATION_PATH}" != /* ]]; then
  # It's a relative path. Ensure SRCROOT is set.
  if [ -z "${SRCROOT}" ]; then
    echo "error: SRCROOT is not set." >&2
    exit 1
  fi
  # Prepend SRCROOT to make the path absolute.
  resolved_path="${SRCROOT}/${FLUTTER_APPLICATION_PATH}"
fi
case "${PLATFORM_NAME}" in
  *macosx*) platform="macos";;
  *iphoneos*) platform="ios";;
  *iphonesimulator*) platform="ios";;
  *)
    # TODO: link to documentation
    echo "error: Unknown PLATFORM_NAME: ${PLATFORM_NAME}. Flutter only supports iOS and macOS." >&2
    exit -1;;
esac
resolved_path="${resolved_path}/${platform}/Flutter/flutter_export_environment.sh"
source "$resolved_path"
BIN_DIR="$FLUTTER_ROOT/packages/flutter_tools/bin/"
DART="$FLUTTER_ROOT/bin/dart"
"$DART" "$BIN_DIR/xcode_backend.dart" build-native "$platform"
''';

    outputDirectory.childDirectory('Scripts').childFile('update.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(updateBuildModeScript);

    outputDirectory.childDirectory('Scripts').childFile('verify.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync(verifyScript);
  }
}
