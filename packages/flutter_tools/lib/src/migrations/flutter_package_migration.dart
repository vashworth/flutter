// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:process/process.dart';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project_migrator.dart';
import '../base/version.dart';
import '../globals.dart';
import '../ios/plist_parser.dart';
import '../ios/xcodeproj.dart';
import '../project.dart';

/// TODO: SPM - comment
class FlutterPackageMigration extends ProjectMigrator {
  FlutterPackageMigration(
    XcodeBasedProject project,
    SupportedPlatform platform, {
    required XcodeProjectInterpreter xcodeProjectInterpreter,
    required Logger logger,
    required FileSystem fileSystem,
    required ProcessManager processManager,
  })  : _xcodeProject = project,
        _xcodeProjectInfoFile = project.xcodeProjectInfoFile,
        _platform = platform,
        _xcodeProjectInterpreter = xcodeProjectInterpreter,
        _fileSystem = fileSystem,
        _processManager = processManager,
        super(logger);

  final XcodeBasedProject _xcodeProject;
  final XcodeProjectInterpreter _xcodeProjectInterpreter;
  final FileSystem _fileSystem;
  final ProcessManager _processManager;
  final File _xcodeProjectInfoFile;
  final SupportedPlatform _platform;

  static const String _flutterPackageBuildFileIdentifier = '78A318202AECB46A00862997';
  static const String flutterPackageFileReferenceIdentifier = '78A3181E2AECB45400862997';
  static const String _flutterPackageProductDependencyIdentifer = '78A3181F2AECB46A00862997';
  static const String _iosRunnerFrameworksBuildPhaseIdentifer = '97C146EB1CF9000F007C117D';
  static const String _macosRunnerFrameworksBuildPhaseIdentifer = '33CC10EA2044A3C60003C045';
  static const String _flutterPackagesGroupIdentifier = '78A3181D2AECB45400862997';
  static const String _iosFlutterGroupIdentifier = '9740EEB11CF90186004384FC';
  static const String _macosFlutterGroupIdentifier = '33CEB47122A05771004F2AC0';
  static const String _iosRunnerNativeTargetIdentifer = '97C146ED1CF9000F007C117D';
  static const String _macosRunnerNativeTargetIdentifer = '33CC10EC2044A3C60003C045';
  static const String _iosProjectIdentifier = '97C146E61CF9000F007C117D';
  static const String _macosProjectIdentifier = '33CC10E52044A3C60003C045';
  static const String _localSwiftPackageReferenceIdentifer = '781AD8BC2B33823900A9FFBB';

  File get backupProjectSettings  => _fileSystem.directory(_xcodeProjectInfoFile.parent).childFile('project.pbxproj.backup');

  String get _runnerFrameworksBuildPhaseIdentifer {
    return _platform == SupportedPlatform.ios ? _iosRunnerFrameworksBuildPhaseIdentifer : _macosRunnerFrameworksBuildPhaseIdentifer;
  }

  String get _flutterGroupIdentifier {
    return _platform == SupportedPlatform.ios ? _iosFlutterGroupIdentifier : _macosFlutterGroupIdentifier;
  }

  String get _runnerNativeTargetIdentifer {
    return _platform == SupportedPlatform.ios ? _iosRunnerNativeTargetIdentifer : _macosRunnerNativeTargetIdentifer;
  }

  String get _projectIdentifier {
    return _platform == SupportedPlatform.ios ? _iosProjectIdentifier : _macosProjectIdentifier;
  }

  late final PlistParser _parser = PlistParser(
    fileSystem: _fileSystem,
    logger: logger,
    processManager: _processManager,
  );

  @override
  void migrate() {
    try {
      if (!_xcodeProjectInfoFile.existsSync()) {
        throw Exception('Xcode project not found.');
      }

      // Update FlutterOutputs.xcfilelist
      if (_platform == SupportedPlatform.macos) {
        final File outputFile = (_xcodeProject as MacOSProject).outputFileList;
        if (outputFile.existsSync() && outputFile.readAsStringSync().contains('FlutterMacOS.framework/Versions/A/FlutterMacOS')) {
          final List<String> lines =  outputFile.readAsLinesSync();
          lines.removeWhere((String path) => path.contains('FlutterMacOS.framework/Versions/A/FlutterMacOS'));
          outputFile.writeAsStringSync(
            lines.join('\n'),
          );
        }
      }

      // Update gitignore
      _updateGitIgnore(_xcodeProject.parent.directory.childFile('.gitignore'));
      _updateGitIgnore(_xcodeProject.hostAppRoot.childFile('.gitignore'));

      final Version? version = _xcodeProjectInterpreter.version;

      bool xcode15 = true;

      // If Xcode not installed or less than 15, skip this migration.
      if (version == null || version < Version(15, 0, 0)) {
        xcode15 = true;
      }

      // Parse project.pbxproj into JSON
      final ParsedProjectInfo parsedInfo = _parseResults();

      // If project is already migrated, skip
      if (_isMigrated(parsedInfo, xcode15)) {
        return;
      }

      final String originalProjectContents =
          _xcodeProjectInfoFile.readAsStringSync();

      List<String> lines = LineSplitter.split(originalProjectContents).toList();
      lines = _migrateBuildFile(lines, parsedInfo);
      lines = _migrateFileReference(lines, parsedInfo);
      lines = _migrateFrameworksBuildPhase(lines, parsedInfo);
      lines = _migrateGroupPackages(lines, parsedInfo);
      lines = _migrateNativeTarget(lines, parsedInfo);
      lines = _migratePackageProductDependencies(lines, parsedInfo);
      lines = _migrateLocalPackageProductDependencies(lines, parsedInfo, xcode15);
      lines = _migrateProjectObject(lines, parsedInfo, xcode15);

      final String newProjectContents = '${lines.join('\n')}\n';

      if (originalProjectContents != newProjectContents) {
        logger.printStatus('Creating backup project settings...');
        _xcodeProjectInfoFile.copySync(backupProjectSettings.path);

        logger.printStatus('Adding Flutter Package as a dependency...');
        _xcodeProjectInfoFile.writeAsStringSync(newProjectContents);
      }

      // Re-parse the project settings to check for syntax errors
      final ParsedProjectInfo updatedInfo = _parseResults();

      if (!_isMigrated(updatedInfo, xcode15)) {
        throw Exception('Settings were not updated correctly.');
      }
    } on Exception catch (e) {
      logger.printError('An error occured when migrating your project to Swift Package Manager: $e');

      throwToolExit('Failed to convert your project to use Swift Package Manager. Please follow instructions found at xxx to manually convert your project.');
    }
  }

  void _updateGitIgnore(File gitignore) {
    // TODO: SPM, should add if not exists?
    if (!gitignore.existsSync()) {
      return;
    }
    final String originalProjectContents = gitignore.readAsStringSync();
    if (originalProjectContents.contains('Flutter/Packages/FlutterPackage')) {
      return;
    }
    String newProjectContents = originalProjectContents;
    newProjectContents = newProjectContents.replaceAll('**/Pods/', '**/Pods/\nFlutter/Packages/FlutterPackage');
    if (originalProjectContents != newProjectContents) {
      gitignore.writeAsStringSync(newProjectContents);
    }
  }

  ParsedProjectInfo _parseResults() {
    final String? results = _parser.plistJsonContent(_xcodeProjectInfoFile.path, sorted: true);
    if (results == null) {
      throw Exception('Failed to parse project settings.');
    }

    try {
      final Object decodeResult = json.decode(results) as Object;
      if (decodeResult is! Map<String, Object?>) {
        throw Exception('project.pbxproj returned unexpected JSON response: $results');
      }
      return ParsedProjectInfo.fromJson(decodeResult);
    } on FormatException {
      throw Exception('project.pbxproj returned non-JSON response: $results');
    }
  }

  bool _isMigrated(ParsedProjectInfo projectInfo, bool xcode15) {
    return _isBuildFilesMigrated(projectInfo) &&
        _isFileReferenceMigrated(projectInfo) &&
        _isFrameworksBuildPhaseMigrated(projectInfo) &&
        _isGroupsMigrated(projectInfo) &&
        _isNativeTargetMigrated(projectInfo) &&
        _isSwiftPackageProductDependencyMigrated(projectInfo) &&
        _isLocalSwiftPackageProductDependencyMigrated(projectInfo, xcode15) &&
        _isProjectObjectMigrated(projectInfo, xcode15);
  }

  bool _isBuildFilesMigrated(ParsedProjectInfo projectInfo) {
    return projectInfo.buildFileIdentifiers.contains(_flutterPackageBuildFileIdentifier);
  }

  List<String> _migrateBuildFile(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isBuildFilesMigrated(projectInfo)) {
      logger.printTrace('PBXBuildFile already migrated. Skipping...');
      return lines;
    }

    final String? nextKey = _nextKeyInSortedList(
      _flutterPackageBuildFileIdentifier,
      projectInfo.buildFileIdentifiers,
    );

    const String newContent =
        '		$_flutterPackageBuildFileIdentifier /* FlutterPackage in Frameworks */ = {isa = PBXBuildFile; productRef = $_flutterPackageProductDependencyIdentifer /* FlutterPackage */; };';

    return _insertAlphabeticallyInSection(
      lines: lines,
      sectionName: 'PBXBuildFile',
      newContent: <String>[newContent],
      nextKey: nextKey,
    );
  }

  bool _isFileReferenceMigrated(ParsedProjectInfo projectInfo) {
    return projectInfo.fileReferenceIndentifiers
        .contains(flutterPackageFileReferenceIdentifier);
  }

  List<String> _migrateFileReference(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isFileReferenceMigrated(projectInfo)) {
      logger.printTrace('PBXFileReference already migrated. Skipping...');
      return lines;
    }

    final String newContent;
    if (_platform == SupportedPlatform.ios) {
      newContent =
        '		$flutterPackageFileReferenceIdentifier /* FlutterPackage */ = {isa = PBXFileReference; lastKnownFileType = wrapper; name = FlutterPackage; path = Flutter/Packages/FlutterPackage; sourceTree = "<group>"; };';
    } else {
      newContent =
        '		$flutterPackageFileReferenceIdentifier /* FlutterPackage */ = {isa = PBXFileReference; lastKnownFileType = wrapper; name = FlutterPackage; path = Packages/FlutterPackage; sourceTree = "<group>"; };';
    }


    final String? nextKey = _nextKeyInSortedList(
      flutterPackageFileReferenceIdentifier,
      projectInfo.fileReferenceIndentifiers,
    );

    return _insertAlphabeticallyInSection(
      lines: lines,
      sectionName: 'PBXFileReference',
      newContent: <String>[newContent],
      nextKey: nextKey,
    );
  }

  bool _isFrameworksBuildPhaseMigrated(ParsedProjectInfo projectInfo) {
    return projectInfo.frameworksBuildPhases
        .where((ParsedProjectFrameworksBuildPhase phase) =>
            phase.identifier == _runnerFrameworksBuildPhaseIdentifer &&
            phase.files != null &&
            phase.files!.contains(_flutterPackageBuildFileIdentifier))
        .toList()
        .isNotEmpty;
  }

  List<String> _migrateFrameworksBuildPhase(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isFrameworksBuildPhaseMigrated(projectInfo)) {
      logger.printTrace('PBXFrameworksBuildPhase already migrated. Skipping...');
      return lines;
    }

    // Add Packages group as a child of the Flutter group

    final ParsedProjectFrameworksBuildPhase? runnerFrameworksPhase = projectInfo
        .frameworksBuildPhases
        .where((ParsedProjectFrameworksBuildPhase phase) =>
            phase.identifier == _runnerFrameworksBuildPhaseIdentifer)
        .toList()
        .firstOrNull;
    if (runnerFrameworksPhase == null) {
      throw Exception('Unable to find PBXFrameworksBuildPhase $_runnerFrameworksBuildPhaseIdentifer');
    }

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('PBXFrameworksBuildPhase', lines);

    final int runnerFrameworksPhaseStartIndex = lines.indexWhere(
      (String line) => line.trim().startsWith(_runnerFrameworksBuildPhaseIdentifer),
      startSectionIndex,
    );
    if (runnerFrameworksPhaseStartIndex == -1 ||
        runnerFrameworksPhaseStartIndex > endSectionIndex) {
      throw Exception('Unable to find PBXFrameworksBuildPhase $_runnerFrameworksBuildPhaseIdentifer');
    }

    final int startFilesIndex = lines.indexWhere(
        (String line) => line.trim().contains('files'), runnerFrameworksPhaseStartIndex);
    const String newContent =
        '				$_flutterPackageBuildFileIdentifier /* FlutterPackage in Frameworks */,';
    lines.insert(startFilesIndex + 1, newContent);

    return lines;
  }

  bool _isGroupsMigrated(ParsedProjectInfo projectInfo) {
    return projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterPackagesGroupIdentifier)
        .toList()
        .isNotEmpty &&
        projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterGroupIdentifier &&
            group.children != null &&
            group.children!.contains(_flutterPackagesGroupIdentifier))
        .toList()
        .isNotEmpty;
  }

  List<String> _migrateGroupPackages(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isGroupsMigrated(projectInfo)) {
      logger.printTrace('PBXGroup already migrated. Skipping...');
      return lines;
    }

    // Add Packages group if it doesn't already exist
    if (projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterPackagesGroupIdentifier)
        .toList()
        .isEmpty) {
      // The Package group is not exist yet, add it
      const List<String> newContent = <String>[
        '		$_flutterPackagesGroupIdentifier /* Packages */ = {',
        '			isa = PBXGroup;',
        '			children = (',
        '				$flutterPackageFileReferenceIdentifier /* FlutterPackage */,',
        '			);',
        '			name = Packages;',
        '			sourceTree = "<group>";',
        '		};',
      ];

      final String? nextKey = _nextKeyInSortedList(
        _flutterPackagesGroupIdentifier,
        projectInfo.parsedGroups.map((ParsedProjectGroup group) => group.identifier).toList(),
      );

      lines = _insertAlphabeticallyInSection(
        lines: lines,
        sectionName: 'PBXGroup',
        newContent: newContent,
        nextKey: nextKey,
      );
    }

    // Add Packages group as a child of the Flutter group
    final ParsedProjectGroup? flutterGroup = projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterGroupIdentifier)
        .toList()
        .firstOrNull;
    if (flutterGroup == null) {
      throw Exception('Unable to find PBXGroup $_flutterGroupIdentifier');
    }

    // Skip if already a child
    if (flutterGroup.children != null &&
        flutterGroup.children!.contains(_flutterPackagesGroupIdentifier)) {
      return lines;
    }

    final (int flutterGroupStartIndex, int flutterGroupEndIndex) = _subSectionRange(
      sectionName: 'PBXGroup',
      identifer: _flutterGroupIdentifier,
      compareList: projectInfo.parsedGroups.map((ParsedProjectGroup group) => group.identifier).toList(),
      lines: lines,
    );

    final int startChildrenIndex = lines.indexWhere(
        (String line) => line.trim().contains('children'), flutterGroupStartIndex);
    if (startChildrenIndex == -1 || startChildrenIndex > flutterGroupEndIndex) {
      throw Exception('Unable to find children of $_flutterGroupIdentifier');
    }
    const String newContent = '				$_flutterPackagesGroupIdentifier /* Packages */,';
    lines.insert(startChildrenIndex + 1, newContent);

    return lines;
  }

  bool _isNativeTargetMigrated(ParsedProjectInfo projectInfo) {
    return projectInfo.nativeTargets
        .where((ParsedNativeTarget target) =>
            target.identifier == _runnerNativeTargetIdentifer &&
            target.packageProductDependencies != null &&
            target.packageProductDependencies!.contains(_flutterPackageProductDependencyIdentifer))
        .toList()
        .isNotEmpty;
  }

  List<String> _migrateNativeTarget(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isNativeTargetMigrated(projectInfo)) {
      logger.printTrace('PBXNativeTarget already migrated. Skipping...');
      return lines;
    }
    final ParsedNativeTarget? runnerNativeTarget = projectInfo.nativeTargets
        .where((ParsedNativeTarget target) =>
            target.identifier == _runnerNativeTargetIdentifer)
        .toList()
        .firstOrNull;
    if (runnerNativeTarget == null) {
      throw Exception(
          'Unable to find PBXNativeTarget $_runnerNativeTargetIdentifer');
    }

    final List<String>? packageProductDependencies =
        runnerNativeTarget.packageProductDependencies;

    if (packageProductDependencies != null &&
        packageProductDependencies.contains(_flutterPackageProductDependencyIdentifer)) {
      return lines;
    }

    final (int runnerNativeTargetStartIndex, int runnerNativeTargetEndIndex) = _subSectionRange(
      sectionName: 'PBXNativeTarget',
      identifer: _runnerNativeTargetIdentifer,
      compareList: projectInfo.nativeTargets.map((ParsedNativeTarget target) => target.identifier).toList(),
      lines: lines,
    );

    if (packageProductDependencies != null) {
      // There are preexisting dependencies, add to it
      const String newContent =
          '				$_flutterPackageProductDependencyIdentifer /* FlutterPackage */,';
      final int startDependenciesIndex = lines.indexWhere(
          (String line) => line.trim().contains('packageProductDependencies'),
          runnerNativeTargetStartIndex);
      lines.insert(startDependenciesIndex + 1, newContent);
    } else {
      // insert it
      final String? nextKey = _nextKeyInSortedList(
        'packageProductDependencies',
        runnerNativeTarget.data.keys.toList(),
      );
      const List<String> newContent = <String>[
        '			packageProductDependencies = (',
        '				$_flutterPackageProductDependencyIdentifer /* FlutterPackage */,',
        '			);',
      ];
      if (nextKey != null) {
        final int index = lines.indexWhere(
            (String line) => line.trim().startsWith(nextKey), runnerNativeTargetStartIndex);
        lines.insertAll(index, newContent);
      } else {
        lines.insertAll(runnerNativeTargetEndIndex, newContent);
      }
    }
    return lines;
  }

  bool _isSwiftPackageProductDependencyMigrated(ParsedProjectInfo projectInfo) {
    return projectInfo.swiftPackageProductDependencies
            .contains(_flutterPackageProductDependencyIdentifer);
  }

  bool _isProjectObjectMigrated(ParsedProjectInfo projectInfo, bool xcode15,) {
    return !xcode15 || projectInfo.projects
        .where((ParsedProject target) =>
            target.identifier == _projectIdentifier &&
            target.packageReferences != null &&
            target.packageReferences!.contains(_localSwiftPackageReferenceIdentifer))
        .toList()
        .isNotEmpty;
  }

  List<String> _migrateProjectObject(
    List<String> lines,
    ParsedProjectInfo projectInfo,
    bool xcode15,
  ) {
    if (_isProjectObjectMigrated(projectInfo, xcode15)) {
      logger.printTrace('PBXProject already migrated. Skipping...');
      return lines;
    }
    final ParsedProject? projectObject = projectInfo.projects
        .where((ParsedProject target) =>
            target.identifier == _projectIdentifier)
        .toList()
        .firstOrNull;
    if (projectObject == null) {
      throw Exception(
          'Unable to find PBXProject $_projectIdentifier');
    }

    final List<String>? packageReferences =
        projectObject.packageReferences;

    if (packageReferences != null &&
        packageReferences.contains(_localSwiftPackageReferenceIdentifer)) {
      return lines;
    }

    final (int projectStartIndex, int projectEndIndex) = _subSectionRange(
      sectionName: 'PBXProject',
      identifer: _projectIdentifier,
      compareList: projectInfo.projects.map((ParsedProject target) => target.identifier).toList(),
      lines: lines,
    );

    if (packageReferences != null) {
      // There are preexisting references, add to it
      const String newContent =
          '				$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */,';
      final int startDependenciesIndex = lines.indexWhere(
          (String line) => line.trim().contains('packageReferences'),
          projectStartIndex);
      lines.insert(startDependenciesIndex + 1, newContent);
    } else {
      // insert it
      final String? nextKey = _nextKeyInSortedList(
        'packageReferences',
        projectObject.data.keys.toList(),
      );
      const List<String> newContent = <String>[
        '			packageReferences = (',
        '				$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */,',
        '			);',
      ];
      if (nextKey != null) {
        final int index = lines.indexWhere(
            (String line) => line.trim().startsWith(nextKey), projectStartIndex);
        lines.insertAll(index, newContent);
      } else {
        lines.insertAll(projectEndIndex, newContent);
      }
    }
    return lines;
  }


  List<String> _migratePackageProductDependencies(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isSwiftPackageProductDependencyMigrated(projectInfo)) {
      logger.printTrace('XCSwiftPackageProductDependency already migrated. Skipping...');
      return lines;
    }

    final (int startSectionIndex, _) = _sectionRange('XCSwiftPackageProductDependency', lines, validateExistance: false);

    if (startSectionIndex == -1) {
      // There isn't a XCSwiftPackageProductDependency section yet, so add it

      final String? nextKey = _nextKeyInSortedList(
        'XCSwiftPackageProductDependency',
        projectInfo.isaTypes,
      );

      final List<String> newContent = <String>[
        '/* Begin XCSwiftPackageProductDependency section */',
        '		$_flutterPackageProductDependencyIdentifer /* FlutterPackage */ = {',
        '			isa = XCSwiftPackageProductDependency;',
        '			productName = FlutterPackage;',
        '		};',
        '/* End XCSwiftPackageProductDependency section */',
      ];

      if (nextKey != null) {
        final int index = lines
            .indexWhere((String line) => line.startsWith('/* Begin $nextKey'));
        if (index == -1) {
          throw Exception('Unable to find section $nextKey');
        }
        lines.insertAll(index, newContent);
      } else {
        final int index = lines.indexWhere((String line) =>
            line.startsWith('/* End ${projectInfo.isaTypes.last}'));
        if (index == -1) {
          throw Exception(
              'Unable to find section ${projectInfo.isaTypes.last}');
        }
        lines.insertAll(index + 1, newContent);
      }
    } else {
      final String? nextKey = _nextKeyInSortedList(
        _flutterPackageProductDependencyIdentifer,
        projectInfo.swiftPackageProductDependencies,
      );

      final List<String> newContent = <String>[
        '		$_flutterPackageProductDependencyIdentifer /* FlutterPackage */ = {',
        '			isa = XCSwiftPackageProductDependency;',
        '			productName = FlutterPackage;',
        '		};',
      ];

      return _insertAlphabeticallyInSection(
        lines: lines,
        sectionName: 'XCSwiftPackageProductDependency',
        newContent: newContent,
        nextKey: nextKey,
      );
    }

    return lines;
  }

  bool _isLocalSwiftPackageProductDependencyMigrated(
    ParsedProjectInfo projectInfo,
    bool xcode15,
  ) {
    return !xcode15 || projectInfo.localSwiftPackageProductDependencies
            .contains(_localSwiftPackageReferenceIdentifer);
  }

  List<String> _migrateLocalPackageProductDependencies(
    List<String> lines,
    ParsedProjectInfo projectInfo,
    bool xcode15,
  ) {
    if (_isLocalSwiftPackageProductDependencyMigrated(projectInfo, xcode15)) {
      logger.printTrace('XCLocalSwiftPackageReference already migrated or not needed. Skipping...');
      return lines;
    }

    final (int startSectionIndex, _) = _sectionRange('XCLocalSwiftPackageReference', lines, validateExistance: false);

    if (startSectionIndex == -1) {
      // There isn't a XCLocalSwiftPackageReference section yet, so add it

      final String? nextKey = _nextKeyInSortedList(
        'XCLocalSwiftPackageReference',
        projectInfo.isaTypes,
      );

      final List<String> newContent = <String>[
        '/* Begin XCLocalSwiftPackageReference section */',
        '		$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */ = {',
        '			isa = XCLocalSwiftPackageReference;',
        '			relativePath = Flutter/Packages/FlutterPackage;',
        '		};',
        '/* End XCLocalSwiftPackageReference section */',
      ];

      if (nextKey != null) {
        final int index = lines
            .indexWhere((String line) => line.startsWith('/* Begin $nextKey'));
        if (index == -1) {
          throw Exception('Unable to find section $nextKey');
        }
        lines.insertAll(index, newContent);
      } else {
        final int index = lines.indexWhere((String line) =>
            line.startsWith('/* End ${projectInfo.isaTypes.last}'));
        if (index == -1) {
          throw Exception(
              'Unable to find section ${projectInfo.isaTypes.last}');
        }
        lines.insertAll(index + 1, newContent);
      }
    } else {
      final String? nextKey = _nextKeyInSortedList(
        _localSwiftPackageReferenceIdentifer,
        projectInfo.localSwiftPackageProductDependencies,
      );

      final List<String> newContent = <String>[
        '		$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */ = {',
        '			isa = XCLocalSwiftPackageReference;',
        '			relativePath = Flutter/Packages/FlutterPackage;',
        '		};',
      ];

      return _insertAlphabeticallyInSection(
        lines: lines,
        sectionName: 'XCLocalSwiftPackageReference',
        newContent: newContent,
        nextKey: nextKey,
      );
    }

    return lines;
  }


  String? _nextKeyInSortedList(String compareTo, List<String> compareList) {
    for (final String value in compareList) {
      final int comparison = value.compareTo(compareTo);
      if (comparison > 0) {
        return value;
      }
    }
    return null;
  }

  (int, int) _sectionRange(String sectionName, List<String> lines, {bool validateExistance = true}) {
    final int startSectionIndex = lines.indexOf('/* Begin $sectionName section */');
    final int endSectionIndex = lines.indexOf('/* End $sectionName section */');
    if (validateExistance && (startSectionIndex == -1 || endSectionIndex == -1 || startSectionIndex > endSectionIndex)) {
      throw Exception('Unable to find $sectionName section');
    }
    return (startSectionIndex, endSectionIndex);
  }

  (int, int) _subSectionRange({
    required String sectionName,
    required String identifer,
    required List<String> lines,
    required List<String> compareList,
  }) {
    final (int startSectionIndex, int endSectionIndex) = _sectionRange(sectionName, lines);

    final RegExp regex = RegExp('\\s*$identifer.*?{');
    final int startIndex = lines.indexWhere(
      (String line) => regex.hasMatch(line),
      startSectionIndex,
    );
    if (startIndex == -1 || startIndex > endSectionIndex) {
      throw Exception('Unable to find $sectionName $identifer');
    }

    final String? nextKey = _nextKeyInSortedList(
      identifer,
      compareList,
    );

    final int endIndex;
    if (nextKey != null) {
      final int index = lines.indexWhere(
            (String line) => line.trim().startsWith(nextKey), startIndex);
      if (index == -1 || index > endSectionIndex) {
        throw Exception('Unable to find $sectionName $nextKey');
      }
      endIndex = index - 1;
    } else {
      endIndex = endSectionIndex - 1;
    }

    return (startIndex, endIndex);
  }

  List<String> _insertAlphabeticallyInSection({
    required String sectionName,
    String? nextKey,
    required List<String> newContent,
    required List<String> lines,
  }) {
    final (int startSectionIndex, int endSectionIndex) = _sectionRange(sectionName, lines);
    // Put new content in before key that's next in alphabetical order.
    // Or put at end of list before the section end if there's no next key.

    final RegExp regex = RegExp('\\s*$nextKey.*?{');
    if (nextKey != null) {
      final int index = lines.indexWhere(
        (String line) => regex.hasMatch(line),
        startSectionIndex,
      );
      if (index == -1 || index > endSectionIndex) {
        throw Exception('Unable to find $sectionName $nextKey');
      }
      lines.insertAll(index, newContent);
    } else {
      lines.insertAll(endSectionIndex, newContent);
    }

    return lines;
  }
}


class ParsedProjectInfo {
  ParsedProjectInfo._({
    required this.isaTypes,
    required this.buildFileIdentifiers,
    required this.fileReferenceIndentifiers,
    required this.parsedGroups,
    required this.frameworksBuildPhases,
    required this.nativeTargets,
    required this.projects,
    required this.swiftPackageProductDependencies,
    required this.localSwiftPackageProductDependencies,
  });

  factory ParsedProjectInfo.fromJson(Map<String, Object?> data) {
    final List<String> buildFiles = <String>[];
    final List<String> references = <String>[];
    final List<ParsedProjectGroup> groups = <ParsedProjectGroup>[];
    final List<ParsedProjectFrameworksBuildPhase> buildPhases =
        <ParsedProjectFrameworksBuildPhase>[];
    final List<ParsedNativeTarget> native = <ParsedNativeTarget>[];
    final List<ParsedProject> project = <ParsedProject>[];
    final List<String> parsedSwiftPackageProductDependencies = <String>[];
    final List<String> parsedLocalSwiftPackageProductDependencies = <String>[];
    final Set<String> keyTypes = <String>{};

    if (data['objects'] is Map<String, Object?>) {
      final Map<String, Object?> values =
          data['objects']! as Map<String, Object?>;
      for (final String key in values.keys) {
        if (values[key] is Map<String, Object?>) {
          final Map<String, Object?> details =
              values[key]! as Map<String, Object?>;
          if (details['isa'] is String) {
            final String objectType = details['isa']! as String;
            keyTypes.add(objectType);
            if (objectType == 'PBXBuildFile') {
              buildFiles.add(key);
            } else if (objectType == 'PBXFileReference') {
              references.add(key);
            } else if (objectType == 'PBXGroup') {
              groups.add(ParsedProjectGroup.fromJson(key, details));
            } else if (objectType == 'PBXFrameworksBuildPhase') {
              buildPhases.add(
                  ParsedProjectFrameworksBuildPhase.fromJson(key, details));
            } else if (objectType == 'PBXNativeTarget') {
              native.add(ParsedNativeTarget.fromJson(key, details));
            } else if (objectType == 'PBXProject') {
              project.add(ParsedProject.fromJson(key, details));
            } else if (objectType == 'XCSwiftPackageProductDependency') {
              parsedSwiftPackageProductDependencies.add(key);
            } else if (objectType == 'XCLocalSwiftPackageReference') {
              parsedLocalSwiftPackageProductDependencies.add(key);
            }
          }
        }
      }
    }

    buildFiles.sort();
    references.sort();
    groups.sort((ParsedProjectGroup a, ParsedProjectGroup b) =>
        a.identifier.compareTo(b.identifier));
    final List<String> asdf = keyTypes.toList();
    asdf.sort();
    parsedSwiftPackageProductDependencies.sort();
    return ParsedProjectInfo._(
      isaTypes: asdf,
      buildFileIdentifiers: buildFiles,
      fileReferenceIndentifiers: references,
      parsedGroups: groups,
      frameworksBuildPhases: buildPhases,
      nativeTargets: native,
      projects: project,
      swiftPackageProductDependencies: parsedSwiftPackageProductDependencies,
      localSwiftPackageProductDependencies: parsedLocalSwiftPackageProductDependencies,
    );
  }

  List<String> isaTypes;

  // PBXBuildFile
  List<String> buildFileIdentifiers;

  // PBXFileReference
  List<String> fileReferenceIndentifiers;

  // PBXGroup
  List<ParsedProjectGroup> parsedGroups;

  // PBXFrameworksBuildPhase
  List<ParsedProjectFrameworksBuildPhase> frameworksBuildPhases;

  // PBXNativeTarget
  List<ParsedNativeTarget> nativeTargets;

  // PBXProject
  List<ParsedProject> projects;

  // XCSwiftPackageProductDependency
  List<String> swiftPackageProductDependencies;

  // XCLocalSwiftPackageReference
  List<String> localSwiftPackageProductDependencies;
}

class ParsedProjectGroup {
  ParsedProjectGroup._(this.identifier, this.children);

  factory ParsedProjectGroup.fromJson(String key, Map<String, Object?> data) {
    final List<String> parsedChildren = <String>[];
    if (data['children'] is List<Object?>) {
      for (final Object? item in data['children']! as List<Object?>) {
        if (item is String) {
          parsedChildren.add(item);
        }
      }
      return ParsedProjectGroup._(key, parsedChildren);
    }
    return ParsedProjectGroup._(key, null);
  }

  final String identifier;
  final List<String>? children;
}

class ParsedProjectFrameworksBuildPhase {
  ParsedProjectFrameworksBuildPhase._(this.identifier, this.files);

  factory ParsedProjectFrameworksBuildPhase.fromJson(
      String key, Map<String, Object?> data) {
    final List<String> parsedFiles = <String>[];
    if (data['files'] is List<Object?>) {
      for (final Object? item in data['files']! as List<Object?>) {
        if (item is String) {
          parsedFiles.add(item);
        }
      }
      return ParsedProjectFrameworksBuildPhase._(key, parsedFiles);
    }
    return ParsedProjectFrameworksBuildPhase._(key, null);
  }

  final String identifier;
  final List<String>? files;
}

class ParsedNativeTarget {
  ParsedNativeTarget._(
      this.data, this.identifier, this.packageProductDependencies,);

  factory ParsedNativeTarget.fromJson(String key, Map<String, Object?> data) {
    final List<String> parsedChildren = <String>[];
    if (data['packageProductDependencies'] is List<Object?>) {
      for (final Object? item
          in data['packageProductDependencies']! as List<Object?>) {
        if (item is String) {
          parsedChildren.add(item);
        }
      }
      return ParsedNativeTarget._(data, key, parsedChildren);
    }
    return ParsedNativeTarget._(data, key, null);
  }

  final Map<String, Object?> data;
  final String identifier;
  final List<String>? packageProductDependencies;
}

class ParsedProject {
  ParsedProject._(
      this.data, this.identifier, this.packageReferences,);

  factory ParsedProject.fromJson(String key, Map<String, Object?> data) {
    final List<String> parsedChildren = <String>[];
    if (data['packageReferences'] is List<Object?>) {
      for (final Object? item
          in data['packageReferences']! as List<Object?>) {
        if (item is String) {
          parsedChildren.add(item);
        }
      }
      return ParsedProject._(data, key, parsedChildren);
    }
    return ParsedProject._(data, key, null);
  }

  final Map<String, Object?> data;
  final String identifier;
  final List<String>? packageReferences;
}
