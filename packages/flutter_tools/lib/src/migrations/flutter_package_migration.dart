// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:process/process.dart';

import '../base/common.dart';
import '../base/error_handling_io.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/project_migrator.dart';
import '../base/version.dart';
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

  void _restoreFromBackup() {
    if (backupProjectSettings.existsSync()) {
      logger.printError('Restoring project settings from backup file...');
      backupProjectSettings.copySync(_xcodeProject.xcodeProjectInfoFile.path);
    }
  }

  @override
  Future<void> migrate() async {
    try {
      if (!_xcodeProjectInfoFile.existsSync()) {
        throw Exception('Xcode project not found.');
      }

      // Update gitignore. If unable to update the platform specific gitignore,
      // try updating the app gitignore.
      if (!_updateGitIgnore(_xcodeProject.hostAppRoot.childFile('.gitignore'))) {
        _updateGitIgnore(_xcodeProject.parent.directory.childFile('.gitignore'));
      }

      final Version? version = _xcodeProjectInterpreter.version;

      bool xcode15 = true;

      // If Xcode not installed or less than 15, skip this migration.
      if (version == null || version < Version(15, 0, 0)) {
        xcode15 = false;
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
      lines = _migrateGroups(lines, parsedInfo);
      lines = _migrateNativeTarget(lines, parsedInfo);
      lines = _migrateProjectObject(lines, parsedInfo, xcode15);
      lines = _migrateLocalPackageProductDependencies(lines, parsedInfo, xcode15);
      lines = _migratePackageProductDependencies(lines, parsedInfo);

      final String newProjectContents = '${lines.join('\n')}\n';

      if (originalProjectContents != newProjectContents) {
        logger.printStatus('Creating backup project settings...');
        _xcodeProjectInfoFile.copySync(backupProjectSettings.path);

        logger.printStatus('Adding Flutter Package as a dependency...');
        _xcodeProjectInfoFile.writeAsStringSync(newProjectContents);

        // Re-parse the project settings to check for syntax errors
        final ParsedProjectInfo updatedInfo = _parseResults();

        if (!_isMigrated(updatedInfo, xcode15, logErrorIfNotMigrated: true)) {
          throw Exception('Settings were not updated correctly.');
        }

        // Get the build settings to make sure it compiles
        await _xcodeProjectInterpreter.getInfo(
          _xcodeProject.hostAppRoot.path,
        );
      }
    } on Exception catch (e) {
      logger.printError('An error occured when migrating your project to Swift Package Manager: $e');
      _restoreFromBackup();
      // TODO: SPM - instructions
      throwToolExit('Failed to convert your project to use Swift Package Manager. Please follow instructions found at xxx to manually convert your project.');
    } finally {
      ErrorHandlingFileSystem.deleteIfExists(backupProjectSettings);
    }
  }

  bool _updateGitIgnore(File gitignore) {
    // TODO: SPM, should add if not exists?
    if (!gitignore.existsSync()) {
      return false;
    }
    final String originalProjectContents = gitignore.readAsStringSync();
    if (originalProjectContents.contains('**/Flutter/Packages/FlutterPackage/')) {
      return true;
    }
    String newProjectContents = originalProjectContents;
    if (originalProjectContents.contains('**/Pods/')) {
      newProjectContents = newProjectContents.replaceFirst('**/Pods/', '**/Pods/\n**/Flutter/Packages/FlutterPackage/');
    } else {
      newProjectContents = '$newProjectContents\n**/Flutter/Packages/FlutterPackage/\n';
    }

    if (originalProjectContents != newProjectContents) {
      logger.printTrace('Adding FlutterPackage to ${gitignore.dirname}/${gitignore.basename}...');
      gitignore.writeAsStringSync(newProjectContents);
    }
    return true;
  }

  /// Parses the project.pbxproj into JSON.
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

  bool _isMigrated(ParsedProjectInfo projectInfo, bool xcode15, {bool logErrorIfNotMigrated = false}) {
    return _isBuildFilesMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isFileReferenceMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isFrameworksBuildPhaseMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isGroupsMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isNativeTargetMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isProjectObjectMigrated(projectInfo, xcode15, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isLocalSwiftPackageProductDependencyMigrated(projectInfo, xcode15, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isSwiftPackageProductDependencyMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated);
  }

  bool _isBuildFilesMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.buildFileIdentifiers.contains(_flutterPackageBuildFileIdentifier);
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('PBXBuildFile not migrated');
    }
    return migrated;
  }

  List<String> _migrateBuildFile(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isBuildFilesMigrated(projectInfo)) {
      logger.printTrace('PBXBuildFile already migrated. Skipping...');
      return lines;
    }

    const String newContent =
        '		$_flutterPackageBuildFileIdentifier /* FlutterPackage in Frameworks */ = {isa = PBXBuildFile; productRef = $_flutterPackageProductDependencyIdentifer /* FlutterPackage */; };';

    final (int _, int endSectionIndex) = _sectionRange('PBXBuildFile', lines);

    lines.insert(endSectionIndex, newContent);
    return lines;
  }

  bool _isFileReferenceMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.fileReferenceIndentifiers
        .contains(flutterPackageFileReferenceIdentifier);
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('PBXFileReference not migrated');
    }
    return migrated;
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

    final (int _, int endSectionIndex) = _sectionRange('PBXFileReference', lines);

    lines.insert(endSectionIndex, newContent);
    return lines;
  }

  bool _isFrameworksBuildPhaseMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.frameworksBuildPhases
        .where((ParsedProjectFrameworksBuildPhase phase) =>
            phase.identifier == _runnerFrameworksBuildPhaseIdentifer &&
            phase.files != null &&
            phase.files!.contains(_flutterPackageBuildFileIdentifier))
        .toList()
        .isNotEmpty;
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('PBXFrameworksBuildPhase not migrated');
    }
    return migrated;
  }

  List<String> _migrateFrameworksBuildPhase(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isFrameworksBuildPhaseMigrated(projectInfo)) {
      logger.printTrace('PBXFrameworksBuildPhase already migrated. Skipping...');
      return lines;
    }

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('PBXFrameworksBuildPhase', lines);

    // Find index where Frameworks Build Phase for the Runner target begins.
    final int runnerFrameworksPhaseStartIndex = lines.indexWhere(
      (String line) => line.trim().startsWith('$_runnerFrameworksBuildPhaseIdentifer /* Frameworks */ = {'),
      startSectionIndex,
    );
    if (runnerFrameworksPhaseStartIndex == -1 ||
        runnerFrameworksPhaseStartIndex > endSectionIndex) {
      throw Exception('Unable to find PBXFrameworksBuildPhase for ${_xcodeProject.hostAppProjectName} target');
    }

    // Get the Frameworks Build Phase for the Runner target from the parsed project info.
    final ParsedProjectFrameworksBuildPhase? runnerFrameworksPhase = projectInfo
        .frameworksBuildPhases
        .where((ParsedProjectFrameworksBuildPhase phase) =>
            phase.identifier == _runnerFrameworksBuildPhaseIdentifer)
        .toList()
        .firstOrNull;
    if (runnerFrameworksPhase == null) {
      throw Exception('Unable to find parsed PBXFrameworksBuildPhase for ${_xcodeProject.hostAppProjectName} target');
    }

    if (runnerFrameworksPhase.files == null) {
      // If files is null, the files field is missing and must be added.
      const String newContent = '''
			files = (
				$_flutterPackageBuildFileIdentifier /* FlutterPackage in Frameworks */,
			);''';
      lines.insert(runnerFrameworksPhaseStartIndex + 1, newContent);
    } else {
      // Find the files field within the Frameworks PBXFrameworksBuildPhase for the Runner target.
      final int startFilesIndex = lines.indexWhere(
          (String line) => line.trim().contains('files'), runnerFrameworksPhaseStartIndex);
      const String newContent =
          '				$_flutterPackageBuildFileIdentifier /* FlutterPackage in Frameworks */,';
      lines.insert(startFilesIndex + 1, newContent);
    }

    return lines;
  }

  bool _isGroupsMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    return _isPackagesGroupMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated) &&
        _isFlutterGroupMigrated(projectInfo, logErrorIfNotMigrated: logErrorIfNotMigrated);
  }

  bool _isPackagesGroupMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterPackagesGroupIdentifier)
        .toList()
        .isNotEmpty;
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('Packages PBXGroup not migrated');
    }
    return migrated;
  }

  bool _isFlutterGroupMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterGroupIdentifier &&
            group.children != null &&
            group.children!.contains(_flutterPackagesGroupIdentifier))
        .toList()
        .isNotEmpty;
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('Flutter PBXGroup not migrated');
    }
    return migrated;
  }

  List<String> _migrateGroups(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isGroupsMigrated(projectInfo)) {
      logger.printTrace('PBXGroup already migrated. Skipping...');
      return lines;
    }

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('PBXGroup', lines);

    lines = _migratePackagesGroup(lines, projectInfo, endSectionIndex);
    lines = _migrateFlutterGroup(lines, projectInfo, startSectionIndex, endSectionIndex);

    return lines;
  }

  List<String> _migratePackagesGroup(
    List<String> lines,
    ParsedProjectInfo projectInfo,
    int endSectionIndex,
  ) {
    if (_isPackagesGroupMigrated(projectInfo)) {
      logger.printTrace('Packages Group already migrated. Skipping...');
      return lines;
    }

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

    lines.insertAll(endSectionIndex, newContent);

    return lines;
  }

  List<String> _migrateFlutterGroup(
    List<String> lines,
    ParsedProjectInfo projectInfo,
    int startSectionIndex,
    int endSectionIndex,
  ) {
    if (_isFlutterGroupMigrated(projectInfo)) {
      logger.printTrace('Flutter Group already migrated. Skipping...');
      return lines;
    }

    // Find index where Flutter Group begins.
    final ParsedProjectGroup? flutterGroup = projectInfo.parsedGroups
        .where((ParsedProjectGroup group) =>
            group.identifier == _flutterGroupIdentifier).firstOrNull;
    if (flutterGroup == null) {
      throw Exception('Unable to find parsed Flutter PBXGroup');
    }

    final String subsectionLineStart = flutterGroup.name != null ? '$_flutterGroupIdentifier /* ${flutterGroup.name} */ = {' : _flutterGroupIdentifier;
    final int flutterGroupStartIndex = lines.indexWhere(
      (String line) => line.trim().startsWith(subsectionLineStart),
      startSectionIndex,
    );
    if (flutterGroupStartIndex == -1 ||
        flutterGroupStartIndex > endSectionIndex) {
      throw Exception('Unable to find Flutter PBXGroup');
    }

    // Find the children field within the Flutter Group.
    final int startChildrenIndex = lines.indexWhere(
        (String line) => line.trim().contains('children'), flutterGroupStartIndex);

    const String newContent = '				$_flutterPackagesGroupIdentifier /* Packages */,';
    lines.insert(startChildrenIndex + 1, newContent);

    return lines;
  }

  bool _isNativeTargetMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.nativeTargets
        .where((ParsedNativeTarget target) =>
            target.identifier == _runnerNativeTargetIdentifer &&
            target.packageProductDependencies != null &&
            target.packageProductDependencies!.contains(_flutterPackageProductDependencyIdentifer))
        .toList()
        .isNotEmpty;
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('PBXNativeTarget not migrated');
    }
    return migrated;
  }

  List<String> _migrateNativeTarget(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isNativeTargetMigrated(projectInfo)) {
      logger.printTrace('PBXNativeTarget already migrated. Skipping...');
      return lines;
    }

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('PBXNativeTarget', lines);

    // Get the Native Target for the Runner target from the parsed project info.
    final ParsedNativeTarget? runnerNativeTarget = projectInfo.nativeTargets
        .where((ParsedNativeTarget target) =>
            target.identifier == _runnerNativeTargetIdentifer)
        .firstOrNull;
    if (runnerNativeTarget == null) {
      throw Exception('Unable to find parsed PBXNativeTarget for ${_xcodeProject.hostAppProjectName} target');
    }

    // Find index where Native Target for the Runner target begins.
    final String subsectionLineStart = runnerNativeTarget.name != null ? '$_runnerNativeTargetIdentifer /* ${runnerNativeTarget.name} */ = {' : _runnerNativeTargetIdentifer;
    final int runnerNativeTargetStartIndex = lines.indexWhere(
      (String line) => line.trim().startsWith(subsectionLineStart),
      startSectionIndex,
    );
    if (runnerNativeTargetStartIndex == -1 ||
        runnerNativeTargetStartIndex > endSectionIndex) {
      throw Exception('Unable to find PBXNativeTarget for ${_xcodeProject.hostAppProjectName} target');
    }

    if (runnerNativeTarget.packageProductDependencies == null) {
      // If packageProductDependencies is null, the packageProductDependencies field is missing and must be added.
      const List<String> newContent = <String>[
        '			packageProductDependencies = (',
        '				$_flutterPackageProductDependencyIdentifer /* FlutterPackage */,',
        '			);',
      ];
      lines.insertAll(runnerNativeTargetStartIndex + 1, newContent);
    } else {
      // Find the packageProductDependencies field within the Native Target for the Runner target.
      final int startDependenciesIndex = lines.indexWhere(
          (String line) => line.trim().contains('packageProductDependencies'),
          runnerNativeTargetStartIndex);
      const String newContent =
          '				$_flutterPackageProductDependencyIdentifer /* FlutterPackage */,';
      lines.insert(startDependenciesIndex + 1, newContent);
    }
    return lines;
  }

  /// Only applicable for Xcode 15
  bool _isProjectObjectMigrated(ParsedProjectInfo projectInfo, bool xcode15, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = !xcode15 || projectInfo.projects
        .where((ParsedProject target) =>
            target.identifier == _projectIdentifier &&
            target.packageReferences != null &&
            target.packageReferences!.contains(_localSwiftPackageReferenceIdentifer))
        .toList()
        .isNotEmpty;
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('PBXProject not migrated');
    }
    return migrated;
  }

  /// Only applicable for Xcode 15
  List<String> _migrateProjectObject(
    List<String> lines,
    ParsedProjectInfo projectInfo,
    bool xcode15,
  ) {
    if (_isProjectObjectMigrated(projectInfo, xcode15)) {
      logger.printTrace('PBXProject already migrated or not needed. Skipping...');
      return lines;
    }

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('PBXProject', lines);

    // Find index where Runner Project begins.
    final int projectStartIndex = lines.indexWhere(
      (String line) => line.trim().startsWith('$_projectIdentifier /* Project object */ = {'),
      startSectionIndex,
    );
    if (projectStartIndex == -1 ||
        projectStartIndex > endSectionIndex) {
      throw Exception('Unable to find PBXProject for ${_xcodeProject.hostAppProjectName}');
    }

    // Get the Runner project from the parsed project info.
    final ParsedProject? projectObject = projectInfo.projects
        .where((ParsedProject target) =>
            target.identifier == _projectIdentifier)
        .toList()
        .firstOrNull;
    if (projectObject == null) {
      throw Exception('Unable to find parsed PBXProject for ${_xcodeProject.hostAppProjectName} target');
    }

    if (projectObject.packageReferences == null) {
      // If packageReferences is null, the packageReferences field is missing and must be added.
      const List<String> newContent = <String>[
        '			packageReferences = (',
        '				$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */,',
        '			);',
      ];
      lines.insertAll(projectStartIndex + 1, newContent);
    } else {
      // Find the packageReferences field within the Runner project.
      final int startDependenciesIndex = lines.indexWhere(
          (String line) => line.trim().contains('packageReferences'),
          projectStartIndex);
      const String newContent =
          '				$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */,';
      lines.insert(startDependenciesIndex + 1, newContent);
    }
    return lines;
  }

  bool _isSwiftPackageProductDependencyMigrated(ParsedProjectInfo projectInfo, {bool logErrorIfNotMigrated = false}) {
    final bool migrated = projectInfo.swiftPackageProductDependencies
            .contains(_flutterPackageProductDependencyIdentifer);
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('XCSwiftPackageProductDependency not migrated');
    }
    return migrated;
  }

  List<String> _migratePackageProductDependencies(
    List<String> lines,
    ParsedProjectInfo projectInfo,
  ) {
    if (_isSwiftPackageProductDependencyMigrated(projectInfo)) {
      logger.printTrace('XCSwiftPackageProductDependency already migrated. Skipping...');
      return lines;
    }

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('XCSwiftPackageProductDependency', lines, throwIfMissing: false);

    if (startSectionIndex == -1) {
      // There isn't a XCSwiftPackageProductDependency section yet, so add it
      final List<String> newContent = <String>[
        '/* Begin XCSwiftPackageProductDependency section */',
        '		$_flutterPackageProductDependencyIdentifer /* FlutterPackage */ = {',
        '			isa = XCSwiftPackageProductDependency;',
        '			productName = FlutterPackage;',
        '		};',
        '/* End XCSwiftPackageProductDependency section */',
      ];

      final int index = lines.lastIndexWhere((String line) => line.trim().startsWith('/* End'));
      if (index == -1) {
        throw Exception('Unable to find any sections.');
      }
      lines.insertAll(index + 1, newContent);

      return lines;
    }

    final List<String> newContent = <String>[
      '		$_flutterPackageProductDependencyIdentifer /* FlutterPackage */ = {',
      '			isa = XCSwiftPackageProductDependency;',
      '			productName = FlutterPackage;',
      '		};',
    ];

    lines.insertAll(endSectionIndex, newContent);

    return lines;
  }

  bool _isLocalSwiftPackageProductDependencyMigrated(
    ParsedProjectInfo projectInfo,
    bool xcode15, {
    bool logErrorIfNotMigrated = false,
  }) {
    final bool migrated = !xcode15 || projectInfo.localSwiftPackageProductDependencies
            .contains(_localSwiftPackageReferenceIdentifer);
    if (logErrorIfNotMigrated && !migrated) {
      logger.printError('XCLocalSwiftPackageReference not migrated');
    }
    return migrated;
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

    final (int startSectionIndex, int endSectionIndex) = _sectionRange('XCLocalSwiftPackageReference', lines, throwIfMissing: false);

    if (startSectionIndex == -1) {
      // There isn't a XCLocalSwiftPackageReference section yet, so add it
      final List<String> newContent = <String>[
        '/* Begin XCLocalSwiftPackageReference section */',
        '		$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */ = {',
        '			isa = XCLocalSwiftPackageReference;',
        '			relativePath = Flutter/Packages/FlutterPackage;',
        '		};',
        '/* End XCLocalSwiftPackageReference section */',
      ];

      final int index = lines.lastIndexWhere((String line) => line.trim().startsWith('/* End'));
      if (index == -1) {
        throw Exception('Unable to find any sections.');
      }
      lines.insertAll(index + 1, newContent);

      return lines;
    }

    final List<String> newContent = <String>[
      '		$_localSwiftPackageReferenceIdentifer /* XCLocalSwiftPackageReference "Flutter/Packages/FlutterPackage" */ = {',
      '			isa = XCLocalSwiftPackageReference;',
      '			relativePath = Flutter/Packages/FlutterPackage;',
      '		};',
    ];

    lines.insertAll(endSectionIndex, newContent);

    return lines;
  }

  (int, int) _sectionRange(String sectionName, List<String> lines, {bool throwIfMissing = true}) {
    final int startSectionIndex = lines.indexOf('/* Begin $sectionName section */');
    final int endSectionIndex = lines.indexOf('/* End $sectionName section */');
    if (throwIfMissing && (startSectionIndex == -1 || endSectionIndex == -1 || startSectionIndex > endSectionIndex)) {
      throw Exception('Unable to find $sectionName section');
    }
    return (startSectionIndex, endSectionIndex);
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
  ParsedProjectGroup._(this.identifier, this.children, this.name);

  factory ParsedProjectGroup.fromJson(String key, Map<String, Object?> data) {
    String? name;
    if (data['name'] is String) {
      name = data['name']! as String;
    } else if (data['path'] is String) {
      name = data['path']! as String;
    }

    final List<String> parsedChildren = <String>[];
    if (data['children'] is List<Object?>) {
      for (final Object? item in data['children']! as List<Object?>) {
        if (item is String) {
          parsedChildren.add(item);
        }
      }
      return ParsedProjectGroup._(key, parsedChildren, name);
    }
    return ParsedProjectGroup._(key, null, name);
  }

  final String identifier;
  final List<String>? children;
  final String? name;
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
      this.data, this.identifier, this.name, this.packageProductDependencies,);

  factory ParsedNativeTarget.fromJson(String key, Map<String, Object?> data) {
    String? name;
    if (data['name'] is String) {
      name = data['name']! as String;
    }

    final List<String> parsedChildren = <String>[];
    if (data['packageProductDependencies'] is List<Object?>) {
      for (final Object? item
          in data['packageProductDependencies']! as List<Object?>) {
        if (item is String) {
          parsedChildren.add(item);
        }
      }
      return ParsedNativeTarget._(data, key, name, parsedChildren);
    }
    return ParsedNativeTarget._(data, key, name, null);
  }

  final Map<String, Object?> data;
  final String identifier;
  final String? name;
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
