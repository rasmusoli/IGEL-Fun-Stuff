# IGEL Log Parser changelog

## [1.0.0](https://github.com/rasmusoli/IGEL-Fun-Stuff/releases/tag/igel-log-parser-v1.0.0) (2026-11-26)

- Reset the public version numbering from 3.50.x to 1.0.0. This release keeps the parser behavior, report schema and rule set from 3.50.696, including its Full JSON export fix.
- Future releases will track meaningful user-facing changes in this changelog rather than internal iteration counts.

## [3.50.696](https://github.com/rasmusoli/IGEL-Fun-Stuff/releases/tag/igel-log-parser-v3.50.696) (2026-11-25)

- Fixed standalone Full JSON export after a reported analysis worker failure. The parser now asks you to rerun the analysis instead of silently downloading an incomplete report. Normal full export and the complete main-thread fallback are unchanged.

## [3.50.695](https://github.com/rasmusoli/IGEL-Fun-Stuff/releases/tag/igel-log-parser-v3.50.695) (2026-11-25)

- Batched eligible arrays during full JSON export while preserving the existing output and fallback behavior.
