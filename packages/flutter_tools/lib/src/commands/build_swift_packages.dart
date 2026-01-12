// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:hooks_runner/hooks_runner.dart' as build_hooks;
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
import '../isolated/native_assets/native_assets.dart';
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
const String _kPackages = 'Packages';
const String _kFrameworks = 'Frameworks';
const String _kCocoaPods = 'CocoaPods';
const String _kPlugins = 'Plugins';
const String _kNativeAssets = 'NativeAssets';

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
      ..addOption('platform', allowed: ['ios', 'macos'], defaultsTo: 'ios')
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

  List<FlutterDarwinPlatform> get _targetPlatforms {
    final String? platformString = stringArg('platform');
    if (platformString != null) {
      final FlutterDarwinPlatform? darwinPlatform = FlutterDarwinPlatform.fromName(platformString);
      if (darwinPlatform != null) {
        return [darwinPlatform];
      }
    }
    return [];

    // return stringsArg('platform')
    //     .map((String platformString) => FlutterDarwinPlatform.fromName(platformString))
    //     .whereType<FlutterDarwinPlatform>()
    //     .toList();
  }

  Future<List<BuildInfo>> _getBuildInfos() async {
    final List<String> buildModes = stringsArg('build-mode');
    final List<BuildInfo> buildInfos = [];
    if (buildModes.contains('debug')) {
      buildInfos.add(await getBuildInfo(forcedBuildMode: BuildMode.debug));
    }
    if (buildModes.contains('profile')) {
      buildInfos.add(await getBuildInfo(forcedBuildMode: BuildMode.profile));
    }
    if (buildModes.contains('release')) {
      buildInfos.add(await getBuildInfo(forcedBuildMode: BuildMode.release));
    }
    return buildInfos;
  }

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
    _validateTargetPlatforms();
    _validateFeatureFlags();
    _validateXcodeVersion();
  }

  void _validateTargetPlatforms() {
    if (_targetPlatforms.isEmpty) {
      throwToolExit('--platform is required.');
    }
    if (_targetPlatforms.contains(FlutterDarwinPlatform.ios) && !project.ios.existsSync()) {
      throwToolExit(
        'The iOS platform is being targeted but the Flutter project does not support iOS. Use '
        'the "--platform" flag to change the targeted platforms.',
      );
    }
    if (_targetPlatforms.contains(FlutterDarwinPlatform.macos) && !project.macos.existsSync()) {
      throwToolExit(
        'The macOS platform is being targeted but the Flutter project does not support macOS. Use '
        'the "--platform" flag to change the targeted platforms.',
      );
    }
  }

  void _validateFeatureFlags() {
    if (!_featureFlags.isSwiftPackageManagerEnabled) {
      throwToolExit(
        'Swift Package Manager is disabled. Ensure it is enabled in your global config ("flutter '
        'config --enable-swift-package-manager") and is not disabled in your Flutter '
        "project's pubspec.yaml.",
      );
    }
  }

  void _validateXcodeVersion() {
    final Version? xcodeVersion = _xcode?.currentVersion;
    if (xcodeVersion == null || xcodeVersion.major < 15) {
      throwToolExit(
        'Flutter requires Xcode 15 or greater when using Swift Package Manager. Please ensure '
        'Xcode is installed and meets the version requirements.',
      );
    }
  }

  late BuildSwiftPackageUtils utils = BuildSwiftPackageUtils(
    analytics: _analytics,
    artifacts: _artifacts,
    buildSystem: _buildSystem,
    cache: _cache,
    fileSystem: _fileSystem,
    flutterVersion: _flutterVersion,
    logger: logger,
    platform: platform,
    processManager: _processManager,
    project: project,
    targetPlatforms: _targetPlatforms,
    templateRenderer: _templateRenderer,
    xcode: _xcode!,
  );

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String outputArgument =
        stringArg('output') ??
        _fileSystem.path.join(_fileSystem.currentDirectory.path, 'build', 'ios', 'SwiftPackages');

    if (outputArgument.isEmpty) {
      throwToolExit('--output is required.');
    }

    await project.regeneratePlatformSpecificTooling(releaseMode: false);

    final List<BuildInfo> buildInfos = await _getBuildInfos();

    final Directory outputDirectory = _fileSystem.directory(
      _fileSystem.path.absolute(_fileSystem.path.normalize(outputArgument)),
    );
    final Directory pluginRegistrantSwiftPackage = outputDirectory.childDirectory(
      kPluginSwiftPackageName,
    );
    pluginRegistrantSwiftPackage.createSync(recursive: true);

    final Directory cacheDirectory = outputDirectory.childDirectory('.cache');
    cacheDirectory.createSync(recursive: true);

    final pluginRegistrant = _FlutterPluginRegistrantSwiftPackage(
      utils: utils,
      output: pluginRegistrantSwiftPackage,
    );
    final flutterFramework = FlutterFrameworkDependency(utils: utils);
    final appFramework = _AppFrameworkAndNativeAssetsDependencies(utils: utils);
    final cocoapodFrameworks = _CocoaPodPluginDependencies(utils: utils);
    final pluginFrameworks = _FlutterPluginDependencies(utils: utils);

    await _buildXcframeworks(
      buildInfos,
      pluginRegistrant,
      flutterFramework,
      appFramework,
      cocoapodFrameworks,
      cacheDirectory,
    );

    await _generateSwiftPackages(
      buildInfos,
      pluginRegistrant,
      flutterFramework,
      appFramework,
      cocoapodFrameworks,
      pluginFrameworks,
      cacheDirectory,
    );

    _createBuildScripts(outputDirectory);

    return FlutterCommandResult.success();
  }

  /// Copy or build xcframeworks for the Flutter framework, App framework, CocoaPod plugins,
  /// and native assets.
  Future<void> _buildXcframeworks(
    List<BuildInfo> buildInfos,
    _FlutterPluginRegistrantSwiftPackage pluginRegistrant,
    FlutterFrameworkDependency flutterFramework,
    _AppFrameworkAndNativeAssetsDependencies appFramework,
    _CocoaPodPluginDependencies cocoapodFrameworks,
    Directory cacheDirectory,
  ) async {
    for (final buildInfo in buildInfos) {
      final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
      final Directory xcframeworkOutput = pluginRegistrant.output.childDirectory(
        xcodeBuildConfiguration,
      );
      ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
      logger.printStatus('Building for $xcodeBuildConfiguration...');
      await flutterFramework.generateArtifacts(
        buildMode: buildInfo.mode,
        xcframeworkOutput: xcframeworkOutput,
      );
      await appFramework.generateArtifacts(
        buildInfo: buildInfo,
        cacheDirectory: cacheDirectory.childDirectory('FlutterFrameworks'),
        packageConfigPath: packageConfigPath(),
        targetFile: targetFile,
        xcframeworkOutput: xcframeworkOutput,
      );
      await cocoapodFrameworks.generateArtifacts(
        buildInfo: buildInfo,
        buildStatic: boolArg('static'),
        cacheDirectory: cacheDirectory.childDirectory('CocoaPodsFrameworks'),
        xcframeworkOutput: xcframeworkOutput.childDirectory(_kCocoaPods),
      );
    }
  }

  Future<void> _generateSwiftPackages(
    List<BuildInfo> buildInfos,
    _FlutterPluginRegistrantSwiftPackage pluginRegistrant,
    FlutterFrameworkDependency flutterFramework,
    _AppFrameworkAndNativeAssetsDependencies appFramework,
    _CocoaPodPluginDependencies cocoapodFrameworks,
    _FlutterPluginDependencies pluginFrameworks,
    Directory cacheDirectory,
  ) async {
    final Status status = logger.startProgress('Generating swift packages...');
    try {
      final BuildMode defaultBuildMode = buildInfos.first.mode;

      ErrorHandlingFileSystem.deleteIfExists(
        pluginRegistrant.swiftDependencyPackages,
        recursive: true,
      );

      flutterFramework.generateSwiftPackage(pluginRegistrant.swiftDependencyPackages);

      final List<Plugin> plugins = await findPlugins(project);
      plugins.sort((Plugin left, Plugin right) => left.name.compareTo(right.name));

      await pluginRegistrant.generateSourceFiles(
        plugins: plugins,
        buildInfos: buildInfos,
        defaultBuildMode: defaultBuildMode,
      );
      await pluginRegistrant.generateSwiftPackage(
        cocoapods: cocoapodFrameworks,
        flutterFramework: flutterFramework,
        flutterPlugins: pluginFrameworks,
        appFramework: appFramework,
        cacheDirectory: cacheDirectory,
        includeCocoaPodBinaryTargets: boolArg('cocoapods-as-binary-targets'),
        plugins: plugins,
        defaultBuildMode: defaultBuildMode,
      );
      _createFrameworkSymlink(pluginRegistrant.output, defaultBuildMode);
    } finally {
      status.stop();
    }
  }

  /// Create a symlink from the Frameworks directory to the [defaultBuildMode] directory.
  void _createFrameworkSymlink(Directory pluginRegistrantSwiftPackage, BuildMode defaultBuildMode) {
    final Link frameworksLink = pluginRegistrantSwiftPackage.childLink(_kFrameworks);
    if (frameworksLink.existsSync()) {
      frameworksLink.updateSync('./${defaultBuildMode.uppercaseName}');
    } else {
      frameworksLink.createSync('./${defaultBuildMode.uppercaseName}');
    }
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

  /// Create an xcframework from a list of frameworks.
  static Future<void> produceXCFramework({
    required Iterable<Directory> frameworks,
    required String frameworkBinaryName,
    required Directory outputDirectory,
    required ProcessManager processManager,
  }) async {
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

    final ProcessResult xcframeworkResult = await processManager.run(
      xcframeworkCommand,
      includeParentEnvironment: false,
    );

    if (xcframeworkResult.exitCode != 0) {
      throwToolExit(
        'Unable to create $frameworkBinaryName.xcframework: ${xcframeworkResult.stderr}',
      );
    }
  }
}

@visibleForTesting
class FlutterFrameworkDependency {
  FlutterFrameworkDependency({required BuildSwiftPackageUtils utils}) : _utils = utils;

  final BuildSwiftPackageUtils _utils;

  /// Copies the Flutter/FlutterMacOS xcframework to [xcframeworkOutput].
  Future<void> generateArtifacts({
    required BuildMode buildMode,
    required Directory xcframeworkOutput,
  }) async {
    final Status status = _utils.logger.startProgress('   ├─Copying Flutter.xcframework...');
    try {
      for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
        final String frameworkArtifactPath = _utils.artifacts.getArtifactPath(
          platform.xcframeworkArtifact,
          platform: platform.targetPlatform,
          mode: buildMode,
        );
        final ProcessResult result = await _utils.processManager.run(<String>[
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
          throwToolExit(
            'Failed to copy $frameworkArtifactPath (exit ${result.exitCode}:\n'
            '${result.stdout}\n---\n${result.stderr}',
          );
        }
      }
    } finally {
      status.stop();
    }
  }

  /// Creates a FlutterFramework swift package within the [packageDirectory]. This swift package
  /// vends the Flutter xcframework.
  void generateSwiftPackage(Directory packageDirectory) {
    final product = SwiftPackageProduct(
      name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
      targets: <String>[kFlutterGeneratedFrameworkSwiftPackageTargetName],
    );
    final List<SwiftPackageTargetDependency> targetDependencies = [];
    final List<SwiftPackageTarget> binaryTargets = [];
    for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
      targetDependencies.add(
        SwiftPackageTargetDependency.target(
          name: platform.binaryName,
          platformCondition: [platform.swiftPackagePlatform],
        ),
      );
      binaryTargets.add(
        SwiftPackageTarget.binaryTarget(
          name: platform.binaryName,
          relativePath: '../../$_kFrameworks/${platform.binaryName}.xcframework',
        ),
      );
    }
    final flutterFrameworkPackage = SwiftPackage(
      manifest: packageDirectory
          .childDirectory(kFlutterGeneratedFrameworkSwiftPackageTargetName)
          .childFile('Package.swift'),
      name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
      platforms: [],
      products: [product],
      dependencies: [],
      targets: [
        SwiftPackageTarget.defaultTarget(
          name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
          dependencies: targetDependencies,
        ),
        ...binaryTargets,
      ],
      templateRenderer: _utils.templateRenderer,
    );
    flutterFrameworkPackage.createSwiftPackage();
  }

  /// The package dependency for the FlutterFramework.
  ///
  /// ```swift
  ///   dependencies: [
  ///     .package(name: "FlutterFramework", path: "Packages/FlutterFramework"),
  /// ```
  SwiftPackagePackageDependency get packageDependency => SwiftPackagePackageDependency(
    name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
    path: '$_kPackages/$kFlutterGeneratedFrameworkSwiftPackageTargetName',
  );

  /// The target dependency for the FlutterFramework.
  ///
  /// ```swift
  ///  .target(
  ///    name: "FlutterPluginRegistrant",
  ///    dependencies: [
  ///      .product(name: "FlutterFramework", package: "FlutterFramework"),
  /// ```
  SwiftPackageTargetDependency get targetDependency => SwiftPackageTargetDependency.product(
    name: kFlutterGeneratedFrameworkSwiftPackageTargetName,
    packageName: kFlutterGeneratedFrameworkSwiftPackageTargetName,
  );
}

class _AppFrameworkAndNativeAssetsDependencies {
  _AppFrameworkAndNativeAssetsDependencies({required BuildSwiftPackageUtils utils})
    : _utils = utils;

  final BuildSwiftPackageUtils _utils;

  static const String _binaryName = 'App';

  /// Builds an App.framework for every platform and sdk and then combines them into
  /// a single xcframework.
  ///
  /// Intermediate build files are put in the [cacheDirectory]. The final xcframework is copied to
  /// the [xcframeworkOutput].
  Future<void> generateArtifacts({
    required BuildInfo buildInfo,
    required Directory xcframeworkOutput,
    required Directory cacheDirectory,
    required String packageConfigPath,
    required String targetFile,
  }) async {
    const appFrameworkName = '$_binaryName.framework';
    final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
    final frameworks = <Directory>[];
    final Map<String, Set<String>> nativeAssetFrameworks = {};
    Status status = _utils.logger.startProgress('   ├─Building $_binaryName.xcframework...');
    try {
      for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
        for (final XcodeSdk sdk in platform.sdks) {
          final Directory outputBuildDirectory = cacheDirectory
              .childDirectory(xcodeBuildConfiguration)
              .childDirectory(sdk.platformName);
          await _buildFlutterTarget(
            buildInfo: buildInfo,
            outputBuildDirectory: outputBuildDirectory,
            packageConfigPath: packageConfigPath,
            targetFile: targetFile,
            platform: platform,
            sdk: sdk,
          );
          final Directory appFramework = outputBuildDirectory.childDirectory(appFrameworkName);
          _findNativeAssetFrameworks(appFramework, nativeAssetFrameworks);
          frameworks.add(appFramework);
        }
        await BuildSwiftPackages.produceXCFramework(
          frameworks: frameworks,
          frameworkBinaryName: _binaryName,
          outputDirectory: xcframeworkOutput,
          processManager: _utils.processManager,
        );
      }
    } finally {
      status.stop();
    }

    status = _utils.logger.startProgress('   ├─Copying native assets...');
    if (nativeAssetFrameworks.isNotEmpty) {
      try {
        await _createXcframeworksForNativeAssets(
          nativeAssetFrameworks,
          xcframeworkOutput.childDirectory(_kNativeAssets),
        );
      } finally {
        status.stop();
      }
    }
  }

  Future<void> _buildFlutterTarget({
    required BuildInfo buildInfo,
    required Directory outputBuildDirectory,
    required String packageConfigPath,
    required String targetFile,
    required FlutterDarwinPlatform platform,
    required XcodeSdk sdk,
  }) async {
    final environment = Environment(
      projectDir: _utils.fileSystem.currentDirectory,
      packageConfigPath: packageConfigPath,
      outputDir: outputBuildDirectory,
      buildDir: _utils.project.dartTool.childDirectory('flutter_build'),
      cacheDir: _utils.cache.getRoot(),
      flutterRootDir: _utils.fileSystem.directory(Cache.flutterRoot),
      defines: <String, String>{
        kTargetFile: targetFile,
        kTargetPlatform: getNameForTargetPlatform(platform.targetPlatform),
        ...await _platformDefines(platform, sdk),
        ...buildInfo.toBuildSystemEnvironment(),
        kXcodeBuildScript: kXcodeBuildScriptValueNativeBuild,
      },
      artifacts: _utils.artifacts,
      fileSystem: _utils.fileSystem,
      logger: _utils.logger,
      processManager: _utils.processManager,
      platform: _utils.platform,
      analytics: _utils.analytics,
      engineVersion: _utils.artifacts.usesLocalArtifacts
          ? null
          : _utils.flutterVersion.engineRevision,
      generateDartPluginRegistry: true,
    );
    final Target target = _determineTarget(platform, sdk, buildInfo);

    final BuildResult result = await _utils.buildSystem.build(target, environment);
    if (!result.success) {
      for (final ExceptionMeasurement measurement in result.exceptions.values) {
        _utils.logger.printError(measurement.exception.toString());
      }
      throwToolExit('The $_binaryName.xcframework build failed.');
    }
  }

  void _findNativeAssetFrameworks(
    Directory appFramework,
    Map<String, Set<String>> nativeAssetFrameworks,
  ) {
    final File nativeAssetsManifest = appFramework
        .childDirectory('flutter_assets')
        .childFile('NativeAssetsManifest.json');
    if (!nativeAssetsManifest.existsSync()) {
      return;
    }
    final List<build_hooks.KernelAsset>? assets = NativeAssetsJson.decodeFromJson(
      nativeAssetsManifest.readAsStringSync(),
    );
    assets?.forEach((build_hooks.KernelAsset asset) {
      final build_hooks.KernelAssetPath assetPath = asset.path;
      if (assetPath is build_hooks.KernelAssetAbsolutePath) {
        final [String directory, String name] = assetPath.uri.pathSegments;
        nativeAssetFrameworks.putIfAbsent(asset.id, () => <String>{}).add(directory);
      }
    });
  }

  Future<void> _createXcframeworksForNativeAssets(
    Map<String, Set<String>> nativeAssetFrameworks,
    Directory xcframeworkOutput,
  ) async {
    final Directory nativeAssetsDirectory = _utils.fileSystem
        .directory(getBuildDirectory())
        .childDirectory('native_assets/ios/');
    if (!await nativeAssetsDirectory.exists()) {
      return;
    }
    for (final String key in nativeAssetFrameworks.keys) {
      // Parse package name from key
      // package:<package>/<name>
      final String packageName = key.replaceAll('package:', '').split('/').first;
      final List<Directory> frameworks = nativeAssetFrameworks[key]!
          .map((String directoryName) => nativeAssetsDirectory.childDirectory(directoryName))
          .toList();
      await BuildSwiftPackages.produceXCFramework(
        frameworks: frameworks,
        frameworkBinaryName: packageName,
        outputDirectory: xcframeworkOutput,
        processManager: _utils.processManager,
      );
    }
  }

  /// The target dependency for the App framework.
  ///
  /// ```swift
  ///  .target(
  ///    name: "FlutterPluginRegistrant",
  ///    dependencies: [
  ///      .target(name: "App"),
  /// ```
  SwiftPackageTargetDependency get targetDependency =>
      SwiftPackageTargetDependency.target(name: _binaryName);

  /// The binary target for the App framework.
  ///
  /// ```swift
  ///   .binaryTarget(
  ///     name: "App",
  ///     path: "Frameworks/App.xcframework"
  ///   )
  /// ```
  SwiftPackageTarget get binaryTarget => SwiftPackageTarget.binaryTarget(
    name: _binaryName,
    relativePath: '$_kFrameworks/$_binaryName.xcframework',
  );

  /// Determine the target to build based on the [platform], [sdk], and [buildInfo].
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

  /// Platform specific defines.
  Future<Map<String, String>> _platformDefines(FlutterDarwinPlatform platform, XcodeSdk sdk) async {
    switch (platform) {
      case FlutterDarwinPlatform.ios:
        return <String, String>{
          kIosArchs: defaultIOSArchsForEnvironment(
            sdk.sdkType,
            _utils.artifacts,
          ).map((DarwinArch e) => e.name).join(' '),
          kSdkRoot: await _utils.xcode.sdkLocation(sdk.sdkType),
        };
      case FlutterDarwinPlatform.macos:
        return <String, String>{
          kDarwinArchs: defaultMacOSArchsForEnvironment(
            _utils.artifacts,
          ).map((DarwinArch e) => e.name).join(' '),
        };
    }
  }

  (List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) generateDependency({
    required Directory pluginRegistrantSwiftPackage,
    required String defaultBuildConfiguration,
    required FileSystem fileSystem,
  }) {
    return generateDependenciesFromDirectory(
      fileSystem: fileSystem,
      dirName: _kNativeAssets,
      xcframeworkDirectory: pluginRegistrantSwiftPackage
          .childDirectory(defaultBuildConfiguration)
          .childDirectory(_kNativeAssets),
    );
  }
}

class _CocoaPodPluginDependencies {
  _CocoaPodPluginDependencies({required BuildSwiftPackageUtils utils}) : _utils = utils;

  final BuildSwiftPackageUtils _utils;

  /// Builds CocoaPod plugins for every platform and sdk into frameworks and then combines them into
  /// a single xcframework for each.
  ///
  /// Intermediate build files are put in the [cacheDirectory]. The final xcframeworks are copied to
  /// the [xcframeworkOutput].
  Future<void> generateArtifacts({
    required BuildInfo buildInfo,
    required Directory cacheDirectory,
    required Directory xcframeworkOutput,
    required bool buildStatic,
  }) async {
    final Status status = _utils.logger.startProgress('   ├─Building CocoaPods...');
    try {
      final String xcodeBuildConfiguration = buildInfo.mode.uppercaseName;
      final bool dependenciesChanged = _hasDependenciesChanged(
        cacheDirectory.path,
        xcframeworkOutput,
        buildInfo.mode.cliName,
      );
      if (!dependenciesChanged && xcframeworkOutput.existsSync()) {
        _utils.logger.printStatus('Skipping building CocoaPod plugins. No change detected');
        return;
      } else if (dependenciesChanged) {
        ErrorHandlingFileSystem.deleteIfExists(cacheDirectory, recursive: true);
        ErrorHandlingFileSystem.deleteIfExists(xcframeworkOutput, recursive: true);
      }

      final createdFrameworks = <String, List<Directory>>{};

      for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
        final XcodeBasedProject xcodeProject = platform.xcodeProject(_utils.project);
        final Directory podsDirectory = xcodeProject.hostAppRoot.childDirectory('Pods');
        if (!podsDirectory.existsSync() || !xcodeProject.podfile.existsSync()) {
          continue;
        }
        await processPodsIfNeeded(xcodeProject, platform.buildDirectory(), buildInfo.mode);

        for (final XcodeSdk sdk in platform.sdks) {
          final Map<String, List<Directory>> sdkCreatedFrameworks = await _buildCocoaPodsForSdk(
            sdk: sdk,
            platform: platform,
            xcodeBuildConfiguration: xcodeBuildConfiguration,
            buildStatic: buildStatic,
            cacheDirectory: cacheDirectory,
            podsDirectory: podsDirectory,
          );
          sdkCreatedFrameworks.forEach((String name, List<Directory> frameworks) {
            createdFrameworks.putIfAbsent(name, () => <Directory>[]).addAll(frameworks);
          });
        }
      }

      for (final String frameworkName in createdFrameworks.keys) {
        final List<Directory>? frameworkDirectories = createdFrameworks[frameworkName];
        if (frameworkDirectories != null) {
          await BuildSwiftPackages.produceXCFramework(
            frameworks: frameworkDirectories,
            frameworkBinaryName: frameworkName,
            outputDirectory: xcframeworkOutput,
            processManager: _utils.processManager,
          );
        }
      }
      _writeFingerprint(cacheDirectory.path, xcframeworkOutput, buildInfo.mode.cliName);
    } finally {
      status.stop();
    }
  }

  /// The target dependencies and binary targets for the CocoaPod plugin xcframeworks.
  ///
  /// ```swift
  ///  .target(
  ///    name: "FlutterPluginRegistrant",
  ///    dependencies: [
  ///      .target(name: "cocoapod_plugin_a"),
  ///
  ///    ...
  ///
  ///   .binaryTarget(
  ///     name: "cocoapod_plugin_a",
  ///     path: "Frameworks/CocoaPods/cocoapod_plugin_a.xcframework"
  ///   )
  /// ```
  (List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) generateDependency({
    required Directory pluginRegistrantSwiftPackage,
    required String defaultBuildConfiguration,
    required FileSystem fileSystem,
  }) {
    return generateDependenciesFromDirectory(
      fileSystem: fileSystem,
      dirName: _kCocoaPods,
      xcframeworkDirectory: pluginRegistrantSwiftPackage
          .childDirectory(defaultBuildConfiguration)
          .childDirectory(_kCocoaPods),
    );
  }

  /// Builds CocoaPod plugins into frameworks for the given [xcodeBuildConfiguration], [platform],
  /// and [sdk].
  Future<Map<String, List<Directory>>> _buildCocoaPodsForSdk({
    required XcodeSdk sdk,
    required FlutterDarwinPlatform platform,
    required String xcodeBuildConfiguration,
    required bool buildStatic,
    required Directory cacheDirectory,
    required Directory podsDirectory,
  }) async {
    final Directory outputBuildDirectory = cacheDirectory
        .childDirectory(xcodeBuildConfiguration)
        .childDirectory(sdk.platformName);
    final String configuration = _configurationForSdkType(sdk, xcodeBuildConfiguration);
    final pluginsBuildCommand = <String>[
      ..._utils.xcode.xcrunCommand(),
      'xcodebuild',
      '-alltargets',
      '-sdk',
      sdk.platformName,
      '-configuration',
      configuration,
      'SYMROOT=${outputBuildDirectory.path}',
      'ONLY_ACTIVE_ARCH=NO', // No device targeted, so build all valid architectures.
      'BUILD_LIBRARY_FOR_DISTRIBUTION=YES',
      if (buildStatic) 'MACH_O_TYPE=staticlib',
    ];
    final ProcessResult buildPluginsResult = await _utils.processManager.run(
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

    return _findFrameworks(platform, configurationBuildDir);
  }

  /// Iterates through the build files and find .frameworks
  ///
  /// ex.
  /// ```text
  /// > Debug-iphoneos
  ///   > plugin_a
  ///     > plugin_a.framework
  /// ```
  Future<Map<String, List<Directory>>> _findFrameworks(
    FlutterDarwinPlatform platform,
    Directory configurationBuildDir,
  ) async {
    final sdkCreatedFrameworks = <String, List<Directory>>{};

    final Iterable<Directory> products = configurationBuildDir
        .listSync(followLinks: false)
        .whereType<Directory>();
    for (final builtProduct in products) {
      for (final Directory podProduct
          in builtProduct.listSync(followLinks: false).whereType<Directory>()) {
        final String podFrameworkName = podProduct.basename;
        if (_utils.fileSystem.path.extension(podFrameworkName) != '.framework') {
          continue;
        }
        final String binaryName = _utils.fileSystem.path.basenameWithoutExtension(podFrameworkName);
        sdkCreatedFrameworks.putIfAbsent(binaryName, () => <Directory>[]).add(podProduct);
      }
    }
    return sdkCreatedFrameworks;
  }

  bool _hasDependenciesChanged(
    String cacheDirectoryPath,
    Directory cocoapodFrameworkDirectory,
    String xcodeBuildConfiguration,
  ) {
    final Fingerprinter fingerprinter = _cocoapodsFingerprinter(
      cacheDirectoryPath,
      cocoapodFrameworkDirectory,
      xcodeBuildConfiguration,
    );
    return !fingerprinter.doesFingerprintMatch();
  }

  void _writeFingerprint(
    String cacheDirectoryPath,
    Directory cocoapodFrameworkDirectory,
    String xcodeBuildConfiguration,
  ) {
    final Fingerprinter fingerprinter = _cocoapodsFingerprinter(
      cacheDirectoryPath,
      cocoapodFrameworkDirectory,
      xcodeBuildConfiguration,
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
    for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
      final XcodeBasedProject xcodeProject = platform.xcodeProject(_utils.project);
      fingerprintedFiles.add(xcodeProject.xcodeProjectInfoFile.path);
      fingerprintedFiles.add(xcodeProject.podfile.path);
      if (xcodeProject.flutterPluginSwiftPackageManifest.existsSync()) {
        fingerprintedFiles.add(xcodeProject.flutterPluginSwiftPackageManifest.path);
      }
    }

    final fingerprinter = Fingerprinter(
      fingerprintPath: _utils.fileSystem.path.join(
        cacheDirectoryPath,
        'build_${xcodeBuildConfiguration}_pod_inputs.fingerprint',
      ),
      paths: <String>[
        _utils.fileSystem.path.join(
          Cache.flutterRoot!,
          'packages',
          'flutter_tools',
          'bin',
          'podhelper.rb',
        ),
        _utils.fileSystem.path.join(
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
      fileSystem: _utils.fileSystem,
      logger: _utils.logger,
    );
    return fingerprinter;
  }

  String _configurationForSdkType(XcodeSdk sdk, String configuration) {
    if (sdk.sdkType == EnvironmentType.simulator) {
      // Always build debug for simulator.
      return BuildMode.debug.uppercaseName;
    } else {
      return configuration;
    }
  }
}

class _FlutterPluginDependencies {
  _FlutterPluginDependencies({required BuildSwiftPackageUtils utils}) : _utils = utils;

  final BuildSwiftPackageUtils _utils;

  Map<SwiftPackagePlatform, SwiftPackageSupportedPlatform> highestSupportedVersion = {};

  Future<(List<SwiftPackagePackageDependency>, List<SwiftPackageTargetDependency>)>
  generatePluginDependencies({
    required Directory swiftDependencyPackages,
    required List<Plugin> plugins,
    required Directory cacheDirectory,
  }) async {
    final Directory cachedPluginsDirectory = cacheDirectory.childDirectory(_kPlugins);
    try {
      ErrorHandlingFileSystem.deleteIfExists(cachedPluginsDirectory, recursive: true);
    } on FileSystemException catch (e, stackTrace) {
      // Delete may fail due to Xcode writing hidden files to the directory at the same time.
      logger.printTrace('Failed to delete ${cachedPluginsDirectory.path}: $e\n$stackTrace');
    }

    final List<SwiftPackagePackageDependency> packageDependencies = [];
    final List<SwiftPackageTargetDependency> targetDependencies = [];
    for (final plugin in plugins) {
      _validatePluginSupportsPlatformsCorrectly(plugin);
      for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
        // If plugin does not support the platform, skip it.
        if (!plugin.supportSwiftPackageManagerForPlatform(_utils.fileSystem, platform)) {
          continue;
        }

        // If plugin is already added as a package dependency, skip it for this platform.
        if (packageDependencies.any((dependency) => dependency.name == plugin.name)) {
          continue;
        }

        // Copy plugins from pubcache to swift package cache
        // The entire plugin is copied (rather than just the swift package) to maintain any relative
        // links within the plugin.
        final Directory pluginDestination = cachedPluginsDirectory.childDirectory(plugin.name)
          ..createSync(recursive: true);
        copyDirectory(
          _utils.fileSystem.directory(plugin.path),
          pluginDestination,
          shouldCopyDirectory: (Directory dir) => !dir.path.endsWith('example'),
        );

        final String? swiftPackagePath = plugin.pluginSwiftPackagePath(
          _utils.fileSystem,
          platform.name,
          overridePath: pluginDestination.path,
        );
        if (swiftPackagePath == null) {
          throwToolExit('Failed to copy ${plugin.name}.');
        }

        final File swiftPackageManifest = _utils.fileSystem.file(
          _utils.fileSystem.path.join(swiftPackagePath, 'Package.swift'),
        );
        if (!swiftPackageManifest.existsSync()) {
          throwToolExit('Failed to copy ${plugin.name}');
        }

        await _parseSwiftPackage(swiftPackagePath, swiftPackageManifest);

        // ErrorHandlingFileSystem.deleteIfExists(
        //   swiftDependencyPackages.childDirectory(plugin.name),
        //   recursive: true,
        // );

        final Link linkToCache = swiftDependencyPackages.childLink(plugin.name);
        linkToCache.createSync(
          _utils.fileSystem.path.relative(swiftPackagePath, from: linkToCache.parent.path),
          recursive: true,
        );

        packageDependencies.add(
          SwiftPackagePackageDependency(name: plugin.name, path: '$_kPackages/${plugin.name}'),
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

  /// Validates the plugin has a unique name per platform or is a darwin plugin
  void _validatePluginSupportsPlatformsCorrectly(Plugin plugin) {
    var count = 0;
    if (plugin.isDarwinPluginWithSharedSources()) {
      return;
    }
    for (final FlutterDarwinPlatform platform in _utils.targetPlatforms) {
      if (!plugin.supportSwiftPackageManagerForPlatform(_utils.fileSystem, platform)) {
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
      final ProcessResult parsedManifest = await _utils.processManager.run([
        'swift',
        'package',
        'dump-package',
      ], workingDirectory: packagePath);
      final SwiftPackage? pluginSwiftPackage = SwiftPackage.fromJson(
        json.decode(parsedManifest.stdout.toString()) as Map<String, Object?>,
        manifest: swiftPackageManifest,
        templateRenderer: _utils.templateRenderer,
      );
      if (pluginSwiftPackage == null) {
        return;
      }

      // Parse the plugins for the minimum deployment target.
      // The FlutterPluginRegistrant needs to match the highest version. Otherwise, it will error.
      for (final SwiftPackageSupportedPlatform swiftPlatform in pluginSwiftPackage.platforms) {
        final SwiftPackageSupportedPlatform? currentHighest =
            highestSupportedVersion[swiftPlatform.platform];
        if (currentHighest == null || currentHighest.version < swiftPlatform.version) {
          highestSupportedVersion[swiftPlatform.platform] = swiftPlatform;
        }
      }

      // Parse swift package for FlutterFramework dependency and add if not found
      // If it's not found as a package dependency, add it and add it as a dependency for each target
      var hasDependencyOnFlutter = false;
      for (final SwiftPackagePackageDependency dependency in pluginSwiftPackage.dependencies) {
        if (dependency.name == kFlutterGeneratedFrameworkSwiftPackageTargetName) {
          hasDependencyOnFlutter = true;
          break;
        }
      }
      if (!hasDependencyOnFlutter) {
        // Add the Flutter framework as a dependency for each target
        final ProcessResult addDependencyResult = await _utils.processManager.run([
          'swift',
          'package',
          'add-dependency',
          '../$kFlutterGeneratedFrameworkSwiftPackageTargetName',
          '--type',
          'path',
        ], workingDirectory: packagePath);
        if (addDependencyResult.exitCode != 0) {
          _utils.logger.printTrace(
            'Failed to add $kFlutterGeneratedFrameworkSwiftPackageTargetName as a package dependency to $packagePath',
          );
          return;
        }
        for (final SwiftPackageTarget target in pluginSwiftPackage.targets) {
          final ProcessResult addDependencyResult = await _utils.processManager.run([
            'swift',
            'package',
            'add-target-dependency',
            kFlutterGeneratedFrameworkSwiftPackageTargetName,
            target.name,
            '--package',
            kFlutterGeneratedFrameworkSwiftPackageTargetName,
          ], workingDirectory: packagePath);
          if (addDependencyResult.exitCode != 0) {
            _utils.logger.printTrace(
              'Failed to add $kFlutterGeneratedFrameworkSwiftPackageTargetName as a target dependency of ${target.name} to $packagePath',
            );
          }
        }
      }
    } on Exception catch (e, stackTrace) {
      _utils.logger.printTrace('Failed to decode $packagePath: $e\n$stackTrace');
      return;
    }
  }
}

class _FlutterPluginRegistrantSwiftPackage {
  _FlutterPluginRegistrantSwiftPackage({
    required BuildSwiftPackageUtils utils,
    required this.output,
  }) : _utils = utils;

  final BuildSwiftPackageUtils _utils;

  /// The FlutterPluginRegistrant swift package directory
  final Directory output;

  /// A subdirectory in the [output] for other swift package dependencies, such as the
  /// `FlutterFramework` swift package and plugin's swift packages.
  Directory get swiftDependencyPackages => output.childDirectory(_kPackages);

  // Create FlutterPluginRegistrant Swift Package with dependencies on the
  // swift pacakge plugins, CocoaPod xcframeworks, and Flutter/App xcframeworks.
  Future<void> generateSwiftPackage({
    required BuildMode defaultBuildMode,
    required List<Plugin> plugins,
    required Directory cacheDirectory,
    required _CocoaPodPluginDependencies cocoapods,
    required _FlutterPluginDependencies flutterPlugins,
    required FlutterFrameworkDependency flutterFramework,
    required _AppFrameworkAndNativeAssetsDependencies appFramework,
    required bool includeCocoaPodBinaryTargets,
  }) async {
    List<SwiftPackageTargetDependency> cocoapodTargetDependencies = [];
    List<SwiftPackageTarget> cocoapodBinaryTargets = [];
    if (includeCocoaPodBinaryTargets) {
      (cocoapodTargetDependencies, cocoapodBinaryTargets) = cocoapods.generateDependency(
        pluginRegistrantSwiftPackage: output,
        defaultBuildConfiguration: defaultBuildMode.uppercaseName,
        fileSystem: _utils.fileSystem,
      );
    }

    final (
      List<SwiftPackageTargetDependency> nativeAssetsTargetDependencies,
      List<SwiftPackageTarget> nativeAssetsBinaryTargets,
    ) = appFramework.generateDependency(
      pluginRegistrantSwiftPackage: output,
      defaultBuildConfiguration: defaultBuildMode.uppercaseName,
      fileSystem: _utils.fileSystem,
    );
    final (
      List<SwiftPackagePackageDependency> pluginPackageDependencies,
      List<SwiftPackageTargetDependency> pluginTargetDependencies,
    ) = await flutterPlugins.generatePluginDependencies(
      plugins: plugins,
      cacheDirectory: cacheDirectory,
      swiftDependencyPackages: swiftDependencyPackages,
    );

    final List<SwiftPackageTargetDependency> targetDependencies = [
      flutterFramework.targetDependency,
      appFramework.targetDependency,
      ...pluginTargetDependencies,
      ...cocoapodTargetDependencies,
      ...nativeAssetsTargetDependencies,
    ];
    final List<SwiftPackageTarget> binaryTargets = [
      appFramework.binaryTarget,
      ...cocoapodBinaryTargets,
      ...nativeAssetsBinaryTargets,
    ];
    final List<SwiftPackagePackageDependency> packageDependencies = [
      flutterFramework.packageDependency,
      ...pluginPackageDependencies,
    ];

    const String swiftPackageName = kPluginSwiftPackageName;
    final File manifestFile = output.childFile('Package.swift');

    final generatedProduct = SwiftPackageProduct(
      name: swiftPackageName,
      targets: <String>[swiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

    final targets = <SwiftPackageTarget>[
      SwiftPackageTarget.defaultTarget(name: swiftPackageName, dependencies: targetDependencies),
      ...binaryTargets,
    ];

    final pluginsPackage = SwiftPackage(
      manifest: manifestFile,
      name: swiftPackageName,
      platforms: <SwiftPackageSupportedPlatform>[
        highestSupportedVersionForPlatform(FlutterDarwinPlatform.ios, flutterPlugins),
        highestSupportedVersionForPlatform(FlutterDarwinPlatform.macos, flutterPlugins),
      ],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: packageDependencies,
      targets: targets,
      templateRenderer: _utils.templateRenderer,
    );

    pluginsPackage.createSwiftPackage();
  }

  SwiftPackageSupportedPlatform highestSupportedVersionForPlatform(
    FlutterDarwinPlatform platform,
    _FlutterPluginDependencies flutterPlugins,
  ) {
    SwiftPackageSupportedPlatform? supportedPlatform =
        flutterPlugins.highestSupportedVersion[platform.swiftPackagePlatform];
    if (supportedPlatform == null ||
        supportedPlatform.version < platform.supportedPackagePlatform.version) {
      supportedPlatform = platform.supportedPackagePlatform;
    }
    return supportedPlatform;
  }

  Future<void> generateSourceFiles({
    required List<Plugin> plugins,
    required List<BuildInfo> buildInfos,
    required BuildMode defaultBuildMode,
  }) async {
    final Directory sourcesDirectory = output.childDirectory('Sources');
    ErrorHandlingFileSystem.deleteIfExists(sourcesDirectory, recursive: true);

    final File implementationFile = sourcesDirectory
        .childDirectory(kPluginSwiftPackageName)
        .childFile('GeneratedPluginRegistrant.m');
    final File headerFile = sourcesDirectory
        .childDirectory(kPluginSwiftPackageName)
        .childDirectory('include')
        .childFile('GeneratedPluginRegistrant.h');
    final File swiftFile = sourcesDirectory
        .childDirectory(kPluginSwiftPackageName)
        .childFile('GeneratedPluginRegistrant.swift');
    if (_utils.targetPlatforms.singleOrNull == FlutterDarwinPlatform.ios) {
      await writeIOSPluginRegistrant(
        _utils.project,
        plugins,
        pluginRegistrantHeader: headerFile,
        pluginRegistrantImplementation: implementationFile,
      );
    } else if (_utils.targetPlatforms.singleOrNull == FlutterDarwinPlatform.macos) {
      await writeMacOSPluginRegistrant(
        _utils.project,
        plugins,
        pluginRegistrantImplementation: swiftFile,
      );
    } else {
      await writeDarwinPluginRegistrant(
        _utils.project,
        plugins,
        pluginRegistrantHeader: headerFile,
        pluginRegistrantImplementation: implementationFile,
      );
    }
  }
}

@visibleForTesting
class BuildSwiftPackageUtils {
  BuildSwiftPackageUtils({
    required this.analytics,
    required this.artifacts,
    required this.buildSystem,
    required this.cache,
    required this.fileSystem,
    required this.flutterVersion,
    required this.logger,
    required this.platform,
    required this.processManager,
    required this.project,
    required this.targetPlatforms,
    required this.templateRenderer,
    required this.xcode,
  });

  final Analytics analytics;
  final Artifacts artifacts;
  final BuildSystem buildSystem;
  final Cache cache;
  final FileSystem fileSystem;
  final FlutterVersion flutterVersion;
  final Logger logger;
  final Platform platform;
  final ProcessManager processManager;
  final FlutterProject project;
  final List<FlutterDarwinPlatform> targetPlatforms;
  final TemplateRenderer templateRenderer;
  final Xcode xcode;
}

(List<SwiftPackageTargetDependency>, List<SwiftPackageTarget>) generateDependenciesFromDirectory({
  required Directory xcframeworkDirectory,
  required FileSystem fileSystem,
  required String dirName,
}) {
  final targetDependencies = <SwiftPackageTargetDependency>[];
  final binaryTargets = <SwiftPackageTarget>[];
  // They should all have the same directories, so just pick the first.

  // final Directory cocoapodsFrameworksDirectory = pluginRegistrantSwiftPackage
  //     .childDirectory(defaultBuildConfiguration)
  //     .childDirectory(_kNativeAssets);

  if (xcframeworkDirectory.existsSync()) {
    for (final FileSystemEntity entity in xcframeworkDirectory.listSync()) {
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
        targetDependencies.add(
          SwiftPackageTargetDependency.target(
            name: frameworkName,
            platformCondition: platformConditions.toList(),
          ),
        );
        binaryTargets.add(
          SwiftPackageTarget.binaryTarget(
            name: frameworkName,
            relativePath: '$_kFrameworks/$dirName/${entity.basename}',
          ),
        );
      }
    }
  }
  return (targetDependencies, binaryTargets);
}
