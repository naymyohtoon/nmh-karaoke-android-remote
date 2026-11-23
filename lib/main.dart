import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const NmhKaraokeRemoteApp());
}

class NmhKaraokeRemoteApp extends StatelessWidget {
  const NmhKaraokeRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NMH Karaoke Remote',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070B14),
      ),
      home: const RemoteHomeScreen(),
    );
  }
}

class RemoteHomeScreen extends StatefulWidget {
  const RemoteHomeScreen({super.key});

  @override
  State<RemoteHomeScreen> createState() => _RemoteHomeScreenState();
}

class _RemoteHomeScreenState extends State<RemoteHomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounceController;

  // PC Server Connection State
  String _pcIp = '';
  final int _pcPort = 8080;
  WebSocketChannel? _wsChannel;
  bool _isConnected = false;
  bool _isDbReady = false;
  int _scannedFileCount = 0;

  String _currentView = 'HOME';
  bool _showMyanmarSubPopup = false;
  bool _showNumberPopup = false;

  String _genderFilter = 'ALL';
  String _searchQuery = '';
  bool _useFullKeyboard = false;
  final TextEditingController _fullTextController = TextEditingController();
  final FocusNode _fullTextFocus = FocusNode();

  String _listHeaderTitle = '';
  List<Map<String, dynamic>> _songResults = [];
  List<Map<String, dynamic>> _artistResults = [];
  List<Map<String, dynamic>> _albumResults = [];
  List<String> _thingyanAlbums = [];
  String _selectedThingyanAlbum = '';

  int _songbookPage = 0;
  final int _songsPerBookPage = 10;

  List<Map<String, dynamic>> _queue = [];
  Map<String, dynamic>? _currentSong;

  bool _isMuted = false;
  double _volume = 100.0;
  String _audioChannelMode = 'Stereo';
  int _selectedAudioTrackIndex = 0;

  static const List<String> _myanmarConsonants = [
    'က', 'ခ', 'ဂ', 'ဃ', 'င', 'စ', 'ဆ',
    'ဇ', 'ဈ', 'ည', 'ဋ', 'ဌ', 'ဍ', 'ဎ',
    'ဏ', 'တ', 'ထ', 'ဒ', 'ဓ', 'န', 'ပ',
    'ဖ', 'ဗ', 'ဘ', 'မ', 'ယ', 'ရ', 'လ',
    'ဝ', 'သ', 'ဟ', 'ဠ', 'အ'
  ];
    String _formatSongCode(Map<String, dynamic> song) {
    final c = (song['code'] ?? '').toString().trim();
    if (c.isNotEmpty) return c.replaceFirst(RegExp(r'^[aA]'), '');
    final fc = (song['file_code'] ?? '').toString().trim();
    return fc.replaceFirst(RegExp(r'^[aA]'), '');
  }

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _loadSavedIpAndConnect();
  }

  Future<void> _loadSavedIpAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('pc_server_ip') ?? '';
    if (savedIp.isNotEmpty) {
      setState(() => _pcIp = savedIp);
      _connectToPc(savedIp);
    }
  }

  Future<void> _connectToPc(String ip) async {
    final cleanIp = ip.trim();
    if (cleanIp.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pc_server_ip', cleanIp);

    setState(() {
      _pcIp = cleanIp;
      _isConnected = false;
    });

    try {
      await _wsChannel?.sink.close();
      final uri = Uri.parse('ws://$cleanIp:$_pcPort/ws');
      final channel = WebSocketChannel.connect(uri);
      await channel.ready;

      _wsChannel = channel;
      if (mounted) setState(() => _isConnected = true);

      channel.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message.toString());
            if (data['type'] == 'STATE' && mounted) {
              setState(() {
                _currentSong = data['currentSong'] != null
                    ? Map<String, dynamic>.from(data['currentSong'])
                    : null;
                _queue = (data['queue'] as List? ?? [])
                    .map((e) => Map<String, dynamic>.from(e))
                    .toList();
                _volume = (data['volume'] as num? ?? 100).toDouble();
                _isMuted = data['isMuted'] == true;
                _audioChannelMode =
                    (data['audioChannelMode'] ?? 'Stereo').toString();
                _selectedAudioTrackIndex =
                    (data['selectedAudioTrackIndex'] as int?) ?? 0;
                _isDbReady = data['isDbReady'] == true;
                _scannedFileCount = (data['scannedFileCount'] as int?) ?? 0;
              });
            }
          } catch (_) {}
        },
        onDone: () {
          if (mounted) setState(() => _isConnected = false);
        },
        onError: (_) {
          if (mounted) setState(() => _isConnected = false);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _isConnected = false);
    }
  }
    void _sendCommand(Map<String, dynamic> cmd) {
    if (_wsChannel == null || !_isConnected) {
      _showIpConnectDialog();
      return;
    }
    try {
      _wsChannel!.sink.add(jsonEncode(cmd));
    } catch (_) {
      setState(() => _isConnected = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchApiList(
      String endpoint, Map<String, String> params) async {
    if (_pcIp.isEmpty) return [];
    try {
      final uri = Uri.http('$_pcIp:$_pcPort', endpoint, params);
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final List decoded = jsonDecode(utf8.decode(res.bodyBytes));
        return decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  void _showIpConnectDialog() {
    final controller = TextEditingController(text: _pcIp);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141E36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF00F5D4), width: 1.5),
        ),
        title: const Text('PC Server IP ချိတ်ဆက်ရန်',
            style: TextStyle(color: Color(0xFFFFD166), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PC မျက်နှာပြင် ညာဘက်အပေါ်ထောင့်တွင် ပြထားသော IP Address ကို ရိုက်ထည့်ပါ (ဥပမာ - 192.168.1.50)',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.black45,
                hintText: '192.168.1.xxx',
                hintStyle: const TextStyle(color: Colors.white38),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF00F5D4)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ပိတ်မည်', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00F5D4)),
            onPressed: () {
              Navigator.pop(ctx);
              _connectToPc(controller.text);
            },
            child: const Text('ချိတ်ဆက်မည်',
                style: TextStyle(
                    color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
    @override
  void dispose() {
    _wsChannel?.sink.close();
    _bounceController.dispose();
    _fullTextController.dispose();
    _fullTextFocus.dispose();
    super.dispose();
  }

  Future<void> _openArtistView() async {
    setState(() {
      _currentView = 'ARTIST_GRID';
      _showMyanmarSubPopup = false;
      _searchQuery = '';
      _fullTextController.clear();
    });
    final list = await _fetchApiList('/api/artists', {
      'initial': '',
      'gender': _genderFilter,
      'fullText': _useFullKeyboard.toString(),
    });
    if (mounted) setState(() => _artistResults = list);
  }

  Future<void> _openAlbumView() async {
    setState(() {
      _currentView = 'ALBUM_GRID';
      _showMyanmarSubPopup = false;
      _searchQuery = '';
      _fullTextController.clear();
    });
    final list = await _fetchApiList('/api/albums', {
      'initial': '',
      'category': 'Myanmar',
      'fullText': _useFullKeyboard.toString(),
    });
    if (mounted) setState(() => _albumResults = list);
  }

  Future<void> _openSongTitleView(
      {String category = 'Myanmar', String title = 'သီချင်းအမည်'}) async {
    setState(() {
      _currentView = 'SONG_LIST';
      _listHeaderTitle = title;
      _showMyanmarSubPopup = false;
      _searchQuery = '';
      _fullTextController.clear();
    });
    final list = await _fetchApiList('/api/songs', {
      'mode': category,
      'query': '',
      'fullText': 'false',
    });
    if (mounted) setState(() => _songResults = list);
  }

  Future<void> _openSongbookView() async {
    setState(() {
      _currentView = 'SONGBOOK';
      _showMyanmarSubPopup = false;
      _songbookPage = 0;
    });
    final list = await _fetchApiList('/api/songs', {
      'mode': 'ALL',
      'query': '',
      'fullText': 'false',
    });
    if (mounted) setState(() => _songResults = list);
  }

  Future<void> _openThingyanView() async {
    setState(() {
      _currentView = 'THINGYAN';
      _showMyanmarSubPopup = false;
    });
    final albums = await _fetchApiList('/api/albums', {
      'initial': '',
      'category': 'Thingyan',
      'fullText': 'false',
    });
    final albumNames = albums
        .map((e) => (e['album'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
    _thingyanAlbums = albumNames;
    _selectedThingyanAlbum = albumNames.isNotEmpty ? albumNames.first : '';
    final songs = _selectedThingyanAlbum.isNotEmpty
        ? await _fetchApiList('/api/songs_by_field', {
            'field': 'album',
            'value': _selectedThingyanAlbum,
          })
        : await _fetchApiList('/api/songs', {
            'mode': 'THINGYAN',
            'query': '',
            'fullText': 'false',
          });
    if (mounted) setState(() => _songResults = songs);
  }
    Future<void> _onSearchChanged(String val) async {
    setState(() => _searchQuery = val);
    if (_currentView == 'ARTIST_GRID') {
      final list = await _fetchApiList('/api/artists', {
        'initial': val,
        'gender': _genderFilter,
        'fullText': _useFullKeyboard.toString(),
      });
      if (mounted) setState(() => _artistResults = list);
    } else if (_currentView == 'ALBUM_GRID') {
      final list = await _fetchApiList('/api/albums', {
        'initial': val,
        'category': 'Myanmar',
        'fullText': _useFullKeyboard.toString(),
      });
      if (mounted) setState(() => _albumResults = list);
    } else if (_currentView == 'SONG_LIST') {
      final mode = _listHeaderTitle == 'Disco Songs' ? 'DISCO' : 'Myanmar';
      final list = await _fetchApiList('/api/songs', {
        'mode': mode,
        'query': val,
        'fullText': _useFullKeyboard.toString(),
      });
      if (mounted) setState(() => _songResults = list);
    }
  }

  void _playSongOnPc(Map<String, dynamic> song) {
    setState(() {
      _showMyanmarSubPopup = false;
      _showNumberPopup = false;
    });
    _sendCommand({'action': 'PLAY_SONG', 'song': song});
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 1),
        backgroundColor: const Color(0xFF00B4D8),
        content: Text('PC တွင် ဖွင့်နေပါသည်: ${song['title'] ?? ''}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _showAudioChannelDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141E36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF00F5D4), width: 1.5),
        ),
        title: const Text('PC Audio Track / Channel ရွေးရန်',
            style: TextStyle(color: Color(0xFFFFD166), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Audio Tracks (အဆိုပါ / တီးလုံးသီးသန့်):',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (int i = 0; i < 2; i++)
                  ChoiceChip(
                    avatar: Icon(
                      i == 0 ? Icons.mic : Icons.music_note,
                      size: 16,
                      color: _selectedAudioTrackIndex == i
                          ? Colors.black
                          : const Color(0xFFFFD166),
                    ),
                    label: Text(
                      i == 0
                          ? 'Track 1 (Vocal + Music)'
                          : 'Track 2 (Karaoke / Music)',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    selected: _selectedAudioTrackIndex == i,
                    selectedColor: const Color(0xFFFFD166),
                    labelStyle: TextStyle(
                      color: _selectedAudioTrackIndex == i
                          ? Colors.black
                          : Colors.white,
                    ),
                    onSelected: (_) {
                      _sendCommand({'action': 'TRACK_INDEX', 'index': i});
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('2. Left / Right Channel:',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final mode in ['Stereo', 'Left', 'Right'])
                  ChoiceChip(
                    label: Text(mode,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    selected: _audioChannelMode == mode,
                    selectedColor: const Color(0xFF00F5D4),
                    labelStyle: TextStyle(
                      color: _audioChannelMode == mode
                          ? Colors.black
                          : Colors.white,
                    ),
                    onSelected: (_) {
                      _sendCommand({'action': 'AUDIO_MODE', 'mode': mode});
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
    @override
  Widget build(BuildContext context) {
    final double keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFCBD5E1),
                    Color(0xFF64748B),
                    Color(0xFF1E293B),
                  ],
                  stops: [0.0, 0.45, 1.0],
                ),
              ),
              child: Column(
                children: [
                  _buildTopBar(),
                  Expanded(child: _buildMainContent()),
                  _buildBottomControlBar(),
                ],
              ),
            ),
          ),
          if (keyboardHeight > 0 && _useFullKeyboard)
            Positioned(
              left: 12,
              right: 12,
              bottom: keyboardHeight + 6,
              child: Material(
                elevation: 10,
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFF141E36),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: const Color(0xFF00F5D4), width: 2),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Color(0xFF00F5D4)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _fullTextController,
                          autofocus: true,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'ရှာလိုသော စာသား ရိုက်ထည့်ပါ...',
                            hintStyle: TextStyle(color: Colors.white54),
                            isDense: true,
                          ),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear, color: Colors.redAccent),
                        onPressed: () {
                          _fullTextController.clear();
                          _onSearchChanged('');
                        },
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00F5D4)),
                        onPressed: () => FocusScope.of(context).unfocus(),
                        child: const Text('OK',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_showNumberPopup) _buildNumberPopupOverlay(),
        ],
      ),
    );
  }
    Widget _buildTopBar() {
    final bool isHome = _currentView == 'HOME';
    return Container(
      height: 56,
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withOpacity(0.65),
        border: Border.all(color: Colors.white.withOpacity(0.28), width: 1.2),
      ),
      child: Row(
        children: [
          if (isHome) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 220,
                height: 46,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: const Color(0xFFFFD166).withOpacity(0.65)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Image.asset('assets/logo.png', fit: BoxFit.fill),
              ),
            ),
            if (_currentSong != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Playing: ${_currentSong!['title'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF00F5D4),
                      fontWeight: FontWeight.bold,
                      fontSize: 12),
                ),
              ),
            ] else
              const Spacer(),
            Text(
              'DB: ${_isDbReady ? "OK" : "NO"} | Songs: $_scannedFileCount',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            const SizedBox(width: 6),
            _topPillBtn(
              icon: _isConnected ? Icons.wifi : Icons.wifi_off,
              label: _isConnected ? 'PC: $_pcIp' : 'PC IP ချိတ်ရန်',
              active: _isConnected,
              accent: const Color(0xFF00F5D4),
              onTap: _showIpConnectDialog,
            ),
            const SizedBox(width: 6),
            _topPillBtn(
              icon: Icons.folder_special_rounded,
              label: 'ရွေးထားသော သီချင်းများ (${_queue.length})',
              active: true,
              accent: Colors.redAccent,
              onTap: () => setState(() => _currentView = 'QUEUE'),
            ),
          ] else ...[
            if (_currentView == 'ARTIST_GRID') ...[
              _topPillBtn(
                  label: 'အားလုံး',
                  active: _genderFilter == 'ALL',
                  accent: const Color(0xFFFFD166),
                  onTap: () {
                    _genderFilter = 'ALL';
                    _openArtistView();
                  }),
              const SizedBox(width: 6),
              _topPillBtn(
                  label: 'ကျား',
                  active: _genderFilter == 'M',
                  accent: const Color(0xFF00BBF9),
                  onTap: () {
                    _genderFilter = 'M';
                    _openArtistView();
                  }),
              const SizedBox(width: 6),
              _topPillBtn(
                  label: 'မ',
                  active: _genderFilter == 'F',
                  accent: const Color(0xFFFF4D6D),
                  onTap: () {
                    _genderFilter = 'F';
                    _openArtistView();
                  }),
            ] else ...[
              Text(
                _currentView == 'SONGBOOK'
                    ? 'သီချင်းစာအုပ် (စုစုပေါင်း ${_songResults.length} ပုဒ်)'
                    : _currentView == 'THINGYAN'
                        ? 'သင်္ကြန်သီချင်းခွေများ'
                        : _currentView == 'ALBUM_GRID'
                            ? 'တေးစီးရီးများ'
                            : _listHeaderTitle,
                style: const TextStyle(
                    color: Color(0xFFFFD166),
                    fontSize: 15,
                    fontWeight: FontWeight.bold),
              ),
            ],
            const Spacer(),
            if (_listHeaderTitle != 'Disco Songs' ||
                _currentView != 'SONG_LIST') ...[
              _topPillBtn(
                  icon: Icons.person,
                  label: 'အဆိုတော်',
                  active: _currentView == 'ARTIST_GRID',
                  accent: const Color(0xFFFFD166),
                  onTap: _openArtistView),
              const SizedBox(width: 6),
              _topPillBtn(
                  icon: Icons.album,
                  label: 'တေးစီးရီး',
                  active: _currentView == 'ALBUM_GRID',
                  accent: const Color(0xFF00F5D4),
                  onTap: _openAlbumView),
              const SizedBox(width: 6),
              _topPillBtn(
                  icon: Icons.music_note,
                  label: 'သီချင်းအမည်',
                  active: _currentView == 'SONG_LIST',
                  accent: const Color(0xFF00BBF9),
                  onTap: () => _openSongTitleView(
                      category: 'Myanmar', title: 'သီချင်းအမည်')),
              const SizedBox(width: 6),
              _topPillBtn(
                  icon: Icons.menu_book,
                  label: 'သီချင်းစာအုပ်',
                  active: _currentView == 'SONGBOOK',
                  accent: const Color(0xFFFF9F1C),
                  onTap: _openSongbookView),
              const SizedBox(width: 6),
            ],
            _topPillBtn(
                icon: Icons.folder_special,
                label: 'ရွေးထားသော သီချင်းများ (${_queue.length})',
                active: true,
                accent: Colors.redAccent,
                onTap: () => setState(() => _currentView = 'QUEUE')),
          ],
        ],
      ),
    );
    }
    Widget _topPillBtn({
    IconData? icon,
    required String label,
    required bool active,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: active ? accent : Colors.white.withOpacity(0.1),
          border: Border.all(
              color: active ? Colors.white : accent.withOpacity(0.75)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: active ? Colors.black : accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: active ? Colors.black : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent() {
    switch (_currentView) {
      case 'ARTIST_GRID':
        return _buildGridWithKeyboard(isAlbum: false);
      case 'ALBUM_GRID':
        return _buildGridWithKeyboard(isAlbum: true);
      case 'SONG_LIST':
        return _buildSongListWithKeyboard();
      case 'SONGBOOK':
        return _buildSongbookTwoPageView();
      case 'THINGYAN':
        return _buildThingyanView();
      case 'QUEUE':
        return _buildQueueView();
      default:
        return _buildHomeCardsWithPopup();
    }
  }

  Widget _buildHomeCardsWithPopup() {
    return GestureDetector(
      onTap: () {
        if (_showMyanmarSubPopup) setState(() => _showMyanmarSubPopup = false);
      },
      child: Stack(
        children: [
          Center(
            child: AnimatedBuilder(
              animation: _bounceController,
              builder: (context, child) {
                final double dy =
                    math.sin(_bounceController.value * math.pi) * -6.0;
                return Transform.translate(offset: Offset(0, dy), child: child);
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildMi7MainCard(
                    title: 'မြန်မာသီချင်းများ',
                    subtitle: 'MYANMAR',
                    icon: Icons.music_note_rounded,
                    accent: const Color(0xFFFFD166),
                    isSelected: _showMyanmarSubPopup,
                    onTap: () => setState(
                        () => _showMyanmarSubPopup = !_showMyanmarSubPopup),
                  ),
                  const SizedBox(width: 26),
                  _buildMi7MainCard(
                    title: 'Disco Songs',
                    subtitle: 'DISCO',
                    icon: Icons.album_rounded,
                    accent: const Color(0xFF00F5D4),
                    isSelected: false,
                    onTap: () => _openSongTitleView(
                        category: 'DISCO', title: 'Disco Songs'),
                  ),
                  const SizedBox(width: 26),
                  _buildMi7MainCard(
                    title: 'Number Input',
                    subtitle: 'NUMBER',
                    icon: Icons.dialpad_rounded,
                    accent: const Color(0xFFFF4D6D),
                    isSelected: _showNumberPopup,
                    onTap: () {
                      _searchQuery = '';
                      setState(() {
                        _showMyanmarSubPopup = false;
                        _showNumberPopup = true;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          if (_showMyanmarSubPopup)
            Positioned(
              bottom: 16,
              left: 14,
              right: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.arrow_drop_up,
                      color: Color(0xFFFFD166), size: 34),
                  Row(
                    children: [
                      Expanded(
                        child: _subMenuChip('အဆိုတော်', 'နာမည်ဖြင့် ရှာမည်',
                            Icons.person, const Color(0xFFFF4D6D), _openArtistView),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip('တေးစီးရီး', 'နာမည်ဖြင့် ရှာမည်',
                            Icons.album, const Color(0xFFFF9F1C), _openAlbumView),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip(
                            'သီချင်းအမည်',
                            'ဖြင့် ရှာမည်',
                            Icons.music_note,
                            const Color(0xFF00BBF9),
                            () => _openSongTitleView(
                                category: 'Myanmar', title: 'သီချင်းအမည်')),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip('သီချင်းစာရင်း', 'ကြည့်မည်',
                            Icons.menu_book, const Color(0xFF00F5D4), _openSongbookView),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _subMenuChip('သင်္ကြန်သီချင်း', 'များ ရှာမည်',
                            Icons.water_drop, const Color(0xFFFFD166), _openThingyanView),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
    Widget _buildMi7MainCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accent,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 190,
            height: 125,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(isSelected ? 0.34 : 0.22),
                  accent.withOpacity(isSelected ? 0.28 : 0.14),
                  Colors.black.withOpacity(0.45),
                ],
              ),
              border: Border.all(
                color: isSelected ? Colors.white : accent.withOpacity(0.85),
                width: isSelected ? 2.5 : 1.8,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 34, color: accent),
                const SizedBox(height: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                        color: accent)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _subMenuChip(String line1, String line2, IconData icon, Color color,
      VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.28),
              color.withOpacity(0.32),
              Colors.black.withOpacity(0.45),
            ],
          ),
          border: Border.all(color: color, width: 1.8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(line1,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            Text(line2,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildSongbookTwoPageView() {
    final int totalPages =
        (_songResults.length / (_songsPerBookPage * 2)).ceil().clamp(1, 9999);
    final int startIndex = _songbookPage * _songsPerBookPage * 2;
    final leftItems =
        _songResults.skip(startIndex).take(_songsPerBookPage).toList();
    final rightItems = _songResults
        .skip(startIndex + _songsPerBookPage)
        .take(_songsPerBookPage)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildSingleBookPage(leftItems)),
                Container(width: 4, color: Colors.black87),
                Expanded(child: _buildSingleBookPage(rightItems)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 32,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: totalPages,
              itemBuilder: (context, idx) {
                final bool active = idx == _songbookPage;
                return GestureDetector(
                  onTap: () => setState(() => _songbookPage = idx),
                  child: Container(
                    width: 52,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFFFFD166)
                          : Colors.white.withOpacity(0.18),
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(8)),
                      border: Border.all(color: Colors.white38),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Page',
                            style: TextStyle(
                                fontSize: 8,
                                color: active ? Colors.black : Colors.white70)),
                        Text('${idx + 1}',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: active ? Colors.black : Colors.white)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
    Widget _buildSingleBookPage(List<Map<String, dynamic>> items) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE5E7EB).withOpacity(0.94),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black54),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFFCBD5E1),
            child: const Row(
              children: [
                SizedBox(
                    width: 56,
                    child: Text('No',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
                Expanded(
                    flex: 6,
                    child: Text('သီချင်းအမည်',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
                Expanded(
                    flex: 4,
                    child: Text('Artist',
                        style: TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.bold,
                            fontSize: 12))),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: Colors.black12, height: 1),
              itemBuilder: (context, idx) {
                final s = items[idx];
                return InkWell(
                  onTap: () => _playSongOnPc(s),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 56,
                          child: Text(
                            _formatSongCode(s).padLeft(5, '0'),
                            style: const TextStyle(
                                color: Colors.black87,
                                fontWeight: FontWeight.bold,
                                fontSize: 11),
                          ),
                        ),
                        Expanded(
                          flex: 6,
                          child: Text(
                            (s['title'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w600,
                                fontSize: 12),
                          ),
                        ),
                        Expanded(
                          flex: 4,
                          child: Text(
                            (s['artist'] ?? '').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridWithKeyboard({required bool isAlbum}) {
    final items = isAlbum ? _albumResults : _artistResults;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: items.isEmpty
                ? Center(
                    child: Text(
                        isAlbum ? 'တေးစီးရီး မတွေ့ပါ' : 'အဆိုတော် မတွေ့ပါ',
                        style: const TextStyle(color: Colors.white70)))
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      childAspectRatio: 0.85,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, idx) {
                      final item = items[idx];
                      final String name =
                          (isAlbum ? item['album'] : item['artist'])
                              .toString();
                      final int photoNo = (item['id'] as int?) ?? 0;
                      final String photoUrl =
                          'http://$_pcIp:$_pcPort/api/photo?no=$photoNo&isAlbum=$isAlbum';
                                            return InkWell(
                        onTap: () async {
                          final songs = await _fetchApiList('/api/songs_by_field', {
                            'field': isAlbum ? 'album' : 'artist',
                            'value': name,
                          });
                          if (mounted) {
                            setState(() {
                              _listHeaderTitle = name;
                              _songResults = songs;
                              _currentView = 'SONG_LIST';
                            });
                          }
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: Colors.white.withOpacity(0.1),
                            border: Border.all(
                                color: (isAlbum
                                        ? const Color(0xFF00F5D4)
                                        : const Color(0xFFFFD166))
                                    .withOpacity(0.75)),
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: photoNo > 0 && _pcIp.isNotEmpty
                                    ? Padding(
                                        padding: EdgeInsets.all(isAlbum ? 6 : 0),
                                        child: isAlbum
                                            ? ClipOval(
                                                child: Image.network(
                                                  photoUrl,
                                                  fit: BoxFit.cover,
                                                  width: 72,
                                                  height: 72,
                                                  errorBuilder: (_, __, ___) =>
                                                      const Icon(Icons.album_rounded,
                                                          size: 42,
                                                          color: Color(0xFF00F5D4)),
                                                ),
                                              )
                                            : ClipRRect(
                                                borderRadius:
                                                    const BorderRadius.vertical(
                                                        top: Radius.circular(13)),
                                                child: Image.network(
                                                  photoUrl,
                                                  fit: BoxFit.cover,
                                                  width: double.infinity,
                                                  errorBuilder: (_, __, ___) =>
                                                      const Icon(Icons.person_rounded,
                                                          size: 42,
                                                          color: Color(0xFFFFD166)),
                                                ),
                                              ),
                                      )
                                    : Center(
                                        child: Icon(
                                          isAlbum
                                              ? Icons.album_rounded
                                              : Icons.person_rounded,
                                          size: 42,
                                          color: isAlbum
                                              ? const Color(0xFF00F5D4)
                                              : const Color(0xFFFFD166),
                                        ),
                                      ),
                              ),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 4, horizontal: 4),
                                decoration: BoxDecoration(
                                  color: isAlbum
                                      ? Colors.black54
                                      : const Color(0xFFB91C1C).withOpacity(0.85),
                                  borderRadius: const BorderRadius.vertical(
                                      bottom: Radius.circular(13)),
                                ),
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: _buildKeyboardPanel()),
        ],
      ),
    );
  }
    Widget _actionSymbolBtn({
    required String label,
    required IconData icon,
    required Color bgColor,
    VoidCallback? onTap,
    double fontSize = 11,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: Colors.black.withOpacity(0.18),
            ),
            Text(
              label,
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: fontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongListWithKeyboard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: _songResults.isEmpty
                  ? const Center(child: Text('သီချင်း မတွေ့ပါ'))
                  : ListView.separated(
                      itemCount: _songResults.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Colors.white12, height: 1),
                      itemBuilder: (context, idx) {
                        final s = _songResults[idx];
                        final bool isPlaying = _currentSong != null &&
                            _currentSong!['code'] == s['code'];
                        final String codeStr = _formatSongCode(s);
                        final String albumStr =
                            (s['album'] ?? '').toString().trim();
                        return Container(
                          color: isPlaying
                              ? const Color(0xFF00F5D4).withOpacity(0.18)
                              : Colors.transparent,
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 0),
                            leading: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: isPlaying
                                    ? const Color(0xFFFFD166)
                                    : Colors.white.withOpacity(0.14),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                codeStr,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isPlaying
                                      ? Colors.black
                                      : const Color(0xFF00F5D4),
                                ),
                              ),
                            ),
                            title: Text(
                              (s['title'] ?? '').toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: isPlaying
                                    ? const Color(0xFFFFD166)
                                    : Colors.white,
                              ),
                            ),
                            subtitle: Text(
                              albumStr.isNotEmpty
                                  ? '${s['artist'] ?? ''} • $albumStr'
                                  : '${s['artist'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.white70),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _actionSymbolBtn(
                                  label: 'ရွေးမည်',
                                  icon: Icons.add_circle_outline_rounded,
                                  bgColor: const Color(0xFFFFD166),
                                  onTap: () {
                                    _sendCommand(
                                        {'action': 'ADD_QUEUE', 'song': s});
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        duration: const Duration(seconds: 1),
                                        content: Text(
                                            'PC စာရင်းထဲ ထည့်ပြီး: ${s['title']}'),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 6),
                                _actionSymbolBtn(
                                  label: 'Play မည်',
                                  icon: Icons.play_circle_filled_rounded,
                                  bgColor: const Color(0xFF00F5D4),
                                  onTap: () => _playSongOnPc(s),
                                ),
                              ],
                            ),
                            onTap: () => _playSongOnPc(s),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: _buildKeyboardPanel()),
        ],
      ),
    );
  }
    Widget _buildThingyanView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 6,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: ListView.separated(
                itemCount: _songResults.length,
                separatorBuilder: (_, __) =>
                    const Divider(color: Colors.white12, height: 1),
                itemBuilder: (context, idx) {
                  final s = _songResults[idx];
                  return ListTile(
                    dense: true,
                    leading: Text(_formatSongCode(s),
                        style: const TextStyle(
                            color: Color(0xFF00F5D4),
                            fontWeight: FontWeight.bold,
                            fontSize: 11)),
                    title: Text((s['title'] ?? '').toString(),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text((s['artist'] ?? '').toString(),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _actionSymbolBtn(
                          label: 'ရွေးမည်',
                          icon: Icons.add_circle_outline_rounded,
                          bgColor: const Color(0xFFFFD166),
                          onTap: () {
                            _sendCommand({'action': 'ADD_QUEUE', 'song': s});
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                duration: const Duration(seconds: 1),
                                content: Text(
                                    'PC စာရင်းထဲ ထည့်ပြီး: ${s['title']}'),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 6),
                        _actionSymbolBtn(
                          label: 'Play မည်',
                          icon: Icons.play_circle_filled_rounded,
                          bgColor: const Color(0xFF00F5D4),
                          onTap: () => _playSongOnPc(s),
                        ),
                      ],
                    ),
                    onTap: () => _playSongOnPc(s),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: const Color(0xFFFFD166).withOpacity(0.6)),
              ),
              child: ListView.builder(
                itemCount: _thingyanAlbums.length,
                itemBuilder: (context, idx) {
                  final alb = _thingyanAlbums[idx];
                  final selected = alb == _selectedThingyanAlbum;
                  return ListTile(
                    dense: true,
                    selected: selected,
                    selectedTileColor:
                        const Color(0xFFFFD166).withOpacity(0.25),
                    leading: const Icon(Icons.spa, color: Color(0xFFFFD166)),
                    title: Text(alb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.white)),
                    onTap: () async {
                      _selectedThingyanAlbum = alb;
                      final songs = await _fetchApiList('/api/songs_by_field', {
                        'field': 'album',
                        'value': alb,
                      });
                      if (mounted) setState(() => _songResults = songs);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
    }
    Widget _buildKeyboardPanel() {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _useFullKeyboard
                      ? TextField(
                          controller: _fullTextController,
                          focusNode: _fullTextFocus,
                          style: const TextStyle(
                              color: Colors.black, fontSize: 13),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'စာလုံးအပြည့် ရိုက်ပါ...',
                            hintStyle:
                                TextStyle(color: Colors.black45, fontSize: 12),
                            isDense: true,
                          ),
                          onChanged: _onSearchChanged,
                        )
                      : Text(
                          _searchQuery.isEmpty
                              ? 'အတိုကောက် ရှာရန်...'
                              : _searchQuery,
                          style: TextStyle(
                            color: _searchQuery.isEmpty
                                ? Colors.black45
                                : Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () {
                  _fullTextController.clear();
                  _onSearchChanged('');
                },
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 17),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () {
                  setState(() {
                    _useFullKeyboard = !_useFullKeyboard;
                    _searchQuery = '';
                    _fullTextController.clear();
                  });
                  if (_useFullKeyboard) {
                    Future.delayed(const Duration(milliseconds: 100), () {
                      if (mounted) _fullTextFocus.requestFocus();
                    });
                  } else {
                    FocusScope.of(context).unfocus();
                  }
                },
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF00F5D4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _useFullKeyboard ? 'အတိုကောက်' : 'ကီးဘုတ်အပြည့်',
                    style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const int cols = 7;
                const int rows = 5;
                final double cellW =
                    (constraints.maxWidth - (cols - 1) * 4) / cols;
                final double cellH =
                    (constraints.maxHeight - (rows - 1) * 4) / rows;
                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    childAspectRatio: (cellW / cellH).clamp(0.5, 3.5),
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: _myanmarConsonants.length,
                  itemBuilder: (context, idx) {
                    final ch = _myanmarConsonants[idx];
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color(0xFF1E2D52),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: const BorderSide(
                              color: Color(0xFF00BBF9), width: 0.8),
                        ),
                      ),
                      onPressed: () => _onSearchChanged(_searchQuery + ch),
                      child: Text(ch,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
    }
    Widget _buildNumberPopupOverlay() {
    final keys = [
      '1', '2', '3', '4', '5', '6',
      '7', '8', '9', 'Clear', '0', 'Del'
    ];
    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          width: 460,
          height: 250,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF141E36),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFF4D6D), width: 2),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFFFD166)),
                      ),
                      child: Text(
                        _searchQuery.isEmpty
                            ? 'သီချင်းနံပါတ် ရိုက်ပါ...'
                            : _searchQuery,
                        style: const TextStyle(
                            color: Color(0xFFFFD166),
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00F5D4)),
                    onPressed: () async {
                      final songs = await _fetchApiList('/api/songs', {
                        'mode': 'NUMBER',
                        'query': _searchQuery,
                        'fullText': 'false',
                      });
                      if (mounted) {
                        setState(() {
                          _showNumberPopup = false;
                          _listHeaderTitle = 'Number: $_searchQuery';
                          _songResults = songs;
                          _currentView = 'SONG_LIST';
                        });
                      }
                    },
                    child: const Text('ရှာမည်',
                        style: TextStyle(
                            color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.redAccent),
                    onPressed: () => setState(() => _showNumberPopup = false),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                    childAspectRatio: 1.3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: keys.length,
                  itemBuilder: (context, idx) {
                    final k = keys[idx];
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color(0xFF1E2D52),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        setState(() {
                          if (k == 'Clear') {
                            _searchQuery = '';
                          } else if (k == 'Del') {
                            if (_searchQuery.isNotEmpty) {
                              _searchQuery = _searchQuery.substring(
                                  0, _searchQuery.length - 1);
                            }
                          } else {
                            _searchQuery += k;
                          }
                        });
                      },
                      child: Text(k,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    }
    Widget _buildQueueView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.72),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.redAccent, width: 1.6),
        ),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.folder_special, color: Colors.redAccent),
                const SizedBox(width: 8),
                Text('ရွေးထားသော သီချင်းများ (${_queue.length})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _currentView = 'HOME'),
                  child: const Text('ပိတ်မည်',
                      style: TextStyle(color: Color(0xFF00F5D4))),
                ),
              ],
            ),
            Expanded(
              child: _queue.isEmpty
                  ? const Center(
                      child: Text(
                          'ရွေးထားသော သီချင်းစာရင်းထဲတွင် သီချင်းမရှိသေးပါ'))
                  : ListView.separated(
                      itemCount: _queue.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Colors.white12, height: 1),
                      itemBuilder: (context, idx) {
                        final s = _queue[idx];
                        final String codeStr = _formatSongCode(s);
                        return ListTile(
                          dense: true,
                          leading: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              codeStr,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00F5D4),
                              ),
                            ),
                          ),
                          title: Text('${idx + 1}. ${s['title']}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white)),
                          subtitle: Text(s['artist'] ?? '',
                              style: const TextStyle(color: Colors.white70)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _actionSymbolBtn(
                                label: 'အပေါ်သို့',
                                icon: Icons.arrow_upward_rounded,
                                bgColor: idx > 0
                                    ? const Color(0xFFFFD166)
                                    : Colors.white24,
                                fontSize: 10,
                                onTap: idx > 0
                                    ? () => _sendCommand({
                                          'action': 'MOVE_QUEUE',
                                          'from': idx,
                                          'to': idx - 1,
                                        })
                                    : null,
                              ),
                              const SizedBox(width: 4),
                              _actionSymbolBtn(
                                label: 'အောက်သို့',
                                icon: Icons.arrow_downward_rounded,
                                bgColor: idx < _queue.length - 1
                                    ? const Color(0xFFFFD166)
                                    : Colors.white24,
                                fontSize: 10,
                                onTap: idx < _queue.length - 1
                                    ? () => _sendCommand({
                                          'action': 'MOVE_QUEUE',
                                          'from': idx,
                                          'to': idx + 1,
                                        })
                                    : null,
                              ),
                              const SizedBox(width: 4),
                              _actionSymbolBtn(
                                label: 'Play မည်',
                                icon: Icons.play_circle_filled_rounded,
                                bgColor: const Color(0xFF00F5D4),
                                fontSize: 10,
                                onTap: () => _playSongOnPc(s),
                              ),
                              const SizedBox(width: 4),
                              _actionSymbolBtn(
                                label: 'ဖျက်မည်',
                                icon: Icons.delete_rounded,
                                bgColor: Colors.redAccent,
                                fontSize: 10,
                                onTap: () => _sendCommand(
                                    {'action': 'REMOVE_QUEUE', 'index': idx}),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
    }
    Widget _buildBottomControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.82),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.22))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ctrlBtn(Icons.play_arrow_rounded, 'Play/Pause', Colors.pinkAccent,
              () => _sendCommand({'action': 'PLAY_PAUSE'})),
          _ctrlBtn(Icons.stop_rounded, 'Stop', Colors.redAccent,
              () => _sendCommand({'action': 'STOP'})),
          _ctrlBtn(Icons.repeat_rounded, 'Repeat', Colors.purpleAccent,
              () => _sendCommand({'action': 'RESTART'})),
          _ctrlBtn(Icons.fast_rewind_rounded, '<<<<', Colors.lightBlueAccent,
              () => _sendCommand({'action': 'SEEK_REL', 'sec': -10})),
          _ctrlBtn(Icons.fast_forward_rounded, '>>>>', Colors.lightBlueAccent,
              () => _sendCommand({'action': 'SEEK_REL', 'sec': 10})),
          _ctrlBtn(Icons.skip_previous_rounded, 'Re-Start', Colors.pinkAccent,
              () => _sendCommand({'action': 'RESTART'})),
          _ctrlBtn(Icons.skip_next_rounded, 'Next', Colors.pinkAccent,
              () => _sendCommand({'action': 'NEXT'})),
          _ctrlBtn(Icons.home_rounded, 'HOME', const Color(0xFFFFD166), () {
            setState(() {
              _currentView = 'HOME';
              _showMyanmarSubPopup = false;
              _showNumberPopup = false;
            });
          }, isHome: true),
          _ctrlBtn(Icons.speaker_group_rounded, _audioChannelMode,
              const Color(0xFF00F5D4), _showAudioChannelDialog),
          _ctrlBtn(
              Icons.mic_rounded,
              _selectedAudioTrackIndex == 0 ? 'Karaoke' : 'Vocal On',
              Colors.redAccent,
              () => _sendCommand({'action': 'CYCLE_TRACK'})),
          _ctrlBtn(Icons.volume_down_rounded, 'Volume-', Colors.cyanAccent, () {
            final nextVol = (_volume - 10).clamp(0, 100);
            _sendCommand({'action': 'VOLUME', 'vol': nextVol});
          }),
          _ctrlBtn(Icons.volume_up_rounded, 'Volume+', Colors.cyanAccent, () {
            final nextVol = (_volume + 10).clamp(0, 100);
            _sendCommand({'action': 'VOLUME', 'vol': nextVol});
          }),
          _ctrlBtn(Icons.volume_off_rounded, 'Mute', Colors.purpleAccent,
              () => _sendCommand({'action': 'MUTE'})),
          _ctrlBtn(Icons.thumb_up_rounded, 'Like', const Color(0xFFFFD166),
              () => _sendCommand({'action': 'APPLAUSE'})),
          _ctrlBtn(Icons.power_settings_new_rounded, 'Exit', Colors.redAccent,
              () => SystemNavigator.pop()),
        ],
      ),
    );
  }

  Widget _ctrlBtn(IconData icon, String label, Color color, VoidCallback onTap,
      {bool isHome = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: isHome ? 38 : 30,
            height: isHome ? 38 : 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isHome
                  ? const Color(0xFFFFD166)
                  : Colors.white.withOpacity(0.12),
              border: Border.all(
                  color: isHome ? Colors.white : color, width: 1.4),
            ),
            child: Icon(icon,
                size: isHome ? 22 : 16, color: isHome ? Colors.black : color),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 8.5,
              fontWeight: isHome ? FontWeight.bold : FontWeight.w500,
              color: isHome
                  ? const Color(0xFFFFD166)
                  : Colors.white.withOpacity(0.85),
            ),
          ),
        ],
      ),
    );
  }
}
