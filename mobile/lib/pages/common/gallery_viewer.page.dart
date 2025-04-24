import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart'; // Import for translations
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/scroll_extensions.dart';
import 'package:immich_mobile/pages/common/download_panel.dart';
import 'package:immich_mobile/pages/common/native_video_viewer.page.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/current_asset.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/show_controls.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_value_provider.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart';
import 'package:immich_mobile/widgets/asset_grid/selected_assets_render_list.dart'; // Import SelectedAssetsRenderList
import 'package:immich_mobile/widgets/asset_viewer/advanced_bottom_sheet.dart';
import 'package:immich_mobile/widgets/asset_viewer/bottom_gallery_bar.dart';
import 'package:immich_mobile/widgets/asset_viewer/detail_panel/detail_panel.dart';
import 'package:immich_mobile/widgets/asset_viewer/gallery_app_bar.dart';
import 'package:immich_mobile/widgets/common/immich_image.dart';
import 'package:immich_mobile/widgets/common/immich_thumbnail.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view_gallery.dart';
import 'package:immich_mobile/widgets/photo_view/src/photo_view_computed_scale.dart';
import 'package:immich_mobile/widgets/photo_view/src/photo_view_scale_state.dart';
import 'package:immich_mobile/widgets/photo_view/src/utils/photo_view_hero_attributes.dart';
import 'package:local_auth/local_auth.dart'; // Import local_auth
import 'package:logging/logging.dart'; // Import logging
import 'package:immich_mobile/providers/locked_view_provider.dart'; // Import locked view provider

final log = Logger('GalleryViewerPage'); // Logger instance

// Helper widget definition (Top Level)
class _ConditionalBottomBar extends StatelessWidget {
  const _ConditionalBottomBar({
    required this.renderList,
    required this.totalAssets,
    required this.controller,
    required this.showStack,
    required this.stackIndex,
    required this.assetIndex,
    required this.isLocked,
    required this.showControls,
  });

  final RenderList renderList;
  final ValueNotifier<int> totalAssets;
  final PageController controller;
  final bool showStack;
  final ValueNotifier<int> stackIndex;
  final ValueNotifier<int> assetIndex;
  final bool isLocked;
  final bool showControls;

  @override
  Widget build(BuildContext context) {
    final isSelectionMode = renderList is SelectedAssetsRenderList;
    // final bool shouldBeVisible = isSelectionMode || showControls; // Removed unused variable
    // Ignore interaction ONLY if locked AND NOT in selection mode.
    final bool ignoreInteraction = isLocked && !isSelectionMode;

    // Opacity is now handled by the parent widget
    return IgnorePointer(
      ignoring: ignoreInteraction,
      child: BottomGalleryBar(
        renderList: renderList,
        totalAssets: totalAssets,
        controller: controller,
        showStack: showStack,
        stackIndex: stackIndex,
        assetIndex: assetIndex,
        isLocked: isLocked,
        isSelectionMode: isSelectionMode,
      ),
    );
  }
}

@RoutePage()
// ignore: must_be_immutable
class GalleryViewerPage extends HookConsumerWidget {
  final int initialIndex;
  final int heroOffset;
  final bool showStack;
  final RenderList renderList;
  final bool startLocked;

  GalleryViewerPage({
    super.key,
    required this.renderList,
    this.initialIndex = 0,
    this.heroOffset = 0,
    this.showStack = false,
    this.startLocked = false,
  }) : controller = PageController(initialPage: initialIndex);

  final PageController controller;

  @pragma('vm:prefer-inline')
  PhotoViewHeroAttributes _getHeroAttributes(Asset asset) {
    return PhotoViewHeroAttributes(
      tag: asset.isInDb
          ? asset.id + heroOffset
          : '${asset.remoteId}-$heroOffset',
      transitionOnUserGestures: true,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localAuth = useMemoized(() => LocalAuthentication());
    final totalAssets = useState(renderList.totalAssets);
    final isZoomed = useState(false);
    final isLocked = useState(startLocked);
    final stackIndex = useState(0);
    final localPosition = useRef<Offset?>(null);
    final currentIndex = useValueNotifier(initialIndex);
    final loadAsset = renderList.loadAsset;
    final isPlayingMotionVideo = ref.watch(isPlayingMotionVideoProvider);
    final isSelectionMode = renderList is SelectedAssetsRenderList;
    final currentAsset = ref.watch(currentAssetProvider);

    // --- Function Definitions ---
    Future<void> precacheNextImage(int index) async {
      if (!context.mounted) return;
      void onError(Object e, StackTrace? s) {
        log.severe('Error precaching image: $e, $s');
      }

      try {
        if (index < totalAssets.value && index >= 0) {
          final asset = loadAsset(index);
          await precacheImage(
            ImmichImage.imageProvider(
              asset: asset,
              width: context.width,
              height: context.height,
            ),
            context,
            onError: onError,
          );
        }
      } catch (e) {
        log.severe('Error precaching image: $e');
        context.maybePop();
      }
    }

    Future<void> toggleLockMode() async {
      final showControlsNotifier = ref.read(showControlsProvider.notifier);
      if (!isLocked.value) {
        isLocked.value = true;
        showControlsNotifier.show = false;
      } else {
        final isBiometricSupported = await localAuth.isDeviceSupported();
        final canCheckBiometrics = await localAuth.canCheckBiometrics;
        if (isBiometricSupported && canCheckBiometrics) {
          try {
            final bool didAuthenticate = await localAuth.authenticate(
              localizedReason: 'gallery_viewer_authenticate_to_unlock'.tr(),
              options: const AuthenticationOptions(
                biometricOnly: true,
                stickyAuth: true,
              ),
            );
            if (didAuthenticate) {
              isLocked.value = false;
              showControlsNotifier.show = true;
              // If the page was started locked, update the global provider too
              if (startLocked) {
                ref.read(lockedViewProvider.notifier).state = false;
              }
            }
          } on PlatformException catch (e) {
            log.severe("Biometric auth error: $e");
            var errorMsg = "Biometric authentication error: ${e.code}";
            if (e.code == 'NotEnrolled') {
              errorMsg = "Biometrics not enrolled on this device.";
            } else if (e.code == 'NotAvailable') {
              errorMsg = "Biometrics not available on this device.";
            }
            log.warning("Cannot unlock via biometrics: $errorMsg");
          }
        } else {
          log.warning("Biometrics not supported/available.");
        }
      }
    }

    void showInfo() {
      final asset = ref.read(currentAssetProvider);
      if (asset == null) return;
      showModalBottomSheet(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(15.0)),
        ),
        barrierColor: Colors.transparent,
        isScrollControlled: true,
        showDragHandle: true,
        enableDrag: true,
        context: context,
        useSafeArea: true,
        builder: (context) {
          return DraggableScrollableSheet(
            minChildSize: 0.5,
            maxChildSize: 1,
            initialChildSize: 0.75,
            expand: false,
            builder: (context, scrollController) {
              return Padding(
                padding: EdgeInsets.only(bottom: context.viewInsets.bottom),
                child: ref.watch(appSettingsServiceProvider).getSetting<bool>(
                          AppSettingsEnum.advancedTroubleshooting,
                        )
                    ? AdvancedBottomSheet(
                        assetDetail: asset,
                        scrollController: scrollController,
                      )
                    : DetailPanel(
                        asset: asset,
                        scrollController: scrollController,
                      ),
              );
            },
          );
        },
      );
    }

    void handleSwipeUpDown(DragUpdateDetails details) {
      const int sensitivity = 15;
      const int dxThreshold = 50;
      const double ratioThreshold = 3.0;
      if (isZoomed.value) return; // Allow swipe down even when locked
      if (localPosition.value == null) return;
      final d = details.localPosition - localPosition.value!;
      if (d.dx.abs() > dxThreshold) return;
      final ratio = d.dy / max(d.dx.abs(), 1);
      if (d.dy > sensitivity && ratio > ratioThreshold) {
        context.maybePop();
      } else if (d.dy < -sensitivity &&
          ratio < -ratioThreshold &&
          !isLocked.value) {
        // Add !isLocked check
        showInfo();
      }
    }

    PhotoViewGalleryPageOptions buildImage(BuildContext context, Asset asset) {
      return PhotoViewGalleryPageOptions(
        onDragStart: (_, details, __) {
          localPosition.value = details.localPosition;
        },
        onDragUpdate: (_, details, __) {
          handleSwipeUpDown(details);
        },
        onTapDown: (_, __, ___) {
          // Allow toggling controls even when locked
          ref.read(showControlsProvider.notifier).toggle();
        },
        onLongPressStart: asset.isMotionPhoto
            ? (_, __, ___) {
                ref.read(isPlayingMotionVideoProvider.notifier).playing = true;
              }
            : null,
        imageProvider: ImmichImage.imageProvider(asset: asset),
        heroAttributes: _getHeroAttributes(asset),
        filterQuality: FilterQuality.high,
        tightMode: true,
        minScale: PhotoViewComputedScale.contained,
        errorBuilder: (context, error, stackTrace) =>
            ImmichImage(asset, fit: BoxFit.contain),
      );
    }

    PhotoViewGalleryPageOptions buildVideo(BuildContext context, Asset asset) {
      // Revert: Remove useMemoized call from buildVideo
      // Directly create and return the PageOptions
      return PhotoViewGalleryPageOptions.customChild(
        onDragStart: (_, details, __) =>
            localPosition.value = details.localPosition,
        onDragUpdate: (_, details, __) => handleSwipeUpDown(details),
        onTapDown: (_, __, ___) {
          // Keep tap handler for unlocked videos
          // Allow toggling controls even when locked
          ref.read(showControlsProvider.notifier).toggle();
        },
        heroAttributes: _getHeroAttributes(asset),
        filterQuality: FilterQuality.high,
        initialScale: PhotoViewComputedScale.contained,
        minScale: PhotoViewComputedScale.contained * 0.8,
        maxScale: PhotoViewComputedScale.covered * 2.5,
        basePosition: Alignment.center,
        // Remove IgnorePointer from here, it's now handled inside NativeVideoViewerPage
        child: SizedBox(
          // Keep SizedBox wrapper if needed for layout
          width: context.width,
          height: context.height,
          child: NativeVideoViewerPage(
            // Use stable key for the viewer page itself if needed,
            // relying on the inner NativeVideoPlayerView's key primarily.
            key: ValueKey("native_viewer_${asset.id}"),
            asset: asset,
            isLocked: isLocked.value, // Pass the locked state down
            image: Image(
              key: ValueKey(
                "placeholder_${asset.id}",
              ), // Use stable asset ID for image key
              image: ImmichImage.imageProvider(
                asset: asset,
                width: context.width,
                height: context.height,
              ),
              fit: BoxFit.contain,
              height: context.height,
              width: context.width,
              alignment: Alignment.center,
            ),
          ),
        ),
      );
    }

    PhotoViewGalleryPageOptions buildAsset(BuildContext context, int index) {
      var newAsset = loadAsset(index); // Revert variable name
      final stackId = newAsset.stackId;
      if (stackId != null && currentIndex.value == index) {
        final stackElements =
            ref.read(assetStackStateProvider(newAsset.stackId!));
        if (stackIndex.value < stackElements.length) {
          newAsset = stackElements.elementAt(stackIndex.value);
        }
      }
      // Directly call buildImage or buildVideo without memoizing the PageOptions here
      if (newAsset.isImage && !isPlayingMotionVideo) {
        return buildImage(context, newAsset);
      }
      return buildVideo(context, newAsset);
    }
    // --- End of Function Definitions ---

    useEffect(
      () {
        // System UI mode should only depend on showControlsProvider
        final show = ref.read(showControlsProvider);
        if (show || Platform.isIOS) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        } else {
          // Use a timer to avoid flicker when controls hide quickly
          Timer(const Duration(milliseconds: 100), () {
            // Check again in case state changed during timer
            if (!ref.read(showControlsProvider)) {
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
            }
          });
        }
        return null;
      },
      [isLocked.value, ref.watch(showControlsProvider)],
    );

    useEffect(
      () {
        Timer(const Duration(milliseconds: 400), () {
          precacheNextImage(currentIndex.value + 1);
        });
        return null;
      },
      [],
    );

    // Control visibility depends only on the provider now
    final bool showMainControls = ref.watch(showControlsProvider);

    Widget buildMainContent() {
      // Always use PhotoViewGallery.builder
      return PhotoViewGallery.builder(
        key: const ValueKey('gallery'),
        scaleStateChangedCallback: (state) {
          // Use currentAsset directly if available, otherwise load
          final asset = currentAsset ?? loadAsset(currentIndex.value);
          if (asset.isImage && !ref.read(isPlayingMotionVideoProvider)) {
            isZoomed.value = state != PhotoViewScaleState.initial;
            if (!isLocked.value) {
              ref.read(showControlsProvider.notifier).show = !isZoomed.value;
            }
          }
        },
        gaplessPlayback: true,
        allowImplicitScrolling:
            true, // Consider if needed with FastScrollPhysics
        loadingBuilder: (context, event, index) {
          final asset = loadAsset(index);
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10)),
                ImmichThumbnail(
                  key: ValueKey(asset),
                  asset: asset,
                  fit: BoxFit.contain,
                ),
              ],
            ),
          );
        },
        pageController: controller,
        // Disable horizontal scrolling if zoomed OR (locked AND not in selection mode)
        scrollPhysics: isZoomed.value || (isLocked.value && !isSelectionMode)
            ? const NeverScrollableScrollPhysics()
            : (Platform.isIOS
                ? const FastScrollPhysics()
                : const FastClampingScrollPhysics()),
        itemCount: totalAssets.value,
        scrollDirection: Axis.horizontal,
        onPageChanged: (value) {
          final next = currentIndex.value < value ? value + 1 : value - 1;
          ref.read(hapticFeedbackProvider.notifier).selectionClick();
          final newAsset = loadAsset(value);
          currentIndex.value = value;
          stackIndex.value = 0;
          ref.read(currentAssetProvider.notifier).set(newAsset);
          if (newAsset.isVideo || newAsset.isMotionPhoto) {
            ref.read(videoPlaybackValueProvider.notifier).reset();
          }
          Timer(const Duration(milliseconds: 400), () {
            precacheNextImage(next);
          });
        },
        builder: buildAsset,
      );
    }

    return PopScope(
      // Allow popping if not locked OR if started locked (returning to locked grid)
      canPop: !isLocked.value || startLocked,
      onPopInvoked: (didPop) async {
        if (didPop) {
          // If pop succeeded (was allowed), reset UI mode
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        } else {
          // Pop was prevented (must be locked AND lock initiated here)
          // Trigger authentication to unlock
          await toggleLockMode();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            buildMainContent(), // Use the conditional builder
            // Top controls (AppBar) - Conditionally visible
            Positioned(
              // Positioned is now the direct child of Stack
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: showMainControls ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !showMainControls,
                  child: GalleryAppBar(
                    key: const ValueKey('app-bar'),
                    showInfo: showInfo,
                    isLocked: isLocked.value,
                    onToggleLock: toggleLockMode,
                  ),
                ),
              ),
            ),
            // Bottom controls - Always render, let _ConditionalBottomBar handle visibility/interaction
            Positioned(
              bottom: 0, // Keep anchored to bottom edge
              left: 0,
              right: 0,
              // Apply AnimatedOpacity here, around the AnimatedPadding
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: showMainControls ? 1.0 : 0.0,
                // Replace Padding with AnimatedPadding
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 150),
                  // Animate padding based on showMainControls
                  padding: EdgeInsets.only(
                    bottom: showMainControls
                        ? MediaQuery.of(context).padding.bottom
                        : 0,
                  ),
                  child: _ConditionalBottomBar(
                    renderList: renderList,
                    totalAssets: totalAssets,
                    controller: controller,
                    showStack: showStack,
                    stackIndex: stackIndex,
                    assetIndex: currentIndex,
                    isLocked: isLocked.value,
                    showControls: showMainControls,
                  ),
                ),
              ),
            ),
            const DownloadPanel(),
          ],
        ),
      ),
    );
  }
}
