import 'package:immich_mobile/entities/asset.entity.dart';
import 'package:immich_mobile/widgets/asset_grid/asset_grid_data_structure.dart';

/// A simple implementation of RenderList that just holds a fixed list of assets.
/// Used for viewing a specific selection of assets (e.g., search results, shared links, selection).
class SelectedAssetsRenderList extends RenderList {
  SelectedAssetsRenderList(List<Asset> selectedAssets)
      // We pass an empty elements list because we don't need grouping/sections.
      // We pass null for the query because we have all assets in memory.
      // We pass the selectedAssets list to the allAssets parameter.
      : super([], null, selectedAssets);

  // The base RenderList class handles totalAssets getter and loadAsset method
  // correctly when the 'allAssets' parameter is provided in the constructor.
  // No further overrides are needed for basic GalleryViewerPage usage.
}
