// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../base/file_system.dart';
import '../base/template.dart';
import '../base/version.dart';

/// Swift toolchain version included with Xcode 15.0.
const String minimumSwiftToolchainVersion = '5.9';

const String _swiftPackageTemplate = '''
// swift-tools-version: {{swiftToolsVersion}}
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Generated file. Do not edit.
//

import PackageDescription

{{#buildMode}}
enum BuildMode: String {
    case Debug
    case Profile
    case Release
}
let selectedBuildMode = BuildMode.{{buildMode}}
{{/buildMode}}

let package = Package(
    name: "{{packageName}}",
    {{#platforms}}
    platforms: [
        {{platforms}}
    ],
    {{/platforms}}
    products: [
        {{products}}
    ],
    dependencies: [
        {{dependencies}}
    ],
    targets: [
        {{targets}}
    ]
)
''';

const String _swiftPackageSourceTemplate = '''
//
//  Generated file. Do not edit.
//
''';

const String _singleIndent = '    ';
const String _doubleIndent = '$_singleIndent$_singleIndent';

/// A Swift Package is reusable code that can be shared across projects and
/// with other developers in iOS and macOS applications. A Swift Package
/// requires a Package.swift. This class handles the formatting and creation of
/// a Package.swift.
///
/// See https://developer.apple.com/documentation/packagedescription/package
/// for more information about Swift Packages and Package.swift.
class SwiftPackage {
  SwiftPackage({
    required this.manifest,
    required this.name,
    required List<SwiftPackageSupportedPlatform> platforms,
    required this.products,
    required List<SwiftPackagePackageDependency> dependencies,
    required List<SwiftPackageTarget> targets,
    String? buildMode,
    required TemplateRenderer templateRenderer,
  })  : _platforms = platforms,
        _dependencies = dependencies,
        _targets = targets,
        _buildMode = buildMode,
        _templateRenderer = templateRenderer;

  /// [File] for Package.swift.
  final File manifest;

  /// The name of the Swift package.
  final String name;

  /// The list of minimum versions for platforms supported by the package.
  final List<SwiftPackageSupportedPlatform> _platforms;

  /// The list of products that this package vends and that clients can use.
  final List<SwiftPackageProduct> products;

  /// The list of package dependencies.
  final List<SwiftPackagePackageDependency> _dependencies;

  /// The list of targets that are part of this package.
  final List<SwiftPackageTarget> _targets;

  final String? _buildMode;

  final TemplateRenderer _templateRenderer;

  /// Context for the [_swiftPackageTemplate] template.
  Map<String, Object> get _templateContext {
    return <String, Object>{
      'swiftToolsVersion': minimumSwiftToolchainVersion,
      'packageName': name,
      // Supported platforms can't be empty, so only include if not null.
      'platforms': _formatPlatforms() ?? false,
      'products': _formatProducts(),
      'dependencies': _formatDependencies(),
      'targets': _formatTargets(),
      'buildMode': _buildMode ?? false,
    };
  }

  /// Create a Package.swift using settings from [_templateContext].
  void createSwiftPackage() {
    // Swift Packages require at least one source file per non-binary target,
    // whether it be in Swift or Objective C. If the target does not have any
    // files yet, create an empty Swift file.
    for (final SwiftPackageTarget target in _targets) {
      if (target.targetType != SwiftPackageTargetType.target) {
        continue;
      }
      final Directory targetDirectory = manifest.parent
          .childDirectory('Sources')
          .childDirectory(target.name);
      if (!targetDirectory.existsSync() || targetDirectory.listSync().isEmpty) {
        final File requiredSwiftFile = targetDirectory.childFile(
          '${target.name}.swift',
        );
        requiredSwiftFile.createSync(recursive: true);
        requiredSwiftFile.writeAsStringSync(_swiftPackageSourceTemplate);
      }
    }

    final String renderedTemplate = _templateRenderer.renderString(
      _swiftPackageTemplate,
      _templateContext,
    );
    manifest.createSync(recursive: true);
    manifest.writeAsStringSync(renderedTemplate);
  }

  String? _formatPlatforms() {
    if (_platforms.isEmpty) {
      return null;
    }
    final List<String> platformStrings = _platforms
        .map((SwiftPackageSupportedPlatform platform) => platform.format())
        .toList();
    return platformStrings.join(',\n$_doubleIndent');
  }

  String _formatProducts() {
    if (products.isEmpty) {
      return '';
    }
    final List<String> libraries = products
        .map((SwiftPackageProduct product) => product.format())
        .toList();
    return libraries.join(',\n$_doubleIndent');
  }

  String _formatDependencies() {
    if (_dependencies.isEmpty) {
      return '';
    }
    final List<String> packages = _dependencies
        .map((SwiftPackagePackageDependency dependency) => dependency.format())
        .toList();
    return packages.join(',\n$_doubleIndent');
  }

  String _formatTargets() {
    if (_targets.isEmpty) {
      return '';
    }
    final List<String> targetList =
        _targets.map((SwiftPackageTarget target) => target.format()).toList();
    return targetList.join(',\n$_doubleIndent');
  }
}

enum SwiftPackagePlatform {
  ios(jsonName: 'ios', swiftFactory: '.iOS'),
  macos(jsonName: 'macos', swiftFactory: '.macOS');

  const SwiftPackagePlatform({
    required this.jsonName,
    required this.swiftFactory,
  });

  final String jsonName;
  final String swiftFactory;
}

/// A platform that the Swift package supports.
///
/// Representation of SupportedPlatform from
/// https://developer.apple.com/documentation/packagedescription/supportedplatform.
class SwiftPackageSupportedPlatform {
  SwiftPackageSupportedPlatform({
    required this.platform,
    required this.version,
  });

  ///
  static SwiftPackageSupportedPlatform? fromJson(Map<String, Object?> json) {
    final Object? platformName = json['platformName'];
    if (platformName == null || platformName is! String) {
      return null;
    }
    final SwiftPackagePlatform packagePlatform;
    if (platformName == SwiftPackagePlatform.ios.jsonName) {
      packagePlatform = SwiftPackagePlatform.ios;
    } else if (platformName == SwiftPackagePlatform.macos.jsonName) {
      packagePlatform = SwiftPackagePlatform.macos;
    } else {
      return null;
    }

    final Object? version = json['version'];
    if (version == null || version is! String) {
      return null;
    }
    final Version? parsedVersion = Version.parse(version);
    if (parsedVersion == null) {
      return null;
    }

    return SwiftPackageSupportedPlatform(
      platform: packagePlatform,
      version: parsedVersion,
    );
  }

  final SwiftPackagePlatform platform;
  final Version version;

  String format() {
    // platforms: [
    //     .macOS("10.14"),
    //     .iOS("12.0"),
    // ],
    return '${platform.swiftFactory}("$version")';
  }
}

/// Types of library linking.
///
/// Representation of Product.Library.LibraryType from
/// https://developer.apple.com/documentation/packagedescription/product/library/librarytype.
enum SwiftPackageLibraryType {
  dynamic(jsonName: 'dynamic', swiftFactory: '.dynamic'),
  static(jsonName: 'static', swiftFactory: '.static');

  const SwiftPackageLibraryType({
    required this.jsonName,
    required this.swiftFactory,
  });

  final String swiftFactory;
  final String jsonName;
}

/// An externally visible build artifact that's available to clients of the
/// package.
///
/// Representation of Product from
/// https://developer.apple.com/documentation/packagedescription/product.
class SwiftPackageProduct {
  SwiftPackageProduct({
    required this.name,
    required this.targets,
    this.libraryType,
  });

  final String name;
  final SwiftPackageLibraryType? libraryType;
  final List<String> targets;

  String format() {
    // products: [
    //     .library(name: "FlutterGeneratedPluginSwiftPackage", targets: ["FlutterGeneratedPluginSwiftPackage"]),
    //     .library(name: "FlutterDependenciesPackage", type: .dynamic, targets: ["FlutterDependenciesPackage"]),
    // ],
    String targetsString = '';
    if (targets.isNotEmpty) {
      final List<String> quotedTargets =
          targets.map((String target) => '"$target"').toList();
      targetsString = ', targets: [${quotedTargets.join(', ')}]';
    }
    String libraryTypeString = '';
    if (libraryType != null) {
      libraryTypeString = ', type: ${libraryType!.swiftFactory}';
    }
    return '.library(name: "$name"$libraryTypeString$targetsString)';
  }
}

/// A package dependency of a Swift package.
///
/// Representation of Package.Dependency from
/// https://developer.apple.com/documentation/packagedescription/package/dependency.
class SwiftPackagePackageDependency {
  SwiftPackagePackageDependency({
    required this.name,
    required this.path,
  });

  final String name;
  final String path;

  String format() {
    // dependencies: [
    //     .package(name: "image_picker_ios", path: "/path/to/packages/image_picker/image_picker_ios/ios/image_picker_ios"),
    // ],
    return '.package(name: "$name", path: "$path")';
  }
}

/// Type of Target constructor.
///
/// See https://developer.apple.com/documentation/packagedescription/target for
/// more information.
enum SwiftPackageTargetType {
  target(jsonName: 'regular', swiftFactory: '.target'),
  binaryTarget(jsonName: 'binary', swiftFactory: '.binaryTarget'),
  remoteBinaryTarget(jsonName: 'binary', swiftFactory: '.binaryTarget');

  const SwiftPackageTargetType({
    required this.jsonName,
    required this.swiftFactory,
  });

  final String jsonName;
  final String swiftFactory;
}

/// A building block of a Swift Package that contains a set of source files
/// that Swift Package Manager compiles into a module.
///
/// Representation of Target from
/// https://developer.apple.com/documentation/packagedescription/target.
class SwiftPackageTarget {
  SwiftPackageTarget.defaultTarget({
    required this.name,
    this.dependencies,
  })  : path = null,
        url = null,
        checksum = null,
        targetType = SwiftPackageTargetType.target;

  SwiftPackageTarget.binaryTarget({
    required this.name,
    required String relativePath,
  })  : path = relativePath,
        dependencies = null,
        url = null,
        checksum = null,
        targetType = SwiftPackageTargetType.binaryTarget;

  SwiftPackageTarget.remoteBinaryTarget({
    required this.name,
    required this.url,
    required this.checksum,
  })  : path = null,
        dependencies = null,
        targetType = SwiftPackageTargetType.remoteBinaryTarget;

  final String name;
  final String? path;
  final List<SwiftPackageTargetDependency>? dependencies;
  final String? url;
  final String? checksum;
  final SwiftPackageTargetType targetType;

  String format() {
    // targets: [
    //     .binaryTarget(
    //         name: "Flutter",
    //         path: "Flutter.xcframework"
    //     ),
    //     .target(
    //         name: "FlutterGeneratedPluginSwiftPackage",
    //         dependencies: [
    //             .target(name: "Flutter"),
    //             .product(name: "image_picker_ios", package: "image_picker_ios")
    //         ]
    //     ),
    // ]
    const String targetIndent = _doubleIndent;
    const String targetDetailsIndent = '$_doubleIndent$_singleIndent';

    final List<String> targetDetails = <String>[];

    final String nameString = 'name: "$name"';
    targetDetails.add(nameString);

    if (path != null) {
      final String pathString = 'path: "$path"';
      targetDetails.add(pathString);
    }

    if (url != null) {
      final String urlString = 'url: "$url"';
      targetDetails.add(urlString);
    }

    if (checksum != null) {
      final String checksumString = 'checksum: "$checksum"';
      targetDetails.add(checksumString);
    }

    if (dependencies != null && dependencies!.isNotEmpty) {
      final List<String> targetDependencies = dependencies!
          .map((SwiftPackageTargetDependency dependency) => dependency.format())
          .toList();
      final String dependenciesString = '''
dependencies: [
${targetDependencies.join(",\n")}
$targetDetailsIndent]''';
      targetDetails.add(dependenciesString);
    }

    return '''
${targetType.swiftFactory}(
$targetDetailsIndent${targetDetails.join(",\n$targetDetailsIndent")}
$targetIndent)''';
  }
}

/// Type of Target.Dependency constructor.
///
/// See https://developer.apple.com/documentation/packagedescription/target/dependency
/// for more information.
enum SwiftPackageTargetDependencyType {
  product(name: '.product'),
  target(name: '.target');

  const SwiftPackageTargetDependencyType({required this.name});

  final String name;
}

/// A dependency for the Target on a product from a package dependency or from
/// another Target in the same package.
///
/// Representation of Target.Dependency from
/// https://developer.apple.com/documentation/packagedescription/target/dependency.
class SwiftPackageTargetDependency {
  SwiftPackageTargetDependency.product({
    required this.name,
    required String packageName,
  })  : package = packageName,
        dependencyType = SwiftPackageTargetDependencyType.product;

  SwiftPackageTargetDependency.target({
    required this.name,
  })  : package = null,
        dependencyType = SwiftPackageTargetDependencyType.target;

  final String name;
  final String? package;
  final SwiftPackageTargetDependencyType dependencyType;

  String format() {
    //         dependencies: [
    //             .target(name: "Flutter"),
    //             .product(name: "image_picker_ios", package: "image_picker_ios")
    //         ]
    if (dependencyType == SwiftPackageTargetDependencyType.product) {
      return '$_doubleIndent$_doubleIndent${dependencyType.name}(name: "$name", package: "$package")';
    }
    return '$_doubleIndent$_doubleIndent${dependencyType.name}(name: "$name")';
  }
}
