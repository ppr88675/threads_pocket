// ============================================================================
// 《Threads 貼文收藏庫》(Threads Pocket) — Android 本機端 Flutter 完整應用程式
// ============================================================================
// 功能總覽：
// 1. 貼文解析 (ThreadsParserService)：
//    - 自動過濾 ?xmt=... / ?igsh=... 等追蹤參數並統一網址格式
//    - 解析 Open Graph 與內嵌資料，擷取作者名稱、@handle、貼文內文
//    - 多圖貼文自動僅擷取並顯示「第一張代表圖」(排除純文字貼文的預設圖示)
// 2. 手機端極速收藏：
//    - 支援 Android 系統原生「分享選單 (Share Sheet)」直接傳入網址收藏
//    - 支援「剪貼簿智慧偵測 (Smart Paste)」，複製連結切回 App 自動彈出收藏提示
// 3. 瀏覽、管理與檢索：
//    - 自適應淺色 / 深色模式 (Material 3 Dark/Light Mode)
//    - 單圖全螢幕燈箱檢視器 (支援雙指縮放 Pinch-to-zoom)
//    - 長文展開 / 收合、一鍵跳轉回 Threads 原文
//    - 全文即時搜尋（內文、作者、標籤、個人筆記）與橫向標籤晶片篩選
// 4. 純本機端儲存與備份：
//    - SQLite 離線資料庫 (threads_pocket.db)，無須連網即可翻閱文字與筆記
//    - 一鍵匯出 / 還原 JSON 備份，換手機可無痛轉移
//
// ----------------------------------------------------------------------------
// 【專案設定檔快速參考】
// 1. pubspec.yaml 依賴套件：
//    dependencies:
//      flutter:
//        sdk: flutter
//      http: ^1.2.1
//      html: ^0.15.4
//      sqflite: ^2.3.3
//      path: ^1.9.0
//      path_provider: ^2.1.3
//      url_launcher: ^6.3.0
//
// 2. AndroidManifest.xml (位於 android/app/src/main/AndroidManifest.xml)：
//    - 請加入網路權限：<uses-permission android:name="android.permission.INTERNET" />
//    - 若需啟用「Android 系統分享選單直接存入」，於 <activity android:name=".MainActivity"> 加入：
//      <intent-filter>
//          <action android:name="android.intent.action.SEND" />
//          <category android:name="android.intent.category.DEFAULT" />
//          <data android:mimeType="text/plain" />
//      </intent-filter>
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ThreadsPocketApp());
}

/// ============================================================================
/// 1. App 進入點與主題設定（支援淺色 / 深色模式跟隨系統切換）
/// ============================================================================
class ThreadsPocketApp extends StatelessWidget {
  const ThreadsPocketApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Threads 貼文收藏庫',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF101010),
        brightness: Brightness.light,
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.grey.shade200),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF8E8E93),
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF101010),
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFF181818),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2C2C2E)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

/// ============================================================================
/// 2. 資料模型 (Data Model)：單篇 Threads 收藏貼文
/// ============================================================================
class ThreadPost {
  final int? id;
  final String url; // 標準化後的乾淨貼文網址
  final String authorName; // 作者顯示名稱
  final String authorHandle; // 作者帳號 (例如 @mosseri)
  final String? authorAvatar; // 作者頭像網址
  final String content; // 貼文內文
  final String? firstImageUrl; // 第一張代表圖片網址 (僅保留首張)
  final List<String> tags; // 分類標籤清單
  final String note; // 個人隨手筆記
  final DateTime savedAt; // 收藏時間

  ThreadPost({
    this.id,
    required this.url,
    required this.authorName,
    required this.authorHandle,
    this.authorAvatar,
    required this.content,
    this.firstImageUrl,
    required this.tags,
    this.note = '',
    required this.savedAt,
  });

  ThreadPost copyWith({
    int? id,
    String? url,
    String? authorName,
    String? authorHandle,
    String? authorAvatar,
    String? content,
    String? firstImageUrl,
    List<String>? tags,
    String? note,
    DateTime? savedAt,
  }) {
    return ThreadPost(
      id: id ?? this.id,
      url: url ?? this.url,
      authorName: authorName ?? this.authorName,
      authorHandle: authorHandle ?? this.authorHandle,
      authorAvatar: authorAvatar ?? this.authorAvatar,
      content: content ?? this.content,
      firstImageUrl: firstImageUrl ?? this.firstImageUrl,
      tags: tags ?? this.tags,
      note: note ?? this.note,
      savedAt: savedAt ?? this.savedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'url': url,
      'author_name': authorName,
      'author_handle': authorHandle,
      'author_avatar': authorAvatar,
      'content': content,
      'first_image_url': firstImageUrl,
      'tags': jsonEncode(tags),
      'note': note,
      'saved_at': savedAt.toIso8601String(),
    };
  }

  factory ThreadPost.fromMap(Map<String, dynamic> map) {
    List<String> parsedTags = [];
    if (map['tags'] != null && (map['tags'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(map['tags'] as String);
        if (decoded is List) {
          parsedTags = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    return ThreadPost(
      id: map['id'] as int?,
      url: map['url'] as String? ?? '',
      authorName: map['author_name'] as String? ?? 'Threads 用戶',
      authorHandle: map['author_handle'] as String? ?? '@unknown',
      authorAvatar: map['author_avatar'] as String?,
      content: map['content'] as String? ?? '',
      firstImageUrl: map['first_image_url'] as String?,
      tags: parsedTags,
      note: map['note'] as String? ?? '',
      savedAt:
          DateTime.tryParse(map['saved_at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// ============================================================================
/// 3. 本地 SQLite 資料庫模組 (DatabaseHelper)
/// ============================================================================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('threads_pocket.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute(
      'CREATE TABLE posts ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'url TEXT NOT NULL UNIQUE, '
      'author_name TEXT NOT NULL, '
      'author_handle TEXT NOT NULL, '
      'author_avatar TEXT, '
      'content TEXT NOT NULL, '
      'first_image_url TEXT, '
      'tags TEXT NOT NULL, '
      'note TEXT NOT NULL, '
      'saved_at TEXT NOT NULL'
      ')',
    );
  }

  /// 新增或覆蓋貼文
  Future<int> upsertPost(ThreadPost post) async {
    final db = await instance.database;
    return await db.insert(
      'posts',
      post.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 更新既有貼文
  Future<int> updatePost(ThreadPost post) async {
    final db = await instance.database;
    return await db.update(
      'posts',
      post.toMap(),
      where: 'id = ?',
      whereArgs: [post.id],
    );
  }

  /// 檢查網址是否已經收藏過
  Future<bool> existsByUrl(String cleanUrl) async {
    final db = await instance.database;
    final res = await db.query(
      'posts',
      columns: ['id'],
      where: 'url = ?',
      whereArgs: [cleanUrl],
      limit: 1,
    );
    return res.isNotEmpty;
  }

  /// 取得所有收藏貼文（依收藏時間由新到舊排序）
  Future<List<ThreadPost>> getAllPosts() async {
    final db = await instance.database;
    final result = await db.query('posts', orderBy: 'saved_at DESC');
    return result.map((map) => ThreadPost.fromMap(map)).toList();
  }

  /// 刪除指定貼文
  Future<int> deletePost(int id) async {
    final db = await instance.database;
    return await db.delete('posts', where: 'id = ?', whereArgs: [id]);
  }

  /// 匯出全部資料為 JSON 字串（供本機備份與換機使用）
  Future<String> exportToJson() async {
    final posts = await getAllPosts();
    final data = {
      'app': 'threads_pocket',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'posts': posts.map((p) => p.toMap()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 從 JSON 字串還原資料
  Future<int> importFromJson(String jsonString) async {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map || decoded['posts'] is! List) {
      throw const FormatException('備份檔案格式不正確');
    }
    final List list = decoded['posts'] as List;
    int importedCount = 0;
    for (final item in list) {
      if (item is Map<String, dynamic>) {
        final mapCopy = Map<String, dynamic>.from(item)..remove('id');
        final post = ThreadPost.fromMap(mapCopy);
        await upsertPost(post);
        importedCount++;
      }
    }
    return importedCount;
  }
}

/// ============================================================================
/// 4. Threads 貼文解析服務 (ThreadsParserService)
///    負責清理追蹤參數、抓取網頁詮釋資料、擷取作者、內文與「第一張代表圖」
/// ============================================================================
class ThreadsParserService {
  /// 從任意分享文字中擷取並清理 Threads 網址
  static String? extractAndCleanThreadsUrl(String rawText) {
    final regex = RegExp(
      r'https?:\/\/(?:www\.)?threads\.(?:net|com)\/(?:@[\w\.\-]+\/post\/[\w\-]+|t\/[\w\-]+)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(rawText);
    if (match == null) return null;

    final rawUrl = match.group(0)!;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return rawUrl;

    // 移除 ?xmt=... 或 ?igsh=... 等追蹤參數，統一網域為 www.threads.net
    return Uri(
      scheme: 'https',
      host: 'www.threads.net',
      path: uri.path,
    ).toString();
  }

  /// 判斷文字是否包含 Threads 連結
  static bool containsThreadsUrl(String text) {
    return extractAndCleanThreadsUrl(text) != null;
  }

  /// 連線抓取並解析貼文資訊（僅保留第一張代表圖）
  static Future<ThreadPost> fetchPostMetadata(String rawInputUrl) async {
    final cleanUrl = extractAndCleanThreadsUrl(rawInputUrl);
    if (cleanUrl == null) {
      throw const FormatException('找不到有效的 Threads 貼文連結');
    }

    // 從網址預先解析作者帳號作為保底值
    String fallbackHandle = '@threads_user';
    final handleMatch = RegExp(r'/@([\w\.\-]+)/post/').firstMatch(cleanUrl);
    if (handleMatch != null) {
      fallbackHandle = '@${handleMatch.group(1)}';
    }

    try {
      final response = await http.get(
        Uri.parse(cleanUrl),
        headers: {
          // 使用社群預覽 Bot User-Agent 以確保直接取得完整 Open Graph 標籤與首圖
          'User-Agent':
              'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
          'Accept-Language': 'zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7',
        },
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        throw HttpException('伺服器回應狀態碼 ${response.statusCode}');
      }

      final document = html_parser.parse(utf8.decode(response.bodyBytes));

      final ogTitle = _getMetaContent(document, 'og:title') ??
          _getMetaContent(document, 'twitter:title') ??
          '';
      final ogDescription = _getMetaContent(document, 'og:description') ??
          _getMetaContent(document, 'twitter:description') ??
          '';
      final ogImage = _getMetaContent(document, 'og:image') ??
          _getMetaContent(document, 'twitter:image');
      final twitterCard = _getMetaContent(document, 'twitter:card') ?? '';

      // 解析作者名稱與 @handle
      // 典型格式: "作者名稱 (@handle) on Threads" 或 "作者名稱 (@handle) • Threads"
      String authorName = fallbackHandle.replaceFirst('@', '');
      String authorHandle = fallbackHandle;

      final titleMatch =
          RegExp(r'^(.+?)\s*\((@[\w\.\-]+)\)').firstMatch(ogTitle);
      if (titleMatch != null) {
        authorName = titleMatch.group(1)!.trim();
        authorHandle = titleMatch.group(2)!.trim();
      } else if (ogTitle.isNotEmpty) {
        authorName = ogTitle
            .replaceAll(
                RegExp(r'\s*(on|•)\s*Threads.*$', caseSensitive: false), '')
            .trim();
      }

      // 判斷圖片是否為貼文附圖（排除純文字貼文的預設小頭像或官方 Logo）
      String? firstRepresentativeImage;
      String? authorAvatar;

      final extractedMedia = _tryExtractFirstPostImageFromScripts(document);
      if (extractedMedia != null) {
        firstRepresentativeImage = extractedMedia.firstImage;
        authorAvatar = extractedMedia.avatarUrl;
      } else if (ogImage != null &&
          ogImage.isNotEmpty &&
          !_isGenericThreadsLogo(ogImage)) {
        // 若 twitter:card 為 summary_large_image，代表該 og:image 是貼文首張附圖
        if (twitterCard.toLowerCase() == 'summary_large_image') {
          firstRepresentativeImage = ogImage;
        } else {
          // 純文字貼文時，og:image 通常為作者頭像，將其設為頭像而非貼文大圖
          authorAvatar = ogImage;
        }
      }

      final cleanedContent = ogDescription.trim().isNotEmpty
          ? ogDescription.trim()
          : '（此貼文無文字內容，或僅包含圖片/媒體）';

      return ThreadPost(
        url: cleanUrl,
        authorName: authorName,
        authorHandle: authorHandle,
        authorAvatar: authorAvatar,
        content: cleanedContent,
        firstImageUrl: firstRepresentativeImage,
        tags: const [],
        note: '',
        savedAt: DateTime.now(),
      );
    } catch (e) {
      // 若網路受限或解析失敗，仍允許以網址保底儲存，避免遺失連結
      return ThreadPost(
        url: cleanUrl,
        authorName: fallbackHandle.replaceFirst('@', ''),
        authorHandle: fallbackHandle,
        content: '（暫時無法自動抓取內文，可點擊「前往原文」查看或手動補充筆記）',
        firstImageUrl: null,
        tags: const [],
        note: '',
        savedAt: DateTime.now(),
      );
    }
  }

  static String? _getMetaContent(dom.Document doc, String propertyName) {
    final el = doc.querySelector('meta[property="$propertyName"]') ??
        doc.querySelector('meta[name="$propertyName"]');
    return el?.attributes['content'];
  }

  static bool _isGenericThreadsLogo(String url) {
    final lower = url.toLowerCase();
    return lower.contains('threads-logo') ||
        lower.contains('threads_app_icon') ||
        lower.contains('static.cdninstagram.com/rsrc.php');
  }

  /// 嘗試從頁面內嵌腳本提取高畫質第一張貼文圖片與作者頭像
  static ({String? firstImage, String? avatarUrl})?
      _tryExtractFirstPostImageFromScripts(dom.Document doc) {
    final scripts = doc.querySelectorAll('script');
    for (final script in scripts) {
      final text = script.text;
      if (!text.contains('image_versions2') &&
          !text.contains('carousel_media')) {
        continue;
      }
      try {
        final imgRegex = RegExp(
          r'"image_versions2"\s*:\s*\{\s*"candidates"\s*:\s*\[\s*\{\s*"height"\s*:\s*\d+\s*,\s*"url"\s*:\s*"([^"]+)"',
        );
        final match = imgRegex.firstMatch(text);
        if (match != null) {
          final rawUrl = match.group(1)!.replaceAll(r'\/', '/');
          final decodedUrl = jsonDecode('"$rawUrl"') as String;

          String? avatar;
          final avatarMatch =
              RegExp(r'"profile_pic_url"\s*:\s*"([^"]+)"').firstMatch(text);
          if (avatarMatch != null) {
            final rawAvatar = avatarMatch.group(1)!.replaceAll(r'\/', '/');
            avatar = jsonDecode('"$rawAvatar"') as String;
          }
          return (firstImage: decodedUrl, avatarUrl: avatar);
        }
      } catch (_) {}
    }
    return null;
  }
}

/// ============================================================================
/// 5. 主畫面 (HomePage)
///    整合：Android 原生分享接收、剪貼簿智慧偵測、搜尋、標籤篩選、卡片清單
/// ============================================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const MethodChannel _shareChannel =
      MethodChannel('app.threads_pocket/share');

  List<ThreadPost> _allPosts = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _selectedTag = '全部';
  String? _lastPromptedClipboardUrl;

  final List<String> _defaultPresetTags = [
    '靈感',
    '美食',
    '技術',
    '好文',
    '待讀',
    '搞笑',
  ];

  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPosts();
    _initAndroidShareReceiver();
    // 啟動後延遲檢查一次剪貼簿
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboardForThreadsUrl();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  /// 當使用者從 Threads 複製連結切換回本 App 時，自動檢查剪貼簿
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboardForThreadsUrl();
    }
  }

  /// 接收來自 Android 系統「分享選單 (Share Sheet)」傳入的網址
  Future<void> _initAndroidShareReceiver() async {
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedText') {
        final sharedText = call.arguments as String?;
        if (sharedText != null && sharedText.isNotEmpty) {
          _handleIncomingSharedText(sharedText);
        }
      }
    });

    try {
      final initialShared =
          await _shareChannel.invokeMethod<String>('getInitialSharedText');
      if (initialShared != null && initialShared.isNotEmpty) {
        _handleIncomingSharedText(initialShared);
      }
    } catch (_) {
      // 在尚未配置原生 Channel 的環境中安全忽略
    }
  }

  void _handleIncomingSharedText(String sharedText) {
    final cleanUrl = ThreadsParserService.extractAndCleanThreadsUrl(sharedText);
    if (cleanUrl != null && mounted) {
      _openAddOrEditSheet(initialUrl: cleanUrl);
    }
  }

  /// 智慧剪貼簿偵測：若複製了尚未收藏的 Threads 網址，底部彈出快速收藏提示
  Future<void> _checkClipboardForThreadsUrl() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      final cleanUrl = ThreadsParserService.extractAndCleanThreadsUrl(text);
      if (cleanUrl == null || cleanUrl == _lastPromptedClipboardUrl) return;

      final alreadySaved = await DatabaseHelper.instance.existsByUrl(cleanUrl);
      if (alreadySaved || !mounted) return;

      _lastPromptedClipboardUrl = cleanUrl;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          content: const Row(
            children: [
              Icon(Icons.content_paste_go, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Expanded(child: Text('偵測到剛複製的 Threads 連結')),
            ],
          ),
          action: SnackBarAction(
            label: '立即收藏',
            onPressed: () {
              _openAddOrEditSheet(initialUrl: cleanUrl);
            },
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> _loadPosts() async {
    setState(() => _isLoading = true);
    final posts = await DatabaseHelper.instance.getAllPosts();
    if (mounted) {
      setState(() {
        _allPosts = posts;
        _isLoading = false;
      });
    }
  }

  /// 彙整目前所有出現過的標籤清單
  List<String> get _availableFilterTags {
    final Set<String> tagSet = {'全部', ..._defaultPresetTags};
    for (final post in _allPosts) {
      tagSet.addAll(post.tags);
    }
    return tagSet.toList();
  }

  /// 根據搜尋關鍵字與選中標籤過濾貼文
  List<ThreadPost> get _filteredPosts {
    return _allPosts.where((post) {
      final matchesTag =
          _selectedTag == '全部' || post.tags.contains(_selectedTag);
      if (!matchesTag) return false;

      if (_searchQuery.trim().isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return post.content.toLowerCase().contains(q) ||
          post.authorName.toLowerCase().contains(q) ||
          post.authorHandle.toLowerCase().contains(q) ||
          post.note.toLowerCase().contains(q) ||
          post.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _openAddOrEditSheet({
    String? initialUrl,
    ThreadPost? existingPost,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => AddOrEditPostSheet(
        initialUrl: initialUrl,
        existingPost: existingPost,
        availableTags: _availableFilterTags.where((t) => t != '全部').toList(),
      ),
    );
    if (saved == true) {
      await _loadPosts();
    }
  }

  Future<void> _confirmDelete(ThreadPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除收藏'),
        content: Text('確定要移除 ${post.authorHandle} 的這篇貼文收藏嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed == true && post.id != null) {
      await DatabaseHelper.instance.deletePost(post.id!);
      await _loadPosts();
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredPosts;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.alternate_email_rounded, size: 24),
            SizedBox(width: 8),
            Text(
              'Threads 收藏庫',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '從剪貼簿快速貼上',
            icon: const Icon(Icons.content_paste_rounded),
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              final text = data?.text ?? '';
              final cleanUrl =
                  ThreadsParserService.extractAndCleanThreadsUrl(text);
              if (cleanUrl != null) {
                _openAddOrEditSheet(initialUrl: cleanUrl);
              } else {
                _openAddOrEditSheet();
              }
            },
          ),
          IconButton(
            tooltip: '備份與還原',
            icon: const Icon(Icons.import_export_rounded),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BackupRestorePage(onRestored: _loadPosts),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 頂部搜尋欄
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                hintText: '搜尋貼文內文、@帳號、標籤或筆記...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // 橫向標籤篩選列
          SizedBox(
            height: 44,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: _availableFilterTags.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final tag = _availableFilterTags[index];
                final isSelected = tag == _selectedTag;
                return ChoiceChip(
                  label: Text(tag),
                  selected: isSelected,
                  onSelected: (_) => setState(() => _selectedTag = tag),
                );
              },
            ),
          ),
          const SizedBox(height: 6),

          // 貼文卡片列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _loadPosts,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final post = filtered[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: ThreadPostCard(
                                post: post,
                                onTapTag: (t) =>
                                    setState(() => _selectedTag = t),
                                onEdit: () =>
                                    _openAddOrEditSheet(existingPost: post),
                                onDelete: () => _confirmDelete(post),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddOrEditSheet(),
        icon: const Icon(Icons.add_link_rounded),
        label: const Text('新增貼文'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_add_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              _allPosts.isEmpty ? '尚無收藏的 Threads 貼文' : '找不到符合條件的貼文',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _allPosts.isEmpty
                  ? '在 Threads 複製貼文連結後，點擊右下角「新增貼文」或右上角「剪貼簿圖示」即可一鍵解析收藏！'
                  : '試著更換搜尋關鍵字或切換上方的分類標籤。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ============================================================================
/// 6. 貼文卡片元件 (ThreadPostCard)
///    顯示：作者資訊、可展開長文、第一張代表圖（點擊放大）、個人筆記、前往原文
/// ============================================================================
class ThreadPostCard extends StatefulWidget {
  final ThreadPost post;
  final ValueChanged<String> onTapTag;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const ThreadPostCard({
    super.key,
    required this.post,
    required this.onTapTag,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<ThreadPostCard> createState() => _ThreadPostCardState();
}

class _ThreadPostCardState extends State<ThreadPostCard> {
  bool _isExpanded = false;

  Future<void> _openOriginalThread() async {
    final uri = Uri.tryParse(widget.post.url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openImageLightbox(BuildContext context, String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SingleImageLightboxPage(
          imageUrl: imageUrl,
          authorHandle: widget.post.authorHandle,
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final y = dt.year.toString();
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y/$m/$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final hasImage =
        post.firstImageUrl != null && post.firstImageUrl!.trim().isNotEmpty;
    final isLongText = post.content.length > 140 ||
        '\n'.allMatches(post.content).length >= 4;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 卡片頂部：作者頭像、名稱、@帳號、選單
            Row(
              children: [
                _buildAvatar(post),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.authorName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${post.authorHandle} · 收藏於 ${_formatDate(post.savedAt)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') widget.onEdit();
                    if (value == 'copy') {
                      Clipboard.setData(ClipboardData(text: post.url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已複製貼文連結')),
                      );
                    }
                    if (value == 'delete') widget.onDelete();
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.edit_note_rounded),
                        title: Text('編輯標籤與筆記'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: ListTile(
                        leading: Icon(Icons.copy_rounded),
                        title: Text('複製原文網址'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline_rounded,
                            color: Colors.redAccent),
                        title: Text('刪除收藏',
                            style: TextStyle(color: Colors.redAccent)),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 12),

            // 2. 貼文文字內容（支援展開/收合）
            GestureDetector(
              onTap: isLongText
                  ? () => setState(() => _isExpanded = !_isExpanded)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post.content,
                    maxLines: _isExpanded ? null : 4,
                    overflow: _isExpanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, height: 1.45),
                  ),
                  if (isLongText)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _isExpanded ? '收起內容' : '展開全文...',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // 3. 第一張代表圖片即時預覽（多圖貼文僅顯示第一張代表圖）
            if (hasImage) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => _openImageLightbox(context, post.firstImageUrl!),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 260,
                      minWidth: double.infinity,
                    ),
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Image.network(
                          post.firstImageUrl!,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          loadingBuilder: (ctx, child, progress) {
                            if (progress == null) return child;
                            return Container(
                              height: 180,
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              alignment: Alignment.center,
                              child: const CircularProgressIndicator(
                                  strokeWidth: 2),
                            );
                          },
                          errorBuilder: (ctx, err, stack) => Container(
                            height: 100,
                            padding: const EdgeInsets.all(16),
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.broken_image_outlined,
                                    color:
                                        Theme.of(context).colorScheme.outline),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '圖片預覽無法載入（可能離線或原始連結已過期）',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color:
                                          Theme.of(context).colorScheme.outline,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.zoom_in_rounded,
                                  color: Colors.white, size: 15),
                              SizedBox(width: 4),
                              Text(
                                '點擊放大',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],

            // 4. 個人隨手筆記區塊
            if (post.note.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .secondaryContainer
                      .withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.sticky_note_2_outlined,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        post.note,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context)
                              .colorScheme
                              .onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // 5. 底部：標籤晶片與「前往原文」按鈕
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: post.tags.map((tag) {
                      return InkWell(
                        onTap: () => widget.onTapTag(tag),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '#$tag',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                TextButton.icon(
                  onPressed: _openOriginalThread,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('前往原文'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(ThreadPost post) {
    final avatarUrl = post.authorAvatar;
    final initial = post.authorName.isNotEmpty
        ? post.authorName.characters.first.toUpperCase()
        : 'T';
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 20,
        backgroundImage: NetworkImage(avatarUrl),
        onBackgroundImageError: (_, __) {},
        child: null,
      );
    }
    return CircleAvatar(
      radius: 20,
      child: Text(
        initial,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// ============================================================================
/// 7. 單張代表圖全螢幕燈箱檢視器 (SingleImageLightboxPage)
///    支援雙指縮放 (Pinch-to-zoom) 與雙擊放大
/// ============================================================================
class SingleImageLightboxPage extends StatelessWidget {
  final String imageUrl;
  final String authorHandle;

  const SingleImageLightboxPage({
    super.key,
    required this.imageUrl,
    required this.authorHandle,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(authorHandle, style: const TextStyle(fontSize: 16)),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4.5,
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text(
              '無法載入原圖',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================================
/// 8. 新增 / 編輯貼文底部彈窗 (AddOrEditPostSheet)
///    支援：貼上網址即時解析、預覽第一張代表圖、快速勾選標籤、新增隨手筆記
/// ============================================================================
class AddOrEditPostSheet extends StatefulWidget {
  final String? initialUrl;
  final ThreadPost? existingPost;
  final List<String> availableTags;

  const AddOrEditPostSheet({
    super.key,
    this.initialUrl,
    this.existingPost,
    required this.availableTags,
  });

  @override
  State<AddOrEditPostSheet> createState() => _AddOrEditPostSheetState();
}

class _AddOrEditPostSheetState extends State<AddOrEditPostSheet> {
  late final TextEditingController _urlController;
  late final TextEditingController _authorNameController;
  late final TextEditingController _authorHandleController;
  late final TextEditingController _contentController;
  late final TextEditingController _imageUrlController;
  late final TextEditingController _noteController;
  late final TextEditingController _newTagController;

  bool _isParsing = false;
  String? _parseError;
  late Set<String> _selectedTags;
  late List<String> _tagPool;

  bool get _isEditing => widget.existingPost != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingPost;
    _urlController = TextEditingController(
      text: existing?.url ?? widget.initialUrl ?? '',
    );
    _authorNameController = TextEditingController(
      text: existing?.authorName ?? '',
    );
    _authorHandleController = TextEditingController(
      text: existing?.authorHandle ?? '',
    );
    _contentController = TextEditingController(
      text: existing?.content ?? '',
    );
    _imageUrlController = TextEditingController(
      text: existing?.firstImageUrl ?? '',
    );
    _noteController = TextEditingController(
      text: existing?.note ?? '',
    );
    _newTagController = TextEditingController();

    _selectedTags = {...(existing?.tags ?? [])};
    _tagPool = {...widget.availableTags, ..._selectedTags}.toList();

    // 若是從剪貼簿或分享選單帶入新網址，立即自動解析
    if (!_isEditing && _urlController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _parseUrl();
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _authorNameController.dispose();
    _authorHandleController.dispose();
    _contentController.dispose();
    _imageUrlController.dispose();
    _noteController.dispose();
    _newTagController.dispose();
    super.dispose();
  }

  Future<void> _parseUrl() async {
    final raw = _urlController.text.trim();
    if (raw.isEmpty) return;

    setState(() {
      _isParsing = true;
      _parseError = null;
    });

    try {
      final parsed = await ThreadsParserService.fetchPostMetadata(raw);
      if (!mounted) return;
      setState(() {
        _urlController.text = parsed.url;
        _authorNameController.text = parsed.authorName;
        _authorHandleController.text = parsed.authorHandle;
        _contentController.text = parsed.content;
        _imageUrlController.text = parsed.firstImageUrl ?? '';
        _isParsing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _parseError = e.toString();
        _isParsing = false;
      });
    }
  }

  Future<void> _savePost() async {
    final cleanUrl =
        ThreadsParserService.extractAndCleanThreadsUrl(_urlController.text) ??
            _urlController.text.trim();
    if (cleanUrl.isEmpty) {
      setState(() => _parseError = '請輸入有效的 Threads 貼文連結');
      return;
    }

    final post = ThreadPost(
      id: widget.existingPost?.id,
      url: cleanUrl,
      authorName: _authorNameController.text.trim().isEmpty
          ? 'Threads 用戶'
          : _authorNameController.text.trim(),
      authorHandle: _authorHandleController.text.trim().isEmpty
          ? '@threads'
          : _authorHandleController.text.trim(),
      authorAvatar: widget.existingPost?.authorAvatar,
      content: _contentController.text.trim().isEmpty
          ? '（無內文摘要）'
          : _contentController.text.trim(),
      firstImageUrl: _imageUrlController.text.trim().isEmpty
          ? null
          : _imageUrlController.text.trim(),
      tags: _selectedTags.toList(),
      note: _noteController.text.trim(),
      savedAt: widget.existingPost?.savedAt ?? DateTime.now(),
    );

    if (_isEditing && post.id != null) {
      await DatabaseHelper.instance.updatePost(post);
    } else {
      await DatabaseHelper.instance.upsertPost(post);
    }

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  void _addCustomTag() {
    final newTag = _newTagController.text.trim().replaceAll('#', '');
    if (newTag.isEmpty) return;
    setState(() {
      if (!_tagPool.contains(newTag)) {
        _tagPool.add(newTag);
      }
      _selectedTags.add(newTag);
      _newTagController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final previewImg = _imageUrlController.text.trim();

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, bottomInset + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 頂部拖曳指示條與標題
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isEditing ? '編輯收藏與筆記' : '收藏 Threads 貼文',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (_isParsing)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // 1. 貼文連結欄 + 解析按鈕
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: 'Threads 貼文連結',
                      hintText: 'https://www.threads.net/@user/post/...',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: '貼上剪貼簿內容',
                        icon: const Icon(Icons.content_paste_rounded),
                        onPressed: () async {
                          final data =
                              await Clipboard.getData(Clipboard.kTextPlain);
                          if (data?.text != null) {
                            _urlController.text = data!.text!;
                            _parseUrl();
                          }
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _isParsing ? null : _parseUrl,
                  child: const Text('解析'),
                ),
              ],
            ),

            if (_parseError != null) ...[
              const SizedBox(height: 8),
              Text(
                _parseError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],

            const SizedBox(height: 14),

            // 2. 作者與帳號欄
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _authorNameController,
                    decoration: const InputDecoration(
                      labelText: '作者名稱',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _authorHandleController,
                    decoration: const InputDecoration(
                      labelText: '作者帳號 (@handle)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // 3. 貼文內文預覽（可手動微調）
            TextField(
              controller: _contentController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '貼文簡易內容',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 12),

            // 4. 第一張代表圖片即時預覽
            if (previewImg.isNotEmpty) ...[
              const Text(
                '第一張代表圖預覽：',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  previewImg,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // 5. 標籤選擇器
            const Text(
              '分類標籤：',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _tagPool.map((tag) {
                final selected = _selectedTags.contains(tag);
                return FilterChip(
                  label: Text(tag),
                  selected: selected,
                  onSelected: (val) {
                    setState(() {
                      if (val) {
                        _selectedTags.add(tag);
                      } else {
                        _selectedTags.remove(tag);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newTagController,
                    onSubmitted: (_) => _addCustomTag(),
                    decoration: const InputDecoration(
                      hintText: '輸入新標籤名稱...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _addCustomTag,
                  child: const Text('新增標籤'),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // 6. 個人隨手筆記
            TextField(
              controller: _noteController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '個人筆記 / 收藏原因（選填）',
                hintText: '記下這篇貼文的重點或待辦事項...',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 18),

            // 7. 儲存按鈕
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _isParsing ? null : _savePost,
                icon: const Icon(Icons.bookmark_added_rounded),
                label: Text(_isEditing ? '更新收藏' : '確認收藏'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ============================================================================
/// 9. 本地備份與還原頁面 (BackupRestorePage)
///    支援將資料庫匯出為 JSON 備份或從 JSON 還原
/// ============================================================================
class BackupRestorePage extends StatefulWidget {
  final VoidCallback onRestored;

  const BackupRestorePage({super.key, required this.onRestored});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  final TextEditingController _jsonController = TextEditingController();
  String? _statusMessage;

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _exportBackup() async {
    final jsonStr = await DatabaseHelper.instance.exportToJson();
    await Clipboard.setData(ClipboardData(text: jsonStr));

    // 同時寫入應用文件目錄供留存
    String savedPath = '';
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, 'threads_pocket_backup.json'));
      await file.writeAsString(jsonStr);
      savedPath = file.path;
    } catch (_) {}

    if (mounted) {
      setState(() {
        _jsonController.text = jsonStr;
        _statusMessage = savedPath.isNotEmpty
            ? '已複製備份 JSON 至剪貼簿，並儲存於：$savedPath'
            : '已將完整備份 JSON 複製至剪貼簿！';
      });
    }
  }

  Future<void> _importBackup() async {
    final raw = _jsonController.text.trim();
    if (raw.isEmpty) {
      setState(() => _statusMessage = '請先貼上要還原的 JSON 備份內容');
      return;
    }
    try {
      final count = await DatabaseHelper.instance.importFromJson(raw);
      widget.onRestored();
      if (mounted) {
        setState(() => _statusMessage = '成功還原 $count 篇 Threads 貼文！');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = '還原失敗：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('本地資料備份與還原')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '所有收藏皆儲存在你的 Android 手機本地 SQLite 資料庫中。你可以隨時將資料匯出成 JSON 備份，換手機時直接貼上即可無痛還原。',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _exportBackup,
                    icon: const Icon(Icons.upload_file_rounded),
                    label: const Text('匯出並複製 JSON'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _importBackup,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('從下方 JSON 還原'),
                  ),
                ),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _statusMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _jsonController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'JSON 備份內容（匯出後會顯示於此，或在此貼上備份進行還原）',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}