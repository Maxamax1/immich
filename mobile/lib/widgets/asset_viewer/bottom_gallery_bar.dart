import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/pages/editing/edit.page.dart';
import 'package:immich_mobile/providers/album/album.provider.dart';
import 'package:immich_mobile/providers/album/current_album.provider.dart';
import 'package:immich_mobile/providers/asset.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_stack.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/current_asset.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/download.provider.dart';
// No longer need showControls provider here
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/stack.service.dart';
import 'package:immich_mobile/utils/hash.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart';
import 'package:immich_mobile/widgets/asset_grid/delete_dialog.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';
import 'package:immich_mobile/widgets/common/immich_image.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';

class BottomGalleryBar extends ConsumerWidget {
  final ValueNotifier<int> assetIndex;
  final bool showStack;
  final ValueNotifier<int> stackIndex;
  final ValueNotifier<int> totalAssets;
  final PageController controller;
  final RenderList renderList;
  final bool isLocked;
  final bool isSelectionMode;

  const BottomGalleryBar({
    super.key,
    required this.showStack,
    required this.stackIndex,
    required this.assetIndex,
    required this.controller,
    required this.totalAssets,
    required this.renderList,
    required this.isLocked,
    required this.isSelectionMode,
  });

  // --- Helper Methods defined inside the class ---

  void _removeAssetFromStack(WidgetRef ref, String? stackId) {
    if (stackIndex.value > 0 && showStack && stackId != null) {
      ref
          .read(assetStackStateProvider(stackId).notifier)
          .removeChild(stackIndex.value - 1);
    }
  }

  Future<void> _handleDelete(
    BuildContext context,
    WidgetRef ref,
    Asset asset,
    bool isStackPrimaryAsset,
  ) async {
    final isTrashEnabled =
        ref.read(serverInfoProvider.select((v) => v.serverFeatures.trash));
    final navStack = AutoRouter.of(context).stackData;
    final isFromTrash = isTrashEnabled &&
        navStack.length > 2 &&
        navStack.elementAt(navStack.length - 2).name == TrashRoute.name;

    Future<bool> onDelete(bool force) async {
      final isDeleted = await ref
          .read(assetProvider.notifier)
          .deleteAssets({asset}, force: force);
      if (isDeleted && isStackPrimaryAsset) {
        renderList.deleteAsset(asset);
        if (totalAssets.value == 1 ||
            assetIndex.value == totalAssets.value - 1) {
          context.maybePop();
        } else {
          totalAssets.value -= 1;
        }
      }
      if (isDeleted && totalAssets.value > 0) {
        // Check if assets remain before setting current
        ref
            .read(currentAssetProvider.notifier)
            .set(renderList.loadAsset(assetIndex.value));
      } else if (isDeleted && totalAssets.value == 0) {
        // If last asset was deleted, pop
        context.maybePop();
      }
      return isDeleted;
    }

    if (isTrashEnabled && !isFromTrash) {
      final isDeleted = await onDelete(false);
      if (isDeleted) {
        if (context.mounted && asset.isRemote && isStackPrimaryAsset) {
          ImmichToast.show(
            durationInSecond: 1,
            context: context,
            msg: 'Asset trashed',
            gravity: ToastGravity.BOTTOM,
          );
        }
        _removeAssetFromStack(ref, asset.stackId);
      }
      return;
    }

    showDialog(
      context: context,
      builder: (BuildContext _) {
        return DeleteDialog(
          onDelete: () async {
            final isDeleted = await onDelete(true);
            if (isDeleted) {
              _removeAssetFromStack(ref, asset.stackId);
            }
          },
        );
      },
    );
  }

  Future<void> _unStack(
    WidgetRef ref,
    Asset asset,
    List<Asset> stackItems,
  ) async {
    if (asset.stackId == null) return;
    await ref
        .read(stackServiceProvider)
        .deleteStack(asset.stackId!, stackItems);
  }

  void _showStackActionItems(
    BuildContext context,
    WidgetRef ref,
    Asset asset,
    List<Asset> stackItems,
  ) {
    showModalBottomSheet<void>(
      context: context,
      enableDrag: false,
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.filter_none_outlined, size: 18),
                  onTap: () async {
                    await _unStack(ref, asset, stackItems);
                    ctx.pop();
                    context.maybePop();
                  },
                  title: const Text(
                    "viewer_unstack",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ).tr(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _shareAsset(BuildContext context, WidgetRef ref, Asset asset) {
    if (asset.isOffline) {
      ImmichToast.show(
        durationInSecond: 1,
        context: context,
        msg: 'asset_action_share_err_offline'.tr(),
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }
    ref.read(downloadStateProvider.notifier).shareAsset(asset, context);
  }

  void _handleEdit(BuildContext context, Asset asset) async {
    final image = Image(image: ImmichImage.imageProvider(asset: asset));
    context.navigator.push(
      MaterialPageRoute(
        builder: (context) =>
            EditImagePage(asset: asset, image: image, isEdited: false),
      ),
    );
  }

  void _handleArchive(
    BuildContext context,
    WidgetRef ref,
    Asset asset,
    bool isStackPrimaryAsset,
  ) {
    ref.read(assetProvider.notifier).toggleArchive([asset]);
    if (isStackPrimaryAsset) {
      context.maybePop();
      return;
    }
    _removeAssetFromStack(ref, asset.stackId);
  }

  void _handleDownload(BuildContext context, WidgetRef ref, Asset asset) {
    if (asset.isLocal) {
      return;
    }
    if (asset.isOffline) {
      ImmichToast.show(
        durationInSecond: 1,
        context: context,
        msg: 'asset_action_share_err_offline'.tr(),
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }
    ref.read(downloadStateProvider.notifier).downloadAsset(asset, context);
  }

  Future<void> _handleRemoveFromAlbum(
    BuildContext context,
    WidgetRef ref,
    Asset asset,
  ) async {
    final album = ref.read(currentAlbumProvider);
    final bool isSuccess = album != null &&
        await ref.read(albumProvider.notifier).removeAsset(album, [asset]);
    if (isSuccess) {
      renderList.deleteAsset(asset);
      if (totalAssets.value == 1) {
        await context.maybePop();
      } else {
        totalAssets.value -= 1;
      }
      if (assetIndex.value == totalAssets.value && assetIndex.value > 0) {
        assetIndex.value -= 1;
      }
      // Update current asset after removal if necessary
      if (totalAssets.value > 0) {
        ref
            .read(currentAssetProvider.notifier)
            .set(renderList.loadAsset(assetIndex.value));
      }
    } else {
      ImmichToast.show(
        context: context,
        msg: "album_viewer_appbar_share_err_remove".tr(),
        toastType: ToastType.error,
        gravity: ToastGravity.BOTTOM,
      );
    }
  }

  // --- End of Helper Methods ---

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(currentAssetProvider);
    if (asset == null) {
      return const SizedBox();
    }
    final isOwner =
        asset.ownerId == fastHash(ref.watch(currentUserProvider)?.id ?? '');
    final stackId = asset.stackId;

    final stackItems = showStack && stackId != null
        ? ref.watch(assetStackStateProvider(stackId))
        : <Asset>[];
    bool isStackPrimaryAsset = asset.stackPrimaryAssetId == null;
    final navStack = AutoRouter.of(context).stackData;
    navStack.length > 2 &&
        navStack.elementAt(navStack.length - 2).name == TrashRoute.name;
    final isInAlbum = ref.watch(currentAlbumProvider)?.isRemote ?? false;

    final List<Map<BottomNavigationBarItem, Function(int)>> albumActions = [
      {
        BottomNavigationBarItem(
          icon: Icon(
            Platform.isAndroid ? Icons.share_rounded : Icons.ios_share_rounded,
          ),
          label: 'control_bottom_app_bar_share'.tr(),
          tooltip: 'control_bottom_app_bar_share'.tr(),
        ): (_) => _shareAsset(context, ref, asset),
      },
      if (asset.isImage)
        {
          BottomNavigationBarItem(
            icon: const Icon(Icons.tune_outlined),
            label: 'control_bottom_app_bar_edit'.tr(),
            tooltip: 'control_bottom_app_bar_edit'.tr(),
          ): (_) => _handleEdit(context, asset),
        },
      if (isOwner)
        {
          asset.isArchived
              ? BottomNavigationBarItem(
                  icon: const Icon(Icons.unarchive_rounded),
                  label: 'control_bottom_app_bar_unarchive'.tr(),
                  tooltip: 'control_bottom_app_bar_unarchive'.tr(),
                )
              : BottomNavigationBarItem(
                  icon: const Icon(Icons.archive_outlined),
                  label: 'control_bottom_app_bar_archive'.tr(),
                  tooltip: 'control_bottom_app_bar_archive'.tr(),
                ): (_) =>
              _handleArchive(context, ref, asset, isStackPrimaryAsset),
        },
      if (isOwner && asset.stackCount > 0)
        {
          BottomNavigationBarItem(
            icon: const Icon(Icons.burst_mode_outlined),
            label: 'control_bottom_app_bar_stack'.tr(),
            tooltip: 'control_bottom_app_bar_stack'.tr(),
          ): (_) => _showStackActionItems(context, ref, asset, stackItems),
        },
      if (isOwner && !isInAlbum)
        {
          BottomNavigationBarItem(
            icon: const Icon(Icons.delete_outline),
            label: 'control_bottom_app_bar_delete'.tr(),
            tooltip: 'control_bottom_app_bar_delete'.tr(),
          ): (_) => _handleDelete(context, ref, asset, isStackPrimaryAsset),
        },
      if (!isOwner)
        {
          BottomNavigationBarItem(
            icon: const Icon(Icons.download_outlined),
            label: 'control_bottom_app_bar_download'.tr(),
            tooltip: 'control_bottom_app_bar_download'.tr(),
          ): (_) => _handleDownload(context, ref, asset),
        },
      if (isInAlbum)
        {
          BottomNavigationBarItem(
            icon: const Icon(Icons.remove_circle_outline),
            label: 'album_viewer_appbar_share_remove'.tr(),
            tooltip: 'album_viewer_appbar_share_remove'.tr(),
          ): (_) => _handleRemoveFromAlbum(context, ref, asset),
        },
    ];

    // Visibility/interactivity is handled by the parent _ConditionalBottomBar wrapper
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black, Colors.transparent],
        ),
      ),
      position: DecorationPosition.background,
      child: Padding(
        padding: const EdgeInsets.only(top: 40.0),
        child: Column(
          children: [
            // Always show video controls if it's a video, regardless of lock state
            if (asset.isVideo) const VideoControls(),
            // Only build and show the action buttons if NOT locked
            if (!isLocked)
              BottomNavigationBar(
                elevation: 0.0,
                backgroundColor: Colors.transparent,
                unselectedIconTheme: const IconThemeData(color: Colors.white),
                selectedIconTheme: const IconThemeData(color: Colors.white),
                unselectedLabelStyle: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  height: 2.3,
                ),
                selectedLabelStyle: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  height: 2.3,
                ),
                unselectedFontSize: 14,
                selectedFontSize: 14,
                selectedItemColor: Colors.white,
                unselectedItemColor: Colors.white,
                showSelectedLabels: true,
                showUnselectedLabels: true,
                items: albumActions
                    .map((e) => e.keys.first)
                    .toList(growable: false),
                onTap: (index) {
                  albumActions[index].values.first.call(index);
                },
              ),
          ],
        ),
      ),
    );
  }
}
