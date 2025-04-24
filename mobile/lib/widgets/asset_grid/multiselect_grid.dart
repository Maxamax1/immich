import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Added for PlatformException
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/collection_extensions.dart';
import 'package:immich_mobile/providers/locked_view_provider.dart'; // Added
import 'package:local_auth/local_auth.dart'; // Added
import 'package:logging/logging.dart'; // Added
import 'package:immich_mobile/providers/album/album.provider.dart';
import 'package:immich_mobile/services/album.service.dart';
import 'package:immich_mobile/services/stack.service.dart';
import 'package:immich_mobile/providers/backup/manual_upload.provider.dart';
import 'package:immich_mobile/models/asset_selection_state.dart';
import 'package:immich_mobile/providers/multiselect.provider.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart';
import 'package:immich_mobile/widgets/asset_grid/immich_asset_grid.dart';
import 'package:immich_mobile/widgets/asset_grid/control_bottom_app_bar.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/entities/album.entity.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/providers/asset.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/utils/immich_loading_overlay.dart';
import 'package:immich_mobile/utils/selection_handlers.dart';
import 'package:immich_mobile/widgets/asset_grid/selected_assets_render_list.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart'; // Added for color scheme

class MultiselectGrid extends HookConsumerWidget {
  MultiselectGrid({
    super.key,
    required this.renderListProvider,
    this.onRefresh,
    this.buildLoadingIndicator,
    this.onRemoveFromAlbum,
    this.topWidget,
    this.stackEnabled = false,
    this.dragScrollLabelEnabled = true,
    this.archiveEnabled = false,
    this.deleteEnabled = true,
    this.favoriteEnabled = true,
    this.editEnabled = false,
    this.unarchive = false,
    this.unfavorite = false,
    this.emptyIndicator,
    this.externalLockedListNotifier, // Add notifier for external lock trigger
  });

  final ProviderListenable<AsyncValue<RenderList>> renderListProvider;
  final Future<void> Function()? onRefresh;
  final Widget Function()? buildLoadingIndicator;
  final Future<bool> Function(Iterable<Asset>)? onRemoveFromAlbum;
  final Widget? topWidget;
  final bool stackEnabled;
  final bool dragScrollLabelEnabled;
  final bool archiveEnabled;
  final bool unarchive;
  final bool deleteEnabled;
  final bool favoriteEnabled;
  final bool unfavorite;
  final bool editEnabled;
  final Widget? emptyIndicator;
  final ValueNotifier<RenderList?>? externalLockedListNotifier; // Add field

  Widget buildDefaultLoadingIndicator() =>
      const Center(child: CircularProgressIndicator());

  Widget buildEmptyIndicator() =>
      emptyIndicator ?? Center(child: const Text("no_assets_to_show").tr());

  final log = Logger('MultiselectGrid');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final multiselectEnabled = ref.watch(multiselectProvider.notifier);
    final selectionEnabledHook = useState(false);
    final selectionAssetState = useState(const AssetSelectionState());
    final isLockedView = ref.watch(lockedViewProvider);
    final lockedRenderListState =
        useState<RenderList?>(null); // Internal state for multi-select lock
    final localAuth = useMemoized(() => LocalAuthentication());

    final selection = useState(<Asset>{});
    final currentUser = ref.watch(currentUserProvider);
    final processing = useProcessingOverlay();

    log.fine(
      "--- Build Start --- isLockedView: $isLockedView, internalLockedListState is null: ${lockedRenderListState.value == null}, externalLockedListNotifier is null: ${externalLockedListNotifier == null}",
    );

    useEffect(
      () {
        selectionEnabledHook.addListener(() {
          multiselectEnabled.state = selectionEnabledHook.value;
        });
        return () {
          if (kReleaseMode) {
            selectionEnabledHook.dispose();
          }
        };
      },
      [],
    );

    void selectionListener(
      bool multiselect,
      Set<Asset> selectedAssets,
    ) {
      selectionEnabledHook.value = multiselect;
      selection.value = selectedAssets;
      selectionAssetState.value =
          AssetSelectionState.fromSelection(selectedAssets);
    }

    errorBuilder(String? msg) => msg != null && msg.isNotEmpty
        ? () => ImmichToast.show(
              context: context,
              msg: msg,
              gravity: ToastGravity.BOTTOM,
            )
        : null;

    Iterable<Asset> ownedRemoteSelection({
      String? localErrorMessage,
      String? ownerErrorMessage,
    }) {
      final assets = selection.value;
      return assets
          .remoteOnly(errorCallback: errorBuilder(localErrorMessage))
          .ownedOnly(
            currentUser,
            errorCallback: errorBuilder(ownerErrorMessage),
          );
    }

    Iterable<Asset> remoteSelection({String? errorMessage}) =>
        selection.value.remoteOnly(
          errorCallback: errorBuilder(errorMessage),
        );

    void onShareAssets(bool shareLocal) {
      processing.value = true;
      if (shareLocal) {
        handleShareAssets(ref, context, selection.value);
      } else {
        final ids =
            remoteSelection(errorMessage: "home_page_share_err_local".tr())
                .map((e) => e.remoteId!);
        context.pushRoute(SharedLinkEditRoute(assetsList: ids.toList()));
      }
      processing.value = false;
      selectionEnabledHook.value = false;
    }

    void onFavoriteAssets() async {
      processing.value = true;
      try {
        final remoteAssets = ownedRemoteSelection(
          localErrorMessage: 'home_page_favorite_err_local'.tr(),
          ownerErrorMessage: 'home_page_favorite_err_partner'.tr(),
        );
        if (remoteAssets.isNotEmpty) {
          await handleFavoriteAssets(ref, context, remoteAssets.toList());
        }
      } finally {
        processing.value = false;
        selectionEnabledHook.value = false;
      }
    }

    void onArchiveAsset() async {
      processing.value = true;
      try {
        final remoteAssets = ownedRemoteSelection(
          localErrorMessage: 'home_page_archive_err_local'.tr(),
          ownerErrorMessage: 'home_page_archive_err_partner'.tr(),
        );
        await handleArchiveAssets(ref, context, remoteAssets.toList());
      } finally {
        processing.value = false;
        selectionEnabledHook.value = false;
      }
    }

    void onDelete([bool force = false]) async {
      processing.value = true;
      try {
        final toDelete = selection.value
            .ownedOnly(
              currentUser,
              errorCallback: errorBuilder('home_page_delete_err_partner'.tr()),
            )
            .toList();
        final isDeleted = await ref
            .read(assetProvider.notifier)
            .deleteAssets(toDelete, force: force);

        if (isDeleted) {
          ImmichToast.show(
            context: context,
            msg: force
                ? 'assets_deleted_permanently'
                    .tr(args: ["${selection.value.length}"])
                : 'assets_trashed'.tr(args: ["${selection.value.length}"]),
            gravity: ToastGravity.BOTTOM,
          );
          selectionEnabledHook.value = false;
        }
      } finally {
        processing.value = false;
      }
    }

    void onDeleteLocal(bool isMergedAsset) async {
      processing.value = true;
      try {
        final localAssets = selection.value.where((a) => a.isLocal).toList();
        final toDelete = isMergedAsset
            ? localAssets.where((e) => e.storage == AssetState.merged)
            : localAssets;
        if (toDelete.isEmpty) return;
        final isDeleted = await ref
            .read(assetProvider.notifier)
            .deleteLocalAssets(toDelete.toList());
        if (isDeleted) {
          final deletedCount =
              localAssets.where((e) => !isMergedAsset || e.isRemote).length;
          ImmichToast.show(
            context: context,
            msg: 'assets_removed_permanently_from_device'
                .tr(args: ["$deletedCount"]),
            gravity: ToastGravity.BOTTOM,
          );
          selectionEnabledHook.value = false;
        }
      } finally {
        processing.value = false;
      }
    }

    void onDeleteRemote([bool shouldDeletePermanently = false]) async {
      processing.value = true;
      try {
        final toDelete = ownedRemoteSelection(
          localErrorMessage: 'home_page_delete_remote_err_local'.tr(),
          ownerErrorMessage: 'home_page_delete_err_partner'.tr(),
        ).toList();
        final isDeleted =
            await ref.read(assetProvider.notifier).deleteRemoteAssets(
                  toDelete,
                  shouldDeletePermanently: shouldDeletePermanently,
                );
        if (isDeleted) {
          ImmichToast.show(
            context: context,
            msg: shouldDeletePermanently
                ? 'assets_deleted_permanently_from_server'
                    .tr(args: ["${toDelete.length}"])
                : 'assets_trashed_from_server'.tr(args: ["${toDelete.length}"]),
            gravity: ToastGravity.BOTTOM,
          );
        }
      } finally {
        selectionEnabledHook.value = false;
        processing.value = false;
      }
    }

    void onUpload() {
      processing.value = true;
      selectionEnabledHook.value = false;
      try {
        ref.read(manualUploadProvider.notifier).uploadAssets(
              context,
              selection.value.where((a) => a.storage == AssetState.local),
            );
      } finally {
        processing.value = false;
      }
    }

    void onAddToAlbum(Album album) async {
      processing.value = true;
      try {
        final Iterable<Asset> assets = remoteSelection(
          errorMessage: "home_page_add_to_album_err_local".tr(),
        );
        if (assets.isEmpty) return;
        final result =
            await ref.read(albumServiceProvider).addAssets(album, assets);
        if (result != null) {
          if (result.alreadyInAlbum.isNotEmpty) {
            ImmichToast.show(
              context: context,
              msg: "home_page_add_to_album_conflicts".tr(
                namedArgs: {
                  "album": album.name,
                  "added": result.successfullyAdded.toString(),
                  "failed": result.alreadyInAlbum.length.toString(),
                },
              ),
            );
          } else {
            ImmichToast.show(
              context: context,
              msg: "home_page_add_to_album_success".tr(
                namedArgs: {
                  "album": album.name,
                  "added": result.successfullyAdded.toString(),
                },
              ),
              toastType: ToastType.success,
            );
          }
        }
      } finally {
        processing.value = false;
        selectionEnabledHook.value = false;
      }
    }

    void onCreateNewAlbum() async {
      processing.value = true;
      try {
        final Iterable<Asset> assets = remoteSelection(
          errorMessage: "home_page_add_to_album_err_local".tr(),
        );
        if (assets.isEmpty) return;
        final result = await ref
            .read(albumServiceProvider)
            .createAlbumWithGeneratedName(assets);
        if (result != null) {
          ref.watch(albumProvider.notifier).refreshRemoteAlbums();
          selectionEnabledHook.value = false;
          context.pushRoute(AlbumViewerRoute(albumId: result.id));
        }
      } finally {
        processing.value = false;
      }
    }

    void onStack() async {
      try {
        processing.value = true;
        if (!selectionEnabledHook.value || selection.value.length < 2) return;
        await ref.read(stackServiceProvider).createStack(
              selection.value.map((e) => e.remoteId!).toList(),
            );
      } finally {
        processing.value = false;
        selectionEnabledHook.value = false;
      }
    }

    void onEditTime() async {
      try {
        final remoteAssets = ownedRemoteSelection(
          localErrorMessage: 'home_page_favorite_err_local'.tr(),
          ownerErrorMessage: 'home_page_favorite_err_partner'.tr(),
        );
        if (remoteAssets.isNotEmpty) {
          handleEditDateTime(ref, context, remoteAssets.toList());
        }
      } finally {
        selectionEnabledHook.value = false;
      }
    }

    void onEditLocation() async {
      try {
        final remoteAssets = ownedRemoteSelection(
          localErrorMessage: 'home_page_favorite_err_local'.tr(),
          ownerErrorMessage: 'home_page_favorite_err_partner'.tr(),
        );
        if (remoteAssets.isNotEmpty) {
          handleEditLocation(ref, context, remoteAssets.toList());
        }
      } finally {
        selectionEnabledHook.value = false;
      }
    }

    // Handler for the "View Locked" action (multi-select lock)
    void onViewLocked() {
      if (selection.value.isEmpty) return;
      log.info(
        "Entering onViewLocked (multi-select). Selection count: ${selection.value.length}",
      );
      final lockedList = SelectedAssetsRenderList(selection.value.toList());
      log.info(
        "Created internal lockedList with ${lockedList.totalAssets} assets.",
      );
      lockedRenderListState.value = lockedList; // Set internal state
      log.info(
        "Set internal lockedRenderListState.value. Is empty? ${lockedRenderListState.value?.isEmpty}",
      );
      selectionEnabledHook.value = false;
      ref.read(lockedViewProvider.notifier).state =
          true; // Activate global lock
      log.info("Set global lockedViewProvider to true.");
    }

    // Handler for unlocking the view (handles both multi-select and album presentation lock)
    Future<void> onUnlock() async {
      final lockedViewNotifier = ref.read(lockedViewProvider.notifier);
      if (!lockedViewNotifier.state) return; // Already unlocked

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
            lockedRenderListState.value = null; // Clear internal state
            externalLockedListNotifier?.value =
                null; // Clear external state if notifier exists
            lockedViewNotifier.state = false; // Disable global lock
            log.info("Unlocked via biometrics.");
          }
        } on PlatformException catch (e) {
          log.severe("Biometric auth error during unlock: $e");
        }
      } else {
        log.warning("Biometrics not supported/available for unlock.");
        // Unlock without auth if biometrics unavailable
        log.warning("Unlocking view without auth (biometrics unavailable).");
        lockedRenderListState.value = null;
        externalLockedListNotifier?.value = null;
        lockedViewNotifier.state = false;
      }
    }

    Future<T> Function() wrapLongRunningFun<T>(
      Future<T> Function() fun, {
      bool showOverlay = true,
    }) =>
        () async {
          if (showOverlay) processing.value = true;
          try {
            final result = await fun();
            if (result.runtimeType != bool || result == true) {
              selectionEnabledHook.value = false;
            }
            return result;
          } finally {
            if (showOverlay) processing.value = false;
          }
        };

    final currentOnRefresh = isLockedView ? null : onRefresh;

    return SafeArea(
      top: !isLockedView,
      bottom: false,
      child: Stack(
        children: [
          // Conditionally build the grid based on the GLOBAL locked state first
          isLockedView // Check the global provider state watched at the top
              ? ValueListenableBuilder<RenderList?>(
                  // Use the external notifier if provided, otherwise a dummy one
                  valueListenable:
                      externalLockedListNotifier ?? ValueNotifier(null),
                  builder: (context, externalList, _) {
                    // Prioritize external list if available, otherwise use internal state
                    final listToUse =
                        externalList ?? lockedRenderListState.value;

                    if (listToUse == null || listToUse.isEmpty) {
                      log.warning(
                        "Rendering locked view (global state): buildEmptyIndicator() because effective list is null or empty (external: ${externalList != null}, internal: ${lockedRenderListState.value != null}).",
                      );
                      return buildEmptyIndicator();
                    } else {
                      log.info(
                        "Rendering locked view (global state): ImmichAssetGrid with effective list (${listToUse.totalAssets} assets, source: ${externalList != null ? 'external' : 'internal'}).",
                      );
                      return ImmichAssetGrid(
                        // Use a key based on the list's hashcode and source
                        key: ValueKey(
                          '${externalList != null ? 'external' : 'internal'}-locked-grid-${listToUse.hashCode}',
                        ),
                        renderList: listToUse,
                        listener: null, // No selection in locked view
                        selectionActive: false, // No selection in locked view
                        onRefresh: null, // No refresh in locked view
                        topWidget: null, // No top widget in locked view
                        showStack: false, // No stack in locked view
                        isLocked: true, // Pass lock state down
                        showDragScrollLabel: dragScrollLabelEnabled,
                      );
                    }
                  },
                )
              // If global state is NOT locked, use the provided renderListProvider
              : ref.watch(renderListProvider).when(
                  data: (data) {
                    // If not locked, but original data is empty
                    if (data.isEmpty &&
                        (buildLoadingIndicator != null || topWidget == null)) {
                      log.fine(
                        "Rendering normal view: buildEmptyIndicator() because provided data is empty.",
                      );
                      return (buildLoadingIndicator ?? buildEmptyIndicator)();
                    }
                    // Render the normal grid using the provided data
                    log.fine(
                      "Rendering normal view: ImmichAssetGrid with provided data (${data.totalAssets} assets).",
                    );
                    return ImmichAssetGrid(
                      key: const ValueKey('normal-grid'),
                      renderList: data,
                      listener: selectionListener,
                      selectionActive: selectionEnabledHook.value,
                      onRefresh: currentOnRefresh == null
                          ? null
                          : wrapLongRunningFun(
                              currentOnRefresh,
                              showOverlay: false,
                            ),
                      topWidget: topWidget,
                      showStack: stackEnabled,
                      isLocked: false, // Explicitly false when not locked
                      showDragScrollLabel: dragScrollLabelEnabled,
                    );
                  },
                  error: (error, _) {
                    log.severe(
                      "Rendering normal view: Error loading data: $error",
                    );
                    return Center(child: Text(error.toString()));
                  },
                  loading: () {
                    log.fine("Rendering normal view: Loading indicator.");
                    return (buildLoadingIndicator ??
                        buildDefaultLoadingIndicator)();
                  },
                ),
          // Show ControlBottomAppBar only if selection is enabled AND not in locked view
          if (selectionEnabledHook.value && !isLockedView)
            ControlBottomAppBar(
              key: const ValueKey("controlBottomAppBar"),
              onShare: onShareAssets,
              onFavorite: favoriteEnabled ? onFavoriteAssets : null,
              onArchive: archiveEnabled ? onArchiveAsset : null,
              onDelete: deleteEnabled ? onDelete : null,
              onDeleteServer: deleteEnabled ? onDeleteRemote : null,
              onDeleteLocal: onDeleteLocal,
              onAddToAlbum: onAddToAlbum,
              onCreateNewAlbum: onCreateNewAlbum,
              onUpload: onUpload,
              enabled: !processing.value,
              selectionAssetState: selectionAssetState.value,
              onStack: stackEnabled ? onStack : null,
              onEditTime: editEnabled ? onEditTime : null,
              onEditLocation: editEnabled ? onEditLocation : null,
              onViewLocked: onViewLocked, // Keep the handler
              unfavorite: unfavorite,
              unarchive: unarchive,
              onRemoveFromAlbum: onRemoveFromAlbum != null
                  ? wrapLongRunningFun(
                      () => onRemoveFromAlbum!(selection.value),
                    )
                  : null,
            ),
          // Show Unlock button when in locked view - Added
          if (isLockedView)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom +
                  20, // Add system padding
              right: 20,
              child: FloatingActionButton.extended(
                onPressed: onUnlock, // Use the unified unlock handler
                icon: const Icon(Icons.lock_open_outlined),
                label: Text('gallery_viewer_authenticate_to_unlock'.tr()),
                backgroundColor: context.colorScheme.primaryContainer,
              ),
            ),
        ],
      ),
    );
  }
}
