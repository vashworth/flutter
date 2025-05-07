// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../artifacts.dart';
import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/template.dart';
import '../base/utils.dart';
import '../base/version.dart';
import '../build_info.dart';
import '../cache.dart';
import '../plugins.dart';
import '../project.dart';
import 'swift_packages.dart';

/// Swift Package Manager is a dependency management solution for iOS and macOS
/// applications.
///
/// See also:
///   * https://www.swift.org/documentation/package-manager/ - documentation on
///     Swift Package Manager.
///   * https://developer.apple.com/documentation/packagedescription/package -
///     documentation on Swift Package Manager manifest file, Package.swift.
class SwiftPackageManager {
  const SwiftPackageManager({
    required Artifacts artifacts,
    required Cache cache,
    required FileSystem fileSystem,
    required TemplateRenderer templateRenderer,
  }) : _artifacts = artifacts,
       _cache = cache,
       _fileSystem = fileSystem,
       _templateRenderer = templateRenderer;

  final Artifacts _artifacts;
  final Cache _cache;
  final FileSystem _fileSystem;
  final TemplateRenderer _templateRenderer;

  static const String _defaultFlutterPluginsSwiftPackageName = 'FlutterGeneratedPluginSwiftPackage';

  static final SwiftPackageSupportedPlatform iosSwiftPackageSupportedPlatform =
      SwiftPackageSupportedPlatform(
        platform: SwiftPackagePlatform.ios,
        version: Version(13, 0, null),
      );

  static final SwiftPackageSupportedPlatform macosSwiftPackageSupportedPlatform =
      SwiftPackageSupportedPlatform(
        platform: SwiftPackagePlatform.macos,
        version: Version(10, 15, null),
      );

  /// Creates a Swift Package that vends the (symlinked) Flutter framework.
  Future<void> generateFlutterFrameworkSwiftPackage(
    SupportedPlatform platform,
    XcodeBasedProject project, {
    BuildMode buildMode = BuildMode.release,
    File? overrideManifestPath,
    bool remoteFramework = false,
  }) async {
    _validatePlatform(platform);

    final String engineVersion = _cache.engineRevision;
    final String buildModeName = sentenceCase(buildMode.cliName);

    // FlutterGeneratedPluginSwiftPackage must be statically linked to ensure
    // any dynamic dependencies are linked to Runner and prevent undefined symbols.
    final SwiftPackageProduct generatedProduct = SwiftPackageProduct(
      name: 'Flutter',
      targets: <String>['FlutterFramework'],
    );

    // if (remoteFramework) {
    //   final SwiftPackageTarget remoteFrameworkTarget = await remoteFlutterFrameworkTarget(
    //     buildMode,
    //   );
    //   final SwiftPackage flutterFrameworkPackage = SwiftPackage(
    //     manifest: overrideManifestPath ?? project.flutterFrameworkSwiftPackageManifest,
    //     name: 'Flutter',
    //     platforms: <SwiftPackageSupportedPlatform>[],
    //     products: <SwiftPackageProduct>[generatedProduct],
    //     dependencies: <SwiftPackagePackageDependency>[],
    //     targets: <SwiftPackageTarget>[
    //       SwiftPackageTarget.defaultTarget(
    //         name: 'FlutterFramework',
    //         dependencies: <SwiftPackageTargetDependency>[SwiftPackageTargetDependency.target(name: 'Flutter')],
    //       ),
    //       remoteFrameworkTarget,
    //     ],
    //     templateRenderer: _templateRenderer,
    //   );
    //   flutterFrameworkPackage.createSwiftPackage();
    //   return;
    // }

    final String frameworkName;
    final List<SwiftPackagePlatform> platformCondition;
    final String frameworkArtifactPath;

    if (platform == SupportedPlatform.ios) {
      frameworkName = 'Flutter';
      platformCondition = <SwiftPackagePlatform>[SwiftPackagePlatform.ios];
      frameworkArtifactPath = _artifacts.getArtifactPath(
        Artifact.flutterXcframework,
        platform: TargetPlatform.ios,
        mode: BuildMode.release,
      );
    } else {
      frameworkName = 'FlutterMacOS';
      platformCondition = <SwiftPackagePlatform>[SwiftPackagePlatform.macos];
      frameworkArtifactPath = _artifacts.getArtifactPath(
        Artifact.flutterMacOSXcframework,
        platform: TargetPlatform.darwin,
        mode: BuildMode.release,
      );
    }

    final String xcframeworkName = '$frameworkName.xcframework';

    final SwiftPackage flutterFrameworkPackage = SwiftPackage(
      manifest: overrideManifestPath ?? project.flutterFrameworkSwiftPackageManifest,
      name: 'Flutter',
      swiftCodeBeforePackageDefinition: '''
let mode = "$buildModeName"
let engine = "$engineVersion"
''',
      platforms: <SwiftPackageSupportedPlatform>[],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: <SwiftPackagePackageDependency>[],
      targets: <SwiftPackageTarget>[
        SwiftPackageTarget.defaultTarget(
          name: 'FlutterFramework',
          dependencies: <SwiftPackageTargetDependency>[
            SwiftPackageTargetDependency.target(
              name: frameworkName,
              platformCondition: platformCondition,
            ),
          ],
        ),
        SwiftPackageTarget.binaryTarget(
          name: frameworkName,
          relativePath: '\\(mode)/\\(engine)/$xcframeworkName',
        ),
      ],
      templateRenderer: _templateRenderer,
    );
    flutterFrameworkPackage.createSwiftPackage();

    ErrorHandlingFileSystem.deleteIfExists(
      project.flutterFrameworkSwiftPackageDirectory.childDirectory(buildModeName),
      recursive: true,
    );
    final Link frameworkLink = _fileSystem.link(
      project.flutterFrameworkSwiftPackageDirectory
          .childDirectory(buildModeName)
          .childDirectory(engineVersion)
          .childDirectory(xcframeworkName)
          .path,
    );
    frameworkLink.createSync(frameworkArtifactPath, recursive: true);
  }

  // Future<SwiftPackageTarget> remoteFlutterFrameworkTarget(BuildMode mode) async {
  //   final Status status = globals.logger.startProgress(
  //     'Downloading Flutter framework to calculate checksum...',
  //   );
  //   // TODO(vashworth): Limit to stable/beta branch
  //   final String artifactsMode = mode == BuildMode.debug ? 'ios' : 'ios-${mode.cliName}';
  //   final String frameworkArtifactUrl =
  //       '${cache.storageBaseUrl}/flutter_infra_release/flutter/${cache.engineRevision}/$artifactsMode/artifacts.zip';
  //   final Directory destination = globals.fs.systemTempDirectory.createTempSync(
  //     'flutter_framework.',
  //   );
  //   await cache.downloadArtifact(
  //     Uri.parse(frameworkArtifactUrl),
  //     destination.childFile('artifacts.zip'),
  //     status,
  //   );
  //   status.stop();

  //   final RunResult results = await globals.processUtils.run(<String>[
  //     'swift',
  //     'package',
  //     'compute-checksum',
  //     destination.childFile('artifacts.zip').path,
  //   ]);
  //   if (results.exitCode != 0) {
  //     throwToolExit('Failed to get checksum for Flutter framework: ${results.stderr}');
  //   }

  //   return SwiftPackageTarget.remoteBinaryTarget(
  //     name: 'Flutter',
  //     zipUrl: frameworkArtifactUrl,
  //     zipChecksum: results.stdout.trim(),
  //   );
  // }

  /// Creates a Swift Package called 'FlutterGeneratedPluginSwiftPackage' that
  /// has dependencies on Flutter plugins that are compatible with Swift
  /// Package Manager.
  Future<void> generatePluginsSwiftPackage(
    List<Plugin> plugins,
    SupportedPlatform platform,
    XcodeBasedProject project,
  ) async {
    _validatePlatform(platform);

    final Directory symlinksDir = project.flutterSwiftPackageDirectory.childDirectory('.symlinks');
    ErrorHandlingFileSystem.deleteIfExists(symlinksDir, recursive: true);
    symlinksDir.createSync(recursive: true);

    final (
      List<SwiftPackagePackageDependency> packageDependencies,
      List<SwiftPackageTargetDependency> targetDependencies,
    ) = dependenciesForPlugins(
      plugins: plugins,
      platform: platform,
      fileSystem: _fileSystem,
      symlinkDirectory: symlinksDir,
      alterPath:
          (String path) => _fileSystem.path.relative(
            path,
            from: project.flutterPluginSwiftPackageManifest.parent.path,
          ),
    );

    // If there aren't any Swift Package plugins and the project hasn't been
    // migrated yet, don't generate a Swift package or migrate the app since
    // it's not needed. If the project has already been migrated, regenerate
    // the Package.swift even if there are no dependencies in case there
    // were dependencies previously.
    if (packageDependencies.isEmpty && !project.flutterPluginSwiftPackageInProjectSettings) {
      return;
    }

    final SwiftPackageSupportedPlatform swiftSupportedPlatform;
    if (platform == SupportedPlatform.ios) {
      swiftSupportedPlatform = iosSwiftPackageSupportedPlatform;
    } else {
      swiftSupportedPlatform = macosSwiftPackageSupportedPlatform;
    }

    // FlutterGeneratedPluginSwiftPackage must be statically linked to ensure
    // any dynamic dependencies are linked to Runner and prevent undefined symbols.
    final SwiftPackageProduct generatedProduct = SwiftPackageProduct(
      name: _defaultFlutterPluginsSwiftPackageName,
      targets: <String>[_defaultFlutterPluginsSwiftPackageName],
      libraryType: SwiftPackageLibraryType.static,
    );

    final SwiftPackageTarget generatedTarget = SwiftPackageTarget.defaultTarget(
      name: _defaultFlutterPluginsSwiftPackageName,
      dependencies: targetDependencies,
    );

    final SwiftPackage pluginsPackage = SwiftPackage(
      manifest: project.flutterPluginSwiftPackageManifest,
      name: _defaultFlutterPluginsSwiftPackageName,
      platforms: <SwiftPackageSupportedPlatform>[swiftSupportedPlatform],
      products: <SwiftPackageProduct>[generatedProduct],
      dependencies: packageDependencies,
      targets: <SwiftPackageTarget>[generatedTarget],
      templateRenderer: _templateRenderer,
    );
    pluginsPackage.createSwiftPackage();
  }

  /// Generate a list of [SwiftPackagePackageDependency] and [SwiftPackageTargetDependency]
  /// from a list of [plugins] for the given [platform].
  ///
  /// If [alterPath] is provided, alter the [SwiftPackagePackageDependency]'s
  /// path using the provided function.
  static (List<SwiftPackagePackageDependency>, List<SwiftPackageTargetDependency>)
  dependenciesForPlugins({
    required List<Plugin> plugins,
    required SupportedPlatform platform,
    required FileSystem fileSystem,
    String Function(String)? alterPath,
    Directory? symlinkDirectory,
  }) {
    final List<SwiftPackagePackageDependency> packageDependencies =
        <SwiftPackagePackageDependency>[];
    final List<SwiftPackageTargetDependency> targetDependencies = <SwiftPackageTargetDependency>[];

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

      String packagePath = fileSystem.file(pluginSwiftPackageManifestPath).parent.path;
      if (symlinkDirectory != null) {
        final Link pluginSymlink = symlinkDirectory.childLink(plugin.name);
        pluginSymlink.createSync(packagePath);
        packagePath = pluginSymlink.path;
      }
      if (alterPath != null) {
        packagePath = alterPath(packagePath);
      }

      packageDependencies.add(
        SwiftPackagePackageDependency.local(packageName: plugin.name, localPath: packagePath),
      );

      // The target dependency product name is hyphen separated because it's
      // the dependency's library name, which Swift Package Manager will
      // automatically use as the CFBundleIdentifier if linked dynamically. The
      // CFBundleIdentifier cannot contain underscores.
      targetDependencies.add(
        SwiftPackageTargetDependency.product(
          name: plugin.name.replaceAll('_', '-'),
          packageName: plugin.name,
        ),
      );
    }
    return (packageDependencies, targetDependencies);
  }

  /// Validates the platform is either iOS or macOS, otherwise throw an error.
  static void _validatePlatform(SupportedPlatform platform) {
    if (platform != SupportedPlatform.ios && platform != SupportedPlatform.macos) {
      throwToolExit(
        'The platform ${platform.name} is not compatible with Swift Package Manager. '
        'Only iOS and macOS are allowed.',
      );
    }
  }

  /// If the project's IPHONEOS_DEPLOYMENT_TARGET/MACOSX_DEPLOYMENT_TARGET is
  /// higher than the FlutterGeneratedPluginSwiftPackage's default
  /// SupportedPlatform, increase the SupportedPlatform to match the project's
  /// deployment target.
  ///
  /// This is done for the use case of a plugin requiring a higher iOS/macOS
  /// version than FlutterGeneratedPluginSwiftPackage.
  ///
  /// Swift Package Manager emits an error if a dependency isn’t compatible
  /// with the top-level package’s deployment version. The deployment target of
  /// a package’s dependencies must be lower than or equal to the top-level
  /// package’s deployment target version for a particular platform.
  ///
  /// To still be able to use the plugin, the user can increase the Xcode
  /// project's iOS/macOS deployment target and this will then increase the
  /// deployment target for FlutterGeneratedPluginSwiftPackage.
  static void updateMinimumDeployment({
    required XcodeBasedProject project,
    required SupportedPlatform platform,
    required String deploymentTarget,
  }) {
    final Version? projectDeploymentTargetVersion = Version.parse(deploymentTarget);
    final SwiftPackageSupportedPlatform defaultPlatform;
    final SwiftPackagePlatform packagePlatform;
    if (platform == SupportedPlatform.ios) {
      defaultPlatform = iosSwiftPackageSupportedPlatform;
      packagePlatform = SwiftPackagePlatform.ios;
    } else {
      defaultPlatform = macosSwiftPackageSupportedPlatform;
      packagePlatform = SwiftPackagePlatform.macos;
    }

    if (projectDeploymentTargetVersion == null ||
        projectDeploymentTargetVersion <= defaultPlatform.version ||
        !project.flutterPluginSwiftPackageManifest.existsSync()) {
      return;
    }

    final String manifestContents = project.flutterPluginSwiftPackageManifest.readAsStringSync();
    final String oldSupportedPlatform = defaultPlatform.format();
    final String newSupportedPlatform =
        SwiftPackageSupportedPlatform(
          platform: packagePlatform,
          version: projectDeploymentTargetVersion,
        ).format();

    project.flutterPluginSwiftPackageManifest.writeAsStringSync(
      manifestContents.replaceFirst(oldSupportedPlatform, newSupportedPlatform),
    );
  }
}
