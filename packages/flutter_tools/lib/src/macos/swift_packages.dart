// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../base/file_system.dart';
import '../base/template.dart';
import '../base/version.dart';

/// Swift toolchain version included with Xcode 15.0.
const minimumSwiftToolchainVersion = '5.9';

const _swiftPackageTemplate = '''
// swift-tools-version: {{swiftToolsVersion}}
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  Generated file. Do not edit.
//

import PackageDescription

{{#hasSwiftCodeBefore}}\n{{swiftCodeBefore}}\n\n{{/hasSwiftCodeBefore}}
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

const _swiftPackageSourceTemplate = '''
//
//  Generated file. Do not edit.
//
''';

const _singleIndent = '    ';
const _doubleIndent = '$_singleIndent$_singleIndent';

/// A Swift Package is reusable code that can be shared across projects and
/// with other developers in iOS and macOS applications. A Swift Package
/// requires a Package.swift. This class handles the formatting and creation of
/// a Package.swift.
///
/// See https://developer.apple.com/documentation/packagedescription/package
/// for more information about Swift Packages and Package.swift.
class SwiftPackage {
  SwiftPackage({
    required File manifest,
    required String name,
    required this.platforms,
    required List<SwiftPackageProduct> products,
    required this.dependencies,
    required this.targets,
    required TemplateRenderer templateRenderer,
    String? swiftCodeBeforePackageDefinition,
  }) : _manifest = manifest,
       _name = name,
       _products = products,
       _templateRenderer = templateRenderer,
       _swiftCodeBeforePackageDefinition = swiftCodeBeforePackageDefinition;

  /// [File] for Package.swift.
  final File _manifest;

  /// The name of the Swift package.
  final String _name;

  /// The list of minimum versions for platforms supported by the package.
  final List<SwiftPackageSupportedPlatform> platforms;

  /// The list of products that this package vends and that clients can use.
  final List<SwiftPackageProduct> _products;

  /// The list of package dependencies.
  final List<SwiftPackagePackageDependency> dependencies;

  /// The list of targets that are part of this package.
  final List<SwiftPackageTarget> targets;

  final TemplateRenderer _templateRenderer;

  final String? _swiftCodeBeforePackageDefinition;

  /// Context for the [_swiftPackageTemplate] template.
  Map<String, Object> get _templateContext => <String, Object>{
    'swiftToolsVersion': minimumSwiftToolchainVersion,
    'hasSwiftCodeBefore': _swiftCodeBeforePackageDefinition != null,
    'swiftCodeBefore': _swiftCodeBeforePackageDefinition ?? '',
    'packageName': _name,
    // Supported platforms can't be empty, so only include if not null.
    'platforms': _formatPlatforms() ?? false,
    'products': _formatProducts(),
    'dependencies': _formatDependencies(),
    'targets': _formatTargets(),
  };

  static SwiftPackage? fromJson(
    Map<String, Object?> data, {
    required File manifest,
    required TemplateRenderer templateRenderer,
  }) {
    if (data case {
      'name': final String name,
      'platforms': final List<Object?> platformsData,
      'dependencies': final List<Object?> dependenciesData,
      'targets': final List<Object?> targetsData,
    }) {
      final products = <SwiftPackageProduct>[];
      final List<SwiftPackageSupportedPlatform> platforms =
          _parseJsonList<SwiftPackageSupportedPlatform>(
            platformsData,
            SwiftPackageSupportedPlatform.fromJson,
          );
      final List<SwiftPackagePackageDependency> dependencies =
          _parseJsonList<SwiftPackagePackageDependency>(
            dependenciesData,
            SwiftPackagePackageDependency.fromJson,
          );
      final List<SwiftPackageTarget> targets = _parseJsonList<SwiftPackageTarget>(
        targetsData,
        SwiftPackageTarget.fromJson,
      );

      return SwiftPackage(
        manifest: manifest,
        name: name,
        platforms: platforms,
        products: products,
        dependencies: dependencies,
        targets: targets,
        templateRenderer: templateRenderer,
      );
    } else {
      return null;
    }
  }

  static List<T> _parseJsonList<T>(List<Object?> data, T? Function(Map<String, Object?>) parse) {
    final parsedItems = <T>[];
    for (final item in data) {
      if (item is Map<String, Object?>) {
        final T? parsedItem = parse(item);
        if (parsedItem != null) {
          parsedItems.add(parsedItem);
        }
      }
    }
    return parsedItems;
  }

  /// Create a Package.swift using settings from [_templateContext].
  void createSwiftPackage({bool generateEmptySources = true}) {
    // Swift Packages require at least one source file per non-binary target,
    // whether it be in Swift or Objective C. If the target does not have any
    // files yet, create an empty Swift file.
    for (final SwiftPackageTarget target in targets) {
      if (target.targetType == SwiftPackageTargetType.binaryTarget) {
        continue;
      }
      final Directory targetDirectory = _manifest.parent
          .childDirectory('Sources')
          .childDirectory(target.name);
      if (generateEmptySources &&
          (!targetDirectory.existsSync() || targetDirectory.listSync().isEmpty)) {
        final File requiredSwiftFile = targetDirectory.childFile('${target.name}.swift');
        requiredSwiftFile.createSync(recursive: true);
        requiredSwiftFile.writeAsStringSync(_swiftPackageSourceTemplate);
      }
    }

    final String renderedTemplate = _templateRenderer.renderString(
      _swiftPackageTemplate,
      _templateContext,
    );
    _manifest.createSync(recursive: true);
    _manifest.writeAsStringSync(renderedTemplate);
  }

  String? _formatPlatforms() {
    if (platforms.isEmpty) {
      return null;
    }
    final List<String> platformStrings = platforms
        .map((SwiftPackageSupportedPlatform platform) => platform.format())
        .toList();
    return platformStrings.join(',\n$_doubleIndent');
  }

  String _formatProducts() {
    if (_products.isEmpty) {
      return '';
    }
    final List<String> libraries = _products
        .map((SwiftPackageProduct product) => product.format())
        .toList();
    return libraries.join(',\n$_doubleIndent');
  }

  String _formatDependencies() {
    if (dependencies.isEmpty) {
      return '';
    }
    final List<String> packages = dependencies
        .map((SwiftPackagePackageDependency dependency) => dependency.format())
        .toList();
    return packages.join(',\n$_doubleIndent');
  }

  String _formatTargets() {
    if (targets.isEmpty) {
      return '';
    }
    final List<String> targetList = targets
        .map((SwiftPackageTarget target) => target.format())
        .toList();
    return targetList.join(',\n$_doubleIndent');
  }
}

enum SwiftPackagePlatform {
  ios(displayName: '.iOS'),
  macos(displayName: '.macOS'),
  tvos(displayName: '.tvOS'),
  watchos(displayName: '.watchOS');

  const SwiftPackagePlatform({required this.displayName});

  final String displayName;
}

/// A platform that the Swift package supports.
///
/// Representation of SupportedPlatform from
/// https://developer.apple.com/documentation/packagedescription/supportedplatform.
class SwiftPackageSupportedPlatform {
  SwiftPackageSupportedPlatform({required this.platform, required this.version});

  static SwiftPackageSupportedPlatform? fromJson(Map<String, Object?> json) {
    if (json case {
      'platformName': final String platformName,
      'version': final String versionString,
    }) {
      final Version? parsedVersion = Version.parse(versionString);
      if (parsedVersion != null) {
        if (platformName == SwiftPackagePlatform.ios.name) {
          return SwiftPackageSupportedPlatform(
            platform: SwiftPackagePlatform.ios,
            version: parsedVersion,
          );
        } else if (platformName == SwiftPackagePlatform.macos.name) {
          return SwiftPackageSupportedPlatform(
            platform: SwiftPackagePlatform.macos,
            version: parsedVersion,
          );
        }
      }
    }
    return null;
  }

  final SwiftPackagePlatform platform;
  final Version version;

  String format() {
    // platforms: [
    //     .macOS("10.15"),
    //     .iOS("13.0"),
    // ],
    return '${platform.displayName}("$version")';
  }
}

/// Types of library linking.
///
/// Representation of Product.Library.LibraryType from
/// https://developer.apple.com/documentation/packagedescription/product/library/librarytype.
enum SwiftPackageLibraryType {
  dynamic(name: '.dynamic'),
  static(name: '.static');

  const SwiftPackageLibraryType({required this.name});

  final String name;
}

/// An externally visible build artifact that's available to clients of the
/// package.
///
/// Representation of Product from
/// https://developer.apple.com/documentation/packagedescription/product.
class SwiftPackageProduct {
  SwiftPackageProduct({required this.name, required this.targets, this.libraryType});

  // factory SwiftPackageProduct? fromJson(Map<String, Object?> json) {
  //   final String? name = json['name'] as String?;
  //   if (name == null) {
  //     return null;
  //   }
  //   final List<Object?>? targetsRaw = json['targets'] as List<Object?>?;
  //   if (targetsRaw == null) {
  //     return null;
  //   }
  //   final List<String> targets = targetsRaw.cast<String>();

  //   SwiftPackageLibraryType? libraryType;
  //   if (json['type'] is Map<String, Object?>) {
  //     final Map<String, Object?> typeMap = json['type']! as Map<String, Object?>;
  //     if (typeMap['library'] is List<Object?> && (typeMap['library']! as List<Object?>).isNotEmpty) {
  //       final String? libraryTypeName = (typeMap['library']! as List<Object?>).first! as String?;
  //       if (libraryTypeName == null) {
  //         return null;
  //       }
  //       switch (libraryTypeName) {
  //         case 'static':
  //           libraryType = SwiftPackageLibraryType.static;
  //           break;
  //         case 'dynamic':
  //           libraryType = SwiftPackageLibraryType.dynamic;
  //           break;
  //         default:
  //           return null; // Unknown library type
  //       }
  //     }
  //   }
  //   return SwiftPackageProduct(name: name, targets: targets, libraryType: libraryType);
  // }

  final String name;
  final SwiftPackageLibraryType? libraryType;
  final List<String> targets;

  String format() {
    // products: [
    //     .library(name: "FlutterGeneratedPluginSwiftPackage", targets: ["FlutterGeneratedPluginSwiftPackage"]),
    //     .library(name: "FlutterDependenciesPackage", type: .dynamic, targets: ["FlutterDependenciesPackage"]),
    // ],
    var targetsString = '';
    if (targets.isNotEmpty) {
      final List<String> quotedTargets = targets.map((String target) => '"$target"').toList();
      targetsString = ', targets: [${quotedTargets.join(', ')}]';
    }
    var libraryTypeString = '';
    if (libraryType != null) {
      libraryTypeString = ', type: ${libraryType!.name}';
    }
    return '.library(name: "$name"$libraryTypeString$targetsString)';
  }
}

/// A package dependency of a Swift package.
///
/// Representation of Package.Dependency from
/// https://developer.apple.com/documentation/packagedescription/package/dependency.
class SwiftPackagePackageDependency {
  SwiftPackagePackageDependency({required this.name, required this.path});

  static SwiftPackagePackageDependency? fromJson(Map<String, Object?> json) {
    final fileSystemList = json['fileSystem'] as List<Object?>?;
    if (fileSystemList == null || fileSystemList.isEmpty) {
      return null;
    }
    for (final Object? item in fileSystemList) {
      if (item is Map<String, Object?>) {
        if (json case {
          'nameForTargetDependencyResolutionOnly': final String name,
          'path': final String path,
        }) {
          return SwiftPackagePackageDependency(name: name, path: path);
        }
      }
    }
    return null;
  }

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
  target(displayName: '.target', jsonName: 'regular'),
  binaryTarget(displayName: '.binaryTarget', jsonName: 'binary'),
  remoteBinaryTarget(displayName: '.binaryTarget', jsonName: 'TODO');

  const SwiftPackageTargetType({required this.displayName, required this.jsonName});

  final String displayName;
  final String jsonName;
}

/// A building block of a Swift Package that contains a set of source files
/// that Swift Package Manager compiles into a module.
///
/// Representation of Target from
/// https://developer.apple.com/documentation/packagedescription/target.
class SwiftPackageTarget {
  SwiftPackageTarget.defaultTarget({required this.name, this.dependencies})
    : path = null,
      url = null,
      checksum = null,
      targetType = SwiftPackageTargetType.target;

  SwiftPackageTarget.binaryTarget({required this.name, required String relativePath})
    : path = relativePath,
      dependencies = null,
      url = null,
      checksum = null,
      targetType = SwiftPackageTargetType.binaryTarget;

  SwiftPackageTarget.remoteBinaryTarget({
    required this.name,
    required String zipUrl,
    required String zipChecksum,
  }) : path = null,
       url = zipUrl,
       checksum = zipChecksum,
       dependencies = null,
       targetType = SwiftPackageTargetType.remoteBinaryTarget;

  static SwiftPackageTarget? fromJson(Map<String, Object?> json) {
    if (json case {
      'name': final String name,
      'type': final String targetTypeString,
      'dependencies': final List<Object?> dependencyItems,
    }) {
      final dependencies = <SwiftPackageTargetDependency>[];
      for (final item in dependencyItems) {
        if (item is Map<String, Object?>) {
          final SwiftPackageTargetDependency? dependency = SwiftPackageTargetDependency.fromJson(
            item,
          );
          if (dependency != null) {
            dependencies.add(dependency);
          }
        }
      }
      final path = json['path'] as String?;
      if (targetTypeString == SwiftPackageTargetType.binaryTarget.jsonName && path != null) {
        return SwiftPackageTarget.binaryTarget(name: name, relativePath: path);
      } else if (targetTypeString == SwiftPackageTargetType.target.jsonName) {
        return SwiftPackageTarget.defaultTarget(name: name, dependencies: dependencies);
      }
    }
    return null;
  }

  final String name;
  final String? path;
  final List<SwiftPackageTargetDependency>? dependencies;
  final SwiftPackageTargetType targetType;
  final String? url;
  final String? checksum;

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
    const targetDetailsIndent = '$_doubleIndent$_singleIndent';

    final targetDetails = <String>[];

    final nameString = 'name: "$name"';
    targetDetails.add(nameString);

    if (path != null) {
      final pathString = 'path: "$path"';
      targetDetails.add(pathString);
    }

    if (dependencies != null && dependencies!.isNotEmpty) {
      final List<String> targetDependencies = dependencies!
          .map((SwiftPackageTargetDependency dependency) => dependency.format())
          .toList();
      final dependenciesString =
          '''
dependencies: [
${targetDependencies.join(",\n")}
$targetDetailsIndent]''';
      targetDetails.add(dependenciesString);
    }

    if (url != null) {
      final urlString = 'url: "$url"';
      targetDetails.add(urlString);
    }

    if (checksum != null) {
      final checksumString = 'checksum: "$checksum"';
      targetDetails.add(checksumString);
    }

    return '''
${targetType.displayName}(
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
    this.platformCondition,
  }) : package = packageName,
       dependencyType = SwiftPackageTargetDependencyType.product;

  SwiftPackageTargetDependency.target({required this.name, this.platformCondition})
    : package = null,
      dependencyType = SwiftPackageTargetDependencyType.target;

  static SwiftPackageTargetDependency? fromJson(Map<String, Object?> json) {
    if (json.containsKey('target')) {
      final targetData = json['target'] as List<Object?>?;
      if (targetData == null || targetData.isEmpty) {
        return null;
      }
      final name = targetData.first as String?;
      if (name == null) {
        return null;
      }
      return SwiftPackageTargetDependency.target(name: name);
    } else if (json.containsKey('product')) {
      final productData = json['product'] as List<Object?>?;
      if (productData == null || productData.length < 2) {
        return null;
      }
      final name = productData.first as String?;
      final packageName = productData[1] as String?;
      if (name == null || packageName == null) {
        return null;
      }
      return SwiftPackageTargetDependency.product(name: name, packageName: packageName);
    }
    return null; // Invalid SwiftPackageTargetDependency JSON
  }

  final String name;
  final String? package;
  final List<SwiftPackagePlatform>? platformCondition;
  final SwiftPackageTargetDependencyType dependencyType;

  String format() {
    //         dependencies: [
    //             .target(name: "Flutter"),
    //             .product(name: "image_picker_ios", package: "image_picker_ios")
    //         ]
    var conditionString = '';
    if (platformCondition != null && platformCondition!.isNotEmpty) {
      conditionString =
          ', condition: .when(platforms: [${platformCondition!.map((SwiftPackagePlatform platform) => platform.displayName).join(', ')}])';
    }
    if (dependencyType == SwiftPackageTargetDependencyType.product) {
      return '$_doubleIndent$_doubleIndent${dependencyType.name}(name: "$name", package: "$package"$conditionString)';
    }
    return '$_doubleIndent$_doubleIndent${dependencyType.name}(name: "$name"$conditionString)';
  }
}
