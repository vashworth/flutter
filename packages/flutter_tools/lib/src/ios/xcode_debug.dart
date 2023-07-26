// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'dart:io';
import 'package:process/process.dart';

import '../base/common.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../cache.dart';
import '../convert.dart';

import '../device.dart';
import '../globals.dart' as globals;
import '../macos/xcode.dart';
import '../xcode_project.dart';
import 'xcodeproj.dart';


class XcodeDebug {
  XcodeDebug({
    required Logger logger,
    required ProcessManager processManager,
    required Xcode xcode,
  })  : _logger = logger,
        _processUtils = ProcessUtils(logger: logger, processManager: processManager),
        _xcode = xcode;


  final ProcessUtils _processUtils;
  final Logger _logger;
  final Xcode _xcode;

  // String? _xcodeProcessId;
  // List<String>? logKeys;
  Process? _startDebugSession;
  bool _automatedOpen = false;

  bool get debugStarted => _startDebugSession != null;

  String? get pathToXcodeApp {
    final String? pathToXcode = _xcode.xcodeSelectPath;
    if (pathToXcode == null || pathToXcode.isEmpty) {
      return null;
    }
    final int index = pathToXcode.indexOf('.app');
    return pathToXcode.substring(0, index + 4); // + '/Contents/MacOS/Xcode';
  }

  String get pathToXcodeAutomationScript {
    final String flutterToolsAbsolutePath = globals.fs.path.join(
      Cache.flutterRoot!,
      'packages',
      'flutter_tools',
    );
    return '$flutterToolsAbsolutePath/bin/xcode_debug.js';
  }

  Future<bool> debugApp({
    required IosProject project,
    required String deviceId,
    required DebuggingOptions debuggingOptions,
    required List<String> launchArguments,
  }) async {
    if (pathToXcodeApp == null) {
      throwToolExit(globals.userMessages.xcodeMissing);
    }

    if (project.xcodeWorkspace == null) {
      globals.printError('Unable to get scheme or workspace');
      return false;
    }

    final XcodeProjectInfo? projectInfo = await project.projectInfo();
    if (projectInfo == null) {
      globals.printError('Xcode project not found.');
      return false;
    }
    final String? scheme = projectInfo.schemeFor(debuggingOptions.buildInfo);
    if (scheme == null) {
      globals.printError('Unable to get scheme or workspace');
      return false;
    }

    // If project is not already opened in Xcode, open it.
    if (!await _isProjectOpenInXcode(project)) {
      final bool openResult = await _openProjectInXcode(project);
      if (!openResult) {
        return openResult;
      }
    }

    _startDebugSession = await _processUtils.start(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'debug',
        '--xcode-path',
        pathToXcodeApp!,
        '--project-path',
        project.xcodeProject.path,
        '--workspace-path',
        project.xcodeWorkspace!.path,
        '--device-id',
        deviceId,
        '--scheme',
        scheme,
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
          stdout = stdout + line;
    });

    String stderr = '';
    final StreamSubscription<String> stderrSubscription = _startDebugSession!.stderr
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) {
          stderr = stderr + line;
    });

    final int exitCode = await _startDebugSession!.exitCode.whenComplete(() async {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
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
      _logger.printTrace('osascript returned unexpected JSON response: ${stdout}');
      return false;
    } on FormatException {
      _logger.printTrace('osascript returned non-JSON response: ${stdout}');
      return false;
    }
  }


  bool exit() {
    final bool success = (_startDebugSession == null) || _startDebugSession!.kill();
    _startDebugSession = null;
    return success;
  }

  Future<bool> _isProjectOpenInXcode(IosProject project) async {

    final RunResult result = await _processUtils.run(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'project-opened',
        '--xcode-path',
        pathToXcodeApp!,
        '--project-path',
        project.xcodeProject.path,
        '--workspace-path',
        project.xcodeWorkspace!.path,
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

  Future<bool> _openProjectInXcode(IosProject project) async {
    if (pathToXcodeApp == null) {
      throwToolExit(globals.userMessages.xcodeMissing);
    }

    if (project.xcodeWorkspace == null) {
      globals.printError('Unable to get workspace');
      return false;
    }

    try {
      final RunResult result = await _processUtils.run(
        <String>[
          'open',
          '-a',
          pathToXcodeApp!,
          // '-n', // Open a new instance of the application(s) even if one is already running.
          // '-F', // Opens the application "fresh," that is, without restoring windows. Saved persistent state is lost, except for Untitled documents.
          '-g', // Do not bring the application to the foreground.
          '-j', // Launches the app hidden.
          project.xcodeWorkspace!.path
        ],
        throwOnError: true,
      );
      if (result.exitCode == 0) {
        _automatedOpen = true;
        return true;
      }
    } on ProcessException catch (error, stackTrace) {
      _logger.printError('$error', stackTrace: stackTrace);
    }
    return false;
  }

  Future<bool> stopDebuggingApp(IosProject project) async {
    final RunResult result = await _processUtils.run(
      <String>[
        ..._xcode.xcrunCommand(),
        'osascript',
        '-l',
        'JavaScript',
        pathToXcodeAutomationScript,
        'stop',
        pathToXcodeApp!,
        '--xcode-path',
        pathToXcodeApp!,
        '--project-path',
        project.xcodeProject.path,
        '--workspace-path',
        project.xcodeWorkspace!.path,
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

  // Future<List<String>> _getXcodeProcessIds() async {
  //   if (pathToXcode == null) {
  //     throwToolExit(globals.userMessages.xcodeMissing);
  //   }

  //   try {
  //     final RunResult result = await _processUtils.run(
  //       <String>[
  //         'pgrep',
  //         '-x',
  //         '-f',
  //         pathToXcode!,
  //       ],
  //     );

  //   //    0       One or more processes were matched.

  //   //  1       No processes were matched.

  //   //  2       Invalid options were specified on the command line.

  //   //  3       An internal error occurred.

  //     if (result.exitCode == 0) {
  //       final String listOutput = result.stdout;
  //       return LineSplitter.split(listOutput).toList();
  //     }
  //   } catch (e, stackTrace) {
  //     print(e);
  //     print(stackTrace);
  //   }
  //   return <String>[];
  // }

  // Future<bool> installAndLaunchApp() async {
  //   final List<String> xcodeProcesses = await _getXcodeProcessIds();

  //   // await Future<void>.delayed(const Duration(seconds: 1));

  //   final bool success = await _openProjectInXcode();
  //   if (!success) {
  //     print('Failed to open Xcode');
  //     return false;
  //   }
  //   final List<String> newXcodeProcesses = await _getXcodeProcessIds();

  //   for (final String processId in newXcodeProcesses) {
  //     if (!xcodeProcesses.contains(processId)) {
  //       _xcodeProcessId = processId;
  //       break;
  //     }
  //   }
  //   if (_xcodeProcessId == null) {
  //     print('No Xcode process found to target');
  //     return false;
  //   }

  //   try {

  //     // TODO: path to DerivedData/Runner-xxx/Logs/Launch/LogStoreManifest.plist
  //     Map<String, dynamic> propertyValues = globals.plistParser.parseFile('path/Logs/Launch/LogStoreManifest.plist');
  //     // XCResultGenerator
  //     if (propertyValues.containsKey('logs')) {
  //       final Map<String, dynamic> logs = propertyValues['logs'] as Map<String, dynamic>;
  //       logKeys = logs.keys.toList();
  //     }
  //   } catch (e, stackTrace) {
  //     print(e);
  //     print(stackTrace);
  //   }


  //   int maxRetires = 3;
  //   for (int currentTry = 0; currentTry < maxRetires; currentTry++) {
  //     try {
  //       final RunResult result = await _processUtils.run(
  //         <String>[
  //           ..._xcode.xcrunCommand(),
  //           'xcdebug',
  //           '--pid', // Xcode process id
  //           _xcodeProcessId!,
  //           '--background', // Leave Xcode as background app
  //           '-s', // scheme
  //           project.hostAppProjectName,
  //           '-d', // destination
  //           deviceId,
  //         ],
  //         throwOnError: true,
  //       );

  //       print(result.exitCode);
  //       if (result.stderr.isNotEmpty) {
  //         // 2023-06-08 16:51:45.390 xcdebug[91211:711350] Error: Error Domain=NSOSStatusErrorDomain Code=-10000 "errAEEventFailed" UserInfo={ErrorNumber=-10000, ErrorString=The workspace document Runner.xcodeproj has not finished loading. Check the 'loaded' property before messaging a workspace document.}
  //         if (result.stderr.contains('xcodeproj has not finished loading')) {
  //           await Future<void>.delayed(const Duration(milliseconds: 5));
  //           continue;
  //         }
  //       }
  //       if (result.exitCode == 0) {
  //         return true;
  //       }
  //     } catch (err, stackTrace) {
  //       print(err);
  //       print(stackTrace);
  //     }
  //   }

  //   return false;
  // }

  // Future<void> checkForLaunchFailure() async {
  //   try {
  //     // TODO: path to DerivedData/Runner-xxx/Logs/Launch/LogStoreManifest.plist
  //     final Map<String, dynamic> propertyValues = globals.plistParser.parseFile('path/Logs/Launch/LogStoreManifest.plist');
  //     //
  //     if (!propertyValues.containsKey('logs')) {
  //       return;
  //     }

  //     final Map<String, dynamic> logs = propertyValues['logs'] as Map<String, dynamic>;
  //     final List<String> newLogKeys = logs.keys.toList();
  //     String? logId;
  //     for (final String logKey in newLogKeys) {
  //       if (logKeys != null && !logKeys!.contains(logKey)) {
  //         logId = logKey;
  //         break;
  //       }
  //     }
  //     if (logId == null) {
  //       print('Did not find log');
  //       return;
  //     }

  //     final Map<String, dynamic> logInfo = logs[logId] as Map<String, dynamic>;
  //     final String fileName = logInfo['fileName'] as String;

  //     // TODO: path to DerivedData/Runner-xxx/Logs/Launch/fileName
  //     final XCResultGenerator xcResultGenerator = XCResultGenerator(
  //       resultPath: 'path/Logs/Launch/$fileName',
  //       xcode: globals.xcode!,
  //       processUtils: globals.processUtils,
  //     );

  //     final XCResult result = await xcResultGenerator.generate();

  //     if (result.parseSuccess) {
  //       for (final XCResultIssue issue in result.issues) {
  //         print(issue.message);
  //       }
  //     }


  //   } catch (e, stackTrace) {
  //     print(e);
  //     print(stackTrace);
  //   }
  // }

  // Future<void> killXcode() async {
  //   if (_xcodeProcessId == null) {
  //     print('No Xcode process found to kill');
  //     return;
  //   }
  //   try {
  //     await _processUtils.run(
  //       <String>[
  //         'kill',
  //         _xcodeProcessId!,
  //       ],
  //       throwOnError: true,
  //     );
  //   } catch (err, stackTrace) {
  //     print(err);
  //     print(stackTrace);
  //   }

  // }

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
