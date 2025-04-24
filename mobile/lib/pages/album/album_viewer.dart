import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For PlatformException
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:local_auth/local_auth.dart'; // For LocalAuthentication
import 'package:logging/logging.dart'; // For Logger
import 'package:immich_mobile/models/albums/asset_selection_page_result.model.dart';
import 'package:immich_mobile/pages/album/album_control_button.dart';
import 'package:immich_mobile/pages/album/album_date_range.dart';
import 'package:immich_mobile/pages/album/album_shared_user_icons.dart';
import 'package:immich_mobile/pages/album/album_title.dart';
import 'package:immich_mobile/providers/album/album.provider.dart';
import 'package:immich_mobile/providers/album/current_album.provider.dart';
import 'package:immich_mobile/providers/timeline.provider.dart';
import 'package:immich_mobile/utils/immich_loading_overlay.dart';
import 'package:immich_mobile/providers/multiselect.provider.dart';
import 'package:immich_mobile/providers/locked_view_provider.dart'; // Import locked view provider
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/widgets/album/album_viewer_appbar.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart'; // Import RenderList
import 'package:immich_mobile/widgets/asset_grid/multiselect_grid.dart';
import 'package:immich_mobile/widgets/asset_grid/selected_assets_render_list.dart'; // Import SelectedAssetsRenderList
import 'package:immich_mobile/widgets/common/immich_toast.dart';

final _log = Logger('AlbumViewer'); // Logger instance

// REMOVED @RoutePage annotation
class AlbumViewer extends HookConsumerWidget {
  // CORRECT class name
  const AlbumViewer({super.key}); // CORRECT class name

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(currentAlbumProvider);
    if (album == null) {
      // Return SizedBox for consistency
      return const SizedBox();
    }

    final titleFocusNode = useFocusNode();
    final userId = ref.watch(authProvider).userId;
    final isMultiselecting = ref.watch(multiselectProvider);
    final isLockedView =
        ref.watch(lockedViewProvider); // Watch global lock state
    final isProcessing = useProcessingOverlay();
    final localAuth = useMemoized(() => LocalAuthentication());
    final externalLockedListNotifier =
        useState<RenderList?>(null); // Notifier for album presentation lock

    Future<bool> onRemoveFromAlbumPressed(Iterable<Asset> assets) async {
      final bool isSuccess =
          await ref.read(albumProvider.notifier).removeAsset(album, assets);

      if (!isSuccess && context.mounted) {
        ImmichToast.show(
          context: context,
          msg: "album_viewer_appbar_share_err_remove".tr(),
          toastType: ToastType.error,
          gravity: ToastGravity.BOTTOM,
        );
      }
      return isSuccess;
    }

    void onAddPhotosPressed() async {
      if (!context.mounted) return;
      AssetSelectionPageResult? returnPayload =
          await context.pushRoute<AssetSelectionPageResult?>(
        AlbumAssetSelectionRoute(
          existingAssets: album.assets,
          canDeselect: false,
        ),
      );

      if (returnPayload != null && returnPayload.selectedAssets.isNotEmpty) {
        isProcessing.value = true;
        await ref
            .watch(albumProvider.notifier)
            .addAssets(album, returnPayload.selectedAssets);
        isProcessing.value = false;
      }
    }

    void onAddUsersPressed() async {
      if (!context.mounted) return;
      List<String>? sharedUserIds = await context.pushRoute<List<String>?>(
        AlbumAdditionalSharedUserSelectionRoute(album: album),
      );

      if (sharedUserIds != null) {
        isProcessing.value = true;
        await ref.watch(albumProvider.notifier).addUsers(album, sharedUserIds);
        isProcessing.value = false;
      }
    }

    onActivitiesPressed() {
      if (album.remoteId != null) {
        if (!context.mounted) return;
        context.pushRoute(
          const ActivitiesRoute(),
        );
      }
    }

    // Function to enter album presentation lock mode (REVISED)
    void onEnterLockedView() async {
      try {
        isProcessing.value = true;
        _log.info(
          "Attempting to enter locked view for album ${album.id}. Awaiting timeline provider...",
        );

        // 1. Await the future to ensure the provider has resolved at least once
        await ref.read(albumTimelineProvider(album.id).future);
        _log.info("Timeline provider future completed for album ${album.id}.");

        // 2. After awaiting, re-read the current state to get the actual data
        final asyncValue = ref.read(albumTimelineProvider(album.id));
        final currentAlbumTimeline = asyncValue.valueOrNull;
        _log.info(
          "Re-read timeline provider state. Value is null: ${currentAlbumTimeline == null}",
        );

        // 3. Check if data is actually available after awaiting
        if (currentAlbumTimeline == null) {
          _log.warning(
            "Cannot enter locked view: Album timeline data still not available after await.",
          );
          if (context.mounted) {
            ImmichToast.show(
              context: context,
              msg:
                  "Error loading album data. Please try again.", // TODO: Add translation
              toastType: ToastType.error,
            );
          }
          return;
        }

        // 4. Safely load all assets using the RenderList's method
        final allAlbumAssets = currentAlbumTimeline.loadAssets(
          0,
          currentAlbumTimeline.totalAssets,
        );
        _log.info(
          "Loaded allAlbumAssets for album ${album.id} using loadAssets. Length: ${allAlbumAssets.length}",
        );

        // 5. Check if assets are empty
        if (allAlbumAssets.isEmpty) {
          _log.warning("allAlbumAssets is null or empty, showing toast.");
          if (!context.mounted) return;
          ImmichToast.show(
            context: context,
            msg: "album_viewer_lock_empty".tr(), // Use the same translation key
            toastType: ToastType.info,
          );
          return; // Exit if no assets
        }

        // 6. Create a RenderList containing the fetched assets
        final lockedList = SelectedAssetsRenderList(
          allAlbumAssets,
        ); // Use ! as null check passed
        _log.info(
          "Created SelectedAssetsRenderList with ${allAlbumAssets.length} assets.",
        );

        // 7. Set the external notifier *with the populated list*
        externalLockedListNotifier.value = lockedList;
        _log.info("Set externalLockedListNotifier with the populated list.");

        // 8. Activate the global lock AFTER setting the notifier value
        ref.read(lockedViewProvider.notifier).state = true;
        _log.info("Activated global lock. Entering locked presentation mode.");
      } catch (e, s) {
        _log.severe(
          "Error entering locked view for album ${album.id}: $e",
          e,
          s,
        );
        if (context.mounted) {
          ImmichToast.show(
            context: context,
            msg: "Error preparing locked view.", // TODO: Add translation
            toastType: ToastType.error,
          );
        }
      } finally {
        isProcessing.value = false;
      }
    }

    // Function to handle unlocking the MULTI-SELECT locked view OR the album presentation lock
    Future<void> attemptUnlockMultiselect() async {
      final lockedViewNotifier = ref.read(lockedViewProvider.notifier);
      if (!lockedViewNotifier.state) return; // Already unlocked

      final isBiometricSupported = await localAuth.isDeviceSupported();
      final canCheckBiometrics = await localAuth.canCheckBiometrics;

      if (isBiometricSupported && canCheckBiometrics) {
        try {
          final bool didAuthenticate = await localAuth.authenticate(
            localizedReason: 'gallery_viewer_authenticate_to_unlock'
                .tr(), // Re-use translation
            options: const AuthenticationOptions(
              biometricOnly: true,
              stickyAuth: true,
            ),
          );
          if (didAuthenticate) {
            // Only need to update the global state here
            lockedViewNotifier.state = false;
            externalLockedListNotifier.value =
                null; // Also clear the external list on unlock
          }
        } on PlatformException catch (e) {
          _log.severe("Biometric auth error (unlock): $e");
          // Handle error appropriately, maybe show a toast
        }
      } else {
        _log.warning("Biometrics not supported/available (unlock).");
        // Handle case where biometrics aren't available - maybe show a message?
        // For now, unlock without auth if biometrics unavailable
        log.warning("Unlocking view without auth (biometrics unavailable).");
        lockedViewNotifier.state = false;
        externalLockedListNotifier.value = null;
      }
    }

    return PopScope(
      canPop: !isLockedView, // Prevent back if global lock is active
      onPopInvoked: (didPop) {
        if (!didPop) {
          // Pop was prevented because view is locked
          attemptUnlockMultiselect(); // Use the unified unlock
        }
      },
      child: Scaffold(
        // Add Scaffold wrapper
        body: Stack(
          children: [
            MultiselectGrid(
              key: const ValueKey("albumViewerMultiselectGrid"),
              renderListProvider: albumTimelineProvider(album.id),
              externalLockedListNotifier:
                  externalLockedListNotifier, // Pass the notifier
              topWidget: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AlbumTitle(
                    key: const ValueKey("albumTitle"),
                    titleFocusNode: titleFocusNode,
                  ),
                  const AlbumDateRange(),
                  const AlbumSharedUserIcons(),
                  if (album.isRemote)
                    AlbumControlButton(
                      key: const ValueKey("albumControlButton"),
                      onAddPhotosPressed: onAddPhotosPressed,
                      onAddUsersPressed: onAddUsersPressed,
                    ),
                ],
              ),
              onRemoveFromAlbum: onRemoveFromAlbumPressed,
              editEnabled: album.ownerId == userId,
            ),
            AnimatedPositioned(
              key: const ValueKey("albumViewerAppbarPositioned"),
              duration: const Duration(milliseconds: 300),
              // Hide AppBar if multiselect is active OR locked view is active
              top: (isMultiselecting || isLockedView)
                  ? -(kToolbarHeight + context.padding.top)
                  : 0,
              left: 0,
              right: 0,
              child: AlbumViewerAppbar(
                key: const ValueKey("albumViewerAppbar"),
                titleFocusNode: titleFocusNode,
                userId: userId,
                onAddPhotos: onAddPhotosPressed,
                onAddUsers: onAddUsersPressed,
                onActivities: onActivitiesPressed,
                isLockedView: isLockedView, // Pass global lock state
                onAttemptUnlock:
                    attemptUnlockMultiselect, // Pass unlock function
                onEnterLockedView:
                    onEnterLockedView, // Pass album lock function
              ),
            ),
            // Add transparent back button when locked (inside children list)
            if (isLockedView)
              Positioned(
                top: context.padding.top,
                left: 8,
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                  ),
                  onPressed: attemptUnlockMultiselect, // Use unified unlock
                  tooltip: 'gallery_viewer_authenticate_to_unlock'.tr(),
                  splashRadius: 25,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
