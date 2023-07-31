// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'dart:io';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../base/template.dart';
import '../base/user_messages.dart';
import '../cache.dart';
import '../convert.dart';

import '../device.dart';
import '../macos/xcode.dart';
import '../template.dart';
import 'application_package.dart';

/// A class to handle interacting with Xcode via Mac Scripting to debug
/// applications.
class XcodeDebug {
  XcodeDebug({
    required Logger logger,
    required ProcessManager processManager,
    required Xcode xcode,
    required FileSystem fileSystem,
    required UserMessages userMessages,
  })  : _logger = logger,
        _processUtils = ProcessUtils(logger: logger, processManager: processManager),
        _xcode = xcode,
        _fileSystem = fileSystem,
        _userMessage = userMessages;


  final ProcessUtils _processUtils;
  final Logger _logger;
  final Xcode _xcode;
  final FileSystem _fileSystem;
  final UserMessages _userMessage;

  Process? _startDebugSession;
  XcodeDebugProject? _currentDebuggingProject;

  bool get debugStarted => _currentDebuggingProject != null;

  String get pathToXcodeApp {
    final String? pathToXcode = _xcode.xcodeSelectPath;
    if (pathToXcode == null || pathToXcode.isEmpty) {
      throwToolExit(_userMessage.xcodeMissing);
    }
    final int index = pathToXcode.indexOf('.app');
    return pathToXcode.substring(0, index + 4);
  }

  String get pathToXcodeAutomationScript {
    final String flutterToolsAbsolutePath = _fileSystem.path.join(
      Cache.flutterRoot!,
      'packages',
      'flutter_tools',
    );
    return '$flutterToolsAbsolutePath/bin/xcode_debug.js';
  }

  Future<bool> debugApp({
    required XcodeDebugProject project,
    required String deviceId,
    required DebuggingOptions debuggingOptions,
    required List<String> launchArguments,
  }) async {

    // If project is not already opened in Xcode, open it.
    if (!await _isProjectOpenInXcode(xcodeProject: project.xcodeProject, xcodeWorkspace: project.xcodeWorkspace)) {
      final bool openResult = await _openProjectInXcode(xcodeWorkspace: project.xcodeWorkspace);
      if (!openResult) {
        return openResult;
      }
    }

    _currentDebuggingProject = project;
    _startDebugSession = await _processUtils.start(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'debug',
        '--xcode-path',
        pathToXcodeApp,
        '--project-path',
        project.xcodeProject.path,
        '--workspace-path',
        project.xcodeWorkspace.path,
        '--device-id',
        deviceId,
        '--scheme',
        project.scheme,
        '--skip-building',
        '--launch-args',
        json.encode(launchArguments),
      ],
    );

    String stdout = '';
    final StreamSubscription<String> stdoutSubscription = _startDebugSession!.stdout
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          _logger.printTrace(line);
          stdout = stdout + line;
    });

    String stderr = '';
    final StreamSubscription<String> stderrSubscription = _startDebugSession!.stderr
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          _logger.printTrace('err: $line');
          stderr = stderr + line;
    });

    final int exitCode = await _startDebugSession!.exitCode.whenComplete(() async {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      _startDebugSession = null;
    });

    if (exitCode != 0) {
      _logger.printTrace('Error executing osascript: ${exitCode}\n${stderr}');
      return false;
    }

    try {
      final Object decodeResult = json.decode(stdout) as Map<String, Object?>;
      if (decodeResult is Map<String, Object?>) {
        final XcodeAutomationScriptResponse response = XcodeAutomationScriptResponse.fromJson(decodeResult);
        if (response.status == false) {
          _logger.printError('Error opening project in Xcode: ${response.errorMessage}');
          return false;
        }
        if (response.debugResult?.status != 'running') {
          _logger.printTrace(
            'Debugging through Xcode returned the following:.\n'
            '  Status: ${response.debugResult?.status}\n'
            '  Completed: ${response.debugResult?.completed}\n'
            '  Error Message: ${response.debugResult?.errorMessage}\n'
          );
          return false;
        }
        return true;
      }
      _logger.printTrace('osascript returned unexpected JSON response: $stdout');
      return false;
    } on FormatException {
      _logger.printTrace('osascript returned non-JSON response: $stdout');
      return false;
    }
  }

  Future<bool> exit() async {
    final bool success = (_startDebugSession == null) || _startDebugSession!.kill();

    if (_currentDebuggingProject != null) {
      final XcodeDebugProject project = _currentDebuggingProject!;
      await stopDebuggingApp(
        xcodeWorkspace: project.xcodeWorkspace,
        xcodeProject: project.xcodeProject,
        closeXcode: project.isTemporaryProject,
      );

      if (project.isTemporaryProject) {
        // Wait a couple seconds before deleting the project. If project is
        // still opened in Xcode and it's deleted, it will prompt the user to
        // restore it.
        await Future<void>.delayed(const Duration(seconds: 1));
        try {
          project.xcodeProject.parent.deleteSync(recursive: true);
        } on FileSystemException {
          _logger.printError('Failed to delete temporary Xcode project: ${project.xcodeProject.parent.path}');
        }
      }
      _currentDebuggingProject = null;
    }

    return success;
  }

  Future<bool> _isProjectOpenInXcode({
    required Directory xcodeWorkspace,
    required Directory xcodeProject,
  }) async {

    final RunResult result = await _processUtils.run(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'project-opened',
        '--xcode-path',
        pathToXcodeApp,
        '--project-path',
        xcodeProject.path,
        '--workspace-path',
        xcodeWorkspace.path,
      ],
      throwOnError: true,
    );

    if (result.exitCode != 0) {
      _logger.printTrace('Error executing osascript: ${result.exitCode}\n${result.stderr}');
      return false;
    }

    try {
      final Object decodeResult = json.decode(result.stdout) as Map<String, Object?>;
      if (decodeResult is Map<String, Object?>) {
        final XcodeAutomationScriptResponse response = XcodeAutomationScriptResponse.fromJson(decodeResult);
        if (response.status == false) {
          _logger.printTrace('Error checking if project opened in Xcode: ${response.errorMessage}');
          return false;
        }
        return true;
      }
      _logger.printTrace('osascript returned unexpected JSON response: ${result.stdout}');
      return false;
    } on FormatException {
      _logger.printTrace('osascript returned non-JSON response: ${result.stdout}');
      return false;
    }
  }

  Future<bool> _openProjectInXcode({
    required Directory xcodeWorkspace,
  }) async {
    try {
      final RunResult result = await _processUtils.run(
        <String>[
          'open',
          '-a',
          pathToXcodeApp,
          // '-n', // Open a new instance of the application(s) even if one is already running.
          // '-F', // Opens the application "fresh," that is, without restoring windows. Saved persistent state is lost, except for Untitled documents.
          '-g', // Do not bring the application to the foreground.
          '-j', // Launches the app hidden.
          xcodeWorkspace.path
        ],
        throwOnError: true,
      );
      if (result.exitCode == 0) {
        return true;
      }
    } on ProcessException catch (error, stackTrace) {
      _logger.printError('$error', stackTrace: stackTrace);
    }
    return false;
  }

  Future<bool> stopDebuggingApp({
    required Directory xcodeWorkspace,
    required Directory xcodeProject,
    bool closeXcode = false,
    bool promptToSaveOnClose = false,
  }) async {
    final RunResult result = await _processUtils.run(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'stop',
        '--xcode-path',
        pathToXcodeApp,
        '--project-path',
        xcodeProject.path,
        '--workspace-path',
        xcodeWorkspace.path,
        if (closeXcode) '--close-window',
        if (promptToSaveOnClose) '--prompt-to-save'
      ],
      throwOnError: true,
    );

    if (result.exitCode != 0) {
      _logger.printTrace('Error executing osascript: ${result.exitCode}\n${result.stderr}');
      return false;
    }

    try {
      final Object decodeResult = json.decode(result.stdout) as Map<String, Object?>;
      if (decodeResult is Map<String, Object?>) {
        final XcodeAutomationScriptResponse response = XcodeAutomationScriptResponse.fromJson(decodeResult);
        if (response.status == false) {
          _logger.printError('Error stopping app in Xcode: ${response.errorMessage}');
          return false;
        }
        return true;
      }
      _logger.printTrace('osascript returned unexpected JSON response: ${result.stdout}');
      return false;
    } on FormatException {
      _logger.printTrace('osascript returned non-JSON response: ${result.stdout}');
      return false;
    }
  }

  Future<XcodeDebugProject> createXcodeProjectWithCustomBundle(
    PrebuiltIOSApp package, {
    required TemplateRenderer templateRenderer,
  }) async {
    final Directory tempXcodeProject = _fileSystem.systemTempDirectory.createTempSync('flutter_empty_xcode.');

    final Template template = await Template.fromName(
      _fileSystem.path.join('xcode', 'ios', 'custom_application_bundle'),
      fileSystem: _fileSystem,
      templateManifest: null,
      logger: _logger,
      templateRenderer: templateRenderer,
    );

    template.render(
      tempXcodeProject,
      <String, Object>{
        'applicationBundlePath': package.deviceBundlePath
      },
      printStatusWhenWriting: false,
    );

    return XcodeDebugProject(
      scheme: 'Runner',
      xcodeProject: tempXcodeProject.childDirectory('Runner.xcodeproj'),
      xcodeWorkspace: tempXcodeProject.childDirectory('Runner.xcworkspace'),
      isTemporaryProject: true,
    );
  }
}

class XcodeAutomationScriptResponse {
  XcodeAutomationScriptResponse._({
    this.status,
    this.errorMessage,
    this.debugResult,
  });

  factory XcodeAutomationScriptResponse.fromJson(Map<String, Object?> data) {
    XcodeAutomationScriptDebugResult? debugResult;
    if (data['debugResult'] != null && data['debugResult'] is Map<String, Object?>) {
      debugResult = XcodeAutomationScriptDebugResult.fromJson(
        data['debugResult']! as Map<String, Object?>,
      );
    }
    return XcodeAutomationScriptResponse._(
      status: data['status'] is bool? ? data['status'] as bool? : null,
      errorMessage: data['errorMessage']?.toString(),
      debugResult: debugResult,
    );
  }

  final bool? status;
  final String? errorMessage;
  final XcodeAutomationScriptDebugResult? debugResult;
}


class XcodeAutomationScriptDebugResult {
  XcodeAutomationScriptDebugResult._({
    required this.completed,
    required this.status,
    required this.errorMessage,
  });

  factory XcodeAutomationScriptDebugResult.fromJson(Map<String, Object?> data) {
    return XcodeAutomationScriptDebugResult._(
      completed: data['completed'] is bool? ? data['completed'] as bool? : null,
      status: data['status']?.toString(),
      errorMessage: data['errorMessage']?.toString(),
    );
  }

  final bool? completed; // Whether this scheme action has completed (sucessfully or otherwise) or not. Will be false if still running
  final String? status; // (not yet started/‌running/‌cancelled/‌failed/‌error occurred/‌succeeded) : Indicates the status of the scheme action.
  final String? errorMessage; //If the result's status is "error occurred", this will be the error message; otherwise, this will be "missing value".
}

class XcodeDebugProject {
  XcodeDebugProject({
    required this.scheme,
    required this.xcodeWorkspace,
    required this.xcodeProject,
    this.isTemporaryProject = false,
  });

  final String scheme;
  final Directory xcodeWorkspace;
  final Directory xcodeProject;
  final bool isTemporaryProject;

}
