import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/app_theme.dart';
import '../core/app_router.dart';
import '../core/game_dialog.dart';
import 'free_map_game_screen.dart';

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key, required this.userId});
  final String userId;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  List<_GameEntry> _games = [];
  bool _isLoading = true;
  bool _isCreating = false;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchFocusNode.addListener(_onSearchFocusChange);
    _db.child('active_games').onValue.listen(_onGamesSnapshot);
  }

  void _onSearchFocusChange() {
    setState(() {});
  }

  @override
  void dispose() {
    _searchFocusNode.removeListener(_onSearchFocusChange);
    _searchFocusNode.dispose();
    _searchController.dispose();
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

  Future<void> _createGame({int maxThieves = 5, int durationMinutes = 40}) async {
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
              _buildCreateButton(),
              const SizedBox(height: 15),
              _buildSearchBar(),
              const SizedBox(height: 10),
              _buildActiveGamesLabel(),
              const SizedBox(height: 15),
              Expanded(child: _buildGamesList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: AppTheme.surfaceCardDecoration(),
        child: Column(
          children: [
            RadarScanner(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [AppTheme.accent, AppTheme.secondary],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accent.withValues(alpha: 0.4),
                      blurRadius: 15,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.sports_esports_rounded, size: 36, color: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'GAME LOBBY',
              style: GoogleFonts.bangers(
                fontSize: 34,
                color: Colors.white,
                letterSpacing: 2.5,
                shadows: [
                  Shadow(
                    offset: const Offset(2, 2),
                    blurRadius: 6,
                    color: Colors.black.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose your role and start the chase',
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: Colors.white60,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRoomConfigBottomSheet() {
    int selectedMaxThieves = 5;
    int selectedDurationMinutes = 45;
    bool isCustomDuration = false;
    double customDuration = 45.0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
          child: StatefulBuilder(
            builder: (context, setModalState) {
              return Container(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              decoration: AppTheme.surfaceCardDecoration(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 50,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [AppTheme.danger, AppTheme.warning],
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.local_police_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 15),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CHASE CONFIGURATION',
                            style: GoogleFonts.bangers(
                              fontSize: 24,
                              color: Colors.white,
                              letterSpacing: 1.5,
                            ),
                          ),
                          Text(
                            'Fine-tune the room parameters',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 30),
                  Text(
                    'MAX THIEVES',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.accentSoft,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [3, 5, 8, 10].map((count) {
                      final isSelected = selectedMaxThieves == count;
                      return Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setModalState(() {
                              selectedMaxThieves = count;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              gradient: isSelected
                                  ? const LinearGradient(
                                      colors: [AppTheme.accent, AppTheme.secondary],
                                    )
                                  : null,
                              color: isSelected
                                  ? null
                                  : AppTheme.overlay,
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: isSelected
                                    ? AppTheme.accent
                                    : AppTheme.divider,
                                width: 1.5,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '$count Thieves',
                                style: GoogleFonts.poppins(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? Colors.white : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 25),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'CHASE DURATION',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.accentSoft,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        isCustomDuration
                            ? '${customDuration.toInt()} Mins'
                            : '$selectedDurationMinutes Mins',
                        style: GoogleFonts.spaceMono(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.accentSoft,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [5, 15, 30, 45].map<Widget>((minutes) {
                      final isSelected = !isCustomDuration && selectedDurationMinutes == minutes;
                      return GestureDetector(
                        onTap: () {
                          setModalState(() {
                            isCustomDuration = false;
                            selectedDurationMinutes = minutes;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            gradient: isSelected
                                ? const LinearGradient(
                                    colors: [AppTheme.accentSoft, AppTheme.accent],
                                  )
                                : null,
                            color: isSelected
                                ? null
                                : AppTheme.overlay,
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: isSelected
                                  ? AppTheme.accentSoft
                                  : AppTheme.divider,
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            '$minutes Min',
                            style: GoogleFonts.poppins(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isSelected ? Colors.white : Colors.white70,
                            ),
                          ),
                        ),
                      );
                    }).toList()
                      ..add(
                        GestureDetector(
                          onTap: () {
                            setModalState(() {
                              isCustomDuration = true;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              gradient: isCustomDuration
                                  ? const LinearGradient(
                                      colors: [AppTheme.accentSoft, AppTheme.accent],
                                    )
                                  : null,
                              color: isCustomDuration
                                  ? null
                                  : AppTheme.overlay,
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: isCustomDuration
                                    ? AppTheme.accentSoft
                                    : AppTheme.divider,
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              'Custom ⚙️',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isCustomDuration ? Colors.white : Colors.white70,
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
                      height: isCustomDuration ? null : 0,
                      padding: const EdgeInsets.only(top: 15),
                      child: isCustomDuration
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Drag to select custom time:',
                                      style: GoogleFonts.poppins(
                                        fontSize: 11,
                                        color: Colors.white60,
                                      ),
                                    ),
                                    Text(
                                      '${customDuration.toInt()} Minutes',
                                      style: GoogleFonts.spaceMono(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    activeTrackColor: AppTheme.accent,
                                    inactiveTrackColor: AppTheme.overlay,
                                    thumbColor: Colors.white,
                                    overlayColor: AppTheme.accent.withValues(alpha: 0.2),
                                    valueIndicatorColor: AppTheme.accent,
                                    valueIndicatorTextStyle: GoogleFonts.spaceMono(color: AppTheme.primary),
                                  ),
                                  child: Slider(
                                    value: customDuration,
                                    min: 1,
                                    max: 120,
                                    divisions: 119,
                                    label: '${customDuration.toInt()} Min',
                                    onChanged: (value) {
                                      setModalState(() {
                                        customDuration = value;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(height: 35),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      final duration = isCustomDuration
                          ? customDuration.toInt()
                          : selectedDurationMinutes;
                      _createGame(
                        maxThieves: selectedMaxThieves,
                        durationMinutes: duration,
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      elevation: 8,
                      shadowColor: AppTheme.shadow,
                    ),
                    child: Ink(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppTheme.accentSoft, AppTheme.accent],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Container(
                        height: 65,
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.flash_on_rounded, size: 28, color: Colors.white),
                            const SizedBox(width: 10),
                            Text(
                              'LAUNCH CHASE ⚡',
                              style: GoogleFonts.bangers(
                                fontSize: 22,
                                color: Colors.white,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
  }

  Widget _buildCreateButton() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ShinyGlazeButton(
        child: ElevatedButton(
          onPressed: _isCreating ? null : _showRoomConfigBottomSheet,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accent,
            disabledBackgroundColor: AppTheme.surface.withValues(alpha: 0.85),
            minimumSize: const Size(double.infinity, 70),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            elevation: 0,
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _isCreating
                ? const SizedBox(
                    key: ValueKey('loading'),
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    key: const ValueKey('label'),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.local_police, size: 30, color: Colors.white),
                      const SizedBox(width: 15),
                      Text(
                        'CREATE GAME AS POLICE',
                        style: GoogleFonts.bangers(
                          fontSize: 22,
                          color: Colors.white,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
          ),
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
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.05),
                Colors.white.withValues(alpha: 0.02),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 15,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            leading: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.blue.shade500, Colors.purple.shade500],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withValues(alpha: 0.3),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: const Icon(Icons.sports_esports_rounded, color: Colors.white, size: 28),
            ),
            title: Text(
              'ROOM ${widget.game.id}',
              style: GoogleFonts.spaceMono(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 2.0,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(Icons.people_alt_rounded, size: 15, color: Colors.white38),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.game.thiefCount}/${widget.game.maxThieves} thieves',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isCreator) ...[
                    const SizedBox(width: 12),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.blue.shade500, Colors.indigo.shade600],
                        ),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withValues(alpha: 0.3),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: Text(
                        'HOST',
                        style: GoogleFonts.poppins(
                          fontSize: 9,
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
                      color: Colors.redAccent,
                      size: 24,
                    ),
                    tooltip: 'Delete Game',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
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