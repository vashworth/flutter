// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:process/process.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/template.dart';
import '../ios/xcodeproj.dart';
import '../plugins.dart';
import '../project.dart';
import 'cocoapods.dart';
import 'swift_packages.dart';

class DarwinDependencyManagementSetup {
  DarwinDependencyManagementSetup({
    required Artifacts artifacts,
    required FileSystem fileSystem,
    required CocoaPods cocoapods,
    required Logger logger,
    required ProcessManager processManager,
    required TemplateRenderer templateRenderer,
    required XcodeProjectInterpreter xcodeProjectInterpreter,
    required FlutterProject project,
    required List<Plugin> plugins,
  }) : _artifacts = artifacts,
       _fileSystem = fileSystem,
       _cocoapods = cocoapods,
       _logger = logger,
       _processManager = processManager,
       _templateRenderer = templateRenderer,
       _xcodeProjectInterpreter = xcodeProjectInterpreter,
       _project = project,
       _plugins = plugins;

  final Artifacts _artifacts;
  final FileSystem _fileSystem;
  final CocoaPods _cocoapods;
  final Logger _logger;
  final ProcessManager _processManager;
  final TemplateRenderer _templateRenderer;
  final XcodeProjectInterpreter _xcodeProjectInterpreter;
  final FlutterProject _project;
  final List<Plugin> _plugins;

  Future<void> setup({
    required SupportedPlatform platform,
    required XcodeBasedProject xcodeProject,
  }) async {
    if (platform != SupportedPlatform.ios && platform != SupportedPlatform.macos) {
      throwToolExit('${platform.name} is incompatible with Darwin Dependency Managers. Only iOS and macOS is allowed.');
    }
    final SwiftPackageManager spm = SwiftPackageManager(
      artifacts: _artifacts,
      fileSystem: _fileSystem,
      logger: _logger,
      processManager: _processManager,
      templateRenderer: _templateRenderer,
      xcodeProjectInterpreter: _xcodeProjectInterpreter,
    );
    if (_project.usingSwiftPackageManager) {
      await spm.generate(_plugins, platform, xcodeProject);
    } else if (SwiftPackageManager.projectMigrated(xcodeProject)) {
      // If SPM is not enabled but the project is already migrated to use SPM,
      // pass no plugins to the SPM generator. This will update SPM to still
      // exist but not have any dependencies.

      await spm.generate(<Plugin>[], platform, xcodeProject);
    }

    final (int pluginCount, int swiftPackageCount, int cocoapodCount) = await _countPlugins(
      platform: platform,
      xcodeProject: xcodeProject,
    );

    final bool useCocoapods = _usingCocoaPodsPlugin(
      pluginCount: pluginCount,
      swiftPackageCount: swiftPackageCount,
      cocoapodCount: cocoapodCount,
    );

    if (useCocoapods || xcodeProject.podfile.existsSync()) {
      if (_plugins.isNotEmpty) {
        await _cocoapods.setupPodfile(xcodeProject);
      }
      /// The user may have a custom maintained Podfile that they're running `pod install`
      /// on themselves.
      else if (xcodeProject.podfile.existsSync() && xcodeProject.podfileLock.existsSync()) {
        _cocoapods.addPodsDependencyToFlutterXcconfig(xcodeProject);
      }
    }
  }

  bool _usingCocoaPodsPlugin({
    required int pluginCount,
    required int swiftPackageCount,
    required int cocoapodCount,
  }) {
    if (_project.usingSwiftPackageManager) {
      if (pluginCount == swiftPackageCount) {
        return false;
      }
    }
    if (cocoapodCount > 0) {
      return true;
    }
    return false;
  }

  Future<(int, int, int)> _countPlugins({
    required SupportedPlatform platform,
    required XcodeBasedProject xcodeProject,
  }) async {
    int pluginCount = 0;
    int swiftPackageCount = 0;
    int cocoapodCount = 0;
    for (final Plugin plugin in _plugins) {
      if (plugin.platforms[platform.name] == null) {
        continue;
      }
      final String? swiftPackagePath = plugin.pluginSwiftPackagePath(platform.name);
      final bool pluginSwiftPackageManagerCompatible = swiftPackagePath != null && _fileSystem.file(swiftPackagePath).existsSync();
      final String? podspecPath = plugin.pluginPodspecPath(platform.name);
      final bool pluginCocoapodCompatible = podspecPath != null && _fileSystem.file(podspecPath).existsSync();

      // If a plugin is missing both a Package.swift and Podspec, it won't be
      // included by either Swift Package Manager or Cocoapods. This can happen
      // when a plugin doesn't have native platform code.
      // For example, image_picker_macos only uses dart code.
      if (!pluginSwiftPackageManagerCompatible && !pluginCocoapodCompatible) {
        continue;
      }

      pluginCount += 1;

      if (pluginSwiftPackageManagerCompatible) {
        swiftPackageCount += 1;
      }

      if (pluginCocoapodCompatible) {
        cocoapodCount += 1;
      } else if (!_project.usingSwiftPackageManager && pluginSwiftPackageManagerCompatible) {
        // If not using Swift Package Manager and plugin does not have podspec but does have swift package, warn it will not be used
        _logger.printWarning('Plugin ${plugin.name} is only Swift Package Manager compatible. Try enabling Swift Package Manager.');
      }
    }

    if (_project.usingSwiftPackageManager) {
      if (pluginCount == swiftPackageCount) {
        final File podfileTemplate = await _cocoapods.getPodfileTemplate(xcodeProject, xcodeProject.xcodeProject);
        final bool podfileExists = xcodeProject.podfile.existsSync();

        // If all plugins are SPM and generic podfile but pod stuff still exists, recommend pod deintegration
        // If all plugins are SPM and custom podfile, recommend migrating

        // TODO: SPM - Improve messages
        if (podfileExists && xcodeProject.podfile.readAsStringSync() == podfileTemplate.readAsStringSync()) {
          _logger.printStatus('All of the plugins you are using for ${platform.name} are Swift Packages. You may consider removing Cococapod files. To remove Cocoapods, in the ${platform.name}/ directory run `pod deintegrate` and delete the Podfile.');
        } else if (podfileExists) {
          _logger.printStatus('All of the plugins you are using for ${platform.name} are Swift Packages, but you may be using other Cocoapods. You may consider migrating to Swift Package Manager.');
        }
      }
    }

    return (pluginCount, swiftPackageCount, cocoapodCount);
  }
}
