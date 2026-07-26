# ArxivReader AI

ArxivReader AI is a desktop reader for daily `astro-ph` papers. It retrieves a
chosen day's papers from arXiv, helps researchers filter them by their own
topics, and uses either Gemini or OpenAI to summarize and discuss a paper.

The current release targets macOS and Windows and is built with Flutter.

## Features

- Browse daily `astro-ph` papers with title, authors, and abstract.
- Filter papers using user-defined topics such as strong lensing, weak
  lensing, photometric redshift estimation, and deep learning.
- Download PDFs, convert them to Markdown locally with MarkItDown, and create
  structured AI summaries.
- Ask follow-up questions about an individual paper and retain the Q&A history.
- Render common LaTeX mathematics in abstracts, summaries, and answers.
- Star papers, open their arXiv page or cached PDF, and export paper metadata,
  summaries, and Q&A as Markdown.
- Configure cache and export locations, inspect cache size, and clear selected
  cached data.

## Use

1. Open **Settings** and select Gemini or OpenAI.
2. Enter an API key, choose a model, then use **Test connection**.
3. Choose a date to load that day's `astro-ph` papers.
4. Use **Filter Topics** to enter the research topics you want to match.
5. Select a paper to summarize it, ask questions, open its PDF, or export its
   reading record.

API keys are stored locally in the app settings and are never committed to this
repository.

## Development

Install Flutter, the desktop development tools for your platform, and Python 3.10 or later.
The macOS script defaults to `python3`; if your current Python is elsewhere,
supply it with `PYTHON3_BIN=/path/to/python3`. The
one-command build script creates a project-local Python virtual environment,
installs MarkItDown and PyInstaller there, bundles the helper, and builds the
app. It does not require Conda or globally installed Python packages:

```bash
cd flutter_app
./tools/build_macos_release.sh
```

On Windows, open PowerShell and run:

```powershell
cd flutter_app
.\tools\build_windows_release.ps1
```

If PowerShell blocks locally checked-out scripts, run it once with
`powershell -ExecutionPolicy Bypass -File .\tools\build_windows_release.ps1`.

For development without a release build:

```bash
cd flutter_app
flutter pub get
flutter run -d macos
```

On Windows, use `flutter run -d windows`.

Run checks with:

```bash
cd flutter_app
flutter test
flutter analyze
```

The packaged macOS app is generated under
`flutter_app/build/macos/Build/Products/Release/`; the Windows executable and
its required companion files are generated under
`flutter_app/build/windows/x64/runner/Release/`. Both build outputs are
intentionally ignored by Git.

The shared Xcode project uses ad-hoc signing and does not contain a developer
team, so local builds do not require an Apple Developer Program membership. To
distribute an app to other people, select your own Team in Xcode and sign the
release with a Developer ID certificate before notarizing it.

## Platform Status

macOS and Windows are supported. Both builds bundle the MarkItDown helper for
local PDF-to-Markdown conversion. Windows uses the current-user Registry entry
for the optional launch-at-login setting. Native macOS notifications are not
currently mirrored on Windows.

## Authors

xczhou & codex
