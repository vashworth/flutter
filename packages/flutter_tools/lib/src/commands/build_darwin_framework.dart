// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/process.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../cache.dart';
import '../convert.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../macos/swift_package_manager.dart';
import '../macos/swift_packages.dart';
import '../plugins.dart';
import '../project.dart';
import '../version.dart';
import 'build.dart';

abstract class BuildFrameworkCommand extends BuildSubCommand {
  BuildFrameworkCommand({
    // Instantiating FlutterVersion kicks off networking, so delay until it's needed, but allow test injection.
    @visibleForTesting FlutterVersion? flutterVersion,
    required BuildSystem buildSystem,
    required bool verboseHelp,
    Cache? cache,
    Platform? platform,
    required super.logger,
  }) : _injectedFlutterVersion = flutterVersion,
       _buildSystem = buildSystem,
       _injectedCache = cache,
       _injectedPlatform = platform,
       super(verboseHelp: verboseHelp) {
    addTreeShakeIconsFlag();
    usesTargetOption();
    usesPubOption();
    usesDartDefineOption();
    addSplitDebugInfoOption();
    addDartObfuscationOption();
    usesExtraDartFlagOptions(verboseHelp: verboseHelp);
    addNullSafetyModeOptions(hide: !verboseHelp);
    addEnableExperimentation(hide: !verboseHelp);

    argParser
      ..addFlag('debug',
        defaultsTo: true,
        help: 'Whether to produce a framework for the debug build configuration. '
              'By default, all build configurations are built.'
      )
      ..addFlag('profile',
        defaultsTo: true,
        help: 'Whether to produce a framework for the profile build configuration. '
              'By default, all build configurations are built.'
      )
      ..addFlag('release',
        defaultsTo: true,
        help: 'Whether to produce a framework for the release build configuration. '
              'By default, all build configurations are built.'
      )
      ..addFlag('cocoapods',
        help: '(deprecated; use remote-flutter-framework instead) '
              'Produce a Flutter.podspec instead of an engine Flutter.xcframework (recommended if host app uses CocoaPods).',
      )
      ..addFlag('remote-flutter-framework',
        help: 'For CocoaPods, this will produce a Flutter.podspec instead of an '
              'engine Flutter.xcframework (recommended if host app uses CocoaPods). '
              'For Swift Package Manager, this will use a remote binary of the '
              'Flutter.xcframework instead of a local one.',
      )
      ..addFlag('plugins',
        defaultsTo: true,
        help: 'Whether to produce frameworks for the plugins. '
              'This is intended for cases where plugins are already being built separately.',
      )
      ..addFlag('static',
        help: 'Build plugins as static frameworks. Link on, but do not embed these frameworks in the existing Xcode project.',
      )
      ..addOption('output',
        abbr: 'o',
        valueHelp: 'path/to/directory/',
        help: 'Location to write the frameworks.',
      )
      ..addFlag('force',
        abbr: 'f',
        help: 'Force Flutter.podspec creation on the master channel. This is only intended for testing the tool itself.',
        hide: !verboseHelp,
      );
  }

  final BuildSystem? _buildSystem;
  @protected
  BuildSystem get buildSystem => _buildSystem ?? globals.buildSystem;

  @protected
  Cache get cache => _injectedCache ?? globals.cache;
  final Cache? _injectedCache;

  @protected
  Platform get platform => _injectedPlatform ?? globals.platform;
  final Platform? _injectedPlatform;

  // FlutterVersion.instance kicks off git processing which can sometimes fail, so don't try it until needed.
  @protected
  FlutterVersion get flutterVersion => _injectedFlutterVersion ?? globals.flutterVersion;
  final FlutterVersion? _injectedFlutterVersion;

  @override
  bool get reportNullSafety => false;

  bool get remoteFlutterFramework {
    return boolArg('cocoapods') || boolArg('remote-flutter-framework');
  }

  @protected
  late final FlutterProject project = FlutterProject.current();

  Future<List<BuildInfo>> getBuildInfos() async {
    final List<BuildInfo> buildInfos = <BuildInfo>[];

    if (boolArg('debug')) {
      buildInfos.add(await getBuildInfo(forcedBuildMode: BuildMode.debug));
    }
    if (boolArg('profile')) {
      buildInfos.add(await getBuildInfo(forcedBuildMode: BuildMode.profile));
    }
    if (boolArg('release')) {
      buildInfos.add(await getBuildInfo(forcedBuildMode: BuildMode.release));
    }

    return buildInfos;
  }

  @override
  bool get supported => platform.isMacOS;

  @override
  Future<void> validateCommand() async {
    await super.validateCommand();
    if (!supported) {
      throwToolExit('Building frameworks for iOS is only supported on the Mac.');
    }

    if ((await getBuildInfos()).isEmpty) {
      throwToolExit('At least one of "--debug" or "--profile", or "--release" is required.');
    }

    if (!boolArg('plugins') && boolArg('static')) {
      throwToolExit('--static cannot be used with the --no-plugins flag');
    }
  }

  static Future<void> produceXCFramework(
    Iterable<Directory> frameworks,
    String frameworkBinaryName,
    Directory outputDirectory,
    ProcessManager processManager,
  ) async {
    final List<String> xcframeworkCommand = <String>[
      'xcrun',
      'xcodebuild',
      '-create-xcframework',
      for (final Directory framework in frameworks) ...<String>[
        '-framework',
        framework.path,
        ...framework.parent
            .listSync()
            .where((FileSystemEntity entity) =>
        entity.basename.endsWith('dSYM'))
            .map((FileSystemEntity entity) => <String>['-debug-symbols', entity.path])
            .expand<String>((List<String> parameter) => parameter),
      ],
      '-output',
      outputDirectory.childDirectory('$frameworkBinaryName.xcframework').path,
    ];

    final ProcessResult xcframeworkResult = await processManager.run(
      xcframeworkCommand,
    );

    if (xcframeworkResult.exitCode != 0) {
      throwToolExit('Unable to create $frameworkBinaryName.xcframework: ${xcframeworkResult.stderr}');
    }
  }

  /// Create a FlutterPluginRegistrant, FlutterFrameworks, and CocoaPodFrameworks
  /// Swift Package.
  ///
  /// FlutterFrameworks will vend the Flutter.xcframework and App.xcframework.
  ///
  /// CocoaPodFrameworks will vend any xcframeworks created by CocoaPods.
  ///
  /// FlutterPluginRegistrant will vend the GeneratedPluginRegistrant. It will
  /// have dependencies on the FlutterFrameworks, CocoaPodFrameworks, and
  /// plugin's compatible with Swift Package Manager.
  Future<void> produceSwiftPackages({
    required FlutterProject project,
    required Directory modeDirectory,
    required Directory flutterFrameworksDir,
    required Directory cocoaPodFrameworksDir,
    required bool useRemoteFlutterFramework,
    required SupportedPlatform platform,
    required String modeName,
    required BuildMode mode,
    required FileSystem fileSystem,
  }) async {
    if (!project.usesSwiftPackageManager) {
      return;
    }
    final Status status = globals.logger.startProgress(
      ' ├─Building Swift Packages...',
    );
    try {
      // Create FlutterFrameworks Swift Package with libraries for Flutter.xcframework and App.xcframework
      SwiftPackageTarget? remoteFlutterFramework;
      if (useRemoteFlutterFramework) {
        remoteFlutterFramework = await remoteFlutterFrameworkTarget(
          mode,
          status,
        );
      }
      final SwiftPackage? flutterFrameworksPackage = _generateFrameworksSwiftPackage(
        frameworksDir: flutterFrameworksDir,
        packageName: 'FlutterFrameworks',
        additionalFrameworks: remoteFlutterFramework != null
            ? <SwiftPackageTarget>[remoteFlutterFramework]
            : <SwiftPackageTarget>[],
        fileSystem: fileSystem,
      );
      if (flutterFrameworksPackage == null) {
        throwToolExit('Failed to get flutter frameworks');
      }

      // Create CocoaPodFrameworks Swift Package with libraries for all xcframeworks produced by CocoaPods.
      final SwiftPackage? cocoaPodFrameworksPackage = _generateFrameworksSwiftPackage(
        frameworksDir: cocoaPodFrameworksDir,
        packageName: 'CocoaPodFrameworks',
        fileSystem: fileSystem,
      );

      final List<Plugin> plugins = await findPlugins(project);
      // Sort the plugins by name to keep ordering stable in generated files.
      plugins.sort((Plugin left, Plugin right) => left.name.compareTo(right.name));

      // Copy Swift Package plugins and inject Flutter framework dependency
      final Directory copiedPluginsDirectory = modeDirectory.childDirectory('Plugins');
      final List<Plugin> copiedPlugins = await _copySwiftPackagePlugins(
        destination: copiedPluginsDirectory,
        flutterFrameworksPackage: flutterFrameworksPackage,
        platform: platform,
        plugins: plugins,
        fileSystem: fileSystem,
      );

      // The rest of this only needs to happen once, not for each mode.
      await _produceFlutterPluginRegistrant(
        modeDirectory: modeDirectory,
        platform: platform,
        mode: modeName,
        plugins: copiedPlugins,
        flutterFrameworksPackage: flutterFrameworksPackage,
        cocoaPodFrameworksPackage: cocoaPodFrameworksPackage,
        fileSystem: fileSystem,
      );
    } finally {
      status.stop();
    }
  }

  /// Find all xcframeworks in the [frameworksDir] and create a Swift Package
  /// named [packageName] that produces a library for each.
  SwiftPackage? _generateFrameworksSwiftPackage({
    required Directory frameworksDir,
    required String packageName,
    List<SwiftPackageTarget> additionalFrameworks = const <SwiftPackageTarget>[],
    required FileSystem fileSystem,
  }) {
    if (!frameworksDir.existsSync()) {
      return null;
    }

    final List<SwiftPackageProduct> products = <SwiftPackageProduct>[];
    final List<SwiftPackageTarget> targets = <SwiftPackageTarget>[];

    for (final FileSystemEntity file in frameworksDir.listSync()) {
      if (file.basename.endsWith('xcframework')) {
        final String frameworkName = fileSystem.path.basenameWithoutExtension(file.path);
        products.add(SwiftPackageProduct(
          name: frameworkName,
          targets: <String>[frameworkName],
        ));
        targets.add(SwiftPackageTarget.binaryTarget(
          name: frameworkName,
          relativePath: file.basename,
        ));
      }
    }
    targets.addAll(additionalFrameworks);
    for (final SwiftPackageTarget framework in additionalFrameworks) {
      products.add(SwiftPackageProduct(
        name: framework.name,
        targets: <String>[framework.name],
      ));
    }

    if (products.isEmpty) {
      return null;
    }

    final SwiftPackage frameworksPackage = SwiftPackage(
      manifest: frameworksDir.childFile('Package.swift'),
      name: packageName,
      platforms: <SwiftPackageSupportedPlatform>[
        SwiftPackageManager.iosSwiftPackageSupportedPlatform,
        SwiftPackageManager.macosSwiftPackageSupportedPlatform,
      ],
      products: products,
      dependencies: <SwiftPackagePackageDependency>[],
      targets: targets,
      templateRenderer: globals.templateRenderer,
    );
    frameworksPackage.createSwiftPackage();
    return frameworksPackage;
  }

  /// Copy plugins with a Package.swift for the given [platform] to [destination].
  /// Also, alter the Package.swift to inject a dependency on the Flutter framework.
  Future<List<Plugin>> _copySwiftPackagePlugins({
    required List<Plugin> plugins,
    required Directory destination,
    required SupportedPlatform platform,
    required SwiftPackage flutterFrameworksPackage,
    required FileSystem fileSystem,
  }) async {
    final List<Plugin> copiedPlugins = <Plugin>[];
    final List<Future<void>> alterPlugins = <Future<void>>[];

    for (final Plugin plugin in plugins) {
      final String? pluginSwiftPackageManifestPath = plugin.pluginSwiftPackageManifestPath(
        fileSystem,
        platform.name,
      );
      if (plugin.platforms[platform.name] == null ||
          pluginSwiftPackageManifestPath == null ||
          !fileSystem.file(pluginSwiftPackageManifestPath).existsSync()) {
        continue;
      }
      final Directory pluginSource = fileSystem.directory(plugin.path);
      final Directory pluginDestination = destination.childDirectory(plugin.name)
          ..createSync(recursive: true);

      copyDirectory(
        pluginSource,
        pluginDestination,
        shouldCopyDirectory: (Directory dir) => !dir.path.endsWith('example'),
      );
      final Plugin copiedPlugin = Plugin(
        name: plugin.name,
        path: pluginDestination.path,
        platforms: plugin.platforms,
        defaultPackagePlatforms: plugin.defaultPackagePlatforms,
        pluginDartClassPlatforms: plugin.pluginDartClassPlatforms,
        dependencies: plugin.dependencies,
        isDirectDependency: plugin.isDirectDependency,
      );
      copiedPlugins.add(copiedPlugin);
      alterPlugins.add(
        _addFlutterFrameworkDependency(
          copiedPlugin: copiedPlugin,
          flutterFrameworksPackage: flutterFrameworksPackage,
          platform: platform,
          fileSystem: fileSystem,
        ),
      );
    }

    await Future.wait(alterPlugins);

    return copiedPlugins;
  }

  /// Add the Flutter framework as a dependency at the bottom of the plugin's
  /// Package.swift. Also, update the SupportedPlatform if the plugin's
  /// versions are lower than that of the Flutter framework.
  Future<void> _addFlutterFrameworkDependency({
    required Plugin copiedPlugin,
    required SwiftPackage flutterFrameworksPackage,
    required SupportedPlatform platform,
    required FileSystem fileSystem,
  }) async {
    final String? copiedManifestPath = copiedPlugin.pluginSwiftPackageManifestPath(
      fileSystem,
      platform.name,
    );
    final File copiedManifestFile = fileSystem.file(copiedManifestPath);
    if (copiedManifestPath == null || !copiedManifestFile.existsSync()) {
      throwToolExit('Failed to find Package.swift for ${copiedPlugin.name}');
    }

    final String relativePathToFlutterFrameworkPackage = fileSystem.path.relative(
      flutterFrameworksPackage.manifest.parent.path,
      from: copiedManifestFile.parent.path,
    );

    // Inject Flutter framework as a dependency
    String manifestContents = copiedManifestFile.readAsStringSync();
    manifestContents = '''
$manifestContents

package.dependencies += [
    .package(path: "$relativePathToFlutterFrameworkPackage")
]
let result = package.targets.filter({ \$0.name == "${copiedPlugin.name}" })
if let target = result.first {
    target.dependencies.append(
        .product(name: "Flutter", package: "${flutterFrameworksPackage.name}")
    )
}
''';

    // Parse package's SupportedPlatforms.
    // Swift Package Manager emits an error if a dependency isn’t compatible
    // with the top-level package’s deployment version. The deployment target of
    // a package’s dependencies must be lower than or equal to the top-level
    // package’s deployment target version for a particular platform.
    //
    // Since plugins have a dependency on the Flutter framework, the deployment
    // target must always be higher or equal to that of the Flutter framework.
    final RunResult results = await globals.processUtils.run(
      <String>['swift', 'package', 'dump-package'],
      workingDirectory: copiedManifestFile.parent.path,
    );
    if (results.exitCode != 0) {
      throwToolExit('Failed convert swift package to json: ${results.stderr}');
    }

    bool foundPlatforms = false;
    SwiftPackageSupportedPlatform? currentSupportedIOS;
    SwiftPackageSupportedPlatform? currentSupportedMacOS;
    try {
      final Object decodeResult = json.decode(results.stdout) as Object;
      if (decodeResult is! Map<String, Object?>) {
        throw Exception(
          '${copiedManifestFile.path} returned unexpected JSON response: $results',
        );
      }
      if (decodeResult['platforms'] != null && decodeResult['platforms'] is List<Object?>) {
        final List<Object?> jsonPlatforms = decodeResult['platforms']! as List<Object?>;
        for (final Object? jsonPlatform in jsonPlatforms) {
          foundPlatforms = true;
          if (jsonPlatform != null && jsonPlatform is Map<String, Object?>) {
            final SwiftPackageSupportedPlatform? platform = SwiftPackageSupportedPlatform.fromJson(
              jsonPlatform,
            );
            if (platform != null) {
              if (platform.platform == SwiftPackagePlatform.ios) {
                currentSupportedIOS = platform;
              } else if (platform.platform == SwiftPackagePlatform.macos) {
                currentSupportedMacOS = platform;
              }
            }
          }
        }
      }
    } on FormatException {
      throw Exception('${copiedManifestFile.path} returned non-JSON response: $results');
    }

    final SwiftPackageSupportedPlatform iosMinDeployment = SwiftPackageManager.iosSwiftPackageSupportedPlatform;
    final SwiftPackageSupportedPlatform macosMinDeployment = SwiftPackageManager.macosSwiftPackageSupportedPlatform;
    if (!foundPlatforms) {
      manifestContents = '''
$manifestContents
package.platforms = [
    ${iosMinDeployment.format()},
    ${macosMinDeployment.format()}
];
''';
    } else {
      final List<String> replacementFilters = <String>[];
      final List<String> appendedPlatform = <String>[];
      if (currentSupportedIOS == null || currentSupportedIOS.version < iosMinDeployment.version) {
        appendedPlatform.add('    package.platforms?.append(${iosMinDeployment.format()})');
        replacementFilters.add(r'!String(describing: $0).contains("ios")');
      }
      if (currentSupportedMacOS == null || currentSupportedMacOS.version < macosMinDeployment.version) {
        appendedPlatform.add('    package.platforms?.append(${macosMinDeployment.format()})');
        replacementFilters.add(r'!String(describing: $0).contains("macos")');
      }
      if (replacementFilters.isNotEmpty || appendedPlatform.isNotEmpty) {
        String replacementFilter = '';
        if (replacementFilters.isNotEmpty) {
          replacementFilter = '    package.platforms = package.platforms?.filter({ ${replacementFilters.join(' && ')} })';
        }

        manifestContents = '''
$manifestContents
if package.platforms != nil {
$replacementFilter
${appendedPlatform.join('\n')}
}
''';
      }
    }

    copiedManifestFile.writeAsStringSync(manifestContents);
  }

  // Create FlutterPluginRegistrant Swift Package with dependencies on the
  // Swift Package plugins, CocoaPods xcframeworks, and Flutter/App xcframeworks.
  Future<void> _produceFlutterPluginRegistrant({
    required Directory modeDirectory,
    required SupportedPlatform platform,
    required String mode,
    required List<Plugin> plugins,
    required SwiftPackage flutterFrameworksPackage,
    SwiftPackage? cocoaPodFrameworksPackage,
    required FileSystem fileSystem,
  }) async {
    // TODO(vashworth): Different name per iOS/macOS so can use both when having a project that supports both?
    // TODO(vashworth): conflict between darwin plugins when using both?
    const String swiftPackageName = 'FlutterPluginRegistrant';
    final Directory swiftPackageDirectory = modeDirectory.parent.childDirectory(swiftPackageName);
    final File manifestFile = swiftPackageDirectory.childFile('Package.swift');
    // Only needs to be produced once (not for each mode), so skip if already created.
    if (manifestFile.existsSync()) {
      return;
    }

    // Create FlutterPluginRegistrant source files
    await produceRegistrantSourceFiles(
      plugins: plugins,
      swiftPackageDirectory: swiftPackageDirectory,
      swiftPackageName: swiftPackageName,
    );

    // Create FlutterPluginRegistrant Swift Package
    final (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies
    ) = SwiftPackageManager.dependenciesForPlugins(
      plugins: plugins,
      platform: platform,
      fileSystem: fileSystem,
      alterPath: (String path) => fileSystem.path
          .relative(path, from: manifestFile.parent.path)
          .replaceFirst('/$mode/', r'/\(selectedBuildMode)/'),
    );

    packageDependencies.add(SwiftPackagePackageDependency(
      name: flutterFrameworksPackage.name,
      path: fileSystem.path
          .relative(
            flutterFrameworksPackage.manifest.parent.path,
            from: swiftPackageDirectory.path,
          )
          .replaceFirst('/$mode/', r'/\(selectedBuildMode)/'),
    ));
    for (final SwiftPackageProduct product in flutterFrameworksPackage.products) {
      targetDependencies.add(SwiftPackageTargetDependency.product(
        name: product.name,
        packageName: flutterFrameworksPackage.name,
      ));
    }

    if (cocoaPodFrameworksPackage != null) {
      packageDependencies.add(SwiftPackagePackageDependency(
        name: cocoaPodFrameworksPackage.name,
        path: fileSystem.path
            .relative(
              cocoaPodFrameworksPackage.manifest.parent.path,
              from: swiftPackageDirectory.path,
            )
            .replaceFirst('/$mode/', r'/\(selectedBuildMode)/'),
      ));
      for (final SwiftPackageProduct product in cocoaPodFrameworksPackage.products) {
        targetDependencies.add(SwiftPackageTargetDependency.product(
          name: product.name,
          packageName: cocoaPodFrameworksPackage.name,
        ));
      }
    }

    final SwiftPackageProduct generatedProduct = SwiftPackageProduct(
      name: swiftPackageName,
      targets: <String>[swiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

    final SwiftPackageTarget generatedTarget = SwiftPackageTarget.defaultTarget(
      name: swiftPackageName,
      dependencies: targetDependencies,
    );

    final SwiftPackage pluginsPackage = SwiftPackage(
      manifest: manifestFile,
      name: swiftPackageName,
      platforms: <SwiftPackageSupportedPlatform>[
        SwiftPackageManager.iosSwiftPackageSupportedPlatform,
        SwiftPackageManager.macosSwiftPackageSupportedPlatform,
      ],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: packageDependencies,
      targets: <SwiftPackageTarget>[generatedTarget],
      templateRenderer: globals.templateRenderer,
      buildMode: mode,
    );
    pluginsPackage.createSwiftPackage();
  }

  @visibleForOverriding
  Future<SwiftPackageTarget> remoteFlutterFrameworkTarget(
    BuildMode mode,
    Status status,
  ) async {
    throw UnimplementedError();
  }

  @visibleForOverriding
  Future<void> produceRegistrantSourceFiles({
    required String swiftPackageName,
    required Directory swiftPackageDirectory,
    required List<Plugin> plugins,
  }) async {
    throw UnimplementedError();
  }
}
