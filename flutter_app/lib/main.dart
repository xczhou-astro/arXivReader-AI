import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _stripJsonFence(String text) {
  final trimmed = text.trim();
  final match = RegExp(
    r'^```(?:json)?\s*([\s\S]*?)\s*```$',
  ).firstMatch(trimmed);
  if (match != null) {
    return match.group(1)!.trim();
  }
  return trimmed;
}

Map<String, dynamic> _jsonObjectFromDecoded(dynamic decoded, String context) {
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  if (decoded is List && decoded.isNotEmpty) {
    final first = decoded.first;
    if (first is Map<String, dynamic>) {
      return first;
    }
    if (first is Map) {
      return Map<String, dynamic>.from(first);
    }
  }
  throw FormatException(
    '$context returned ${decoded.runtimeType}, but the app expected a JSON object.',
  );
}

Map<String, dynamic> _jsonObjectFromText(String text, String context) {
  return _jsonObjectFromDecoded(jsonDecode(_stripJsonFence(text)), context);
}

List<dynamic> _jsonListFromText(String text, String context) {
  final decoded = jsonDecode(_stripJsonFence(text));
  if (decoded is List) {
    return decoded;
  }
  if (decoded is Map) {
    final papers = decoded['papers'];
    if (papers is List) {
      return papers;
    }
    final items = decoded['items'];
    if (items is List) {
      return items;
    }
  }
  throw FormatException(
    '$context returned ${decoded.runtimeType}, but the app expected a JSON array.',
  );
}

void main() {
  runApp(const ArxivReaderApp());
}

class ArxivReaderApp extends StatefulWidget {
  const ArxivReaderApp({super.key});

  @override
  State<ArxivReaderApp> createState() => _ArxivReaderAppState();
}

class _ArxivReaderAppState extends State<ArxivReaderApp> {
  AppSettings _settings = AppSettings.defaults();
  bool _settingsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      _settings = AppSettings.fromPreferences(preferences);
      _settingsLoaded = true;
    });
  }

  Future<void> _updateSettings(AppSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await settings.saveToPreferences(preferences);
    await AppStartupService().syncLaunchAtLogin(settings.launchAtLogin);

    if (!mounted) {
      return;
    }

    setState(() {
      _settings = settings;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F766E),
      brightness: Brightness.light,
    );
    final baseTheme = ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: const Color(0xFFF3F4EF),
      useMaterial3: true,
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
    );

    return MaterialApp(
      title: 'ArxivReader AI',
      debugShowCheckedModeBanner: false,
      theme: _settings.fontPreset.apply(baseTheme),
      home: _settingsLoaded
          ? ReaderHomePage(
              settings: _settings,
              onSettingsChanged: _updateSettings,
            )
          : const _AppLoadingPage(),
    );
  }
}

class _AppLoadingPage extends StatelessWidget {
  const _AppLoadingPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class ReaderHomePage extends StatefulWidget {
  const ReaderHomePage({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
  });

  final AppSettings settings;
  final Future<void> Function(AppSettings settings) onSettingsChanged;

  @override
  State<ReaderHomePage> createState() => _ReaderHomePageState();
}

class _ReaderHomePageState extends State<ReaderHomePage> {
  static const MethodChannel _nativeChannel = MethodChannel(
    'arxiv_reader/native',
  );
  final ArxivService _arxivService = ArxivService();
  final GeminiFilterService _geminiService = GeminiFilterService();
  final OpenAiPaperService _openAiService = OpenAiPaperService();
  final AppCacheService _cacheService = AppCacheService();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _questionController = TextEditingController();

  DateTime _selectedDate = DateTime.now();
  List<PaperPreview> _allPapers = const [];
  List<PaperPreview> _sourcePapers = const [];
  List<PaperPreview>? _lastFilteredPapers;
  String? _lastFilteredTopics;
  List<PaperPreview> _visiblePapers = const [];
  PaperPreview? _selectedPaper;
  PaperSummary? _selectedSummary;
  List<PaperQaExchange> _qaHistory = const [];

  bool _isLoading = false;
  bool _isSummarizing = false;
  bool _isOpeningPdf = false;
  bool _isAskingQuestion = false;
  bool _isBatchSummarizing = false;
  bool _cancelBatchSummaryRequested = false;
  String? _batchSummaryStatus;
  SummaryStatus _summaryStatus = SummaryStatus.idle;
  QaStatus _qaStatus = QaStatus.idle;
  String? _errorMessage;
  String? _retryLabel;
  Future<void> Function()? _retryAction;

  String _activeTopics = 'All astro-ph papers';
  double _listPanelFraction = 0.3;
  QueueScope _queueScope = QueueScope.all;
  Map<String, PaperUserState> _paperStates = const {};
  String _searchQuery = '';

  AppSettings get _settings => widget.settings;
  String get _currentApiKey {
    switch (_settings.aiProvider) {
      case AiProvider.gemini:
        return _settings.geminiApiKey;
      case AiProvider.openai:
        return _settings.openAiApiKey;
    }
  }

  String get _currentProviderLabel {
    switch (_settings.aiProvider) {
      case AiProvider.gemini:
        return 'Gemini';
      case AiProvider.openai:
        return 'OpenAI';
    }
  }

  void _setErrorMessage(
    String message, {
    String? retryLabel,
    Future<void> Function()? retryAction,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _errorMessage = message;
      _retryLabel = retryLabel;
      _retryAction = retryAction;
    });
  }

  void _clearErrorState() {
    if (!mounted) {
      return;
    }
    setState(() {
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
    });
  }

  void _setBatchSummaryStatus(String? status) {
    if (!mounted) {
      return;
    }
    setState(() {
      _batchSummaryStatus = status;
    });
  }

  @override
  void initState() {
    super.initState();
    _nativeChannel.setMethodCallHandler(_handleNativeCall);
    _initializeApp();
  }

  @override
  void dispose() {
    _nativeChannel.setMethodCallHandler(null);
    _searchController.dispose();
    _questionController.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await _loadPaperStates();
    await _fetchPapersForSelectedDate();
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'showTodayPapers') {
      await _showTodayPapersIfNeeded();
    }
  }

  Future<void> _showTodayPapersIfNeeded() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_selectedDate.year == today.year &&
        _selectedDate.month == today.month &&
        _selectedDate.day == today.day) {
      return;
    }

    setState(() {
      _selectedDate = today;
    });
    await _fetchPapersForSelectedDate();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2010),
      lastDate: DateTime.now(),
    );
    if (picked == null) {
      return;
    }

    setState(() {
      _selectedDate = picked;
    });
    await _fetchPapersForSelectedDate();
  }

  Future<void> _fetchPapersForSelectedDate() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
      _selectedSummary = null;
      _qaHistory = const [];
    });

    try {
      final cachedPapers = await _cacheService.loadAllPapers(_selectedDate);
      final papers =
          cachedPapers ?? await _arxivService.fetchAstroPhPapers(_selectedDate);

      if (cachedPapers == null) {
        await _cacheService.saveAllPapers(_selectedDate, papers);
      }

      setState(() {
        _allPapers = papers;
        _sourcePapers = papers;
        _lastFilteredPapers = null;
        _lastFilteredTopics = null;
        _activeTopics = 'All astro-ph papers';
      });

      _refreshVisiblePapers();
      await _loadCachedSummaryForSelection();
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
        _retryLabel = 'Retry loading papers';
        _retryAction = _fetchPapersForSelectedDate;
        _allPapers = const [];
        _sourcePapers = const [];
        _lastFilteredPapers = null;
        _lastFilteredTopics = null;
        _visiblePapers = const [];
        _selectedPaper = null;
        _selectedSummary = null;
        _qaHistory = const [];
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadCachedSummaryForSelection() async {
    final paper = _selectedPaper;
    if (paper == null) {
      if (mounted) {
        setState(() {
          _selectedSummary = null;
          _qaHistory = const [];
        });
      }
      return;
    }

    final summary = await _cacheService.loadSummary(paper.id);
    if (!mounted || _selectedPaper?.id != paper.id) {
      return;
    }

    setState(() {
      _selectedSummary = summary;
    });
  }

  Future<void> _loadCachedQaHistoryForSelection() async {
    final paper = _selectedPaper;
    if (paper == null) {
      if (mounted) {
        setState(() {
          _qaHistory = const [];
        });
      }
      return;
    }

    final history = await _cacheService.loadQaHistory(paper.id);
    if (!mounted || _selectedPaper?.id != paper.id) {
      return;
    }

    setState(() {
      _qaHistory = history;
    });
  }

  Future<String> _markdownForAi(PaperPreview paper, File pdfFile) async {
    try {
      final markdownFile = await _cacheService.ensureMarkdownConverted(
        paper: paper,
        pdfFile: pdfFile,
      );
      return markdownFile.readAsString();
    } catch (error) {
      debugPrint('MarkItDown conversion failed: $error');
      if (_isBatchSummarizing) {
        _setBatchSummaryStatus(
          'Markdown conversion was unavailable. Using the original PDF...',
        );
      }
      // The original PDF remains a complete multimodal input, so conversion
      // failures should not stop the paper-reading workflow.
      return '';
    }
  }

  Future<List<PaperPreview>> _filterPapersWithProvider(String topics) {
    switch (_settings.aiProvider) {
      case AiProvider.gemini:
        return _geminiService.filterPapers(
          papers: _allPapers,
          topics: topics,
          apiKey: _currentApiKey,
          model: _settings.geminiModel,
        );
      case AiProvider.openai:
        return _openAiService.filterPapers(
          papers: _allPapers,
          topics: topics,
          apiKey: _currentApiKey,
          model: _settings.openAiModel,
        );
    }
  }

  Future<PaperSummary> _summarizeWithProvider(
    PaperPreview paper,
    File pdfFile,
  ) async {
    switch (_settings.aiProvider) {
      case AiProvider.gemini:
        return _geminiService.summarizePaper(
          paper: paper,
          pdfFile: pdfFile,
          apiKey: _currentApiKey,
          model: _settings.geminiModel,
          markdown: await _markdownForAi(paper, pdfFile),
        );
      case AiProvider.openai:
        return _openAiService.summarizePaper(
          paper: paper,
          pdfFile: pdfFile,
          apiKey: _currentApiKey,
          model: _settings.openAiModel,
          markdown: await _markdownForAi(paper, pdfFile),
        );
    }
  }

  Future<PaperQaExchange> _answerWithProvider(
    PaperPreview paper,
    File pdfFile,
    String question,
  ) async {
    switch (_settings.aiProvider) {
      case AiProvider.gemini:
        return _geminiService.answerQuestionAboutPaper(
          paper: paper,
          pdfFile: pdfFile,
          question: question,
          apiKey: _currentApiKey,
          model: _settings.geminiModel,
          markdown: await _markdownForAi(paper, pdfFile),
        );
      case AiProvider.openai:
        return _openAiService.answerQuestionAboutPaper(
          paper: paper,
          pdfFile: pdfFile,
          question: question,
          apiKey: _currentApiKey,
          model: _settings.openAiModel,
          markdown: await _markdownForAi(paper, pdfFile),
        );
    }
  }

  Future<void> _showTopicDialog() async {
    final topicsController = TextEditingController(
      text: _activeTopics == 'All astro-ph papers'
          ? _settings.defaultTopics
          : _activeTopics,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Filter Papers with AI'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Feed the paper titles and abstracts to $_currentProviderLabel. A paper is kept if it matches at least one of your topics.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: topicsController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Topics',
                    hintText:
                        'e.g. deep learning, strong lensing, weak lensing, photometric redshift estimation',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'API key source: Settings > AI model',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(topicsController.text.trim());
              },
              child: const Text('Filter'),
            ),
          ],
        );
      },
    );

    if (result == null) {
      _showAllPapers();
      return;
    }
    if (result.isEmpty) {
      _setErrorMessage('Please enter at least one topic to filter by AI.');
      return;
    }
    if (_currentApiKey.trim().isEmpty) {
      _setErrorMessage(
        'Please save your $_currentProviderLabel API key in Settings first.',
      );
      return;
    }

    await _runTopicFilter(result);
  }

  Future<void> _openSettingsPage() async {
    final result = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (context) => SettingsPage(settings: _settings),
      ),
    );

    if (result == null) {
      return;
    }

    try {
      await widget.onSettingsChanged(result);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage('Could not save settings: $error');
      return;
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Settings saved.')));
  }

  Future<List<PaperPreview>> _runTopicFilter(String topics) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
      _selectedSummary = null;
    });

    try {
      final cachedFiltered = await _cacheService.loadFilteredPapers(
        _selectedDate,
        topics,
      );

      final filteredPapers =
          cachedFiltered ?? await _filterPapersWithProvider(topics);

      final normalizedFilteredPapers = _normalizeMatchedTopicsForPapers(
        filteredPapers,
        topics,
      );

      if (cachedFiltered == null) {
        await _cacheService.saveFilteredPapers(
          _selectedDate,
          topics,
          normalizedFilteredPapers,
        );
      }

      setState(() {
        _activeTopics = topics;
        _sourcePapers = normalizedFilteredPapers;
        _lastFilteredPapers = normalizedFilteredPapers;
        _lastFilteredTopics = topics;
      });

      _refreshVisiblePapers();
      await _loadCachedSummaryForSelection();
      return normalizedFilteredPapers;
    } catch (error) {
      _setErrorMessage(
        error.toString(),
        retryLabel: 'Retry topic filter',
        retryAction: () => _runTopicFilter(topics),
      );
      return const [];
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _summarizeAllCurrentPapers() async {
    final papers = _sourcePapers;
    if (papers.isEmpty) {
      _setErrorMessage('Load papers or filter topics before summarizing.');
      return;
    }
    if (_currentApiKey.isEmpty) {
      _setErrorMessage(
        'Please save your $_currentProviderLabel API key in Settings first.',
      );
      return;
    }
    final papersToSummarize = <PaperPreview>[];
    for (final paper in papers) {
      final hasSummary = await _cacheService.loadSummary(paper.id) != null;
      final hasMarkdown = await _cacheService.hasMarkdownConverted(paper.id);
      if (!hasSummary || !hasMarkdown) {
        papersToSummarize.add(paper);
      }
    }

    if (papersToSummarize.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'All papers in the current view are already summarized and converted to Markdown.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _isBatchSummarizing = true;
      _cancelBatchSummaryRequested = false;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
    });

    var generatedCount = 0;
    var markdownCount = 0;
    var failedCount = 0;
    final failures = <String>[];
    try {
      for (var index = 0; index < papersToSummarize.length; index++) {
        if (_cancelBatchSummaryRequested) {
          break;
        }
        final paper = papersToSummarize[index];
        _setBatchSummaryStatus(
          'Summarizing ${index + 1}/${papersToSummarize.length}: ${paper.title}',
        );

        try {
          final cachedSummary = await _cacheService.loadSummary(paper.id);
          final pdfFile = await _cacheService.ensurePdfDownloaded(paper);
          if (cachedSummary != null) {
            _setBatchSummaryStatus(
              'Converting Markdown ${index + 1}/${papersToSummarize.length}: ${paper.title}',
            );
            await _cacheService.ensureMarkdownConverted(
              paper: paper,
              pdfFile: pdfFile,
            );
            markdownCount += 1;
            continue;
          }

          final summary = await _summarizeWithProvider(paper, pdfFile);
          await _cacheService.saveSummary(paper.id, summary);
          generatedCount += 1;
          if (await _cacheService.hasMarkdownConverted(paper.id)) {
            markdownCount += 1;
          }

          if (mounted && _selectedPaper?.id == paper.id) {
            setState(() {
              _selectedSummary = summary;
            });
          }
        } catch (error) {
          failedCount += 1;
          failures.add(error.toString());
        }
      }

      if (_cancelBatchSummaryRequested && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Summary cancelled. Generated $generatedCount new summar${generatedCount == 1 ? 'y' : 'ies'}.',
            ),
          ),
        );
      } else if (failedCount > 0) {
        _setErrorMessage(
          'Could not summarize $failedCount paper${failedCount == 1 ? '' : 's'}. First error: ${failures.first}',
          retryLabel: 'Retry remaining summaries',
          retryAction: _summarizeAllCurrentPapers,
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Generated $generatedCount new summar${generatedCount == 1 ? 'y' : 'ies'} and prepared $markdownCount Markdown file${markdownCount == 1 ? '' : 's'}.',
            ),
          ),
        );
      }
    } finally {
      _setBatchSummaryStatus(null);
      if (mounted) {
        setState(() {
          _isBatchSummarizing = false;
          _cancelBatchSummaryRequested = false;
        });
      }
    }
  }

  Future<void> _showSettingsDialog() async {
    await _openSettingsPage();
  }

  void _togglePaperView() {
    final filteredPapers = _lastFilteredPapers;
    if (filteredPapers == null || _isBatchSummarizing) {
      return;
    }

    final isShowingFiltered = _activeTopics != 'All astro-ph papers';
    if (isShowingFiltered) {
      _showAllPapers();
      return;
    }

    setState(() {
      _activeTopics = _lastFilteredTopics ?? 'Filtered results';
      _sourcePapers = filteredPapers;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
      _selectedSummary = null;
    });
    _refreshVisiblePapers();
    _loadCachedSummaryForSelection();
  }

  void _showAllPapers() {
    setState(() {
      _activeTopics = 'All astro-ph papers';
      _sourcePapers = _allPapers;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
      _selectedSummary = null;
    });
    _refreshVisiblePapers();
    _loadCachedSummaryForSelection();
  }

  void _cancelBatchSummary() {
    if (!_isBatchSummarizing) {
      return;
    }
    setState(() {
      _cancelBatchSummaryRequested = true;
      _batchSummaryStatus =
          'Cancellation requested. Finishing the current paper...';
    });
  }

  Future<void> _openCacheFolder() async {
    try {
      final root = await _cacheService.ensureCacheRoot();
      await _openPath(root.path);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage(
        'Could not open cache folder: $error',
        retryLabel: 'Retry opening cache folder',
        retryAction: _openCacheFolder,
      );
    }
  }

  Future<void> _openSelectedPdf() async {
    final paper = _selectedPaper;
    if (paper == null) {
      return;
    }
    setState(() {
      _isOpeningPdf = true;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
    });

    try {
      final pdfFile = await _cacheService.ensurePdfDownloaded(paper);
      await _openPath(pdfFile.path);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage(
        'Could not open cached PDF: $error',
        retryLabel: 'Retry opening PDF',
        retryAction: _openSelectedPdf,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isOpeningPdf = false;
        });
      }
    }
  }

  Future<void> _openSelectedWebsite() async {
    final paper = _selectedPaper;
    if (paper == null) {
      return;
    }

    try {
      _clearErrorState();
      await _openPath(_arxivAbsUrl(paper.id));
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage(
        'Could not open arXiv website: $error',
        retryLabel: 'Retry opening website',
        retryAction: _openSelectedWebsite,
      );
    }
  }

  Future<void> _exportSelectedPaperMarkdown() async {
    final paper = _selectedPaper;
    if (paper == null) {
      return;
    }

    try {
      _clearErrorState();
      final summary =
          _selectedSummary ?? await _cacheService.loadSummary(paper.id);
      final qaHistory = _qaHistory.isNotEmpty
          ? _qaHistory
          : await _cacheService.loadQaHistory(paper.id);

      final markdown = _buildPaperMarkdown(
        paper: paper,
        summary: summary,
        qaHistory: qaHistory,
      );
      final file = await _cacheService.exportPaperMarkdown(
        paperId: paper.id,
        markdown: markdown,
      );
      await _openPath(file.path);

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported Markdown: ${file.path.split('/').last}'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage(
        'Could not export Markdown: $error',
        retryLabel: 'Retry export',
        retryAction: _exportSelectedPaperMarkdown,
      );
    }
  }

  String _buildPaperMarkdown({
    required PaperPreview paper,
    required PaperSummary? summary,
    required List<PaperQaExchange> qaHistory,
  }) {
    final buffer = StringBuffer()
      ..writeln('# ${paper.title}')
      ..writeln()
      ..writeln('- arXiv ID: ${paper.id}')
      ..writeln('- Website: ${_arxivAbsUrl(paper.id)}')
      ..writeln('- Authors: ${paper.authors}')
      ..writeln('- Subjects: ${paper.subjects}')
      ..writeln('- PDF: ${paper.pdfUrl}')
      ..writeln();

    if (paper.matchExplanation != null && paper.matchExplanation!.isNotEmpty) {
      buffer
        ..writeln('## Matched Topics')
        ..writeln()
        ..writeln(paper.matchExplanation!)
        ..writeln();
    }

    buffer
      ..writeln('## Abstract')
      ..writeln()
      ..writeln(paper.abstractText)
      ..writeln();

    if (summary != null) {
      buffer
        ..writeln('## Summary')
        ..writeln()
        ..writeln(summary.tldr)
        ..writeln();

      void writeBulletSection(String title, List<String> items) {
        if (items.isEmpty) {
          return;
        }
        buffer
          ..writeln('### $title')
          ..writeln();
        for (final item in items) {
          buffer.writeln('- $item');
        }
        buffer.writeln();
      }

      writeBulletSection('Key Contributions', summary.keyContributions);
      writeBulletSection('Methods', summary.methods);
      writeBulletSection('Main Results', summary.mainResults);
      writeBulletSection('Limitations', summary.limitations);
    }

    if (qaHistory.isNotEmpty) {
      buffer
        ..writeln('## Q&A')
        ..writeln();
      for (final exchange in qaHistory) {
        buffer
          ..writeln('### Q: ${exchange.question}')
          ..writeln()
          ..writeln(exchange.answer)
          ..writeln();
        if (exchange.citations.isNotEmpty) {
          buffer.writeln('Evidence:');
          for (final citation in exchange.citations) {
            buffer.writeln('- $citation');
          }
          buffer.writeln();
        }
      }
    }

    return buffer.toString().trimRight();
  }

  Future<void> _summarizeSelectedPaper() async {
    final paper = _selectedPaper;
    if (paper == null) {
      return;
    }
    if (_currentApiKey.isEmpty) {
      _setErrorMessage(
        'Please save your $_currentProviderLabel API key in Settings first.',
      );
      return;
    }
    setState(() {
      _isSummarizing = true;
      _summaryStatus = SummaryStatus.downloadingPdf;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
    });

    try {
      final cachedSummary = await _cacheService.loadSummary(paper.id);
      if (cachedSummary != null) {
        final pdfFile = await _cacheService.ensurePdfDownloaded(paper);
        await _cacheService.ensureMarkdownConverted(
          paper: paper,
          pdfFile: pdfFile,
        );
        setState(() {
          _selectedSummary = cachedSummary;
          _summaryStatus = SummaryStatus.idle;
        });
        return;
      }

      final pdfFile = await _cacheService.ensurePdfDownloaded(paper);
      if (mounted) {
        setState(() {
          _summaryStatus = SummaryStatus.summarizing;
        });
      }
      final summary = await _summarizeWithProvider(paper, pdfFile);
      await _cacheService.saveSummary(paper.id, summary);

      if (!mounted || _selectedPaper?.id != paper.id) {
        return;
      }

      setState(() {
        _selectedSummary = summary;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage(
        error.toString(),
        retryLabel: 'Retry summary',
        retryAction: _summarizeSelectedPaper,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSummarizing = false;
          _summaryStatus = SummaryStatus.idle;
        });
      }
    }
  }

  Future<void> _askQuestionAboutSelectedPaper() async {
    final paper = _selectedPaper;
    final question = _questionController.text.trim();
    if (paper == null) {
      return;
    }
    if (question.isEmpty) {
      _setErrorMessage('Please enter a question first.');
      return;
    }
    if (_currentApiKey.isEmpty) {
      _setErrorMessage(
        'Please save your $_currentProviderLabel API key in Settings first.',
      );
      return;
    }
    setState(() {
      _isAskingQuestion = true;
      _qaStatus = QaStatus.downloadingPdf;
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
    });

    try {
      final pdfFile = await _cacheService.ensurePdfDownloaded(paper);
      if (mounted) {
        setState(() {
          _qaStatus = QaStatus.answering;
        });
      }

      final answer = await _answerWithProvider(paper, pdfFile, question);

      if (!mounted || _selectedPaper?.id != paper.id) {
        return;
      }

      final updatedHistory = [
        ..._qaHistory,
        answer.copyWith(
          askedAtIso8601: DateTime.now().toUtc().toIso8601String(),
        ),
      ];
      await _cacheService.saveQaHistory(paper.id, updatedHistory);

      setState(() {
        _qaHistory = updatedHistory;
      });
      _questionController.clear();
    } catch (error) {
      if (!mounted) {
        return;
      }
      _setErrorMessage(
        error.toString(),
        retryLabel: 'Retry answer',
        retryAction: _askQuestionAboutSelectedPaper,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAskingQuestion = false;
          _qaStatus = QaStatus.idle;
        });
      }
    }
  }

  Future<void> _selectPaper(PaperPreview paper) async {
    setState(() {
      _selectedPaper = paper;
      _selectedSummary = null;
      _qaHistory = const [];
      _errorMessage = null;
      _retryLabel = null;
      _retryAction = null;
    });
    await _loadCachedSummaryForSelection();
    await _loadCachedQaHistoryForSelection();
    _questionController.clear();
  }

  Future<void> _loadPaperStates() async {
    final loadedStates = await _cacheService.loadPaperStates();
    setState(() {
      _paperStates = loadedStates;
    });
  }

  PaperUserState _paperStateFor(String paperId) {
    return _paperStates[paperId] ?? const PaperUserState();
  }

  Future<void> _updatePaperState(
    String paperId,
    PaperUserState Function(PaperUserState current) updater,
  ) async {
    final current = _paperStateFor(paperId);
    final updated = updater(current);
    final nextStates = Map<String, PaperUserState>.from(_paperStates);

    if (updated.isEmpty) {
      nextStates.remove(paperId);
    } else {
      nextStates[paperId] = updated;
    }

    setState(() {
      _paperStates = nextStates;
    });

    await _cacheService.savePaperStates(nextStates);
    _refreshVisiblePapers(preferredPaperId: paperId);
  }

  Future<void> _toggleStarSelectedPaper() async {
    final paper = _selectedPaper;
    if (paper == null) {
      return;
    }
    await _updatePaperState(
      paper.id,
      (current) => current.copyWith(isStarred: !current.isStarred),
    );
  }

  void _setQueueScope(QueueScope scope) {
    setState(() {
      _queueScope = scope;
    });
    _refreshVisiblePapers();
  }

  void _setSearchQuery(String value) {
    setState(() {
      _searchQuery = value.trim();
    });
    _refreshVisiblePapers();
  }

  List<PaperPreview> _normalizeMatchedTopicsForPapers(
    List<PaperPreview> papers,
    String topics,
  ) {
    final topicList = topics
        .split(',')
        .map((topic) => topic.trim())
        .where((topic) => topic.isNotEmpty)
        .toList();

    if (topicList.isEmpty) {
      return papers;
    }

    return papers.map((paper) {
      final matchedTopics = <String>[];
      final lowerExplanation = (paper.matchExplanation ?? '').toLowerCase();
      final haystack = '${paper.title} ${paper.abstractText} ${paper.subjects}'
          .toLowerCase();

      for (final topic in topicList) {
        final lowerTopic = topic.toLowerCase();
        final normalizedTopic = lowerTopic
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (normalizedTopic.isEmpty) {
          continue;
        }

        if (lowerExplanation.contains(normalizedTopic) ||
            haystack.contains(normalizedTopic)) {
          matchedTopics.add(topic);
        }
      }

      final topicText = matchedTopics.isNotEmpty
          ? matchedTopics.join(' • ')
          : topicList.first;

      return paper.copyWith(matchExplanation: topicText);
    }).toList();
  }

  void _updateSplitRatio(double deltaDx, double totalWidth) {
    final availableWidth = totalWidth - 18;
    if (availableWidth <= 0) {
      return;
    }

    final currentListWidth = availableWidth * _listPanelFraction;
    final nextListWidth = currentListWidth + deltaDx;
    final minWidth = 320.0;
    final maxWidth = availableWidth - 420.0;

    if (maxWidth <= minWidth) {
      return;
    }

    final clampedWidth = nextListWidth.clamp(minWidth, maxWidth);
    setState(() {
      _listPanelFraction = clampedWidth / availableWidth;
    });
  }

  Future<void> _openPath(String path) async {
    if (Platform.isMacOS) {
      final result = await Process.run('open', [path]);
      if (result.exitCode != 0) {
        throw Exception(result.stderr.toString().trim());
      }
      return;
    }

    if (Platform.isWindows) {
      // Explorer is normally a long-lived shell process. Waiting for it with
      // Process.run can report a spurious non-zero result even when it opens
      // the requested file or folder successfully.
      await Process.start(
        'explorer.exe',
        [path],
        mode: ProcessStartMode.detached,
      );
      return;
    }

    final result = await Process.run('xdg-open', [path]);
    if (result.exitCode != 0) {
      throw Exception(result.stderr.toString().trim());
    }
  }

  String _arxivAbsUrl(String paperId) {
    return Uri.https('arxiv.org', '/abs/${paperId.trim()}').toString();
  }

  List<PaperPreview> _applyQueueScope(List<PaperPreview> papers) {
    return papers.where((paper) {
      final state = _paperStateFor(paper.id);
      switch (_queueScope) {
        case QueueScope.all:
          return true;
        case QueueScope.starred:
          return state.isStarred;
      }
    }).toList();
  }

  bool _matchesSearchQuery(PaperPreview paper) {
    if (_searchQuery.isEmpty) {
      return true;
    }

    final paperState = _paperStateFor(paper.id);
    final haystack = [
      paper.title,
      paper.authors,
      paper.abstractText,
      paper.subjects,
      paper.matchExplanation ?? '',
      paperState.tags.join(' '),
    ].join(' ').toLowerCase();

    return haystack.contains(_searchQuery.toLowerCase());
  }

  void _refreshVisiblePapers({String? preferredPaperId}) {
    final preferredId = preferredPaperId ?? _selectedPaper?.id;
    final nextVisiblePapers = _applyQueueScope(
      _sourcePapers,
    ).where(_matchesSearchQuery).toList();
    PaperPreview? preferredPaper;

    if (preferredId != null) {
      for (final paper in nextVisiblePapers) {
        if (paper.id == preferredId) {
          preferredPaper = paper;
          break;
        }
      }
    }

    final nextSelectedPaper = preferredId == null
        ? (nextVisiblePapers.isNotEmpty ? nextVisiblePapers.first : null)
        : preferredPaper ??
              (nextVisiblePapers.isNotEmpty ? nextVisiblePapers.first : null);

    setState(() {
      _visiblePapers = nextVisiblePapers;
      _selectedPaper = nextSelectedPaper;
    });
  }

  @override
  Widget build(BuildContext context) {
    final formattedDate = _formatDate(_selectedDate);

    return Scaffold(
      body: Stack(
        children: [
          const _BackdropDecoration(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final useVerticalLayout = constraints.maxWidth < 1150;

                        final topBar = _TopBar(
                          selectedDateLabel: formattedDate,
                          paperCount: _visiblePapers.length,
                          isLoading: _isLoading,
                          batchSummaryStatus: _batchSummaryStatus,
                          isBatchSummarizing: _isBatchSummarizing,
                          hasFilteredResults: _lastFilteredPapers != null,
                          isShowingFiltered:
                              _activeTopics != 'All astro-ph papers',
                          onPickDate: _pickDate,
                          onFilterTopics: _showTopicDialog,
                          onTogglePaperView: _togglePaperView,
                          onOpenCache: _openCacheFolder,
                          onOpenSettings: _showSettingsDialog,
                          onSummarizeAll: _summarizeAllCurrentPapers,
                          onCancelBatchSummary: _cancelBatchSummary,
                        );

                        final listPanel = _PaperListPanel(
                          papers: _visiblePapers,
                          selectedPaper: _selectedPaper,
                          queueScope: _queueScope,
                          paperStates: _paperStates,
                          searchController: _searchController,
                          searchQuery: _searchQuery,
                          isLoading: _isLoading,
                          errorMessage: _errorMessage,
                          retryLabel: _retryLabel,
                          onRetry: _retryAction == null
                              ? null
                              : () => _retryAction!.call(),
                          onSelect: _selectPaper,
                          onScopeChanged: _setQueueScope,
                          onSearchChanged: _setSearchQuery,
                        );

                        final detailPanel = _PaperDetailPanel(
                          paper: _selectedPaper,
                          paperState: _selectedPaper == null
                              ? null
                              : _paperStateFor(_selectedPaper!.id),
                          summary: _selectedSummary,
                          qaHistory: _qaHistory,
                          isLoading: _isLoading,
                          isSummarizing: _isSummarizing,
                          summaryStatus: _summaryStatus,
                          isAskingQuestion: _isAskingQuestion,
                          qaStatus: _qaStatus,
                          errorMessage: _errorMessage,
                          retryLabel: _retryLabel,
                          onRetry: _retryAction == null
                              ? null
                              : () => _retryAction!.call(),
                          questionController: _questionController,
                          onSummarize: _summarizeSelectedPaper,
                          onAskQuestion: _askQuestionAboutSelectedPaper,
                          onOpenPdf: _openSelectedPdf,
                          onOpenWebsite: _openSelectedWebsite,
                          onExportMarkdown: _exportSelectedPaperMarkdown,
                          onToggleStar: _toggleStarSelectedPaper,
                          isOpeningPdf: _isOpeningPdf,
                        );

                        return Column(
                          children: [
                            SizedBox(
                              width: constraints.maxWidth,
                              child: topBar,
                            ),
                            const SizedBox(height: 18),
                            Expanded(
                              child: useVerticalLayout
                                  ? Column(
                                      children: [
                                        Expanded(child: listPanel),
                                        const SizedBox(height: 18),
                                        Expanded(child: detailPanel),
                                      ],
                                    )
                                  : Builder(
                                      builder: (context) {
                                        final availableWidth =
                                            constraints.maxWidth - 18;
                                        final listWidth =
                                            availableWidth * _listPanelFraction;

                                        return Row(
                                          children: [
                                            SizedBox(
                                              width: listWidth,
                                              child: listPanel,
                                            ),
                                            _SplitDragHandle(
                                              onDragUpdate: (delta) {
                                                _updateSplitRatio(
                                                  delta.delta.dx,
                                                  constraints.maxWidth,
                                                );
                                              },
                                            ),
                                            Expanded(child: detailPanel),
                                          ],
                                        );
                                      },
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.selectedDateLabel,
    required this.paperCount,
    required this.isLoading,
    required this.batchSummaryStatus,
    required this.isBatchSummarizing,
    required this.hasFilteredResults,
    required this.isShowingFiltered,
    required this.onPickDate,
    required this.onFilterTopics,
    required this.onTogglePaperView,
    required this.onOpenCache,
    required this.onOpenSettings,
    required this.onSummarizeAll,
    required this.onCancelBatchSummary,
  });

  final String selectedDateLabel;
  final int paperCount;
  final bool isLoading;
  final String? batchSummaryStatus;
  final bool isBatchSummarizing;
  final bool hasFilteredResults;
  final bool isShowingFiltered;
  final VoidCallback onPickDate;
  final VoidCallback onFilterTopics;
  final VoidCallback onTogglePaperView;
  final VoidCallback onOpenCache;
  final VoidCallback onOpenSettings;
  final Future<void> Function() onSummarizeAll;
  final VoidCallback onCancelBatchSummary;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F766E), Color(0xFF164E63), Color(0xFF0B1220)],
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.16),
            blurRadius: 36,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 64, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 12,
                  spacing: 16,
                  children: [
                    SizedBox(
                      width: constraints.maxWidth > 1280
                          ? 620
                          : (constraints.maxWidth > 980
                                ? 560
                                : constraints.maxWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Daily astro-ph reader',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  height: 1.1,
                                ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _MetricPill(
                                  icon: Icons.event_note_outlined,
                                  label: 'Date',
                                  value: selectedDateLabel,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: _MetricPill(
                                  icon: Icons.article_outlined,
                                  label: 'Papers',
                                  value: '$paperCount',
                                ),
                              ),
                            ],
                          ),
                          if (batchSummaryStatus != null) ...[
                            const SizedBox(height: 10),
                            _AutomationStatusBanner(
                              status: batchSummaryStatus!,
                            ),
                          ],
                        ],
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: isLoading ? null : onPickDate,
                          icon: const Icon(Icons.calendar_month_outlined),
                          label: const Text('Choose Date'),
                          style: _heroButtonStyle(),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: isLoading ? null : onFilterTopics,
                          icon: const Icon(Icons.auto_awesome_outlined),
                          label: const Text('Filter Topics'),
                          style: _heroButtonStyle(),
                        ),
                        if (isBatchSummarizing)
                          FilledButton.tonalIcon(
                            onPressed: onCancelBatchSummary,
                            icon: const Icon(Icons.stop_circle_outlined),
                            label: const Text('Cancel'),
                            style: _heroButtonStyle(),
                          )
                        else
                          FilledButton.tonalIcon(
                            onPressed: isLoading
                                ? null
                                : () => onSummarizeAll(),
                            icon: const Icon(Icons.summarize_outlined),
                            label: const Text('Summarize All Papers'),
                            style: _heroButtonStyle(),
                          ),
                        FilledButton.tonalIcon(
                          onPressed: isLoading ? null : onOpenCache,
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('Open Cache'),
                          style: _heroButtonStyle(),
                        ),
                        TextButton(
                          onPressed:
                              !hasFilteredResults ||
                                  isLoading ||
                                  isBatchSummarizing
                              ? null
                              : onTogglePaperView,
                          style: ButtonStyle(
                            foregroundColor: WidgetStateProperty.resolveWith(
                              (states) => states.contains(WidgetState.disabled)
                                  ? Colors.white.withValues(alpha: 0.38)
                                  : Colors.white,
                            ),
                            textStyle: WidgetStatePropertyAll(
                              Theme.of(context).textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          child: Text(
                            isShowingFiltered ? 'Show All' : 'Show Filtered',
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: IconButton.filledTonal(
              onPressed: isLoading ? null : onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              style: ButtonStyle(
                backgroundColor: WidgetStatePropertyAll(
                  Colors.white.withValues(alpha: 0.12),
                ),
                foregroundColor: const WidgetStatePropertyAll(Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutomationStatusBanner extends StatelessWidget {
  const _AutomationStatusBanner({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final isPaused = status.startsWith('Automatic update paused');
    final color = isPaused ? const Color(0xFFFDE68A) : const Color(0xFFA7F3D0);
    final textColor = isPaused
        ? const Color(0xFF78350F)
        : const Color(0xFF064E3B);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: isPaused
                  ? Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: textColor,
                    )
                  : CircularProgressIndicator(strokeWidth: 2, color: textColor),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PaperListPanel extends StatelessWidget {
  const _PaperListPanel({
    required this.papers,
    required this.selectedPaper,
    required this.queueScope,
    required this.paperStates,
    required this.searchController,
    required this.searchQuery,
    required this.isLoading,
    required this.errorMessage,
    required this.retryLabel,
    required this.onRetry,
    required this.onSelect,
    required this.onScopeChanged,
    required this.onSearchChanged,
  });

  final List<PaperPreview> papers;
  final PaperPreview? selectedPaper;
  final QueueScope queueScope;
  final Map<String, PaperUserState> paperStates;
  final TextEditingController searchController;
  final String searchQuery;
  final bool isLoading;
  final String? errorMessage;
  final String? retryLabel;
  final Future<void> Function()? onRetry;
  final ValueChanged<PaperPreview> onSelect;
  final ValueChanged<QueueScope> onScopeChanged;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE6F5F1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.inventory_2_outlined,
                    color: Color(0xFF0F766E),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Paper Queue',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${papers.length} results for the current view',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: QueueScope.values.map((scope) {
                          final selected = scope == queueScope;
                          return ChoiceChip(
                            label: Text(_queueScopeLabel(scope)),
                            selected: selected,
                            onSelected: (_) => onScopeChanged(scope),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: searchController,
                        onChanged: onSearchChanged,
                        decoration: InputDecoration(
                          hintText: 'Search title, author, abstract...',
                          prefixIcon: const Icon(Icons.search_outlined),
                          suffixIcon: searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    searchController.clear();
                                    onSearchChanged('');
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAF8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFDDE4E3),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFFDDE4E3),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(
                              color: Color(0xFF0F766E),
                              width: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Builder(
              builder: (context) {
                if (isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (errorMessage != null) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            errorMessage!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.red.shade700),
                          ),
                          if (onRetry != null) ...[
                            const SizedBox(height: 14),
                            FilledButton.tonalIcon(
                              onPressed: () {
                                onRetry?.call();
                              },
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(retryLabel ?? 'Retry'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }
                if (papers.isEmpty) {
                  return LayoutBuilder(
                    builder: (context, innerConstraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(28),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: math.max(
                              0,
                              innerConstraints.maxHeight - 56,
                            ),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE2E8F0),
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: const Icon(
                                    Icons.search_off_outlined,
                                    size: 34,
                                    color: Color(0xFF475569),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'No papers found',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Try another date or clear the topic filter.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: const Color(0xFF64748B),
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemBuilder: (context, index) {
                    final paper = papers[index];
                    final selected = paper == selectedPaper;
                    final paperState =
                        paperStates[paper.id] ?? const PaperUserState();
                    return InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => onSelect(paper),
                      child: Ink(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: selected
                                ? const [Color(0xFFE6FFFA), Color(0xFFF4FBFF)]
                                : const [Colors.white, Color(0xFFF7F7F4)],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF0F766E)
                                : const Color(0xFFDDE4E3),
                            width: selected ? 1.4 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF0F172A,
                              ).withValues(alpha: selected ? 0.09 : 0.04),
                              blurRadius: selected ? 18 : 10,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    margin: const EdgeInsets.only(top: 2),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? const Color(0xFF0F766E)
                                          : const Color(0xFFE2E8F0),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      selected
                                          ? Icons.radio_button_checked
                                          : Icons.article_outlined,
                                      size: 16,
                                      color: selected
                                          ? Colors.white
                                          : const Color(0xFF475569),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: LatexText(
                                      paper.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            height: 1.25,
                                            color: const Color(0xFF0F172A),
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                paper.authors,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: const Color(0xFF475569),
                                      height: 1.4,
                                    ),
                              ),
                              if (paper.matchExplanation != null &&
                                  paper.matchExplanation!.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8FAF5),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Padding(
                                        padding: EdgeInsets.only(top: 1),
                                        child: Icon(
                                          Icons.auto_awesome,
                                          size: 14,
                                          color: Color(0xFF0F766E),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          paper.matchExplanation!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: const Color(0xFF0F766E),
                                                fontWeight: FontWeight.w600,
                                                height: 1.35,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              if (paperState.isStarred ||
                                  paperState.tags.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    if (paperState.isStarred)
                                      const _MiniStateChip(
                                        icon: Icons.star,
                                        label: 'Starred',
                                      ),
                                    for (final tag in paperState.tags.take(3))
                                      _MiniStateChip(
                                        icon: Icons.sell_outlined,
                                        label: tag,
                                      ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 12),
                              LatexText(
                                paper.abstractText,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: const Color(0xFF334155),
                                      height: 1.45,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemCount: papers.length,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PaperDetailPanel extends StatelessWidget {
  const _PaperDetailPanel({
    required this.paper,
    required this.paperState,
    required this.summary,
    required this.qaHistory,
    required this.isLoading,
    required this.isSummarizing,
    required this.summaryStatus,
    required this.isAskingQuestion,
    required this.qaStatus,
    required this.isOpeningPdf,
    required this.errorMessage,
    required this.retryLabel,
    required this.onRetry,
    required this.questionController,
    required this.onSummarize,
    required this.onAskQuestion,
    required this.onOpenPdf,
    required this.onOpenWebsite,
    required this.onExportMarkdown,
    required this.onToggleStar,
  });

  final PaperPreview? paper;
  final PaperUserState? paperState;
  final PaperSummary? summary;
  final List<PaperQaExchange> qaHistory;
  final bool isLoading;
  final bool isSummarizing;
  final SummaryStatus summaryStatus;
  final bool isAskingQuestion;
  final QaStatus qaStatus;
  final bool isOpeningPdf;
  final String? errorMessage;
  final String? retryLabel;
  final Future<void> Function()? onRetry;
  final TextEditingController questionController;
  final VoidCallback onSummarize;
  final VoidCallback onAskQuestion;
  final VoidCallback onOpenPdf;
  final VoidCallback onOpenWebsite;
  final VoidCallback onExportMarkdown;
  final VoidCallback onToggleStar;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Builder(
          builder: (context) {
            if (isLoading) {
              return const Center(child: CircularProgressIndicator());
            }
            if (errorMessage != null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      errorMessage!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.red.shade700,
                      ),
                    ),
                    if (onRetry != null) ...[
                      const SizedBox(height: 14),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          onRetry?.call();
                        },
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(retryLabel ?? 'Retry'),
                      ),
                    ],
                  ],
                ),
              );
            }
            if (paper == null) {
              return const Center(
                child: Text('Choose a paper to inspect the abstract.'),
              );
            }
            final effectivePaperState = paperState ?? const PaperUserState();
            return SelectionArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0F766E), Color(0xFF164E63)],
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.menu_book_outlined,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Paper Detail',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Abstract, PDF access, and AI-generated reading notes',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    LatexText(
                      paper!.title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.12,
                            color: const Color(0xFF0F172A),
                          ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      paper!.authors,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF475569),
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _InfoChip(icon: Icons.badge_outlined, label: paper!.id),
                        if (paper!.subjects.isNotEmpty)
                          _InfoChip(
                            icon: Icons.category_outlined,
                            label: paper!.subjects,
                          ),
                        if (effectivePaperState.tags.isNotEmpty)
                          _InfoChip(
                            icon: Icons.sell_outlined,
                            label: effectivePaperState.tags.join(', '),
                          ),
                      ],
                    ),
                    if (paper!.matchExplanation != null &&
                        paper!.matchExplanation!.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFE8FAF5), Color(0xFFF3FCFF)],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFCBEDE4)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F766E),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(
                                Icons.auto_awesome,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                paper!.matchExplanation!,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: const Color(0xFF0F766E),
                                      fontWeight: FontWeight.w600,
                                      height: 1.45,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAF8),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: const Color(0xFFE2E8E3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Actions',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: isOpeningPdf ? null : onOpenPdf,
                                icon: isOpeningPdf
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.picture_as_pdf_outlined),
                                label: Text(
                                  isOpeningPdf ? 'Downloading...' : 'Open PDF',
                                ),
                              ),
                              FilledButton.icon(
                                onPressed: isSummarizing ? null : onSummarize,
                                icon: isSummarizing
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.summarize_outlined),
                                label: Text(_summaryButtonLabel()),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF0F766E),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: onToggleStar,
                                icon: Icon(
                                  effectivePaperState.isStarred
                                      ? Icons.star
                                      : Icons.star_border,
                                ),
                                label: Text(
                                  effectivePaperState.isStarred
                                      ? 'Starred'
                                      : 'Star',
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: onExportMarkdown,
                                icon: const Icon(Icons.file_download_outlined),
                                label: const Text('Export Notes'),
                              ),
                              OutlinedButton.icon(
                                onPressed: onOpenWebsite,
                                icon: const Icon(
                                  Icons.open_in_browser_outlined,
                                ),
                                label: const Text('Website'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    const _SectionLabel(
                      title: 'Abstract',
                      icon: Icons.notes_outlined,
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFEFB),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFE9E8E0)),
                      ),
                      child: LatexText(
                        paper!.abstractText,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          height: 1.72,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    if (summary != null) ...[
                      const SizedBox(height: 24),
                      _SummarySectionCard(summary: summary!),
                    ],
                    const SizedBox(height: 24),
                    _QaSectionCard(
                      questionController: questionController,
                      qaHistory: qaHistory,
                      isAskingQuestion: isAskingQuestion,
                      qaStatus: qaStatus,
                      onAskQuestion: onAskQuestion,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _summaryButtonLabel() {
    switch (summaryStatus) {
      case SummaryStatus.idle:
        return 'Summarize Paper';
      case SummaryStatus.downloadingPdf:
        return 'Downloading PDF...';
      case SummaryStatus.summarizing:
        return 'Summarizing...';
    }
  }
}

class _QaSectionCard extends StatelessWidget {
  const _QaSectionCard({
    required this.questionController,
    required this.qaHistory,
    required this.isAskingQuestion,
    required this.qaStatus,
    required this.onAskQuestion,
  });

  final TextEditingController questionController;
  final List<PaperQaExchange> qaHistory;
  final bool isAskingQuestion;
  final QaStatus qaStatus;
  final VoidCallback onAskQuestion;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFCF5), Color(0xFFF8FBFF)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE5E7DC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel(
            title: 'Ask About This Paper',
            icon: Icons.question_answer_outlined,
          ),
          const SizedBox(height: 12),
          Text(
            'Ask a paper-specific question for citation-grounded answers. Common concept questions may be answered directly without citations.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF64748B),
              height: 1.45,
            ),
          ),
          if (qaHistory.isNotEmpty) ...[
            const SizedBox(height: 18),
            for (final exchange in qaHistory.reversed)
              _QaExchangeCard(exchange: exchange),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): () {
                      if (!isAskingQuestion) {
                        onAskQuestion();
                      }
                    },
                  },
                  child: TextField(
                    controller: questionController,
                    minLines: 2,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      hintText:
                          'e.g. What is the main observational result? How does this compare to prior weak-lensing work?',
                      helperText: 'Enter to submit, Shift+Enter for a new line',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: isAskingQuestion ? null : onAskQuestion,
                icon: isAskingQuestion
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(_qaButtonLabel()),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
                  backgroundColor: const Color(0xFF164E63),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _qaButtonLabel() {
    switch (qaStatus) {
      case QaStatus.idle:
        return 'Ask';
      case QaStatus.downloadingPdf:
        return 'Downloading PDF...';
      case QaStatus.answering:
        return 'Answering...';
    }
  }
}

class _QaExchangeCard extends StatelessWidget {
  const _QaExchangeCard({required this.exchange});

  final PaperQaExchange exchange;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8E3)),
      ),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Q: ${exchange.question}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 10),
            LatexText(
              exchange.answer,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.6,
                color: const Color(0xFF334155),
              ),
            ),
            if (exchange.citations.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Evidence',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF0F766E),
                ),
              ),
              const SizedBox(height: 6),
              for (final citation in exchange.citations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: LatexText(
                    '• $citation',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF0F766E),
                      height: 1.45,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SplitDragHandle extends StatelessWidget {
  const _SplitDragHandle({required this.onDragUpdate});

  final ValueChanged<DragUpdateDetails> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: onDragUpdate,
        child: SizedBox(
          width: 18,
          child: Center(
            child: Container(
              width: 6,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFD8DEE0),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Center(
                child: Container(
                  width: 2,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF94A3B8),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SummarySectionCard extends StatelessWidget {
  const _SummarySectionCard({required this.summary});

  final PaperSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF8FAF8), Color(0xFFF1F7F5)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFDDE7E2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel(
            title: 'AI Summary',
            icon: Icons.auto_awesome_outlined,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(18),
            ),
            child: LatexText(
              summary.tldr,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.45,
                color: const Color(0xFF0F172A),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _SummaryBlock(
            title: 'Key Contributions',
            bullets: summary.keyContributions,
          ),
          _SummaryBlock(title: 'Methods', bullets: summary.methods),
          _SummaryBlock(title: 'Main Results', bullets: summary.mainResults),
          _SummaryBlock(title: 'Limitations', bullets: summary.limitations),
        ],
      ),
    );
  }
}

class _SummaryBlock extends StatelessWidget {
  const _SummaryBlock({required this.title, this.bullets = const []});

  final String title;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    if (bullets.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: const Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          for (final bullet in bullets) _BulletText(text: bullet),
        ],
      ),
    );
  }
}

class _BulletText extends StatelessWidget {
  const _BulletText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 2), child: Text('• ')),
          Expanded(
            child: LatexText(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: const Color(0xFF334155),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: Colors.white.withValues(alpha: 0.92),
    borderRadius: BorderRadius.circular(30),
    border: Border.all(color: const Color(0xFFE4E7DF)),
    boxShadow: [
      BoxShadow(
        color: const Color(0xFF0F172A).withValues(alpha: 0.08),
        blurRadius: 36,
        offset: const Offset(0, 16),
      ),
    ],
  );
}

ButtonStyle _heroButtonStyle({Color? backgroundColor, Color? foregroundColor}) {
  return FilledButton.styleFrom(
    backgroundColor: backgroundColor ?? Colors.white.withValues(alpha: 0.12),
    foregroundColor: foregroundColor ?? Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
  );
}

class _BackdropDecoration extends StatelessWidget {
  const _BackdropDecoration();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF7F7F1), Color(0xFFEFEFE7)],
            ),
          ),
        ),
        Positioned(
          top: -80,
          left: -40,
          child: _glowCircle(
            size: 260,
            colors: const [Color(0x662DD4BF), Color(0x002DD4BF)],
          ),
        ),
        Positioned(
          top: 120,
          right: -30,
          child: _glowCircle(
            size: 220,
            colors: const [Color(0x4D38BDF8), Color(0x0038BDF8)],
          ),
        ),
      ],
    );
  }

  Widget _glowCircle({required double size, required List<Color> colors}) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: colors),
        ),
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              '$label: $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFDCE4E1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF0F766E)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF334155),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFFE6F5F1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: const Color(0xFF0F766E)),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: const Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }
}

String _queueScopeLabel(QueueScope scope) {
  switch (scope) {
    case QueueScope.all:
      return 'All';
    case QueueScope.starred:
      return 'Starred';
  }
}

class _MiniStateChip extends StatelessWidget {
  const _MiniStateChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFDCE4E1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFF0F766E)),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFF334155),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class PaperPreview {
  const PaperPreview({
    required this.id,
    required this.title,
    required this.authors,
    required this.abstractText,
    required this.subjects,
    required this.pdfUrl,
    this.matchExplanation,
  });

  final String id;
  final String title;
  final String authors;
  final String abstractText;
  final String subjects;
  final String pdfUrl;
  final String? matchExplanation;

  PaperPreview copyWith({
    String? id,
    String? title,
    String? authors,
    String? abstractText,
    String? subjects,
    String? pdfUrl,
    String? matchExplanation,
  }) {
    return PaperPreview(
      id: id ?? this.id,
      title: title ?? this.title,
      authors: authors ?? this.authors,
      abstractText: abstractText ?? this.abstractText,
      subjects: subjects ?? this.subjects,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      matchExplanation: matchExplanation ?? this.matchExplanation,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'authors': authors,
      'abstractText': abstractText,
      'subjects': subjects,
      'pdfUrl': pdfUrl,
      'matchExplanation': matchExplanation,
    };
  }

  factory PaperPreview.fromJson(Map<String, dynamic> json) {
    return PaperPreview(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      authors: json['authors']?.toString() ?? '',
      abstractText: json['abstractText']?.toString() ?? '',
      subjects: json['subjects']?.toString() ?? '',
      pdfUrl: json['pdfUrl']?.toString() ?? '',
      matchExplanation: json['matchExplanation']?.toString(),
    );
  }
}

enum QueueScope { all, starred }

enum SummaryStatus { idle, downloadingPdf, summarizing }

enum QaStatus { idle, downloadingPdf, answering }

class PaperUserState {
  const PaperUserState({
    this.isStarred = false,
    this.isRead = false,
    this.inReadingList = false,
    this.tags = const [],
  });

  final bool isStarred;
  final bool isRead;
  final bool inReadingList;
  final List<String> tags;

  bool get isEmpty => !isStarred && !isRead && !inReadingList && tags.isEmpty;

  PaperUserState copyWith({
    bool? isStarred,
    bool? isRead,
    bool? inReadingList,
    List<String>? tags,
  }) {
    return PaperUserState(
      isStarred: isStarred ?? this.isStarred,
      isRead: isRead ?? this.isRead,
      inReadingList: inReadingList ?? this.inReadingList,
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'isStarred': isStarred,
      'isRead': isRead,
      'inReadingList': inReadingList,
      'tags': tags,
    };
  }

  factory PaperUserState.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    return PaperUserState(
      isStarred: json['isStarred'] == true,
      isRead: json['isRead'] == true,
      inReadingList: json['inReadingList'] == true,
      tags: rawTags is List
          ? rawTags
                .map((tag) => tag.toString().trim())
                .where((tag) => tag.isNotEmpty)
                .toList()
          : const [],
    );
  }
}

class PaperSummary {
  const PaperSummary({
    required this.tldr,
    required this.keyContributions,
    required this.methods,
    required this.mainResults,
    required this.limitations,
  });

  final String tldr;
  final List<String> keyContributions;
  final List<String> methods;
  final List<String> mainResults;
  final List<String> limitations;

  Map<String, dynamic> toJson() {
    return {
      'tldr': tldr,
      'keyContributions': keyContributions,
      'methods': methods,
      'mainResults': mainResults,
      'limitations': limitations,
    };
  }

  factory PaperSummary.fromJson(Map<String, dynamic> json) {
    List<String> readList(String key) {
      final raw = json[key];
      if (raw is List) {
        return raw
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
      return const [];
    }

    return PaperSummary(
      tldr: json['tldr']?.toString().trim() ?? '',
      keyContributions: readList('keyContributions'),
      methods: readList('methods'),
      mainResults: readList('mainResults'),
      limitations: readList('limitations'),
    );
  }
}

class PaperQaExchange {
  const PaperQaExchange({
    required this.question,
    required this.answer,
    required this.citations,
    required this.askedAtIso8601,
  });

  final String question;
  final String answer;
  final List<String> citations;
  final String askedAtIso8601;

  PaperQaExchange copyWith({
    String? question,
    String? answer,
    List<String>? citations,
    String? askedAtIso8601,
  }) {
    return PaperQaExchange(
      question: question ?? this.question,
      answer: answer ?? this.answer,
      citations: citations ?? this.citations,
      askedAtIso8601: askedAtIso8601 ?? this.askedAtIso8601,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'question': question,
      'answer': answer,
      'citations': citations,
      'askedAtIso8601': askedAtIso8601,
    };
  }

  factory PaperQaExchange.fromJson(Map<String, dynamic> json) {
    final rawCitations = json['citations'];
    return PaperQaExchange(
      question: json['question']?.toString().trim() ?? '',
      answer: json['answer']?.toString().trim() ?? '',
      citations: rawCitations is List
          ? rawCitations
                .map((item) => item.toString().trim())
                .where((item) => item.isNotEmpty)
                .toList()
          : const [],
      askedAtIso8601: json['askedAtIso8601']?.toString().trim() ?? '',
    );
  }
}

class ArxivService {
  Future<List<PaperPreview>> fetchAstroPhPapers(DateTime date) async {
    final formattedDate = _formatDate(date);
    final url = Uri.parse(
      'https://arxiv.org/catchup/astro-ph/$formattedDate?abs=True',
    );
    final response = await http.get(url);

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch arXiv papers for $formattedDate.');
    }

    final document = html_parser.parse(utf8.decode(response.bodyBytes));
    final submissionList = document.querySelector('dl');

    if (submissionList == null) {
      return const [];
    }

    final entries = submissionList.children.whereType<dom.Element>().toList();
    final papers = <PaperPreview>[];

    for (var i = 0; i < entries.length - 1; i++) {
      final current = entries[i];
      final next = entries[i + 1];

      if (current.localName != 'dt' || next.localName != 'dd') {
        continue;
      }

      final title =
          next
              .querySelector('div.list-title.mathjax')
              ?.text
              .replaceFirst('Title:', '')
              .trim() ??
          'No title';

      final abstractText =
          next.querySelector('p.mathjax')?.text.trim() ??
          'No abstract provided.';

      final authors = next
          .querySelectorAll('div.list-authors a')
          .map((author) => author.text.trim())
          .where((author) => author.isNotEmpty)
          .join(', ');

      final subjects =
          next.querySelector('div.list-subjects')?.text.trim() ?? '';
      final absAnchor = current.querySelector('a[href*="/abs/"]');
      final paperId = absAnchor == null
          ? '$formattedDate-$i'
          : (absAnchor.attributes['href'] ?? '').split('/').last;
      final pdfAnchor = current.querySelector('a[title="Download PDF"]');
      final pdfUrl = pdfAnchor == null
          ? _pdfUrlForPaperId(paperId)
          : _absoluteArxivUrl(pdfAnchor.attributes['href'] ?? '');

      papers.add(
        PaperPreview(
          id: paperId,
          title: _sanitizeArxivText(title),
          authors: _sanitizeArxivText(authors),
          abstractText: _sanitizeArxivText(abstractText),
          subjects: _sanitizeArxivText(subjects),
          pdfUrl: pdfUrl,
        ),
      );
    }

    return papers;
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  String _absoluteArxivUrl(String href) {
    final trimmed = href.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      return trimmed;
    }
    return Uri.https(
      'arxiv.org',
      trimmed.startsWith('/') ? trimmed : '/$trimmed',
    ).toString();
  }

  String _pdfUrlForPaperId(String paperId) {
    return Uri.https('arxiv.org', '/pdf/${paperId.trim()}').toString();
  }

  String _collapseWhitespace(String input) {
    return input.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _sanitizeArxivText(String input) {
    var output = input;

    output = output.replaceAllMapped(
      RegExp(r'\{\\em\s+([^{}]+)\}'),
      (match) => match.group(1) ?? '',
    );
    output = output.replaceAllMapped(
      RegExp(r'\{\\it\s+([^{}]+)\}'),
      (match) => match.group(1) ?? '',
    );

    for (final command in const [
      'emph',
      'textit',
      'textbf',
      'textsc',
      'mathrm',
      'mathbf',
      'mathit',
      'textrm',
      'texttt',
      'url',
    ]) {
      final pattern = RegExp('\\\\$command\\{([^{}]*)\\}');
      var previous = '';
      while (previous != output) {
        previous = output;
        output = output.replaceAllMapped(
          pattern,
          (match) => match.group(1) ?? '',
        );
      }
    }

    for (final entry in const {
      'alpha': 'α',
      'beta': 'β',
      'gamma': 'γ',
      'delta': 'δ',
      'epsilon': 'ϵ',
      'varepsilon': 'ε',
      'lambda': 'λ',
      'mu': 'μ',
      'nu': 'ν',
      'pi': 'π',
      'sigma': 'σ',
      'tau': 'τ',
      'phi': 'φ',
      'varphi': 'ϕ',
      'psi': 'ψ',
      'omega': 'ω',
      'times': '×',
      'sim': '∼',
      'approx': '≈',
      'lesssim': '≲',
      'gtrsim': '≳',
      'leq': '≤',
      'geq': '≥',
    }.entries) {
      output = output.replaceAll('\\${entry.key}', entry.value);
    }

    output = output
        .replaceAll(r'\,', ' ')
        .replaceAll(r'\%', '%')
        .replaceAll(r'\&', '&')
        .replaceAll(r'\_', '_')
        .replaceAll(r'\\', ' ')
        .replaceAll('{', '')
        .replaceAll('}', '');

    return _collapseWhitespace(output);
  }
}

class GeminiFilterService {
  static const String _apiBase = 'https://generativelanguage.googleapis.com';
  static const String _uploadBase =
      'https://generativelanguage.googleapis.com/upload';

  Future<List<PaperPreview>> filterPapers({
    required List<PaperPreview> papers,
    required String topics,
    required String apiKey,
    required String model,
  }) async {
    if (papers.isEmpty) {
      return const [];
    }

    final requestUrl = Uri.parse(
      '$_apiBase/v1beta/models/$model:generateContent',
    );

    final requestBody = {
      'contents': [
        {
          'parts': [
            {
              'text':
                  '''
You are an expert astrophysics research assistant.

The user is interested in these topics:
$topics

You will be given a JSON array of papers with id, title, authors, abstract, and subjects.
Return valid JSON only.

Return an array of objects. Each object must contain exactly:
- "id": string
- "relevant": boolean
- "matched_topics": string[]

If a paper clearly matches at least one of the user's topics, mark it as relevant.
Use the title, abstract, and subject line. The match does not need to cover all topics.
Be reasonably inclusive for papers that are genuinely relevant to any one topic.
For "matched_topics", return only the specific user topics that match this paper.
Do not write sentence explanations.

Papers:
${jsonEncode(papers.map((paper) => {'id': paper.id, 'title': paper.title, 'authors': paper.authors, 'abstract': paper.abstractText, 'subjects': paper.subjects}).toList())}
''',
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        'responseMimeType': 'application/json',
      },
    };

    final response = await http.post(
      requestUrl,
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      throw Exception(_geminiError('filter papers', response));
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      return const [];
    }

    final parts =
        (candidates.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>?;
    final textParts = parts?['parts'] as List<dynamic>?;
    final rawText = textParts != null && textParts.isNotEmpty
        ? (textParts.first as Map<String, dynamic>)['text'] as String? ?? '[]'
        : '[]';

    final parsed = _jsonListFromText(rawText, 'Gemini topic filter');
    final relevantById = <String, String>{};

    for (final item in parsed) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final relevant = item['relevant'] == true;
      final id = item['id']?.toString() ?? '';
      if (relevant && id.isNotEmpty) {
        final matchedTopics = item['matched_topics'] is List
            ? (item['matched_topics'] as List<dynamic>)
                  .map((topic) => topic.toString().trim())
                  .where((topic) => topic.isNotEmpty)
                  .toList()
            : const <String>[];
        relevantById[id] = matchedTopics.join(' • ');
      }
    }

    return papers
        .where((paper) => relevantById.containsKey(paper.id))
        .map(
          (paper) => paper.copyWith(matchExplanation: relevantById[paper.id]),
        )
        .toList();
  }

  Future<PaperSummary> summarizePaper({
    required PaperPreview paper,
    required File pdfFile,
    required String apiKey,
    required String model,
    required String markdown,
  }) async {
    return _retrySummaryRequest(
      () => _summarizePaperOnce(
        paper: paper,
        pdfFile: pdfFile,
        apiKey: apiKey,
        model: model,
        markdown: markdown,
      ),
    );
  }

  Future<PaperSummary> _summarizePaperOnce({
    required PaperPreview paper,
    required File pdfFile,
    required String apiKey,
    required String model,
    required String markdown,
  }) async {
    final uploadedFile = await _uploadPdf(pdfFile, apiKey);
    final activeFile = await _waitForFileActive(
      fileName: uploadedFile.name,
      apiKey: apiKey,
    );

    final requestUrl = Uri.parse(
      '$_apiBase/v1beta/models/$model:generateContent',
    );
    final requestBody = {
      'contents': [
        {
          'parts': [
            {
              'text':
                  '''
You are reading an arXiv paper in astrophysics.

Return valid JSON only with exactly these fields:
- "tldr": string
- "keyContributions": string[]
- "methods": string[]
- "mainResults": string[]
- "limitations": string[]

Keep the summary concise, accurate, and useful for a researcher scanning papers.
Base your answer on the uploaded PDF.
Every summary item must include supporting page references when possible, such as "(p. 4)" or "(pp. 4-5)".
Do not invent page numbers. If a page reference is uncertain, omit it rather than guessing.
Paper title: ${paper.title}
Authors: ${paper.authors}
''',
            },
            {'text': _markdownContext(markdown)},
            {
              'file_data': {
                'mime_type': activeFile.mimeType,
                'file_uri': activeFile.uri,
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.2,
        'responseMimeType': 'application/json',
      },
    };

    final response = await http.post(
      requestUrl,
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      throw Exception(_geminiError('summarize paper', response));
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Gemini did not return a summary.');
    }

    final content =
        (candidates.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>?;
    final textParts = content?['parts'] as List<dynamic>?;
    final rawText = textParts != null && textParts.isNotEmpty
        ? (textParts.first as Map<String, dynamic>)['text'] as String? ?? '{}'
        : '{}';

    final parsed = _jsonObjectFromText(rawText, 'Gemini paper summary');
    return PaperSummary.fromJson(parsed);
  }

  Future<PaperSummary> _retrySummaryRequest(
    Future<PaperSummary> Function() request,
  ) async {
    const maxAttempts = 3;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await request();
      } catch (error) {
        lastError = error;
        if (attempt == maxAttempts || !_isRetryableGeminiError(error)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(seconds: attempt * 4));
      }
    }

    throw StateError('Summary request failed unexpectedly: $lastError');
  }

  bool _isRetryableGeminiError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('rate limit') ||
        message.contains('http 500') ||
        message.contains('http 502') ||
        message.contains('http 503') ||
        message.contains('http 504') ||
        message.contains('timed out') ||
        message.contains('socketexception') ||
        message.contains('connection');
  }

  Future<PaperQaExchange> answerQuestionAboutPaper({
    required PaperPreview paper,
    required File pdfFile,
    required String question,
    required String apiKey,
    required String model,
    required String markdown,
  }) async {
    final uploadedFile = await _uploadPdf(pdfFile, apiKey);
    final activeFile = await _waitForFileActive(
      fileName: uploadedFile.name,
      apiKey: apiKey,
    );

    final requestUrl = Uri.parse(
      '$_apiBase/v1beta/models/$model:generateContent',
    );
    final requestBody = {
      'contents': [
        {
          'parts': [
            {
              'text':
                  '''
You are helping a researcher read an arXiv paper in astrophysics.

Answer the user's question using the uploaded PDF when the question is about this paper.
If the question is mainly a general concept or term explanation, you may answer directly without citing the paper.

Return valid JSON only with exactly these fields:
- "question": string
- "answer": string
- "citations": string[]

Rules:
- If the answer depends on the paper, cite supporting page references when possible, such as "p. 4" or "pp. 4-5".
- For paper-grounded answers, "citations" should contain short evidence notes with page references.
- For general knowledge or concept explanations, "citations" may be an empty array.
- Do not invent citations or page numbers.
- Keep the answer concise but useful.

Paper title: ${paper.title}
Authors: ${paper.authors}
User question: $question
''',
            },
            {'text': _markdownContext(markdown)},
            {
              'file_data': {
                'mime_type': activeFile.mimeType,
                'file_uri': activeFile.uri,
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.2,
        'responseMimeType': 'application/json',
      },
    };

    final response = await http.post(
      requestUrl,
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      throw Exception(_geminiError('answer the question', response));
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Gemini did not return an answer.');
    }

    final content =
        (candidates.first as Map<String, dynamic>)['content']
            as Map<String, dynamic>?;
    final textParts = content?['parts'] as List<dynamic>?;
    final rawText = textParts != null && textParts.isNotEmpty
        ? (textParts.first as Map<String, dynamic>)['text'] as String? ?? '{}'
        : '{}';

    final parsed = _jsonObjectFromText(rawText, 'Gemini paper Q&A');
    return PaperQaExchange.fromJson(parsed);
  }

  Future<void> testConnection({
    required String apiKey,
    required String model,
  }) async {
    final requestUrl = Uri.parse(
      '$_apiBase/v1beta/models/$model:generateContent',
    );
    final response = await http.post(
      requestUrl,
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': 'Reply with the single word: ready'},
            ],
          },
        ],
        'generationConfig': {'temperature': 0, 'maxOutputTokens': 8},
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(_geminiError('test the Gemini connection', response));
    }
  }

  Future<void> testOpenAiConnection({
    required String apiKey,
    required String model,
  }) async {
    final response = await http.get(
      Uri.parse('https://api.openai.com/v1/models/$model'),
      headers: {'Authorization': 'Bearer $apiKey'},
    );
    if (response.statusCode != 200) {
      throw Exception(
        'OpenAI could not verify the API key or selected model (HTTP ${response.statusCode}).',
      );
    }
  }

  Future<_GeminiUploadedFile> _uploadPdf(File pdfFile, String apiKey) async {
    final bytes = await pdfFile.readAsBytes();
    final startUrl = Uri.parse('$_uploadBase/v1beta/files?key=$apiKey');

    final startResponse = await http.post(
      startUrl,
      headers: {
        'X-Goog-Upload-Protocol': 'resumable',
        'X-Goog-Upload-Command': 'start',
        'X-Goog-Upload-Header-Content-Length': bytes.length.toString(),
        'X-Goog-Upload-Header-Content-Type': 'application/pdf',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'file': {
          'display_name': pdfFile.uri.pathSegments.isNotEmpty
              ? pdfFile.uri.pathSegments.last
              : 'paper.pdf',
        },
      }),
    );

    if (startResponse.statusCode < 200 || startResponse.statusCode >= 300) {
      throw Exception(_geminiError('start PDF upload', startResponse));
    }

    final uploadUrl = startResponse.headers['x-goog-upload-url'];
    if (uploadUrl == null || uploadUrl.isEmpty) {
      throw Exception('Gemini did not return an upload URL.');
    }

    final uploadResponse = await http.post(
      Uri.parse(uploadUrl),
      headers: {
        'Content-Length': bytes.length.toString(),
        'X-Goog-Upload-Offset': '0',
        'X-Goog-Upload-Command': 'upload, finalize',
      },
      body: bytes,
    );

    if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 300) {
      throw Exception(_geminiError('upload PDF', uploadResponse));
    }

    final decoded = jsonDecode(uploadResponse.body) as Map<String, dynamic>;
    final file = decoded['file'] as Map<String, dynamic>?;
    if (file == null) {
      throw Exception('Gemini upload response did not contain file metadata.');
    }

    final name = file['name']?.toString() ?? '';
    final uri = file['uri']?.toString() ?? '';
    final mimeType = file['mimeType']?.toString() ?? 'application/pdf';
    if (name.isEmpty || uri.isEmpty) {
      throw Exception('Gemini upload returned incomplete file metadata.');
    }

    return _GeminiUploadedFile(name: name, uri: uri, mimeType: mimeType);
  }

  Future<_GeminiUploadedFile> _waitForFileActive({
    required String fileName,
    required String apiKey,
  }) async {
    final requestUrl = Uri.parse('$_apiBase/v1beta/$fileName?key=$apiKey');

    for (var attempt = 0; attempt < 18; attempt++) {
      final response = await http.get(requestUrl);
      if (response.statusCode != 200) {
        throw Exception(_geminiError('check PDF processing', response));
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final state = decoded['state']?.toString() ?? 'STATE_UNSPECIFIED';
      final name = decoded['name']?.toString() ?? fileName;
      final uri = decoded['uri']?.toString() ?? '';
      final mimeType = decoded['mimeType']?.toString() ?? 'application/pdf';

      if (state == 'ACTIVE') {
        return _GeminiUploadedFile(name: name, uri: uri, mimeType: mimeType);
      }
      if (state == 'FAILED') {
        throw Exception('Gemini failed to process the uploaded PDF.');
      }

      await Future<void>.delayed(const Duration(seconds: 3));
    }

    throw Exception('Gemini file processing timed out.');
  }

  String _markdownContext(String markdown) {
    const maxCharacters = 240000;
    final normalized = markdown.trim();
    final content = normalized.length <= maxCharacters
        ? normalized
        : '${normalized.substring(0, maxCharacters)}\n\n[Markdown truncated for context length.]';
    return '''
The following Markdown was extracted locally from the same PDF. Use it to read
the paper's text, section structure, and tables. Keep the original PDF as the
source for figures, equations, page layout, and any details missing here.

--- Extracted Markdown ---
$content
--- End Extracted Markdown ---
''';
  }

  String _geminiError(String action, http.Response response) {
    String? apiMessage;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          apiMessage = error['message']?.toString();
        }
      }
    } on FormatException {
      apiMessage = null;
    }

    final message = apiMessage?.trim();
    if (response.statusCode == 401 || response.statusCode == 403) {
      return 'Gemini could not authenticate the API key. Check it in Settings and try again.';
    }
    if (response.statusCode == 404) {
      return 'Gemini could not find the selected model. Update the app or try again later.';
    }
    if (response.statusCode == 429) {
      return 'Gemini rate limit reached. Please wait a moment and retry.';
    }
    if (message != null && message.isNotEmpty) {
      return 'Gemini could not $action: $message';
    }
    return 'Gemini could not $action (HTTP ${response.statusCode}). Please retry.';
  }
}

class OpenAiPaperService {
  static const _apiBase = 'https://api.openai.com/v1';

  Future<List<PaperPreview>> filterPapers({
    required List<PaperPreview> papers,
    required String topics,
    required String apiKey,
    required String model,
  }) async {
    if (papers.isEmpty) return const [];
    final text = await _responseText(
      apiKey: apiKey,
      model: model,
      responseFormat: _jsonSchemaFormat(
        name: 'paper_topic_filter',
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'required': ['papers'],
          'properties': {
            'papers': {
              'type': 'array',
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'required': ['id', 'relevant', 'matched_topics'],
                'properties': {
                  'id': {'type': 'string'},
                  'relevant': {'type': 'boolean'},
                  'matched_topics': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
              },
            },
          },
        },
      ),
      prompt:
          '''You are an expert astrophysics research assistant. The user is interested in: $topics
Return a JSON object with a "papers" array. Each item must have id, relevant, and matched_topics. Mark a paper relevant when it matches at least one user topic. Be inclusive but do not explain.
Papers: ${jsonEncode(papers.map((paper) => {'id': paper.id, 'title': paper.title, 'authors': paper.authors, 'abstract': paper.abstractText, 'subjects': paper.subjects}).toList())}''',
    );
    final parsed = _decodeJsonObject(text, 'OpenAI topic filter');
    final paperItems = parsed['papers'] as List<dynamic>? ?? const [];
    final matches = <String, String>{};
    for (final item in paperItems.whereType<Map<String, dynamic>>()) {
      if (item['relevant'] == true && item['id'] != null) {
        final topics = (item['matched_topics'] as List<dynamic>? ?? const [])
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .join(' • ');
        matches[item['id'].toString()] = topics;
      }
    }
    return papers
        .where((paper) => matches.containsKey(paper.id))
        .map((paper) => paper.copyWith(matchExplanation: matches[paper.id]))
        .toList();
  }

  Future<PaperSummary> summarizePaper({
    required PaperPreview paper,
    required File pdfFile,
    required String apiKey,
    required String model,
    required String markdown,
  }) async {
    final text = await _responseText(
      apiKey: apiKey,
      model: model,
      pdfFile: pdfFile,
      responseFormat: _jsonSchemaFormat(
        name: 'paper_summary',
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'required': [
            'tldr',
            'keyContributions',
            'methods',
            'mainResults',
            'limitations',
          ],
          'properties': {
            'tldr': {'type': 'string'},
            'keyContributions': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'methods': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'mainResults': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'limitations': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
        },
      ),
      prompt:
          '''You are reading an arXiv paper in astrophysics. Return JSON only with exactly: tldr (string), keyContributions (string[]), methods (string[]), mainResults (string[]), limitations (string[]).
Be concise and accurate. Base the answer on the PDF and the extracted Markdown below. Include supporting page references when possible, but never invent them.
Paper title: ${paper.title}
Authors: ${paper.authors}

${_markdownContext(markdown)}''',
    );
    return PaperSummary.fromJson(
      _decodeJsonObject(text, 'OpenAI paper summary'),
    );
  }

  Future<PaperQaExchange> answerQuestionAboutPaper({
    required PaperPreview paper,
    required File pdfFile,
    required String question,
    required String apiKey,
    required String model,
    required String markdown,
  }) async {
    final text = await _responseText(
      apiKey: apiKey,
      model: model,
      pdfFile: pdfFile,
      responseFormat: _jsonSchemaFormat(
        name: 'paper_question_answer',
        schema: {
          'type': 'object',
          'additionalProperties': false,
          'required': ['question', 'answer', 'citations'],
          'properties': {
            'question': {'type': 'string'},
            'answer': {'type': 'string'},
            'citations': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
        },
      ),
      prompt:
          '''You are helping a researcher read an arXiv paper. Return JSON only with exactly question (string), answer (string), citations (string[]).
Answer using the PDF and the extracted Markdown below when the question concerns this paper. General concept questions may have an empty citations array. Cite page references when possible; never invent citations.
Paper title: ${paper.title}
User question: $question

${_markdownContext(markdown)}''',
    );
    return PaperQaExchange.fromJson(
      _decodeJsonObject(text, 'OpenAI paper Q&A'),
    );
  }

  Future<String> _responseText({
    required String apiKey,
    required String model,
    required String prompt,
    required Map<String, dynamic> responseFormat,
    File? pdfFile,
  }) async {
    String? fileId;
    try {
      if (pdfFile != null) {
        fileId = await _uploadPdf(pdfFile, apiKey);
      }
      final content = <Map<String, dynamic>>[
        {'type': 'input_text', 'text': prompt},
      ];
      if (fileId != null) {
        content.add({'type': 'input_file', 'file_id': fileId});
      }
      final response = await http.post(
        Uri.parse('$_apiBase/responses'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': model,
          'input': [
            {'role': 'user', 'content': content},
          ],
          'text': {'format': responseFormat},
        }),
      );
      if (response.statusCode != 200) {
        throw Exception(_error('create a response', response));
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final output = decoded['output'] as List<dynamic>? ?? const [];
      for (final message in output.whereType<Map<String, dynamic>>()) {
        for (final part
            in (message['content'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()) {
          if (part['type'] == 'output_text' && part['text'] is String) {
            return part['text'] as String;
          }
        }
      }
      throw Exception('OpenAI did not return text output.');
    } finally {
      if (fileId != null) {
        await _deleteFile(fileId, apiKey);
      }
    }
  }

  Future<String> _uploadPdf(File file, String apiKey) async {
    final request = http.MultipartRequest('POST', Uri.parse('$_apiBase/files'))
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['purpose'] = 'user_data'
      ..files.add(
        await http.MultipartFile.fromPath(
          'file',
          file.path,
          filename: file.uri.pathSegments.last,
        ),
      );
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      throw Exception(_error('upload the PDF', response));
    }
    final id = (jsonDecode(response.body) as Map<String, dynamic>)['id']
        ?.toString();
    if (id == null || id.isEmpty) {
      throw Exception('OpenAI did not return a file ID.');
    }
    return id;
  }

  Future<void> _deleteFile(String id, String apiKey) async {
    try {
      await http.delete(
        Uri.parse('$_apiBase/files/$id'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );
    } catch (_) {}
  }

  String _stripFence(String text) => text
      .trim()
      .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
      .replaceFirst(RegExp(r'\s*```$'), '');

  Map<String, dynamic> _jsonSchemaFormat({
    required String name,
    required Map<String, dynamic> schema,
  }) {
    return {
      'type': 'json_schema',
      'name': name,
      'strict': true,
      'schema': schema,
    };
  }

  Map<String, dynamic> _decodeJsonObject(String text, String context) {
    return _jsonObjectFromText(_stripFence(text), context);
  }

  String _markdownContext(String markdown) {
    const maxCharacters = 240000;
    final normalized = markdown.trim();
    if (normalized.isEmpty) {
      return 'No local Markdown extraction was available; rely on the uploaded PDF.';
    }
    final content = normalized.length <= maxCharacters
        ? normalized
        : '${normalized.substring(0, maxCharacters)}\n\n[Markdown truncated for context length.]';
    return '''
The following Markdown was extracted locally from the same PDF. Use it to read
the paper's text, section structure, and tables. Keep the original PDF as the
source for figures, equations, page layout, and any details missing here.

--- Extracted Markdown ---
$content
--- End Extracted Markdown ---
''';
  }

  String _error(String action, http.Response response) {
    try {
      final decoded = _jsonObjectFromText(response.body, 'OpenAI error');
      final error = decoded['error'];
      if (error is Map) {
        final message = error['message'];
        if (message != null) {
          return 'OpenAI could not $action: $message';
        }
      }
    } catch (_) {}
    return 'OpenAI could not $action (HTTP ${response.statusCode}).';
  }
}

class MarkItDownService {
  Future<void> convertPdfToMarkdown({
    required File pdfFile,
    required File markdownFile,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      throw Exception(
        'Local PDF-to-Markdown conversion is available in the macOS and Windows desktop apps only.',
      );
    }

    final bundledExecutable = _bundledExecutable();
    if (!await bundledExecutable.exists()) {
      throw Exception(
        'The bundled MarkItDown converter is missing. Reinstall the app and retry.',
      );
    }

    final result = await Process.run(bundledExecutable.path, [
      pdfFile.path,
      markdownFile.path,
    ]);
    if (result.exitCode != 0) {
      final details = result.stderr.toString().trim();
      throw Exception(
        details.isEmpty ? 'MarkItDown could not convert the PDF.' : details,
      );
    }

    if (!await markdownFile.exists() || await markdownFile.length() == 0) {
      throw Exception('MarkItDown did not produce Markdown for this PDF.');
    }
  }

  File _bundledExecutable() {
    final appExecutable = File(Platform.resolvedExecutable);
    if (Platform.isWindows) {
      return File(
        '${appExecutable.parent.path}/data/arxiv_markitdown/arxiv_markitdown.exe',
      );
    }
    return File(
      '${appExecutable.parent.parent.path}/Resources/arxiv_markitdown/arxiv_markitdown',
    );
  }
}

class AppCacheService {
  static const String cacheDirectoryPreferenceKey = 'cache_directory_path';
  static const String exportDirectoryPreferenceKey = 'export_directory_path';
  static const String defaultCacheLeafPath = 'arXivReader_AI/cache';
  static const String defaultExportLeafPath = 'arXivReader_AI/exports';
  final MarkItDownService _markItDownService = MarkItDownService();

  Future<Directory> ensureCacheRoot({String? overridePath}) async {
    final directory = await _ensureDirectory(
      await _resolveStoragePath(
        preferenceKey: cacheDirectoryPreferenceKey,
        defaultLeafPath: defaultCacheLeafPath,
        overridePath: overridePath,
      ),
    );
    await _migrateDocumentsRootCacheIfNeeded(directory);
    return directory;
  }

  Future<Directory> ensureExportRoot({String? overridePath}) async {
    return _ensureDirectory(
      await _resolveStoragePath(
        preferenceKey: exportDirectoryPreferenceKey,
        defaultLeafPath: defaultExportLeafPath,
        overridePath: overridePath,
      ),
    );
  }

  Future<int> cacheSizeBytes({String? overridePath}) async {
    final root = await ensureCacheRoot(overridePath: overridePath);
    var totalBytes = 0;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      try {
        totalBytes += await entity.length();
      } on FileSystemException {
        // A file can disappear while the cache is being cleared or updated.
      }
    }
    return totalBytes;
  }

  static String formatStorageSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  Future<Directory> _ensureSubdirectory(String name) async {
    final root = await ensureCacheRoot();
    final directory = Directory('${root.path}/$name');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> saveAllPapers(DateTime date, List<PaperPreview> papers) async {
    final file = await _allPapersFile(date);
    await file.writeAsString(
      jsonEncode(papers.map((paper) => paper.toJson()).toList()),
    );
  }

  Future<List<PaperPreview>?> loadAllPapers(DateTime date) async {
    final file = await _allPapersFile(date);
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(PaperPreview.fromJson)
        .toList();
  }

  Future<void> saveFilteredPapers(
    DateTime date,
    String topics,
    List<PaperPreview> papers,
  ) async {
    final file = await _filteredPapersFile(date, topics);
    await file.writeAsString(
      jsonEncode({
        'topics': topics,
        'papers': papers.map((paper) => paper.toJson()).toList(),
      }),
    );
  }

  Future<List<PaperPreview>?> loadFilteredPapers(
    DateTime date,
    String topics,
  ) async {
    final file = await _filteredPapersFile(date, topics);
    if (!await file.exists()) {
      return null;
    }
    final decoded = _jsonObjectFromText(
      await file.readAsString(),
      'cached filtered papers',
    );
    final papers = decoded['papers'] as List<dynamic>? ?? const [];
    return papers
        .whereType<Map<String, dynamic>>()
        .map(PaperPreview.fromJson)
        .toList();
  }

  Future<File> ensurePdfDownloaded(PaperPreview paper) async {
    final directory = await _ensureSubdirectory('pdfs');
    final safeId = _safeFileName(paper.id);
    final file = File('${directory.path}/$safeId.pdf');

    if (await file.exists() && await file.length() > 0) {
      return file;
    }

    if (await file.exists()) {
      await file.delete();
    }

    final urls = _candidatePdfUrls(paper);
    if (urls.isEmpty) {
      throw Exception('No PDF URL is available for ${paper.id}.');
    }

    final errors = <String>[];
    for (final url in urls) {
      try {
        final bytes = await _downloadPdfBytes(url);
        await file.writeAsBytes(bytes);
        return file;
      } catch (error) {
        errors.add('$url -> $error');
      }
    }

    throw Exception(
      'Failed to download PDF for ${paper.id}. Tried ${urls.length} URL'
      '${urls.length == 1 ? '' : 's'}: ${errors.join(' | ')}',
    );
  }

  List<String> _candidatePdfUrls(PaperPreview paper) {
    final urls = <String>[];
    final existing = paper.pdfUrl.trim();
    if (existing.isNotEmpty) {
      urls.add(existing);
    }

    final fallback = _pdfUrlForPaperId(paper.id);
    if (!urls.contains(fallback)) {
      urls.add(fallback);
    }
    return urls;
  }

  Future<List<int>> _downloadPdfBytes(String url) async {
    final uri = Uri.parse(url);
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await http.get(
          uri,
          headers: const {
            'Accept': 'application/pdf,*/*;q=0.8',
            'User-Agent':
                'ArxivReaderAI/1.0 (+https://arxiv.org; local research reader)',
          },
        );
        if (response.statusCode == 200 && _looksLikePdf(response.bodyBytes)) {
          return response.bodyBytes;
        }

        final contentType = response.headers['content-type'] ?? 'unknown';
        final preview = utf8
            .decode(response.bodyBytes.take(160).toList(), allowMalformed: true)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        lastError =
            'HTTP ${response.statusCode}, content-type $contentType'
            '${preview.isEmpty ? '' : ', body "$preview"'}';
      } catch (error) {
        lastError = error;
      }

      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }

    throw Exception(lastError ?? 'unknown download error');
  }

  bool _looksLikePdf(List<int> bytes) {
    if (bytes.length < 4) {
      return false;
    }
    return bytes[0] == 0x25 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x44 &&
        bytes[3] == 0x46;
  }

  Future<File> ensureMarkdownConverted({
    required PaperPreview paper,
    required File pdfFile,
  }) async {
    final markdownFile = await _markdownFile(paper.id);
    if (await markdownFile.exists() && await markdownFile.length() > 0) {
      return markdownFile;
    }

    await _markItDownService.convertPdfToMarkdown(
      pdfFile: pdfFile,
      markdownFile: markdownFile,
    );
    return markdownFile;
  }

  Future<bool> hasMarkdownConverted(String paperId) async {
    final markdownFile = await _markdownFile(paperId);
    return await markdownFile.exists() && await markdownFile.length() > 0;
  }

  Future<void> saveSummary(String paperId, PaperSummary summary) async {
    final file = await _summaryFile(paperId);
    await file.writeAsString(jsonEncode(summary.toJson()));
  }

  Future<PaperSummary?> loadSummary(String paperId) async {
    final file = await _summaryFile(paperId);
    if (!await file.exists()) {
      return null;
    }
    final decoded = _jsonObjectFromText(
      await file.readAsString(),
      'cached paper summary',
    );
    return PaperSummary.fromJson(decoded);
  }

  Future<void> saveQaHistory(
    String paperId,
    List<PaperQaExchange> history,
  ) async {
    final file = await _qaHistoryFile(paperId);
    await file.writeAsString(
      jsonEncode(history.map((entry) => entry.toJson()).toList()),
    );
  }

  Future<List<PaperQaExchange>> loadQaHistory(String paperId) async {
    final file = await _qaHistoryFile(paperId);
    if (!await file.exists()) {
      return const [];
    }

    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(PaperQaExchange.fromJson)
        .toList();
  }

  Future<void> savePaperStates(Map<String, PaperUserState> states) async {
    final file = await _paperStatesFile();
    await file.writeAsString(
      jsonEncode(
        states.map((paperId, state) => MapEntry(paperId, state.toJson())),
      ),
    );
  }

  Future<Map<String, PaperUserState>> loadPaperStates() async {
    final file = await _paperStatesFile();
    if (!await file.exists()) {
      return const {};
    }

    final decoded = _jsonObjectFromText(
      await file.readAsString(),
      'cached paper states',
    );
    final states = <String, PaperUserState>{};

    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        states[entry.key] = PaperUserState.fromJson(value);
      } else if (value is Map) {
        states[entry.key] = PaperUserState.fromJson(
          Map<String, dynamic>.from(value),
        );
      }
    }

    return states;
  }

  Future<File> _allPapersFile(DateTime date) async {
    final directory = await _ensureSubdirectory('all_papers');
    return File('${directory.path}/${_formatDate(date)}.json');
  }

  Future<File> _filteredPapersFile(DateTime date, String topics) async {
    final directory = await _ensureSubdirectory('filtered_papers');
    return File(
      '${directory.path}/${_formatDate(date)}_${_topicsHash(topics)}.json',
    );
  }

  Future<File> _summaryFile(String paperId) async {
    final directory = await _ensureSubdirectory('summaries');
    return File('${directory.path}/${_safeFileName(paperId)}.json');
  }

  Future<File> _markdownFile(String paperId) async {
    final directory = await _ensureSubdirectory('markdown');
    return File('${directory.path}/${_safeFileName(paperId)}.md');
  }

  Future<File> _qaHistoryFile(String paperId) async {
    final directory = await _ensureSubdirectory('qa_history');
    return File('${directory.path}/${_safeFileName(paperId)}.json');
  }

  Future<File> exportPaperMarkdown({
    required String paperId,
    required String markdown,
  }) async {
    final directory = await ensureExportRoot();
    final file = File('${directory.path}/${_safeFileName(paperId)}.md');
    await file.writeAsString(markdown);
    return file;
  }

  Future<void> clearCache({
    String? overridePath,
    Set<CacheSection>? sections,
  }) async {
    final root = await ensureCacheRoot(overridePath: overridePath);
    final targetSections = sections ?? CacheSection.values.toSet();

    for (final section in targetSections) {
      if (section == CacheSection.paperStates) {
        final file = File('${root.path}/paper_states.json');
        if (await file.exists()) {
          await file.delete();
        }
        continue;
      }

      final directory = Directory('${root.path}/${section.directoryName}');
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }

    await root.create(recursive: true);
  }

  Future<File> _paperStatesFile() async {
    final root = await ensureCacheRoot();
    return File('${root.path}/paper_states.json');
  }

  String _topicsHash(String topics) {
    return md5.convert(utf8.encode(topics.trim().toLowerCase())).toString();
  }

  Future<String> _resolveStoragePath({
    required String preferenceKey,
    required String defaultLeafPath,
    String? overridePath,
  }) async {
    final normalizedOverride = overridePath?.trim() ?? '';
    if (normalizedOverride.isNotEmpty) {
      return normalizedOverride;
    }

    final preferences = await SharedPreferences.getInstance();
    final storedPath = preferences.getString(preferenceKey)?.trim() ?? '';
    if (storedPath.isNotEmpty) {
      if (_isDocumentsRoot(storedPath)) {
        return await _defaultDocumentsPath(defaultLeafPath);
      }
      return storedPath;
    }

    return await _defaultDocumentsPath(defaultLeafPath);
  }

  bool _isDocumentsRoot(String path) {
    final normalized = _normalizePath(path);
    if (normalized.split('/').last != 'Documents') {
      return false;
    }

    final home = Platform.environment['HOME'];
    return home == null ||
        home.isEmpty ||
        normalized == _normalizePath('$home/Documents') ||
        normalized.endsWith('/Documents');
  }

  Future<String> _defaultDocumentsPath(String defaultLeafPath) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return '${documentsDirectory.path}/$defaultLeafPath';
  }

  String _normalizePath(String path) {
    return path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  }

  Future<void> _migrateDocumentsRootCacheIfNeeded(Directory cacheRoot) async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return;
    }

    final documentsRoot = Directory('$home/Documents');
    final expectedCacheRoot = _normalizePath(
      '$home/Documents/$defaultCacheLeafPath',
    );
    if (_normalizePath(cacheRoot.path) != expectedCacheRoot) {
      return;
    }

    final legacyNames = {
      'all_papers',
      'filtered_papers',
      'markdown',
      'pdfs',
      'qa_history',
      'summaries',
    };
    for (final name in legacyNames) {
      final legacyDirectory = Directory('${documentsRoot.path}/$name');
      if (!await legacyDirectory.exists()) {
        continue;
      }

      final targetDirectory = Directory('${cacheRoot.path}/$name');
      if (await targetDirectory.exists()) {
        continue;
      }
      await legacyDirectory.rename(targetDirectory.path);
    }

    final legacyPaperStates = File('${documentsRoot.path}/paper_states.json');
    final targetPaperStates = File('${cacheRoot.path}/paper_states.json');
    if (await legacyPaperStates.exists() && !await targetPaperStates.exists()) {
      await legacyPaperStates.rename(targetPaperStates.path);
    }
  }

  Future<Directory> _ensureDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  String _safeFileName(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  String _pdfUrlForPaperId(String paperId) {
    return Uri.https('arxiv.org', '/pdf/${paperId.trim()}').toString();
  }

  String _formatDate(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }
}

enum CacheSection {
  allPapers('all_papers', 'Paper lists'),
  filteredPapers('filtered_papers', 'Filtered results'),
  pdfs('pdfs', 'Downloaded PDFs'),
  markdown('markdown', 'PDF to Markdown conversions'),
  summaries('summaries', 'Paper summaries'),
  qaHistory('qa_history', 'Q&A history'),
  paperStates('paper_states', 'Starred papers and tags');

  const CacheSection(this.directoryName, this.label);

  final String directoryName;
  final String label;
}

enum AiProvider { gemini, openai }

class GeminiModelOption {
  const GeminiModelOption({
    required this.id,
    required this.label,
    required this.description,
  });

  static const defaultModelId = 'gemini-3.5-flash';
  static const values = <GeminiModelOption>[
    GeminiModelOption(
      id: 'gemini-3.5-flash',
      label: 'Gemini 3.5 Flash',
      description: 'Recommended: stable, capable PDF reading',
    ),
    GeminiModelOption(
      id: 'gemini-3.1-flash-lite',
      label: 'Gemini 3.1 Flash-Lite',
      description: 'Fastest and lower-cost for frequent triage',
    ),
    GeminiModelOption(
      id: 'gemini-3-flash-preview',
      label: 'Gemini 3 Flash Preview',
      description: 'Preview model with changing availability',
    ),
  ];

  final String id;
  final String label;
  final String description;
}

class OpenAiModelOption {
  const OpenAiModelOption(this.id, this.label);

  static const defaultModelId = 'gpt-5.4';
  static const values = <OpenAiModelOption>[
    OpenAiModelOption('gpt-5.4', 'GPT-5.4'),
    OpenAiModelOption('gpt-4.1', 'GPT-4.1'),
    OpenAiModelOption('gpt-4o', 'GPT-4o'),
  ];

  final String id;
  final String label;
}

enum AppFontPreset { system, serif, plex, atkinson }

extension AppFontPresetTheme on AppFontPreset {
  String get label {
    switch (this) {
      case AppFontPreset.system:
        return 'System';
      case AppFontPreset.serif:
        return 'Source Serif 4';
      case AppFontPreset.plex:
        return 'IBM Plex Sans';
      case AppFontPreset.atkinson:
        return 'Atkinson Hyperlegible';
    }
  }

  ThemeData apply(ThemeData baseTheme) {
    switch (this) {
      case AppFontPreset.system:
        return baseTheme;
      case AppFontPreset.serif:
        return baseTheme.copyWith(
          textTheme: GoogleFonts.sourceSerif4TextTheme(baseTheme.textTheme),
          primaryTextTheme: GoogleFonts.sourceSerif4TextTheme(
            baseTheme.primaryTextTheme,
          ),
        );
      case AppFontPreset.plex:
        return baseTheme.copyWith(
          textTheme: GoogleFonts.ibmPlexSansTextTheme(baseTheme.textTheme),
          primaryTextTheme: GoogleFonts.ibmPlexSansTextTheme(
            baseTheme.primaryTextTheme,
          ),
        );
      case AppFontPreset.atkinson:
        return baseTheme.copyWith(
          textTheme: GoogleFonts.atkinsonHyperlegibleTextTheme(
            baseTheme.textTheme,
          ),
          primaryTextTheme: GoogleFonts.atkinsonHyperlegibleTextTheme(
            baseTheme.primaryTextTheme,
          ),
        );
    }
  }
}

class AppSettings {
  const AppSettings({
    required this.defaultTopics,
    required this.aiProvider,
    required this.geminiApiKey,
    required this.geminiModel,
    required this.openAiApiKey,
    required this.openAiModel,
    required this.fontPreset,
    required this.launchAtLogin,
    required this.cacheDirectoryPath,
    required this.exportDirectoryPath,
  });

  final String defaultTopics;
  final AiProvider aiProvider;
  final String geminiApiKey;
  final String geminiModel;
  final String openAiApiKey;
  final String openAiModel;
  final AppFontPreset fontPreset;
  final bool launchAtLogin;
  final String cacheDirectoryPath;
  final String exportDirectoryPath;

  factory AppSettings.defaults() {
    return const AppSettings(
      defaultTopics:
          'deep learning, strong lensing, weak lensing, photometric redshift estimation',
      aiProvider: AiProvider.gemini,
      geminiApiKey: '',
      geminiModel: GeminiModelOption.defaultModelId,
      openAiApiKey: '',
      openAiModel: OpenAiModelOption.defaultModelId,
      fontPreset: AppFontPreset.system,
      launchAtLogin: false,
      cacheDirectoryPath: '',
      exportDirectoryPath: '',
    );
  }

  factory AppSettings.fromPreferences(SharedPreferences preferences) {
    final defaults = AppSettings.defaults();
    final providerName =
        preferences.getString('ai_provider') ?? defaults.aiProvider.name;
    final fontName =
        preferences.getString('font_preset') ?? defaults.fontPreset.name;
    final savedGeminiModel =
        preferences.getString('gemini_model') ?? defaults.geminiModel;
    final geminiModel =
        GeminiModelOption.values.any((option) => option.id == savedGeminiModel)
        ? savedGeminiModel
        : defaults.geminiModel;

    return AppSettings(
      defaultTopics:
          preferences.getString('default_topics') ?? defaults.defaultTopics,
      aiProvider: AiProvider.values.firstWhere(
        (provider) => provider.name == providerName,
        orElse: () => defaults.aiProvider,
      ),
      geminiApiKey:
          preferences.getString('gemini_api_key') ?? defaults.geminiApiKey,
      geminiModel: geminiModel,
      openAiApiKey:
          preferences.getString('openai_api_key') ?? defaults.openAiApiKey,
      openAiModel:
          preferences.getString('openai_model') ?? defaults.openAiModel,
      fontPreset: AppFontPreset.values.firstWhere(
        (preset) => preset.name == fontName,
        orElse: () => defaults.fontPreset,
      ),
      launchAtLogin:
          preferences.getBool('launch_at_login') ?? defaults.launchAtLogin,
      cacheDirectoryPath:
          preferences.getString(AppCacheService.cacheDirectoryPreferenceKey) ??
          defaults.cacheDirectoryPath,
      exportDirectoryPath:
          preferences.getString(AppCacheService.exportDirectoryPreferenceKey) ??
          defaults.exportDirectoryPath,
    );
  }

  Future<void> saveToPreferences(SharedPreferences preferences) async {
    await preferences.setString('default_topics', defaultTopics);
    await preferences.setString('ai_provider', aiProvider.name);
    await preferences.setString('gemini_api_key', geminiApiKey);
    await preferences.setString('gemini_model', geminiModel);
    await preferences.setString('openai_api_key', openAiApiKey);
    await preferences.setString('openai_model', openAiModel);
    await preferences.setString('font_preset', fontPreset.name);
    await preferences.setBool('launch_at_login', launchAtLogin);
    await preferences.remove('auto_fetch_on_launch');
    await preferences.remove('auto_summarize_filtered_papers_on_launch');
    await preferences.remove('last_daily_update_date');
    await preferences.remove('last_auto_fetch_date');
    await preferences.remove('auto_fetch_hour');
    await preferences.remove('auto_fetch_minute');
    await preferences.setString(
      AppCacheService.cacheDirectoryPreferenceKey,
      cacheDirectoryPath,
    );
    await preferences.setString(
      AppCacheService.exportDirectoryPreferenceKey,
      exportDirectoryPath,
    );
  }

  AppSettings copyWith({
    String? defaultTopics,
    AiProvider? aiProvider,
    String? geminiApiKey,
    String? geminiModel,
    String? openAiApiKey,
    String? openAiModel,
    AppFontPreset? fontPreset,
    bool? launchAtLogin,
    String? cacheDirectoryPath,
    String? exportDirectoryPath,
  }) {
    return AppSettings(
      defaultTopics: defaultTopics ?? this.defaultTopics,
      aiProvider: aiProvider ?? this.aiProvider,
      geminiApiKey: geminiApiKey ?? this.geminiApiKey,
      geminiModel: geminiModel ?? this.geminiModel,
      openAiApiKey: openAiApiKey ?? this.openAiApiKey,
      openAiModel: openAiModel ?? this.openAiModel,
      fontPreset: fontPreset ?? this.fontPreset,
      launchAtLogin: launchAtLogin ?? this.launchAtLogin,
      cacheDirectoryPath: cacheDirectoryPath ?? this.cacheDirectoryPath,
      exportDirectoryPath: exportDirectoryPath ?? this.exportDirectoryPath,
    );
  }
}

class AppStartupService {
  Future<void> syncLaunchAtLogin(bool enabled) async {
    if (Platform.isWindows) {
      await _syncWindowsLaunchAtLogin(enabled);
      return;
    }
    if (!Platform.isMacOS) {
      return;
    }

    final file = await _launchAgentFile();
    if (!enabled) {
      await Process.run('launchctl', ['unload', file.path]);
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }

    final appBundlePath = _currentAppBundlePath();
    if (appBundlePath == null) {
      throw Exception('Could not determine the app bundle path.');
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(_launchAgentPlist(appBundlePath));
    await Process.run('launchctl', ['load', file.path]);
  }

  Future<void> _syncWindowsLaunchAtLogin(bool enabled) async {
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    const valueName = 'ArxivReaderAI';
    final arguments = enabled
        ? <String>[
            'add',
            key,
            '/v',
            valueName,
            '/t',
            'REG_SZ',
            '/d',
            '"${Platform.resolvedExecutable}"',
            '/f',
          ]
        : <String>['delete', key, '/v', valueName, '/f'];
    final result = await Process.run('reg', arguments);
    if (result.exitCode != 0 && !(!enabled && result.exitCode == 1)) {
      final details = result.stderr.toString().trim();
      throw Exception(
        details.isEmpty
            ? 'Windows could not update the launch-at-login setting.'
            : details,
      );
    }
  }

  Future<File> _launchAgentFile() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw Exception('HOME is not available.');
    }
    return File(
      '$home/Library/LaunchAgents/com.example.flutterApp.autostart.plist',
    );
  }

  String? _currentAppBundlePath() {
    final executablePath = Platform.resolvedExecutable;
    final marker = '.app/';
    final markerIndex = executablePath.indexOf(marker);
    if (markerIndex == -1) {
      return null;
    }
    return executablePath.substring(0, markerIndex + 4);
  }

  String _launchAgentPlist(String appBundlePath) {
    return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.flutterApp.autostart</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-n</string>
    <string>$appBundlePath</string>
    <string>--args</string>
    <string>--background</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppCacheService _cacheService = AppCacheService();
  final GeminiFilterService _geminiService = GeminiFilterService();
  static const MethodChannel _nativeChannel = MethodChannel(
    'arxiv_reader/native',
  );
  late final TextEditingController _topicsController;
  late final TextEditingController _geminiKeyController;
  late final TextEditingController _openAiKeyController;
  late final TextEditingController _cachePathController;
  late final TextEditingController _exportPathController;
  late AiProvider _provider;
  late String _geminiModel;
  late String _openAiModel;
  late AppFontPreset _fontPreset;
  late bool _launchAtLogin;
  int? _cacheSizeBytes;
  bool _isLoadingCacheSize = true;
  String? _cacheSizeError;
  bool _isTestingGemini = false;
  bool _isTestingOpenAi = false;
  String? _geminiTestMessage;
  bool? _geminiTestSucceeded;

  @override
  void initState() {
    super.initState();
    _topicsController = TextEditingController(
      text: widget.settings.defaultTopics,
    );
    _geminiKeyController = TextEditingController(
      text: widget.settings.geminiApiKey,
    );
    _openAiKeyController = TextEditingController(
      text: widget.settings.openAiApiKey,
    );
    _cachePathController = TextEditingController(
      text: widget.settings.cacheDirectoryPath,
    );
    _exportPathController = TextEditingController(
      text: widget.settings.exportDirectoryPath,
    );
    _provider = widget.settings.aiProvider;
    _geminiModel = widget.settings.geminiModel;
    _openAiModel = widget.settings.openAiModel;
    _fontPreset = widget.settings.fontPreset;
    _launchAtLogin = widget.settings.launchAtLogin;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCacheSize());
  }

  Future<void> _testGeminiConnection() async {
    final apiKey = _geminiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() {
        _geminiTestSucceeded = false;
        _geminiTestMessage = 'Enter a Gemini API key first.';
      });
      return;
    }

    setState(() {
      _isTestingGemini = true;
      _geminiTestMessage = null;
      _geminiTestSucceeded = null;
    });

    try {
      await _geminiService.testConnection(apiKey: apiKey, model: _geminiModel);
      if (!mounted) {
        return;
      }
      setState(() {
        _geminiTestSucceeded = true;
        _geminiTestMessage = 'Connection succeeded: $_geminiModel is ready.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _geminiTestSucceeded = false;
        _geminiTestMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isTestingGemini = false;
        });
      }
    }
  }

  Future<void> _testOpenAiConnection() async {
    final apiKey = _openAiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() {
        _geminiTestSucceeded = false;
        _geminiTestMessage = 'Enter an OpenAI API key first.';
      });
      return;
    }
    setState(() {
      _isTestingOpenAi = true;
      _geminiTestMessage = null;
      _geminiTestSucceeded = null;
    });
    try {
      await GeminiFilterService().testOpenAiConnection(
        apiKey: apiKey,
        model: _openAiModel,
      );
      if (!mounted) return;
      setState(() {
        _geminiTestSucceeded = true;
        _geminiTestMessage =
            'Connection succeeded: $_openAiModel is available.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _geminiTestSucceeded = false;
        _geminiTestMessage = error.toString();
      });
    } finally {
      if (mounted) setState(() => _isTestingOpenAi = false);
    }
  }

  @override
  void dispose() {
    _topicsController.dispose();
    _geminiKeyController.dispose();
    _openAiKeyController.dispose();
    _cachePathController.dispose();
    _exportPathController.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory({
    required TextEditingController controller,
    required String title,
  }) async {
    try {
      final initialPath = controller.text.trim();
      final nativeResult = await _pickDirectoryWithNativePanel(
        title: title,
        initialPath: initialPath,
      );
      final selectedPath = nativeResult.usedNativePicker
          ? nativeResult.path
          : await FilePicker.platform.getDirectoryPath(
              dialogTitle: 'Choose $title',
            );
      if (selectedPath == null || !mounted) {
        return;
      }
      setState(() {
        controller.text = selectedPath;
      });
      await _refreshCacheSize();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not choose $title. Please retry. $error'),
        ),
      );
    }
  }

  Future<_DirectoryPickResult> _pickDirectoryWithNativePanel({
    required String title,
    required String initialPath,
  }) async {
    if (!Platform.isMacOS) {
      return const _DirectoryPickResult(path: null, usedNativePicker: false);
    }

    try {
      final path = await _nativeChannel.invokeMethod<String>(
        'chooseDirectory',
        <String, String>{'title': 'Choose $title', 'initialPath': initialPath},
      );
      return _DirectoryPickResult(path: path, usedNativePicker: true);
    } on PlatformException {
      return const _DirectoryPickResult(path: null, usedNativePicker: false);
    } on MissingPluginException {
      return const _DirectoryPickResult(path: null, usedNativePicker: false);
    }
  }

  void _clearDirectory(TextEditingController controller) {
    setState(() {
      controller.clear();
    });
    _refreshCacheSize();
  }

  Future<void> _refreshCacheSize() async {
    if (mounted) {
      setState(() {
        _isLoadingCacheSize = true;
        _cacheSizeError = null;
      });
    }

    try {
      final size = await _cacheService.cacheSizeBytes(
        overridePath: _cachePathController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _cacheSizeBytes = size;
        _isLoadingCacheSize = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _cacheSizeBytes = null;
        _isLoadingCacheSize = false;
        _cacheSizeError = error.toString();
      });
    }
  }

  void _save() {
    Navigator.of(context).pop(
      AppSettings(
        defaultTopics: _topicsController.text.trim(),
        aiProvider: _provider,
        geminiApiKey: _geminiKeyController.text.trim(),
        geminiModel: _geminiModel,
        openAiApiKey: _openAiKeyController.text.trim(),
        openAiModel: _openAiModel,
        fontPreset: _fontPreset,
        launchAtLogin: _launchAtLogin,
        cacheDirectoryPath: _cachePathController.text.trim(),
        exportDirectoryPath: _exportPathController.text.trim(),
      ),
    );
  }

  Future<void> _clearCache() async {
    final selectedSections = Set<CacheSection>.from(CacheSection.values);

    final confirmed = await showDialog<Set<CacheSection>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Clear Cache'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Choose which cached data to remove. Exported Markdown files are kept separately.',
                    ),
                    const SizedBox(height: 16),
                    ...CacheSection.values.map((section) {
                      return CheckboxListTile(
                        value: selectedSections.contains(section),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(section.label),
                        onChanged: (checked) {
                          setDialogState(() {
                            if (checked ?? false) {
                              selectedSections.add(section);
                            } else {
                              selectedSections.remove(section);
                            }
                          });
                        },
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selectedSections.isEmpty
                      ? null
                      : () => Navigator.of(
                          context,
                        ).pop(Set<CacheSection>.from(selectedSections)),
                  child: const Text('Clear Selected'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == null || confirmed.isEmpty || !mounted) {
      return;
    }

    try {
      await _cacheService.clearCache(
        overridePath: _cachePathController.text.trim(),
        sections: confirmed,
      );
      await _refreshCacheSize();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cleared: ${confirmed.map((section) => section.label).join(', ')}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear cache. Please retry. $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const _BackdropDecoration(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                children: [
                  Container(
                    decoration: _panelDecoration(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Settings',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Defaults, storage, and appearance.',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Save'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: ListView(
                      children: [
                        _SettingsSection(
                          title: 'Research Defaults',
                          subtitle:
                              'Topics prefill the manual Filter Topics dialog.',
                          child: TextField(
                            controller: _topicsController,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Default topics',
                              hintText:
                                  'e.g. strong lensing, weak lensing, redshift estimation, deep learning',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _SettingsSection(
                          title: 'AI Model',
                          subtitle:
                              'Pick which provider the app should read keys from.',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SegmentedButton<AiProvider>(
                                segments: const [
                                  ButtonSegment(
                                    value: AiProvider.gemini,
                                    label: Text('Gemini'),
                                    icon: Icon(Icons.auto_awesome_outlined),
                                  ),
                                  ButtonSegment(
                                    value: AiProvider.openai,
                                    label: Text('OpenAI'),
                                    icon: Icon(Icons.smart_toy_outlined),
                                  ),
                                ],
                                selected: {_provider},
                                onSelectionChanged: (selection) {
                                  setState(() {
                                    _provider = selection.first;
                                  });
                                },
                              ),
                              const SizedBox(height: 16),
                              if (_provider == AiProvider.gemini) ...[
                                TextField(
                                  controller: _geminiKeyController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Gemini API key',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  initialValue: _geminiModel,
                                  decoration: const InputDecoration(
                                    labelText: 'Gemini model',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: GeminiModelOption.values
                                      .map(
                                        (option) => DropdownMenuItem(
                                          value: option.id,
                                          child: Text(
                                            '${option.label} - ${option.description}',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _isTestingGemini
                                      ? null
                                      : (model) {
                                          if (model == null) {
                                            return;
                                          }
                                          setState(() {
                                            _geminiModel = model;
                                            _geminiTestMessage = null;
                                            _geminiTestSucceeded = null;
                                          });
                                        },
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _isTestingGemini
                                          ? null
                                          : _testGeminiConnection,
                                      icon: _isTestingGemini
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.wifi_tethering_rounded,
                                            ),
                                      label: Text(
                                        _isTestingGemini
                                            ? 'Testing connection...'
                                            : 'Test Gemini connection',
                                      ),
                                    ),
                                    if (_geminiTestMessage != null)
                                      Text(
                                        _geminiTestMessage!,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color:
                                                  _geminiTestSucceeded == true
                                                  ? const Color(0xFF047857)
                                                  : Colors.red.shade700,
                                            ),
                                      ),
                                  ],
                                ),
                              ] else ...[
                                TextField(
                                  controller: _openAiKeyController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'OpenAI API key',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  initialValue: _openAiModel,
                                  decoration: const InputDecoration(
                                    labelText: 'OpenAI model',
                                    border: OutlineInputBorder(),
                                  ),
                                  items: OpenAiModelOption.values
                                      .map(
                                        (option) => DropdownMenuItem(
                                          value: option.id,
                                          child: Text(option.label),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _isTestingOpenAi
                                      ? null
                                      : (model) => setState(() {
                                          _openAiModel = model ?? _openAiModel;
                                          _geminiTestMessage = null;
                                          _geminiTestSucceeded = null;
                                        }),
                                ),
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  onPressed: _isTestingOpenAi
                                      ? null
                                      : _testOpenAiConnection,
                                  icon: _isTestingOpenAi
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.wifi_tethering_rounded,
                                        ),
                                  label: Text(
                                    _isTestingOpenAi
                                        ? 'Testing connection...'
                                        : 'Test OpenAI connection',
                                  ),
                                ),
                                if (_geminiTestMessage != null) ...[
                                  const SizedBox(height: 8),
                                  Text(_geminiTestMessage!),
                                ],
                                const SizedBox(height: 12),
                                Text(
                                  'OpenAI will be used for topic filtering, PDF summaries, and paper Q&A when selected.',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: const Color(0xFF64748B),
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _SettingsSection(
                          title: 'Storage',
                          subtitle:
                              'Leave blank to use Documents/arXivReader_AI for cache and Markdown exports.',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _DirectoryPickerField(
                                label: 'Cache folder',
                                value: _cachePathController.text,
                                fallbackHint:
                                    '~/Documents/${AppCacheService.defaultCacheLeafPath}',
                                onChoose: () => _pickDirectory(
                                  controller: _cachePathController,
                                  title: 'cache folder',
                                ),
                                onClear: _cachePathController.text.isEmpty
                                    ? null
                                    : () =>
                                          _clearDirectory(_cachePathController),
                              ),
                              const SizedBox(height: 12),
                              _DirectoryPickerField(
                                label: 'Export folder',
                                value: _exportPathController.text,
                                fallbackHint:
                                    '~/Documents/${AppCacheService.defaultExportLeafPath}',
                                onChoose: () => _pickDirectory(
                                  controller: _exportPathController,
                                  title: 'export folder',
                                ),
                                onClear: _exportPathController.text.isEmpty
                                    ? null
                                    : () => _clearDirectory(
                                        _exportPathController,
                                      ),
                              ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.storage_outlined,
                                        size: 18,
                                        color: Color(0xFF64748B),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _isLoadingCacheSize
                                            ? 'Cache size: Calculating...'
                                            : _cacheSizeBytes != null
                                            ? 'Cache size: ${AppCacheService.formatStorageSize(_cacheSizeBytes!)}'
                                            : 'Cache size unavailable',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: const Color(0xFF475569),
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      IconButton(
                                        tooltip:
                                            _cacheSizeError ??
                                            'Refresh cache size',
                                        onPressed: _isLoadingCacheSize
                                            ? null
                                            : _refreshCacheSize,
                                        icon: const Icon(Icons.refresh_rounded),
                                      ),
                                    ],
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _clearCache,
                                    icon: const Icon(
                                      Icons.delete_sweep_outlined,
                                    ),
                                    label: const Text('Clear Cache'),
                                  ),
                                  Text(
                                    'If an operation fails, the app will now show a Retry action.',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: const Color(0xFF64748B),
                                        ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _SettingsSection(
                          title: 'About',
                          subtitle: 'Product details for this desktop build.',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _InfoLine(label: 'App', value: 'ArxivReader AI'),
                              const SizedBox(height: 10),
                              _InfoLine(label: 'Version', value: '1.0.0'),
                              const SizedBox(height: 10),
                              _InfoLine(
                                label: 'Authors',
                                value: 'xczhou & codex',
                              ),
                              const SizedBox(height: 10),
                              _InfoLine(
                                label: 'Local storage',
                                value:
                                    'API keys stay on this device via app settings.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _SettingsSection(
                          title: 'Appearance',
                          subtitle:
                              'Choose the reading font for the whole application.',
                          child: DropdownButtonFormField<AppFontPreset>(
                            initialValue: _fontPreset,
                            decoration: const InputDecoration(
                              labelText: 'Font',
                              border: OutlineInputBorder(),
                            ),
                            items: AppFontPreset.values
                                .map(
                                  (preset) => DropdownMenuItem(
                                    value: preset,
                                    child: Text(preset.label),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _fontPreset = value;
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (Platform.isMacOS || Platform.isWindows)
                          _SettingsSection(
                            title: 'Startup',
                            subtitle:
                                'Start the app automatically when you sign in.',
                            child: Column(
                              children: [
                                SwitchListTile(
                                  value: _launchAtLogin,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Launch app at login'),
                                  subtitle: Text(
                                    Platform.isWindows
                                        ? 'Open the Windows app automatically when you sign in.'
                                        : 'Open the macOS app automatically when you sign in.',
                                  ),
                                  onChanged: (value) {
                                    setState(() {
                                      _launchAtLogin = value;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            Material(color: Colors.transparent, child: child),
          ],
        ),
      ),
    );
  }
}

class _DirectoryPickResult {
  const _DirectoryPickResult({
    required this.path,
    required this.usedNativePicker,
  });

  final String? path;
  final bool usedNativePicker;
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: const Color(0xFF0F172A),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF475569),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _DirectoryPickerField extends StatelessWidget {
  const _DirectoryPickerField({
    required this.label,
    required this.value,
    required this.fallbackHint,
    required this.onChoose,
    this.onClear,
  });

  final String label;
  final String value;
  final String fallbackHint;
  final VoidCallback onChoose;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final displayText = value.isEmpty ? fallbackHint : value;
    final isUsingDefault = value.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAF8),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFDDE4E3)),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  displayText,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isUsingDefault
                        ? const Color(0xFF64748B)
                        : const Color(0xFF0F172A),
                    fontStyle: isUsingDefault
                        ? FontStyle.italic
                        : FontStyle.normal,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: onChoose,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Choose'),
                  ),
                  if (onClear != null)
                    TextButton(
                      onPressed: onClear,
                      child: const Text('Default'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GeminiUploadedFile {
  const _GeminiUploadedFile({
    required this.name,
    required this.uri,
    required this.mimeType,
  });

  final String name;
  final String uri;
  final String mimeType;
}

class LatexText extends StatelessWidget {
  const LatexText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  static final RegExp _mathPattern = RegExp(
    r'(\$\$.*?\$\$|\$.*?\$)',
    dotAll: true,
  );

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = style ?? DefaultTextStyle.of(context).style;
    final spans = <InlineSpan>[];
    final normalizedText = _normalizeLatexText(text);
    var lastEnd = 0;

    for (final match in _mathPattern.allMatches(normalizedText)) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: normalizedText.substring(lastEnd, match.start),
            style: effectiveStyle,
          ),
        );
      }

      final raw = match.group(0) ?? '';
      final isBlock = raw.startsWith(r'$$') && raw.endsWith(r'$$');
      final equation = _normalizeEquation(
        raw.substring(isBlock ? 2 : 1, raw.length - (isBlock ? 2 : 1)).trim(),
      );

      if (equation.isEmpty) {
        spans.add(TextSpan(text: raw, style: effectiveStyle));
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Math.tex(
                equation,
                mathStyle: isBlock ? MathStyle.display : MathStyle.text,
                textStyle: effectiveStyle,
                onErrorFallback: (FlutterMathException error) {
                  return Text(raw, style: effectiveStyle);
                },
              ),
            ),
          ),
        );
      }

      lastEnd = match.end;
    }

    if (lastEnd < normalizedText.length) {
      spans.add(
        TextSpan(
          text: normalizedText.substring(lastEnd),
          style: effectiveStyle,
        ),
      );
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: normalizedText, style: effectiveStyle));
    }

    return SelectableText.rich(
      TextSpan(style: effectiveStyle, children: spans),
      maxLines: maxLines,
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  String _normalizeLatexText(String input) {
    return input
        .replaceAll(r'\unHz', 'uHz')
        .replaceAll(r'\uHz', 'uHz')
        .replaceAll(r'\,', ' ')
        .replaceAll(r'~', '∼');
  }

  String _normalizeEquation(String input) {
    return input
        .replaceAll(r'\unHz', r'\,\mu\mathrm{Hz}')
        .replaceAll(r'\uHz', r'\,\mu\mathrm{Hz}')
        .replaceAll(r'\umHz', r'\,\mathrm{mHz}')
        .replaceAll(r'\Hz', r'\,\mathrm{Hz}')
        .replaceAll('∼', r'\sim ');
  }
}
