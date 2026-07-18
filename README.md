# ArxivReader AI

ArxivReader AI is a desktop reader for daily `astro-ph` papers. It retrieves a
chosen day's papers from arXiv, helps researchers filter them by their own
topics, and uses either Gemini or OpenAI to summarize and discuss a paper.

The current release targets macOS and is built with Flutter.

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

Install Flutter and the macOS desktop development tools, then run:

```bash
cd flutter_app
flutter pub get
flutter run -d macos
```

Before the first macOS build, generate the local MarkItDown helper. The script
uses the `ai` Conda environment and PyInstaller:

```bash
cd flutter_app
./tools/build_markitdown_onedir.sh
```

Run checks with:

```bash
cd flutter_app
flutter test
flutter analyze
```

Build a release app with:

```bash
cd flutter_app
flutter build macos --release
```

The packaged app is generated under
`flutter_app/build/macos/Build/Products/Release/` and is intentionally ignored
by Git.

The shared Xcode project uses ad-hoc signing and does not contain a developer
team, so local builds do not require an Apple Developer Program membership. To
distribute an app to other people, select your own Team in Xcode and sign the
release with a Developer ID certificate before notarizing it.

## Platform Status

macOS is supported. The Flutter UI and Dart services are designed to be
portable, but Windows still needs platform-specific work for the bundled
MarkItDown helper, notifications, launch-at-login, and native window behavior.

## Authors

xczhou & codex
