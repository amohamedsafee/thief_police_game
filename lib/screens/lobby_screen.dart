import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_theme.dart';
import '../core/app_router.dart';
import '../core/game_dialog.dart';
import '../core/design_system.dart';
import 'free_map_game_screen.dart';

enum LobbyTab {
  browse,
  host,
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key, required this.userId});
  final String userId;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  LobbyTab _currentTab = LobbyTab.browse;

  List<_GameEntry> _games = [];
  bool _isLoading = true;
  bool _isCreating = false;

  // Host configuration state
  int _selectedMaxThieves = 5;
  int _selectedDurationMinutes = 45;
  bool _isCustomDuration = false;
  double _customDuration = 45.0;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  final TextEditingController _roomNameController = TextEditingController();
  final FocusNode _roomNameFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChange);
    _roomNameFocusNode.addListener(_onRoomNameFocusChange);
    _db.child('active_games').onValue.listen(_onGamesSnapshot);
  }

  void _onSearchFocusChange() {
    setState(() {});
  }

  void _onRoomNameFocusChange() {
    setState(() {});
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onSearchFocusChange);
    _searchFocusNode.dispose();
    _searchController.dispose();
    _roomNameFocusNode.removeListener(_onRoomNameFocusChange);
    _roomNameFocusNode.dispose();
    _roomNameController.dispose();
    super.dispose();
  }

  // ── Firebase ──────────────────────────────────────────────────────────────

  void _cleanupStaleGames(Map<String, dynamic> rawMap) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const sevenDaysMs = 7 * 24 * 60 * 60 * 1000;
    
    rawMap.forEach((key, value) {
      if (value is Map) {
        final createdAt = value['created_at'] as num?;
        if (createdAt != null) {
          final age = nowMs - createdAt;
          if (age > sevenDaysMs) {
            _db.child('active_games/$key').remove();
            _db.child('locations/$key').remove();
            _db.child('caught_events/$key').remove();
          }
        }
      }
    });
  }

  void _onGamesSnapshot(DatabaseEvent event) {
    if (!mounted) return;
    final raw = event.snapshot.value;

    if (raw == null) {
      setState(() {
        _games = [];
        _isLoading = false;
      });
      return;
    }

    final rawMap = Map<String, dynamic>.from(raw as Map);
    _cleanupStaleGames(rawMap);

    final list = <_GameEntry>[];

    for (final e in rawMap.entries) {
      final game = Map<String, dynamic>.from(e.value as Map);
      if (game['status'] != 'waiting') continue;
      final thiefIds = game['thief_ids'];
      list.add(
        _GameEntry(
          id: e.key,
          policeId: game['police_id'] as String? ?? '',
          thiefCount: thiefIds is List ? thiefIds.length : 0,
          maxThieves: (game['max_thieves'] as num?)?.toInt() ?? 5,
        ),
      );
    }

    setState(() {
      _games = list;
      _isLoading = false;
    });
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<String> _generateUniqueRoomCode() async {
    final rand = Random();
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    while (true) {
      final code = List.generate(4, (index) => letters[rand.nextInt(letters.length)]).join();
      final snapshot = await _db.child('active_games/$code').get();
      if (!snapshot.exists) {
        return code;
      }
    }
  }

  Future<void> _createGame({int maxThieves = 5, int durationMinutes = 40, String roomName = ''}) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);

    String roomCode = '';
    try {
      roomCode = await _generateUniqueRoomCode();
    } catch (e) {
      debugPrint('Error generating unique room code: $e');
      final rand = Random();
      const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
      roomCode = List.generate(4, (index) => letters[rand.nextInt(letters.length)]).join();
    }

    final gameRef = _db.child('active_games').child(roomCode);
    await gameRef.set({
      'status': 'waiting',
      'police_id': widget.userId,
      'thief_ids': [],
      'visited_thief_ids': [], // permanent record — never shrinks
      'created_at': ServerValue.timestamp,
      'max_thieves': maxThieves,
      'duration_minutes': durationMinutes,
      'room_name': roomName.isNotEmpty ? roomName : 'PATROL $roomCode',
    });

    if (!mounted) return;
    setState(() => _isCreating = false);

    Navigator.push(
      context,
      AppRouter.slide(
        FreeMapGameScreen(
          gameId: roomCode,
          userId: widget.userId,
          isPolice: true,
        ),
      ),
    );
  }

  Future<void> _joinGame(String gameId) async {
    final gameRef = _db.child('active_games/$gameId');
    final snapshot = await gameRef.get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from(snapshot.value as Map);
    final thiefIds = List.from((data['thief_ids'] as List?) ?? []);
    final maxThieves = (data['max_thieves'] as num?)?.toInt() ?? 5;

    // ── One-visit rule ────────────────────────────────────────────────────────
    // A thief may only enter a room once. Once they leave (or are caught) their
    // ID stays in `visited_thief_ids` permanently, blocking a re-entry.
    final visitedIds = List.from((data['visited_thief_ids'] as List?) ?? []);
    if (visitedIds.contains(widget.userId)) {
      if (!mounted) return;
      _showSnack(
        '🚫 You have already been in this room and cannot re-enter.',
        backgroundColor: Colors.deepOrange.shade700,
      );
      return;
    }
    // ─────────────────────────────────────────────────────────────────────────

    if (thiefIds.length >= maxThieves) {
      if (!mounted) return;
      _showSnack('Game is full!', backgroundColor: Colors.red);
      return;
    }

    thiefIds.add(widget.userId);
    visitedIds.add(widget.userId); // record visit permanently
    await gameRef.update({
      'thief_ids': thiefIds,
      'visited_thief_ids': visitedIds,
    });

    if (!mounted) return;
    Navigator.push(
      context,
      AppRouter.slide(
        FreeMapGameScreen(
          gameId: gameId,
          userId: widget.userId,
          isPolice: false,
        ),
      ),
    );
  }

  Future<void> _deleteGame(String gameId) async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => GameDialog(
        title: 'DELETE GAME',
        message: 'Are you sure you want to delete this game room?',
        cancelLabel: 'CANCEL',
        confirmLabel: 'DELETE',
        confirmColor: Colors.red.shade700,
        leadingIcon: Icons.warning_amber_rounded,
        onConfirm: () => Navigator.pop(ctx, true),
        onCancel: () => Navigator.pop(ctx, false),
      ),
    );
    if (confirm != true || !mounted) return;

    _showSnack('Deleting game…', backgroundColor: Colors.orange);

    await Future.wait([
      _db.child('active_games/$gameId').remove(),
      _db.child('locations/$gameId').remove(),
      _db.child('caught_events/$gameId').remove(),
    ]);

    if (mounted) {
      _showSnack('Game deleted successfully!', backgroundColor: Colors.green);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _showSnack(String message, {Color? backgroundColor}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _searchFocusNode.hasFocus
                ? AppTheme.accent.withValues(alpha: 0.4)
                : AppTheme.divider,
            width: 1.5,
          ),
          boxShadow: _searchFocusNode.hasFocus
              ? [
                  BoxShadow(
                    color: AppTheme.accent.withValues(alpha: 0.1),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : [],
        ),
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          style: GoogleFonts.poppins(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          onChanged: (val) {
            setState(() {
              _searchQuery = val.trim().toUpperCase();
            });
          },
          decoration: InputDecoration(
            hintText: 'SEARCH ROOM CODE (e.g. ABCD)...',
            hintStyle: GoogleFonts.poppins(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: _searchFocusNode.hasFocus ? AppTheme.accent : Colors.white38,
            ),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                      });
                    },
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.mainGradient(),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _currentTab == LobbyTab.browse
                      ? _buildBrowsePanel()
                      : _buildHostPanel(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: LiquidGlassContainer(
        borderRadius: 20,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        child: Row(
          children: [
            RadarScanner(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [AppTheme.accent, AppTheme.secondary],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accent.withValues(alpha: 0.35),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(Icons.sports_esports_rounded, size: 24, color: Colors.white),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlowText(
                    'GAME LOBBY',
                    glowColor: AppTheme.accent,
                    glowRadius: 6,
                    style: AppTheme.bangersStyle(
                      fontSize: 26,
                      letterSpacing: 1.5,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    'Choose your workspace and start the chase',
                    style: AppTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: GlassSegmentedControl<LobbyTab>(
        segments: const {
          LobbyTab.browse: 'ACTIVE CHASES',
          LobbyTab.host: 'CREATE CHASE',
        },
        selectedSegment: _currentTab,
        onSegmentSelected: (tab) {
          setState(() {
            _currentTab = tab;
          });
        },
      ),
    );
  }

  Widget _buildBrowsePanel() {
    return Column(
      key: const ValueKey('browse'),
      children: [
        const SizedBox(height: 10),
        _buildSearchBar(),
        const SizedBox(height: 14),
        _buildActiveGamesLabel(),
        const SizedBox(height: 10),
        Expanded(child: _buildGamesList()),
      ],
    );
  }

  Widget _buildHostPanel() {
    return SingleChildScrollView(
      key: const ValueKey('host'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LiquidGlassContainer(
        borderRadius: 24,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [AppTheme.danger, AppTheme.warning],
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.local_police_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GlowText(
                      'HOST CONFIGURATION',
                      glowColor: AppTheme.accent,
                      glowRadius: 6,
                      style: AppTheme.bangersStyle(
                        fontSize: 22,
                        letterSpacing: 1,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Configure your tactical room parameters',
                      style: AppTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
            const Divider(color: Colors.white12, height: 28),
            Text(
              'ROOM NAME',
              style: GoogleFonts.spaceMono(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppTheme.accent,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _roomNameFocusNode.hasFocus
                      ? AppTheme.accent.withValues(alpha: 0.4)
                      : Colors.white.withValues(alpha: 0.05),
                  width: 1.5,
                ),
              ),
              child: TextField(
                controller: _roomNameController,
                focusNode: _roomNameFocusNode,
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'ENTER ROOM NAME (e.g. ALPHA PATROL)...',
                  hintStyle: GoogleFonts.poppins(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(Icons.edit_road_rounded, color: Colors.white38),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'MAX THIEVES IN ROOM',
              style: GoogleFonts.spaceMono(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppTheme.accent,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [3, 5, 8, 10].map((count) {
                final isSelected = _selectedMaxThieves == count;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedMaxThieves = count;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        gradient: isSelected
                            ? LinearGradient(
                                colors: [AppTheme.accent.withValues(alpha: 0.2), AppTheme.secondary.withValues(alpha: 0.6)],
                              )
                            : null,
                        color: isSelected ? null : Colors.white.withValues(alpha: 0.02),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected ? AppTheme.accent : Colors.white.withValues(alpha: 0.05),
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '$count',
                          style: AppTheme.bodyLarge.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isSelected ? Colors.white : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CHASE DURATION',
                  style: GoogleFonts.spaceMono(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accent,
                    letterSpacing: 1.5,
                  ),
                ),
                Text(
                  _isCustomDuration
                      ? '${_customDuration.toInt()} Mins'
                      : '$_selectedDurationMinutes Mins',
                  style: GoogleFonts.spaceMono(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [5, 15, 30, 45].map<Widget>((minutes) {
                final isSelected = !_isCustomDuration && _selectedDurationMinutes == minutes;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _isCustomDuration = false;
                      _selectedDurationMinutes = minutes;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      gradient: isSelected
                          ? LinearGradient(
                              colors: [AppTheme.accent.withValues(alpha: 0.2), AppTheme.secondary.withValues(alpha: 0.6)],
                            )
                          : null,
                      color: isSelected ? null : Colors.white.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected ? AppTheme.accent : Colors.white.withValues(alpha: 0.05),
                        width: 1.5,
                      ),
                    ),
                    child: Text(
                      '$minutes Min',
                      style: AppTheme.bodyMedium.copyWith(
                        fontWeight: FontWeight.bold,
                        color: isSelected ? Colors.white : AppTheme.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList()
                ..add(
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isCustomDuration = true;
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: _isCustomDuration
                            ? LinearGradient(
                                colors: [AppTheme.accent.withValues(alpha: 0.2), AppTheme.secondary.withValues(alpha: 0.6)],
                              )
                            : null,
                        color: _isCustomDuration ? null : Colors.white.withValues(alpha: 0.02),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _isCustomDuration ? AppTheme.accent : Colors.white.withValues(alpha: 0.05),
                          width: 1.5,
                        ),
                      ),
                      child: Text(
                        'Custom ⚙️',
                        style: AppTheme.bodyMedium.copyWith(
                          fontWeight: FontWeight.bold,
                          color: _isCustomDuration ? Colors.white : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: Container(
                height: _isCustomDuration ? null : 0,
                padding: const EdgeInsets.only(top: 18),
                child: _isCustomDuration
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: AppTheme.accent,
                              inactiveTrackColor: Colors.white10,
                              thumbColor: Colors.white,
                              overlayColor: AppTheme.accent.withValues(alpha: 0.2),
                              valueIndicatorColor: AppTheme.accent,
                              valueIndicatorTextStyle: GoogleFonts.spaceMono(color: AppTheme.primary),
                            ),
                            child: Slider(
                              value: _customDuration,
                              min: 1,
                              max: 120,
                              divisions: 119,
                              label: '${_customDuration.toInt()} Min',
                              onChanged: (value) {
                                setState(() {
                                  _customDuration = value;
                                });
                              },
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 32),
            NeoGlassButton(
              onPressed: _isCreating
                  ? null
                  : () {
                      final duration = _isCustomDuration
                          ? _customDuration.toInt()
                          : _selectedDurationMinutes;
                      _createGame(
                        maxThieves: _selectedMaxThieves,
                        durationMinutes: duration,
                        roomName: _roomNameController.text.trim(),
                      );
                    },
              accentColor: AppTheme.accent,
              glowing: true,
              height: 60,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.flash_on_rounded, size: 24, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    'LAUNCH CHASE ⚡',
                    style: AppTheme.bangersStyle(
                      fontSize: 20,
                      letterSpacing: 1.5,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveGamesLabel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          DynamicGradientPill(
            child: Text(
              'ACTIVE GAMES',
              style: GoogleFonts.bangers(fontSize: 18, color: Colors.white),
            ),
          ),
          const Spacer(),
          Text(
            '${_games.length} available',
            style: GoogleFonts.poppins(fontSize: 12, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildGamesList() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final filteredGames = _games.where((game) {
      return game.id.toUpperCase().contains(_searchQuery);
    }).toList();

    // Show "no games at all" only when there truly are none and no active search.
    if (_games.isEmpty && _searchQuery.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.games, size: 80, color: Colors.white.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text(
              'No Games Available',
              style: GoogleFonts.poppins(
                fontSize: 18,
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Create a game as Police to start',
              style: GoogleFonts.poppins(fontSize: 14, color: Colors.white54),
            ),
          ],
        ),
      );
    }

    // Show "no search results" when the query doesn't match any room.
    if (filteredGames.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded, size: 70, color: Colors.white.withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text(
              'No Rooms Found',
              style: GoogleFonts.poppins(
                fontSize: 18,
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _searchQuery.isEmpty
                  ? 'Create a game as Police to start'
                  : 'No active rooms match "$_searchQuery"',
              style: GoogleFonts.poppins(fontSize: 14, color: Colors.white54),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: filteredGames.length,
      itemBuilder: (context, index) => StaggeredAnimatedCard(
        index: index,
        child: _GameCard(
          game: filteredGames[index],
          myUserId: widget.userId,
          onJoin: () => _joinGame(filteredGames[index].id),
          onDelete: () => _deleteGame(filteredGames[index].id),
        ),
      ),
    );
  }
}

// ── Data model ────────────────────────────────────────────────────────────────

class _GameEntry {
  const _GameEntry({
    required this.id,
    required this.policeId,
    required this.thiefCount,
    required this.maxThieves,
  });
  final String id;
  final String policeId;
  final int thiefCount;
  final int maxThieves;
}

// ── Game card widget ──────────────────────────────────────────────────────────

class _GameCard extends StatefulWidget {
  const _GameCard({
    required this.game,
    required this.myUserId,
    required this.onJoin,
    required this.onDelete,
  });

  final _GameEntry game;
  final String myUserId;
  final VoidCallback onJoin;
  final VoidCallback onDelete;

  @override
  State<_GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<_GameCard> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isCreator = widget.game.policeId == widget.myUserId;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.97 : 1.00,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: LiquidGlassContainer(
            borderRadius: 22,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            accentColor: isCreator ? AppTheme.accent : AppTheme.thiefAccent,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isCreator
                        ? [AppTheme.accent, AppTheme.secondary]
                        : [AppTheme.thiefAccent, AppTheme.secondary],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: (isCreator ? AppTheme.accent : AppTheme.thiefAccent).withValues(alpha: 0.3),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Icon(
                  isCreator ? Icons.local_police_rounded : Icons.directions_run_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              title: Text(
                'ROOM ${widget.game.id}',
                style: GoogleFonts.spaceMono(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 2.0,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.people_alt_rounded, size: 14, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      '${widget.game.thiefCount}/${widget.game.maxThieves} thieves',
                      style: AppTheme.bodySmall,
                    ),
                    if (isCreator) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppTheme.accent, AppTheme.secondary],
                          ),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accent.withValues(alpha: 0.2),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Text(
                          'HOST',
                          style: GoogleFonts.spaceMono(
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCreator) ...[
                    IconButton(
                      onPressed: widget.onDelete,
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: AppTheme.danger,
                        size: 22,
                      ),
                      tooltip: 'Delete Game',
                      style: IconButton.styleFrom(
                        backgroundColor: AppTheme.danger.withValues(alpha: 0.1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  AnimatedJoinButton(
                    onTap: widget.onJoin,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RadarScanner extends StatefulWidget {
  const RadarScanner({super.key, required this.child});
  final Widget child;

  @override
  State<RadarScanner> createState() => _RadarScannerState();
}

class _RadarScannerState extends State<RadarScanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _RadarPainter(_controller.value),
          child: widget.child,
        );
      },
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = (size.width > size.height ? size.width : size.height) * 1.6;

    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + i / 3.0) % 1.0;
      final radius = maxRadius * ringProgress;
      final opacity = (1.0 - ringProgress) * 0.25;

      final paint = Paint()
        ..color = AppTheme.accent.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class ShinyGlazeButton extends StatefulWidget {
  const ShinyGlazeButton({super.key, required this.child});
  final Widget child;

  @override
  State<ShinyGlazeButton> createState() => _ShinyGlazeButtonState();
}

class _ShinyGlazeButtonState extends State<ShinyGlazeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return CustomPaint(
          foregroundPainter: _SheenPainter(progress),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.accent.withValues(alpha: 0.15 + sin(progress * 2 * pi) * 0.05),
                  blurRadius: 16 + sin(progress * 2 * pi) * 4,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}

class _SheenPainter extends CustomPainter {
  _SheenPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress > 0.40) return;

    final sheenProgress = progress / 0.40;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.35, 0.5, 0.65],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..blendMode = BlendMode.srcATop;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(20),
      ));

    canvas.save();
    canvas.clipPath(path);

    final xTranslation = size.width * 2 * sheenProgress - size.width;
    canvas.translate(xTranslation, 0);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SheenPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class DynamicGradientPill extends StatefulWidget {
  const DynamicGradientPill({super.key, required this.child});
  final Widget child;

  @override
  State<DynamicGradientPill> createState() => _DynamicGradientPillState();
}

class _DynamicGradientPillState extends State<DynamicGradientPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final double wave = sin(_controller.value * 2 * pi);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.0 + wave * 0.2, -0.5),
              end: Alignment(1.0 - wave * 0.2, 0.5),
              colors: const [AppTheme.accent, AppTheme.danger],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppTheme.accent.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: Offset(-2, 3 + wave * 2),
              ),
              BoxShadow(
                color: AppTheme.danger.withValues(alpha: 0.12),
                blurRadius: 10,
                offset: Offset(2, 3 + wave * 2),
              ),
            ],
          ),
          child: widget.child,
        );
      },
    );
  }
}

class StaggeredAnimatedCard extends StatefulWidget {
  const StaggeredAnimatedCard({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  State<StaggeredAnimatedCard> createState() => _StaggeredAnimatedCardState();
}

class _StaggeredAnimatedCardState extends State<StaggeredAnimatedCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _slideAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.8, curve: Curves.easeOut),
      ),
    );

    _slideAnim = Tween<double>(begin: 35.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
      ),
    );

    Future.delayed(Duration(milliseconds: min(300, widget.index * 75)), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _fadeAnim.value,
          child: Transform.translate(
            offset: Offset(0, _slideAnim.value),
            child: widget.child,
          ),
        );
      },
    );
  }
}

class AnimatedJoinButton extends StatefulWidget {
  const AnimatedJoinButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  State<AnimatedJoinButton> createState() => _AnimatedJoinButtonState();
}

class _AnimatedJoinButtonState extends State<AnimatedJoinButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slideAnim;
  late final Animation<double> _glowAnim;
  late final Animation<double> _sheenAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _slideAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 4.0).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
      TweenSequenceItem(tween: Tween<double>(begin: 4.0, end: 0.0).chain(CurveTween(curve: Curves.easeIn)), weight: 30),
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 40),
    ]).animate(_controller);

    _glowAnim = Tween<double>(begin: 4.0, end: 12.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _sheenAnim = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeInOut),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              foregroundPainter: _JoinSheenPainter(_sheenAnim.value),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.accent,
                      Color.lerp(AppTheme.accent, Colors.purple, 0.4)!,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accent.withValues(alpha: 0.3),
                      blurRadius: _glowAnim.value,
                      spreadRadius: 1,
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: Offset(_slideAnim.value, 0),
                      child: const Icon(
                        Icons.login_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'JOIN',
                      style: GoogleFonts.bangers(
                        fontSize: 15,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
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
}

class _JoinSheenPainter extends CustomPainter {
  _JoinSheenPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress < 0.0 || progress > 1.0) return;

    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.35, 0.5, 0.65],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..blendMode = BlendMode.srcATop;

    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(14),
      ));

    canvas.save();
    canvas.clipPath(path);

    final xTranslation = size.width * 2 * progress - size.width;
    canvas.translate(xTranslation, 0);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JoinSheenPainter oldDelegate) =>
      oldDelegate.progress != progress;
}