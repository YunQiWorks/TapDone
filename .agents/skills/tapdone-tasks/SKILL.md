---
name: tapdone-tasks
description: Create or update TapDone tasks and categories through its local CLI when the user wants to add computer actions to TapDone, pin tasks to its Dock, or import AI-generated task configurations. Does not execute tasks or configure unrelated apps.
---

# TapDone tasks

Use the local TapDone CLI to manage tasks. Creating a task only saves its definition; it never executes the target. Currently supported: applications, HTTP/HTTPS URLs, folders, files, local shell commands/scripts, and generic external programs using the v1 JSON protocol. Commands run in the background through `/bin/zsh -lc`. Interactive terminal sessions, native AppleScript task types and multi-step workflows are not supported yet.

## Locate the CLI

Use `tapdone` if it is already on PATH. Otherwise use the CLI path shown in TapDone → Settings → AI integration, or an existing installed app's `Contents/Helpers/tapdone`. Quote paths containing spaces. Do not build or install the app or CLI merely to discover it without a user request for that work. If no CLI is available, generate a JSON file for the user to import through Settings → Tasks → Import.

## Read before changing

- `tapdone tasks list` returns all task definitions and the library revision.
- `tapdone categories list` returns category IDs, names and counts.
- `tapdone schema` returns the current JSON Schema; use it when a field or type is uncertain.
- `tapdone paths` reports the library location. Do not edit the internal library directly.

Match an existing task by its intent and reuse its ID when updating. For a new task, use a stable ID such as `development.open-project`, not a fresh random ID each time. Reuse category names exactly; a new category is created on apply if needed. Only two levels exist: categories and tasks.

## Prepare and apply

Write one JSON object, or an array for a batch:

```json
{
  "schemaVersion": 1,
  "id": "development.open-project",
  "category": "开发工具",
  "name": "打开项目",
  "icon": "folder",
  "showInDock": true,
  "action": {"type": "open", "path": "~/Documents/MyProject"}
}
```

Use actual user-selected paths. `open` detects a folder or file; paths must exist and be absolute or start with `~/`. For `website`, supply `url` including HTTP/HTTPS. For `application`, supply `bundleIdentifier`, not an app name or executable path. For a selected `.app` path, `open` is also supported.

Only include `showInDock: true` when requested. Omission leaves new tasks unpinned and preserves existing tasks' Dock choices. An omitted icon uses the type's default; include the current icon when preserving a customized one. `apply` replaces the specified task definition, so preserve its name, target and category when making unrelated changes. Other task IDs remain untouched.

Use `tapdone tasks validate --file <json-file>` to inspect the proposed created/updated IDs, then `tapdone tasks apply --file <json-file> --if-revision <revision-from-list>` to save. Both accept `--file -` for stdin. A batch either saves completely or not at all. They never execute tasks.

For only a Dock change, use `tapdone tasks update <id> --dock true|false --if-revision <revision>`.

## Results and conflicts

Commands emit JSON to stdout. Success has `ok: true`; errors have `ok: false`, `error.code`, `error.message` and exit status 1. Check the result before reporting success.

On `REVISION_CONFLICT`, reread and reconcile the changed tasks, then retry once if the user's intent still applies. Do not remove the revision check to force an old definition through. On invalid paths or unavailable storage, report the specific issue instead of inventing a path or resetting the library. Import/apply never deletes unrelated tasks.

Report which tasks were created or updated and whether they were pinned. The GUI refreshes automatically. No MCP connection or AI account inside TapDone is required.

## Local command or script tasks

Use this type when the user wants TapDone to run a local command or script, including a build trigger. Do not substitute a website/file opener merely because the task executes a command. Query `tapdone schema` to confirm the installed CLI supports `command`; if the installed executable is older, explain that it needs the updated TapDone version rather than silently changing the requested behavior.

```json
{
  "schemaVersion": 1,
  "id": "build.project",
  "category": "打包",
  "name": "项目打包",
  "icon": "hammer",
  "action": {
    "type": "command",
    "command": "./build.sh",
    "workingDirectory": "~/Documents/MyProject",
    "timeoutSeconds": 1800,
    "environment": {"BUILD_CONFIGURATION": "Release"}
  }
}
```

Use the user's actual command and working directory; ask for them if missing instead of inventing server settings. `command` may contain shell syntax, pipelines and newlines. Quote paths and arguments as shell code; never interpolate untrusted text into it. For a non-executable script, explicitly use its interpreter (for example `bash ./build.sh` or `python3 ./build.py`). The working directory must exist. Timeout is 1–86400 seconds, default 300; choose an appropriate value for the requested build. Environment variables merge over the app's inherited environment and are stored in the local task definition.

`validate` does not execute the command or prove that its external dependencies work. Saving/applying a command is not authorization to run it. The user launches it from the Dock, menu or settings. TapDone provides status, logs and stop controls in the Run history tab; a running task cannot be launched a second time. Existing open-type tasks remain supported.

## Extend TapDone without recompilation

For a new business capability, prefer an `external` task backed by a script or executable. Do not propose a new Swift enum case or an app rebuild for each server, API, build system or file-processing operation. Read the installed `tapdone schema`; `external` is the stable extension type. The app must already include this interface once, but future scripts and their JSON business parameters require no app build.

Use `tapdone paths` to locate the `scripts` directory. Create a named extension folder with its implementation and task JSON. Keep its script path stable when updating it. Use an available interpreter's absolute path; do not assume Python, Node or other dependencies are installed, or install a runtime without scope to do so. `validate` verifies the executable and working directory, not the semantics of argv or the script.

```json
{
  "schemaVersion": 1,
  "id": "extensions.project-build",
  "category": "打包",
  "name": "项目打包",
  "icon": "hammer",
  "action": {
    "type": "external",
    "executable": "/absolute/path/to/python3",
    "arguments": ["main.py"],
    "workingDirectory": "/actual/extension/directory",
    "timeoutSeconds": 1800,
    "input": {"configuration": "Release"}
  }
}
```

Arguments are passed directly as argv: no Shell expansion, no `~` expansion, and no variable interpolation. Use a script to adapt a tool or API to the protocol rather than embedding user data into a Shell string. `input` accepts arbitrary JSON values, so new business parameters do not require new native fields. Preserve existing custom parameters when modifying only one part of an extension.

The implementation reads one stdin JSON envelope `{protocolVersion:1,taskID,runID,input}` to EOF. It writes exactly one stdout JSON object `{protocolVersion:1,ok:true,message:"...",data:...}` and writes logs to stderr. Return exit code 0 on success; nonzero or `ok:false` means failure. Limit input and output to 1 MB each. Environment includes TAPDONE_PROTOCOL_VERSION, TAPDONE_TASK_ID and TAPDONE_RUN_ID. The run history shows the message, output JSON and stderr log.

Apply the task through the existing validate/apply flow. Script changes take effect at the next launch without restarting TapDone. Creating or updating the implementation is not permission to execute it; let the user click the task unless execution was requested. Do not compile or run the extension merely to add it when the user's task scope excludes testing.
