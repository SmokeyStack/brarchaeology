# Minecraft Bedrock Preview change-tracking workflow

A set of small scripts that let you keep a complete, readable history of the
files inside every **Minecraft Bedrock Preview** update on Windows, and see
exactly what Mojang changed from one version to the next.

> **Plain-language glossary** (terms used throughout this guide)
>
> - **Preview** - the public test version of Minecraft Bedrock that Mojang
>   updates roughly every week, ahead of the main game.
> - **Repository (repo)** - a folder whose entire history is recorded, so you
>   can look back at any earlier state of it. The recording is done by a tool
>   called **Git**.
> - **Commit** - one saved snapshot in that history, like a labeled save
>   point ("version 1.26.50.25").
> - **Diff** - a side-by-side comparison showing what changed between two
>   snapshots: added lines in green, removed lines in red.
> - **PowerShell** - a text window built into Windows where you run commands
>   by typing them and pressing Enter. The scripts in this project are
>   PowerShell scripts (`.ps1` files).
> - **`.brarchive`** - a container format Mojang now uses to ship many game
>   files bundled together (like an uncompressed zip file).
> - **MCB** - a compiled, unreadable binary form of certain game JSON files
>   (particles, cameras, trades, crafting catalogs, voxel shapes).
> - **Schema** - a machine-readable description of what a file's structure
>   means. The workflow uses schemas published inside Mojang's own server
>   software to turn MCB files back into readable JSON.
> - **BDS** - Bedrock Dedicated Server, Mojang's official server program.
>   We run it once per version purely to make it write out its schemas.

---

## 1. What this workflow is for

Every Preview update, Mojang changes hundreds or thousands of game files:
blocks, entities, loot tables, textures, sounds, translations, and more.
Since mid-2026 most of those files ship inside `.brarchive` containers, and
some JSON is compiled into unreadable MCB binaries - so you can no longer
just open the game folder and read them.

This workflow, run once after each Preview update:

1. Copies the new game files into your tracking folder.
2. Unpacks every `.brarchive` back into ordinary files.
3. Converts compiled MCB files back into readable JSON using Mojang's own
   schemas.
4. Formats everything so that comparisons between versions show only real
   changes, not formatting noise.

The expected outcome: a folder where a tool like **GitHub Desktop** shows
you, in plain green/red diffs, exactly what changed in each update - new
mobs, tweaked loot tables, renamed identifiers, removed textures.

**Who it is for:** wiki editors, add-on and marketplace creators, content
creators, and curious players who want to know what changed - no programming
background required. If you can install a program and copy-paste a command,
you can run this.

---

## 2. What you need before starting

All of this is free. Install in this order.

| Tool                             | What it does                                                                                                  | Where to get it                                                                                                     |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **Minecraft Preview**            | The game itself - the source of all files being tracked.                                                      | Xbox app or Microsoft Store (requires a Microsoft account that owns Minecraft)                                      |
| **PowerShell 7**                 | Runs the scripts in this project. Windows has an older PowerShell built in, but these scripts need version 7. | Microsoft Store ("PowerShell") or https://aka.ms/powershell                                                         |
| **Git**                          | Records the history of your tracking folder. GitHub Desktop installs it for you.                              | Installed with GitHub Desktop                                                                                       |
| **GitHub Desktop**               | A friendly window for Git: shows diffs, makes commits, no typing required.                                    | https://desktop.github.com                                                                                          |
| **Node.js 20 or newer**          | A program-runner needed by the MCB-to-JSON converter.                                                         | https://nodejs.org (choose the LTS version)                                                                         |
| **brarchive-cli**                | Unpacks `.brarchive` containers. A single `.exe`, no install.                                                 | https://github.com/bedrock-crustaceans/brarchive/releases - download `brarchive-cli-...-x86_64-pc-windows-msvc.zip` |
| **brarchive-extractor ("brax")** | Converts MCB binaries back to readable JSON.                                                                  | https://github.com/LPaicen/brarchive-extractor (setup steps below)                                                  |
| **Agent Ransack**                | Searches for text inside files, including the game's program file. Used for verification.                     | https://www.mythicsoft.com/agentransack/                                                                            |

**Accounts:** a Microsoft account that owns Minecraft (for Preview). A GitHub
account is only needed if you later choose to put your tracking folder
online; everything in this guide works without one.

### One-time setup

1. Create a folder for your tracking repository, for example
   `C:\minecraft-tracking`. Avoid folders inside OneDrive or Documents (sync
   tools fight with the scripts).
2. Copy the `tools\` folder from this project into it, and copy the two
   files from `templates\` into it, renaming them to exactly
   `.gitattributes` and `.gitignore` (note the leading dot, and remove the
   `.template` ending). If Windows complains about names starting with a
   dot, rename them from within GitHub Desktop's editor or PowerShell:
   `Rename-Item gitattributes.template .gitattributes`

    **Do not skip the `.gitattributes` file.** Without it, Git silently
    corrupts every image, sound, and archive file it touches. This is the
    single most important safety file in the workflow.

3. Unzip `brarchive-cli.exe` into the `tools\` folder.
4. Set up brax. Open PowerShell 7, then run these three lines one at a time
   (right-click to paste into PowerShell):

    ```powershell
    git clone https://github.com/LPaicen/brarchive-extractor C:\minecraft-tracking\tools\brax
    cd C:\minecraft-tracking\tools\brax
    npm install; npm run build
    ```

    (Adjust the paths if you used a different folder. Version 0.2.1 or newer
    is required.)

5. In GitHub Desktop: **File -> Add local repository** -> choose your tracking
   folder. If it offers to "create a repository" there, accept - that just
   turns on history recording for the folder. Nothing goes online unless you
   explicitly click Publish, which this workflow never requires.

Your folder should now look like:

```
C:\minecraft-tracking\
|--- .gitattributes
|--- .gitignore
|--- tools\
|   |--- Update-All.ps1            (the one-command runner)
|   |--- Sync-PreviewPayload.ps1
|   |--- Dump-BdsSchema.ps1
|   |--- Extract-Brarchives.ps1
|   |--- Test-Repo.ps1
|   |--- Report-Changes.ps1
|   |--- Copy-GameExecutable.ps1
|   |--- brarchive-cli.exe
|   |--- brax\   (cloned and built)
```

> **If PowerShell refuses to run scripts** ("running scripts is disabled"),
> run this once in PowerShell 7 and answer Yes:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

---

## 3. How to run the workflow (every Preview update)

### The short version: one command

1. **Update Minecraft Preview** in the Xbox app.
2. **Open PowerShell 7 in your tracking folder.** Easiest way: open the
   folder in File Explorer, click the address bar, type `pwsh` and press
   Enter.
3. Run:

    ```powershell
    .\tools\Update-All.ps1
    ```

    This runs every step below in order (sync, schema dump, extraction, the
    integrity checks, and the change report). When it completes, skip to
    step 6 ("Save the snapshot").

The rest of this section explains the individual steps - read it once so you
know what the one command is doing, and use it when you want to run or re-run
a single step.

### The individual steps

3a. **Copy the new game files in:**

```powershell
.\tools\Sync-PreviewPayload.ps1
```

This clears the folder (keeping `.git`, `tools`, and the config files)
and copies the new version's files. Expected result: a robocopy summary
table with **FAILED : 0**. If FAILED is not 0, run the same command again.

4. **Dump Mojang's schemas for this version** (needed for MCB conversion):

    ```powershell
    .\tools\Dump-BdsSchema.ps1
    ```

    Run without options, this looks up the newest server version Mojang has
    published and uses that. Because Mojang often publishes the server
    _before_ the game update reaches players, this also lets the curious dump
    schemas for an update they cannot install yet - to pin an exact version
    instead, add `-Version 1.26.50.25` (the game version is shown in the Xbox
    app or bottom-right of the game's main menu).

    The script downloads Mojang's server program (~90 MB), runs it for a few
    seconds, and collects the schema files it writes. Expected result, after
    a minute or two:
    `Schema root written to ...\tools\bds-schema (..., version 1.26.50.25).`
    A firewall permission popup for `bedrock_server.exe` may appear - you can
    safely click Cancel; the server only needs to start, not go online.

5. **Unpack and convert everything:**

    ```powershell
    .\tools\Extract-Brarchives.ps1
    ```

    This takes a minute or two (it decodes several archives at once; add
    `-ThrottleLimit 1` if you prefer one at a time, or a higher number on a
    fast machine). Expected healthy output is three lines like:

    ```
    Decoded 1841/1841 archives (134 packs).
    MCB restored to JSON (schema 1.26.50.25): 500 of 501; 1 kept binary.
    Whitespace-only changes reverted to HEAD formatting: 8519 of 9393 modified JSON files.
    Binary .json files (MCB) marked in .gitattributes: 1 total (1 seen this run).
    ```

    The exact numbers change every update. Signs something went wrong:
    - `WARNING: ... failed to decode` naming specific archives -> see
      Troubleshooting.
    - A `kept binary:` list much longer than a handful of files -> your schema
      version probably doesn't match the game version (redo step 4).
    - The command window shows red error text and stops -> read the message;
      the Troubleshooting section covers the common ones.

6. **Save the snapshot.** Open GitHub Desktop, confirm the changed-files
   list looks sensible (see section 5), type the version number
   (e.g. `1.26.50.25`) in the "Summary" box at bottom-left, and click
   **Commit**. That's the whole update recorded.

---

## 4. Dependencies on Mojang

Almost every step of this workflow depends on things only Mojang controls.
It works today; any of the following can change without warning.

- **Mojang must release the Minecraft Preview update** through the Xbox app /
  Microsoft Store. The workflow reads the locally installed game - no
  update installed, nothing to track.
- **Mojang must release the matching BDS build.** Step 4 downloads
  `bedrock-server-<version>.zip` from minecraft.net. BDS Preview usually
  appears the same day as the game update, but it can lag by hours or days,
  and occasionally a game version never gets a matching BDS version. Until
  the matching BDS exists, MCB conversion either fails or must run with the
  previous version's schemas (usually mostly works, but new file types won't
  convert).
- **Version numbers must line up.** The BDS version you pass to
  `Dump-BdsSchema.ps1` should match the game version. A too-old schema set
  can't describe new content.
- **Download availability.** The scripts use Mojang's official download
  location (`https://www.minecraft.net/bedrockdedicatedserver/...`). If
  Mojang moves, renames, or rate-limits these downloads, step 4 breaks until
  the script is updated.
- **File formats.** The workflow assumes:
    - `.brarchive` container format version 1 (as currently shipped);
    - the current MCB binary format and its undocumented conventions;
    - Mojang's current packing conventions (e.g. zero-length archive entries
      are placeholders for files shipped separately; some textures ship as
      zero-byte placeholder files with real content inside archives).
      Mojang has already changed shipping formats once (that's why this
      workflow exists) and can do so again. A format change typically means the
      community tools need updates first, then this workflow follows.
- **Schema completeness.** BDS only documents what Mojang chose to export.
  Today one file type (`minecraft:camera_entity`, currently just
  `cameras/death.json`) has no usable schema and stays binary. Future
  updates may add more gaps - the script prints exactly what it could not
  convert and why.
- **The game executable is encrypted on disk** by the Store packaging; the
  included `Copy-GameExecutable.ps1` works around this today, but packaging
  changes could break it.

In short: this workflow rides on Mojang's release process. When something
suddenly fails right after an update, the first question is always "did
Mojang change something?" - check the community tools' issue pages before
assuming you did something wrong.

---

## 5. What to do after running the workflow

Never rely on or share results without reviewing them first.

### Reviewing changes in GitHub Desktop (for complete beginners)

1. Open **GitHub Desktop**. Make sure the current repository (top-left) is
   your tracking folder.
2. The left panel lists every changed file. The number at the top is the
   total. Sanity checks:
    - A normal Preview update changes hundreds to a few thousand files. If
      you see close to **zero**, the sync step probably didn't run. If you
      see **every single file** changed (tens of thousands), formatting or
      line-ending handling broke - do not commit; see Troubleshooting.
3. Click any file to see its **diff**: red lines were removed, green lines
   were added. For example, clicking a loot-table file might show a green
   line with a new item - that's a real gameplay change Mojang made.
4. Images show as before/after pictures. Files marked "binary" just say the
   file changed - that's expected for sounds and the few remaining binary
   files.
5. When satisfied, type the version number in the **Summary** box
   (bottom-left) and click **Commit to main**. To look at any past version
   later, use the **History** tab.

### Searching inside the game executable with Agent Ransack

Some information never appears in the data files at all - new feature names,
identifiers, error messages, and experiment names often exist only as text
embedded inside the game's program file (`Minecraft.Windows.exe`). Searching
it is how the community often spots upcoming features.

The catch: the installed executable is **encrypted on disk**, so Agent
Ransack would find nothing in it directly. First make a readable copy:

1. In PowerShell 7 (in your tracking folder), run:
   `.\tools\Copy-GameExecutable.ps1`
   This asks the game's own app container to copy its executable, producing
   a readable `decrypted.exe` in the current folder. (This reads your own
   installed game for personal analysis - don't share the copy.)
2. Open **Agent Ransack**. In **Look in**, browse to the folder containing
   `decrypted.exe`. In **File name**, type `decrypted.exe`.
3. In **Containing text**, type what you're hunting for - e.g. a new mob
   name from the changelog, or a guess like `copper_golem`. Tick **Regular
   expression** only if you know what that is; plain text works fine.
4. Click **Start**. Matches appear with surrounding text in the preview
   pane.
5. **Verify what you find.** Raw executable text is full of fragments and
   coincidences:
    - A hit surrounded by other readable identifiers
      (`minecraft:something`, file paths, JSON keys) is probably a real
      identifier.
    - A hit surrounded by garbage characters may be a coincidence in binary
      data - treat it as noise.
    - Compare against the previous version's copy: a string that exists in
      the new exe but not the old one is far more interesting than one that
      was always there. Keep last version's `decrypted.exe` around for
      exactly this comparison.

### The integrity checks

`Update-All.ps1` runs `.\tools\Test-Repo.ps1` before the change report (you
can also run it on its own at any time). It performs five health checks -
every JSON file parses, every image loads, every archive byte-matches the
game's copy, no binary file is left unprotected against line-ending
corruption, and no file has been silently emptied. Each prints `[PASS]` or
`[FAIL]` with the offending files listed; a `FAILED` result means **do not
commit yet** - the messages say what to fix (usually just re-running an
earlier step). It takes about a minute and a half.

### The change report

`Update-All.ps1` ends with a summary produced by `.\tools\Report-Changes.ps1`
(which you can also run on its own at any time before committing): counts of
modified/new/deleted files, the busiest packs, and - most usefully - a list
of **new identifiers** that appeared in JSON files, which is often a direct
list of new blocks, items, entities, and biomes in the update. Add
`-OutFile report.txt` to save it as a text file for a changelog draft.

### Other sanity checks

- Spot-open a few changed JSON files (double-click in the diff view) - they
  should be readable, properly indented JSON, not one giant line or binary
  garbage.
- Open a couple of changed textures to confirm they're valid images.
- The extraction script's own output is a health report - re-read its
  warnings before trusting the run.

---

## 6. Controversial Method: Using AI

Using AI assistants (Claude, ChatGPT, Copilot and similar) for Minecraft
data-mining is a divisive topic in parts of the community - some people
object to AI-generated content or find AI-assisted findings less
trustworthy, while others use these tools daily. This section stays neutral:
whether to use AI is your call, and this workflow works perfectly well
without it.

Where AI assistance is genuinely practical here:

- **Explaining diffs.** Paste a confusing diff and ask what the change
  actually does ("what does this new loot-table condition mean?").
- **Interpreting executable strings.** Paste a cluster of strings found with
  Agent Ransack and ask for plausible interpretations or related search
  terms to try next.
- **Drafting write-ups.** Turning a pile of raw diffs into a readable
  changelog summary is something AI does quickly - with your review.
- **Troubleshooting errors.** Paste a script error message verbatim and ask
  what it means; this is often faster than searching.
- **Suggesting search terms.** Given a changelog entry, AI can suggest
  identifier spellings Mojang tends to use (`minecraft:oak_shelf` vs
  `minecraft:shelf_oak`).

The non-negotiable part: **verify everything yourself before repeating or
publishing it.** AI output can be confidently wrong, invent identifiers that
don't exist, or misread a diff. Check claims against the actual files, the
actual executable, and the actual game. Never present unverified AI output
as a finding, and be upfront about AI assistance where your community
expects that disclosure. Communities have long memories for confidently
wrong "leaks" - the tools don't take the blame; the person posting does.

---

## 7. Troubleshooting and limitations

| Problem                                                           | Likely cause                                                                                                               | Fix                                                                                                                                 |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `Download failed (HTTP error)` in Dump-BdsSchema                  | Mojang hasn't published that BDS version yet, or a typo in the version                                                     | Double-check the version number; try again later; check https://www.minecraft.net/download/server/bedrock                           |
| `BDS did not produce docs\json_schemas`                           | Antivirus/SmartScreen blocked `bedrock_server.exe`, or it crashed                                                          | Check the log path shown in the error; allow the file in your antivirus; re-run                                                     |
| `brarchive-cli.exe not found`                                     | Step "One-time setup" #3 skipped                                                                                           | Put `brarchive-cli.exe` into `tools\`                                                                                               |
| `MCB restore skipped: install brax ...`                           | brax not built, or no schema dumped                                                                                        | Redo one-time setup step 4 and workflow step 4                                                                                      |
| A long `kept binary:` list                                        | Schema version older than the game version                                                                                 | Re-run `Dump-BdsSchema.ps1` with the correct version                                                                                |
| `[missing-schema] ... No root schema found for payload key "X"`   | Mojang added a new compiled file type and BDS doesn't export its schema (or the converter doesn't recognize its title yet) | Nothing you did wrong. The file stays safely binary. Report it on the brarchive-extractor issue tracker with the exact warning text |
| `git restore failed ... repository busy`                          | GitHub Desktop was scanning while the script ran                                                                           | Just re-run `.\tools\Extract-Brarchives.ps1` - it's safe to run repeatedly                                                          |
| GitHub Desktop shows tens of thousands of changed files, all text | `.gitattributes` missing or renamed wrong                                                                                  | Restore it from `templates\`, then re-run the extraction script                                                                     |
| Zero-byte `.jpg`/`.nbt` files appear                              | Normal: Mojang ships these as placeholders in archives; the real files ship separately and the scripts keep them           | Nothing to fix - if a real file went missing, re-run steps 3a and 5 (or just `Update-All.ps1`)                                                                  |
| `running scripts is disabled`                                     | PowerShell's default safety setting                                                                                        | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once                                                                          |
| Agent Ransack finds nothing in the exe                            | Searching the encrypted original instead of the copied one                                                                 | Use `Copy-GameExecutable.ps1` and search `decrypted.exe`                                                                            |

**Known limitations**

- One file (`resource_packs/vanilla/cameras/death.json`) cannot currently be
  converted from MCB - the schema it needs ("Camera Document") has not yet
  appeared in any published BDS build. It is tracked as a binary file and
  will convert automatically once Mojang ships a BDS that exports that
  schema (brax 0.2.1+ already knows to look for it).
- Converted MCB JSON is a _reconstruction_: content-accurate, but Mojang's
  original comments, key order, and "was this default written out?" details
  are not recoverable. Expect a large one-time diff the first time a file
  type is converted.
- The version number in step 4 is typed by hand - there is no automatic
  detection of the installed Preview version yet.
- Windows-only, by design (the game install, BDS build, and scripts are all
  Windows-specific).

---

## 8. Safety and responsible use

- **These scripts delete files.** `Sync-PreviewPayload.ps1` clears the
  tracking folder (except the preserve list) every run. Only point it at the
  dedicated tracking folder - never at a folder containing anything you
  care about. The version history in `.git` is your safety net; commit
  before experimenting.
- **Respect Mojang's rights.** The game files, BDS, and the executable are
  Mojang/Microsoft property under the Minecraft EULA. Analyzing your own
  installed copy is one thing; **redistributing game files - including
  publishing a tracking repository full of them - is your legal
  responsibility to evaluate**, and sharing the copied executable is out of
  the question.
- **Verify before you publish claims.** A diff shows a file changed - it
  doesn't tell you _why_, and Preview content is frequently unfinished,
  disabled, or removed later. Executable strings especially are hints, not
  announcements. Confirm in-game where possible, and label speculation as
  speculation.
- **Downloads:** only fetch brarchive-cli, brax, and BDS from the official
  sources linked in this README. Treat any re-hosted copy as suspect.
- **The unofficial tools can lag Mojang.** After a major format change,
  expect breakage and wait for tool updates rather than forcing partial
  results.
- Nothing here modifies the game, connects to game servers, or touches your
  Minecraft account. The workflow only reads installed files and runs an
  unmodified BDS locally for a few seconds.

---

_See `THIRD-PARTY.md` for tool credits and licensing. Minecraft is a
trademark of Mojang AB; this project is unaffiliated with Mojang/Microsoft._
