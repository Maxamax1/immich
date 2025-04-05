import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Provider to indicate if the application is currently in a locked grid view state.
/// When true, the main UI (AppBar, BottomNav, etc.) should be hidden,
/// and the asset grid should only show the locked assets.
final lockedViewProvider = StateProvider<bool>((ref) => false);
