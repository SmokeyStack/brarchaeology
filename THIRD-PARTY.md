# Third-party tools, attribution, and licensing

This workflow orchestrates several tools written by other people. None of
their code or binaries is redistributed in this repository - you download or
build each one yourself - but the workflow depends on them and they deserve
credit.

## brarchive-cli - bedrock-crustaceans/brarchive

- https://github.com/bedrock-crustaceans/brarchive
- License: **Apache-2.0**
- Used to decode Mojang's `.brarchive` container files back into individual
  files. Download `brarchive-cli-<version>-x86_64-pc-windows-msvc.zip` from
  the project's Releases page and place `brarchive-cli.exe` in `tools\`.

## brarchive-extractor ("brax") - LPaicen/brarchive-extractor

- https://github.com/LPaicen/brarchive-extractor
- License: **MIT**
- Used to convert compiled binary "MCB" `.json` files back into readable
  JSON, driven by schemas dumped from the Bedrock Dedicated Server. You clone
  and build it locally (see the README). Version **0.2.1 or newer** is
  required (earlier versions cannot convert crafting-catalog documents).

## Format documentation

The community documentation that made this workflow possible:

- `.brarchive` format: https://github.com/bedrock-crustaceans/brarchive-rs/blob/main/FORMAT.md
  and https://gist.github.com/tryashtar/4e62280c1611d744b6aa5d752ab69c15
- MCB format (unofficial): https://gist.github.com/theaddonn/e98f5e10a6f9e1c43b14b586fb670b5f
- The BDS schema-dumping technique is used by
  https://github.com/bedrock-apis/bds-docs, which inspired the local
  `Dump-BdsSchema.ps1` implementation.

## Mojang / Microsoft

- The Bedrock Dedicated Server and all Minecraft game files are the property
  of Mojang AB / Microsoft and are covered by the Minecraft EULA
  (https://www.minecraft.net/eula) and Usage Guidelines.
- This workflow downloads BDS directly from minecraft.net and reads the
  locally installed Minecraft Preview files. **Do not redistribute Mojang's
  game files, and think carefully before making a tracking repository that
  contains game data public** - that is your responsibility, not something
  these scripts decide for you.
- Minecraft is a trademark of Mojang AB. This project is not affiliated with
  or endorsed by Mojang or Microsoft.

## Other tools referenced by the README

- Git (https://git-scm.com) - GPLv2, installed separately.
- GitHub Desktop (https://desktop.github.com) - MIT, installed separately.
- Agent Ransack (https://www.mythicsoft.com/agentransack/) - freeware search
  tool by Mythicsoft, installed separately.
- Node.js (https://nodejs.org) - MIT-style license, installed separately.
- PowerShell 7 (https://github.com/PowerShell/PowerShell) - MIT, installed
  separately.
