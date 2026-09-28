<img src="docs/icon.png" width="96" alt="DayStack icon">

# DayStack

**English** · [한국어](README.ko.md)

A tiny calendar + to-do list that lives in your Mac's menu bar, with a black-and-grey activity heatmap and to-do sharing with friends.

<p>
  <img src="docs/month.png" width="300" alt="Month view with heatmap and today's to-dos">
  <img src="docs/day.png" width="300" alt="Day view with to-do list">
</p>

## ⬇️ Install

Requires macOS 13 or later on an Apple Silicon Mac.

### Easiest: one line in Terminal (no security prompts)

Open **Terminal**, paste this, and press Return:

```bash
curl -fsSL https://raw.githubusercontent.com/Sskskxi/daystack/main/install.sh | bash
```

It downloads the latest DayStack, puts it in Applications, and opens it, with no "can't verify" warning. Run the same line again any time to update.

### Or: download the .dmg

**[Download DayStack.dmg](https://github.com/Sskskxi/daystack/releases/latest/download/DayStack.dmg)**

1. Open `DayStack.dmg` and drag **DayStack** onto **Applications**.
2. Open **DayStack** from your Applications folder.
3. macOS will say it *can't verify* the app: open **System Settings → Privacy & Security**, scroll down, click **Open Anyway** next to DayStack, and confirm. You only need to do this once.

Then look for the calendar icon in the menu bar at the top-right of your screen and click it.

> Don't see the icon? On MacBooks with a notch, extra menu bar icons can hide behind the camera. Quit an app or two, or check **System Settings → Menu Bar** and make sure DayStack is on.

## Features

- **Calendar:** each day is shaded grey → black by how many to-dos you finished that day, with one small dot per to-do (up to 5).
- **Stacked heatmap:** the grid button shows the last 18 weeks, GitHub-style.
- **Quick to-dos:** click a day, type, press ⏎. Double-click a to-do to edit it; hover to delete.
- **Today at a glance:** today's to-dos and anything left unfinished from earlier days are shown under the calendar.
- **Friends:** share full to-do lists and heatmaps through a shared iCloud Drive folder.
- **Updates:** an **Update** button appears when a new version is published to your group.
- **Settings** (gear button): heatmap color, week starts on Monday or Sunday, open at login, Reminders sync, Claude connection, and Quit.
- **English and Korean:** follows your Mac's language, or pick one in **Settings → Language**.
- Light and dark mode.

## Alerts

- **Time alerts:** type a time in a to-do, like *"3pm Dentist"*, *"15:30 meeting"* or *"오후 3시 치과"*, or hover a to-do and click 🕒. You get a Mac notification at that time. With Reminders sync on, the alert comes from Apple Reminders instead, so it rings on your Mac *and* iPhone, only once.
- **Morning summary:** a notification each morning with the day's to-dos (9:00 by default). Mac only.
- **Evening nudge:** a notification in the evening only if something is still open (21:00 by default).

Turn each one on or off and change the times in **Settings → Alerts**. Allow notifications when macOS asks.

## iPhone home screen widget

The widget shows your heatmap and today's to-dos, in your heatmap color and in light or dark mode. It runs through the free **[Scriptable](https://apps.apple.com/app/scriptable/id1405459188)** app, so there's nothing to build.

1. Install **Scriptable** on your iPhone and open it once (iCloud Drive must be on).
2. Keep DayStack running on your Mac. It puts a **DayStack** script into Scriptable automatically; **Settings → iPhone widget** shows *Ready* once it has.
3. On your iPhone home screen: long-press → **+** → **Scriptable** → pick a size → add it.
4. Long-press the new widget → **Edit Widget** → **Script: DayStack**.

Sizes: small shows the heatmap, medium adds today's to-dos, and large shows 18 weeks plus up to 8 to-dos. iOS refreshes widgets every 15 minutes or so, and iCloud may add a minute.

## Apple Reminders sync

Open **Settings** (gear button), turn on **Sync with Reminders**, and allow access when macOS asks. DayStack creates a **DayStack** list in Reminders and keeps it in two-way sync:

- To-dos you add in DayStack appear in Reminders, on your iPhone too via iCloud.
- Reminders you add, complete, rename, reschedule or delete in the DayStack list come back into DayStack.
- Your other Reminders lists are never touched.

## Ask Claude to plan for you (MCP)

DayStack ships with a small MCP server, so Claude can read and edit your to-dos. Just say things like *"add a plan: dentist tomorrow at 3pm"* or *"plan my study schedule for this week in DayStack"*.

**Easiest:** open **Settings** (gear button) and click **Connect** next to Claude Code or Claude Desktop. Restart Claude Desktop afterwards, or start a new Claude Code session.

To set it up by hand instead:

**Claude Code:**
```bash
claude mcp add --scope user daystack -- /Applications/DayStack.app/Contents/MacOS/daystack-mcp
```

**Claude Desktop:** add this to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart Claude:
```json
{
  "mcpServers": {
    "daystack": { "command": "/Applications/DayStack.app/Contents/MacOS/daystack-mcp" }
  }
}
```

Tools: `list_todos`, `add_todo`, `add_todos`, `update_todo`, `delete_todo`. Changes show up in the menu bar instantly.

> ChatGPT's desktop app only supports MCP servers hosted on the internet, so it can't use this local server.

## Sharing with friends

Everyone needs DayStack and iCloud Drive turned on.

**To create a group:**
1. Click the menu bar icon → the people button → **Create a group**. You'll get a 6-character invite code.
2. Click **Share folder…**. In Finder, right-click the `DayStack-XXXXXX` folder → **Share** and invite your friend.
3. Send your friend the invite code.

**To join a group:**
1. Accept the iCloud folder invite from your friend.
2. Click the menu bar icon → the people button → enter the code → **Join**.

Friends' to-dos refresh every 20 seconds; iCloud may take up to a minute to sync changes.

## Your data

To-dos are stored locally in `~/Library/Application Support/DayStack/todos.json`. When you're in a group, a copy is written to the shared iCloud folder so friends can see it. Nothing is sent anywhere else.

## Security

- **Signed updates:** the Update button only installs updates signed with the publisher's private key, and never an older version. A file dropped into the shared folder by anyone else is ignored.
- **Hardened runtime:** macOS blocks other programs from injecting code into DayStack.
- **Untrusted friend data:** friends' files are size-limited and trimmed before display.
- **Claude limits:** the MCP server caps title length and how many to-dos can be added at once.
- **No network server, no accounts, no tracking.** Your data stays on your Mac and in iCloud folders you choose to share.

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh            # builds build/DayStack.app and build/DayStack.dmg
./build.sh --publish  # also copies the update + installer into your iCloud group folder
```

To release a new version, bump the number in `VERSION`, run `./build.sh`, and attach `build/DayStack.dmg` to a new GitHub release.

The first build creates an update-signing key at `~/Library/Application Support/DayStack-Publisher/update-signing.key`. **Back it up and never share it**; without it, friends' apps won't accept your updates.
