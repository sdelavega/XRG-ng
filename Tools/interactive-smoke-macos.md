# Interactive macOS validation

Use a freshly built app and a new results directory:

```sh
python3 Tools/interactive-smoke-macos.py prepare \
  --app /absolute/path/to/XRG-ng.app --results /tmp/xrg-interactive-check
```

The tool copies the app, changes its bundle identifier to a private UUID and
ad-hoc signs it. Executable text, entry command and MainMenu hashes must remain
unchanged. It seeds separate preferences with Weather, Stock, AI tracking and
update checks disabled. It does not install injected hooks or a sandbox. Native
read-only system collectors run. Keep external-provider tracking disabled during
this check; use the fixture harness for those controls.

Open the results folder in Finder and double-click its XRG-ng.app. Always target
this copy by its full path or the printed UUID bundle ID when using native app
control; the user's installed XRG may also be running.

Check these actions in the visible UI:

1. Open Preferences with Command-comma. Change the title and orientation; toggle
   a system graph off and on. Leave external-provider graphs and updates disabled.
2. Visit General, Appearance, CPU, Memory, Temperature, Network, Disk, Weather,
   Stocks and AI. Use the toolbar overflow menu when a panel narrows the window.
   Change a budget value without enabling AI tracking.
3. Save a theme inside the results folder, then load that same file through the
   native dialogs. Open and close Window > Temperature Sensors.
4. Close Preferences. Double-click the graph title to collapse it. Quit normally
   with Command-Q, then reopen the app from Finder. Check the restored title,
   orientation and collapsed geometry, and expand the graph again.
5. Quit normally before inspecting saved preferences or cleaning up.

Write the expected saved values to a JSON file, for example:

```json
{
  "windowTitle": "XRG-ng interactive restore",
  "graphOrientationVertical": false,
  "aiTokensDailyBudget": 2345,
  "windowIsMinimized": false,
  "showGPUGraph": true,
  "showAITokenGraph": false,
  "aiTokensTrackingEnabled": false,
  "checkForUpdates": false,
  "showSensorWindow": false
}
```

Verify and clean up, even if a manual UI check failed:

```sh
python3 Tools/interactive-smoke-macos.py verify \
  --results /tmp/xrg-interactive-check --expect /absolute/path/to/expected.json
python3 Tools/interactive-smoke-macos.py cleanup --results /tmp/xrg-interactive-check
```

Verification requires the disposable process to have exited, unchanged executable
text/entry/MainMenu hashes and matching saved values. Its report lists preference
keys, not their contents. Cleanup unregisters the disposable bundle from
LaunchServices and removes UUID-owned preferences/cache/state artifacts from the
home directory. The app copy and test-owned theme remain in the results folder.
The tool refuses cleanup for a mismatched bundle or a running disposable app.

This is a manual check, separate from CI's automated fixture and packaged smoke
checks. Record the configuration, host architecture and actions actually exercised.
It does not establish VoiceOver usability, notarization, physical sensor accuracy,
sleep/wake behavior, external-provider operation or Intel runtime compatibility.
