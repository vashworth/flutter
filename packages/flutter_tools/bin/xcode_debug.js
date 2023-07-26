// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/**
 * @fileoverview Description of file, its uses and information
 * about its dependencies.
 * @package
 */

"use strict";

function run(args_array = []) {

	// debugger

	let args;
	try {
		args = new CommandArguments(args_array);
	} catch (e) {
		return new RunJsonResponse(false, `Failed to parse arguments: ${e}`);
	}

	let xcodeResult = getXcode(args);
	if (xcodeResult.error != null) {
		return new RunJsonResponse(false, xcodeResult.error);
	}
	let xcode = xcodeResult.result;

	if (args.command === "project-opened") {
		let result = getWorkspace(xcode, args);
		return new RunJsonResponse(result.error == null, result.error).stringify();
	} else if (args.command === "debug") {
		let result = debugApp(xcode, args);
		return new RunJsonResponse(result.error == null, result.error, result.result).stringify();
	} else if (args.command === "stop") {
		let result = stopApp(xcode, args);
		return new RunJsonResponse(result.error == null, result.error).stringify();
	} else {
		return new RunJsonResponse(false, "Unknown command").stringify();
	}
}

/**
 * Parsed and validated arguments passed from the command line.
 */
class CommandArguments {
	/**
	 *
	 * @param {!Array<string>} args List of arguments passed from the command line.
	 */
	constructor(args) {
		this.command = this.validatedCommand(args[0]);

		const parsedArguments = this.parseArguments(args);

		this.xcodePath = this.validatedCommonStringArgument("--xcode-path", parsedArguments["--xcode-path"]);
		this.projectPath = this.validatedCommonStringArgument("--project-path", parsedArguments["--project-path"]);
		this.workspacePath = this.validatedCommonStringArgument("--workspace-path", parsedArguments["--workspace-path"]);
		this.targetDestinationId = this.validatedDebugStringArgument("--device-id", parsedArguments["--device-id"]);
		this.targetSchemeName = this.validatedDebugStringArgument("--scheme", parsedArguments["--scheme"]);
		this.skipBuilding = this.validatedDebugBoolArgument(parsedArguments["--skip-building"]);
		this.launchArguments = this.validatedDebugJsonArgument("--launch-args", parsedArguments["--launch-args"]);

		// console.log(JSON.stringify(this));
	}

	/**
	 * Validates the command is available.
	 *
	 * @param {?string} command
	 * @returns {!string} The validated command.
	 * @throws Will throw an error if command is not recognized.
	 */
	validatedCommand(command) {
		switch (command) {
			case "project-opened":
			case "debug":
			case "stop":
				return command;
			default:
				throw `Unrecognized Command: ${command}`;
		}
	}

	/**
	 * Parses the command line arguments into an object.
	 *
	 * @param {!Array<string>} args List of arguments passed from the command line.
	 * @returns {!Object.<string, string>} Object mapping flag to value.
	 * @throws Will throw an error if flag is not recognized.
	 */
	parseArguments(args) {
		let valuesPerFlag = {};
		for (let index = 1; index < args.length; index++) {
			let entry = args[index];
			let flag;
			let value;
			const splitIndex = entry.indexOf("=");
			if (splitIndex === -1) {
				flag = entry;
				value = args[index + 1];

				// If next value in the array is also a flag, set the value to null.
				if (value != null && value.startsWith("--")) {
					value = null;
				} else {
					index++;
				}
			} else {
				flag = entry.substring(0, splitIndex);
				value = entry.substring(splitIndex + 1, entry.length + 1);
			}
			if (!flag.startsWith("--")) {
				throw `Unrecognized Flag: ${flag}`;
			}
			// console.log(`Flag: ${flag}, Value: ${value}`);
			valuesPerFlag[flag] = value;
		}
		return valuesPerFlag;
	}


	/**
	 * Validates `value` is not null, undefined, or empty.
	 *
	 * @param {!string} flag
	 * @param {?string} value
	 * @returns {!string}
	 * @throws Will throw an error if `value` is null, undefined, or empty.
	 */
	validatedCommonStringArgument(flag, value) {
		if (value == null || value === "") {
			throw `Missing value for ${flag}`;
		}
		return value;
	}

	/**
	 * Validates `value` is not null, undefined, or empty when the command is
	 *     `debug`. If the command is not `debug`, will always return `null`.
	 *
	 * @param {!string} flag
	 * @param {?string} value
	 * @returns {?string}
	 * @throws Will throw an error if the command is `debug` and `value` is
	 *     null, undefined, or empty.
	 */
	validatedDebugStringArgument(flag, value) {
		if (this.command !== "debug") {
			return null;
		}
		return this.validatedCommonStringArgument(flag, value);
	}

	/**
	 * Converts `value` to a boolean when the command is `debug`. If `value` is
	 *     null, undefined, or empty, it will return true. If the command is
	 *     not `debug`, will always return `null`.
	 *
	 * @param {?string} value
	 * @returns {?boolean}
	 */
	validatedDebugBoolArgument(value) {
		if (this.command !== "debug") {
			return null;
		}
		if (value == null || value === "") {
			return true;
		}
		return value === "true";
	}

	/**
	 * Validates `value` is not null, undefined, or empty when the command is
	 *     `debug`. Parses `value` as JSON. If the command is not `debug`,
	 *     will always return `null`.
	 *
	 * @param {!string} flag
	 * @param {?string} value
	 * @returns {!Object}
	 * @throws Will throw an error if the command is `debug` and the value is
	 *     null, undefined, or empty. Will also throw an error if parsing fails.
	 */
	validatedDebugJsonArgument(flag, value) {
		const stringValue = this.validatedDebugStringArgument(flag, value);
		try {
			return JSON.parse(stringValue);
		} catch (e) {
			throw `Error parsing ${flag}: ${e}`;
		}
	}
}

/**
 * Response to return in `run` function.
 */
class RunJsonResponse {
	/**
	 *
	 * @param {!bool} success Whether the command was successful.
	 * @param {?string=} errorMessage Defaults to null.
	 * @param {?DebugResult=} debugResult Curated results from Xcode's debug
	 *     function. Defaults to null.
	 */
	constructor(success, errorMessage = null, debugResult = null) {
		this.status = success;
		this.errorMessage = errorMessage;
		this.debugResult = debugResult;
	}

	/**
	 * Converts this object to a JSON string.
	 *
	 * @returns {!string}
	 * @throws Throws an error if converison fails.
	 */
	stringify() {
		return JSON.stringify(this);
	}
}

/**
 * Utility class to return a result along with a potential error.
 */
class FunctionResult {
	/**
	 *
	 * @param {?Object} result
	 * @param {?string=} error
	 */
	constructor(result, error = null) {
		this.result = result;
		this.error = error;
	}
}

/**
 * Curated results from Xcode's debug function. Mirrors parts of
 *     `scheme action result` from Xcode's Script Editor dictionary.
 */
class DebugResult {
	/**
	 *
	 * @param {!Object} result
	 */
	constructor(result) {
		this.completed = result.completed();
		this.status = result.status();
		this.errorMessage = result.errorMessage();
	}
}

/**
 * Get the Xcode application from the given path. Since macs can have multiple
 *     Xcode version, we use the path to target the specific Xcode application.
 *     If the Xcode app is not running, return null with an error.
 *
 * @param {!CommandArguments} args
 * @returns {!FunctionResult}
 */
function getXcode(args) {
	try {
		let xcode = Application(args.xcodePath);
		let isXcodeRunning = xcode.running();

		if (!isXcodeRunning) {
			return new FunctionResult(null, "Xcode is not running");
		}

		return new FunctionResult(xcode);
	} catch (e) {
		return new FunctionResult(null, `Failed to get Xcode application: ${e}`);
	}
}

/**
 * Gets workspace opened in Xcode matching the projectPath or workspacePath
 *     from the command line arguments. If workspace is not found, return null
 *     with an error.
 *
 * @param {!Application} xcode Mac Scripting Application for Xcode
 * @param {!CommandArguments} args
 * @returns {!FunctionResult}
 */
function getWorkspace(xcode, args) {
	let matchingDocument = null;

	try {
		let documents = xcode.workspaceDocuments();
		for (let document of documents) {
			let filePath = document.file().toString();
			if (filePath === args.projectPath || filePath === args.workspacePath) {
				matchingDocument = document;
				break;
			}
		}
	} catch (e) {
		return new FunctionResult(null, `Failed to get workspace: ${e}`);
	}

	if (matchingDocument == null) {
		return new FunctionResult(null, `Failed to get workspace.`);
	}

	return new FunctionResult(matchingDocument);
}

/**
 * Sets active run destination to targeted device. Uses Xcode debug function
 *     from Mac Scripting for Xcode to install the app on the device and start
 *     a debugging session using the "run" or "run without building" scheme
 *     action (depending on `args.skipBuilding`). Waits for the debugging session to start running.
 *
 * @param {!Application} xcode Mac Scripting Application for Xcode
 * @param {!CommandArguments} args
 * @returns {!FunctionResult}
 */
function debugApp(xcode, args) {
	let documentLoadedResult = waitForWorkspaceToLoad(xcode, args);
	if (documentLoadedResult.error != null) {
		return new FunctionResult(null, documentLoadedResult.error);
	}

	let workspaceResult = getWorkspace(xcode, args);
	if (workspaceResult.error != null) {
		return new FunctionResult(null, workspaceResult.error);
	}
	let targetWorkspace = workspaceResult.result;

	let destinationResult = getTargetDestination(targetWorkspace, args.targetDestinationId);
	if (destinationResult.error != null) {
		return new FunctionResult(null, destinationResult.error)
	}

	try {
		// Documentation from the Xcode Script Editor dictionary indicates that the
		// `debug` function has a parameter called `runDestinationSpecifier` which
		// is used to specify which device to debug the app on. It also states that
		// it should be the same as the xcodebuild -destination specifier. It also
		// states that if not specified, the `activeRunDestination` is used instead.
		//
		// Experimentation has shown that the `runDestinationSpecifier` does not work.
		// It will always use the `activeRunDestination`. To mitigate this, we set
		// the `activeRunDestination` to the targeted device prior to starting the debug.
		targetWorkspace.activeRunDestination = destinationResult.result;

		let actionResult = targetWorkspace.debug({
			scheme: args.targetSchemeName,
			skipBuilding: args.skipBuilding,
			commandLineArguments: args.launchArguments,
		});

		// Wait until app has started.
		// Potential statuses include: not yet started/‌running/‌cancelled/‌failed/‌error occurred/‌succeeded.
		// If started without issue, `completed` will continue to be false until
		// the debug session has been stopped.
		let isCompleted = actionResult.completed();
		let checkFrequencyInSeconds = 0.5;
		while (!isCompleted) {
			if (actionResult.status() != "not yet started") {
				break;
			}
			delay(checkFrequencyInSeconds);
			isCompleted = actionResult.completed();
		}

		return new FunctionResult(new DebugResult(actionResult));
	} catch (e) {
		return new FunctionResult(null, `Failed to start debugging session: ${e}`);
	}
}

/**
 * Iterates through available run destinations looking for one with a matching
 *     `deviceId`. If device is not found, return null with an error.
 *
 * @param {!WorkspaceDocument} targetWorkspace WorkspaceDocument from Mac Scripting for Xcode
 * @param {!string} deviceId
 * @returns {!FunctionResult}
 */
function getTargetDestination(targetWorkspace, deviceId) {
	try {
		let targetDestination;
		for (let runDest of targetWorkspace.runDestinations()) {
			if (runDest.device() != null && runDest.device().deviceIdentifier() === deviceId) {
				targetDestination = runDest;
				break;
			}
		}
		if (targetDestination == null) {
			return new FunctionResult(null, "Unable to find target device. Is it paired, unlocked, connected, correct deployment, symbols done?");
		}

		return new FunctionResult(targetDestination);
	} catch (e) {
		return new FunctionResult(null, `Failed to get target destination: ${e}`);
	}
}

/**
 * Waits for the workspace to load. If the workspace is not loaded or in the
 * process of opening, it will wait indefinitely.
 *
 * @param {!Application} xcode Mac Scripting Application for Xcode
 * @param {!CommandArguments} args
 * @returns {!FunctionResult}
 */
function waitForWorkspaceToLoad(xcode, args) {
	try {
		let isDocumentLoaded = false;
		let checkFrequencyInSeconds = 0.5;
		while(!isDocumentLoaded) {
			for (let window of xcode.windows()) {
				let document = window.document();
				if (document != null) {
					let filePath = document.file().toString();
					if (filePath === args.projectPath || filePath === args.workspacePath) {
						if (document.loaded()) {
							isDocumentLoaded = true;
						}
					}
				}
			}
			delay(checkFrequencyInSeconds);
		}
		if (isDocumentLoaded) {
			return new FunctionResult(true, null);
		}
	} catch (e) {
		return new FunctionResult(true, `Failed to wait for workspace to load: ${e}`);
	}
}

/**
 * Stops all debug sessions in the target workspace.
 *
 * @param {!Application} xcode Mac Scripting Application for Xcode
 * @param {!CommandArguments} args
 * @returns {!FunctionResult}
 */
function stopApp(xcode, args) {
	let workspaceResult = getWorkspace(xcode, args);
	if (workspaceResult.error != null) {
		return new FunctionResult(null, workspaceResult.error);
	}
	let targetDocument = workspaceResult.result;

	try {
		targetDocument.stop();
	} catch (e) {
		return new FunctionResult(null, `Failed to stop app: ${e}`);
	}
	return new FunctionResult(null, null);
}

// function openProject(xcode, args) {
// 	try {
// 		xcode.open(args.workspacePath);

// 		// Wait for document to be loaded
// 		for (let i = 0; i < 120; i++) {
// 			let isDocumentLoaded = false;
// 			for (let window of xcode.windows()) {
// 				let document = window.document();
// 				if (document != null) {
// 					let filePath = document.file().toString();
// 					if (filePath === args.projectPath || filePath === args.workspacePath) {
// 						window.visible = false;
// 						if (document.loaded()) {
// 							isDocumentLoaded = true;
// 						}
// 					}
// 				}
// 			}
// 			if (isDocumentLoaded) {
// 				break;
// 			}
// 			delay(0.25);
// 		}
// 	} catch (e) {
// 		return new FunctionResult(null, `Failed to open project: $`);
// 	}
// 	return new FunctionResult(null, null);
// }
